#!/usr/bin/env python3
"""Validate `tau setup --client` artifacts against per-client config schemas.

The client-guides smoke group already byte-pins the docs' snippets to setup's
output; this checker pins setup's output to the *clients'* documented config
formats — the contract that matters to the editor reading the file. Every
artifact `tau setup --client <name>` produces is validated:

  - settings files written fresh (~/.config/zed/settings.json,
    claude_desktop_config.json, opencode.json, ...) — parsed and validated
    against tests/client-schemas/<client>.schema.json, which encodes the
    vendor-documented section shape plus the wiring tau promises (the
    agent/server entry name, the `acp serve` args or the `npx -y mcacp`
    bridge spawn line)
  - ~/.config/mcacp/mcacp.json for MCP-bridge clients — validated against
    tests/client-schemas/mcacp.schema.json
  - paste-ready snippets (~/.config/tau/snippets/*) emitted when the real
    settings file already exists — jsonc fragments are comment-stripped,
    wrapped in braces, and validated against the same client schema;
    non-JSON artifacts (nvim lua, emacs elisp, goose/continue yaml, codex
    toml) are checked against the structural contracts below
  - codex.toml is additionally parsed with tomllib when available

Client coverage is not hardcoded alone: the ClientKind enum and the
clientName() table in src/setup.zig are scraped for the authoritative
client-name set, so adding a client without a contract fails here.

Run by the client-contracts smoke group; also usable standalone:

    python3 scripts/check-client-contracts.py --tau zig-out/bin/tau
"""

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCHEMA_DIR = ROOT / "tests" / "client-schemas"
SETUP_ZIG = ROOT / "src" / "setup.zig"

sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))
from jsonschema_lite import validate  # noqa: E402

try:
    import tomllib
except ImportError:  # Python < 3.11 — structural fallback below
    tomllib = None

# client -> settings-file schema basename (None for snippet-only clients
# whose real config setup never writes: nvim lua, emacs elisp, and the
# YAML/TOML MCP configs of goose/continue/codex).
CLIENT_SCHEMAS = {
    "zed": "zed",
    "vscode": "vscode",
    "cursor": "cursor",
    "jetbrains": "jetbrains",
    "windsurf": "windsurf",
    "gemini": "gemini",
    "claude-desktop": "claude-desktop",
    "opencode": "opencode",
    "cline": "cline",
    "roo-code": "roo-code",
    "kilo-code": "kilo-code",
    "amazonq": "amazonq",
    "nvim": None,
    "emacs": None,
    "goose": None,
    "continue": None,
    "codex": None,
}

# Clients wired through the shared mcacp MCP->ACP bridge — their settings
# entry spawns `npx -y mcacp` and the bridge config carries the tau entry.
BRIDGE_CLIENTS = frozenset(("windsurf", "gemini", "claude-desktop",
                            "opencode", "cline", "roo-code", "kilo-code",
                            "amazonq", "goose", "continue", "codex"))

# Bridge clients whose config format setup can't splice — setup always
# reports "manual" and drops a paste-ready snippet in the client's own
# format. They still get the shared mcacp.json wired.
MANUAL_BRIDGE = frozenset(("goose", "continue", "codex"))

# Clients with no settings file at all — always "manual", snippet only.
SNIPPET_ONLY = frozenset(("nvim", "emacs"))

# Structural contracts for artifacts no JSON schema can check: ordered
# regexes each snippet must match top-to-bottom (re.search per entry, in
# order). These pin the vendor-documented keys the pasted block needs.
STRUCTURAL = {
    "nvim": [
        r'command = "[^"]+"',                       # avante acp_providers.tau
        r'args = \{\s*"acp", "serve"\s*\}',
        r'type = "acp"',                            # CodeCompanion adapter
        r'default = \{\s*"[^"]+", "acp", "serve"',  # CodeCompanion commands
        r'protocolVersion = 1',
    ],
    "emacs": [
        r"agent-shell-make-agent-config",
        r":identifier 'tau",
        r':command "[^"]+"',
        r':command-params \'?\("acp" "serve"\)',
    ],
    "goose": [
        r"^extensions:",
        r"^\s+mcacp:",
        r"^\s+type: stdio",
        r"^\s+name: mcacp",
        r"^\s+enabled: true",
        r"^\s+cmd: npx",
        r'^\s+args: \["-y", "mcacp"\]',
        r"^\s+timeout: 300",
    ],
    "continue": [
        r"^mcpServers:",
        r"^\s+- name: mcacp",
        r"^\s+command: npx",
        r"^\s+args:",
        r'^\s+- "-y"',
        r'^\s+- "mcacp"',
    ],
}

# Provider key env vars scrubbed so setup always seeds xiaomi from
# XIAOMI_API_KEY — same recipe as the client-guides checker.
SCRUB = ("OPENAI_API_KEY", "DEEPSEEK_API_KEY", "OPENCODE_API_KEY",
         "TAU_API_KEY", "PIZIG_API_KEY", "TAU_ENDPOINT")


def fail(msg):
    print(f"check-client-contracts: {msg}", file=sys.stderr)
    sys.exit(1)


def run_setup(tau, client, home):
    env = {k: v for k, v in os.environ.items() if k not in SCRUB}
    env.update({"HOME": home, "SHELL": "/bin/bash",
                "XIAOMI_API_KEY": "smoke-key"})
    proc = subprocess.run(
        [tau, "setup", "--offline", "--client", client, "--yes"],
        env=env, capture_output=True, text=True)
    if proc.returncode != 0:
        fail(f"`tau setup --client {client}` exited {proc.returncode}\n"
             f"{proc.stdout}{proc.stderr}")
    for line in proc.stdout.splitlines():
        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            continue
        if obj.get("step") == "clients":
            return obj
    fail(f"`tau setup --client {client}` emitted no clients step")


def strip_jsonc(text):
    """Remove // and /* */ comments outside string literals (mirrors
    configfile.stripComments in src/configfile.zig)."""
    out = []
    i, n = 0, len(text)
    in_str = False
    while i < n:
        c = text[i]
        if in_str:
            out.append(c)
            if c == "\\" and i + 1 < n:
                out.append(text[i + 1])
                i += 2
                continue
            if c == '"':
                in_str = False
            i += 1
            continue
        if c == '"':
            in_str = True
            out.append(c)
            i += 1
            continue
        if c == "/" and i + 1 < n and text[i + 1] == "/":
            while i < n and text[i] != "\n":
                i += 1
            continue
        if c == "/" and i + 1 < n and text[i + 1] == "*":
            i += 2
            while i + 1 < n and not (text[i] == "*" and text[i + 1] == "/"):
                i += 1
            i += 2
            continue
        out.append(c)
        i += 1
    return "".join(out)


def load_schema(name):
    path = SCHEMA_DIR / f"{name}.schema.json"
    if not path.is_file():
        fail(f"missing client schema {path}")
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as e:
        fail(f"{path} is not valid JSON: {e}")


def check_schema(schema_name, text, what):
    """Validate a whole JSON document against a client schema; returns a
    list of error strings."""
    schema = SCHEMAS[schema_name]
    try:
        doc = json.loads(text)
    except json.JSONDecodeError as e:
        return [f"{what}: not valid JSON: {e}"]
    errors = []
    validate(doc, schema, schema.get("$defs", {}), what, errors)
    return errors


def check_snippet_jsonc(schema_name, text, what):
    """A jsonc snippet is a document fragment — strip comments, wrap it in
    braces, and validate it against the client schema like a real file."""
    return check_schema(schema_name, "{" + strip_jsonc(text) + "}", what)


def check_snippet_toml(text, what):
    """Codex's snippet is a valid TOML fragment — parse it when tomllib is
    available, else fall back to the ordered-token check."""
    if tomllib is not None:
        try:
            doc = tomllib.loads(text)
        except tomllib.TOMLDecodeError as e:
            return [f"{what}: not valid TOML: {e}"]
        srv = doc.get("mcp_servers", {}).get("mcacp")
        if srv is None:
            return [f"{what}: no [mcp_servers.mcacp] table"]
        errors = []
        if srv.get("command") != "npx":
            errors.append(f"{what}: mcp_servers.mcacp.command "
                          f"{srv.get('command')!r} != 'npx'")
        if srv.get("args") != ["-y", "mcacp"]:
            errors.append(f"{what}: mcp_servers.mcacp.args "
                          f"{srv.get('args')!r} != ['-y', 'mcacp']")
        return errors
    tokens = [r"\[mcp_servers\.mcacp\]", r'command = "npx"',
              r'args = \["-y", "mcacp"\]']
    return check_ordered(tokens, text, what)


def check_ordered(tokens, text, what):
    """Every regex must match, in order — position of each match must come
    after the previous one."""
    errors = []
    pos = 0
    for tok in tokens:
        m = re.search(tok, text[pos:], re.MULTILINE)
        if m is None:
            errors.append(f"{what}: expected pattern not found: {tok}")
            continue
        pos += m.end()
    return errors


def check_snippet_structural(client, text, what):
    if client == "codex":
        return check_snippet_toml(text, what)
    return check_ordered(STRUCTURAL[client], text, what)


def read(path, what):
    try:
        with open(path, encoding="utf-8") as f:
            return f.read()
    except OSError as e:
        fail(f"{what}: cannot read {path}: {e}")


def expected_clients():
    """The authoritative client-name set: every ClientKind member resolved
    through clientName() in src/setup.zig."""
    text = SETUP_ZIG.read_text(encoding="utf-8")
    m = re.search(r"pub const ClientKind = enum \{([^}]*)\}", text)
    if m is None:
        fail("cannot find ClientKind enum in src/setup.zig")
    members = re.findall(r"\w+", m.group(1))
    nm = re.search(r"pub fn clientName[^{]*\{(.*?)\n\}", text, re.DOTALL)
    if nm is None:
        fail("cannot find clientName() in src/setup.zig")
    names = dict(re.findall(r'\.(\w+) => "([^"]+)"', nm.group(1)))
    missing = [k for k in members if k not in names]
    if missing:
        fail(f"ClientKind members without a clientName() arm: {missing}")
    return {names[k] for k in members}


SCHEMAS = {}


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--tau", default=str(ROOT / "zig-out/bin/tau"),
                    help="path to the tau binary")
    args = ap.parse_args()

    if not os.path.isfile(args.tau):
        fail(f"tau binary not found: {args.tau}")

    # Coverage gate: every ClientKind must have a contract entry here —
    # adding a client without a schema/structural contract fails loudly.
    expected = expected_clients()
    have = set(CLIENT_SCHEMAS)
    if expected != have:
        fail(f"client contract coverage drifted — setup.zig knows "
             f"{sorted(expected)} but CLIENT_SCHEMAS covers {sorted(have)}")

    for name in set(CLIENT_SCHEMAS.values()) - {None} | {"mcacp"}:
        SCHEMAS[name] = load_schema(name)

    problems = []

    def entry_for(step, client):
        entry = next((c for c in step["clients"]
                      if c.get("client") == client), None)
        if entry is None:
            fail(f"clients step has no entry for {client}")
        return entry

    # Pass 1 — clean HOME: fresh settings files (+ the shared bridge config
    # for MCP clients), or "manual" + snippet for the clients setup never
    # writes.
    with tempfile.TemporaryDirectory() as home:
        for client, schema_name in CLIENT_SCHEMAS.items():
            entry = entry_for(run_setup(args.tau, client, home), client)
            if schema_name is not None:
                if entry.get("status") != "installed":
                    problems.append(
                        f"{client}: expected status installed, got "
                        f"{entry.get('status')} — {json.dumps(entry)}")
                    continue
                problems += check_schema(
                    schema_name, read(entry["path"], f"{client} settings"),
                    f"{client}: settings file")
                if client in BRIDGE_CLIENTS:
                    if entry.get("bridge_status") not in ("installed",
                                                          "already_installed"):
                        problems.append(f"{client}: unexpected bridge_status "
                                        f"{entry.get('bridge_status')}")
                    else:
                        problems += check_schema(
                            "mcacp",
                            read(entry["bridge_path"], "mcacp.json"),
                            f"{client}: mcacp.json")
                continue
            # No settings file — setup must report manual and point at a
            # paste-ready snippet.
            if entry.get("status") != "manual":
                problems.append(f"{client}: expected status manual, got "
                                f"{entry.get('status')} — {json.dumps(entry)}")
                continue
            problems += check_snippet_structural(
                client,
                read(entry["snippet_path"], f"{client} snippet"),
                f"{client}: snippet")
            if client in MANUAL_BRIDGE:
                if entry.get("bridge_status") not in ("installed",
                                                      "already_installed"):
                    problems.append(f"{client}: unexpected bridge_status "
                                    f"{entry.get('bridge_status')}")
                else:
                    problems += check_schema(
                        "mcacp", read(entry["bridge_path"], "mcacp.json"),
                        f"{client}: mcacp.json")

    # Pass 2 — every settings file already exists (foreign entries only):
    # setup must not touch them, so paste-ready snippets land under
    # ~/.config/tau/snippets/ instead. Snippet-only clients are covered by
    # pass 1.
    with tempfile.TemporaryDirectory() as home:
        seeds = {
            ".config/zed/settings.json":
                '{"agent_servers":{"other":{"command":"x"}}}',
            ".config/Code/User/settings.json":
                '{"acp.agents":{"other":{"command":"x"}}}',
            ".config/Cursor/User/settings.json":
                '{"acp.agents":{"other":{"command":"x"}}}',
            ".jetbrains/acp.json":
                '{"agent_servers":{"other":{"command":"x"}}}',
            ".codeium/windsurf/mcp_config.json":
                '{"mcpServers":{"other":{"command":"x"}}}',
            ".gemini/settings.json":
                '{"mcpServers":{"other":{"command":"x"}}}',
            ".config/Claude/claude_desktop_config.json":
                '{"mcpServers":{"other":{"command":"x"}}}',
            ".config/opencode/opencode.json":
                '{"mcp":{"other":{"type":"local","command":["x"]}}}',
            ".config/Code/User/globalStorage/saoudrizwan.claude-dev/settings/cline_mcp_settings.json":
                '{"mcpServers":{"other":{"command":"x"}}}',
            ".config/Code/User/globalStorage/rooveterinaryinc.roo-cline/settings/mcp_settings.json":
                '{"mcpServers":{"other":{"command":"x"}}}',
            ".config/kilo/kilo.jsonc":
                '{"mcp":{"other":{"type":"local","command":["x"]}}}',
            ".aws/amazonq/mcp.json":
                '{"mcpServers":{"other":{"command":"x"}}}',
            ".config/mcacp/mcacp.json":
                '{"agent_servers":{"other":{"command":"y","args":[]}}}',
        }
        for rel, content in seeds.items():
            p = os.path.join(home, *rel.split("/"))
            os.makedirs(os.path.dirname(p), exist_ok=True)
            with open(p, "w", encoding="utf-8") as f:
                f.write(content)
        for client, schema_name in CLIENT_SCHEMAS.items():
            if client in SNIPPET_ONLY:
                continue
            entry = entry_for(run_setup(args.tau, client, home), client)
            if entry.get("status") != "manual":
                problems.append(
                    f"{client}: expected manual outcome with snippet, got "
                    f"{json.dumps(entry)}")
                continue
            if schema_name is not None:
                problems += check_snippet_jsonc(
                    schema_name,
                    read(entry["snippet_path"], f"{client} snippet"),
                    f"{client}: snippet")
            else:
                problems += check_snippet_structural(
                    client,
                    read(entry["snippet_path"], f"{client} snippet"),
                    f"{client}: snippet")
            if client in BRIDGE_CLIENTS:
                if "bridge_snippet_path" not in entry:
                    problems.append(
                        f"{client}: no bridge_snippet_path on seeded run")
                else:
                    problems += check_snippet_jsonc(
                        "mcacp",
                        read(entry["bridge_snippet_path"], "mcacp snippet"),
                        f"{client}: mcacp snippet")

    if problems:
        for p in problems:
            print(f"check-client-contracts: {p}", file=sys.stderr)
        print(f"check-client-contracts: {len(problems)} contract "
              "violation(s) — setup output no longer conforms to a client's "
              "documented config schema", file=sys.stderr)
        sys.exit(1)
    print("check-client-contracts: every `setup --client` artifact conforms "
          "to its client's documented config schema")


if __name__ == "__main__":
    main()
