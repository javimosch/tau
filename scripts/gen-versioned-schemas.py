#!/usr/bin/env python3
"""Generate the versioned, published copy of tau's --json output schemas.

schema/tau-*.schema.json tracks the latest (master) contract — every stable
`--json` command output named in docs/stability.md is pinned there. Each
tagged release also ships a versioned set under schema/v<version>/ so
integrators can fetch the exact schemas a release implements instead of
tracking a moving master URL:

    schema/v0.4.0/tau-doctor.schema.json   # byte-identical to schema/
                                          # except $id, which is re-anchored
                                          # to the release tag:
    https://raw.githubusercontent.com/javimosch/tau/v0.4.0/schema/v0.4.0/tau-doctor.schema.json

    schema/v0.4.0/index.json              # manifest: command -> file + $id

The release workflow (release.yml) packs the directory as the
tau-schemas.tar.gz release asset; SHA256SUMS.txt covers it.

Usage:

    python3 scripts/gen-versioned-schemas.py             # write schema/v<version>/
    python3 scripts/gen-versioned-schemas.py --check     # exit 1 on drift
    python3 scripts/gen-versioned-schemas.py --src DIR --out DIR  # override paths

Stdlib only; paths default to locations relative to this script so it runs
from any cwd. Run it after a version bump (src/version.zig) or any schema
edit, and commit the regenerated directory — CI drift-checks it with
--check (the versioned-schemas smoke group replays the same check).
"""

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCHEMA_DIR = ROOT / "schema"
VERSION_ZIG = ROOT / "src" / "version.zig"
RAW_BASE = "https://raw.githubusercontent.com/javimosch/tau"

# The stable command surface each schema pins, from the "Structured stdout"
# table in docs/stability.md. A schema file missing here fails generation —
# new command schemas must name their command (the index is part of the
# published contract).
COMMANDS = {
    "tau-bug.schema.json": "tau bug --json",
    "tau-completions.schema.json": "tau completions install --json",
    "tau-config-show.schema.json": "tau config show --json",
    "tau-config-validate.schema.json": "tau config validate --json",
    "tau-config.schema.json": "tau config schema",
    "tau-doctor.schema.json": "tau doctor --json",
    "tau-explain.schema.json": "tau explain --json",
    "tau-init.schema.json": "tau init --json",
    "tau-setup.schema.json": "tau setup --json",
    "tau-upgrade.schema.json": "tau upgrade --json",
    "tau-version.schema.json": "tau version --json",
}

ID_LINE = re.compile(r'("\$id":\s*")[^"]*(")')


def fail(msg):
    print(f"gen-versioned-schemas: {msg}", file=sys.stderr)
    sys.exit(2)


def tau_version():
    """The release version the published set is anchored to."""
    m = re.search(r'version\s*=\s*"([^"]+)"', VERSION_ZIG.read_text(encoding="utf-8"))
    if not m:
        fail("could not find version in src/version.zig")
    return m.group(1)


def versioned(text, versioned_id):
    """Rewrite the schema's $id to its tag-anchored URL. Everything else is
    byte-identical to the source so reviewers can diff source vs published."""
    new, n = ID_LINE.subn(r"\g<1>" + versioned_id + r"\g<2>", text, count=1)
    if n != 1:
        fail("schema has no top-level $id to version")
    return new


def render(src_dir, version):
    """Return {relative_name: text} for the whole published directory."""
    sources = sorted(src_dir.glob("tau-*.schema.json"))
    if not sources:
        fail(f"no tau-*.schema.json under {src_dir}")
    out = {}
    entries = []
    for src in sources:
        if src.name not in COMMANDS:
            fail(f"{src.name} has no entry in COMMANDS — name its stable command")
        vid = f"{RAW_BASE}/v{version}/schema/v{version}/{src.name}"
        out[src.name] = versioned(src.read_text(encoding="utf-8"), vid)
        entries.append({
            "command": COMMANDS[src.name],
            "file": src.name,
            "id": vid,
        })
    index = {
        "version": version,
        "schemas": entries,
    }
    out["index.json"] = json.dumps(index, indent=2) + "\n"
    return out


def write_out(out_dir, files):
    out_dir.mkdir(parents=True, exist_ok=True)
    stale = {p.name for p in out_dir.iterdir() if p.is_file()} - set(files)
    for name in stale:
        (out_dir / name).unlink()
    for name, text in files.items():
        (out_dir / name).write_text(text, encoding="utf-8")
    print(f"gen-versioned-schemas: wrote {len(files)} files to {out_dir}")


def check(out_dir, files):
    problems = []
    if not out_dir.is_dir():
        problems.append(f"{out_dir} missing — run scripts/gen-versioned-schemas.py")
    else:
        have = sorted(p.name for p in out_dir.iterdir() if p.is_file())
        want = sorted(files)
        for name in want:
            if name not in have:
                problems.append(f"missing generated file {out_dir / name}")
        for name in have:
            if name not in want:
                problems.append(f"stale file not regenerated: {out_dir / name}")
        for name in set(want) & set(have):
            if (out_dir / name).read_text(encoding="utf-8") != files[name]:
                problems.append(f"{out_dir / name} differs from generated output")
    if problems:
        for p in problems:
            print(f"gen-versioned-schemas: {p}", file=sys.stderr)
        return 1
    print(f"gen-versioned-schemas: {out_dir} is in sync")
    return 0


def main():
    args = sys.argv[1:]
    do_check = "--check" in args
    args = [a for a in args if a != "--check"]

    src_dir, out_dir = SCHEMA_DIR, None
    i = 0
    while i < len(args):
        if args[i] == "--src" and i + 1 < len(args):
            src_dir = Path(args[i + 1]); i += 2
        elif args[i] == "--out" and i + 1 < len(args):
            out_dir = Path(args[i + 1]); i += 2
        else:
            fail(f"unknown argument: {args[i]}")
    if out_dir is None:
        version = tau_version()
        out_dir = SCHEMA_DIR / f"v{version}"

    if do_check:
        files = render(src_dir, tau_version())
        return check(out_dir, files)
    files = render(src_dir, tau_version())
    write_out(out_dir, files)
    return 0


if __name__ == "__main__":
    sys.exit(main())
