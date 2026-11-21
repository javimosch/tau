#!/usr/bin/env python3
"""Regenerate docs/clients.md from the client registries.

The ClientKind tables in src/setup.zig (clientName, parseClientName,
clientSettingsPath, clientConfigDir, clientNextStep, snippetPath,
clientUsesBridge, mcacpConfigPath) plus the catalog-owned data in
src/clientcatalog.zig (prereqs, mergeTarget, clientAliases, manualLabel,
nativePaths — the same registry `tau explain client.<id>` reads) are the
single source of truth for which editors `tau setup --client` can wire,
the paths setup touches, and each client's native per-OS config
locations. Doctor check/fix ids come from src/doctor.zig
(clientCheckName, clientFixKind). This script renders the per-client
catalog so the doc cannot drift:

    python3 scripts/gen-clients-doc.py            # rewrite docs/clients.md
    python3 scripts/gen-clients-doc.py --check    # exit 1 if stale

Every section is the exact byte shape clientSectionMarkdown in
src/clientcatalog.zig renders — the doc-mirror zig test pins each
section verbatim, and the cross-checks below keep clientcatalog's own
tables in sync with setup.zig's parseClientName/clientSettingsPath.

Stdlib only. Paths resolve relative to the script, so it can run from
any cwd. The clients-doc smoke group runs --check.
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SETUP_ZIG = ROOT / "src" / "setup.zig"
DOCTOR_ZIG = ROOT / "src" / "doctor.zig"
CLIENTCAT_ZIG = ROOT / "src" / "clientcatalog.zig"
OUT_MD = ROOT / "docs" / "clients.md"


def fail(msg):
    print(f"gen-clients-doc: {msg}", file=sys.stderr)
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


def fn_body(src, clean, name, path):
    """Return (raw, clean) body text of `fn name(`/`pub fn name(` via brace
    matching on the stripped copy."""
    m = re.search(r"(?:pub )?fn %s\(" % re.escape(name), clean)
    if not m:
        fail(f"could not find `fn {name}` in {path}")
    i = clean.index("{", m.end())
    depth = 0
    for j in range(i, len(clean)):
        if clean[j] == "{":
            depth += 1
        elif clean[j] == "}":
            depth -= 1
            if depth == 0:
                return src[i + 1:j], clean[i + 1:j]
    fail(f"unbalanced braces in `fn {name}` ({path})")


def switch_arms(body_raw, body_clean, fname):
    """Map enum member -> raw RHS text for `.a, .b => RHS,` switch arms."""
    arms = {}
    starts = [(m.start(), m.group(1)) for m in
              re.finditer(r"((?:\.\w+\s*(?:,\s*)?)+)=>\s*", body_clean)]
    for idx, (pos, lhs) in enumerate(starts):
        rhs = body_clean[pos:starts[idx + 1][0] if idx + 1 < len(starts)
                         else len(body_clean)]
        members = re.findall(r"\.(\w+)", lhs)
        for member in members:
            arms[member] = body_raw[pos:pos + len(rhs)]
    if not arms:
        fail(f"no switch arms found in `{fname}`")
    return arms


def arm_value(raw):
    """Interpret one switch-arm RHS: literal, allocPrint template, null, or
    unreachable."""
    m = re.match(r"[^=]*=>\s*(.*)", raw, re.S)
    rhs = m.group(1)
    if re.match(r"\s*null\b", rhs):
        return None
    if re.match(r"\s*unreachable\b", rhs):
        return "unreachable"
    m = re.search(r'allocPrint\(arena,\s*"((?:[^"\\]|\\.)*)"', rhs)
    if m:
        return zig_unescape(m.group(1))
    m = re.match(r'\s*"((?:[^"\\]|\\.)*)"', rhs)
    if m:
        return zig_unescape(m.group(1))
    fail(f"unrecognized switch-arm RHS: {rhs[:80]!r}")


def home_path(template):
    """'{s}/.config/zed' -> '~/.config/zed'"""
    return template.replace("{s}", "~")


def parse_setup(src):
    clean = zig_stripped(src)

    m = re.search(r"pub const ClientKind = enum\s*\{([^}]*)\}", clean)
    if not m:
        fail("could not find `pub const ClientKind = enum` in src/setup.zig")
    members = [w for w in re.findall(r"\b(\w+)\b", m.group(1))]
    if not members:
        fail("ClientKind enum parsed empty")

    clients = {k: {} for k in members}

    raw, cln = fn_body(src, clean, "clientName", "src/setup.zig")
    for k, arm in switch_arms(raw, cln, "clientName").items():
        clients.setdefault(k, {})["display"] = arm_value(arm)

    raw, _ = fn_body(src, clean, "parseClientName", "src/setup.zig")
    for stmt in raw.split(";"):
        rm = re.search(r"return \.(\w+)", stmt)
        if not rm:
            continue
        names = re.findall(r'std\.mem\.eql\(u8, name, "([^"]+)"\)', stmt)
        clients.setdefault(rm.group(1), {})["cli_names"] = names

    for fname, key in (("clientSettingsPath", "settings"),
                       ("clientConfigDir", "config_dir"),
                       ("clientNextStep", "next_step")):
        raw, cln = fn_body(src, clean, fname, "src/setup.zig")
        for k, arm in switch_arms(raw, cln, fname).items():
            v = arm_value(arm)
            if v == "unreachable":
                continue
            clients.setdefault(k, {})[key] = home_path(v) if v else v

    # snippetPath: per-member ext switch arms + path template.
    raw, _ = fn_body(src, clean, "snippetPath", "src/setup.zig")
    exts = dict(re.findall(r"\.(\w+)\s*=>\s*\"(\w+)\"", raw))
    m = re.search(r'else\s*=>\s*"(\w+)"', raw)
    if not m or not exts:
        fail("could not parse snippet extension rule in snippetPath")
    def_ext = m.group(1)
    m = re.search(r'allocPrint\(arena,\s*"((?:[^"\\]|\\.)*)"', raw)
    if not m:
        fail("could not find snippet path template in snippetPath")
    tmpl = m.group(1)
    for k, c in clients.items():
        ext = exts.get(k, def_ext)
        c["snippet"] = tmpl.replace("{s}", "~", 1).replace(
            "{s}", c.get("display", k), 1).replace("{s}", ext, 1)

    # clientUsesBridge: `.a, .b, .c => true,` — MCP-bridge clients.
    raw, cln = fn_body(src, clean, "clientUsesBridge", "src/setup.zig")
    for k, arm in switch_arms(raw, cln, "clientUsesBridge").items():
        rhs = arm.split("=>", 1)[1].strip()
        clients.setdefault(k, {})["bridge"] = rhs.startswith("true")

    # mcacpConfigPath: single allocPrint template (shared bridge config).
    raw, _ = fn_body(src, clean, "mcacpConfigPath", "src/setup.zig")
    m = re.search(r'allocPrint\(arena,\s*"((?:[^"\\]|\\.)*)"', raw)
    if not m:
        fail("could not find the mcacp path template in mcacpConfigPath")
    bridge = home_path(zig_unescape(m.group(1)))
    for c in clients.values():
        c["bridge_path"] = bridge

    return members, clients


def parse_doctor(src):
    """Per-client fix kinds from doctor.zig's clientFixKind."""
    raw, _ = fn_body(src, zig_stripped(src), "clientFixKind", "src/doctor.zig")
    fixes = {}
    for lhs, v in re.findall(r"((?:\.\w+\s*(?:,\s*)?)+)=>\s*(\.?\w+|null)", raw):
        for k in re.findall(r"\.(\w+)", lhs):
            fixes[k] = None if v == "null" else v.lstrip(".")
    return fixes


def parse_const(src, name, path):
    m = re.search(r"(?:pub )?const %s = %s;" % (re.escape(name), STRING),
                  src)
    if not m:
        fail(f"could not find `const {name}` in {path}")
    return zig_unescape(m.group(1))


def parse_clientcatalog(src):
    """The catalog-owned per-client data in src/clientcatalog.zig."""
    clean = zig_stripped(src)
    cat = {}

    tau_ready = parse_const(src, "tau_ready", "src/clientcatalog.zig")

    # bridgePrereq(who): `return tau_ready ++ "A" ++ who ++ "B";`
    raw, _ = fn_body(src, clean, "bridgePrereq", "src/clientcatalog.zig")
    m = re.search(r"return\s+tau_ready\s*\+\+\s*" + STRING +
                  r"\s*\+\+\s*who\s*\+\+\s*" + STRING, raw)
    if not m:
        fail("could not parse bridgePrereq template in clientcatalog.zig")
    bridge_a, bridge_b = zig_unescape(m.group(1)), zig_unescape(m.group(2))

    def eval_prereq(arm):
        rhs = arm.split("=>", 1)[1].strip().rstrip(";}").strip().rstrip(",")
        if rhs == "tau_ready":
            return tau_ready
        m = re.match(STRING + r"\s*\+\+\s*tau_ready$", rhs)
        if m:
            return zig_unescape(m.group(1)) + tau_ready
        m = re.match(r"comptime\s+bridgePrereq\(" + STRING + r"\)$", rhs)
        if m:
            who = zig_unescape(m.group(1))
            return tau_ready + bridge_a + who + bridge_b
        fail(f"unrecognized prereqs arm: {rhs[:80]!r}")

    raw, cln = fn_body(src, clean, "prereqs", "src/clientcatalog.zig")
    for k, arm in switch_arms(raw, cln, "prereqs").items():
        cat.setdefault(k, {})["prereqs"] = eval_prereq(arm)

    for fname, key in (("mergeTarget", "merge_target"),
                       ("manualLabel", "manual_label")):
        raw, cln = fn_body(src, clean, fname, "src/clientcatalog.zig")
        for k, arm in switch_arms(raw, cln, fname).items():
            v = arm_value(arm)
            if v != "unreachable":
                cat.setdefault(k, {})[key] = v

    # nativePaths: `.a => .{ .linux = "x", .macos = "y", .windows = "z" },`
    raw, cln = fn_body(src, clean, "nativePaths", "src/clientcatalog.zig")
    nat_re = re.compile(
        r"\.linux\s*=\s*" + STRING + r"\s*,\s*"
        r"\.macos\s*=\s*" + STRING + r"\s*,\s*"
        r"\.windows\s*=\s*" + STRING)
    for k, arm in switch_arms(raw, cln, "nativePaths").items():
        m = nat_re.search(arm)
        if not m:
            fail(f"could not parse nativePaths arm for .{k}")
        cat.setdefault(k, {})["native"] = tuple(
            zig_unescape(g) for g in m.groups())

    # clientAliases: `.a => &.{"x", "y"},` — member arms only; the `else`
    # arm contributes nothing.
    raw, cln = fn_body(src, clean, "clientAliases", "src/clientcatalog.zig")
    for k, arm in switch_arms(raw, cln, "clientAliases").items():
        m = re.search(r"&\.\{(.*?)\}", arm, re.S)
        if not m:
            fail(f"could not parse clientAliases arm for .{k}")
        cat.setdefault(k, {})["aliases"] = [
            zig_unescape(s) for s in re.findall(STRING, m.group(1))]

    return cat


def guide_file(display):
    """docs/clients/<file>.md — mirrors guideFile() in doctorcatalog.zig."""
    return "gemini-cli" if display == "gemini" else display


def check_name(display):
    """`client_<name>` — mirrors clientCheckName in doctor.zig."""
    return "client_" + display.replace("-", "_")


def catalog():
    """Ordered per-client entries, all sources merged and cross-checked."""
    members, clients = parse_setup(SETUP_ZIG.read_text(encoding="utf-8"))
    fixes = parse_doctor(DOCTOR_ZIG.read_text(encoding="utf-8"))
    cat = parse_clientcatalog(CLIENTCAT_ZIG.read_text(encoding="utf-8"))

    rows = []
    for k in members:
        c = clients[k]
        cc = cat.get(k, {})
        display = c["display"]

        if "prereqs" not in cc or "native" not in cc:
            fail(f"clientcatalog.zig is missing prereqs/nativePaths for .{k}")

        # The alias table must equal parseClientName's extra spellings.
        aliases = cc.get("aliases", [])
        extra = c["cli_names"][1:]
        if c["cli_names"][0] != display:
            fail(f"parseClientName's first spelling for .{k} is not "
                 f"clientName '{display}'")
        if aliases != extra:
            fail(f"clientAliases(.{k}) {aliases} does not match "
                 f"parseClientName's extra spellings {extra}")

        snippet = c["settings"] is None
        if snippet and ("merge_target" not in cc or "manual_label" not in cc):
            fail(f"clientcatalog.zig is missing mergeTarget/manualLabel "
                 f"for snippet client .{k}")
        if not snippet and ("merge_target" in cc or "manual_label" in cc):
            fail(f"clientcatalog.zig has mergeTarget/manualLabel for "
                 f"direct client .{k}")

        rows.append({
            "name": display,
            "aliases": aliases,
            "setup_cmd": f"tau setup --client {display} --yes",
            "transport": "mcacp" if c.get("bridge") else "acp",
            "wiring": "snippet" if snippet else "direct",
            "prereqs": cc["prereqs"],
            "settings_path": cc["merge_target"] if snippet else c["settings"],
            "config_dir": c["config_dir"],
            "snippet_path": c["snippet"],
            "bridge_path": c["bridge_path"] if c.get("bridge") else None,
            "native": cc["native"],
            "check": check_name(display),
            "fix": fixes.get(k),
            "manual_label": cc.get("manual_label"),
            "guide": guide_file(display),
            "next_step": c["next_step"],
        })
    return rows


def render_section(r):
    """One client section — byte-identical to clientSectionMarkdown in
    src/clientcatalog.zig (the doc-mirror test pins that)."""
    lines = [f"### `{r['name']}`", ""]
    a = lines.append
    cli = f"- **`--client`:** `{r['name']}`"
    if r["aliases"]:
        word = "alias" if len(r["aliases"]) == 1 else "aliases"
        cli += f" ({word} " + ", ".join(f"`{x}`" for x in r["aliases"]) + ")"
    a(cli + f" — `{r['setup_cmd']}`")

    if r["transport"] == "mcacp":
        transport = ("the editor speaks MCP, not ACP; its server entry "
                     "launches the `npx -y mcacp` bridge")
    else:
        transport = "the editor spawns `tau acp serve` itself"
    if r["wiring"] == "direct":
        wiring = ("setup splices the settings file (an existing file is "
                  "never rewritten — a paste-ready snippet drops instead)")
    else:
        wiring = (f"setup can't splice the {r['manual_label']} config; it "
                  "always drops a paste-ready snippet to merge by hand")
    a(f"- **Transport / wiring:** `{r['transport']}` — {transport} · "
      f"`{r['wiring']}` — {wiring}")

    a(f"- **Prerequisites:** {r['prereqs']}")

    kind = "settings" if r["wiring"] == "direct" else "merge target"
    paths = (f"- **Paths:** {kind} `{r['settings_path']}` · detection dir "
             f"`{r['config_dir']}` · snippet `{r['snippet_path']}`")
    if r["bridge_path"]:
        paths += f" · bridge `{r['bridge_path']}`"
    a(paths)

    linux, macos, windows = r["native"]
    a(f"- **Native locations:** Linux `{linux}` · macOS `{macos}` · "
      f"Windows `{windows}`")

    if r["fix"]:
        fix = f"`tau doctor --fix` runs `{r['fix']}`"
    else:
        fix = (f"manual only — `tau doctor` can't verify the "
               f"{r['manual_label']} config; `{r['setup_cmd']}` "
               "(re)generates the snippet")
    a(f"- **Wiring check:** `{r['check']}` — reported once "
      f"`{r['config_dir']}` exists; {fix} "
      f"(`tau explain doctor.{r['check']}`)")

    a(f"- **Explain:** `tau explain client.{r['name']}`")
    a(f"- **Guide:** [docs/clients/{r['guide']}.md](clients/{r['guide']}.md)")
    a(f"- **Finish in the editor:** {r['next_step']}")
    return "\n".join(lines) + "\n"


def render(rows):
    a = []
    w = a.append
    w("# `tau setup --client` catalog")
    w("")
    w("<!-- GENERATED FILE — do not edit by hand.")
    w("     Source of truth: the ClientKind tables in src/setup.zig and the")
    w("     client catalog in src/clientcatalog.zig — the same registry")
    w("     `tau explain client.<id>` reads; doctor check/fix ids from")
    w("     src/doctor.zig.")
    w("     Regenerate:  python3 scripts/gen-clients-doc.py")
    w("     Drift check: python3 scripts/gen-clients-doc.py --check")
    w("     (the clients-doc smoke group runs the drift check) -->")
    w("")
    w("`tau setup --client <id>` wires `tau acp serve` into an editor")
    w("client's config — the same wiring `tau explain client.<id>` prints")
    w("offline as JSON (`--human` renders prose). This page catalogs every")
    w("supported `--client` id: accepted spellings, transport and wiring")
    w("kind, prerequisites, the paths setup touches, each client's native")
    w("per-OS config locations, the `tau doctor` check row that verifies")
    w("the wiring, and the per-client guide.")
    w("")
    w("`~` is `$HOME` on Linux/macOS and `%USERPROFILE%` on Windows — setup")
    w("writes the `~` form of every path on every OS (clients that honor")
    w("`$XDG_CONFIG_HOME` override the Linux/macOS prefix accordingly); the")
    w("**Native locations** line lists where each client itself resolves")
    w("the file per OS. Detection — `tau doctor`, or `tau setup --detect`")
    w("for the read-only inventory — only *reports* clients whose")
    w("detection dir exists and never writes. `--client all` expands to")
    w("every section below.")
    w("")
    w("The one-table summary of the same registry is")
    w("[docs/compatibility.md](compatibility.md); every wiring check's")
    w("symptom/cause/fix is [docs/doctor.md](doctor.md); and each linked")
    w("guide carries the exact config snippets `tau setup` writes,")
    w("verified byte-for-byte.")
    w("")
    w("## Clients")
    w("")
    for r in rows:
        a.append(render_section(r))
    return "\n".join(a)


def main():
    check = "--check" in sys.argv[1:]
    want = render(catalog())
    have = OUT_MD.read_text(encoding="utf-8") if OUT_MD.is_file() else None
    if have != want:
        if check:
            print("gen-clients-doc: stale docs/clients.md — run "
                  "scripts/gen-clients-doc.py", file=sys.stderr)
            return 1
        OUT_MD.write_text(want, encoding="utf-8")
        print("gen-clients-doc: regenerated docs/clients.md")
    return 0


if __name__ == "__main__":
    sys.exit(main())
