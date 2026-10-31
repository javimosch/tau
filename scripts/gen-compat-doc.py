#!/usr/bin/env python3
"""Regenerate docs/compatibility.md from the client registry in src/setup.zig.

The ClientKind enum and its per-client tables (clientName, parseClientName,
clientSettingsPath, clientConfigDir, clientSectionKey, clientNextStep,
snippetPath, renderClientJson, inspectClientWiring) in src/setup.zig are the
single source of truth for which editors `tau setup --client` can wire to
`tau acp serve`, where each one's config lives, and what shape it takes.
The doctor-side pieces come from src/doctor.zig (clientCheckName,
clientFixKind); the version rows derive from src/version.zig and
CHANGELOG.md (the release that shipped `tau acp serve`). This script renders
the human-readable matrix so the doc cannot drift:

    python3 scripts/gen-compat-doc.py            # rewrite docs/compatibility.md
    python3 scripts/gen-compat-doc.py --check    # exit 1 if the doc is stale

Stdlib only. Paths resolve relative to the script, so it can run from any
cwd. The compat-doc smoke group runs --check; zig build test separately
asserts the matrix rows, settings paths, and section keys appear verbatim in
docs/compatibility.md.
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SETUP_ZIG = ROOT / "src" / "setup.zig"
DOCTOR_ZIG = ROOT / "src" / "doctor.zig"
VERSION_ZIG = ROOT / "src" / "version.zig"
CHANGELOG = ROOT / "CHANGELOG.md"
OUT_MD = ROOT / "docs" / "compatibility.md"


def fail(msg):
    print(f"gen-compat-doc: {msg}", file=sys.stderr)
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
            # Multiline string literal: `\\` at line start (mod whitespace)
            # swallows the rest of the line.
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

    # clientName: .zed => "zed", ...
    raw, cln = fn_body(src, clean, "clientName", "src/setup.zig")
    for k, arm in switch_arms(raw, cln, "clientName").items():
        clients.setdefault(k, {})["display"] = arm_value(arm)

    # parseClientName: statements 'if (eqls...) return .member;' — collect
    # every std.mem.eql(u8, name, "x") literal per member.
    raw, _ = fn_body(src, clean, "parseClientName", "src/setup.zig")
    for stmt in raw.split(";"):
        rm = re.search(r"return \.(\w+)", stmt)
        if not rm:
            continue
        names = re.findall(r'std\.mem\.eql\(u8, name, "([^"]+)"\)', stmt)
        clients.setdefault(rm.group(1), {})["cli_names"] = names

    for fname, key, pathify in (
        ("clientSettingsPath", "settings", True),
        ("clientConfigDir", "config_dir", True),
        ("clientSectionKey", "section", False),
        ("clientNextStep", "next_step", False),
    ):
        raw, cln = fn_body(src, clean, fname, "src/setup.zig")
        for k, arm in switch_arms(raw, cln, fname).items():
            v = arm_value(arm)
            if v == "unreachable":
                continue
            clients.setdefault(k, {})[key] = home_path(v) if (v and pathify) else v

    # snippetPath: ext rule + path template.
    raw, _ = fn_body(src, clean, "snippetPath", "src/setup.zig")
    m = re.search(r'if \(k == \.(\w+)\) "(\w+)" else "(\w+)"', raw)
    if not m:
        fail("could not parse snippet extension rule in snippetPath")
    odd, odd_ext, def_ext = m.group(1), m.group(2), m.group(3)
    m = re.search(r'allocPrint\(arena,\s*"((?:[^"\\]|\\.)*)"', raw)
    if not m:
        fail("could not find snippet path template in snippetPath")
    tmpl = m.group(1)  # "{s}/.config/tau/snippets/{s}.{s}"
    for k, c in clients.items():
        ext = odd_ext if k == odd else def_ext
        c["snippet"] = tmpl.replace("{s}", "~", 1).replace(
            "{s}", c.get("display", k), 1).replace("{s}", ext, 1)

    # renderClientJson: per-member chunk — does the minimal entry carry
    # "type": "custom"? Does it pin args to ["acp", "serve"]?
    raw, cln = fn_body(src, clean, "renderClientJson", "src/setup.zig")
    for k, arm in switch_arms(raw, cln, "renderClientJson").items():
        if "unreachable" in arm[:60]:
            continue
        clients.setdefault(k, {})["needs_type_custom"] = '"type": "custom"' in arm
        clients[k]["acp_serve_args"] = '"args": ["acp", "serve"]' in arm

    # clientUsesBridge: `.a, .b, .c => true,` — MCP-bridge clients.
    raw, cln = fn_body(src, clean, "clientUsesBridge", "src/setup.zig")
    for k, arm in switch_arms(raw, cln, "clientUsesBridge").items():
        rhs = arm.split("=>", 1)[1].strip()
        clients.setdefault(k, {})["bridge"] = rhs.startswith("true")

    # inspectClientWiring: `if (k == .X) return .{ .state = .manual_only }`.
    raw, _ = fn_body(src, clean, "inspectClientWiring", "src/setup.zig")
    for k, state in re.findall(
            r"if \(k == \.(\w+)\) return \.\{ \.state = \.(\w+) \}", raw):
        clients.setdefault(k, {})["doctor_state"] = state

    # resolveClients 'all' expansion must cover every enum member.
    raw, _ = fn_body(src, clean, "resolveClients", "src/setup.zig")
    m = re.search(r'appendSlice\(arena, &\.\{([^}]*)\}\)', raw)
    if not m:
        fail("could not find the `all` expansion in resolveClients")
    expanded = re.findall(r"\.(\w+)", m.group(1))
    if sorted(expanded) != sorted(members):
        fail(f"'all' expansion {expanded} does not cover ClientKind {members}")

    return members, clients


def parse_doctor(src):
    """client_<name> check prefix + per-client fix kinds from doctor.zig."""
    m = re.search(r'fn clientCheckName\(.*?"client_\{s\}"', src, re.S)
    if not m:
        fail("could not find clientCheckName in src/doctor.zig")
    raw, _ = fn_body(src, zig_stripped(src), "clientFixKind", "src/doctor.zig")
    fixes = {}
    for k, v in re.findall(r"\.(\w+) => (\.?\w+|null)", raw):
        fixes[k] = None if v == "null" else v.lstrip(".")
    return fixes


def parse_version(src):
    m = re.search(r'pub const version = "([^"]+)"', src)
    if not m:
        fail("could not find `pub const version` in src/version.zig")
    return m.group(1)


def acp_serve_since(changelog):
    """Earliest release section that mentions `tau acp serve`."""
    versions = []
    for m in re.finditer(r"## \[(\d+\.\d+\.\d+)\](.*?)(?=\n## \[|\Z)",
                         changelog, re.S):
        if "acp serve" in m.group(2):
            versions.append(tuple(int(x) for x in m.group(1).split(".")))
    if not versions:
        fail("no CHANGELOG section mentions `tau acp serve`")
    return ".".join(str(x) for x in min(versions))


def md_cell(text):
    return text.replace("|", "\\|")


def render(members, clients, fixes, version, acp_since):
    next_rel = f"unreleased (lands after {version})"
    lines = []
    a = lines.append
    a("# tau client compatibility matrix")
    a("")
    a("<!-- GENERATED FILE — do not edit by hand.")
    a("     Source of truth: the ClientKind registry and per-client tables in")
    a("     src/setup.zig (doctor check/fix ids from src/doctor.zig; version")
    a("     rows from src/version.zig + CHANGELOG.md).")
    a("     Regenerate:  python3 scripts/gen-compat-doc.py")
    a("     Drift check: python3 scripts/gen-compat-doc.py --check")
    a("     (the compat-doc smoke group runs the drift check) -->")
    a("")
    a("Which editors can drive `tau` as an ACP agent, where each one's config")
    a("lives, what shape the config takes, and which tau version each")
    a("integration path needs. Step-by-step guides:")
    a("[docs/editors.md](editors.md) and [docs/acp.md](acp.md), plus a")
    a("dedicated per-client guide for each MCP-bridge client:")
    a("[Windsurf](clients/windsurf.md), [Gemini CLI](clients/gemini-cli.md),")
    a("[Claude Desktop](clients/claude-desktop.md).")
    a("")
    a("## Supported editor clients")
    a("")
    a("| Client | `tau setup --client` | Config dir (detection) | Settings file | Agent-section key | Extra required field | Snippet fallback | `tau doctor` check / `--fix` |")
    a("|--------|----------------------|------------------------|---------------|-------------------|----------------------|------------------|----------------------------|")
    for k in members:
        c = clients[k]
        cli = f"`{c['cli_names'][0]}`" + "".join(
            f" (alias `{n}`)" for n in c["cli_names"][1:])
        settings = f"`{c['settings']}`" if c.get("settings") else "— (Lua plugin config)"
        section = f"`{c['section']}`" if c.get("section") else "—"
        if not c.get("settings"):
            extra = "—"
        else:
            extra = '`"type": "custom"`' if c.get("needs_type_custom") else "none"
        snippet = f"`{c['snippet']}`"
        if c.get("doctor_state") == "manual_only":
            doctor = f"`client_{k}` (manual only — Lua config)"
        else:
            fix = fixes.get(k)
            doctor = f"`client_{k}`" + (f" / `{fix}`" if fix else "")
        client_cell = f"`{k}`" + (" (mcacp)" if c.get("bridge") else "")
        a(f"| {client_cell} | {cli} | `{c['config_dir']}` | {settings} | {section} | {extra} | {snippet} | {doctor} |")
    a("")
    a("`tau setup --client all` expands to every row. Detection (setup with no")
    a("`--client`, or `tau doctor`) only *reports* clients whose config dir")
    a("exists — it never writes.")
    a("")
    a("## Config formats")
    a("")
    a("Every direct-ACP JSON client's `tau` entry spawns the same process —")
    a("the editor runs `command` + `args`, and `args` must be exactly")
    a("`[\"acp\", \"serve\"]` (anything else is flagged stale by `tau doctor`):")
    a("")
    a("```jsonc")
    a('"<agent-section key>": {')
    a('  "tau": {')
    a('    "command": "<path-to-tau>",')
    a('    "args": ["acp", "serve"],')
    a('    "env": {}')
    a("  }")
    a("}")
    a("```")
    a("")
    bridge_clients = [k for k in members if clients[k].get("bridge")]
    if bridge_clients:
        names = ", ".join(f"`{k}`" for k in bridge_clients)
        a("MCP-bridge clients (" + names + ") speak MCP, not ACP — they can't")
        a("spawn `tau acp serve` directly. Their `mcpServers` entry launches")
        a("the [mcacp](https://github.com/Oortonaut/mcacp) bridge instead:")
        a("")
        a("```jsonc")
        a('"mcpServers": {')
        a('  "mcacp": {')
        a('    "command": "npx",')
        a('    "args": ["-y", "mcacp"]')
        a("  }")
        a("}")
        a("```")
        a("")
        a("`tau setup --client` writes the matching bridge config too —")
        a("`~/.config/mcacp/mcacp.json` carries the real `agent_servers.tau`")
        a("entry in the direct-ACP shape above (one file, shared by every")
        a("bridge client; `tau doctor` checks both halves).")
        a("")
    a("| File | Format |")
    a("|------|--------|")
    a("| Client settings files (matrix above) | JSONC — `//` and `/* */` comments are tolerated and preserved: existing files are never rewritten, setup emits a paste-ready snippet instead |")
    if bridge_clients:
        a("| `~/.config/mcacp/mcacp.json` | JSONC — the mcacp MCP→ACP bridge's `agent_servers.tau` entry, shared by every bridge client |")
    a("| `~/.config/tau/snippets/*` | `.jsonc` fragment for JSON clients; `.lua` for Neovim (plugin adapters — e.g. avante.nvim, CodeCompanion.nvim) |")
    a("| `~/.config/tau/config.json` | JSONC — see [docs/config.md](config.md) and `schema/tau-config.schema.json` |")
    a("")
    a("## Required tau versions")
    a("")
    a("| Capability | Minimum tau |")
    a("|------------|-------------|")
    a(f"| `tau acp serve` — every client wiring spawns it | ≥ {acp_since} |")
    a(f"| `tau setup --client <name>` / `--client all` | {next_rel} |")
    a(f"| `tau setup --dry-run` | {next_rel} |")
    a(f"| `tau doctor` `client_*` wiring checks + `--fix` remediation | {next_rel} |")
    a("")
    a("Hand-editing a settings file only needs `tau acp serve`, so every client")
    a(f"in the matrix works on tau ≥ {acp_since}. The version-gated rows are the")
    a("automation: `setup --client` writes the entries for you, and `doctor`")
    a("verifies or repairs them.")
    a("")
    a("## In-editor finish")
    a("")
    a("After tau writes (or previews) the config, one in-editor step remains:")
    a("")
    a("| Client | Last step |")
    a("|--------|-----------|")
    for k in members:
        a(f"| `{k}` | {md_cell(clients[k]['next_step'])} |")
    a("")
    return "\n".join(lines)


def main():
    check = "--check" in sys.argv[1:]
    setup_src = SETUP_ZIG.read_text()
    members, clients = parse_setup(setup_src)
    for k in members:
        for key in ("display", "cli_names", "config_dir", "next_step",
                    "snippet"):
            if key not in clients[k] or clients[k][key] in (None, ""):
                fail(f"client '{k}' missing '{key}' — registry parse incomplete")
        if clients[k].get("settings"):
            if "section" not in clients[k]:
                fail(f"client '{k}' has a settings file but no section key")
            if not clients[k].get("bridge") and not clients[k].get("acp_serve_args"):
                fail(f"client '{k}' minimal entry doesn't pin args [\"acp\", \"serve\"]")
    fixes = parse_doctor(DOCTOR_ZIG.read_text())
    version = parse_version(VERSION_ZIG.read_text())
    since = acp_serve_since(CHANGELOG.read_text())
    doc = render(members, clients, fixes, version, since)

    if check:
        if not OUT_MD.exists():
            fail(f"{OUT_MD} does not exist — run scripts/gen-compat-doc.py")
        current = OUT_MD.read_text()
        if current != doc:
            fail("docs/compatibility.md is stale — regenerate with"
                 " scripts/gen-compat-doc.py")
        print("docs/compatibility.md is up to date")
        return
    OUT_MD.write_text(doc)
    print(f"wrote {OUT_MD}")


if __name__ == "__main__":
    main()
