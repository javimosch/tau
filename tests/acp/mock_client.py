#!/usr/bin/env python3
"""Mock ACP client — drives `tau acp serve` over newline-delimited JSON-RPC.

Integration coverage for the ACP stdio transport, fully offline:

  * handshake          — initialize negotiates protocolVersion + agentInfo
  * sessions           — session/new mints + persists an id, session/load echoes it
  * tool call          — a stubbed `curl` (tests/acp/stub-bin) answers the provider
                         HTTP call so a real tool_call -> tool_call_update ->
                         agent_message_chunk turn runs end to end
  * error envelopes    — unknown method -> -32601, prompt without API key ->
                         -32000, provider failure -> -32001
  * robustness         — malformed JSON lines and notifications produce no reply
  * exit codes         — serve exits 0 on stdin EOF; bad argv exits 80

Output is TAP (`ok N - name`). Exit status is 0 iff every check passed.

Usage: python3 tests/acp/mock_client.py --bin ./zig-out/bin/tau [--verbose]
"""

import argparse
import json
import os
import queue
import shutil
import subprocess
import sys
import tempfile
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
STUB_BIN = os.path.join(HERE, "stub-bin")

# Every env var tau can resolve an API key from (provider env_keys + the
# TAU_API_KEY fallback). Scrubbed for the no-key scenario, stubbed for the
# keyed one so the default provider always resolves a credential.
KEY_VARS = [
    "XIAOMI_API_KEY",
    "PIZIG_API_KEY",
    "OPENAI_API_KEY",
    "DEEPSEEK_API_KEY",
    "OPENCODE_API_KEY",
    "TAU_API_KEY",
]

_pass = 0
_fail = 0
_skip = 0
_verbose = False


def note(msg):
    sys.stderr.write("# %s\n" % msg)


def check(name, cond, detail=""):
    global _pass, _fail
    n = _pass + _fail + _skip + 1
    if cond:
        _pass += 1
        sys.stdout.write("ok %d - %s\n" % (n, name))
    else:
        _fail += 1
        suffix = " (%s)" % detail if detail else ""
        sys.stdout.write("not ok %d - %s%s\n" % (n, name, suffix))
    sys.stdout.flush()


def skip(name, reason):
    global _skip
    n = _pass + _fail + _skip + 1
    _skip += 1
    sys.stdout.write("ok %d - %s # skip %s\n" % (n, name, reason))
    sys.stdout.flush()


class AcpClient:
    """A spawned `tau acp serve` process plus a reader thread.

    stdout frames are parsed as JSON and pushed onto `msgs`; a None sentinel
    means the process closed its stdout (died or exited).
    """

    def __init__(self, bin_path, env, cwd):
        self.proc = subprocess.Popen(
            [bin_path, "acp", "serve", "--max-iterations", "5"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=env,
            cwd=cwd,
        )
        self.msgs = queue.Queue()
        self.raw_lines = []
        self._reader = threading.Thread(target=self._pump, daemon=True)
        self._reader.start()
        self._next_id = 0

    def _pump(self):
        try:
            for line in self.proc.stdout:
                line = line.decode("utf-8", "replace").strip()
                if not line:
                    continue
                self.raw_lines.append(line)
                if _verbose:
                    note("<< %s" % line)
                try:
                    self.msgs.put(json.loads(line))
                except ValueError:
                    self.msgs.put({"_unparsed": line})
        finally:
            self.msgs.put(None)

    def send_raw(self, text):
        if _verbose:
            note(">> %s" % text)
        self.proc.stdin.write(text.encode("utf-8") + b"\n")
        self.proc.stdin.flush()

    def request(self, method, params=None, timeout=30):
        """Send a request; return (response_msg, [notifications seen])."""
        self._next_id += 1
        rid = self._next_id
        frame = {"jsonrpc": "2.0", "id": rid, "method": method}
        if params is not None:
            frame["params"] = params
        self.send_raw(json.dumps(frame))
        notifications = []
        deadline = time.monotonic() + timeout
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError("no response for id %d (%s)" % (rid, method))
            try:
                msg = self.msgs.get(timeout=remaining)
            except queue.Empty:
                raise TimeoutError("no response for id %d (%s)" % (rid, method))
            if msg is None:
                raise EOFError("serve closed stdout while awaiting id %d" % rid)
            if isinstance(msg, dict) and msg.get("id") == rid:
                return msg, notifications
            notifications.append(msg)

    def drain(self, seconds):
        """Collect everything that arrives within `seconds` (for silence checks)."""
        got = []
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            try:
                msg = self.msgs.get(timeout=deadline - time.monotonic())
            except queue.Empty:
                break
            if msg is None:
                break
            got.append(msg)
        return got

    def close(self, timeout=15):
        """Close stdin (EOF) and wait for exit; return the exit code."""
        try:
            self.proc.stdin.close()
        except BrokenPipeError:
            pass
        return self.proc.wait(timeout=timeout)

    def kill(self):
        if self.proc.poll() is None:
            self.proc.kill()
            self.proc.wait(timeout=10)


def base_env(home, keyed):
    env = dict(os.environ)
    for k in KEY_VARS:
        env.pop(k, None)
    env["HOME"] = home
    # Fail fast (connection refused) if anything ever reaches a real socket —
    # the curl shim is what should answer, never the network.
    env["TAU_ENDPOINT"] = "http://127.0.0.1:9/acp-stub"
    if keyed:
        for k in KEY_VARS:
            env[k] = "acp-stub-key"
        env["PATH"] = STUB_BIN + os.pathsep + env.get("PATH", "")
    return env


def updates_of(notifications, kind):
    return [
        n for n in notifications
        if isinstance(n, dict)
        and n.get("method") == "session/update"
        and isinstance(n.get("params"), dict)
        and isinstance(n["params"].get("update"), dict)
        and n["params"]["update"].get("sessionUpdate") == kind
    ]


def scenario_handshake_errors(bin_path, home, work):
    note("scenario A: handshake, sessions, error envelopes (no API key)")
    env = base_env(home, keyed=False)
    client = AcpClient(bin_path, env, work)
    try:
        # --- initialize handshake -----------------------------------------
        resp, _ = client.request("initialize", {
            "protocolVersion": 1,
            "clientCapabilities": {"fs": {"readTextFile": False, "writeTextFile": False}},
        })
        result = resp.get("result") or {}
        check("initialize returns a result", "result" in resp,
              json.dumps(resp)[:200])
        check("initialize negotiates protocolVersion 1",
              result.get("protocolVersion") == 1,
              json.dumps(result)[:200])
        check("initialize reports agentInfo.name=tau",
              (result.get("agentInfo") or {}).get("name") == "tau",
              json.dumps(result.get("agentInfo"))[:200])
        check("initialize advertises agentCapabilities",
              isinstance(result.get("agentCapabilities"), dict))

        # --- authenticate --------------------------------------------------
        resp, _ = client.request("authenticate", {"methodId": "none"})
        check("authenticate resolves with empty result", resp.get("result") == {},
              json.dumps(resp)[:200])

        # --- session/new ---------------------------------------------------
        resp, _ = client.request("session/new", {"cwd": work, "mcpServers": []})
        sid = ((resp.get("result") or {}).get("sessionId")) or ""
        check("session/new returns an acp-* sessionId", sid.startswith("acp-"),
              sid)
        sess_file = os.path.join(home, ".config", "tau", "sessions", sid + ".json")
        check("session/new persists the session file", os.path.isfile(sess_file),
              sess_file)

        # --- unknown method -> JSON-RPC -32601 ------------------------------
        resp, _ = client.request("tau/no-such-method")
        err = resp.get("error") or {}
        check("unknown method -> error envelope", "error" in resp,
              json.dumps(resp)[:200])
        check("unknown method -> code -32601", err.get("code") == -32601,
              json.dumps(err)[:200])

        # --- malformed JSON + notification -> silence -----------------------
        client.send_raw("this is { not json")
        client.send_raw(json.dumps({
            "jsonrpc": "2.0",
            "method": "session/cancel",
            "params": {"sessionId": sid},
        }))
        stray = client.drain(0.6)
        check("malformed JSON + cancel notification produce no reply",
              stray == [], json.dumps(stray)[:200])
        # Server still alive: a fresh initialize is answered.
        resp, _ = client.request("initialize", {"protocolVersion": 1})
        check("server survives malformed input", "result" in resp,
              json.dumps(resp)[:200])

        # --- session/prompt without API key -> -32000 -----------------------
        resp, _ = client.request("session/prompt", {
            "sessionId": sid,
            "prompt": [{"type": "text", "text": "hello"}],
        })
        err = resp.get("error") or {}
        check("prompt without API key -> error envelope", "error" in resp,
              json.dumps(resp)[:200])
        check("prompt without API key -> code -32000", err.get("code") == -32000,
              json.dumps(err)[:200])

        # --- session/load --------------------------------------------------
        resp, _ = client.request("session/load", {"sessionId": sid, "cwd": work})
        got = (resp.get("result") or {}).get("sessionId")
        check("session/load echoes the sessionId", got == sid,
              "want %s got %s" % (sid, got))

        # --- clean EOF shutdown --------------------------------------------
        rc = client.close()
        check("serve exits 0 on stdin EOF", rc == 0, "exit %s" % rc)
        return
    finally:
        client.kill()


def scenario_tool_call(bin_path, home, work):
    if os.name == "nt":
        for name in (
            "tool turn -> stopReason end_turn",
            "tool turn streams tool_call notification",
            "tool turn streams tool_call_update completed + tool output",
            "tool turn streams agent_message_chunk",
            "plain turn -> agent_message_chunk + end_turn, no tool calls",
            "provider failure -> -32001 completion failed",
            "serve exits 0 on stdin EOF (keyed)",
        ):
            skip(name, "curl shim is not executable under a native Windows binary")
        return

    note("scenario B: tool call turn + provider failure (stubbed curl)")
    env = base_env(home, keyed=True)
    client = AcpClient(bin_path, env, work)
    try:
        client.request("initialize", {
            "protocolVersion": 1,
            # fs capabilities left false so mutating tools run directly —
            # no fs/* client round-trips to answer.
            "clientCapabilities": {"fs": {"readTextFile": False, "writeTextFile": False}},
        })
        resp, _ = client.request("session/new", {"cwd": work, "mcpServers": []})
        sid = (resp.get("result") or {}).get("sessionId") or ""

        # --- full tool-call turn -------------------------------------------
        resp, notes = client.request("session/prompt", {
            "sessionId": sid,
            "prompt": [{"type": "text", "text": "please run a command for me"}],
        }, timeout=60)
        result = resp.get("result") or {}
        check("tool turn -> stopReason end_turn",
              result.get("stopReason") == "end_turn", json.dumps(resp)[:200])

        tcs = updates_of(notes, "tool_call")
        check("tool turn streams tool_call notification",
              len(tcs) == 1
              and tcs[0]["params"]["update"].get("title") == "bash"
              and tcs[0]["params"]["update"].get("kind") == "execute",
              json.dumps(tcs)[:300])

        tcus = updates_of(notes, "tool_call_update")
        completed = [
            u for u in tcus
            if u["params"]["update"].get("status") == "completed"
            and "ACP_STUB_TOOL_OK" in json.dumps(u)
        ]
        check("tool turn streams tool_call_update completed + tool output",
              len(completed) == 1, json.dumps(tcus)[:300])

        chunks = updates_of(notes, "agent_message_chunk")
        check("tool turn streams agent_message_chunk",
              any("ACP_STUB_FINAL_ANSWER" in json.dumps(c) for c in chunks),
              json.dumps(chunks)[:300])

        # --- plain text turn (no tool calls) -------------------------------
        resp, notes = client.request("session/prompt", {
            "sessionId": sid,
            "prompt": [{"type": "text", "text": "TRIGGER_PLAIN"}],
        }, timeout=60)
        result = resp.get("result") or {}
        check("plain turn -> agent_message_chunk + end_turn, no tool calls",
              result.get("stopReason") == "end_turn"
              and len(updates_of(notes, "tool_call")) == 0
              and len(updates_of(notes, "agent_message_chunk")) >= 1,
              json.dumps(resp)[:200])

        # --- provider failure -> -32001 ------------------------------------
        resp, _ = client.request("session/prompt", {
            "sessionId": sid,
            "prompt": [{"type": "text", "text": "TRIGGER_ERROR"}],
        }, timeout=60)
        err = resp.get("error") or {}
        check("provider failure -> -32001 completion failed",
              err.get("code") == -32001
              and "completion failed" in (err.get("message") or ""),
              json.dumps(resp)[:200])

        rc = client.close()
        check("serve exits 0 on stdin EOF (keyed)", rc == 0, "exit %s" % rc)
    finally:
        client.kill()


def scenario_exit_codes(bin_path, work):
    note("scenario C: exit codes")
    env = base_env(work, keyed=False)

    r = subprocess.run([bin_path, "acp", "bogus"], env=env,
                       stdin=subprocess.DEVNULL,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    check("acp bogus -> exit 80", r.returncode == 80, "exit %s" % r.returncode)

    r = subprocess.run([bin_path, "acp", "serve", "--bogus-flag"], env=env,
                       stdin=subprocess.DEVNULL,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    check("acp serve --bogus-flag -> exit 80", r.returncode == 80,
          "exit %s" % r.returncode)

    r = subprocess.run([bin_path, "acp", "serve"], env=env,
                       stdin=subprocess.DEVNULL,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                       timeout=15)
    check("acp serve with immediate EOF -> exit 0", r.returncode == 0,
          "exit %s" % r.returncode)


def main():
    global _verbose
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--bin", dest="bin_path", required=True, help="path to tau")
    ap.add_argument("--verbose", action="store_true", help="log JSON-RPC frames")
    args = ap.parse_args()
    _verbose = args.verbose

    bin_path = os.path.abspath(args.bin_path)
    if not os.path.isfile(bin_path):
        sys.stderr.write("tau binary not found: %s\n" % bin_path)
        return 2

    tmp = tempfile.mkdtemp(prefix="tau-acp-mock-")
    try:
        home_a = os.path.join(tmp, "home-a")
        home_b = os.path.join(tmp, "home-b")
        work = os.path.join(tmp, "work")
        for d in (home_a, home_b, work):
            os.makedirs(d)

        scenario_handshake_errors(bin_path, home_a, work)
        scenario_tool_call(bin_path, home_b, work)
        scenario_exit_codes(bin_path, work)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    total = _pass + _fail + _skip
    sys.stdout.write("1..%d\n" % total)
    sys.stdout.flush()
    note("%d passed, %d failed, %d skipped" % (_pass, _fail, _skip))
    return 1 if _fail else 0


if __name__ == "__main__":
    sys.exit(main())
