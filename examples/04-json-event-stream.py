#!/usr/bin/env python3
"""Minimal consumer for tau's JSON stdout event stream.

In the default JSON mode with streaming enabled, tau writes newline-delimited
JSON (NDJSON) to stdout — one complete JSON object per line:

    {"chunk":"Hel","done":false}                       content delta
    {"chunk":"lo!","done":false}                       ...
    {"reasoning":"...","done":false}                   only with --thinking
    {"version":"0.4.0","model":"xiaomi/mimo-v2.5",
     "content":"Hello!","done":true}                   final envelope

The line with "done":true carries the fully assembled response in .content,
so a consumer can either render .chunk events live (as below) or simply wait
for the final envelope. Other command results (dry-run plans, /goal status)
also arrive as single JSON objects. One exception: `tau fleet` prints a
pretty-printed multi-line manifest — collect all of stdout for that command
instead of parsing line by line.

stderr carries envelopes only — never prose:

    {"warn":{"message":"..."}}
    {"err":{"code":106,"type":"auth","message":"...","recoverable":false}}

Exit codes: 0 ok · 80 bad args · 82 missing field · 105 timeout ·
            106 auth · 110 internal · 111 unimplemented.
Caveat: a missing API key exits 106 with no envelope at all.

Usage:
    python3 examples/04-json-event-stream.py "Summarise Zig in one line"
    python3 examples/04-json-event-stream.py --no-tools "What is 2+2?"
    TAU_BIN=/path/to/tau python3 examples/04-json-event-stream.py "..."
"""

import json
import os
import subprocess
import sys

EXIT_CODES = {
    80: "invalid_argument",
    82: "missing_field",
    105: "timeout",
    106: "auth",
    110: "internal_error",
    111: "unimplemented",
}


def report_stderr(raw):
    """Decode tau's stderr envelopes; echo anything else verbatim."""
    for line in raw.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            ev = json.loads(line)
        except json.JSONDecodeError:
            print(f"stderr: {line}", file=sys.stderr)
            continue
        if not isinstance(ev, dict):
            print(f"stderr: {line}", file=sys.stderr)
        elif "warn" in ev:
            print(f"warn: {ev['warn'].get('message', '')}", file=sys.stderr)
        elif "err" in ev:
            err = ev["err"]
            print(f"err {err.get('code')}: {err.get('message', '')}", file=sys.stderr)
        else:
            print(f"stderr event: {json.dumps(ev)}", file=sys.stderr)


def main():
    tau = os.environ.get("TAU_BIN", "tau")
    # argv is passed through to tau verbatim; default to a quick demo call.
    args = sys.argv[1:] or ["--no-tools", "Say hello in one short sentence."]

    proc = subprocess.Popen(
        [tau, *args],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )

    final = None
    saw_chunk = False
    # Read events as they arrive. tau's stderr is bounded (small envelopes),
    # so draining it after stdout closes cannot deadlock this script.
    for line in proc.stdout:
        line = line.strip()
        if not line:
            continue
        try:
            ev = json.loads(line)
        except json.JSONDecodeError:
            # Not a tau event — e.g. part of a pretty-printed fleet manifest.
            print(f"non-JSON stdout line: {line}", file=sys.stderr)
            continue
        if not isinstance(ev, dict):
            continue
        if "chunk" in ev:  # content delta — render live
            saw_chunk = True
            print(ev["chunk"], end="", flush=True)
        elif "reasoning" in ev:  # thinking delta (requires --thinking)
            print(f"[thinking] {ev['reasoning']}", end="", file=sys.stderr, flush=True)
        elif ev.get("done"):
            final = ev
        else:
            # Command result objects: {"dry_run":...}, {"goal":...}, etc.
            print(json.dumps(ev, indent=2))

    stderr = proc.stderr.read()
    rc = proc.wait()
    if saw_chunk:
        print()  # newline after the live-rendered chunks

    report_stderr(stderr)

    if rc != 0:
        print(f"tau failed: exit {rc} ({EXIT_CODES.get(rc, 'unknown')})", file=sys.stderr)
        return rc
    if final is None:
        print("tau exited 0 but emitted no final envelope", file=sys.stderr)
        return 1

    # final["content"] == every chunk concatenated. Use whichever suits you.
    print(f"---\nmodel={final.get('model')} version={final.get('version')} "
          f"content_chars={len(final.get('content', ''))}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
