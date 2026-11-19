#!/usr/bin/env python3
"""Regenerate docs/cli-reference.md from the CLI surface.

The single sources of truth are the same tables and help pages the
binary itself prints:

- `flag_specs` + `help_text` in src/main.zig — the global flag table
  (`tau --help` Options section supplies the descriptions; the same
  `flag_specs` table `tau --help-json` emits supplies the names),
  plus the goal-mode directives, exit codes, and top-level examples.
- The per-subcommand help pages in src/subhelp.zig — each section
  embeds the exact `tau <name> --help` text (also byte-locked by the
  golden-help smoke goldens).
- The Spec registry in src/subcommandcatalog.zig — the same catalog
  `tau explain subcommand.<name>` reads — for each section's summary,
  related error/config-key/doctor-check links, and docs URL.

    python3 scripts/gen-cli-reference-doc.py            # rewrite docs/cli-reference.md
    python3 scripts/gen-cli-reference-doc.py --check    # exit 1 if the doc is stale

Every subcommand section is the exact byte shape subcommandSectionMarkdown
in src/subcommandcatalog.zig renders — the doc-mirror zig test pins each
section verbatim, and the cross-checks below keep the catalog in sync
with subhelp.zig's entries table.

Stdlib only. Paths resolve relative to the script, so it can run from
any cwd. The cli-reference-doc smoke group runs --check.
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MAIN_ZIG = ROOT / "src" / "main.zig"
SUBHELP_ZIG = ROOT / "src" / "subhelp.zig"
SUBCAT_ZIG = ROOT / "src" / "subcommandcatalog.zig"
VERSION_ZIG = ROOT / "src" / "version.zig"
OUT_MD = ROOT / "docs" / "cli-reference.md"


def fail(msg):
    print(f"gen-cli-reference-doc: {msg}", file=sys.stderr)
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


STRING = r'"((?:[^"\\]|\\.)*)"'
REPO_BASE = "https://github.com/javimosch/tau/blob/master/"


def zig_stripped(src):
    """Return src with strings/comments blanked out (same length), so
    structural scans can't be fooled by braces inside literals."""
    out = list(src)
    i, n = 0, len(src)
    while i < n:
        if src.startswith("//", i):
            j = src.find("\n", i)
            j = n if j < 0 else j
            for k in range(i, j):
                out[k] = " "
            i = j
        elif src.startswith("\\\\", i):
            line_start = src.rfind("\n", 0, i) + 1
            if src[line_start:i].strip() == "":
                j = src.find("\n", i)
                j = n if j < 0 else j
                for k in range(i, j):
                    out[k] = " "
                i = j
            else:
                i += 2
        elif src[i] == '"':
            j = i + 1
            while j < n and src[j] != '"':
                if src[j] == "\\":
                    j += 1
                j += 1
            for k in range(i, min(j + 1, n)):
                out[k] = " "
            i = j + 1
        else:
            i += 1
    return "".join(out)


def multiline_segments(src, const_name, path):
    """The line segments of `const <name> =\n    \\seg\n    \\seg\n;` —
    one entry per `\\\\` line, preserving Zig's join semantics."""
    m = re.search(r"(?:pub )?const %s =\n((?:[ \t]*\\\\[^\n]*\n)+)"
                  % re.escape(const_name), src)
    if not m:
        fail(f"could not find multiline `const {const_name}` in {path}")
    segs = []
    for line in m.group(1).splitlines():
        sm = re.match(r"^[ \t]*\\\\(.*)$", line)
        if not sm:
            fail(f"unparseable multiline line in {const_name}: {line!r}")
        segs.append(sm.group(1))
    return segs


def md_cell(text):
    return text.replace("|", "\\|")


def docs_link(url):
    """[repo/rel/path](path-relative-to-docs/) — mirrors the Docs line in
    subcommandSectionMarkdown (src/subcommandcatalog.zig)."""
    if url.startswith(REPO_BASE):
        rel = url[len(REPO_BASE):]
        href = rel[5:] if rel.startswith("docs/") else "../" + rel
        return f"[{rel}]({href})"
    return f"[{url}]({url})"


def section_lines(lines, start, stop):
    """Help-text lines strictly between the `start` and `stop` headers."""
    if start not in lines:
        fail(f"help_text has no '{start}' section")
    i = lines.index(start)
    j = lines.index(stop, i + 1) if stop in lines else len(lines)
    return lines[i + 1:j]


FLAG_ENTRY = re.compile(
    r"^  (?:-\S+, +)? {0,4}(--[a-z][a-z0-9-]*)"
    r"( <[^>]+>)?(?: {2,}(.*))?$")


def parse_flag_descs(option_lines):
    """long flag -> single-line description from help_text's Options."""
    descs = {}
    last = None
    for line in option_lines:
        m = FLAG_ENTRY.match(line)
        if m:
            long, _arg, desc = m.group(1), m.group(2), (m.group(3) or "").strip()
            descs[long] = desc
            last = long
        elif line.strip():
            if last is None:
                fail(f"Options continuation before any flag: {line!r}")
            descs[last] = (descs[last] + " " + line.strip()).strip()
    return descs


def parse_main(src):
    """flag_specs + help_text (options, goal lines, exit codes, examples)."""
    clean = zig_stripped(src)

    m = re.search(r"const flag_specs = \[_\]FlagSpec\{(.*?)\};", clean, re.S)
    if not m:
        fail("could not find `const flag_specs` in src/main.zig")
    flags = []
    for fm in re.finditer(
            r'\.\{\s*\.long = "([^"]+)"'
            r'(?:\s*,\s*\.short = "([^"]+)")?'
            r'(?:\s*,\s*\.arg = "([^"]+)")?\s*\}', src[m.start(1):m.end(1)]):
        flags.append({"long": fm.group(1), "short": fm.group(2),
                      "arg": fm.group(3)})
    if not flags:
        fail("flag_specs parsed empty")

    help_lines = multiline_segments(src, "help_text", "src/main.zig")
    option_lines = section_lines(help_lines, "Options:", "Setup:")
    descs = parse_flag_descs(option_lines)
    for f in flags:
        if f["long"] not in descs:
            fail(f"help_text Options has no entry for flag_specs "
                 f"'{f['long']}'")
    extra = [k for k in descs if k not in {f["long"] for f in flags}]
    if extra:
        fail(f"help_text Options entries missing from flag_specs: {extra}")

    usage = [l.strip() for l in section_lines(help_lines, "Usage:", "Options:")
             if l.strip()]
    if len(usage) != 1 or not usage[0].startswith("tau "):
        fail(f"help_text Usage block is not a single 'tau ...' line: {usage!r}")

    goal_lines = section_lines(help_lines, "Goal mode (in the prompt):",
                               "ACP (Agent Client Protocol) server:")
    goals = []
    for line in goal_lines:
        if not line.strip():
            continue
        gm = re.match(r"^  (/goal .+?) {2,}(.*)$", line)
        if not gm:
            fail(f"unparseable goal-mode line: {line!r}")
        goals.append((gm.group(1).strip(), gm.group(2).strip()))

    em = re.search(r'\\"exit_codes\\":\{([^}]*)\}', src)
    if not em:
        fail("could not find the exit_codes object in src/main.zig")
    exit_codes = re.findall(r'\\"(\d+)\\":\\"([^\\]+)\\"', em.group(1))
    if not exit_codes:
        fail("exit_codes parsed empty")

    ex_lines = section_lines(help_lines, "Examples:", None)
    examples = [l.strip() for l in ex_lines if l.strip()]
    if not examples or not all(e.startswith("tau ") for e in examples):
        fail(f"help_text Examples block has non-'tau ...' lines: {examples!r}")

    return {"flags": flags, "descs": descs, "usage": usage[0],
            "goals": goals, "exit_codes": exit_codes, "examples": examples}


def parse_subhelp(src):
    """Ordered (name, help-text) pairs from the entries table."""
    clean = zig_stripped(src)
    m = re.search(r"pub const entries = \[_\]Entry\{(.*?)\};", clean, re.S)
    if not m:
        fail("could not find `pub const entries` in src/subhelp.zig")
    pairs = re.findall(r'\.\{ \.name = "([^"]+)", \.text = (\w+) \}',
                       src[m.start(1):m.end(1)])
    if not pairs:
        fail("subhelp entries table parsed empty")
    out = []
    for name, const_name in pairs:
        out.append((name, "\n".join(
            multiline_segments(src, const_name, "src/subhelp.zig"))))
    return out


def parse_version_urls(src):
    """`pub const X = "url";` consts in src/version.zig."""
    urls = {}
    for m in re.finditer(r"pub const (\w+) = " + STRING + ";", src):
        urls[m.group(1)] = zig_unescape(m.group(2))
    if not urls:
        fail("no url consts found in src/version.zig")
    return urls


def resolve_docs(expr, urls):
    """Evaluate a Spec.docs expression: `repo_doc_base ++ "p"` /
    `version.x_doc_url` / `version.x_doc_url ++ "#frag"` / `"literal"`."""
    url = ""
    for part in expr.split("++"):
        part = part.strip()
        if part == "repo_doc_base":
            url += REPO_BASE
        elif part.startswith("version."):
            key = part[len("version."):]
            if key not in urls:
                fail(f"unresolved version const in docs expr: {expr!r}")
            url += urls[key]
        else:
            sm = re.match(STRING + r"$", part)
            if not sm:
                fail(f"unrecognized docs expr part {part!r} in {expr!r}")
            url += zig_unescape(sm.group(1))
    return url


def parse_specs(src, urls):
    """Ordered Spec dicts from the subcommandcatalog specs table."""
    clean = zig_stripped(src)
    m = re.search(r"pub const specs = \[_\]Spec\{", clean)
    if not m:
        fail("could not find `pub const specs` in src/subcommandcatalog.zig")
    body_clean = clean[m.end():]
    # Each Spec entry opens at `    .{` (col-4) — inner `&.{...}` array
    # literals never sit at that indent.
    starts = [sm.start() for sm in re.finditer(r"(?m)^    \.\{", body_clean)]
    if not starts:
        fail("specs table parsed empty")
    specs = []
    for idx, pos in enumerate(starts):
        end = starts[idx + 1] if idx + 1 < len(starts) else len(body_clean)
        raw = src[m.end() + pos:m.end() + end]
        s = {}
        for field, key in (("name", "name"), ("summary", "summary")):
            fm = re.search(r"\.%s = %s" % (field, STRING), raw)
            if not fm:
                fail(f"spec entry missing .{field}: {raw[:80]!r}")
            s[key] = zig_unescape(fm.group(1))
        for field in ("errors", "config_keys", "doctor_checks"):
            fm = re.search(r"\.%s = &\.\{(.*?)\}" % field, raw, re.S)
            if not fm:
                fail(f"spec '{s['name']}' missing .{field}")
            s[field] = [zig_unescape(x)
                        for x in re.findall(STRING, fm.group(1))]
        dm = re.search(r"\.docs = (.+?),\s*\n\s*\}", raw)
        if not dm:
            fail(f"spec '{s['name']}' missing .docs")
        s["docs"] = resolve_docs(dm.group(1), urls)
        specs.append(s)
    return specs


def rel_group(label, items):
    return label + " " + ", ".join(f"`{x}`" for x in items)


def render_subcmd(spec, help_text):
    """One subcommand section — byte-identical to subcommandSectionMarkdown
    in src/subcommandcatalog.zig (the doc-mirror test pins that)."""
    groups = []
    if spec["errors"]:
        groups.append(rel_group("errors", spec["errors"]))
    if spec["config_keys"]:
        groups.append(rel_group("config keys", spec["config_keys"]))
    if spec["doctor_checks"]:
        groups.append(rel_group("checks", spec["doctor_checks"]))
    n = spec["name"]
    return (f"### `tau {n}`\n\n{spec['summary']}\n\n```text\n{help_text}```\n\n"
            f"- **Related:** {' · '.join(groups) if groups else '—'}\n"
            f"- **Explain:** `tau explain subcommand.{n}` "
            f"(bare `tau explain {n}` resolves too)\n"
            f"- **Docs:** {docs_link(spec['docs'])}\n")


def render(main, entries, specs):
    help_map = dict(entries)
    spec_map = {s["name"]: s for s in specs}
    if [n for n, _ in entries] != [s["name"] for s in specs]:
        fail("subhelp entries order does not match the subcommandcatalog "
             "specs order")
    for n, _ in entries:
        if n not in spec_map:
            fail(f"subcommandcatalog.zig has no Spec for subhelp entry '{n}'")

    a = []
    w = a.append
    w("# `tau` CLI reference")
    w("")
    w("<!-- GENERATED FILE — do not edit by hand.")
    w("     Source of truth: flag_specs + help_text in src/main.zig (the")
    w("     same tables `tau --help` and `tau --help-json` emit), the")
    w("     per-subcommand help pages in src/subhelp.zig, and the Spec")
    w("     registry in src/subcommandcatalog.zig — the same catalog")
    w("     `tau explain subcommand.<name>` reads.")
    w("     Regenerate:  python3 scripts/gen-cli-reference-doc.py")
    w("     Drift check: python3 scripts/gen-cli-reference-doc.py --check")
    w("     (the cli-reference-doc smoke group runs the drift check) -->")
    w("")
    w("Everything `tau --help` and every `tau <subcommand> --help` prints,")
    w("on one browsable page: the global flag table, goal-mode directives,")
    w("exit codes, and a section per subcommand with its full help text —")
    w("usage, options, and runnable examples — plus the offline explain")
    w("catalog's related links. Each help page is byte-locked by the")
    w("golden-help goldens and every `tau ...` example is proven to parse")
    w("by the subhelp.zig unit tests, so this reference cannot drift from")
    w("the real CLI surface.")
    w("")
    w("## `tau` — prompt mode")
    w("")
    w(f"`{main['usage']}` — `@path` positionals inline a file's contents as")
    w("a user message (one message per file, in order); the remaining")
    w("positionals join into the prompt, and `/goal ...` directives enter")
    w("goal mode. Output is JSON by default (`--mode text` for prose);")
    w("errors are always `{\"err\":{...}}` envelopes on stderr.")
    w("")
    w("### Global flags")
    w("")
    w("Every flag the top-level parser accepts — the `flag_specs` table in")
    w("`src/main.zig`, also emitted machine-readably by `tau --help-json`.")
    w("")
    w("| Flag | Short | Argument | Description |")
    w("|------|-------|----------|-------------|")
    for f in main["flags"]:
        short = f"`{f['short']}`" if f["short"] else "—"
        arg = f"`{md_cell(f['arg'])}`" if f["arg"] else "—"
        w(f"| `{f['long']}` | {short} | {arg} | {md_cell(main['descs'][f['long']])} |")
    w("")
    w("### Goal-mode directives")
    w("")
    w("`/goal` commands run inside a prompt — the management verbs need")
    w("`--session`:")
    w("")
    w("| Directive | Effect |")
    w("|-----------|--------|")
    for cmd, effect in main["goals"]:
        w(f"| `{md_cell(cmd)}` | {md_cell(effect)} |")
    w("")
    w("### Exit codes")
    w("")
    w("The stable process-status contract — cause, remediation, and")
    w("recoverability per code/type in [docs/errors.md](errors.md), or")
    w("offline via `tau explain <code>`:")
    w("")
    w("| Code | Type |")
    w("|------|------|")
    for code, typ in main["exit_codes"]:
        w(f"| `{code}` | `{typ}` |")
    w("")
    w("### Examples")
    w("")
    w("```text")
    a.extend(main["examples"])
    w("```")
    w("")
    w("## Subcommands")
    w("")
    w("Every registered subcommand, in catalog order — the same order")
    w("`tau explain --list` indexes them under `subcommand.<name>`. Each")
    w("section embeds the exact `tau <name> --help` page followed by the")
    w("catalog's related links.")
    w("")
    w("| Subcommand | Summary |")
    w("|------------|---------|")
    for s in specs:
        anchor = f"#tau-{s['name']}"
        w(f"| [`tau {s['name']}`]({anchor}) | {md_cell(s['summary'])} |")
    w("")
    for name, help_text in entries:
        a.append(render_subcmd(spec_map[name], help_text))
    return "\n".join(a)


def main():
    check = "--check" in sys.argv[1:]
    urls = parse_version_urls(VERSION_ZIG.read_text(encoding="utf-8"))
    want = render(parse_main(MAIN_ZIG.read_text(encoding="utf-8")),
                  parse_subhelp(SUBHELP_ZIG.read_text(encoding="utf-8")),
                  parse_specs(SUBCAT_ZIG.read_text(encoding="utf-8"), urls))
    have = OUT_MD.read_text(encoding="utf-8") if OUT_MD.is_file() else None
    if have != want:
        if check:
            print("gen-cli-reference-doc: stale docs/cli-reference.md — "
                  "run scripts/gen-cli-reference-doc.py", file=sys.stderr)
            return 1
        OUT_MD.write_text(want, encoding="utf-8")
        print("gen-cli-reference-doc: regenerated docs/cli-reference.md")
    return 0


if __name__ == "__main__":
    sys.exit(main())
