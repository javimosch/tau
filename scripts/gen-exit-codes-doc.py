#!/usr/bin/env python3
"""Regenerate docs/exit-codes.md from the exit-code registry in src/exitcodes.zig.

The Spec catalog in src/exitcodes.zig is the single source of truth for the
process exit-status contract — the codes scripts branch on, their semantic
names (the `ExitCode` enum spellings `--help-json` advertises), what each
status means, and where a script reads the detail. This script renders the
human-readable catalog so the doc cannot drift:

    python3 scripts/gen-exit-codes-doc.py          # rewrite docs/exit-codes.md
    python3 scripts/gen-exit-codes-doc.py --check  # exit 1 if docs/exit-codes.md is stale

Stdlib only. Paths resolve relative to the script, so it can run from any cwd.
The exit-codes-doc smoke group runs --check; zig build test separately
asserts the catalog rows, meanings, and scripting cells appear verbatim in
docs/exit-codes.md.
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
EXITCODES_ZIG = ROOT / "src" / "exitcodes.zig"
VERSION_ZIG = ROOT / "src" / "version.zig"
OUT_MD = ROOT / "docs" / "exit-codes.md"


def fail(msg):
    print(f"gen-exit-codes-doc: {msg}", file=sys.stderr)
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
        for field in ("name", "meaning", "scripting", "docs"):
            fm = re.search(
                r'\.%s = ("(?:[^"\\]|\\.)*"|\w+)' % field, body)
            if fm:
                raw = fm.group(1)
                entry[field] = zig_unescape(raw[1:-1]) if raw.startswith('"') else raw
        specs[name] = entry
    return specs


def spec_order(src):
    """Order of names in `pub const specs = [_]Spec{ ... };`."""
    m = re.search(r"pub const specs = \[_\]Spec\{(.*?)\};", src, re.S)
    if not m:
        fail("could not find `pub const specs = [_]Spec{...}` in src/exitcodes.zig")
    names = re.findall(r"\b(\w+)\b", re.sub(r"//[^\n]*", "", m.group(1)))
    return names


def md_cell(text):
    return text.replace("|", "\\|")


def render(entries, order):
    lines = []
    a = lines.append
    a("# tau exit codes — the scripting contract")
    a("")
    a("<!-- GENERATED FILE — do not edit by hand.")
    a("     Source of truth: the Spec catalog in src/exitcodes.zig.")
    a("     Regenerate:  python3 scripts/gen-exit-codes-doc.py")
    a("     Drift check: python3 scripts/gen-exit-codes-doc.py --check")
    a("     (the exit-codes-doc smoke group runs the drift check) -->")
    a("")
    a("Every process exit status tau can return, what it means, and where a")
    a("script reads the detail. These codes are a **stable contract** —")
    a("integrations may branch on `$?` / `$LASTEXITCODE`. New codes may be")
    a("added; existing ones are never renumbered or renamed.")
    a("")
    a("`name` is the semantic identifier — the same spelling the `ExitCode`")
    a("enum and `--help-json`'s `exit_codes` map use. It deliberately differs")
    a("from the error catalog's wire `type` tags in [docs/errors.md](errors.md)")
    a("(exit `105` is `connection_timeout`; its envelope type is `Timeout`).")
    a("")
    a("## Catalog")
    a("")
    a("| Exit code | `name` | Meaning | Scripting guidance |")
    a("|-----------|--------|---------|--------------------|")
    for name in order:
        e = entries[name]
        a(f"| `{e['code']}` | `{e['name']}` | {md_cell(e['meaning'])} | {md_cell(e['scripting'])} |")
    a("")
    a("Exit statuses outside this table are not part of the contract — an")
    a("uncataloged nonzero status still produces a well-formed `{\"err\"}`")
    a("envelope (inheriting the `internal_error` type) when one is emitted,")
    a("but only the codes above are guaranteed stable.")
    a("")
    a("## Reading this catalog offline")
    a("")
    a("`tau explain` renders the same registry from the CLI — no network or")
    a("API key needed. The `exit.` prefix selects this contract view: a bare")
    a("decimal stays an error-catalog lookup (`tau explain 80` prints the")
    a("`invalid_argument` error entry), while `tau explain exit.80` prints")
    a("the process-status contract:")
    a("")
    a("```sh")
    a("tau explain                 # every catalog entry (JSON)")
    a("tau explain exit.0          # what exit 0 guarantees on stdout")
    a("tau explain exit.80         # the invalid_argument status contract")
    a("tau explain exit.auth_failed  # name spellings resolve too")
    a("tau explain --human exit.1  # prose instead of JSON")
    a("```")
    a("")
    a("The bare `tau explain` catalog lists these entries under `exit_codes`;")
    a("`exit.` queries that don't resolve — `exit.42`, `exit.bogus` — exit `1`")
    a("with a `not_found` envelope (the `exit.` namespace fails closed rather")
    a("than borrowing the error catalog's uncataloged-code fallback).")
    a("")
    a("For envelope-level detail — the `{\"err\":{code,type,...}}` object a")
    a("failure prints on stderr — see the generated error catalog in")
    a("[docs/errors.md](errors.md); `tau explain <code>` renders those entries.")
    a("For the broader stability policy (what is contract vs. informational),")
    a("see [docs/stability.md](stability.md).")
    a("")
    a("## Regenerating")
    a("")
    a("After editing the Spec catalog in `src/exitcodes.zig`:")
    a("")
    a("```sh")
    a("python3 scripts/gen-exit-codes-doc.py")
    a("```")
    a("")
    a("`--check` regenerates in memory and exits non-zero if this file is")
    a("stale; the `exit-codes-doc` smoke group")
    a("(`scripts/smoke.sh --group exit-codes-doc`) runs it, `zig build test`")
    a("asserts every catalog row and meaning/scripting cell appears here")
    a("verbatim, and the `explain-coverage` gate checks every row resolves")
    a("via `tau explain exit.<code>`.")
    a("")
    return "\n".join(lines)


def main():
    check = "--check" in sys.argv[1:]

    exitcodes_src = EXITCODES_ZIG.read_text(encoding="utf-8")
    version_src = VERSION_ZIG.read_text(encoding="utf-8")
    urls = parse_version_urls(version_src)

    # Resolve `const alias = @import("version.zig").name;` aliases used by specs.
    aliases = {m.group(1): m.group(2) for m in re.finditer(
        r'const (\w+) = @import\("version\.zig"\)\.(\w+);', exitcodes_src)}

    entries = parse_specs(exitcodes_src)
    order = spec_order(exitcodes_src)

    missing = [n for n in order if n not in entries]
    if missing:
        fail(f"specs names without Spec decls: {', '.join(missing)}")

    for name in order:
        e = entries[name]
        for field in ("name", "meaning", "scripting"):
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
            fail(f"{OUT_MD.relative_to(ROOT)} does not exist — run `python3 scripts/gen-exit-codes-doc.py`")
        current = OUT_MD.read_text(encoding="utf-8")
        if current != rendered:
            print("gen-exit-codes-doc: docs/exit-codes.md is stale — run `python3 scripts/gen-exit-codes-doc.py`", file=sys.stderr)
            sys.exit(1)
        print("gen-exit-codes-doc: docs/exit-codes.md is up to date")
        return

    OUT_MD.write_text(rendered, encoding="utf-8")
    print(f"gen-exit-codes-doc: wrote {OUT_MD.relative_to(ROOT)} ({len(order)} catalog entries)")


if __name__ == "__main__":
    main()
