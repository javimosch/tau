#!/usr/bin/env bash
# tau smoke test harness — revised modular version.
#
# Usage:
#   scripts/smoke.sh                         # offline CLI tests only
#   scripts/smoke.sh --net                   # also run real LLM calls
#   scripts/smoke.sh --bench                 # run benchmarks after tests
#   scripts/smoke.sh --group "help,fleet"    # run specific test groups
#   scripts/smoke.sh --group=fleet           # same, = form is also accepted
#   scripts/smoke.sh --list-groups           # list available test groups
#   scripts/smoke.sh --config ./my-config    # use custom config
#
# Note: the default offline run includes the "bench" regression guard
# (marked :slow in ALL_TEST_GROUPS), which recursively runs the smoke
# harness with --bench and adds ~10s. To skip it during fast iteration,
# list the fast groups explicitly (use --list-groups to see all):
#   scripts/smoke.sh --group=help,flags,role,...
#
# Exit 0 if all run tests pass, 1 otherwise.
#
# Environment variables:
#   SMOKE_DEBUG=1          verbose debug output
#   SMOKE_TRACE=1          bash -x tracing
#   SMOKE_VERBOSE=1        print test names as they run
#   SMOKE_LOG=/path/log    append all smoke output to file
#   SMOKE_GROUPS="group1,group2"  filter test groups
#   TAU_BIN=/path/to/tau   override binary path
#
# ---------------------------------------------------------------------------
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB="$SCRIPT_DIR/lib/smoke-lib.sh"

# Source the shared library
if [ ! -f "$LIB" ]; then
  echo "FATAL: shared library not found at $LIB" >&2
  exit 1
fi
source "$LIB"

# ── Test group counters (caller-owned, consumed by lib helpers) ────────────
# The lib's helpers (ok, contains, skip_test) and print_summary expect these
# to be initialized by the caller. Under `set -u`, arithmetic on unset vars
# aborts, so we must declare them here — matching the smoke-features.sh
# convention.
pass=0
fail=0
skip=0

# ── Test group registry (declared early so --list-groups works) ───────────
# Format: "name:function_name[:network]". The optional :network marker means
# the group requires network + an API key; it will be skipped otherwise.
# This is the single source of truth — the dispatch loops below derive from it.
ALL_TEST_GROUPS=(
  "help:test_group_help"
  "flags:test_group_flag_parsing"
  "role:test_group_role_offline"
  "fleet:test_group_fleet"
  "issue11:test_group_issue11_flags"
  "model:test_group_model_shorthand"
  "acp:test_group_acp"
  "config-file:test_group_config_file"
  "goal:test_group_goal_offline"
  "dry-run:test_group_dry_run"
  "at-file-system-prompt:test_group_at_file_system_prompt"
  "scan-agents:test_group_scan_agents"
  "session-validation:test_group_session_name_validation"
  "fleet-items:test_group_fleet_items"
  "invalid-numeric:test_group_invalid_numeric"
  "fleet-flags:test_group_fleet_flags"
  "bench:test_group_bench_smoke:slow"
  "baseline:test_group_network_baseline:network"
  "json-mode:test_group_network_json_mode:network"
  "at-file:test_group_network_at_file:network"
  "streaming:test_group_network_streaming:network"
  "tools:test_group_network_tools:network"
  "session:test_group_network_session:network"
  "compaction:test_group_network_compaction:network"
  "edit-tool:test_group_network_edit_tool:network"
  "find-grep:test_group_network_find_grep_tools:network"
  "dry-run-no-side:test_group_network_dry_run_no_side_effect:network"
  "max-iterations:test_group_network_max_iterations:network"
  "no-tools:test_group_network_no_tools:network"
  "system-prompt:test_group_network_system_prompt_flags:network"
  "exclude-tools:test_group_network_exclude_tools:network"
  "large-file:test_group_network_large_file_injection:network"
  "goal-mode:test_group_network_goal_mode:network"
  "goal-strip:test_group_network_goal_sentinel_strip:network"
  "multi-tool:test_group_network_multi_tool_turn:network"
  "ls-tool:test_group_network_ls_tool:network"
  "role-critic:test_group_network_role_critic:network"
)

# ── Configuration ──────────────────────────────────────────────────────────
load_config "$SCRIPT_DIR"

# Defaults (may be overridden by config or environment)
BIN="${TAU_BIN:-"$ROOT/zig-out/bin/tau"}"
NET="${SMOKE_NET:-0}"
RUN_BENCH="${SMOKE_BENCH:-0}"
CLEANUP="${SMOKE_CLEANUP:-1}"

# Parse CLI arguments (must come before env overrides)
while [ $# -gt 0 ]; do
  case "$1" in
    --net)        NET=1 ;;
    --bench)      RUN_BENCH=1 ;;
    --no-cleanup) CLEANUP=0 ;;
    --list-groups) list_test_groups; exit 0 ;;
    --group|--group=*)
      if [ "$1" = "--group" ]; then
        shift; SMOKE_GROUPS="${1:-}"
      else
        SMOKE_GROUPS="${1#--group=}"
      fi
      [ -z "$SMOKE_GROUPS" ] && bail_out "--group requires a non-empty value (comma-separated group names)"
      export SMOKE_GROUPS
      ;;
    --config|--config=*)
      if [ "$1" = "--config" ]; then
        shift; [ -f "${1:-}" ] && source "$1"
      else
        cfg="${1#--config=}"
        [ -f "$cfg" ] && source "$cfg"
      fi
      ;;
    --help|-h)
      sed -ne '/^# Usage:/,/^# -----/p' "$0" | sed 's/^# \?//'
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      echo "Usage: $0 [--net] [--bench] [--group <groups>] [--list-groups] [--config <file>]" >&2
      exit 1
      ;;
  esac
  shift
done

# ── Runtime setup ─────────────────────────────────────────────────────────

# Check binary
check_binary "$BIN" "$ROOT" || bail_out "binary check failed"

# Ensure tau is on PATH for fleet worker spawns
export PATH="$ROOT/zig-out/bin:$PATH"

# Check API key availability
has_key=false
check_api_key || true  # don't abort; we'll skip network tests

# Setup temp dir
setup_temp

# Trap for cleanup
cleanup() {
  local rc=$?
  if [ "$CLEANUP" = "1" ]; then
    cleanup_temp
    # Clean up smoke sessions/fleets
    cleanup_sessions "smoke-*"
    cleanup_fleets "smoke-*"
  fi
  # Restore terminal settings if needed
  exit $rc
}
trap cleanup EXIT INT TERM

# ── TAP plan (will be updated dynamically) ────────────────────────────────
# We emit plan at the end with total count. Start with a note.
echo "# tau smoke test harness"
echo "# binary: $BIN"
echo "# network tests: $([ "$NET" = 1 ] && echo enabled || echo disabled)"
echo "# date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo

# ═══════════════════════════════════════════════════════════════════════════
# Test Groups
# ═══════════════════════════════════════════════════════════════════════════

# ok_parser_accepted <name> <exit_code>
# When a test uses a fake API key, the parser has accepted the arguments as
# long as the exit code is not 80 (invalid_argument). Auth/network failures
# downstream exit 106/110 and are still a parser-acceptance pass.
ok_parser_accepted() {
  local name="$1"
  local rc="$2"
  if [ "$rc" != "80" ]; then
    ok "$name accepted by parser (downstream exit $rc)" 0 0
  else
    ok "$name rejected by parser" 1 0
  fi
}

# Group: version and help
test_group_help() {
  local out

  out=$("$BIN" --version); ok "--version exit" "$?" 0
  contains "--version says tau" "$out" "tau"

  out=$("$BIN" --help); ok "--help exit" "$?" 0
  contains "--help shows usage header" "$out" "Usage:"
  contains "--help mentions tau" "$out" "tau"

  out=$("$BIN" --help-json)
  if printf '%s' "$out" | python3 -c 'import sys,json;json.load(sys.stdin)' 2>/dev/null; then
    ok "--help-json is valid JSON" 0 0
  else
    ok "--help-json is not valid JSON" 1 0
  fi
}

# Group: basic flag parsing
test_group_flag_parsing() {
  local out rc

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

  # --exclude-tools multi-tool CSV parsing (#20)
  # Use fake key to auth-fail fast at exit 106 (still != 80 = parser accepted)
  "$BIN" --exclude-tools bash,write --no-stream --api-key fake --provider openai "x" >/dev/null 2>&1; rc=$?
  if [ "$rc" != "80" ]; then
    ok "--exclude-tools multi-tool CSV accepted (exit $rc)" 0 0
  else
    ok "--exclude-tools multi-tool CSV rejected" 1 0
  fi
}

# Group: --role flag (offline parser check)
# Use --api-key fake --provider openai so auth fails fast at exit 106 (still != 80).
# This avoids making slow LLM calls via the configured provider.
test_group_role_offline() {
  local rc

  note "--role flag parsing"
  "$BIN" --role invalid "x" >/dev/null 2>&1;       ok "--role invalid -> invalid_argument" "$?" 80
  for r in author critic coordinator none; do
    "$BIN" --role "$r" --no-tools --no-stream --api-key fake --provider openai "x" >/dev/null 2>&1
    rc=$?
    ok_parser_accepted "--role $r" "$rc"
  done
}

# Group: fleet subcommands
test_group_fleet() {
  local out rc nonex_id

  note "fleet subcommand parsing"

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
  # logs without id -> invalid_argument
  "$BIN" fleet logs >/dev/null 2>&1;              ok "fleet logs no id -> invalid_argument" "$?" 80

  # status of nonexistent id -> exit 0, prints {"fleet":null}
  nonex_id="smoke-nonexistent-$$-$RANDOM"
  capture fleet_status "$BIN" fleet status "$nonex_id" 2>&1
  if [ "$fleet_status_rc" -eq 0 ] && printf '%s' "$fleet_status_out" | grep -q '"fleet":null'; then
    ok "fleet status nonexistent -> {\"fleet\":null}" 0 0
  else
    ok "fleet status nonexistent (got rc=$fleet_status_rc)" 1 0
    [ "$SMOKE_DEBUG" = "1" ] && diag "output: $fleet_status_out"
  fi

  # cancel of nonexistent id -> exit 0, prints {"fleet":null}
  capture fleet_cancel "$BIN" fleet cancel "$nonex_id" 2>&1
  if [ "$fleet_cancel_rc" -eq 0 ] && printf '%s' "$fleet_cancel_out" | grep -q '"fleet":null'; then
    ok "fleet cancel nonexistent -> {\"fleet\":null}" 0 0
  else
    ok "fleet cancel nonexistent (got rc=$fleet_cancel_rc)" 1 0
  fi

  # list -> exit 0, prints {"fleets":[...]}
  capture fleet_list "$BIN" fleet list 2>&1
  if [ "$fleet_list_rc" -eq 0 ] && printf '%s' "$fleet_list_out" | grep -q '"fleets":'; then
    ok "fleet list -> exit 0 with fleets array" 0 0
  else
    ok "fleet list (got rc=$fleet_list_rc)" 1 0
  fi

  # Help text mentions --role and fleet subcommands
  local help_out
  help_out=$("$BIN" --help 2>&1)
  contains "--help mentions --role" "$help_out" "--role"
  contains "--help mentions fleet run" "$help_out" "fleet run"
  contains "--help mentions fleet status" "$help_out" "fleet status"
  contains "--help mentions fleet cancel" "$help_out" "fleet cancel"
  contains "--help mentions fleet logs" "$help_out" "fleet logs"
  contains "--help mentions fleet list" "$help_out" "fleet list"
}

# Group: Issue #11 flags
# Use --api-key fake --provider openai for "accepted by parser" tests so auth
# fails fast at exit 106 (still != 80), avoiding slow LLM calls.
test_group_issue11_flags() {
  local rc

  note "flag parsing: --thinking, --debug, --max-tokens, --timeout-ms, --api-key"

  # --thinking accepted by parser
  "$BIN" --thinking --no-tools --no-stream --api-key fake --provider openai "x" >/dev/null 2>&1; rc=$?
  if [ "$rc" != "80" ]; then
    ok "--thinking accepted by parser (exit $rc)" 0 0
  else
    ok "--thinking rejected by parser" 1 0
  fi

  # --debug accepted by parser
  "$BIN" --debug --no-tools --no-stream --api-key fake --provider openai "x" >/dev/null 2>&1; rc=$?
  if [ "$rc" != "80" ]; then
    ok "--debug accepted by parser (exit $rc)" 0 0
  else
    ok "--debug rejected by parser" 1 0
  fi

  # --max-tokens bad value -> exit 80
  "$BIN" --max-tokens bad "x" >/dev/null 2>&1; ok "bad --max-tokens -> exit 80" "$?" 80
  # --max-tokens valid value accepted (fake key for fast auth fail)
  "$BIN" --max-tokens 1000 --no-tools --no-stream --api-key fake --provider openai "x" >/dev/null 2>&1; rc=$?
  if [ "$rc" != "80" ]; then
    ok "--max-tokens 1000 accepted (exit $rc)" 0 0
  else
    ok "--max-tokens 1000 rejected" 1 0
  fi

  # --timeout-ms bad value -> exit 80
  "$BIN" --timeout-ms bad "x" >/dev/null 2>&1; ok "bad --timeout-ms -> exit 80" "$?" 80
  # --timeout-ms valid value accepted (fake key for fast auth fail)
  "$BIN" --timeout-ms 5000 --no-tools --no-stream --api-key fake --provider openai "x" >/dev/null 2>&1; rc=$?
  if [ "$rc" != "80" ]; then
    ok "--timeout-ms 5000 accepted (exit $rc)" 0 0
  else
    ok "--timeout-ms 5000 rejected" 1 0
  fi

  # --api-key no value -> exit 80
  "$BIN" --api-key >/dev/null 2>&1; ok "--api-key no value -> exit 80" "$?" 80
}

# Group: Issue #12 --model shorthand
test_group_model_shorthand() {
  local rc

  note "--model provider/id shorthand"

  # Valid provider/model shorthand accepted (fake key for fast auth fail)
  "$BIN" --model openai/gpt-4o-mini --no-tools --no-stream --api-key fake "x" >/dev/null 2>&1; rc=$?
  if [ "$rc" != "80" ]; then
    ok "--model openai/gpt-4o-mini accepted (exit $rc)" 0 0
  else
    ok "--model openai/gpt-4o-mini rejected" 1 0
  fi

  # Invalid provider in shorthand rejected
  "$BIN" --model nope/some-model "x" >/dev/null 2>&1; ok "--model nope/some-model -> unknown provider" "$?" 80
}

# Group: Issue #13 ACP subcommand
test_group_acp() {
  local out rc

  note "ACP subcommand parsing"

  "$BIN" acp bogus >/dev/null 2>&1; ok "acp bogus -> invalid_argument" "$?" 80

  # acp status accepted by parser (exit 0 if not running)
  capture acp_status "$BIN" acp status 2>&1
  if [ "$acp_status_rc" = "0" ] && printf '%s' "$acp_status_out" | grep -q '"acp"'; then
    ok "acp status -> exit 0 with acp JSON" 0 0
  else
    ok "acp status: exit $acp_status_rc" 1 0
  fi
  # Verify status reports running:false when not running
  if printf '%s' "$acp_status_out" | grep -q '"running":false'; then
    ok "acp status reports running:false" 0 0
  else
    ok "acp status missing running:false" 1 0
  fi

  # acp stop accepted by parser (exit 0 if not running)
  capture acp_stop "$BIN" acp stop 2>&1
  if [ "$acp_stop_rc" = "0" ] && printf '%s' "$acp_stop_out" | grep -q '"acp"'; then
    ok "acp stop -> exit 0 with acp JSON" 0 0
  else
    ok "acp stop: exit $acp_stop_rc" 1 0
  fi

  # acp serve --max-iterations: bad value rejected at parse time
  "$BIN" acp serve --max-iterations bad >/dev/null 2>&1; ok "acp serve --max-iterations bad -> exit 80" "$?" 80

  # acp serve --acp-socket flag recognized by parser (combine with bad flag to avoid hanging)
  "$BIN" acp serve --acp-socket /tmp/tau-test.sock --max-iterations bad >/dev/null 2>&1; rc=$?
  if [ "$rc" = "80" ]; then
    ok "acp serve --acp-socket recognized (parse error on bad --max-iterations, exit 80)" 0 0
  else
    ok "acp serve --acp-socket recognized (exit $rc)" 1 0
  fi
}

# Group: Issue #14 config file loading + CLI override
test_group_config_file() {
  local rc mock_home mock_config

  note "config file loading and CLI override precedence"

  mock_home="$(mktemp -d)"
  register_temp_dir "$mock_home"
  mock_config="$mock_home/.config/tau"
  mkdir -p "$mock_config"

  # Test 1: config file loads correctly (provider from config used)
  printf '{"provider":"openai"}' > "$mock_config/config.json"
  HOME="$mock_home" "$BIN" --api-key fake "x" >/dev/null 2>&1; rc=$?
  if [ "$rc" != "80" ]; then
    ok "config file provider loaded (openai + fake key → exit $rc, not 80)" 0 0
  else
    ok "config file provider loaded (exit 80 = parser rejected)" 1 0
  fi

  # Test 2: CLI overrides config file (--provider beats config)
  printf '{"provider":"nope"}' > "$mock_config/config.json"
  HOME="$mock_home" "$BIN" --provider openai --api-key fake "x" >/dev/null 2>&1; rc=$?
  if [ "$rc" != "80" ]; then
    ok "CLI --provider overrides config (openai + fake key → exit $rc, not 80)" 0 0
  else
    ok "CLI --provider overrides config (exit 80 = config nope rejected)" 1 0
  fi

  # Test 3: invalid JSON degrades gracefully (returns to defaults, doesn't exit 80)
  printf 'this is not valid json' > "$mock_config/config.json"
  HOME="$mock_home" "$BIN" --provider openai --api-key fake "x" >/dev/null 2>&1; rc=$?
  if [ "$rc" != "80" ]; then
    ok "invalid config JSON degrades gracefully (exit $rc, not 80)" 0 0
  else
    ok "invalid config JSON degrades gracefully" 1 0
  fi
}

# Group: Issue #17 goal mode subcommands offline
test_group_goal_offline() {
  local out rc GSESS_OFF sub sname

  note "goal mode subcommands (offline)"

  # /goal subcommands require --session
  "$BIN" "/goal status" >/dev/null 2>&1;   ok "/goal status without --session -> exit 80" "$?" 80
  "$BIN" "/goal pause" >/dev/null 2>&1;    ok "/goal pause without --session -> exit 80" "$?" 80
  "$BIN" "/goal resume" >/dev/null 2>&1;   ok "/goal resume without --session -> exit 80" "$?" 80
  "$BIN" "/goal clear" >/dev/null 2>&1;    ok "/goal clear without --session -> exit 80" "$?" 80
  "$BIN" "/goal complete" >/dev/null 2>&1; ok "/goal complete without --session -> exit 80" "$?" 80

  # /goal status with --session, no prior goal -> {"goal":null}
  GSESS_OFF="smoke-goal-offline-$$"
  capture goal_status "$BIN" --session "$GSESS_OFF" --no-tools --no-stream "/goal status" 2>&1
  ok "/goal status (no goal) exit" "$goal_status_rc" 0
  if printf '%s' "$goal_status_out" | grep -q '"goal":null'; then
    ok "/goal status (no goal) -> {\"goal\":null}" 0 0
  else
    ok "/goal status (no goal): unexpected output" 1 0
  fi
  cleanup_sessions "$GSESS_OFF"

  # /goal pause|resume|clear|complete with --session, no prior goal -> {"goal":null}
  for sub in pause resume clear complete; do
    sname="smoke-goal-off-${sub}-$$"
    capture goal_sub "$BIN" --session "$sname" --no-tools --no-stream "/goal $sub" 2>&1
    ok "/goal $sub (no goal) exit" "$goal_sub_rc" 0
    if printf '%s' "$goal_sub_out" | grep -q '"goal":null'; then
      ok "/goal $sub (no goal) -> {\"goal\":null}" 0 0
    else
      ok "/goal $sub (no goal): unexpected output" 1 0
    fi
    cleanup_sessions "$sname"
  done

  # /goal --tokens parsing (use --timeout-ms 1 so the LLM call fails fast)
  "$BIN" --no-tools --no-stream --timeout-ms 1 "/goal --tokens 250K test" >/dev/null 2>&1; rc=$?
  if [ "$rc" != "80" ]; then
    ok "/goal --tokens 250K accepted (exit $rc)" 0 0
  else
    ok "/goal --tokens 250K rejected" 1 0
  fi
}

# Group: Issue #18 --dry-run JSON format + error envelope
# Note: --dry-run makes one LLM planning turn, so it needs a valid API key.
# We use the configured provider for the dry-run JSON format test.
test_group_dry_run() {
  local dry_json err_env

  note "--dry-run JSON format + error envelope"

  # --dry-run output is valid JSON with expected fields
  # dry-run makes one LLM planning turn, so we need the configured API key.
  if $has_key; then
    capture dry_run "$BIN" --dry-run --tools bash "echo hello" 2>&1
    if printf '%s' "$dry_run_out" | python3 -c 'import sys,json; d=json.load(sys.stdin); assert d.get("dry_run") == True; assert isinstance(d.get("tool_calls"), list)' 2>/dev/null; then
      ok "--dry-run output is valid JSON with expected fields" 0 0
    else
      ok "--dry-run JSON format invalid" 1 0
      [ "$SMOKE_DEBUG" = "1" ] && diag "dry-run output: $dry_run_out"
    fi
  else
    skip_test "--dry-run JSON format" "no API key"
  fi

  # Error envelope JSON on stderr for invalid arguments (exit 80)
  capture err_env "$BIN" --bogus 2>&1 >/dev/null
  if printf '%s' "$err_env_err" | python3 -c 'import sys,json; d=json.load(sys.stdin); assert d.get("err",{}).get("code") == 80; assert d.get("err",{}).get("type") == "invalid_argument"' 2>/dev/null; then
    ok "error envelope code 80 has type invalid_argument" 0 0
  else
    ok "error envelope code 80 format invalid" 1 0
    [ "$SMOKE_DEBUG" = "1" ] && diag "error envelope: $err_env_err"
  fi

  # Error envelope for missing required field (exit 82)
  # fleet run without --goal writes to stdout via fleetRequires (term.out, not term.err)
  capture err_82 "$BIN" fleet run 2>&1 >/dev/null
  if printf '%s' "$err_82_out" | python3 -c 'import sys,json; d=json.load(sys.stdin); assert d.get("err",{}).get("code") == 82' 2>/dev/null; then
    ok "error envelope code 82 exists" 0 0
  else
    ok "error envelope code 82 format invalid" 1 0
    [ "$SMOKE_DEBUG" = "1" ] && diag "error envelope 82: $err_82_out"
  fi

  # Error envelope for internal error (exit 110) triggered by fake API key
  capture err_110 "$BIN" --api-key fake --provider openai --no-tools --no-stream "x" 2>&1 >/dev/null
  if printf '%s' "$err_110_err" | python3 -c 'import sys,json; d=json.load(sys.stdin); assert d.get("err",{}).get("code") == 110' 2>/dev/null; then
    ok "error envelope code 110 has internal_error" 0 0
  else
    ok "error envelope code 110 format invalid" 1 0
    [ "$SMOKE_DEBUG" = "1" ] && diag "error envelope 110: $err_110_err"
  fi
}

# Group: --scan-agents JSON output (Issue: unescaped path/first_line broke machine output)
test_group_scan_agents() {
  local out rc tmpdir

  note "--scan-agents JSON validity"

  # Repo root should always contain AGENTS.md; output must be valid JSON.
  out=$("$BIN" --scan-agents); rc=$?
  ok "--scan-agents exit" "$rc" 0
  if printf '%s' "$out" | python3 -c 'import sys,json; d=json.load(sys.stdin); assert isinstance(d.get("agents_md_files"), list)' 2>/dev/null; then
    ok "--scan-agents output is valid JSON" 0 0
  else
    ok "--scan-agents output is not valid JSON" 1 0
    [ "$SMOKE_DEBUG" = "1" ] && diag "scan-agents output: $out"
  fi

  # Temp tree with special characters in the title must still produce valid JSON.
  tmpdir="$(mktemp -d)"
  register_temp_dir "$tmpdir"
  printf '# Title with "quotes" and \\ backslash\n\nBody\n' > "$tmpdir/AGENTS.md"
  out=$(cd "$tmpdir" && "$BIN" --scan-agents); rc=$?
  ok "--scan-agents special-chars exit" "$rc" 0
  if printf '%s' "$out" | python3 -c 'import sys,json; d=json.load(sys.stdin); fs=d["agents_md_files"]; assert len(fs)==1; assert "quotes" in fs[0]["first_line"]' 2>/dev/null; then
    ok "--scan-agents escapes special chars in first_line" 0 0
  else
    ok "--scan-agents special-chars JSON invalid" 1 0
    [ "$SMOKE_DEBUG" = "1" ] && diag "scan-agents special-chars output: $out"
  fi
}

# Group: Issue #16 multiple @file + repeatable --append-system-prompt
# Use --api-key fake --provider openai so auth fails fast at exit 106 (still != 80).
test_group_at_file_system_prompt() {
  local rc tmp1 tmp2

  note "multiple @file injection + --append-system-prompt repeatability"

  # Multiple @file injection: create two temp files, verify parser accepts multiple @ args
  tmp1="$(mktemp)"; printf 'content one' > "$tmp1"
  register_temp_file "$tmp1"
  tmp2="$(mktemp)"; printf 'content two' > "$tmp2"
  register_temp_file "$tmp2"
  "$BIN" "@$tmp1" "@$tmp2" --no-stream --api-key fake --provider openai "x" >/dev/null 2>&1; rc=$?
  if [ "$rc" != "80" ]; then
    ok "multiple @file injection accepted (exit $rc)" 0 0
  else
    ok "multiple @file injection rejected" 1 0
  fi

  # --append-system-prompt repeatability: verify multiple flags are accepted
  "$BIN" --append-system-prompt "Be concise" --append-system-prompt "Be accurate" --no-stream --api-key fake --provider openai "x" >/dev/null 2>&1; rc=$?
  if [ "$rc" != "80" ]; then
    ok "--append-system-prompt repeatable accepted (exit $rc)" 0 0
  else
    ok "--append-system-prompt repeatable rejected" 1 0
  fi
}

# Group: Issue #19 session name validation
# Note: tau's parser does NOT validate session names at parse time.
# Session name validation (validName) happens during load/save, which is
# after auth. So invalid names with --api-key fake will exit 106 (auth failed),
# not 80. We test that invalid names are accepted by the parser (!= 80).
test_group_session_name_validation() {
  local rc

  note "session name validation"

  # Empty session name: parser accepts it, but session load/save will handle it.
  # With fake key, auth fails first at exit 106 (still != 80 = parser accepted).
  "$BIN" --session "" --no-tools --no-stream --api-key fake --provider openai "x" >/dev/null 2>&1; rc=$?
  if [ "$rc" != "80" ]; then
    ok "empty session name accepted by parser (exit $rc)" 0 0
  else
    ok "empty session name rejected by parser" 1 0
  fi

  # Path traversal in session name: parser accepts it
  "$BIN" --session "../escape" --no-tools --no-stream --api-key fake --provider openai "x" >/dev/null 2>&1; rc=$?
  if [ "$rc" != "80" ]; then
    ok "../escape session name accepted by parser (exit $rc)" 0 0
  else
    ok "../escape session name rejected by parser" 1 0
  fi

  # Session name with spaces: parser accepts it
  "$BIN" --session "has space" --no-tools --no-stream --api-key fake --provider openai "x" >/dev/null 2>&1; rc=$?
  if [ "$rc" != "80" ]; then
    ok "session name with space accepted by parser (exit $rc)" 0 0
  else
    ok "session name with space rejected by parser" 1 0
  fi

  # Valid session name with hyphens/underscores accepted
  "$BIN" --session "my-test_123" --no-tools --no-stream --api-key fake --provider openai "/goal status" >/dev/null 2>&1; rc=$?
  if [ "$rc" != "80" ]; then
    ok "valid session name my-test_123 accepted (exit $rc)" 0 0
  else
    ok "valid session name rejected" 1 0
  fi
  cleanup_sessions "my-test_123"
}

# Group: Issue #21 / #23 fleet run --items
test_group_fleet_items() {
  local rc

  note "fleet run --items flag"

  # --items accepted by parser. No --api-key needed: --items skips the
  # coordinator LLM call, and empty items array fails before spawning workers.
  "$BIN" fleet run --goal test --items '{"items":[]}' >/dev/null 2>&1; rc=$?
  if [ "$rc" != "80" ]; then
    ok "fleet run --items accepted (exit $rc, not 80)" 0 0
  else
    ok "fleet run --items rejected" 1 0
  fi

  # --items with invalid JSON: graceful degradation (not exit 80)
  "$BIN" fleet run --goal test --items '{invalid}' >/dev/null 2>&1; rc=$?
  if [ "$rc" != "80" ]; then
    ok "fleet run --items invalid JSON degrades gracefully (exit $rc, not 80)" 0 0
  else
    ok "fleet run --items invalid JSON rejected as bad arg" 1 0
  fi
}

# Group: Issue #22 invalid numeric flag values
test_group_invalid_numeric() {
  note "invalid numeric flag values"

  "$BIN" --context-window bad "x" >/dev/null 2>&1; ok "bad --context-window -> exit 80" "$?" 80
  "$BIN" --compact-threshold bad "x" >/dev/null 2>&1; ok "bad --compact-threshold -> exit 80" "$?" 80
  "$BIN" --compact-keep-recent bad "x" >/dev/null 2>&1; ok "bad --compact-keep-recent -> exit 80" "$?" 80
  "$BIN" --goal-max-iterations bad "x" >/dev/null 2>&1; ok "bad --goal-max-iterations -> exit 80" "$?" 80
  "$BIN" --max-iterations bad "x" >/dev/null 2>&1;     ok "bad --max-iterations -> exit 80" "$?" 80
}

# Group: fleet flag parsing (from smoke-features)
# Use --api-key fake --provider openai so auth fails fast.
test_group_fleet_flags() {
  local rc

  note "fleet flag parsing"

  "$BIN" fleet run --goal "test" --coordinator-model openai/gpt-4o-mini --api-key fake --provider openai >/dev/null 2>&1; rc=$?
  if [ "$rc" != "80" ]; then
    ok "fleet run --coordinator-model accepted by parser (exit $rc)" 0 0
  else
    ok "fleet run --coordinator-model rejected by parser" 1 0
  fi

  "$BIN" fleet run --goal "test" --sequential --api-key fake --provider openai >/dev/null 2>&1; rc=$?
  if [ "$rc" != "80" ]; then
    ok "fleet run --sequential accepted by parser (exit $rc)" 0 0
  else
    ok "fleet run --sequential rejected by parser" 1 0
  fi

  "$BIN" fleet run --goal "test" --parallel --api-key fake --provider openai >/dev/null 2>&1; rc=$?
  if [ "$rc" != "80" ]; then
    ok "fleet run --parallel accepted by parser (exit $rc)" 0 0
  else
    ok "fleet run --parallel rejected by parser" 1 0
  fi

  "$BIN" fleet run --goal "test" --worker-model openai/gpt-4o-mini --api-key fake --provider openai >/dev/null 2>&1; rc=$?
  if [ "$rc" != "80" ]; then
    ok "fleet run --worker-model accepted by parser (exit $rc)" 0 0
  else
    ok "fleet run --worker-model rejected by parser" 1 0
  fi

  "$BIN" fleet run --goal "x" --bogus >/dev/null 2>&1;   ok "fleet run --bogus -> invalid_argument" "$?" 80
}

# Group: --bench regression guard
# Runs the smoke harness recursively with --bench, asserts a benchmark CSV
# row is emitted. Prevents --bench from silently regressing to dead-code
# state (where the flag is parsed but run_benchmarks is never wired up).
test_group_bench_smoke() {
  local out rc; out=$("$ROOT/scripts/smoke.sh" --bench --group=help 2>&1); rc=$?
  if printf '%s\n' "$out" | grep -qE '^#? [a-z-]+,[0-9.]+,'; then
    ok "--bench produces CSV row" 0 0
  else
    diag "--bench inner call exit=$rc; last 5 lines of output:"
    diag "$(printf '%s\n' "$out" | tail -5)"
    ok "--bench produces CSV row" 1 0
  fi
}

# ═══════════════════════════════════════════════════════════════════════════
# Online (network) test groups
# ═══════════════════════════════════════════════════════════════════════════

test_group_network_baseline() {
  local out rc

  note "network: baseline say-hi"

  out=$("$BIN" --mode text --no-tools --no-stream "Reply with exactly: PIZIG_SMOKE_OK"); rc=$?
  ok "text-mode prompt exit" "$rc" 0
  contains "text-mode returns marker" "$out" "PIZIG_SMOKE_OK"
}

test_group_network_json_mode() {
  local out rc

  note "network: json-mode"

  out=$("$BIN" --mode json --no-stream "Say hi in three words"); rc=$?
  ok "json-mode prompt exit" "$rc" 0
  if printf '%s' "$out" | python3 -c 'import sys,json;d=json.load(sys.stdin);assert d["content"]' 2>/dev/null; then
    ok "json-mode has content field" 0 0
  else
    ok "json-mode invalid/empty" 1 0
  fi
}

test_group_network_at_file() {
  local out rc tmp

  note "network: @file + system-prompt"

  tmp="$(mktemp)"; printf 'the magic token is ZQ-91' > "$tmp"
  register_temp_file "$tmp"
  out=$("$BIN" --mode text --system-prompt "Reply with only the token." "@$tmp" "What is the magic token?"); rc=$?
  ok "@file + system-prompt exit" "$rc" 0
  contains "@file content reaches model" "$out" "ZQ-91"
}

test_group_network_streaming() {
  local out rc

  note "network: streaming"

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
    ok "stream json is valid NDJSON ending in done" 0 0
  else
    ok "stream json malformed" 1 0
  fi
}

test_group_network_tools() {
  local out rc tf wf

  note "network: tool-calling"

  # Tool-calling: bash round-trip
  out=$("$BIN" --mode text --tools bash "Use the bash tool to run: echo TOOLS_WORK_91"); rc=$?
  ok "bash tool exit" "$rc" 0
  contains "bash tool executed end-to-end" "$out" "TOOLS_WORK_91"

  # Tool-calling: read round-trip
  tf="$(mktemp)"; printf 'SMOKE_FILE_MARKER_77' > "$tf"
  register_temp_file "$tf"
  out=$("$BIN" --mode text --tools read "Use the read tool to read $tf and quote its contents."); rc=$?
  ok "read tool exit" "$rc" 0
  contains "read tool returned file contents" "$out" "SMOKE_FILE_MARKER_77"

  # Tool-calling: write round-trip (verify the side effect on disk)
  wf="$(mktemp -u)"
  register_temp_file "$wf"
  out=$("$BIN" --tools write "Use the write tool to create $wf containing exactly: WRITE_MARKER_55"); rc=$?
  ok "write tool exit" "$rc" 0
  if [ -f "$wf" ] && grep -q "WRITE_MARKER_55" "$wf"; then
    ok "write tool created file on disk" 0 0
  else
    ok "write tool did not create expected file" 1 0
  fi
}

test_group_network_session() {
  local out rc SESS sess_file

  note "session tests"

  SESS="smoke-session-$$"
  sess_file="$HOME/.config/tau/sessions/${SESS}.json"

  out=$("$BIN" --session "$SESS" --no-tools --no-stream -p "My secret number is 42"); rc=$?
  ok "session: first turn exit" "$rc" 0

  out=$("$BIN" --session "$SESS" --no-tools --no-stream -p "What is my secret number?"); rc=$?
  ok "session: second turn exit" "$rc" 0
  contains "session: model recalls secret number" "$out" "42"

  # Verify session file was written and has 4 messages (2 turns x user+assistant)
  if python3 - "$sess_file" <<'PYEOF' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
assert len(d["messages"]) == 4, f"expected 4 messages, got {len(d['messages'])}"
PYEOF
  then
    ok "session: file has 4 messages" 0 0
  else
    ok "session: unexpected message count" 1 0
  fi

  cleanup_sessions "$SESS"
}

test_group_network_compaction() {
  local out rc CSESS csess_file LONG_MSG seed_ok

  note "compaction tests"

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
    ok "compaction seed: $seed_ok" 0 0
  else
    ok "compaction seed: session not fat enough" 1 0
  fi

  # Trigger compaction: context_window=200, threshold=0.5 -> fire at >100 tokens
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
    ok "compaction: session shrank with summary sentinel" 0 0
  else
    ok "compaction: session not compacted or summary missing" 1 0
  fi

  cleanup_sessions "$CSESS"
}

test_group_network_edit_tool() {
  local out rc ef

  note "edit / find / grep tools"

  # Edit tool
  ef="$(mktemp)"; printf 'Hello World' > "$ef"
  register_temp_file "$ef"
  out=$("$BIN" --tools edit "Use the edit tool to replace 'World' with 'Mars' in $ef"); rc=$?
  ok "edit tool exit" "$rc" 0
  if [ -f "$ef" ] && grep -q "Mars" "$ef"; then
    ok "edit tool mutated file on disk" 0 0
  else
    ok "edit tool did not update file" 1 0
  fi
}

test_group_network_find_grep_tools() {
  local out rc fdir gf

  note "find / grep tools"

  # Find tool
  fdir="$(mktemp -d)"
  register_temp_dir "$fdir"
  touch "$fdir/tau-FINDME99.txt"
  out=$("$BIN" --mode text --tools find "Use the find tool to find files matching the pattern 'FINDME99' under $fdir. Quote the exact filename you find."); rc=$?
  ok "find tool exit" "$rc" 0
  contains "find tool returns result" "$out" "FINDME99"

  # Grep tool
  gf="$(mktemp)"; printf 'GREP_NEEDLE_42 is the answer' > "$gf"
  register_temp_file "$gf"
  out=$("$BIN" --mode text --tools grep "Use the grep tool to search for GREP_NEEDLE_42 in $gf. Quote the matching line exactly."); rc=$?
  ok "grep tool exit" "$rc" 0
  contains "grep tool finds pattern" "$out" "GREP_NEEDLE_42"
}

test_group_network_dry_run_no_side_effect() {
  local out rc dry_file

  note "dry-run / iteration cap / no-tools"

  # --dry-run: tool reported, not executed
  dry_file="/tmp/tau-dryrun-$$-shouldnotexist"
  out=$("$BIN" --dry-run --tools bash "Use bash to run: touch $dry_file"); rc=$?
  ok "dry-run exit" "$rc" 0
  if [ ! -f "$dry_file" ]; then
    ok "dry-run: no side effect on disk" 0 0
  else
    ok "dry-run: file was created (should not be)" 1 0
    rm -f "$dry_file"
  fi
}

test_group_network_max_iterations() {
  local out rc

  note "--max-iterations backstop"

  # max-iterations=1: model gets exactly 1 tool call, then is forced to give a final text answer
  out=$("$BIN" --max-iterations 1 --tools bash "Use bash to run 'echo HI', then summarize the output."); rc=$?
  ok "--max-iterations=1 backstop exit" "$rc" 0
}

test_group_network_no_tools() {
  local out rc

  note "--no-tools"

  out=$("$BIN" --no-tools "What is 2+2? Reply with just the number."); rc=$?
  ok "--no-tools exit" "$rc" 0
  contains "--no-tools model still answers" "$out" "4"
}

test_group_network_system_prompt_flags() {
  local out rc

  note "system prompt flags"

  out=$("$BIN" --mode text --no-tools --append-system-prompt "CRITICAL: prefix every reply with APPENDED_99" "Reply with exactly: APPENDED_99"); rc=$?
  ok "--append-system-prompt exit" "$rc" 0
  contains "--append-system-prompt honored" "$out" "APPENDED_99"
}

test_group_network_exclude_tools() {
  local out rc excl_dir

  note "--exclude-tools denylist"

  excl_dir="$(mktemp -d)"
  register_temp_dir "$excl_dir"
  touch "$excl_dir/alpha.txt" "$excl_dir/beta.txt"
  out=$("$BIN" --mode text --exclude-tools bash "List files in $excl_dir using available tools. Say how many files there are."); rc=$?
  ok "--exclude-tools exit" "$rc" 0
}

test_group_network_large_file_injection() {
  local out rc bigf

  note "large @file injection"

  bigf="$(mktemp)"
  register_temp_file "$bigf"
  python3 -c "
filler = 'The following text is padding to make a large file. ' * 60
print(filler)
print('The magic token is: BIGFILE_TOKEN_77')
print(filler)
" > "$bigf"
  out=$("$BIN" --no-stream "@$bigf" "What is the magic token mentioned in the file? Reply with just the token."); rc=$?
  ok "large @file exit" "$rc" 0
  contains "large @file content reaches model" "$out" "BIGFILE_TOKEN_77"
}

test_group_network_goal_mode() {
  local out rc GSESS gsess_file goal_target

  note "goal mode"

  GSESS="smoke-goal-$$"
  gsess_file="$HOME/.config/tau/sessions/${GSESS}.json"
  goal_target="/tmp/tau-goal-target-$$"

  out=$("$BIN" --session "$GSESS" --tools bash,write,read \
    "/goal Create a file at $goal_target containing exactly: GOAL_SMOKE_OK"); rc=$?
  ok "goal mode exit" "$rc" 0
  if [ -f "$goal_target" ] && grep -q "GOAL_SMOKE_OK" "$goal_target"; then
    ok "goal mode: file created with correct content" 0 0
  else
    ok "goal mode: file missing or wrong content" 1 0
  fi
  rm -f "$goal_target"
  cleanup_sessions "$GSESS"
}

test_group_network_goal_sentinel_strip() {
  local out rc GSESS2 gsess2_file goal_target2

  note "goal mode: GOAL_MET sentinel stripped from terminal output"

  GSESS2="smoke-goalstrip-$$"
  gsess2_file="$HOME/.config/tau/sessions/${GSESS2}.json"
  goal_target2="/tmp/tau-goal-target2-$$"
  out=$("$BIN" --session "$GSESS2" --tools write \
    "/goal Write the word SENTINEL_STRIP_OK to $goal_target2")
  if printf '%s' "$out" | grep -q '<GOAL_MET>'; then
    ok "goal mode: <GOAL_MET> leaked to terminal output" 1 0
  else
    ok "goal mode: <GOAL_MET> sentinel not visible in output" 0 0
  fi
  rm -f "$goal_target2"
  cleanup_sessions "$GSESS2"
}

test_group_network_multi_tool_turn() {
  local out rc mf1 mf2

  note "multi-tool turn"

  mf1="$(mktemp)"; printf 'MULTI_A_11' > "$mf1"
  mf2="$(mktemp)"; printf 'MULTI_B_22' > "$mf2"
  register_temp_file "$mf1" "$mf2"
  out=$("$BIN" --mode text --tools read "Read both $mf1 and $mf2 and quote their exact contents on one line each."); rc=$?
  ok "multi-tool turn exit" "$rc" 0
  contains "multi-tool: first file content" "$out" "MULTI_A_11"
  contains "multi-tool: second file content" "$out" "MULTI_B_22"
}

test_group_network_ls_tool() {
  local out rc ltdir

  note "ls tool end-to-end"

  ltdir="$(mktemp -d)"
  register_temp_dir "$ltdir"
  touch "$ltdir/tau-LS-ALPHA.txt" "$ltdir/tau-LS-BETA.txt"
  out=$("$BIN" --mode text --tools ls "Use the ls tool to list files in $ltdir. Quote the exact filenames you see."); rc=$?
  ok "ls tool exit" "$rc" 0
  contains "ls tool returns alpha" "$out" "tau-LS-ALPHA"
  contains "ls tool returns beta" "$out" "tau-LS-BETA"
}

# Group: --role critic network test (Issue #8)
# Verifies the critic directive is injected and the model emits a verdict sentinel.
test_group_network_role_critic() {
  local out rc

  note "network: --role critic directive and verdict sentinel"

  out=$("$BIN" --role critic --tools read,grep,ls \
    "Audit $ROOT/src/main.zig for bugs"); rc=$?
  ok "--role critic audit exit" "$rc" 0

  # The Critic directive requires the response to end with exactly one of these.
  contains_any_of "--role critic audit emits verdict" "$out" "<APPROVED>" "<BLOCKED>"
}

# ═══════════════════════════════════════════════════════════════════════════
# Main test execution
# ═══════════════════════════════════════════════════════════════════════════

# Run offline groups
for entry in "${ALL_TEST_GROUPS[@]}"; do
  case "$entry" in *:network) continue ;; esac
  _smoke_split_entry "$entry"
  run_test_group "$_smoke_entry_name" "$_smoke_entry_func"
done

# Run online groups if --net and API key available
if [ "$NET" = "1" ]; then
  if ! $has_key; then
    echo "# WARNING: --net specified but no API key found; skipping online tests" >&2
  else
    for entry in "${ALL_TEST_GROUPS[@]}"; do
      case "$entry" in *:network) ;; *) continue ;; esac
      _smoke_split_entry "$entry"
      run_test_group "$_smoke_entry_name" "$_smoke_entry_func"
    done
  fi
else
  echo "# (network tests skipped; use --net to enable)"
fi

# ── Benchmark integration ─────────────────────────────────────────────────
if [ "$RUN_BENCH" = "1" ]; then
  run_benchmarks
fi

# ── Final summary ─────────────────────────────────────────────────────────
print_summary
