#!/usr/bin/env python3
"""Regenerate docs/errors.md from the error registry in src/errors.zig.

The Spec catalog in src/errors.zig is the single source of truth for stable
exit codes, wire `type` tags, causes, remediation hints, and per-class guide
links. This script renders the human-readable catalog so the doc cannot
drift:

    python3 scripts/gen-errors-doc.py          # rewrite docs/errors.md
    python3 scripts/gen-errors-doc.py --check  # exit 1 if docs/errors.md is stale

Stdlib only. Paths resolve relative to the script, so it can run from any cwd.
The errors-doc smoke group runs --check; zig build test separately asserts the
catalog rows and hints appear verbatim in docs/errors.md.
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ERRORS_ZIG = ROOT / "src" / "errors.zig"
VERSION_ZIG = ROOT / "src" / "version.zig"
OUT_MD = ROOT / "docs" / "errors.md"


def fail(msg):
    print(f"gen-errors-doc: {msg}", file=sys.stderr)
    sys.exit(2)


def zig_unescape(s):
    """Decode a Zig string literal body (no surrounding quotes)."""
    def repl(m):
        esc = m.group(1)
        if esc.startswith("x"):
            return chr(int(esc[1:], 16))
        if esc.startswith("u{") and esc.endswith("}"):
            return chr(int(esc[2:-1], 16))
        return {"n": "\n", "r": "\r", "t": "\t", '"': '"', "'": "'",
                "\\": "\\", "0": "\0"}[esc]
    return re.sub(r"\\(x[0-9a-fA-F]{2}|u\{[0-9a-fA-F]+\}|.)", repl, s)


def parse_version_urls(src):
    """pub const name = "url";  ->  {name: url}"""
    return {m.group(1): zig_unescape(m.group(2))
            for m in re.finditer(r'pub const (\w+) = "((?:[^"\\]|\\.)*)";', src)}


def parse_specs(src):
    """Parse `pub const <name> = Spec{ ... };` blocks -> {name: dict}."""
    specs = {}
    for m in re.finditer(r"pub const (\w+) = Spec\{(.*?)\};", src, re.S):
        name, body = m.group(1), m.group(2)
        entry = {}
        code = re.search(r"\.code = (\d+)", body)
        if not code:
            continue
        entry["code"] = int(code.group(1))
        for field in ("type_name", "cause", "hint", "docs"):
            fm = re.search(
                r'\.%s = ("(?:[^"\\]|\\.)*"|\w+)' % field, body)
            if fm:
                raw = fm.group(1)
                entry[field] = zig_unescape(raw[1:-1]) if raw.startswith('"') else raw
        rm = re.search(r"\.recoverable = (true|false)", body)
        entry["recoverable"] = rm.group(1) == "true" if rm else False
        specs[name] = entry
    return specs


def spec_order(src):
    """Order of names in `pub const specs = [_]Spec{ ... };`."""
    m = re.search(r"pub const specs = \[_\]Spec\{(.*?)\};", src, re.S)
    if not m:
        fail("could not find `pub const specs = [_]Spec{...}` in src/errors.zig")
    names = re.findall(r"\b(\w+)\b", re.sub(r"//[^\n]*", "", m.group(1)))
    return names


def md_cell(text):
    return text.replace("|", "\\|")


def doc_link(url):
    """Render a guide URL as [basename](url)."""
    base = url.rsplit("/", 1)[-1]
    return f"[{base}]({url})"


def render(entries, order):
    lines = []
    a = lines.append
    a("# tau error catalog")
    a("")
    a("<!-- GENERATED FILE — do not edit by hand.")
    a("     Source of truth: the Spec catalog in src/errors.zig.")
    a("     Regenerate:  python3 scripts/gen-errors-doc.py")
    a("     Drift check: python3 scripts/gen-errors-doc.py --check")
    a("     (the errors-doc smoke group runs the drift check) -->")
    a("")
    a("Every `{\"err\":{...}}` envelope tau can emit, what triggers it, and how to")
    a("fix it. `code` doubles as the process exit code; `code` and `type` are a")
    a("**stable contract** — integrations may switch on them. New codes may be")
    a("added; existing ones are never renumbered or renamed.")
    a("")
    a("## Envelope shape")
    a("")
    a("Failures are reported on **stderr** as a single-line JSON envelope — even")
    a("in `--mode text` (fleet subcommands are the exception: they report on")
    a("stdout):")
    a("")
    a("```json")
    a('{"err":{"code":106,"type":"AuthFailed","message":"no API key for provider \'openai\'","recoverable":false,"hint":"provide an API key via --api-key, the provider env var, config.json, or TAU_API_KEY","docs":"https://github.com/javimosch/tau/blob/master/docs/providers.md"}}')
    a("```")
    a("")
    a("| Field | Meaning |")
    a("|-------|---------|")
    a("| `code` | Stable exit code — also the process exit status. Branch on this first. |")
    a("| `type` | Stable wire tag for the error class. Emitters may override it with the underlying Zig error name (e.g. `HTTPRequestFailed`) while keeping `code` stable — branch on `code`, use `type` for detail. |")
    a("| `message` | Human-readable detail; usually names the exact fix. |")
    a("| `recoverable` | `true` when retrying the same call may succeed. |")
    a("| `hint` | Canned remediation for the error class; dynamic failures override it with a more specific fix. |")
    a("| `docs` | Guide link for that error class (see the table below). |")
    a("| `debug_log` | Present only when `--debug` opened a diagnostic log — attach it to bug reports. |")
    a("")
    a("## Catalog")
    a("")
    a("| Exit code | `type` | Recoverable | Cause | Remediation `hint` | Guide |")
    a("|-----------|--------|-------------|-------|--------------------|-------|")
    for name in order:
        e = entries[name]
        rec = "`true`" if e["recoverable"] else "`false`"
        a(f"| `{e['code']}` | `{e['type_name']}` | {rec} | {md_cell(e['cause'])} | {md_cell(e['hint'])} | {doc_link(e['docs'])} |")
    a("")
    a("Exit codes outside this table still produce a well-formed envelope: they")
    a("inherit the `internal_error` type and hint while keeping their own `code`.")
    a("")
    a("Non-fatal problems use a separate `{\"warn\":{\"message\":\"...\"}}` envelope")
    a("and the run continues.")
    a("")
    a("## Silent exit paths")
    a("")
    a("Not every failure prints an envelope. These paths exit with a bare status")
    a("and no `{\"err\":...}` line:")
    a("")
    a("| Exit code | When |")
    a("|-----------|------|")
    a("| `82` | `tau` ran with no prompt and no active goal — nothing to do. |")
    a("| `106` | No API key resolved for the provider (checked before the request). |")
    a("| `110` | The `--max-iterations` tool-loop cap was hit mid-turn — partial output may already be on stdout. |")
    a("")
    a("Exit `0` means success and is never an error.")
    a("")
    a("## Regenerating")
    a("")
    a("After editing the Spec catalog in `src/errors.zig`:")
    a("")
    a("```sh")
    a("python3 scripts/gen-errors-doc.py")
    a("```")
    a("")
    a("`--check` regenerates in memory and exits non-zero if this file is stale;")
    a("the `errors-doc` smoke group (`scripts/smoke.sh --group errors-doc`) runs")
    a("it, and `zig build test` asserts every catalog row and hint appears here")
    a("verbatim.")
    a("")
    return "\n".join(lines)


def main():
    check = "--check" in sys.argv[1:]

    errors_src = ERRORS_ZIG.read_text(encoding="utf-8")
    version_src = VERSION_ZIG.read_text(encoding="utf-8")
    urls = parse_version_urls(version_src)

    # Resolve `const alias = @import("version.zig").name;` aliases used by specs.
    aliases = {m.group(1): m.group(2) for m in re.finditer(
        r'const (\w+) = @import\("version\.zig"\)\.(\w+);', errors_src)}

    entries = parse_specs(errors_src)
    order = spec_order(errors_src)

    missing = [n for n in order if n not in entries]
    if missing:
        fail(f"specs names without Spec decls: {', '.join(missing)}")

    for name in order:
        e = entries[name]
        for field in ("type_name", "cause", "hint"):
            if field not in e or not e[field]:
                fail(f"spec '{name}' is missing a non-empty .{field}")
        raw_docs = e.get("docs", "doc_url")
        if raw_docs in aliases:
            target = aliases[raw_docs]
            if target not in urls:
                fail(f"version.zig has no pub const {target}")
            e["docs"] = urls[target]
        elif not raw_docs.startswith("http"):
            fail(f"spec '{name}' .docs uses unresolvable reference '{raw_docs}'")

    rendered = render(entries, order)

    if check:
        if not OUT_MD.exists():
            fail(f"{OUT_MD.relative_to(ROOT)} does not exist — run `python3 scripts/gen-errors-doc.py`")
        current = OUT_MD.read_text(encoding="utf-8")
        if current != rendered:
            print("gen-errors-doc: docs/errors.md is stale — run `python3 scripts/gen-errors-doc.py`", file=sys.stderr)
            sys.exit(1)
        print("gen-errors-doc: docs/errors.md is up to date")
        return

    OUT_MD.write_text(rendered, encoding="utf-8")
    print(f"gen-errors-doc: wrote {OUT_MD.relative_to(ROOT)} ({len(order)} catalog entries)")


if __name__ == "__main__":
    main()
