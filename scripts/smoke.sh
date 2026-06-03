#!/usr/bin/env bash
# pizig smoke test harness.
#
# Usage:
#   scripts/smoke.sh            # deterministic, offline CLI tests only
#   scripts/smoke.sh --net      # also run real LLM calls (needs network + key)
#
# Exit 0 if all run tests pass, 1 otherwise.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/zig-out/bin/tau"
NET=0
[ "${1:-}" = "--net" ] && NET=1

pass=0
fail=0

# ok <name> <actual_exit> <expected_exit>
ok() {
  if [ "$2" = "$3" ]; then
    printf 'PASS  %s (exit %s)\n' "$1" "$2"
    pass=$((pass + 1))
  else
    printf 'FAIL  %s (got exit %s, want %s)\n' "$1" "$2" "$3"
    fail=$((fail + 1))
  fi
}

# contains <name> <haystack> <needle>
contains() {
  case "$2" in
    *"$3"*) printf 'PASS  %s\n' "$1"; pass=$((pass + 1)) ;;
    *)      printf 'FAIL  %s (missing %q)\n' "$1" "$3"; fail=$((fail + 1)) ;;
  esac
}

if [ ! -x "$BIN" ]; then
  echo "building pizig..."
  ( cd "$ROOT" && zig build ) || { echo "build failed"; exit 1; }
fi

echo "== deterministic CLI tests =="

out=$("$BIN" --version); ok "--version exit" "$?" 0
contains "--version says tau" "$out" "tau"

out=$("$BIN" --help); ok "--help exit" "$?" 0
# --help now outputs JSON by default (agent-first), check for JSON structure
if printf '%s' "$out" | python3 -c 'import sys,json;d=json.load(sys.stdin);assert d["name"]=="tau"' 2>/dev/null; then
  printf 'PASS  --help is valid JSON with tau name\n'; pass=$((pass + 1))
else
  printf 'FAIL  --help is not valid JSON or missing tau name\n'; fail=$((fail + 1))
fi

out=$("$BIN" --help-json)
if printf '%s' "$out" | python3 -c 'import sys,json;json.load(sys.stdin)' 2>/dev/null; then
  printf 'PASS  --help-json is valid JSON\n'; pass=$((pass + 1))
else
  printf 'FAIL  --help-json is not valid JSON\n'; fail=$((fail + 1))
fi

# No prompt now shows help (exit 0) instead of missing_required_field (82)
"$BIN" -p >/dev/null 2>&1;                       ok "no prompt -> shows help" "$?" 0
# Text mode help should show human-readable usage
out=$("$BIN" --mode text --help); ok "--mode text --help exit" "$?" 0
contains "--mode text --help shows usage" "$out" "Usage:"
"$BIN" --bogus "x" >/dev/null 2>&1;              ok "unknown flag -> invalid_argument" "$?" 80
"$BIN" --provider nope "x" >/dev/null 2>&1;      ok "unknown provider -> invalid_argument" "$?" 80
"$BIN" --mode bad "x" >/dev/null 2>&1;           ok "bad --mode -> invalid_argument" "$?" 80
"$BIN" --temperature notafloat "x" >/dev/null 2>&1; ok "bad --temperature -> invalid_argument" "$?" 80
"$BIN" "@/no/such/file" "x" >/dev/null 2>&1;     ok "missing @file -> invalid_argument" "$?" 80

if [ "$NET" = 1 ]; then
  echo "== network LLM tests =="

  out=$("$BIN" -p "Reply with exactly: PIZIG_SMOKE_OK"); rc=$?
  ok "text-mode prompt exit" "$rc" 0
  contains "text-mode returns marker" "$out" "PIZIG_SMOKE_OK"

  out=$("$BIN" --mode json "Say hi in three words"); rc=$?
  ok "json-mode prompt exit" "$rc" 0
  if printf '%s' "$out" | python3 -c 'import sys,json;d=json.load(sys.stdin);assert d["content"]' 2>/dev/null; then
    printf 'PASS  json-mode has content field\n'; pass=$((pass + 1))
  else
    printf 'FAIL  json-mode invalid/empty\n'; fail=$((fail + 1))
  fi

  tmp="$(mktemp)"; printf 'the magic token is ZQ-91' > "$tmp"
  out=$("$BIN" --system-prompt "Reply with only the token." "@$tmp" "What is the magic token?"); rc=$?
  ok "@file + system-prompt exit" "$rc" 0
  contains "@file content reaches model" "$out" "ZQ-91"
  rm -f "$tmp"

  # Streaming: text mode round-trip
  out=$("$BIN" --stream --mode text "Reply with exactly: STREAM_OK_42"); rc=$?
  ok "stream text exit" "$rc" 0
  contains "stream text returns marker" "$out" "STREAM_OK_42"

  # Streaming: json mode emits valid NDJSON with a final done line
  out=$("$BIN" --stream --mode json "Say hello in two words"); rc=$?
  ok "stream json exit" "$rc" 0
  if printf '%s' "$out" | python3 -c 'import sys,json
lines=[l for l in sys.stdin if l.strip()]
assert all(json.loads(l) for l in lines)
assert json.loads(lines[-1]).get("done") is True' 2>/dev/null; then
    printf 'PASS  stream json is valid NDJSON ending in done\n'; pass=$((pass + 1))
  else
    printf 'FAIL  stream json malformed\n'; fail=$((fail + 1))
  fi

  # Tool-calling: bash round-trip (model calls bash -> we execute -> model answers)
  out=$("$BIN" --tools bash "Use the bash tool to run: echo TOOLS_WORK_91"); rc=$?
  ok "bash tool exit" "$rc" 0
  contains "bash tool executed end-to-end" "$out" "TOOLS_WORK_91"

  # Tool-calling: read round-trip
  tf="$(mktemp)"; printf 'SMOKE_FILE_MARKER_77' > "$tf"
  out=$("$BIN" --tools read "Use the read tool to read $tf and quote its contents."); rc=$?
  ok "read tool exit" "$rc" 0
  contains "read tool returned file contents" "$out" "SMOKE_FILE_MARKER_77"
  rm -f "$tf"

  # Tool-calling: write round-trip (verify the side effect on disk)
  wf="$(mktemp -u)"
  out=$("$BIN" --tools write "Use the write tool to create $wf containing exactly: WRITE_MARKER_55"); rc=$?
  ok "write tool exit" "$rc" 0
  if [ -f "$wf" ] && grep -q "WRITE_MARKER_55" "$wf"; then
    printf 'PASS  write tool created file on disk\n'; pass=$((pass + 1))
  else
    printf 'FAIL  write tool did not create expected file\n'; fail=$((fail + 1))
  fi
  rm -f "$wf"

  # ── Session smoke test ──────────────────────────────────────────────────────
  echo "== session tests =="
  SESS="smoke-session-$$"
  sess_file="$HOME/.config/tau/sessions/${SESS}.json"

  out=$("$BIN" --session "$SESS" --no-tools --no-stream -p "My secret number is 42"); rc=$?
  ok "session: first turn exit" "$rc" 0

  out=$("$BIN" --session "$SESS" --no-tools --no-stream -p "What is my secret number?"); rc=$?
  ok "session: second turn exit" "$rc" 0
  contains "session: model recalls secret number" "$out" "42"

  # Verify session file was written and has 4 messages (2 turns × user+assistant)
  if python3 - "$sess_file" <<'PYEOF' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
assert len(d["messages"]) == 4, f"expected 4 messages, got {len(d['messages'])}"
PYEOF
  then
    printf 'PASS  session: file has 4 messages\n'; pass=$((pass + 1))
  else
    printf 'FAIL  session: unexpected message count\n'; fail=$((fail + 1))
  fi

  rm -f "$sess_file"

  # ── Auto-compaction smoke test ───────────────────────────────────────────────
  # Strategy: seed a session with fat messages (--no-compact), then on the next
  # call use --compact-keep-recent 50 with a tiny --context-window so that:
  #   shouldCompact: est_tokens > context_window × compact_threshold  (fires)
  #   compact():     tail_start > head+1                              (does work)
  # Result: session shrinks and first msg contains "[Earlier conversation summary]"
  echo "== compaction tests =="
  CSESS="smoke-compact-$$"
  csess_file="$HOME/.config/tau/sessions/${CSESS}.json"

  # Seed 3 turns with long messages (~200 chars each) — total ~300 tokens
  LONG_MSG="$(python3 -c "print('Tell me something interesting about space exploration. ' * 4, end='')")"
  for i in 1 2 3; do
    "$BIN" --session "$CSESS" --no-tools --no-stream --no-compact -p "$LONG_MSG" > /dev/null
  done

  # Verify seeding worked: 6 messages, enough tokens to exceed threshold
  seed_ok=$(python3 - "$csess_file" <<'PYEOF' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
msgs = d["messages"]
total_chars = sum(len(m["content"]) for m in msgs)
est_tokens = total_chars // 4
# shouldCompact: est_tokens > 200 * 0.5 = 100
assert len(msgs) >= 6, f"expected >=6 messages, got {len(msgs)}"
assert est_tokens > 100, f"expected est_tokens>100, got {est_tokens}"
print(f"seeded: {len(msgs)} msgs, {est_tokens} tokens")
PYEOF
  )
  if [ -n "$seed_ok" ]; then
    printf 'PASS  compaction seed: %s\n' "$seed_ok"; pass=$((pass + 1))
  else
    printf 'FAIL  compaction seed: session not fat enough\n'; fail=$((fail + 1))
  fi

  # Trigger compaction: context_window=200, threshold=0.5 → fire at >100 tokens
  # compact_keep_recent=50 → tiny tail, forces middle span to be summarized
  out=$("$BIN" --session "$CSESS" --no-tools --no-stream \
    --context-window 200 --compact-threshold 0.5 --compact-keep-recent 50 \
    -p "Summarize what we discussed so far."); rc=$?
  ok "compaction: trigger turn exit" "$rc" 0

  # Verify: session shrank and contains the summary sentinel
  if python3 - "$csess_file" <<'PYEOF' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
msgs = d["messages"]
assert len(msgs) < 6, f"expected <6 messages after compaction, got {len(msgs)}"
has_summary = any("[Earlier conversation summary]" in m["content"] for m in msgs)
assert has_summary, "no compaction summary found in messages"
print(f"compacted: {len(msgs)} msgs, summary present")
PYEOF
  then
    printf 'PASS  compaction: session shrank with summary sentinel\n'; pass=$((pass + 1))
  else
    printf 'FAIL  compaction: session not compacted or summary missing\n'; fail=$((fail + 1))
  fi

  rm -f "$csess_file"
else
  echo "(skipping network tests; pass --net to enable)"
fi

echo
echo "== summary: $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
