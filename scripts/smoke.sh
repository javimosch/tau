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
BIN="$ROOT/zig-out/bin/pizig"
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
contains "--version says pizig" "$out" "pizig"

out=$("$BIN" --help); ok "--help exit" "$?" 0
contains "--help shows usage" "$out" "Usage:"

out=$("$BIN" --help-json)
if printf '%s' "$out" | python3 -c 'import sys,json;json.load(sys.stdin)' 2>/dev/null; then
  printf 'PASS  --help-json is valid JSON\n'; pass=$((pass + 1))
else
  printf 'FAIL  --help-json is not valid JSON\n'; fail=$((fail + 1))
fi

"$BIN" -p >/dev/null 2>&1;                       ok "no prompt -> missing_required_field" "$?" 82
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
else
  echo "(skipping network tests; pass --net to enable)"
fi

echo
echo "== summary: $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
