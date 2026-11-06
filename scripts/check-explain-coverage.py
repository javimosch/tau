#!/usr/bin/env python3
"""Gate: every generated-catalog entry resolves via `tau explain`.

docs/errors.md is generated from the Spec catalog in src/errors.zig and
docs/config.md from the FileConfig schema — together they declare every
name a user (or an agent parsing the envelope's `explain` footer) can
look up offline. This checker fails when a catalog entry does not
resolve to a real `tau explain` entry, where "resolves" means:

  - `tau explain <code>` exits 0 and emits an entry carrying BOTH the
    code and its catalog `type` tag — an uncataloged code would pass
    vacuously through the generic internal_error fallback, so the tag
    must match too;
  - `tau explain <type-tag>` exits 0 and resolves to the paired code;
  - `tau explain <key>` (each row of the docs/config.md `## Keys` table)
    exits 0 and emits an entry carrying `"key":"<key>"`;
  - `tau explain keys.<member>` — for each member named in the `keys`
    row's "member names" clause — exits 0 with `"key":"keys.<member>"`.

The reverse direction is gated too: every code and key the live
`tau explain` catalog lists must appear in the generated docs, so a new
Spec or config field cannot ship undocumented.

Usage:

    python3 scripts/check-explain-coverage.py [--tau PATH]
        [--errors-doc PATH] [--config-doc PATH]

Exit codes: 0 = full coverage, 1 = coverage gap (each printed to stderr),
2 = usage/IO error. Stdlib only — paths resolve relative to the script,
so it runs from any cwd; the path overrides exist so the smoke harness can
prove the gate fails closed on staged fixtures.
"""

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# Catalog rows in docs/errors.md: `| `106` | `AuthFailed` | ...` — code
# plus its wire `type` tag. The silent-exit table repeats codes without a
# tag column and the envelope-shape table's first cells are field names,
# so the pair regex only matches real catalog rows.
ERROR_PAIR = re.compile(r"^\|\s*`(\d+)`\s*\|\s*`([^`]+)`\s*\|", re.MULTILINE)

# Key rows inside the docs/config.md `## Keys` table: `| `timeout_ms` |`.
CONFIG_ROW = re.compile(r"^\|\s*`([^`\s]+)`\s*\|", re.MULTILINE)
KEYS_SECTION = re.compile(r"^## Keys\b.*?(?=^## |\Z)", re.MULTILINE | re.DOTALL)

# The `keys` row declares its member names inside the constraints cell:
#   member names: `xiaomi` | `openai` | `deepseek` | `opencode-go`; ...
MEMBER_CLAUSE = re.compile(r"member names:([^;]+)")
MEMBER_TOKEN = re.compile(r"`([^`]+)`")


def error_entries(catalog: Path):
    """{(code, type)} pairs from the docs/errors.md catalog table."""
    if not catalog.is_file():
        raise OSError(f"catalog not found: {catalog}")
    pairs = set(ERROR_PAIR.findall(catalog.read_text(encoding="utf-8")))
    if not pairs:
        raise OSError(f"no `| `<code>` | `<type>` |` rows parsed from {catalog}")
    return pairs


def config_entries(doc: Path):
    """([flat keys], [member names]) from the docs/config.md ## Keys table."""
    if not doc.is_file():
        raise OSError(f"config doc not found: {doc}")
    text = doc.read_text(encoding="utf-8")
    section = KEYS_SECTION.search(text)
    if not section:
        raise OSError(f"no '## Keys' section parsed from {doc}")
    keys = CONFIG_ROW.findall(section.group(0))
    if not keys:
        raise OSError(f"no `| `<key>` |` rows parsed from {doc} ## Keys")
    members = []
    for line in section.group(0).splitlines():
        if line.startswith("| `keys` |"):
            clause = MEMBER_CLAUSE.search(line)
            if clause:
                members = MEMBER_TOKEN.findall(clause.group(1))
    return keys, members


def explain(tau: str, *args):
    """(returncode, stdout) of `tau explain <args>` — pure catalog lookup."""
    proc = subprocess.run([tau, "explain", *args], capture_output=True, text=True)
    return proc.returncode, proc.stdout


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--tau", default=str(ROOT / "zig-out" / "bin" / "tau"),
                    help="path to the tau binary")
    ap.add_argument("--errors-doc", type=Path, default=ROOT / "docs" / "errors.md")
    ap.add_argument("--config-doc", type=Path, default=ROOT / "docs" / "config.md")
    args = ap.parse_args(argv)

    if not Path(args.tau).is_file():
        print(f"check-explain-coverage: tau binary not found: {args.tau}",
              file=sys.stderr)
        return 2

    try:
        errors = error_entries(args.errors_doc)
        keys, members = config_entries(args.config_doc)
    except OSError as e:
        print(f"check-explain-coverage: {e}", file=sys.stderr)
        return 2

    problems = []

    # Forward: every documented entry resolves to a real explain entry.
    for code, tag in sorted(errors, key=lambda p: int(p[0])):
        rc, out = explain(args.tau, code)
        if rc != 0 or f'"code":{code}' not in out or f'"type":"{tag}"' not in out:
            problems.append(
                f"errors.md code {code} (`{tag}`) does not resolve to a real "
                f"`tau explain {code}` entry (exit {rc}) — a missing Spec emits "
                "the internal_error fallback instead of the catalog tag"
            )
        rc, out = explain(args.tau, tag)
        if rc != 0 or f'"code":{code}' not in out:
            problems.append(
                f"errors.md type `{tag}` does not resolve to code {code} via "
                f"`tau explain {tag}` (exit {rc})"
            )
    for key in sorted(keys):
        rc, out = explain(args.tau, key)
        if rc != 0 or f'"key":"{key}"' not in out:
            problems.append(
                f"config.md key `{key}` does not resolve via `tau explain {key}` "
                f"(exit {rc})"
            )
    for member in sorted(members):
        path = f"keys.{member}"
        rc, out = explain(args.tau, path)
        if rc != 0 or f'"key":"{path}"' not in out:
            problems.append(
                f"config.md member path `{path}` does not resolve via "
                f"`tau explain {path}` (exit {rc})"
            )

    # Reverse: every entry the live catalog lists is documented.
    rc, out = explain(args.tau)
    if rc != 0:
        problems.append(f"`tau explain` catalog listing exited {rc}")
    else:
        try:
            live = json.loads(out)
        except json.JSONDecodeError as e:
            problems.append(f"`tau explain` catalog listing is not JSON: {e}")
        else:
            documented = {code for code, _ in errors}
            for entry in live.get("errors", []):
                if str(entry.get("code")) not in documented:
                    problems.append(
                        f"`tau explain` lists code {entry.get('code')} but it is "
                        "absent from docs/errors.md — regenerate the catalog"
                    )
            allowed_keys = set(keys) | {f"keys.{m}" for m in members}
            for entry in live.get("config_keys", []):
                if entry.get("key") not in allowed_keys:
                    problems.append(
                        f"`tau explain` lists key `{entry.get('key')}` but it is "
                        "absent from docs/config.md — regenerate the catalog"
                    )

    for p in problems:
        print(f"check-explain-coverage: {p}", file=sys.stderr)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
