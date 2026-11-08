#!/usr/bin/env python3
"""Regenerate docs/env.md from the TAU_* env-var registry in src/envvars.zig.

The Spec table in src/envvars.zig is the single source of truth for the
recognized TAU_* environment surface — the same table the startup warning
(unknownVarWarning) scans against before emitting a {"warn"} envelope for
unrecognized or misspelled names. This script renders the human-readable
catalog so the doc cannot drift:

    python3 scripts/gen-env-doc.py          # rewrite docs/env.md
    python3 scripts/gen-env-doc.py --check  # exit 1 if docs/env.md is stale

Stdlib only. Paths resolve relative to the script, so it can run from any
cwd. The env-doc smoke group runs --check; zig build test separately
asserts every catalog row and summary appears verbatim in docs/env.md.
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ENVVARS_ZIG = ROOT / "src" / "envvars.zig"
VERSION_ZIG = ROOT / "src" / "version.zig"
OUT_MD = ROOT / "docs" / "env.md"

SECTION_TITLES = {
    "tau": "Read by the tau binary",
    "installer": "Read by the installers",
    "external": "Read by companion tooling",
}
SECTION_ORDER = ("tau", "installer", "external")


def fail(msg):
    print(f"gen-env-doc: {msg}", file=sys.stderr)
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


def parse_specs(src):
    """Parse the `pub const specs = [_]Spec{ ... };` block -> [dict]."""
    m = re.search(r"pub const specs = \[_\]Spec\{(.*?)\};", src, re.S)
    if not m:
        fail("could not find `pub const specs = [_]Spec{...}` in src/envvars.zig")
    # Strip full-line comments only — inline `//` stripping would eat the
    # `file://` URLs inside summary string literals.
    body = re.sub(r"(?m)^\s*//[^\n]*$", "", m.group(1))
    specs = []
    for em in re.finditer(r"\.\{(.*?)\},?", body, re.S):
        entry = {}
        eb = em.group(1)
        for field in ("name", "consumers", "summary"):
            fm = re.search(
                r'\.%s = ("(?:[^"\\]|\\.)*")' % field, eb)
            if not fm:
                fail(f"spec missing .{field}: {eb.strip()[:80]}")
            entry[field] = zig_unescape(fm.group(1)[1:-1])
        sm = re.search(r"\.section = \.(\w+)", eb)
        if not sm or sm.group(1) not in SECTION_TITLES:
            fail(f"spec {entry['name']} missing a valid .section")
        entry["section"] = sm.group(1)
        specs.append(entry)
    if not specs:
        fail("no Spec entries parsed from src/envvars.zig")
    return specs


def parse_version_urls(src):
    """pub const name = "url";  ->  {name: url}"""
    return {m.group(1): zig_unescape(m.group(2))
            for m in re.finditer(r'pub const (\w+) = "((?:[^"\\]|\\.)*)";', src)}


def md_cell(text):
    return text.replace("|", "\\|")


def render(specs, env_url):
    lines = []
    a = lines.append
    a("# tau environment variables")
    a("")
    a("<!-- GENERATED FILE — do not edit by hand.")
    a("     Source of truth: the Spec registry in src/envvars.zig.")
    a("     Regenerate:  python3 scripts/gen-env-doc.py")
    a("     Drift check: python3 scripts/gen-env-doc.py --check")
    a("     (the env-doc smoke group runs the drift check) -->")
    a("")
    a("Every `TAU_*` environment variable tau — or its companion tooling —")
    a("recognizes, what consumes it, and what it does. Precedence is stable:")
    a("**CLI flags > environment > config file > in-code defaults**.")
    a("")
    a("## Typo warnings")
    a("")
    a("At startup tau scans the environment for `TAU_*` names that are not in")
    a("this catalog — a misspelled variable is silently ignored by every")
    a("consumer otherwise. Unrecognized names emit a")
    a("`{\"warn\":{\"message\":\"...\"}}` envelope on stderr (the run continues),")
    a("sorted by name; each within two case-insensitive edits of a recognized")
    a("name gets a ` — did you mean \"<name>\"?` hint pointing back here:")
    a("")
    a("```console")
    a('$ TAU_ENDPONT=https://example.com tau --version')
    a('{"warn":{"message":"environment has unrecognized TAU_* variable (ignored): \\"TAU_ENDPONT\\" — did you mean \\"TAU_ENDPOINT\\"? — the recognized set is documented at ' + env_url + '"}}')
    a("```")
    a("")
    a("Only the exact `TAU_` prefix is scanned — provider keys")
    a("(`XIAOMI_API_KEY`, `OPENAI_API_KEY`, `DEEPSEEK_API_KEY`,")
    a("`OPENCODE_API_KEY`, `PIZIG_API_KEY`), generic variables (`HOME`,")
    a("`NO_COLOR`, `SHELL`, `VISUAL`, `EDITOR`), and proxy/TLS variables are")
    a("documented in [docs/configuration.md](configuration.md) and never warn.")
    a("")

    for section in SECTION_ORDER:
        rows = [s for s in specs if s["section"] == section]
        if not rows:
            continue
        a(f"## {SECTION_TITLES[section]}")
        a("")
        a("| Variable | Consumed by | Purpose |")
        a("|----------|-------------|---------|")
        for s in rows:
            a(f"| `{s['name']}` | {md_cell(s['consumers'])} | {md_cell(s['summary'])} |")
        a("")

    a("Variables under \"companion tooling\" are documented surface — external")
    a("launchers translate them into CLI flags — so they never trigger the")
    a("typo warning even though `tau` itself ignores them.")
    a("")
    a("## Regenerating")
    a("")
    a("After editing the Spec registry in `src/envvars.zig`:")
    a("")
    a("```sh")
    a("python3 scripts/gen-env-doc.py")
    a("```")
    a("")
    a("`--check` regenerates in memory and exits non-zero if this file is")
    a("stale; the `env-doc` smoke group (`scripts/smoke.sh --group env-doc`)")
    a("runs it, and `zig build test` asserts every registry row and summary")
    a("appears here verbatim.")
    a("")
    return "\n".join(lines)


def main():
    check = "--check" in sys.argv[1:]

    envvars_src = ENVVARS_ZIG.read_text(encoding="utf-8")
    version_src = VERSION_ZIG.read_text(encoding="utf-8")
    urls = parse_version_urls(version_src)
    env_url = urls.get("env_doc_url")
    if not env_url:
        fail("version.zig is missing env_doc_url")

    specs = parse_specs(envvars_src)
    seen = set()
    for s in specs:
        if not s["name"].startswith("TAU_"):
            fail(f"registry name {s['name']} lacks the TAU_ prefix")
        if s["name"] in seen:
            fail(f"duplicate registry name {s['name']}")
        seen.add(s["name"])

    rendered = render(specs, env_url)

    if check:
        if not OUT_MD.exists():
            fail("docs/env.md does not exist — run gen-env-doc.py to create it")
        current = OUT_MD.read_text(encoding="utf-8")
        if current != rendered:
            print("gen-env-doc: docs/env.md is stale — run gen-env-doc.py",
                  file=sys.stderr)
            sys.exit(1)
        return

    OUT_MD.write_text(rendered, encoding="utf-8")
    print(f"wrote {OUT_MD}")


if __name__ == "__main__":
    main()
