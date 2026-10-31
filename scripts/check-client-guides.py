#!/usr/bin/env python3
"""Verify the per-client setup guides match `tau setup --client` output.

docs/clients/{windsurf,gemini-cli,claude-desktop}.md embed the config
snippets tau writes. Each verified block is marked with an HTML comment
directly above the fenced code block:

    <!-- setup-verify: client-file -->
    ```json
    ...
    ```

Slots:
  client-file     the client's settings file when setup writes it fresh
  bridge-file     ~/.config/mcacp/mcacp.json (the shared MCP->ACP bridge
                  config; its absolute "command" path is normalized to
                  "tau" before comparison)
  client-snippet  the paste-ready ~/.config/tau/snippets/<client>.jsonc
                  setup drops when the settings file already exists
  bridge-snippet  ~/.config/tau/snippets/mcacp.jsonc for an existing
                  mcacp.json (normalized like bridge-file)

The check runs `tau setup --client <name> --yes` twice per client: once in
a clean HOME (fresh files) and once with pre-seeded settings files
(snippet path). Each marked block must equal the bytes tau wrote,
byte-for-byte. Run by the client-guides smoke group; also usable
standalone:

    python3 scripts/check-client-guides.py --tau zig-out/bin/tau
"""

import argparse
import difflib
import json
import os
import re
import subprocess
import sys
import tempfile

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

GUIDES = {
    "windsurf.md": "windsurf",
    "gemini-cli.md": "gemini",
    "claude-desktop.md": "claude-desktop",
}

SLOTS = ("client-file", "bridge-file", "client-snippet", "bridge-snippet")

MARKER = re.compile(
    r"<!--\s*setup-verify:\s*(client-file|bridge-file|client-snippet|bridge-snippet)\s*-->"
    r"\s*```(?:json|jsonc)\n(.*?)```",
    re.DOTALL,
)

# Provider key env vars scrubbed so setup always seeds xiaomi from
# XIAOMI_API_KEY — same recipe as the client-examples smoke group.
SCRUB = ("OPENAI_API_KEY", "DEEPSEEK_API_KEY", "OPENCODE_API_KEY",
         "TAU_API_KEY", "PIZIG_API_KEY", "TAU_ENDPOINT")


def fail(msg):
    print(f"check-client-guides: {msg}", file=sys.stderr)
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


def norm_command(text):
    """Absolute tau path -> "tau", like the client-examples smoke group."""
    return re.sub(r'"command": "[^"]*"', '"command": "tau"', text)


def collect(tau):
    """{client: {slot: bytes-written}} from real `tau setup` runs."""
    out = {}

    # Pass 1 — clean HOME: fresh settings files + the shared bridge config.
    with tempfile.TemporaryDirectory() as home:
        for client in GUIDES.values():
            step = run_setup(tau, client, home)
            entry = next((c for c in step["clients"]
                          if c.get("client") == client), None)
            if entry is None:
                fail(f"clients step has no entry for {client}")
            if entry.get("status") != "installed":
                fail(f"{client}: expected status installed, got "
                     f"{entry.get('status')} — {json.dumps(entry)}")
            if entry.get("bridge_status") not in ("installed",
                                                  "already_installed"):
                fail(f"{client}: unexpected bridge_status "
                     f"{entry.get('bridge_status')}")
            slots = out.setdefault(client, {})
            with open(entry["path"], encoding="utf-8") as f:
                slots["client-file"] = f.read()
            with open(entry["bridge_path"], encoding="utf-8") as f:
                slots["bridge-file"] = norm_command(f.read())

    # Pass 2 — every settings file already exists (foreign entries only):
    # setup must not touch them, so paste-ready snippets land under
    # ~/.config/tau/snippets/ instead.
    with tempfile.TemporaryDirectory() as home:
        seeds = {
            ".codeium/windsurf/mcp_config.json":
                '{"mcpServers":{"other":{"command":"x"}}}',
            ".gemini/settings.json":
                '{"mcpServers":{"other":{"command":"x"}}}',
            ".config/Claude/claude_desktop_config.json":
                '{"mcpServers":{"other":{"command":"x"}}}',
            ".config/mcacp/mcacp.json":
                '{"agent_servers":{"other":{"command":"y","args":[]}}}',
        }
        for rel, content in seeds.items():
            p = os.path.join(home, *rel.split("/"))
            os.makedirs(os.path.dirname(p), exist_ok=True)
            with open(p, "w", encoding="utf-8") as f:
                f.write(content)
        for client in GUIDES.values():
            step = run_setup(tau, client, home)
            entry = next((c for c in step["clients"]
                          if c.get("client") == client), None)
            if entry is None or entry.get("status") != "manual":
                fail(f"{client}: expected manual outcome with snippet, got "
                     f"{json.dumps(entry)}")
            slots = out[client]
            with open(entry["snippet_path"], encoding="utf-8") as f:
                slots["client-snippet"] = f.read()
            if "bridge_snippet_path" not in entry:
                fail(f"{client}: no bridge_snippet_path on seeded run")
            with open(entry["bridge_snippet_path"], encoding="utf-8") as f:
                slots["bridge-snippet"] = norm_command(f.read())

    return out


def extract_blocks(path):
    text = open(path, encoding="utf-8").read()
    return {m.group(1): m.group(2) for m in MARKER.finditer(text)}


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--tau", default=os.path.join(REPO, "zig-out/bin/tau"),
                    help="path to the tau binary")
    ap.add_argument("--docs", default=os.path.join(REPO, "docs/clients"),
                    help="directory holding the per-client guides")
    args = ap.parse_args()

    if not os.path.isfile(args.tau):
        fail(f"tau binary not found: {args.tau}")

    expected = collect(args.tau)

    problems = []
    for guide, client in GUIDES.items():
        path = os.path.join(args.docs, guide)
        if not os.path.isfile(path):
            problems.append(f"{guide}: missing (expected for --client {client})")
            continue
        blocks = extract_blocks(path)
        for slot in SLOTS:
            if slot not in blocks:
                problems.append(f"{guide}: no <!-- setup-verify: {slot} --> block")
                continue
            want = expected[client][slot]
            got = blocks[slot]
            if slot.endswith("-file"):
                try:
                    json.loads(got)
                except json.JSONDecodeError as e:
                    problems.append(f"{guide}: {slot} block is not valid JSON: {e}")
            if got != want:
                diff = "\n".join(difflib.unified_diff(
                    want.splitlines(), got.splitlines(),
                    f"setup --client {client}", f"{guide}:{slot}",
                    lineterm=""))
                problems.append(f"{guide}: {slot} block drifted\n{diff}")

    if problems:
        for p in problems:
            print(f"check-client-guides: {p}", file=sys.stderr)
        print("check-client-guides: guides drifted — re-copy the snippets "
              "`tau setup --client` writes", file=sys.stderr)
        sys.exit(1)
    print("check-client-guides: per-client guides match `tau setup --client` "
          "output")


if __name__ == "__main__":
    main()
