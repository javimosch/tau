#!/usr/bin/env python3
"""Regenerate the `tau doctor` check table in docs/troubleshooting.md.

The CheckSpec catalog in src/doctorcatalog.zig — the same registry
`tau explain doctor.<check>` reads — is the single source of truth for the
check ids the `tau doctor` report can emit, when each one warns or fails,
and the remediation that resolves it. This script splices the rendered
table between the GENERATED DOCTOR CHECKS markers in
docs/troubleshooting.md so the doc cannot drift:

    python3 scripts/gen-doctor-checks-doc.py            # rewrite the region
    python3 scripts/gen-doctor-checks-doc.py --check    # exit 1 if stale

Static rows come from the `static_specs` array; the dynamic families are
rebuilt from src/setup.zig (`client_<name>` per ClientKind, via the
clientName switch and doctor.zig's hyphen->underscore check-id rule) and
src/llm/provider.zig (`probe_<provider>`/`probe_<provider>_auth` per
registered provider). Stdlib only. Paths resolve relative to the script,
so it can run from any cwd. The doctor-checks smoke group runs --check;
zig build test separately asserts every catalog row appears verbatim in
the doc.
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DOCTORCAT_ZIG = ROOT / "src" / "doctorcatalog.zig"
SETUP_ZIG = ROOT / "src" / "setup.zig"
PROVIDER_ZIG = ROOT / "src" / "llm" / "provider.zig"
OUT_MD = ROOT / "docs" / "troubleshooting.md"

BEGIN = "<!-- BEGIN GENERATED DOCTOR CHECKS"
END = "<!-- END GENERATED DOCTOR CHECKS -->"

HEADER = """<!-- BEGIN GENERATED DOCTOR CHECKS — do not edit between the markers.
     Source of truth: the CheckSpec catalog in src/doctorcatalog.zig —
     the same registry `tau explain doctor.<check>` reads.
     Regenerate:  python3 scripts/gen-doctor-checks-doc.py
     Drift check: python3 scripts/gen-doctor-checks-doc.py --check
     (the doctor-checks smoke group runs the drift check) -->"""


def fail(msg):
    print(f"gen-doctor-checks-doc: {msg}", file=sys.stderr)
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


def parse_static_specs(src):
    """Rows of `pub const static_specs = [_]CheckSpec{ ... };`."""
    m = re.search(r"pub const static_specs = \[_\]CheckSpec\{(.*?)\n\};",
                  src, re.S)
    if not m:
        fail("could not find `pub const static_specs = [_]CheckSpec{...}` "
             "in src/doctorcatalog.zig")
    entry = re.compile(
        r"\.\{\s*\.name\s*=\s*" + STRING + r","
        r"\s*\.fails_when\s*=\s*" + STRING + r","
        r"\s*\.remediation\s*=\s*" + STRING)
    rows = [{"name": zig_unescape(m.group(1)),
             "fails_when": zig_unescape(m.group(2)),
             "remediation": zig_unescape(m.group(3))}
            for m in entry.finditer(m.group(1))]
    if not rows:
        fail("static_specs parsed empty in src/doctorcatalog.zig")
    return rows


def parse_const(src, name):
    """`pub const <name> = "...";` -> decoded string."""
    m = re.search(r"pub const %s = %s;" % (re.escape(name), STRING), src)
    if not m:
        fail(f"could not find `pub const {name}` in src/doctorcatalog.zig")
    return zig_unescape(m.group(1))


def parse_clients(src):
    """[(enum_member, display_name)] in all_clients order."""
    m = re.search(r"pub const all_clients = \[_\]ClientKind\{([^}]*)\};",
                  src)
    if not m:
        fail("could not find `pub const all_clients` in src/setup.zig")
    order = re.findall(r"\.(\w+)", m.group(1))
    if not order:
        fail("all_clients parsed empty in src/setup.zig")

    start = src.find("pub fn clientName")
    end = src.find("pub fn parseClientName")
    if start < 0 or end < 0:
        fail("could not bound `fn clientName` in src/setup.zig")
    names = dict(re.findall(r"\.(\w+)\s*=>\s*" + STRING,
                            src[start:end]))
    missing = [k for k in order if k not in names]
    if missing:
        fail(f"clientName switch missing members: {missing}")
    return [(k, zig_unescape(names[k])) for k in order]


def parse_providers(src):
    """Provider names in `pub const providers` order."""
    m = re.search(r"pub const providers = \[_\]Provider\{(.*?)\n\};",
                  src, re.S)
    if not m:
        fail("could not find `pub const providers` in src/llm/provider.zig")
    names = [zig_unescape(n)
             for n in re.findall(r"\.name\s*=\s*" + STRING, m.group(1))]
    if not names:
        fail("providers parsed empty in src/llm/provider.zig")
    return names


def guide_file(display):
    """docs/clients/<file>.md — mirrors guideFile() in doctorcatalog.zig."""
    return "gemini-cli" if display == "gemini" else display


def check_rows():
    """The full ordered row list the generated table renders."""
    dc = DOCTORCAT_ZIG.read_text(encoding="utf-8")
    rows = parse_static_specs(dc)

    client_fw = parse_const(dc, "client_fails_when")
    client_rem = parse_const(dc, "client_remediation_tmpl")
    probe_fw = parse_const(dc, "probe_fails_when")
    probe_rem = parse_const(dc, "probe_remediation")
    pa_fw = parse_const(dc, "probe_auth_fails_when")
    pa_rem = parse_const(dc, "probe_auth_remediation_tmpl")

    for _, display in parse_clients(SETUP_ZIG.read_text(encoding="utf-8")):
        rows.append({
            "name": "client_" + display.replace("-", "_"),
            "fails_when": client_fw,
            "remediation": client_rem.replace("{s}", display, 1)
                                     .replace("{s}", guide_file(display), 1),
        })
    for pname in parse_providers(PROVIDER_ZIG.read_text(encoding="utf-8")):
        rows.append({"name": "probe_" + pname,
                     "fails_when": probe_fw,
                     "remediation": probe_rem})
        rows.append({"name": "probe_" + pname + "_auth",
                     "fails_when": pa_fw,
                     "remediation": pa_rem.replace("{s}", pname)})
    return rows


def md_cell(text):
    return text.replace("|", "\\|")


def render_region(rows):
    """The marked region, markers included."""
    lines = [HEADER, ""]
    a = lines.append
    a("| Check | Fails or warns when | Remediate |")
    a("|-------|---------------------|-----------|")
    for r in rows:
        a(f"| `{r['name']}` | {md_cell(r['fails_when'])} "
          f"| {md_cell(r['remediation'])} |")
    a("")
    a(END)
    return "\n".join(lines)


def splice(doc_text, region):
    begin = doc_text.find(BEGIN)
    end = doc_text.find(END)
    if begin < 0 or end < 0:
        fail(f"GENERATED DOCTOR CHECKS markers not found in {OUT_MD} — "
             "wrap the check table in `<!-- BEGIN GENERATED DOCTOR CHECKS"
             " -->` / `<!-- END GENERATED DOCTOR CHECKS -->`")
    return doc_text[:begin] + region + doc_text[end + len(END):]


def main():
    check = "--check" in sys.argv[1:]
    if not OUT_MD.is_file():
        fail(f"{OUT_MD} not found")
    doc = OUT_MD.read_text(encoding="utf-8")
    want = splice(doc, render_region(check_rows()))
    if want == doc:
        return 0
    if check:
        print("gen-doctor-checks-doc: docs/troubleshooting.md is stale — "
              "run scripts/gen-doctor-checks-doc.py", file=sys.stderr)
        return 1
    OUT_MD.write_text(want, encoding="utf-8")
    print("gen-doctor-checks-doc: regenerated the check table in "
          "docs/troubleshooting.md")
    return 0


if __name__ == "__main__":
    sys.exit(main())
