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
# --help outputs human-readable text; check for expected sections
contains "--help shows usage header" "$out" "Usage:"
contains "--help mentions tau" "$out" "tau"

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

# ── --role flag (Author↔Critic primitive) ─────────────────────────────────────
echo "== --role flag parsing =="
# Invalid role name rejected by parser
"$BIN" --role invalid "x" >/dev/null 2>&1;       ok "--role invalid -> invalid_argument" "$?" 80
# Valid role names accepted by parser; downstream auth (no API key) is expected
# (106) — what we verify is the parser did NOT reject the value (so !=80).
for r in author critic coordinator none; do
  "$BIN" --role "$r" --no-tools --no-stream "x" >/dev/null 2>&1
  rc=$?
  if [ "$rc" != "80" ]; then
    printf 'PASS  --role %s accepted by parser (downstream exit %s)\n' "$r" "$rc"
    pass=$((pass + 1))
  else
    printf 'FAIL  --role %s rejected by parser\n' "$r"
    fail=$((fail + 1))
  fi
done

# ── tau fleet subcommand parsing ──────────────────────────────────────────────
echo "== tau fleet subcommand parsing =="
# No subcommand -> invalid_argument
"$BIN" fleet >/dev/null 2>&1;                   ok "fleet (no sub) -> invalid_argument" "$?" 80
# Unknown subcommand -> invalid_argument
"$BIN" fleet bogus >/dev/null 2>&1;             ok "fleet bogus -> invalid_argument" "$?" 80
# run without --goal -> missing_required_field
"$BIN" fleet run >/dev/null 2>&1;               ok "fleet run without --goal -> missing_required_field" "$?" 82
# status without id -> invalid_argument
"$BIN" fleet status >/dev/null 2>&1;            ok "fleet status no id -> invalid_argument" "$?" 80
# cancel without id -> invalid_argument
"$BIN" fleet cancel >/dev/null 2>&1;            ok "fleet cancel no id -> invalid_argument" "$?" 80
# status of nonexistent id -> exit 0, prints {"fleet":null}
nonex_id="smoke-nonexistent-$$-$RANDOM"
out=$("$BIN" fleet status "$nonex_id" 2>&1)
if [ $? -eq 0 ] && printf '%s' "$out" | grep -q '"fleet":null'; then
  printf 'PASS  fleet status nonexistent -> {"fleet":null}\n'; pass=$((pass + 1))
else
  printf 'FAIL  fleet status nonexistent: %s\n' "$out"; fail=$((fail + 1))
fi
# cancel of nonexistent id -> exit 0, prints {"fleet":null}
out=$("$BIN" fleet cancel "$nonex_id" 2>&1)
if [ $? -eq 0 ] && printf '%s' "$out" | grep -q '"fleet":null'; then
  printf 'PASS  fleet cancel nonexistent -> {"fleet":null}\n'; pass=$((pass + 1))
else
  printf 'FAIL  fleet cancel nonexistent: %s\n' "$out"; fail=$((fail + 1))
fi
# list -> exit 0, prints {"fleets":[...]} (may be empty array)
out=$("$BIN" fleet list 2>&1)
if [ $? -eq 0 ] && printf '%s' "$out" | grep -q '"fleets":'; then
  printf 'PASS  fleet list -> exit 0 with fleets array\n'; pass=$((pass + 1))
else
  printf 'FAIL  fleet list: %s\n' "$out"; fail=$((fail + 1))
fi
# Help text mentions --role and the new fleet subcommands
contains "--help mentions --role" "$("$BIN" --help 2>&1)" "--role"
contains "--help mentions fleet run" "$("$BIN" --help 2>&1)" "fleet run"
contains "--help mentions fleet status" "$("$BIN" --help 2>&1)" "fleet status"
contains "--help mentions fleet cancel" "$("$BIN" --help 2>&1)" "fleet cancel"

if [ "$NET" = 1 ]; then
  echo "== network LLM tests =="

  # Use --mode text so the response is raw streaming text, not NDJSON deltas —
  # streaming JSON wraps each token in {"delta":"..."} which may split markers
  # across chunks, making a substring search unreliable.
  out=$("$BIN" --mode text "Reply with exactly: PIZIG_SMOKE_OK"); rc=$?
  ok "text-mode prompt exit" "$rc" 0
  contains "text-mode returns marker" "$out" "PIZIG_SMOKE_OK"

  # json-mode with --no-stream: single JSON object, check content field
  out=$("$BIN" --mode json --no-stream "Say hi in three words"); rc=$?
  ok "json-mode prompt exit" "$rc" 0
  if printf '%s' "$out" | python3 -c 'import sys,json;d=json.load(sys.stdin);assert d["content"]' 2>/dev/null; then
    printf 'PASS  json-mode has content field\n'; pass=$((pass + 1))
  else
    printf 'FAIL  json-mode invalid/empty\n'; fail=$((fail + 1))
  fi

  tmp="$(mktemp)"; printf 'the magic token is ZQ-91' > "$tmp"
  out=$("$BIN" --mode text --system-prompt "Reply with only the token." "@$tmp" "What is the magic token?"); rc=$?
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
  out=$("$BIN" --mode text --tools bash "Use the bash tool to run: echo TOOLS_WORK_91"); rc=$?
  ok "bash tool exit" "$rc" 0
  contains "bash tool executed end-to-end" "$out" "TOOLS_WORK_91"

  # Tool-calling: read round-trip
  tf="$(mktemp)"; printf 'SMOKE_FILE_MARKER_77' > "$tf"
  out=$("$BIN" --mode text --tools read "Use the read tool to read $tf and quote its contents."); rc=$?
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

  # ── Edit tool ────────────────────────────────────────────────────────────────
  echo "== edit / find / grep tools =="
  ef="$(mktemp)"; printf 'Hello World' > "$ef"
  out=$("$BIN" --tools edit "Use the edit tool to replace 'World' with 'Mars' in $ef"); rc=$?
  ok "edit tool exit" "$rc" 0
  if [ -f "$ef" ] && grep -q "Mars" "$ef"; then
    printf 'PASS  edit tool mutated file on disk\n'; pass=$((pass + 1))
  else
    printf 'FAIL  edit tool did not update file\n'; fail=$((fail + 1))
  fi
  rm -f "$ef"

  # ── Find tool ────────────────────────────────────────────────────────────────
  fdir="$(mktemp -d)"
  touch "$fdir/tau-FINDME99.txt"
  out=$("$BIN" --mode text --tools find "Use the find tool to find files matching the pattern 'FINDME99' under $fdir. Quote the exact filename you find."); rc=$?
  ok "find tool exit" "$rc" 0
  contains "find tool returns result" "$out" "FINDME99"
  rm -rf "$fdir"

  # ── Grep tool ────────────────────────────────────────────────────────────────
  gf="$(mktemp)"; printf 'GREP_NEEDLE_42 is the answer' > "$gf"
  out=$("$BIN" --mode text --tools grep "Use the grep tool to search for GREP_NEEDLE_42 in $gf. Quote the matching line exactly."); rc=$?
  ok "grep tool exit" "$rc" 0
  contains "grep tool finds pattern" "$out" "GREP_NEEDLE_42"
  rm -f "$gf"

  # ── --dry-run: tool reported, not executed ────────────────────────────────────
  echo "== dry-run / iteration cap / no-tools =="
  dry_file="/tmp/tau-dryrun-$$-shouldnotexist"
  out=$("$BIN" --dry-run --tools bash "Use bash to run: touch $dry_file"); rc=$?
  ok "dry-run exit" "$rc" 0
  if [ ! -f "$dry_file" ]; then
    printf 'PASS  dry-run: no side effect on disk\n'; pass=$((pass + 1))
  else
    printf 'FAIL  dry-run: file was created (should not be)\n'; fail=$((fail + 1))
    rm -f "$dry_file"
  fi

  # ── --max-iterations backstop ─────────────────────────────────────────────────
  # max-iterations=1: model gets exactly 1 tool call, then is forced to give a
  # final text answer. Should still exit 0 (forced-answer path).
  out=$("$BIN" --max-iterations 1 --tools bash "Use bash to run 'echo HI', then summarize the output."); rc=$?
  ok "--max-iterations=1 backstop exit" "$rc" 0

  # ── --no-tools: model answers without tools ───────────────────────────────────
  out=$("$BIN" --no-tools "What is 2+2? Reply with just the number."); rc=$?
  ok "--no-tools exit" "$rc" 0
  contains "--no-tools model still answers" "$out" "4"

  # ── --append-system-prompt ────────────────────────────────────────────────────
  echo "== system prompt flags =="
  out=$("$BIN" --mode text --no-tools --append-system-prompt "CRITICAL: prefix every reply with APPENDED_99" "Reply with exactly: APPENDED_99"); rc=$?
  ok "--append-system-prompt exit" "$rc" 0
  contains "--append-system-prompt honored" "$out" "APPENDED_99"

  # ── --exclude-tools denylist ──────────────────────────────────────────────────
  # bash excluded; model should use ls tool. Use a small controlled directory
  # (not /tmp: 2600+ files → 87KB ls output → SystemResources on second API call)
  excl_dir="$(mktemp -d)"
  touch "$excl_dir/alpha.txt" "$excl_dir/beta.txt"
  out=$("$BIN" --mode text --exclude-tools bash "List files in $excl_dir using available tools. Say how many files there are."); rc=$?
  ok "--exclude-tools exit" "$rc" 0
  rm -rf "$excl_dir"

  # ── Large @file injection ─────────────────────────────────────────────────────
  echo "== large @file injection =="
  bigf="$(mktemp)"
  python3 -c "
filler = 'The following text is padding to make a large file. ' * 60
print(filler)
print('The magic token is: BIGFILE_TOKEN_77')
print(filler)
" > "$bigf"
  out=$("$BIN" --no-stream "@$bigf" "What is the magic token mentioned in the file? Reply with just the token."); rc=$?
  ok "large @file exit" "$rc" 0
  contains "large @file content reaches model" "$out" "BIGFILE_TOKEN_77"
  rm -f "$bigf"

  # ── Goal mode ─────────────────────────────────────────────────────────────────
  echo "== goal mode =="
  GSESS="smoke-goal-$$"
  gsess_file="$HOME/.config/tau/sessions/${GSESS}.json"
  goal_target="/tmp/tau-goal-target-$$"

  out=$("$BIN" --session "$GSESS" --tools bash,write,read \
    "/goal Create a file at $goal_target containing exactly: GOAL_SMOKE_OK"); rc=$?
  ok "goal mode exit" "$rc" 0
  if [ -f "$goal_target" ] && grep -q "GOAL_SMOKE_OK" "$goal_target"; then
    printf 'PASS  goal mode: file created with correct content\n'; pass=$((pass + 1))
  else
    printf 'FAIL  goal mode: file missing or wrong content\n'; fail=$((fail + 1))
  fi
  rm -f "$goal_target" "$gsess_file"

  # ── Goal mode: GOAL_MET sentinel stripped from terminal output ───────────────
  # Verify <GOAL_MET> does not appear in what tau prints (it is consumed internally)
  GSESS2="smoke-goalstrip-$$"
  gsess2_file="$HOME/.config/tau/sessions/${GSESS2}.json"
  goal_target2="/tmp/tau-goal-target2-$$"
  out=$("$BIN" --session "$GSESS2" --tools write \
    "/goal Write the word SENTINEL_STRIP_OK to $goal_target2")
  if printf '%s' "$out" | grep -q '<GOAL_MET>'; then
    printf 'FAIL  goal mode: <GOAL_MET> leaked to terminal output\n'; fail=$((fail + 1))
  else
    printf 'PASS  goal mode: <GOAL_MET> sentinel not visible in output\n'; pass=$((pass + 1))
  fi
  rm -f "$goal_target2" "$gsess2_file"

  # ── Multi-tool in a single turn ───────────────────────────────────────────────
  echo "== multi-tool turn =="
  mf1="$(mktemp)"; printf 'MULTI_A_11' > "$mf1"
  mf2="$(mktemp)"; printf 'MULTI_B_22' > "$mf2"
  out=$("$BIN" --mode text --tools read "Read both $mf1 and $mf2 and quote their exact contents on one line each."); rc=$?
  ok "multi-tool turn exit" "$rc" 0
  contains "multi-tool: first file content" "$out" "MULTI_A_11"
  contains "multi-tool: second file content" "$out" "MULTI_B_22"
  rm -f "$mf1" "$mf2"

else
  echo "(skipping network tests; pass --net to enable)"
fi

echo
echo "== summary: $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
