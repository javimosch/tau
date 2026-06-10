#!/usr/bin/env bash
# tau v0.3 feature smoke tests — Author↔Critic loop + Fleet orchestration.
#
# Usage:
#   scripts/smoke-features.sh            # online LLM tests (needs API key)
#   scripts/smoke-features.sh --offline  # deterministic offline CLI-only tests
#
# Exit 0 if all run tests pass, 1 otherwise.
set -u -o pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/zig-out/bin/tau"
MODE="${1:-online}"
[ "$MODE" = "--offline" ] && MODE=offline

pass=0
fail=0
skip=0

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

ok() {
  if [ "$2" = "$3" ]; then
    printf 'PASS  %s (exit %s)\n' "$1" "$2"
    pass=$((pass + 1))
  else
    printf 'FAIL  %s (got exit %s, want %s)\n' "$1" "$2" "$3"
    fail=$((fail + 1))
  fi
}

contains() {
  case "$2" in
    *"$3"*) printf 'PASS  %s\n' "$1"; pass=$((pass + 1)) ;;
    *)      printf 'FAIL  %s (missing %q)\n' "$1" "$3"; fail=$((fail + 1)) ;;
  esac
}

skip_test() {
  printf 'SKIP  %s\n' "$1"
  skip=$((skip + 1))
}

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------

if [ ! -x "$BIN" ]; then
  echo "building tau..."
  ( cd "$ROOT" && zig build ) || { echo "build failed"; exit 1; }
fi

# Ensure tau is on PATH for fleet worker spawns (fleet.zig invokes "tau").
export PATH="$ROOT/zig-out/bin:$PATH"

# Pre-check: does an API key exist? (for online tests)
has_key=false
if [ "$MODE" != "offline" ]; then
  for v in TAU_API_KEY XIAOMI_API_KEY PIZIG_API_KEY OPENAI_API_KEY DEEPSEEK_API_KEY; do
    if [ -n "${!v:-}" ]; then has_key=true; break; fi
  done
  # Also check config file
  if [ -f "$HOME/.config/tau/config.json" ] && grep -q '"api_key"' "$HOME/.config/tau/config.json" 2>/dev/null; then
    has_key=true
  fi
  if ! $has_key; then
    echo "WARNING: No API key found in env or config. Online tests will be skipped."
    echo "  Set TAU_API_KEY, XIAOMI_API_KEY, or OPENAI_API_KEY, or add api_key to ~/.config/tau/config.json"
  fi
fi

# ===========================================================================
# Offline section (deterministic CLI parsing tests)
# ===========================================================================
echo "== offline: help text coverage =="

out=$("$BIN" --help 2>&1)
contains "--help mentions --role" "$out" "--role"
contains "--help mentions fleet run" "$out" "fleet run"
contains "--help mentions fleet status" "$out" "fleet status"
contains "--help mentions fleet cancel" "$out" "fleet cancel"
contains "--help mentions fleet logs" "$out" "fleet logs"
contains "--help mentions fleet list" "$out" "fleet list"

echo "== offline: --role flag parsing =="
"$BIN" --role invalid "x" >/dev/null 2>&1;       ok "--role invalid -> invalid_argument" "$?" 80
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

echo "== offline: fleet subcommand parsing =="
"$BIN" fleet >/dev/null 2>&1;                   ok "fleet (no sub) -> invalid_argument" "$?" 80
"$BIN" fleet bogus >/dev/null 2>&1;             ok "fleet bogus -> invalid_argument" "$?" 80
"$BIN" fleet run >/dev/null 2>&1;               ok "fleet run without --goal -> missing_required_field" "$?" 82
"$BIN" fleet status >/dev/null 2>&1;            ok "fleet status no id -> invalid_argument" "$?" 80
"$BIN" fleet cancel >/dev/null 2>&1;            ok "fleet cancel no id -> invalid_argument" "$?" 80
"$BIN" fleet logs >/dev/null 2>&1;              ok "fleet logs no id -> invalid_argument" "$?" 80

nonex_id="smoke-ft-nonexistent-$$-$RANDOM"
out=$("$BIN" fleet status "$nonex_id" 2>&1)
if [ $? -eq 0 ] && printf '%s' "$out" | grep -q '"fleet":null'; then
  printf 'PASS  fleet status nonexistent -> {"fleet":null}\n'; pass=$((pass + 1))
else
  printf 'FAIL  fleet status nonexistent: %s\n' "$out"; fail=$((fail + 1))
fi

out=$("$BIN" fleet cancel "$nonex_id" 2>&1)
if [ $? -eq 0 ] && printf '%s' "$out" | grep -q '"fleet":null'; then
  printf 'PASS  fleet cancel nonexistent -> {"fleet":null}\n'; pass=$((pass + 1))
else
  printf 'FAIL  fleet cancel nonexistent: %s\n' "$out"; fail=$((fail + 1))
fi

out=$("$BIN" fleet logs "$nonex_id" 2>&1)
if [ $? -eq 0 ] && printf '%s' "$out" | grep -q '"note"'; then
  printf 'PASS  fleet logs nonexistent -> note\n'; pass=$((pass + 1))
else
  printf 'FAIL  fleet logs nonexistent: %s\n' "$out"; fail=$((fail + 1))
fi

out=$("$BIN" fleet list 2>&1)
if [ $? -eq 0 ] && printf '%s' "$out" | grep -q '"fleets":'; then
  printf 'PASS  fleet list -> exit 0 with fleets array\n'; pass=$((pass + 1))
else
  printf 'FAIL  fleet list: %s\n' "$out"; fail=$((fail + 1))
fi

echo "== offline: fleet flag parsing =="
"$BIN" fleet run --goal "test" --coordinator-model openai/gpt-4o-mini >/dev/null 2>&1; rc=$?
if [ "$rc" != "80" ]; then
  printf 'PASS  fleet run --coordinator-model accepted by parser (exit %s)\n' "$rc"
  pass=$((pass + 1))
else
  printf 'FAIL  fleet run --coordinator-model rejected by parser\n'
  fail=$((fail + 1))
fi

"$BIN" fleet run --goal "test" --sequential >/dev/null 2>&1; rc=$?
if [ "$rc" != "80" ]; then
  printf 'PASS  fleet run --sequential accepted by parser (exit %s)\n' "$rc"
  pass=$((pass + 1))
else
  printf 'FAIL  fleet run --sequential rejected by parser\n'
  fail=$((fail + 1))
fi

"$BIN" fleet run --goal "test" --parallel >/dev/null 2>&1; rc=$?
if [ "$rc" != "80" ]; then
  printf 'PASS  fleet run --parallel accepted by parser (exit %s)\n' "$rc"
  pass=$((pass + 1))
else
  printf 'FAIL  fleet run --parallel rejected by parser\n'
  fail=$((fail + 1))
fi

"$BIN" fleet run --goal "test" --worker-model openai/gpt-4o-mini >/dev/null 2>&1; rc=$?
if [ "$rc" != "80" ]; then
  printf 'PASS  fleet run --worker-model accepted by parser (exit %s)\n' "$rc"
  pass=$((pass + 1))
else
  printf 'FAIL  fleet run --worker-model rejected by parser\n'
  fail=$((fail + 1))
fi

"$BIN" fleet run --goal "x" --bogus >/dev/null 2>&1;   ok "fleet run --bogus -> invalid_argument" "$?" 80

# ===========================================================================
# Online section (LLM calls)
# ===========================================================================
if [ "$MODE" = "offline" ]; then
  echo
  echo "== summary: $pass passed, $fail failed, $skip skipped =="
  [ "$fail" -eq 0 ]
  exit
fi

if ! $has_key; then
  skip_test "all online tests (no API key)"
  echo
  echo "== summary: $pass passed, $fail failed, $skip skipped =="
  [ "$fail" -eq 0 ]
  exit
fi

echo
echo "== online: 1. baseline say-hi =="

out=$("$BIN" --mode text --no-tools --no-stream "Reply with exactly: HI_TAU_BASELINE_42" 2>&1)
rc=$?
if [ "$rc" = "106" ]; then
  skip_test "baseline say-hi (auth failed)"
else
  ok "baseline say-hi exit" "$rc" 0
  contains "baseline returns marker" "$out" "HI_TAU_BASELINE_42"
fi

echo
echo "== online: 2. --role author sentinel check =="

out=$("$BIN" --role author --no-tools --no-stream --mode text \
  "Reply with exactly: ACK. Then emit <READY_FOR_REVIEW> on its own line." 2>&1)
rc=$?
if [ "$rc" = "106" ]; then
  skip_test "--role author sentinel (auth failed)"
else
  ok "--role author text exit" "$rc" 0
  if printf '%s' "$out" | grep -q '<READY_FOR_REVIEW>'; then
    printf 'PASS  --role author emitted READY_FOR_REVIEW\n'; pass=$((pass + 1))
  else
    printf 'WARN  --role author did not emit sentinel (needs more turns)\n'
  fi
fi

echo
echo "== online: 3. --role author tools (create file + sentinel) =="

afile="$(mktemp -u)"
asess="smoke-author-$$"
out=$("$BIN" --role author --tools bash,write,read --session "$asess" --mode text \
  "Create a file at $afile containing exactly: AUTHOR_TOOL_SMOKE_OK. Then emit <READY_FOR_REVIEW>." 2>&1)
rc=$?
if [ "$rc" = "106" ]; then
  skip_test "--role author tools (auth failed)"
else
  ok "--role author tools exit" "$rc" 0
  if [ -f "$afile" ] && grep -q "AUTHOR_TOOL_SMOKE_OK" "$afile"; then
    printf 'PASS  --role author created file with correct content\n'; pass=$((pass + 1))
  else
    printf 'WARN  --role author did not create expected file (may need more iterations)\n'
  fi
fi
rm -f "$afile"
rm -f "$HOME/.config/tau/sessions/${asess}.json"

echo
echo "== online: 4. --role critic read-only review =="

creview="$(mktemp)"
printf 'def add(a,b): return a+b\n' > "$creview"
csess="smoke-critic-$$"
out=$("$BIN" --role critic --tools read,grep,ls,find --session "$csess" --mode text \
  "Review $creview. It contains a simple add function. Emit <APPROVED> if correct, or <BLOCKED> if you find defects." 2>&1)
rc=$?
if [ "$rc" = "106" ]; then
  skip_test "--role critic review (auth failed)"
else
  ok "--role critic exit" "$rc" 0
  if printf '%s' "$out" | grep -q '<APPROVED>'; then
    printf 'PASS  --role critic emitted APPROVED\n'; pass=$((pass + 1))
  elif printf '%s' "$out" | grep -q '<BLOCKED>'; then
    printf 'PASS  --role critic emitted BLOCKED\n'; pass=$((pass + 1))
  else
    printf 'WARN  --role critic did not emit verdict sentinel\n'
  fi
fi
rm -f "$creview"
rm -f "$HOME/.config/tau/sessions/${csess}.json"

echo
echo "== online: 5. Author↔Critic micro-loop (manual) =="

loop_file="$(mktemp -u)"
loop_prefix="smoke-acloop-$$"
out=$("$BIN" --role author --tools write,read,bash --session "${loop_prefix}" --mode text \
  "Create a file at $loop_file containing exactly: AC_LOOP_OK_77. Then emit <READY_FOR_REVIEW>." 2>&1)
rc=$?
if [ "$rc" = "106" ]; then
  skip_test "Author↔Critic loop (auth failed)"
else
  ok "A/C loop: author turn exit" "$rc" 0
  if printf '%s' "$out" | grep -q '<READY_FOR_REVIEW>'; then
    printf 'PASS  A/C loop: author emitted READY\n'; pass=$((pass + 1))
  else
    printf 'WARN  A/C loop: author did not emit READY\n'
  fi

  if [ -f "$loop_file" ]; then
    out=$("$BIN" --role critic --tools read,grep,ls --session "${loop_prefix}" --mode text \
      "Review $loop_file. It should contain 'AC_LOOP_OK_77'. Emit <APPROVED> if correct, <BLOCKED> otherwise." 2>&1)
    rc=$?
    ok "A/C loop: critic turn exit" "$rc" 0
    if printf '%s' "$out" | grep -q '<APPROVED>'; then
      printf 'PASS  A/C loop: critic APPROVED\n'; pass=$((pass + 1))
    elif printf '%s' "$out" | grep -q '<BLOCKED>'; then
      printf 'WARN  A/C loop: critic BLOCKED (unexpected for correct file)\n'
    else
      printf 'WARN  A/C loop: critic did not emit verdict\n'
    fi
  fi
fi
rm -f "$loop_file"
# Clean up all session files for this prefix (may have multiple iteration files)
rm -f "$HOME/.config/tau/sessions/${loop_prefix}-author-"*.json \
      "$HOME/.config/tau/sessions/${loop_prefix}-critic-"*.json

echo
echo "== online: 6. tau fleet run (coordinator + workers) =="

fleet_out=$("$BIN" fleet run --goal "Create a file /tmp/tau-fleet-smoke-OK.txt with exactly the word FLEET_OK_99" 2>&1)
rc=$?
if [ "$rc" = "106" ]; then
  skip_test "fleet run (auth failed)"
elif [ "$rc" = "110" ]; then
  printf 'WARN  fleet run coordinator error (exit 110): %s\n' "$fleet_out"
else
  ok "fleet run exit" "$rc" 0
  # Extract fleet id from JSON output
  fleet_id=$(printf '%s' "$fleet_out" | python3 -c 'import sys,json; print(json.load(sys.stdin)["fleet"]["id"])' 2>/dev/null || echo "")
  if [ -n "$fleet_id" ]; then
    printf 'PASS  fleet run returned fleet id: %s\n' "$fleet_id"; pass=$((pass + 1))

    # 6a. fleet status
    status_out=$("$BIN" fleet status "$fleet_id" 2>&1)
    if [ $? -eq 0 ] && printf '%s' "$status_out" | grep -q '"items"'; then
      printf 'PASS  fleet status returns manifest with items\n'; pass=$((pass + 1))
    else
      printf 'FAIL  fleet status: %s\n' "$status_out"; fail=$((fail + 1))
    fi

    # 6b. fleet list includes our fleet
    list_out=$("$BIN" fleet list 2>&1)
    if printf '%s' "$list_out" | grep -q "$fleet_id"; then
      printf 'PASS  fleet list includes new fleet\n'; pass=$((pass + 1))
    else
      printf 'WARN  fleet list may not include new fleet (race): %s\n' "$list_out"
    fi

    # 6c. fleet logs hint
    logs_out=$("$BIN" fleet logs "$fleet_id" 2>&1)
    if [ $? -eq 0 ] && printf '%s' "$logs_out" | grep -q '"note"'; then
      printf 'PASS  fleet logs returns session hint\n'; pass=$((pass + 1))
    else
      printf 'FAIL  fleet logs: %s\n' "$logs_out"; fail=$((fail + 1))
    fi

    # 6d. fleet cancel (persists cancelled status)
    cancel_out=$("$BIN" fleet cancel "$fleet_id" 2>&1)
    if [ $? -eq 0 ] && printf '%s' "$cancel_out" | grep -q '"cancelled"'; then
      printf 'PASS  fleet cancel updates global_status to cancelled\n'; pass=$((pass + 1))
    else
      printf 'FAIL  fleet cancel: %s\n' "$cancel_out"; fail=$((fail + 1))
    fi

    # Clean up fleet manifest
    [ -n "$fleet_id" ] && rm -f "$HOME/.config/tau/fleets/${fleet_id}.json"
  fi
fi
rm -f /tmp/tau-fleet-smoke-OK.txt

echo
echo "== online: 7. --role author json mode with sentinel =="

out=$("$BIN" --role author --no-tools --no-stream --mode json \
  "Acknowledge you are the Author. Emit <READY_FOR_REVIEW> on its own line." 2>&1)
rc=$?
if [ "$rc" = "106" ]; then
  skip_test "--role author json (auth failed)"
else
  ok "--role author json exit" "$rc" 0
  if printf '%s' "$out" | python3 -c 'import sys,json; d=json.load(sys.stdin); assert d["content"]' 2>/dev/null; then
    printf 'PASS  --role author json has content field\n'; pass=$((pass + 1))
  else
    printf 'FAIL  --role author json malformed: %s\n' "$out"; fail=$((fail + 1))
  fi
fi

echo
echo "== online: 8. --role critic json mode with verdict =="

creview2="$(mktemp)"
printf 'const x = 1;\n' > "$creview2"
out=$("$BIN" --role critic --no-stream --mode json \
  "Review $creview2. It sets a constant. Emit <APPROVED>." 2>&1)
rc=$?
if [ "$rc" = "106" ]; then
  skip_test "--role critic json (auth failed)"
else
  ok "--role critic json exit" "$rc" 0
  if printf '%s' "$out" | python3 -c 'import sys,json; d=json.load(sys.stdin); c=d.get("content",""); assert "<APPROVED>" in c or "<BLOCKED>" in c' 2>/dev/null; then
    printf 'PASS  --role critic json contains verdict sentinel\n'; pass=$((pass + 1))
  else
    printf 'WARN  --role critic json may not contain sentinel\n'
  fi
fi
rm -f "$creview2"

echo
echo "== online: 9. author nudge on premature stop =="

nsess="smoke-nudge-$$"
out=$("$BIN" --role author --no-stream --mode text --max-iterations 1 --session "$nsess" \
  "You are an Author. Just say hello and stop. Do NOT emit <READY_FOR_REVIEW> yet." 2>&1)
rc=$?
if [ "$rc" = "106" ]; then
  skip_test "author nudge (auth failed)"
else
  ok "author nudge exit" "$rc" 0
  sfile="$HOME/.config/tau/sessions/${nsess}.json"
  if [ -f "$sfile" ]; then
    if python3 - "$sfile" <<'PYEOF' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
has_nudge = any("You stopped without emitting" in m["content"] for m in d["messages"] if m["role"] == "user")
sys.exit(0 if has_nudge else 1)
PYEOF
    then
      printf 'PASS  author nudge detected in session\n'; pass=$((pass + 1))
    else
      printf 'WARN  author nudge not found (one-shot may have succeeded)\n'
    fi
  fi
fi
rm -f "$HOME/.config/tau/sessions/${nsess}.json"

echo
echo "== online: 10. --role coordinator smoke =="

out=$("$BIN" --role coordinator --no-tools --no-stream --mode json \
  "Decompose this into work items: add a hello world endpoint. Output JSON with items array." 2>&1)
rc=$?
if [ "$rc" = "106" ]; then
  skip_test "--role coordinator (auth failed)"
else
  ok "--role coordinator exit" "$rc" 0
  if printf '%s' "$out" | python3 -c 'import sys,json; json.load(sys.stdin)' 2>/dev/null; then
    printf 'PASS  --role coordinator output is valid JSON\n'; pass=$((pass + 1))
  else
    printf 'WARN  --role coordinator output not valid JSON\n'
  fi
fi

echo
echo "== summary: $pass passed, $fail failed, $skip skipped =="
[ "$fail" -eq 0 ]
