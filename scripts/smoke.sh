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
  "guide:test_group_guide"
  "flags:test_group_flag_parsing"
  "role:test_group_role_flag"
  "fleet:test_group_fleet"
  "issue11:test_group_issue11_flags"
  "model:test_group_model_shorthand"
  "acp:test_group_acp"
  "config-file:test_group_config_file"
  "doctor:test_group_doctor"
  "config-show:test_group_config_show"
  "config-validate:test_group_config_validate"
  "config-edit:test_group_config_edit"
  "config-editor:test_group_config_editor"
  "bug:test_group_bug"
  "init:test_group_init"
  "setup:test_group_setup"
  "client-examples:test_group_client_examples"
  "goal:test_group_goal_offline"
  "dry-run:test_group_dry_run"
  "at-file-system-prompt:test_group_at_file_system_prompt"
  "scan-agents:test_group_scan_agents"
  "session-validation:test_group_session_name_validation"
  "fleet-items:test_group_fleet_items"
  "invalid-numeric:test_group_invalid_numeric"
  "fleet-flags:test_group_fleet_flags"
  "completions:test_group_completions"
  "debug:test_group_debug"
  "version:test_group_version"
  "release:test_group_release"
  "first-run:test_group_first_run"
  "golden-errors:test_group_golden_errors"
  "golden-onboarding:test_group_golden_onboarding"
  "golden-help:test_group_golden_help"
  "update:test_group_update"
  "upgrade:test_group_upgrade"
  "errors-doc:test_group_errors_doc"
  "explain:test_group_explain"
  "golden-maintenance:test_group_golden_maintenance"
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

# version subcommand + build metadata surfaced across version --verbose,
# tau doctor (report + NDJSON verdict), and the --debug log header.
test_group_version() {
  local out rc
  local scrub=(env -u XIAOMI_API_KEY -u PIZIG_API_KEY -u TAU_API_KEY -u OPENAI_API_KEY -u DEEPSEEK_API_KEY)

  out=$("$BIN" version); ok "version exit" "$?" 0
  contains "version prints name + semver" "$out" "tau 0.4.0"

  out=$("$BIN" -v); ok "-v exit" "$?" 0
  contains "-v output unchanged" "$out" "tau 0.4.0"

  # --verbose: JSON object with all four build metadata keys.
  out=$("$BIN" version --verbose); ok "version --verbose exit" "$?" 0
  printf '%s' "$out" | python3 -c 'import sys,json; d=json.load(sys.stdin); need=["name","version","commit","target","build_date","zig"]; sys.exit(0 if all(d.get(k) for k in need) and d["name"]=="tau" else 1)' 2>/dev/null
  ok "version --verbose carries all metadata keys" "$?" 0

  # --mode text: same metadata as key: value lines.
  out=$("$BIN" version --verbose --mode text); ok "version --verbose --mode text exit" "$?" 0
  contains "text mode has commit line" "$out" "commit: "
  contains "text mode has target line" "$out" "target: "
  contains "text mode has zig line" "$out" "zig: "

  "$BIN" version --bogus >/dev/null 2>&1; ok "version rejects unknown arg (exit 80)" "$?" 80

  # doctor --json: the terminal done:true verdict carries the build object.
  local vout
  vout=$("${scrub[@]}" HOME="$SMOKE_TEMP/vhome" "$BIN" doctor --json --offline 2>/dev/null | tail -1)
  contains "doctor --json verdict carries build" "$vout" '"build":{"commit":"'
  contains "doctor verdict build has zig" "$vout" '"zig":"'

  # doctor single-object report carries it too (tau setup embeds this shape).
  local rout
  rout=$("${scrub[@]}" HOME="$SMOKE_TEMP/vhome" "$BIN" doctor --offline 2>/dev/null)
  contains "doctor report carries build" "$rout" '"build":{"commit":"'

  # --debug log header carries the one-line build stamp.
  local dlog="$SMOKE_TEMP/version-debug.log"
  "${scrub[@]}" HOME="$SMOKE_TEMP/vhome" TAU_DEBUG_LOG="$dlog" "$BIN" --debug --no-stream "hi" >/dev/null 2>&1
  if [ -f "$dlog" ]; then
    contains "debug log has build header" "$(cat "$dlog")" "# build: commit="
    contains "debug log build has target" "$(cat "$dlog")" "target="
  else
    ok "debug log has build header" 1 0
    ok "debug log build has target" 1 0
  fi
}

# tau version --check + the doctor update_available warning — a non-blocking,
# opt-out (TAU_NO_UPDATE_CHECK) check against the latest release. Fully
# offline: TAU_UPDATE_URL points curl at file:// stubs.
test_group_update() {
  local out stub_home
  stub_home="$SMOKE_TEMP/uhome"
  mkdir -p "$stub_home"
  local scrub=(env -u XIAOMI_API_KEY -u PIZIG_API_KEY -u OPENAI_API_KEY -u DEEPSEEK_API_KEY -u OPENCODE_API_KEY -u TAU_API_KEY HOME="$stub_home")

  printf '{"tag_name":"v99.9.9","name":"newer"}' > "$SMOKE_TEMP/rel-newer.json"
  printf '{"tag_name":"v0.4.0"}' > "$SMOKE_TEMP/rel-same.json"
  printf 'not json' > "$SMOKE_TEMP/rel-bad.json"

  # 1. Explicit --check honors the opt-out: checked:false, reason names the var.
  capture vc_off env TAU_NO_UPDATE_CHECK=1 "$BIN" version --check
  ok "version --check opt-out exit 0" "$vc_off_rc" 0
  contains "opt-out reports checked:false" "$vc_off_out" '"checked":false'
  contains "opt-out reason names the var" "$vc_off_out" 'TAU_NO_UPDATE_CHECK'

  # 2. Newer release available -> update_available:true + release page URL.
  capture vc_new env TAU_UPDATE_URL="file://$SMOKE_TEMP/rel-newer.json" "$BIN" version --check
  ok "version --check newer exit 0" "$vc_new_rc" 0
  contains "newer checked:true" "$vc_new_out" '"checked":true'
  contains "newer latest normalized" "$vc_new_out" '"latest":"99.9.9"'
  contains "newer update_available:true" "$vc_new_out" '"update_available":true'
  contains "newer update_url points at tag" "$vc_new_out" '"update_url":"https://github.com/javimosch/tau/releases/tag/v99.9.9"'

  # 3. Same version -> up to date, no update_url.
  capture vc_same env TAU_UPDATE_URL="file://$SMOKE_TEMP/rel-same.json" "$BIN" version --check
  ok "version --check same exit 0" "$vc_same_rc" 0
  contains "same update_available:false" "$vc_same_out" '"update_available":false'
  if printf '%s' "$vc_same_out" | grep -qF 'update_url'; then
    ok "same omits update_url" 1 0
  else
    ok "same omits update_url" 0 0
  fi

  # 4. Failure paths are non-blocking: bad payload and missing stub both exit 0
  #    with checked:false.
  capture vc_bad env TAU_UPDATE_URL="file://$SMOKE_TEMP/rel-bad.json" "$BIN" version --check
  ok "bad payload exit 0" "$vc_bad_rc" 0
  contains "bad payload checked:false" "$vc_bad_out" '"checked":false'
  contains "bad payload reason" "$vc_bad_out" 'tag_name'
  capture vc_missing env TAU_UPDATE_URL="file://$SMOKE_TEMP/rel-missing.json" "$BIN" version --check
  ok "missing stub exit 0" "$vc_missing_rc" 0
  contains "missing stub checked:false" "$vc_missing_out" '"checked":false'
  contains "missing stub reason" "$vc_missing_out" 'release lookup failed'

  # 5. --mode text renders key: value lines; --verbose composes with --check.
  capture vc_txt env TAU_UPDATE_URL="file://$SMOKE_TEMP/rel-newer.json" "$BIN" version --check --mode text
  ok "text mode exit 0" "$vc_txt_rc" 0
  contains "text latest line" "$vc_txt_out" 'latest: 99.9.9'
  contains "text update_available line" "$vc_txt_out" 'update_available: true'
  contains "text update_url line" "$vc_txt_out" 'update_url: https://github.com/javimosch/tau/releases/tag/v99.9.9'
  capture vc_txt_off env TAU_NO_UPDATE_CHECK=1 "$BIN" version --check --mode text
  contains "text opt-out line" "$vc_txt_off_out" 'update_check: disabled (TAU_NO_UPDATE_CHECK)'
  capture vc_vrb env TAU_UPDATE_URL="file://$SMOKE_TEMP/rel-same.json" "$BIN" version --check --verbose
  contains "verbose+check has commit" "$vc_vrb_out" '"commit":"'
  contains "verbose+check has checked" "$vc_vrb_out" '"checked":true'

  # 6. Doctor's update_available row: warn on newer, ok on same, skip on
  #    --offline / TAU_NO_UPDATE_CHECK. It never fails the run by itself.
  capture doc_new "${scrub[@]}" TAU_UPDATE_URL="file://$SMOKE_TEMP/rel-newer.json" "$BIN" doctor --offline --provider openai --api-key k
  # --offline skips the check — even with a stub URL set.
  contains "doctor --offline skips update check" "$doc_new_out" '"name":"update_available","status":"skip"'
  capture doc_upd "${scrub[@]}" TAU_UPDATE_URL="file://$SMOKE_TEMP/rel-newer.json" "$BIN" doctor --provider openai --api-key k
  contains "doctor warns on newer release" "$doc_upd_out" '"name":"update_available","status":"warn"'
  contains "doctor warn names versions" "$doc_upd_out" 'new release available: 99.9.9 (running 0.4.0)'
  capture doc_ok "${scrub[@]}" TAU_UPDATE_URL="file://$SMOKE_TEMP/rel-same.json" "$BIN" doctor --provider openai --api-key k
  contains "doctor ok when current" "$doc_ok_out" '"name":"update_available","status":"ok"'
  capture doc_dis "${scrub[@]}" TAU_NO_UPDATE_CHECK=1 "$BIN" doctor --provider openai --api-key k
  contains "doctor skips when opted out" "$doc_dis_out" '"name":"update_available","status":"skip"'
  contains "doctor opt-out message" "$doc_dis_out" 'skipped (TAU_NO_UPDATE_CHECK)'

  # 7. Help advertises the flag.
  "$BIN" --help 2>&1 | grep -q -- '--check' && ok "--help mentions --check" 0 0 || ok "--help mentions --check" 1 0
}

# Group: `tau upgrade` — self-update in place via the verified install.sh.
# Reuses the update check (TAU_UPDATE_URL stubs), gates on a confirmation
# prompt (--yes/TAU_YES on non-TTY), then downloads and execs the release
# tag's install.sh. Everything is stubbed offline: TAU_UPDATE_URL points at a
# file:// release payload, TAU_INSTALL_URL at a staged copy of install.sh and
# TAU_BASE_URL at a staged release tree, so the whole check→confirm→install
# path runs without network.
test_group_upgrade() {
  local stub_home="$SMOKE_TEMP/ug-home"
  mkdir -p "$stub_home"

  printf '{"tag_name":"v99.9.9","name":"newer"}' > "$SMOKE_TEMP/ug-rel-newer.json"
  printf '{"tag_name":"v0.4.0"}' > "$SMOKE_TEMP/ug-rel-same.json"

  # 1. Arg validation: unknown flag, positional and missing --dir value all
  #    exit 80 with an invalid_argument envelope on stderr.
  capture ug_bogus "$BIN" upgrade --bogus
  ok "upgrade --bogus exit 80" "$ug_bogus_rc" 80
  contains "upgrade --bogus envelope" "$ug_bogus_err" '"type":"invalid_argument"'
  contains "upgrade --bogus names the arg" "$ug_bogus_err" 'unknown upgrade argument: --bogus'
  capture ug_pos "$BIN" upgrade now
  ok "upgrade positional exit 80" "$ug_pos_rc" 80
  capture ug_nodir "$BIN" upgrade --dir
  ok "upgrade --dir missing value exit 80" "$ug_nodir_rc" 80
  contains "upgrade --dir missing message" "$ug_nodir_err" 'missing value for --dir'

  # 2. Up to date -> status up_to_date, exit 0.
  capture ug_same env TAU_UPDATE_URL="file://$SMOKE_TEMP/ug-rel-same.json" "$BIN" upgrade
  ok "upgrade same-version exit 0" "$ug_same_rc" 0
  contains "same checked:true" "$ug_same_out" '"checked":true'
  contains "same update_available:false" "$ug_same_out" '"update_available":false'
  contains "same status" "$ug_same_out" '"status":"up_to_date"'

  # 3. Newer release but no --yes on a non-TTY stdin -> skipped, exit 1,
  #    detail points at --yes. stdin is pinned to /dev/null so the check is
  #    deterministic even when the harness itself runs interactively.
  capture ug_skip env TAU_UPDATE_URL="file://$SMOKE_TEMP/ug-rel-newer.json" \
    sh -c '"$0" upgrade < /dev/null' "$BIN"
  ok "upgrade unconfirmed exit 1" "$ug_skip_rc" 1
  contains "unconfirmed status skipped" "$ug_skip_out" '"status":"skipped"'
  contains "unconfirmed detail names --yes" "$ug_skip_out" 'pass --yes'
  contains "unconfirmed carries release_url" "$ug_skip_out" '"release_url":"https://github.com/javimosch/tau/releases/tag/v99.9.9"'

  # 4. Opt-out: TAU_NO_UPDATE_CHECK short-circuits the check — checked:false,
  #    status skipped, reason names the var, exit 1.
  capture ug_off env TAU_NO_UPDATE_CHECK=1 "$BIN" upgrade --yes
  ok "upgrade opt-out exit 1" "$ug_off_rc" 1
  contains "opt-out checked:false" "$ug_off_out" '"checked":false'
  contains "opt-out status skipped" "$ug_off_out" '"status":"skipped"'
  contains "opt-out detail names the var" "$ug_off_out" 'TAU_NO_UPDATE_CHECK'

  # 5. Lookup failure -> checked:false, status failed, exit 1.
  capture ug_miss env TAU_UPDATE_URL="file://$SMOKE_TEMP/ug-rel-missing.json" "$BIN" upgrade --yes
  ok "upgrade lookup-failure exit 1" "$ug_miss_rc" 1
  contains "lookup-failure checked:false" "$ug_miss_out" '"checked":false'
  contains "lookup-failure status failed" "$ug_miss_out" '"status":"failed"'

  # 6. --dry-run resolves the plan (installer URL + install dir) without
  #    touching anything — status dry_run, exit 0.
  capture ug_dry env TAU_UPDATE_URL="file://$SMOKE_TEMP/ug-rel-newer.json" TAU_INSTALL_DIR="$SMOKE_TEMP/ug-dry-dest" "$BIN" upgrade --dry-run
  ok "upgrade --dry-run exit 0" "$ug_dry_rc" 0
  contains "dry-run status" "$ug_dry_out" '"status":"dry_run"'
  contains "dry-run names the installer" "$ug_dry_out" 'install.sh'
  contains "dry-run resolves install_dir" "$ug_dry_out" "\"install_dir\":\"$SMOKE_TEMP/ug-dry-dest\""
  [ ! -e "$SMOKE_TEMP/ug-dry-dest" ]; ok "dry-run created nothing" "$?" 0

  # 7. Installer download failure -> status failed, exit 1.
  capture ug_noinst env TAU_UPDATE_URL="file://$SMOKE_TEMP/ug-rel-newer.json" TAU_INSTALL_URL="file://$SMOKE_TEMP/ug-no-such-install.sh" "$BIN" upgrade --yes
  ok "upgrade missing-installer exit 1" "$ug_noinst_rc" 1
  contains "missing-installer status failed" "$ug_noinst_out" '"status":"failed"'
  contains "missing-installer detail" "$ug_noinst_out" 'installer download failed'

  # 8. Full staged e2e: newer release + staged installer + staged release
  #    tree -> --yes runs install.sh end to end (checksum verified on
  #    stderr), the binary lands in TAU_INSTALL_DIR, stdout stays pure JSON.
  local asset_os asset_arch
  case "$(uname -s)" in
    Linux)  asset_os=linux ;;
    Darwin) asset_os=macos ;;
    *)      asset_os="" ;;
  esac
  asset_arch="$(uname -m)"
  case "$asset_arch" in
    amd64) asset_arch=x86_64 ;;
    arm64) asset_arch=aarch64 ;;
    x86_64|aarch64) ;;
    *) asset_arch="" ;;
  esac

  if [ -n "$asset_os" ] && [ -n "$asset_arch" ]; then
    local e2e asset
    e2e="$SMOKE_TEMP/ug-e2e"
    asset="tau-$asset_os-$asset_arch.tar.gz"
    mkdir -p "$e2e/srv/download/v99.9.9" "$e2e/pkg" "$e2e/bin"
    printf '#!/bin/sh\necho "tau 99.9.9"\n' > "$e2e/pkg/tau"
    chmod +x "$e2e/pkg/tau"
    tar -czf "$e2e/srv/download/v99.9.9/$asset" -C "$e2e/pkg" tau
    (cd "$e2e/srv/download/v99.9.9" && \
      { sha256sum "$asset" 2>/dev/null || shasum -a 256 "$asset"; } > SHA256SUMS.txt)
    cp "$ROOT/install.sh" "$e2e/install.sh"

    capture ug_yes env TAU_UPDATE_URL="file://$SMOKE_TEMP/ug-rel-newer.json" \
      TAU_INSTALL_URL="file://$e2e/install.sh" \
      TAU_BASE_URL="file://$e2e/srv" \
      TAU_INSTALL_DIR="$e2e/bin" \
      "$BIN" upgrade --yes
    ok "upgrade --yes e2e exit 0" "$ug_yes_rc" 0
    contains "e2e status upgraded" "$ug_yes_out" '"status":"upgraded"'
    contains "e2e detail reports dest" "$ug_yes_out" "installed tau 99.9.9 -> $e2e/bin/tau"
    contains "e2e installer verified checksum" "$ug_yes_err" 'checksum verified'
    [ -x "$e2e/bin/tau" ]; ok "e2e installed binary is executable" "$?" 0
    contains "e2e installed binary runs" "$("$e2e/bin/tau")" 'tau 99.9.9'

    # TAU_YES=1 approves the same way as --yes.
    rm -f "$e2e/bin/tau"
    capture ug_envyes env TAU_UPDATE_URL="file://$SMOKE_TEMP/ug-rel-newer.json" \
      TAU_INSTALL_URL="file://$e2e/install.sh" \
      TAU_BASE_URL="file://$e2e/srv" \
      TAU_INSTALL_DIR="$e2e/bin" \
      TAU_YES=1 \
      "$BIN" upgrade
    ok "upgrade TAU_YES e2e exit 0" "$ug_envyes_rc" 0
    contains "TAU_YES e2e status upgraded" "$ug_envyes_out" '"status":"upgraded"'
    [ -x "$e2e/bin/tau" ]; ok "TAU_YES e2e installed binary" "$?" 0
  else
    note "upgrade: skipping e2e install (unsupported host platform)"
  fi

  # 9. Help advertises the subcommand.
  "$BIN" --help 2>&1 | grep -q 'tau upgrade' && ok "--help mentions tau upgrade" 0 0 || ok "--help mentions tau upgrade" 1 0
}

# guide — the embedded operator manual (cli-guide-spec). JSON default, --human markdown, no runtime fetch.
test_group_guide() {
  local out

  out=$("$BIN" guide); ok "guide exit" "$?" 0
  if printf '%s' "$out" | python3 -c 'import sys,json;json.load(sys.stdin)' 2>/dev/null; then
    ok "guide is valid JSON" 0 0
  else
    ok "guide is not valid JSON" 1 0
  fi
  printf '%s' "$out" | python3 -c 'import sys,json; d=json.load(sys.stdin); need=["one_liner","model","loop","concepts","commands","examples","gotchas","see_also","version"]; sys.exit(0 if all(k in d for k in need) and d["version"] else 1)' 2>/dev/null
  ok "guide has all spec keys + version" "$?" 0

  out=$("$BIN" guide --human); ok "guide --human exit" "$?" 0
  contains "guide --human renders markdown" "$out" "## Commands"

  "$BIN" guide --bogus >/dev/null 2>&1; ok "guide rejects unknown arg (exit 80)" "$?" 80
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

# Group: --role flag
# Use --api-key fake --provider openai so auth fails fast at exit 106 (still != 80).
# This avoids making slow LLM calls via the configured provider.
test_group_role_flag() {
  local rc

  note "--role flag parsing"
  "$BIN" --role invalid "x" >/dev/null 2>&1;       ok "--role invalid -> invalid_argument" "$?" 80
  for r in author critic coordinator none; do
    "$BIN" --role "$r" --no-tools --no-stream --api-key fake --provider openai "x" >/dev/null 2>&1
    rc=$?
    if [ "$rc" != "80" ]; then
      ok "--role $r accepted by parser (downstream exit $rc)" 0 0
    else
      ok "--role $r rejected by parser" 1 0
    fi
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
  # run without --goal -> missing_required_field (--api-key fake keeps this
  # deterministic: key resolution runs before the --goal check, so a keyless
  # environment would exit 106 instead of reaching it)
  "$BIN" fleet run --api-key fake >/dev/null 2>&1; ok "fleet run without --goal -> missing_required_field" "$?" 82
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

  # --api-key with value accepted by parser
  "$BIN" --api-key fake --no-tools --no-stream --provider openai "x" >/dev/null 2>&1; rc=$?
  if [ "$rc" != "80" ]; then
    ok "--api-key value accepted by parser (exit $rc)" 0 0
  else
    ok "--api-key value rejected by parser" 1 0
  fi
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

  # acp status accepted by parser (exit 0 if not running). The daemon
  # (start/stop/status) is POSIX-only: on Windows it exits 111 with an err
  # envelope instead — both contracts are pinned here.
  capture acp_status "$BIN" acp status 2>&1
  if printf '%s' "$acp_status_out" | grep -q '"code":111'; then
    ok "acp status -> exit 111 err envelope (daemon unsupported on this platform)" "$acp_status_rc" 111
    skip_test "acp status reports running:false" "daemon unsupported on this platform"
    skip_test "acp stop" "daemon unsupported on this platform"
  else
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

# Group: `tau config show` — resolved effective config (file/env/flag merge,
# API keys redacted). Offline; uses a mock HOME for config-file cases.
test_group_config_show() {
  local out rc mock_home mock_config

  note "tau config show"

  "$BIN" config >/dev/null 2>&1;            ok "config (no sub) -> invalid_argument" "$?" 80
  "$BIN" config bogus >/dev/null 2>&1;      ok "config bogus -> invalid_argument" "$?" 80
  "$BIN" config show stray >/dev/null 2>&1; ok "config show positional -> invalid_argument" "$?" 80

  mock_home="$(mktemp -d)"; register_temp_dir "$mock_home"
  mock_config="$mock_home/.config/tau"; mkdir -p "$mock_config"
  printf '{"provider":"deepseek","mode":"text","timeout_ms":9000,"api_key":"file-secret-4242"}' > "$mock_config/config.json"

  out=$(HOME="$mock_home" "$BIN" config show); rc=$?
  ok "config show exit" "$rc" 0
  if printf '%s' "$out" | python3 -c 'import sys,json;json.load(sys.stdin)' 2>/dev/null; then
    ok "config show is valid JSON" 0 0
  else
    ok "config show is not valid JSON" 1 0
  fi
  contains "config show merges config provider" "$out" '"provider":"deepseek"'
  contains "config show merges config mode" "$out" '"mode":"text"'
  contains "config show merges config timeout" "$out" '"timeout_ms":9000'
  contains "config show reports config file exists" "$out" '"exists":true'
  # File api_key must be redacted (config api_key is below provider env in
  # precedence, but no env keys are set in the mock HOME test env).
  if printf '%s' "$out" | grep -q 'file-secret-4242'; then
    ok "config show does NOT leak config api_key" 1 0
  else
    ok "config show redacts config api_key" 0 0
  fi

  # CLI flags merge over the config file.
  out=$(HOME="$mock_home" "$BIN" config show --provider openai --model gpt-test --no-stream)
  contains "config show CLI --provider override" "$out" '"provider":"openai"'
  contains "config show CLI --model override" "$out" '"model":"gpt-test"'
  contains "config show CLI --no-stream" "$out" '"stream":false'

  # Key-source checks need a config file WITHOUT an api_key (config api_key
  # outranks TAU_API_KEY in precedence and would shadow it).
  local empty_home; empty_home="$(mktemp -d)"; register_temp_dir "$empty_home"

  # Env key is reported by source and redacted, never printed raw. Clear all
  # provider env keys so TAU_API_KEY is what actually resolves on this host.
  out=$(env -u XIAOMI_API_KEY -u PIZIG_API_KEY -u OPENAI_API_KEY -u DEEPSEEK_API_KEY -u OPENCODE_API_KEY TAU_API_KEY="smoke-secret-aa11" HOME="$empty_home" "$BIN" config show)
  if printf '%s' "$out" | grep -q 'smoke-secret-aa11'; then
    ok "config show does NOT leak TAU_API_KEY" 1 0
  else
    ok "config show redacts TAU_API_KEY" 0 0
  fi
  contains "config show reports api_key set" "$out" '"api_key":{"set":true'
  contains "config show reports env source" "$out" '"source":"env TAU_API_KEY"'
  contains "config show value is masked" "$out" '"value":"***'

  out=$(HOME="$empty_home" "$BIN" config show --api-key flag-secret-bb22)
  if printf '%s' "$out" | grep -q 'flag-secret-bb22'; then
    ok "config show does NOT leak --api-key" 1 0
  else
    ok "config show redacts --api-key" 0 0
  fi
  contains "config show reports flag source" "$out" '"source":"--api-key"'

  # No key anywhere -> set:false (read-only diagnostic, still exits 0).
  out=$(env -u TAU_API_KEY -u XIAOMI_API_KEY -u PIZIG_API_KEY -u OPENAI_API_KEY -u DEEPSEEK_API_KEY -u OPENCODE_API_KEY HOME="$empty_home" "$BIN" config show); rc=$?
  ok "config show no key still exits 0" "$rc" 0
  contains "config show no key -> set:false" "$out" '"api_key":{"set":false'

  # TAU_ENDPOINT override is attributed.
  out=$(HOME="$empty_home" TAU_ENDPOINT="http://localhost:1/v1/chat/completions" "$BIN" config show)
  contains "config show attributes TAU_ENDPOINT" "$out" '"endpoint_source":"env:TAU_ENDPOINT"'
}

# Group: `tau config validate` — offline config-file validation for
# CI/pre-commit. Exit 0 on valid, 1 on any problem found, 80 on CLI misuse.
test_group_config_validate() {
  local out rc tmpdir mock_home empty_home

  note "tau config validate"

  tmpdir="$(mktemp -d)"; register_temp_dir "$tmpdir"

  # Usage errors -> invalid_argument.
  "$BIN" config validate a.json b.json >/dev/null 2>&1; ok "config validate two paths -> exit 80" "$?" 80
  "$BIN" config validate --bogus >/dev/null 2>&1;       ok "config validate unknown flag -> exit 80" "$?" 80
  "$BIN" config validate --mode >/dev/null 2>&1;        ok "config validate bare --mode -> exit 80" "$?" 80

  # Missing file -> exit 1 with a file-level error (not an err envelope).
  out=$("$BIN" config validate "$tmpdir/nope.json"); rc=$?
  ok "config validate missing file -> exit 1" "$rc" 1
  contains "missing file reports file not found" "$out" 'file not found'

  # Valid config -> exit 0, ok:true, empty errors.
  printf '{"provider":"openai","mode":"text","temperature":0.2,"keys":{"deepseek":"sk-x"}}' > "$tmpdir/good.json"
  out=$("$BIN" config validate "$tmpdir/good.json"); rc=$?
  ok "config validate valid file -> exit 0" "$rc" 0
  contains "valid file reports ok:true" "$out" '"ok":true'
  contains "valid file reports no errors" "$out" '"errors":[]'

  # Semantic + type + unknown-key errors -> exit 1, every problem listed.
  printf '{"provider":"nope","mode":"yaml","stream":"yes","compact_threshold":2,"proivder":true,"keys":{"openai":5}}' > "$tmpdir/bad.json"
  out=$("$BIN" config validate "$tmpdir/bad.json"); rc=$?
  ok "config validate invalid file -> exit 1" "$rc" 1
  contains "bad provider flagged" "$out" '"key":"provider"'
  contains "bad mode flagged" "$out" '"key":"mode"'
  contains "wrong type flagged" "$out" 'must be a boolean'
  contains "range flagged" "$out" 'between 0 and 1'
  contains "unknown key flagged" "$out" 'not a tau config key'
  contains "keys value flagged" "$out" '"key":"keys.openai"'

  # The report parses as JSON with a non-empty errors array.
  if printf '%s' "$out" | python3 -c 'import sys,json;d=json.load(sys.stdin);sys.exit(0 if d["ok"] is False and len(d["errors"])>0 else 1)' 2>/dev/null; then
    ok "validate report parses as JSON" 0 0
  else
    ok "validate report parses as JSON" 1 0
  fi

  # Invalid JSON syntax -> line/column in the message.
  printf '{"provider": "openai",\n' > "$tmpdir/broken.json"
  out=$("$BIN" config validate "$tmpdir/broken.json"); rc=$?
  ok "config validate broken JSON -> exit 1" "$rc" 1
  contains "syntax error reports position" "$out" 'invalid JSON at line'

  # Non-object top level.
  printf '["provider","openai"]' > "$tmpdir/arr.json"
  out=$("$BIN" config validate "$tmpdir/arr.json"); rc=$?
  ok "config validate array top level -> exit 1" "$rc" 1
  contains "non-object flagged" "$out" 'must be a JSON object'

  # --mode text prints human-readable lines.
  out=$("$BIN" config validate --mode text "$tmpdir/bad.json")
  contains "text mode error lines" "$out" ': error in "provider"'
  out=$("$BIN" config validate --mode text "$tmpdir/good.json")
  contains "text mode ok line" "$out" ': ok'

  # Default path: validates ~/.config/tau/config.json when no path is given.
  mock_home="$(mktemp -d)"; register_temp_dir "$mock_home"
  mkdir -p "$mock_home/.config/tau"
  printf '{"provider":"deepseek"}' > "$mock_home/.config/tau/config.json"
  out=$(HOME="$mock_home" "$BIN" config validate); rc=$?
  ok "config validate default path -> exit 0" "$rc" 0
  contains "default path appears in report" "$out" '.config/tau/config.json'

  # No config file at all -> exit 1 with an actionable message.
  empty_home="$(mktemp -d)"; register_temp_dir "$empty_home"
  out=$(HOME="$empty_home" "$BIN" config validate); rc=$?
  ok "config validate no config file -> exit 1" "$rc" 1
  contains "no config points at tau init" "$out" 'tau init'

  # API key values are never echoed in the report.
  printf '{"api_key":123,"keys":{"bogus-prov":"sk-leak-me"}}' > "$tmpdir/keys.json"
  out=$("$BIN" config validate "$tmpdir/keys.json"); rc=$?
  ok "config validate keys issues -> exit 1" "$rc" 1
  if printf '%s' "$out" | grep -q 'sk-leak-me'; then
    ok "validate never echoes key values" 1 0
  else
    ok "validate never echoes key values" 0 0
  fi
}

# Group: `tau config set|get|unset` — programmatic, schema-checked edits to the
# config file. Offline; uses a mock HOME.
test_group_config_edit() {
  local out rc mock_home cfg

  note "tau config set|get|unset"

  mock_home="$(mktemp -d)"; register_temp_dir "$mock_home"
  cfg="$mock_home/.config/tau/config.json"

  # Usage errors -> invalid_argument (80).
  "$BIN" config set onlykey >/dev/null 2>&1;      ok "config set missing value -> exit 80" "$?" 80
  "$BIN" config get >/dev/null 2>&1;              ok "config get missing key -> exit 80" "$?" 80
  "$BIN" config get k a b >/dev/null 2>&1;        ok "config get extra arg -> exit 80" "$?" 80
  "$BIN" config set k v --bogus >/dev/null 2>&1;  ok "config set unknown flag -> exit 80" "$?" 80
  "$BIN" config unset x --raw >/dev/null 2>&1;    ok "config unset --raw -> exit 80" "$?" 80
  "$BIN" config set a.b.c v >/dev/null 2>&1;      ok "config set deep path -> exit 80" "$?" 80

  # set creates the file (+ parents) when missing.
  out=$(HOME="$mock_home" "$BIN" config set provider openai); rc=$?
  ok "config set on missing file -> exit 0" "$rc" 0
  contains "set reports created:true" "$out" '"created":true'
  contains "set echoes key/value" "$out" '"key":"provider","value":"openai"'
  if [ -f "$cfg" ]; then ok "config set wrote the file" 0 0; else ok "config set wrote the file" 1 0; fi
  if [ "$(stat -c '%a' "$cfg" 2>/dev/null || stat -f '%Lp' "$cfg" 2>/dev/null)" = "600" ]; then
    ok "new config file is 0600" 0 0
  else
    ok "new config file is 0600" 1 0
  fi

  # get returns the stored value (JSON + text modes).
  out=$(HOME="$mock_home" "$BIN" config get provider); rc=$?
  ok "config get -> exit 0" "$rc" 0
  contains "get reports value" "$out" '"value":"openai"'
  contains "get reports set:true" "$out" '"set":true'
  out=$(HOME="$mock_home" "$BIN" config get provider --mode text)
  if [ "$out" = "openai" ]; then ok "get --mode text prints bare value" 0 0; else ok "get --mode text prints bare value" 1 0; fi

  # get/unset of an absent key -> exit 1 not_found.
  HOME="$mock_home" "$BIN" config get model >/dev/null 2>&1;   ok "get unset key -> exit 1" "$?" 1
  HOME="$mock_home" "$BIN" config unset model >/dev/null 2>&1; ok "unset absent key -> exit 1" "$?" 1

  # Schema checks reject bad values before writing (file unchanged).
  HOME="$mock_home" "$BIN" config set stream yes >/dev/null 2>&1;    ok "set wrong type -> exit 80" "$?" 80
  HOME="$mock_home" "$BIN" config set bogus x >/dev/null 2>&1;       ok "set unknown key -> exit 80" "$?" 80
  HOME="$mock_home" "$BIN" config set provider nope >/dev/null 2>&1; ok "set bad provider -> exit 80" "$?" 80
  HOME="$mock_home" "$BIN" config set compact_threshold 2 >/dev/null 2>&1; ok "set out-of-range -> exit 80" "$?" 80
  contains "file still holds only provider" "$(cat "$cfg")" '"provider"'

  # keys.<provider> addressing + redaction.
  out=$(HOME="$mock_home" "$BIN" config set keys.openai sk-secret-zz99)
  contains "set keys.<p> ok" "$out" '"key":"keys.openai"'
  if printf '%s' "$out" | grep -q 'sk-secret-zz99'; then
    ok "set never echoes the secret" 1 0
  else
    ok "set redacts the secret in output" 0 0
  fi
  contains "secret stored in file" "$(cat "$cfg")" '"openai": "sk-secret-zz99"'
  out=$(HOME="$mock_home" "$BIN" config get keys.openai --mode text)
  if printf '%s' "$out" | grep -q 'sk-secret-zz99'; then
    ok "get leaks the secret" 1 0
  else
    ok "get redacts secrets by default" 0 0
  fi
  out=$(HOME="$mock_home" "$BIN" config get keys.openai --raw --mode text)
  if [ "$out" = "sk-secret-zz99" ]; then ok "get --raw prints the real value" 0 0; else ok "get --raw prints the real value" 1 0; fi

  # unset removes the member; file stays valid JSON.
  out=$(HOME="$mock_home" "$BIN" config unset keys.openai); rc=$?
  ok "config unset -> exit 0" "$rc" 0
  contains "unset reports removed" "$out" '"removed":true'
  if printf '%s' "$(cat "$cfg")" | grep -q 'sk-secret-zz99'; then
    ok "unset left the secret behind" 1 0
  else
    ok "unset removed the secret" 0 0
  fi
  out=$(HOME="$mock_home" "$BIN" config validate)
  contains "file still validates after edits" "$out" '"ok":true'

  # Edits preserve comments (JSONC): write a commented file and set into it.
  printf '{\n  // user note\n  "provider": "deepseek"\n}\n' > "$cfg"
  HOME="$mock_home" "$BIN" config set mode text >/dev/null
  contains "comment preserved after set" "$(cat "$cfg")" '// user note'
  contains "new key inserted" "$(cat "$cfg")" '"mode": "text"'
  out=$(HOME="$mock_home" "$BIN" config get provider --mode text)
  if [ "$out" = "deepseek" ]; then ok "get reads commented file" 0 0; else ok "get reads commented file" 1 0; fi

  # Malformed file -> exit 1 invalid_config (never silently clobbers).
  printf '{"provider": "openai",\n' > "$cfg"
  out=$(HOME="$mock_home" "$BIN" config set mode text 2>&1); rc=$?
  ok "set on broken JSON -> exit 1" "$rc" 1
  contains "broken JSON reported" "$out" 'invalid JSON'
}

# Group: `tau config edit` — interactive $EDITOR edit, schema-checked on save.
# TAU_EDITOR is stubbed so the group runs fully offline/non-interactive.
test_group_config_editor() {
  local out rc mock_home cfg

  note "tau config edit (stubbed editor)"

  mock_home="$(mktemp -d)"; register_temp_dir "$mock_home"
  cfg="$mock_home/.config/tau/config.json"

  # Usage errors -> invalid_argument (80).
  "$BIN" config edit a b >/dev/null 2>&1;        ok "config edit two paths -> exit 80" "$?" 80
  "$BIN" config edit --bogus >/dev/null 2>&1;    ok "config edit unknown flag -> exit 80" "$?" 80
  "$BIN" config bogus >/dev/null 2>&1;           ok "config bogus subcommand -> exit 80" "$?" 80
  capture edti "$BIN" config edti
  contains "subcommand typo gets a hint" "$edti_err" 'did you mean \"edit\"?'

  # Missing file: seeded with the init scaffold, then the stubbed editor is a
  # no-op -> the scaffold validates clean.
  out=$(env -u VISUAL -u EDITOR HOME="$mock_home" TAU_EDITOR=true "$BIN" config edit); rc=$?
  ok "config edit missing file -> exit 0" "$rc" 0
  contains "edit reports ok:true" "$out" '"ok":true'
  contains "edit reports created:true" "$out" '"created":true'
  contains "edit reports valid" "$out" '"valid":true'
  if grep -q '^// ' "$cfg" 2>/dev/null && grep -q '"provider"' "$cfg"; then
    ok "missing file got the commented scaffold" 0 0
  else
    ok "missing file got the commented scaffold" 1 0
  fi

  # Editor that writes a misspelled key -> exit 1, validation report on stdout
  # with a did-you-mean hint; the bad content stays on disk.
  out=$(env -u VISUAL -u EDITOR HOME="$mock_home" TAU_EDITOR="printf '{\"proivder\":\"openai\"}' >" "$BIN" config edit); rc=$?
  ok "config edit bad save -> exit 1" "$rc" 1
  contains "report lists the typo" "$out" '"key":"proivder"'
  contains "did-you-mean hint on unknown key" "$out" 'did you mean \"provider\"?'
  contains "bad edit stays on disk" "$(cat "$cfg")" '"proivder"'

  # Editor exiting non-zero -> editor_failed envelope on stderr, exit 1.
  capture edfail env -u VISUAL -u EDITOR HOME="$mock_home" TAU_EDITOR=false "$BIN" config edit
  ok "editor exit 1 -> exit 1" "$edfail_rc" 1
  contains "editor_failed envelope on stderr" "$edfail_err" '"type":"editor_failed"'

  # --mode text prints the human-readable ok line.
  printf '{"provider":"openai"}' > "$cfg"
  out=$(env -u VISUAL -u EDITOR HOME="$mock_home" TAU_EDITOR=true "$BIN" config edit --mode text)
  contains "text mode ok line" "$out" ': ok'

  # Explicit path argument (existing file, no HOME needed for resolution).
  printf '{"proivder":true}' > "$mock_home/bad.json"
  out=$(env -u VISUAL -u EDITOR HOME="$mock_home" TAU_EDITOR=true "$BIN" config edit "$mock_home/bad.json"); rc=$?
  ok "config edit explicit path -> exit 1" "$rc" 1
  contains "explicit path in report" "$out" 'bad.json'
}

# Group: tau doctor — offline-first setup diagnostics (issue #127)
# All assertions run with --offline (or keyless --deep) so no real network or
# API key is needed; ambient keys/config are scrubbed via env -u + mock HOME.
test_group_doctor() {
  local rc mock_home mock_config

  note "tau doctor (offline diagnostics)"

  mock_home="$(mktemp -d)"
  register_temp_dir "$mock_home"
  mock_config="$mock_home/.config/tau"
  mkdir -p "$mock_config"

  # 1. Keyless env + no config file: api_key fails, exit 1, network checks skip.
  capture doc_keyless env -u XIAOMI_API_KEY -u PIZIG_API_KEY -u OPENAI_API_KEY -u DEEPSEEK_API_KEY -u OPENCODE_API_KEY -u TAU_API_KEY \
    HOME="$mock_home" "$BIN" doctor --offline
  ok "doctor --offline keyless exit 1" "$doc_keyless_rc" 1
  if printf '%s' "$doc_keyless_out" | python3 -c 'import sys,json;json.load(sys.stdin)' 2>/dev/null; then
    ok "doctor report is valid JSON" 0 0
  else
    ok "doctor report is valid JSON" 1 0
  fi
  contains "keyless report is not ok" "$doc_keyless_out" '"ok":false'
  contains "api_key check fails" "$doc_keyless_out" '"name":"api_key","status":"fail"'
  contains "api_key hint names provider env vars" "$doc_keyless_out" 'XIAOMI_API_KEY'
  contains "missing config file is ok" "$doc_keyless_out" '"name":"config_file","status":"ok"'
  contains "provider_resolution ok" "$doc_keyless_out" '"name":"provider_resolution","status":"ok"'
  contains "endpoint_reachable skipped offline" "$doc_keyless_out" '"name":"endpoint_reachable","status":"skip"'
  contains "auth_probe skipped offline" "$doc_keyless_out" '"name":"auth_probe","status":"skip"'
  contains "curl check present" "$doc_keyless_out" '"name":"curl"'
  contains "report has summary" "$doc_keyless_out" '"summary":{'

  # 2. Key via env + --provider override: local checks pass -> exit 0.
  capture doc_openai env -u XIAOMI_API_KEY -u PIZIG_API_KEY -u DEEPSEEK_API_KEY -u OPENCODE_API_KEY -u TAU_API_KEY \
    OPENAI_API_KEY=sk-doctor-secret HOME="$mock_home" "$BIN" doctor --offline --provider openai
  ok "doctor --offline --provider openai with key exit 0" "$doc_openai_rc" 0
  contains "report ok:true" "$doc_openai_out" '"ok":true'
  contains "provider override reported" "$doc_openai_out" 'provider=openai'
  contains "key source attributed to env" "$doc_openai_out" 'env:OPENAI_API_KEY'
  if printf '%s' "$doc_openai_out" | grep -qF 'sk-doctor-secret'; then
    ok "key material never printed" 1 0
  else
    ok "key material never printed" 0 0
  fi

  # 3. --model provider/id shorthand resolves the provider.
  capture doc_shorthand env -u XIAOMI_API_KEY -u PIZIG_API_KEY -u OPENAI_API_KEY -u DEEPSEEK_API_KEY -u OPENCODE_API_KEY -u TAU_API_KEY \
    HOME="$mock_home" "$BIN" doctor --offline --model deepseek/deepseek-reasoner
  contains "--model provider/id shorthand resolves" "$doc_shorthand_out" 'provider=deepseek'
  contains "shorthand model reported" "$doc_shorthand_out" 'model=deepseek-reasoner'

  # 4. Malformed config.json: config_file fails with the path; the remaining
  #    checks still run (no early abort).
  printf 'this is not valid json' > "$mock_config/config.json"
  capture doc_badcfg env -u XIAOMI_API_KEY -u PIZIG_API_KEY -u OPENAI_API_KEY -u DEEPSEEK_API_KEY -u OPENCODE_API_KEY -u TAU_API_KEY \
    HOME="$mock_home" "$BIN" doctor --offline
  ok "malformed config exit 1" "$doc_badcfg_rc" 1
  contains "config_file fails" "$doc_badcfg_out" '"name":"config_file","status":"fail"'
  contains "config_file message names path" "$doc_badcfg_out" '.config/tau/config.json'
  contains "api_key check still ran" "$doc_badcfg_out" '"name":"api_key"'
  contains "endpoint check still ran" "$doc_badcfg_out" '"name":"endpoint_reachable"'

  # 5. Config file naming an unknown provider: config_file warns and
  #    provider_resolution fails (exit 1, not the parse-error 80).
  printf '{"provider":"nope"}' > "$mock_config/config.json"
  capture doc_badprov env -u XIAOMI_API_KEY -u PIZIG_API_KEY -u OPENAI_API_KEY -u DEEPSEEK_API_KEY -u OPENCODE_API_KEY -u TAU_API_KEY \
    HOME="$mock_home" "$BIN" doctor --offline
  ok "unknown config provider exit 1" "$doc_badprov_rc" 1
  contains "config_file warns on unknown provider" "$doc_badprov_out" '"name":"config_file","status":"warn"'
  contains "provider_resolution fails" "$doc_badprov_out" '"name":"provider_resolution","status":"fail"'
  contains "provider_resolution names the bad provider" "$doc_badprov_out" "unknown provider 'nope'"

  # 6. Unknown --provider flag: also a report-level fail, not exit 80.
  rm -f "$mock_config/config.json"
  capture doc_flagprov env -u XIAOMI_API_KEY -u PIZIG_API_KEY -u OPENAI_API_KEY -u DEEPSEEK_API_KEY -u OPENCODE_API_KEY -u TAU_API_KEY \
    HOME="$mock_home" "$BIN" doctor --offline --provider nope
  ok "unknown --provider exit 1" "$doc_flagprov_rc" 1
  contains "flag provider_resolution fails" "$doc_flagprov_out" '"name":"provider_resolution","status":"fail"'

  # 7. --deep with no key: auth_probe still skips (nothing to probe).
  capture doc_deep env -u XIAOMI_API_KEY -u PIZIG_API_KEY -u OPENAI_API_KEY -u DEEPSEEK_API_KEY -u OPENCODE_API_KEY -u TAU_API_KEY \
    HOME="$mock_home" "$BIN" doctor --deep
  contains "--deep keyless auth_probe skips" "$doc_deep_out" '"name":"auth_probe","status":"skip"'

  # 8. Argument validation.
  "$BIN" doctor --bogus >/dev/null 2>&1; ok "doctor --bogus -> exit 80" "$?" 80
  "$BIN" doctor --provider >/dev/null 2>&1; ok "doctor --provider missing value -> exit 80" "$?" 80
  capture doc_pos "$BIN" doctor extra
  ok "doctor positional arg -> exit 80" "$doc_pos_rc" 80
  contains "positional error names the arg" "$doc_pos_err" 'unknown doctor argument'
  "$BIN" --help 2>&1 | grep -q "tau doctor" && ok "--help mentions tau doctor" 0 0 || ok "--help mentions tau doctor" 1 0

  # 9. curl missing from PATH: curl check fails with an install hint and the
  #    two network checks cascade-skip (env -i + empty PATH dir). --deep (not
  #    --offline) so both skips report the curl gate, not the offline gate.
  local empty_bin
  empty_bin="$(mktemp -d)"
  register_temp_dir "$empty_bin"
  capture doc_nocurl env -i PATH="$empty_bin" HOME="$mock_home" "$BIN" doctor --deep
  ok "no curl on PATH -> exit 1" "$doc_nocurl_rc" 1
  contains "curl check fails" "$doc_nocurl_out" '"name":"curl","status":"fail"'
  contains "curl failure message" "$doc_nocurl_out" 'curl not found on PATH'
  contains "curl hint is actionable" "$doc_nocurl_out" 'install curl'
  contains "endpoint skipped without curl" "$doc_nocurl_out" '"name":"endpoint_reachable","status":"skip","message":"skipped (curl unavailable)"'
  contains "auth_probe skipped without curl" "$doc_nocurl_out" '"name":"auth_probe","status":"skip","message":"skipped (curl unavailable)"'

  # 10. Warn does not fail the run: config file names an unknown provider but a
  #     valid --provider flag + key resolve everything else -> exit 0.
  printf '{"provider":"nope"}' > "$mock_config/config.json"
  capture doc_warn env -u XIAOMI_API_KEY -u PIZIG_API_KEY -u DEEPSEEK_API_KEY -u OPENCODE_API_KEY -u TAU_API_KEY \
    OPENAI_API_KEY=sk-warn HOME="$mock_home" "$BIN" doctor --offline --provider openai
  ok "warn-only report exits 0" "$doc_warn_rc" 0
  contains "config_file warns on unknown provider" "$doc_warn_out" '"name":"config_file","status":"warn"'
  contains "flag provider wins over config" "$doc_warn_out" 'provider=openai'
  contains "warn does not flip ok" "$doc_warn_out" '"ok":true'
  rm -f "$mock_config/config.json"

  # 11. doctor --fix (non-interactive, no --yes): fixable outcomes are listed
  #     in "fixes" but skipped — nothing is written without confirmation.
  rm -rf "$mock_home/.local" "$mock_home/.config"
  capture doc_fix_skip env -u XIAOMI_API_KEY -u PIZIG_API_KEY -u DEEPSEEK_API_KEY -u OPENCODE_API_KEY -u TAU_API_KEY \
    HOME="$mock_home" SHELL=/bin/bash "$BIN" doctor --offline --fix
  contains "--fix report carries a fixes array" "$doc_fix_skip_out" '"fixes":['
  contains "scaffold fix skipped without confirmation" "$doc_fix_skip_out" '"id":"scaffold_config","check":"config_file","status":"skipped"'
  contains "completions fix skipped without confirmation" "$doc_fix_skip_out" '"id":"install_completions","check":"shell_completions","status":"skipped"'
  contains "skipped fix points at --yes" "$doc_fix_skip_out" 'pass --yes'
  if [ ! -f "$mock_config/config.json" ] && [ ! -e "$mock_home/.local/share/bash-completion/completions/tau" ]; then
    ok "unconfirmed --fix wrote nothing" 0 0
  else
    ok "unconfirmed --fix wrote nothing" 1 0
  fi

  # 12. doctor --fix --yes: scaffold + completions apply, permissions tighten,
  #     and the emitted report reflects the post-fix state. TAU_API_KEY makes
  #     api_key resolvable so the whole post-fix report is ok -> exit 0.
  capture doc_fix_yes env -u XIAOMI_API_KEY -u PIZIG_API_KEY -u OPENAI_API_KEY -u DEEPSEEK_API_KEY -u OPENCODE_API_KEY \
    TAU_API_KEY=sk-fix HOME="$mock_home" SHELL=/bin/bash "$BIN" doctor --offline --fix --yes
  ok "--fix --yes all-fixable run exits 0" "$doc_fix_yes_rc" 0
  contains "scaffold fix applied" "$doc_fix_yes_out" '"id":"scaffold_config","check":"config_file","status":"applied"'
  contains "completions fix applied" "$doc_fix_yes_out" '"id":"install_completions","check":"shell_completions","status":"applied"'
  contains "post-fix config_file is ok" "$doc_fix_yes_out" '"name":"config_file","status":"ok","message":"config file parsed'
  contains "post-fix completions are ok" "$doc_fix_yes_out" '"name":"shell_completions","status":"ok"'
  if [ -f "$mock_config/config.json" ]; then
    ok "scaffolded config.json exists" 0 0
  else
    ok "scaffolded config.json exists" 1 0
  fi
  grep -q '"provider"' "$mock_config/config.json" && ok "scaffolded config has a provider" 0 0 || ok "scaffolded config has a provider" 1 0
  if [ -f "$mock_home/.local/share/bash-completion/completions/tau" ]; then
    ok "bash completion script installed" 0 0
  else
    ok "bash completion script installed" 1 0
  fi
  if [ "$(stat -c %a "$mock_config" 2>/dev/null)" = "700" ] && [ "$(stat -c %a "$mock_config/config.json" 2>/dev/null)" = "600" ]; then
    ok "scaffolded config lands with 0700/0600" 0 0
  else
    ok "scaffolded config lands with 0700/0600" 1 0
  fi

  # 13. --fix --yes on an invalid config: moved to .bak, fresh scaffold written.
  printf 'this is not valid json' > "$mock_config/config.json"
  chmod 644 "$mock_config/config.json"
  capture doc_fix_restore env -u XIAOMI_API_KEY -u PIZIG_API_KEY -u OPENAI_API_KEY -u DEEPSEEK_API_KEY -u OPENCODE_API_KEY \
    TAU_API_KEY=sk-fix HOME="$mock_home" SHELL=/bin/bash "$BIN" doctor --offline --fix --yes
  ok "restore run exits 0" "$doc_fix_restore_rc" 0
  contains "restore fix applied" "$doc_fix_restore_out" '"id":"restore_config","check":"config_file","status":"applied"'
  if [ -f "$mock_config/config.json.bak" ] && grep -q 'not valid json' "$mock_config/config.json.bak"; then
    ok "invalid config preserved at .bak" 0 0
  else
    ok "invalid config preserved at .bak" 1 0
  fi
  grep -q '"provider"' "$mock_config/config.json" && ok "restored config is a fresh scaffold" 0 0 || ok "restored config is a fresh scaffold" 1 0
  rm -f "$mock_config/config.json" "$mock_config/config.json.bak"

  # 14. -y/--yes implies --fix; bad --shell value is an arg error.
  capture doc_fix_short env -u XIAOMI_API_KEY -u PIZIG_API_KEY -u OPENAI_API_KEY -u DEEPSEEK_API_KEY -u OPENCODE_API_KEY -u TAU_API_KEY \
    HOME="$mock_home" SHELL=/bin/bash "$BIN" doctor --offline -y
  contains "-y implies --fix" "$doc_fix_short_out" '"fixes":['
  "$BIN" doctor --shell tcsh >/dev/null 2>&1; ok "doctor --shell tcsh -> exit 80" "$?" 80
  "$BIN" doctor --fix --shell >/dev/null 2>&1; ok "doctor --shell missing value -> exit 80" "$?" 80

  # 15. Live probe paths against a local stub HTTP server: endpoint_reachable
  #     treats ANY HTTP response as reachable, and --deep maps the auth probe's
  #     HTTP status to ok/fail/warn. Requires python3 + curl.
  if command -v python3 >/dev/null 2>&1 && command -v curl >/dev/null 2>&1; then
    local stub_dir stub_port stub_pid doc_stub doc_deep
    stub_dir="$(mktemp -d)"
    register_temp_dir "$stub_dir"
    echo 401 > "$stub_dir/code"
    cat > "$stub_dir/stub.py" <<'PYEOF'
import http.server, socketserver, sys
code_file, port = sys.argv[1], int(sys.argv[2])
class H(http.server.BaseHTTPRequestHandler):
    def _respond(self):
        try:
            code = int(open(code_file).read().strip())
        except Exception:
            code = 500
        body = b'{}'
        self.send_response(code)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    do_GET = _respond
    do_POST = _respond
    def log_message(self, *args):
        pass
socketserver.TCPServer(('127.0.0.1', port), H).serve_forever()
PYEOF
    stub_port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
    python3 "$stub_dir/stub.py" "$stub_dir/code" "$stub_port" &
    stub_pid=$!
    # Wait until the stub accepts TCP connections (HTTP status doesn't matter).
    local _i
    for _i in $(seq 1 50); do
      python3 -c "import socket; s=socket.create_connection(('127.0.0.1',$stub_port),1); s.close()" 2>/dev/null && break
      sleep 0.1
    done

    # a) 401 still counts as reachable; TAU_ENDPOINT drives the probe target.
    capture doc_stub env -u XIAOMI_API_KEY -u PIZIG_API_KEY -u DEEPSEEK_API_KEY -u OPENCODE_API_KEY -u TAU_API_KEY \
      OPENAI_API_KEY=sk-stub TAU_ENDPOINT="http://127.0.0.1:$stub_port/v1/chat/completions" \
      HOME="$mock_home" "$BIN" doctor --provider openai
    ok "stub endpoint run exits 0" "$doc_stub_rc" 0
    contains "TAU_ENDPOINT override honored" "$doc_stub_out" "endpoint=http://127.0.0.1:$stub_port"
    contains "401 still counts as reachable" "$doc_stub_out" '"name":"endpoint_reachable","status":"ok"'
    contains "reachable reports HTTP status" "$doc_stub_out" 'endpoint reachable (HTTP 401)'
    contains "auth_probe skips without --deep" "$doc_stub_out" '"name":"auth_probe","status":"skip"'

    # b) --deep + 401 -> auth_probe fails with an actionable hint; exit 1.
    capture doc_deep env -u XIAOMI_API_KEY -u PIZIG_API_KEY -u DEEPSEEK_API_KEY -u OPENCODE_API_KEY -u TAU_API_KEY \
      OPENAI_API_KEY=sk-stub TAU_ENDPOINT="http://127.0.0.1:$stub_port/v1/chat/completions" \
      HOME="$mock_home" "$BIN" doctor --provider openai --deep
    ok "deep probe 401 -> exit 1" "$doc_deep_rc" 1
    contains "auth_probe fails on 401" "$doc_deep_out" '"name":"auth_probe","status":"fail"'
    contains "auth rejection is actionable" "$doc_deep_out" 'API key rejected (HTTP 401)'
    contains "auth hint names the fix" "$doc_deep_out" 'verify the key'
    contains "report not ok" "$doc_deep_out" '"ok":false'
    if printf '%s' "$doc_deep_out" | grep -qF 'sk-stub'; then
      ok "auth probe never prints key material" 1 0
    else
      ok "auth probe never prints key material" 0 0
    fi

    # c) --deep + 200 -> auth_probe ok; exit 0.
    echo 200 > "$stub_dir/code"
    capture doc_deep env -u XIAOMI_API_KEY -u PIZIG_API_KEY -u DEEPSEEK_API_KEY -u OPENCODE_API_KEY -u TAU_API_KEY \
      OPENAI_API_KEY=sk-stub TAU_ENDPOINT="http://127.0.0.1:$stub_port/v1/chat/completions" \
      HOME="$mock_home" "$BIN" doctor --provider openai --deep
    ok "deep probe 200 -> exit 0" "$doc_deep_rc" 0
    contains "auth_probe ok on 200" "$doc_deep_out" '"name":"auth_probe","status":"ok"'
    contains "auth success reports HTTP" "$doc_deep_out" 'authenticated probe succeeded (HTTP 200)'

    # d) --deep + 429 -> warn, not fail; exit 0.
    echo 429 > "$stub_dir/code"
    capture doc_deep env -u XIAOMI_API_KEY -u PIZIG_API_KEY -u DEEPSEEK_API_KEY -u OPENCODE_API_KEY -u TAU_API_KEY \
      OPENAI_API_KEY=sk-stub TAU_ENDPOINT="http://127.0.0.1:$stub_port/v1/chat/completions" \
      HOME="$mock_home" "$BIN" doctor --provider openai --deep
    ok "deep probe 429 warn -> exit 0" "$doc_deep_rc" 0
    contains "auth_probe warns on 429" "$doc_deep_out" '"name":"auth_probe","status":"warn"'
    contains "429 message explains undetermined" "$doc_deep_out" 'rate limited'
    contains "warn keeps report ok" "$doc_deep_out" '"ok":true'

    kill "$stub_pid" 2>/dev/null
    wait "$stub_pid" 2>/dev/null
  else
    skip_test "doctor live-probe checks" "python3 or curl not available"
  fi

  # 16. --json streams NDJSON: {"check":{...},"done":false} per check plus a
  #     terminal {"ok":...,"summary":{...},"done":true} verdict as the last
  #     line. Exit code is unchanged (keyless -> 1).
  rm -f "$mock_config/config.json"
  capture doc_json env -u XIAOMI_API_KEY -u PIZIG_API_KEY -u OPENAI_API_KEY -u DEEPSEEK_API_KEY -u OPENCODE_API_KEY -u TAU_API_KEY \
    HOME="$mock_home" "$BIN" doctor --offline --json
  ok "doctor --json keyless exit 1" "$doc_json_rc" 1
  if printf '%s\n' "$doc_json_out" | python3 -c '
import sys, json
lines = [l for l in sys.stdin.read().splitlines() if l.strip()]
events = [json.loads(l) for l in lines]
assert len(events) >= 2, "expected check events plus a verdict line"
assert all(e.get("done") is False for e in events[:-1]), "a non-terminal event ended the stream"
assert events[-1].get("done") is True, "last line is not the done:true verdict"
assert "ok" in events[-1] and "summary" in events[-1], "verdict missing ok/summary"
names = [e["check"]["name"] for e in events[:-1]]
for want in ("config_file", "provider_resolution", "api_key", "curl", "endpoint_reachable", "auth_probe"):
    assert want in names, "missing check event: %s" % want
' 2>/dev/null; then
    ok "doctor --json emits well-formed NDJSON events" 0 0
  else
    ok "doctor --json emits well-formed NDJSON events" 1 0
  fi
  contains "check events carry the report check shape" "$doc_json_out" '"check":{"name":"api_key","status":"fail"'
  contains "verdict reports ok:false" "$doc_json_out" '"ok":false'
  contains "verdict line carries done:true" "$doc_json_out" '"done":true'

  # 17. --json --fix --yes: fix events stream between the first-pass check
  #     events and the verdict; re-diagnosed checks re-emit post-fix state.
  rm -rf "$mock_home/.local" "$mock_home/.config"
  capture doc_json_fix env -u XIAOMI_API_KEY -u PIZIG_API_KEY -u DEEPSEEK_API_KEY -u OPENCODE_API_KEY \
    TAU_API_KEY=sk-fix HOME="$mock_home" SHELL=/bin/bash "$BIN" doctor --offline --json --fix --yes
  ok "doctor --json --fix --yes exits 0" "$doc_json_fix_rc" 0
  contains "fix events carry done:false payload" "$doc_json_fix_out" '"fix":{"id":"scaffold_config","check":"config_file","status":"applied"'
  contains "post-fix check re-emitted ok" "$doc_json_fix_out" '"check":{"name":"config_file","status":"ok","message":"config file parsed'
  contains "verdict carries the fixes array" "$doc_json_fix_out" '"fixes":['
  if printf '%s\n' "$doc_json_fix_out" | tail -n 1 | grep -q '"done":true'; then
    ok "verdict is the last NDJSON line" 0 0
  else
    ok "verdict is the last NDJSON line" 1 0
  fi

  # 18. --report renders a redacted Markdown bundle: verdict, build metadata,
  #     the checks table, effective settings, and the config file verbatim
  #     (credentials masked). Exit code is unchanged (keyless -> 1).
  rm -f "$mock_config/config.json"
  capture doc_report env -u XIAOMI_API_KEY -u PIZIG_API_KEY -u OPENAI_API_KEY -u DEEPSEEK_API_KEY -u OPENCODE_API_KEY -u TAU_API_KEY \
    HOME="$mock_home" "$BIN" doctor --offline --report
  ok "doctor --report keyless exit 1" "$doc_report_rc" 1
  contains "report has a markdown title" "$doc_report_out" '# tau doctor report'
  contains "report states the verdict" "$doc_report_out" '**Verdict:** **FAILING**'
  contains "report has a build table" "$doc_report_out" '| commit | `'
  contains "build table carries zig version" "$doc_report_out" '| zig | `'
  contains "report has a checks table" "$doc_report_out" '| check | status | message | hint |'
  contains "checks table lists api_key fail" "$doc_report_out" '| `api_key` | **fail** |'
  contains "endpoint skip row present" "$doc_report_out" '| `endpoint_reachable` | skip |'
  contains "report has effective config" "$doc_report_out" '## Effective configuration'
  contains "key source reports none resolved" "$doc_report_out" '| api_key_source | `none resolved` |'
  contains "missing config noted" "$doc_report_out" '_No config file at `'
  if printf '%s' "$doc_report_out" | grep -q '"ok"'; then
    ok "report is not the JSON shape" 1 0
  else
    ok "report is not the JSON shape" 0 0
  fi

  # 19. --report embeds the config file with credentials masked: the literal
  #     key under keys.openai never appears in the bundle.
  printf '{ "provider": "openai", "keys": { "openai": "sk-report-secret-456" } }' > "$mock_config/config.json"
  capture doc_report_cfg env -u XIAOMI_API_KEY -u PIZIG_API_KEY -u DEEPSEEK_API_KEY -u OPENCODE_API_KEY -u TAU_API_KEY \
    HOME="$mock_home" "$BIN" doctor --offline --report --provider openai
  ok "report with config + env-less key exits 0" "$doc_report_cfg_rc" 0
  contains "config dump is embedded" "$doc_report_cfg_out" '```jsonc'
  contains "key source attributed to config keys" "$doc_report_cfg_out" '| api_key_source | `keys[openai]` |'
  if printf '%s' "$doc_report_cfg_out" | grep -qF 'sk-report-secret-456'; then
    ok "report never prints key material" 1 0
  else
    ok "report never prints key material" 0 0
  fi
  contains "key literal is masked" "$doc_report_cfg_out" '***REDACTED***'
  rm -f "$mock_config/config.json"

  # 20. --report + --json is an invalid-argument error (mutually exclusive).
  "$BIN" doctor --report --json >/dev/null 2>&1; ok "doctor --report --json -> exit 80" "$?" 80
  "$BIN" --help 2>&1 | grep -q -- "--report" && ok "--help mentions --report" 0 0 || ok "--help mentions --report" 1 0

  # 21. --probe live-verifies every provider: without it a single
  #     provider_probes row advertises the sweep; with it each registry
  #     provider gets a connectivity row (probe_<name>) and a credential row
  #     (probe_<name>_auth). Offline keeps everything skipped; the stub
  #     server exercises real pass/fail for the configured provider.
  rm -f "$mock_config/config.json"
  capture doc_noprobe env -u XIAOMI_API_KEY -u PIZIG_API_KEY -u OPENAI_API_KEY -u DEEPSEEK_API_KEY -u OPENCODE_API_KEY -u TAU_API_KEY \
    HOME="$mock_home" "$BIN" doctor --offline
  contains "default run advertises --probe" "$doc_noprobe_out" '"name":"provider_probes","status":"skip"'
  contains "placeholder hint mentions --probe" "$doc_noprobe_out" 'pass --probe'
  if printf '%s' "$doc_noprobe_out" | grep -qF '"name":"probe_openai"'; then
    ok "no per-provider rows without --probe" 1 0
  else
    ok "no per-provider rows without --probe" 0 0
  fi

  capture doc_probe_off env -u XIAOMI_API_KEY -u PIZIG_API_KEY -u OPENAI_API_KEY -u DEEPSEEK_API_KEY -u OPENCODE_API_KEY -u TAU_API_KEY \
    HOME="$mock_home" "$BIN" doctor --offline --probe
  ok "doctor --offline --probe keyless exit 1" "$doc_probe_off_rc" 1
  contains "probe connectivity row skipped offline" "$doc_probe_off_out" '"name":"probe_openai","status":"skip"'
  contains "probe auth row skipped offline" "$doc_probe_off_out" '"name":"probe_openai_auth","status":"skip"'
  contains "probe sweep covers xiaomi" "$doc_probe_off_out" '"name":"probe_xiaomi","status":"skip"'
  contains "probe sweep covers deepseek" "$doc_probe_off_out" '"name":"probe_deepseek_auth","status":"skip"'
  contains "probe sweep covers opencode-go" "$doc_probe_off_out" '"name":"probe_opencode-go","status":"skip"'
  if printf '%s' "$doc_probe_off_out" | grep -qF '"name":"provider_probes"'; then
    ok "no placeholder row once --probe runs" 1 0
  else
    ok "no placeholder row once --probe runs" 0 0
  fi

  # --probe streams its per-provider rows as NDJSON check events under --json.
  capture doc_probe_json env -u XIAOMI_API_KEY -u PIZIG_API_KEY -u OPENAI_API_KEY -u DEEPSEEK_API_KEY -u OPENCODE_API_KEY -u TAU_API_KEY \
    HOME="$mock_home" "$BIN" doctor --offline --probe --json
  contains "--probe rows stream as check events" "$doc_probe_json_out" '"check":{"name":"probe_openai","status":"skip"'
  contains "--probe auth rows stream too" "$doc_probe_json_out" '"check":{"name":"probe_deepseek_auth","status":"skip"'
  contains "--json verdict still terminates" "$doc_probe_json_out" '"done":true'

  # Live sweep against the stub: the configured provider (openai) probes the
  # stub via TAU_ENDPOINT; a 401 rejects its credential (exit 1), a 200
  # verifies it. Other providers' rows are not asserted — their endpoints are
  # real and connectivity depends on the runner's network.
  if command -v python3 >/dev/null 2>&1 && command -v curl >/dev/null 2>&1; then
    local pstub_dir pstub_port pstub_pid doc_probe
    pstub_dir="$(mktemp -d)"
    register_temp_dir "$pstub_dir"
    echo 401 > "$pstub_dir/code"
    cat > "$pstub_dir/stub.py" <<'PYEOF'
import http.server, socketserver, sys
code_file, port = sys.argv[1], int(sys.argv[2])
class H(http.server.BaseHTTPRequestHandler):
    def _respond(self):
        try:
            code = int(open(code_file).read().strip())
        except Exception:
            code = 500
        body = b'{}'
        self.send_response(code)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    do_GET = _respond
    do_POST = _respond
    def log_message(self, *args):
        pass
socketserver.TCPServer(('127.0.0.1', port), H).serve_forever()
PYEOF
    pstub_port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
    python3 "$pstub_dir/stub.py" "$pstub_dir/code" "$pstub_port" &
    pstub_pid=$!
    local _i
    for _i in $(seq 1 50); do
      python3 -c "import socket; s=socket.create_connection(('127.0.0.1',$pstub_port),1); s.close()" 2>/dev/null && break
      sleep 0.1
    done

    capture doc_probe env -u XIAOMI_API_KEY -u PIZIG_API_KEY -u DEEPSEEK_API_KEY -u OPENCODE_API_KEY -u TAU_API_KEY \
      OPENAI_API_KEY=sk-probe-stub TAU_ENDPOINT="http://127.0.0.1:$pstub_port/v1/chat/completions" \
      HOME="$mock_home" "$BIN" doctor --provider openai --probe
    ok "probe sweep with a rejected key exits 1" "$doc_probe_rc" 1
    contains "stub endpoint counts as reachable" "$doc_probe_out" '"name":"probe_openai","status":"ok"'
    contains "reachable reports HTTP status" "$doc_probe_out" 'endpoint reachable (HTTP 401)'
    contains "probe auth fails on 401" "$doc_probe_out" '"name":"probe_openai_auth","status":"fail"'
    contains "rejection names the redacted source" "$doc_probe_out" 'credentials rejected (HTTP 401, source: env:OPENAI_API_KEY)'
    # Unkeyed providers always skip their credential row — the message varies
    # with connectivity ("endpoint unreachable" vs "no credentials resolved").
    contains "unkeyed provider auth skips" "$doc_probe_out" '"name":"probe_deepseek_auth","status":"skip"'
    if printf '%s' "$doc_probe_out" | grep -qF 'sk-probe-stub'; then
      ok "probe sweep never prints key material" 1 0
    else
      ok "probe sweep never prints key material" 0 0
    fi

    echo 200 > "$pstub_dir/code"
    capture doc_probe env -u XIAOMI_API_KEY -u PIZIG_API_KEY -u DEEPSEEK_API_KEY -u OPENCODE_API_KEY -u TAU_API_KEY \
      OPENAI_API_KEY=sk-probe-stub TAU_ENDPOINT="http://127.0.0.1:$pstub_port/v1/chat/completions" \
      HOME="$mock_home" "$BIN" doctor --provider openai --probe
    contains "probe auth verifies on 200" "$doc_probe_out" '"name":"probe_openai_auth","status":"ok"'
    contains "verification reports source" "$doc_probe_out" 'credentials verified (HTTP 200, source: env:OPENAI_API_KEY)'

    kill "$pstub_pid" 2>/dev/null
    wait "$pstub_pid" 2>/dev/null
  else
    skip_test "doctor --probe live sweep" "python3 or curl not available"
  fi

  "$BIN" --help 2>&1 | grep -q -- "--probe" && ok "--help mentions --probe" 0 0 || ok "--help mentions --probe" 1 0

  # 22. --selftest: credential-free end-to-end run — the check spawns the tau
  #     binary itself with a scrubbed env (throwaway HOME, stub TAU_API_KEY,
  #     TAU_ENDPOINT -> 127.0.0.1) and requires the canned reply back. It is
  #     loopback-only by construction, so it runs under --offline. Without
  #     the flag the row advertises it instead of running.
  contains "default run advertises --selftest" "$doc_noprobe_out" '"name":"selftest","status":"skip"'
  contains "selftest placeholder hint names the flag" "$doc_noprobe_out" 'pass --selftest'

  if command -v curl >/dev/null 2>&1; then
    capture doc_selftest env -u XIAOMI_API_KEY -u PIZIG_API_KEY -u OPENAI_API_KEY -u DEEPSEEK_API_KEY -u OPENCODE_API_KEY -u TAU_API_KEY \
      HOME="$mock_home" "$BIN" doctor --offline --selftest
    contains "selftest runs end-to-end under --offline" "$doc_selftest_out" '"name":"selftest","status":"ok"'
    contains "selftest reports the stub session" "$doc_selftest_out" 'loopback stub provider succeeded'

    # Credential-free guarantee: ambient keys + a dead ambient TAU_ENDPOINT
    # must not leak into the child — a passing row proves the scrub.
    capture doc_selftest_iso env -u XIAOMI_API_KEY -u PIZIG_API_KEY -u DEEPSEEK_API_KEY -u OPENCODE_API_KEY -u TAU_API_KEY \
      OPENAI_API_KEY=sk-should-not-leak TAU_ENDPOINT="http://127.0.0.1:1/dead" \
      HOME="$mock_home" "$BIN" doctor --offline --selftest
    contains "selftest ignores ambient endpoint and keys" "$doc_selftest_iso_out" '"name":"selftest","status":"ok"'
    if printf '%s' "$doc_selftest_iso_out" | grep -qF 'sk-should-not-leak'; then
      ok "selftest never prints ambient key material" 1 0
    else
      ok "selftest never prints ambient key material" 0 0
    fi

    # --json streams the selftest row as a check event like any other check.
    capture doc_selftest_json env -u XIAOMI_API_KEY -u PIZIG_API_KEY -u OPENAI_API_KEY -u DEEPSEEK_API_KEY -u OPENCODE_API_KEY -u TAU_API_KEY \
      HOME="$mock_home" "$BIN" doctor --offline --selftest --json
    contains "selftest streams as a check event" "$doc_selftest_json_out" '"check":{"name":"selftest","status":"ok"'
    contains "selftest json verdict terminates" "$doc_selftest_json_out" '"done":true'
  else
    capture doc_selftest_nocurl env -u XIAOMI_API_KEY -u PIZIG_API_KEY -u OPENAI_API_KEY -u DEEPSEEK_API_KEY -u OPENCODE_API_KEY -u TAU_API_KEY \
      HOME="$mock_home" "$BIN" doctor --offline --selftest
    contains "selftest skips without curl" "$doc_selftest_nocurl_out" '"name":"selftest","status":"skip"'
    contains "selftest skip names curl" "$doc_selftest_nocurl_out" 'curl unavailable'
  fi

  "$BIN" --help 2>&1 | grep -q -- "--selftest" && ok "--help mentions --selftest" 0 0 || ok "--help mentions --selftest" 1 0
}

# Group: tau bug — pre-filled GitHub issue carrying the redacted doctor bundle
test_group_bug() {
  local mock_home mock_config

  note "tau bug (pre-filled GitHub issue + redacted diagnostics bundle)"

  mock_home="$(mktemp -d)"
  register_temp_dir "$mock_home"
  mock_config="$mock_home/.config/tau"
  mkdir -p "$mock_config"

  # 1. Bare run (keyless, offline): exit 0 — the diagnostics verdict lives in
  #    the bundle, not the exit status — with the issues/new URL + report.
  capture bug_basic env -u XIAOMI_API_KEY -u PIZIG_API_KEY -u OPENAI_API_KEY -u DEEPSEEK_API_KEY -u OPENCODE_API_KEY -u TAU_API_KEY \
    HOME="$mock_home" "$BIN" bug --offline
  ok "tau bug exits 0" "$bug_basic_rc" 0
  if printf '%s' "$bug_basic_out" | python3 -c 'import sys,json;json.load(sys.stdin)' 2>/dev/null; then
    ok "bug output is valid JSON" 0 0
  else
    ok "bug output is valid JSON" 1 0
  fi
  contains "url points at issues/new" "$bug_basic_out" '"url":"https://github.com/javimosch/tau/issues/new?title='
  contains "default title encoded" "$bug_basic_out" 'title=Bug%20report'
  contains "default labels field" "$bug_basic_out" '"labels":"bug"'
  contains "labels param in URL" "$bug_basic_out" '&labels=bug'
  contains "report field carries the bundle" "$bug_basic_out" '"report":"# tau doctor report'
  contains "body carries the bundle" "$bug_basic_out" '"body":"# tau doctor report'
  contains "verdict inside the bundle" "$bug_basic_out" 'Verdict'
  contains "not truncated" "$bug_basic_out" '"url_truncated":false'
  contains "not opened" "$bug_basic_out" '"opened":false'
  contains "no out file" "$bug_basic_out" '"out":null'
  contains "done:true" "$bug_basic_out" '"done":true'

  # 2. --title/--body/--labels: encoded into the URL; description precedes the
  #    bundle in the emitted body.
  capture bug_custom env -u XIAOMI_API_KEY -u PIZIG_API_KEY -u OPENAI_API_KEY -u DEEPSEEK_API_KEY -u OPENCODE_API_KEY -u TAU_API_KEY \
    HOME="$mock_home" "$BIN" bug --offline --title "crash on --deep" --body "it broke" --labels "bug,triage"
  ok "custom bug exits 0" "$bug_custom_rc" 0
  contains "custom title in JSON" "$bug_custom_out" '"title":"crash on --deep"'
  contains "title URL-encoded" "$bug_custom_out" 'title=crash%20on%20--deep'
  contains "labels csv URL-encoded" "$bug_custom_out" '&labels=bug%2Ctriage'
  contains "body starts with description" "$bug_custom_out" '"body":"it broke\n\n---'
  contains "bundle follows the description" "$bug_custom_out" 'tau doctor report'

  # 3. --no-report: report:null and the URL body carries the omission note.
  capture bug_norep env -u XIAOMI_API_KEY -u PIZIG_API_KEY -u OPENAI_API_KEY -u DEEPSEEK_API_KEY -u OPENCODE_API_KEY -u TAU_API_KEY \
    HOME="$mock_home" "$BIN" bug --offline --no-report
  ok "bug --no-report exits 0" "$bug_norep_rc" 0
  contains "report is null" "$bug_norep_out" '"report":null'
  contains "placeholder description in URL" "$bug_norep_out" '_Describe%20the%20bug%20here'
  contains "omission note in body" "$bug_norep_out" '_No diagnostics attached'
  if printf '%s' "$bug_norep_out" | grep -qF 'tau doctor report'; then
    ok "no bundle leaked under --no-report" 1 0
  else
    ok "no bundle leaked under --no-report" 0 0
  fi

  # 4. --out writes the redacted bundle to a file and reports the path.
  capture bug_out env -u XIAOMI_API_KEY -u PIZIG_API_KEY -u OPENAI_API_KEY -u DEEPSEEK_API_KEY -u OPENCODE_API_KEY -u TAU_API_KEY \
    HOME="$mock_home" "$BIN" bug --offline --out "$mock_home/report.md"
  ok "bug --out exits 0" "$bug_out_rc" 0
  contains "out path in JSON" "$bug_out_out" '"out":"'
  if [ -f "$mock_home/report.md" ] && grep -qF '# tau doctor report' "$mock_home/report.md"; then
    ok "--out wrote the bundle file" 0 0
  else
    ok "--out wrote the bundle file" 1 0
  fi

  # 5. Argument validation: mutex + unknown flag + missing value.
  "$BIN" bug --out x.md --no-report >/dev/null 2>&1; ok "bug --out --no-report -> exit 80" "$?" 80
  "$BIN" bug --bogus >/dev/null 2>&1; ok "bug --bogus -> exit 80" "$?" 80
  "$BIN" bug --title >/dev/null 2>&1; ok "bug --title missing value -> exit 80" "$?" 80
  capture bug_mutex "$BIN" bug --out x.md --no-report
  contains "mutex error message" "$bug_mutex_err" 'mutually exclusive'
  capture bug_badarg "$BIN" bug --bogus
  contains "unknown-arg error names the flag" "$bug_badarg_err" 'unknown bug argument'
  "$BIN" --help 2>&1 | grep -q "tau bug" && ok "--help mentions tau bug" 0 0 || ok "--help mentions tau bug" 1 0

  # 6. --open launches the issue URL via $BROWSER; a missing opener degrades to
  #    opened:false without failing the command.
  local stub_dir
  stub_dir="$(mktemp -d)"
  register_temp_dir "$stub_dir"
  printf '#!/bin/sh\nprintf "%%s" "$1" > "%s/opened-url"\n' "$stub_dir" > "$stub_dir/browser"
  chmod +x "$stub_dir/browser"
  capture bug_open env -u XIAOMI_API_KEY -u PIZIG_API_KEY -u OPENAI_API_KEY -u DEEPSEEK_API_KEY -u OPENCODE_API_KEY -u TAU_API_KEY \
    BROWSER="$stub_dir/browser" HOME="$mock_home" "$BIN" bug --offline --open
  ok "bug --open exits 0" "$bug_open_rc" 0
  contains "opened:true with a working opener" "$bug_open_out" '"opened":true'
  if [ -f "$stub_dir/opened-url" ] && grep -qF 'issues/new' "$stub_dir/opened-url"; then
    ok "opener received the issues/new URL" 0 0
  else
    ok "opener received the issues/new URL" 1 0
  fi
  capture bug_noopen env -u XIAOMI_API_KEY -u PIZIG_API_KEY -u OPENAI_API_KEY -u DEEPSEEK_API_KEY -u OPENCODE_API_KEY -u TAU_API_KEY \
    BROWSER=/nonexistent-browser-cmd HOME="$mock_home" "$BIN" bug --offline --open
  ok "missing opener still exits 0" "$bug_noopen_rc" 0
  contains "opened:false when the opener fails" "$bug_noopen_out" '"opened":false'

  # 7. Redaction: a key literal in the config file is masked inside the bundle
  #    exactly like `doctor --report`.
  printf '{ "provider": "openai", "keys": { "openai": "sk-bug-secret-789" } }' > "$mock_config/config.json"
  capture bug_redact env -u XIAOMI_API_KEY -u PIZIG_API_KEY -u DEEPSEEK_API_KEY -u OPENCODE_API_KEY -u TAU_API_KEY \
    OPENAI_API_KEY=sk-env-secret HOME="$mock_home" "$BIN" bug --offline --provider openai
  ok "bug with keyed config exits 0" "$bug_redact_rc" 0
  if printf '%s' "$bug_redact_out" | grep -qF 'sk-bug-secret-789'; then
    ok "config key literal never in output" 1 0
  else
    ok "config key literal never in output" 0 0
  fi
  if printf '%s' "$bug_redact_out" | grep -qF 'sk-env-secret'; then
    ok "env key literal never in output" 1 0
  else
    ok "env key literal never in output" 0 0
  fi
  contains "key literal is masked" "$bug_redact_out" '***REDACTED***'

  # 8. Over-long bundle: a large config file pushes the URL past the cap, so
  #    the link falls back to a short body (url_truncated:true) while the JSON
  #    body/report fields keep the full bundle.
  { printf '// padding to inflate the embedded config dump\n// '; head -c 9000 /dev/zero | tr '\0' 'x'; printf '\n'; } > "$mock_config/config.json"
  capture bug_trunc env -u XIAOMI_API_KEY -u PIZIG_API_KEY -u OPENAI_API_KEY -u DEEPSEEK_API_KEY -u OPENCODE_API_KEY -u TAU_API_KEY \
    HOME="$mock_home" "$BIN" bug --offline
  ok "oversized bundle still exits 0" "$bug_trunc_rc" 0
  contains "url_truncated:true" "$bug_trunc_out" '"url_truncated":true'
  contains "URL falls back to the short body" "$bug_trunc_out" 'Diagnostics%20bundle%20omitted'
  contains "JSON body keeps the full bundle" "$bug_trunc_out" '"body":"# tau doctor report'
  if printf '%s' "$bug_trunc_out" | grep -qF 'tau%20doctor%20report'; then
    ok "encoded bundle dropped from the URL" 1 0
  else
    ok "encoded bundle dropped from the URL" 0 0
  fi
  rm -f "$mock_config/config.json"

  # 9. Unknown --provider rides into the bundle as a failed check (exit 0, not
  #    the parse-error 80) — same convention as `tau doctor`.
  capture bug_badprov env -u XIAOMI_API_KEY -u PIZIG_API_KEY -u OPENAI_API_KEY -u DEEPSEEK_API_KEY -u OPENCODE_API_KEY -u TAU_API_KEY \
    HOME="$mock_home" "$BIN" bug --offline --provider nope
  ok "unknown provider still exits 0" "$bug_badprov_rc" 0
  contains "bad provider inside the bundle" "$bug_badprov_out" "unknown provider 'nope'"
}

# Group: tau init — commented starter config scaffold
test_group_init() {
  local mock_home warn

  note "tau init scaffolds a commented config seeded from detected env keys"

  mock_home="$(mktemp -d)"
  register_temp_dir "$mock_home"

  # Fresh HOME -> creates ~/.config/tau/config.json, reports created:true.
  capture init_write env HOME="$mock_home" "$BIN" init
  ok "init on fresh HOME exits 0" "$init_write_rc" 0
  if printf '%s' "$init_write_out" | grep -q '"created":true'; then
    ok "init reports created:true" 0 0
  else
    ok "init reports created:true" 1 0
  fi
  if [ -f "$mock_home/.config/tau/config.json" ]; then
    ok "init wrote ~/.config/tau/config.json" 0 0
  else
    ok "init wrote ~/.config/tau/config.json" 1 0
  fi
  if grep -q '^// ' "$mock_home/.config/tau/config.json" 2>/dev/null && grep -q '"provider"' "$mock_home/.config/tau/config.json"; then
    ok "config has comments + provider key" 0 0
  else
    ok "config has comments + provider key" 1 0
  fi

  # Generated (commented) config must load without the invalid-JSON warning.
  warn=$(HOME="$mock_home" "$BIN" --version 2>&1 1>/dev/null)
  if printf '%s' "$warn" | grep -q 'invalid JSON'; then
    ok "generated JSONC config loads without warning" 1 0
  else
    ok "generated JSONC config loads without warning" 0 0
  fi

  # Existing config -> refused without --force (exit 1, JSON err envelope).
  capture init_again env HOME="$mock_home" "$BIN" init
  ok "init on existing config exits 1" "$init_again_rc" 1
  if printf '%s' "$init_again_err" | grep -q '"already_exists"'; then
    ok "init existing -> already_exists envelope" 0 0
  else
    ok "init existing -> already_exists envelope" 1 0
  fi

  # --force overwrites and reports it.
  capture init_force env HOME="$mock_home" "$BIN" init --force
  ok "init --force exits 0" "$init_force_rc" 0
  if printf '%s' "$init_force_out" | grep -q '"overwritten":true'; then
    ok "init --force reports overwritten:true" 0 0
  else
    ok "init --force reports overwritten:true" 1 0
  fi

  # --stdout prints the scaffold without writing; detected env key selects the
  # provider and is named in a comment, but the secret value never appears.
  rm -f "$mock_home/.config/tau/config.json"
  capture init_stdout env -u XIAOMI_API_KEY -u PIZIG_API_KEY -u DEEPSEEK_API_KEY \
    -u OPENCODE_API_KEY -u TAU_API_KEY HOME="$mock_home" OPENAI_API_KEY=smoke-secret "$BIN" init --stdout
  ok "init --stdout exits 0" "$init_stdout_rc" 0
  if printf '%s' "$init_stdout_out" | grep -q '"provider": "openai"'; then
    ok "init --stdout picks detected provider (openai)" 0 0
  else
    ok "init --stdout picks detected provider (openai)" 1 0
  fi
  if printf '%s' "$init_stdout_out" | grep -q 'smoke-secret'; then
    ok "init --stdout never leaks the key value" 1 0
  else
    ok "init --stdout never leaks the key value" 0 0
  fi
  if [ -f "$mock_home/.config/tau/config.json" ]; then
    ok "init --stdout does not write a file" 1 0
  else
    ok "init --stdout does not write a file" 0 0
  fi

  # --provider overrides detection.
  capture init_prov env HOME="$mock_home" "$BIN" init --provider deepseek --stdout
  if printf '%s' "$init_prov_out" | grep -q '"provider": "deepseek"'; then
    ok "init --provider selects the given provider" 0 0
  else
    ok "init --provider selects the given provider" 1 0
  fi

  # Bad arguments.
  "$BIN" init --bogus >/dev/null 2>&1; ok "init --bogus -> exit 80" "$?" 80
  "$BIN" init --provider acme >/dev/null 2>&1; ok "init --provider acme -> exit 80" "$?" 80
}

# Group: tau setup — one-shot onboarding (init + completions + doctor)
# All runs use --offline so no real network/API key is needed; ambient keys
# and config are scrubbed via env -u + mock HOME.
test_group_setup() {
  local mock_home line1 line2 line3 line4 line5

  note "tau setup scaffolds config, installs completions, embeds doctor"

  mock_home="$(mktemp -d)"
  register_temp_dir "$mock_home"

  # Fresh HOME + detected zsh + a provider env key -> all steps ok, exit 0.
  capture s1 env -u OPENAI_API_KEY -u DEEPSEEK_API_KEY -u OPENCODE_API_KEY -u TAU_API_KEY -u PIZIG_API_KEY \
    HOME="$mock_home" SHELL=/bin/zsh XIAOMI_API_KEY=smoke-key "$BIN" setup --offline
  ok "setup on fresh HOME exits 0" "$s1_rc" 0
  line1=$(printf '%s' "$s1_out" | sed -n '1p')
  line2=$(printf '%s' "$s1_out" | sed -n '2p')
  line3=$(printf '%s' "$s1_out" | sed -n '3p')
  line4=$(printf '%s' "$s1_out" | sed -n '4p')
  line5=$(printf '%s' "$s1_out" | sed -n '5p')
  contains "line 1 is the init step, status created" "$line1" '"step":"init","status":"created"'
  contains "init reports the config path" "$line1" '"config_path":'
  contains "line 2 is the completions step" "$line2" '"step":"completions","status":"installed"'
  contains "completions detected zsh" "$line2" '"shell":"zsh"'
  contains "zsh rc was appended" "$line2" '"rc_status":"appended"'
  contains "line 3 is the clients step, skipped without --client" "$line3" '"step":"clients","status":"skipped"'
  contains "clients step reports detection + hint" "$line3" '"detected":'
  contains "line 4 embeds the doctor report" "$line4" '"step":"doctor","report":{"ok":true'
  contains "line 5 is the setup verdict" "$line5" '"step":"setup","ok":true'
  contains "verdict carries the version" "$line5" '"version":'

  # Files actually landed.
  [ -f "$mock_home/.config/tau/config.json" ]; ok "config.json was written" "$?" 0
  [ -f "$mock_home/.zsh/completions/_tau" ]; ok "zsh completion installed" "$?" 0
  [ -f "$mock_home/.zshrc" ]; ok ".zshrc created" "$?" 0
  # The installed file is the embedded script — byte-identical to the repo copy.
  cmp -s "$mock_home/.zsh/completions/_tau" "$ROOT/completions/_tau"; ok "installed _tau matches shipped script" "$?" 0
  grep -q '# tau completions' "$mock_home/.zshrc" 2>/dev/null; ok ".zshrc carries the tau marker" "$?" 0
  grep -q 'fpath=(~/.zsh/completions \$fpath)' "$mock_home/.zshrc" 2>/dev/null; ok ".zshrc registers the fpath" "$?" 0

  # Re-run is idempotent: init -> exists, rc -> present, marker not duplicated.
  capture s2 env -u OPENAI_API_KEY -u DEEPSEEK_API_KEY -u OPENCODE_API_KEY -u TAU_API_KEY -u PIZIG_API_KEY \
    HOME="$mock_home" SHELL=/bin/zsh XIAOMI_API_KEY=smoke-key "$BIN" setup --offline
  ok "setup re-run exits 0" "$s2_rc" 0
  contains "re-run reports config exists" "$s2_out" '"step":"init","status":"exists"'
  contains "re-run reports already_installed" "$s2_out" '"status":"already_installed"'
  contains "re-run reports rc present" "$s2_out" '"rc_status":"present"'
  [ "$(grep -c '# tau completions' "$mock_home/.zshrc")" = "1" ]; ok "rc marker not duplicated" "$?" 0

  # --shell overrides detection; fish needs no rc edit.
  local mock_home2; mock_home2="$(mktemp -d)"; register_temp_dir "$mock_home2"
  capture s3 env -u OPENAI_API_KEY -u DEEPSEEK_API_KEY -u OPENCODE_API_KEY -u TAU_API_KEY -u PIZIG_API_KEY \
    HOME="$mock_home2" SHELL=/bin/bash XIAOMI_API_KEY=smoke-key "$BIN" setup --offline --shell fish
  ok "setup --shell fish exits 0" "$s3_rc" 0
  contains "--shell fish installs fish" "$s3_out" '"shell":"fish"'
  [ -f "$mock_home2/.config/fish/completions/tau.fish" ]; ok "fish completion installed" "$?" 0
  cmp -s "$mock_home2/.config/fish/completions/tau.fish" "$ROOT/completions/tau.fish"; ok "installed tau.fish matches shipped script" "$?" 0

  # --shell all installs every supported shell (pwsh gets a profile line).
  local mock_home3; mock_home3="$(mktemp -d)"; register_temp_dir "$mock_home3"
  capture s4 env -u OPENAI_API_KEY -u DEEPSEEK_API_KEY -u OPENCODE_API_KEY -u TAU_API_KEY -u PIZIG_API_KEY \
    HOME="$mock_home3" XIAOMI_API_KEY=smoke-key "$BIN" setup --offline --shell all
  ok "setup --shell all exits 0" "$s4_rc" 0
  contains "--shell all covers bash" "$s4_out" '"shell":"bash"'
  contains "--shell all covers zsh" "$s4_out" '"shell":"zsh"'
  contains "--shell all covers fish" "$s4_out" '"shell":"fish"'
  contains "--shell all covers pwsh" "$s4_out" '"shell":"pwsh"'
  [ -f "$mock_home3/.local/share/bash-completion/completions/tau" ]; ok "bash completion installed" "$?" 0
  cmp -s "$mock_home3/.config/tau/completions/tau.ps1" "$ROOT/completions/tau.ps1"; ok "installed tau.ps1 matches shipped script" "$?" 0
  grep -q '# tau completions' "$mock_home3/.config/powershell/Microsoft.PowerShell_profile.ps1" 2>/dev/null
  ok "pwsh profile carries the tau marker" "$?" 0

  # No SHELL -> completions skipped (still a pass), setup verdict stays ok.
  local mock_home4; mock_home4="$(mktemp -d)"; register_temp_dir "$mock_home4"
  capture s5 env -u OPENAI_API_KEY -u DEEPSEEK_API_KEY -u OPENCODE_API_KEY -u TAU_API_KEY -u PIZIG_API_KEY -u SHELL \
    HOME="$mock_home4" XIAOMI_API_KEY=smoke-key "$BIN" setup --offline
  ok "setup without SHELL exits 0" "$s5_rc" 0
  contains "undetected shell is skipped with a hint" "$s5_out" '"step":"completions","status":"skipped"'

  # Doctor failure (no API key anywhere) -> ok:false, exit 1.
  local mock_home5; mock_home5="$(mktemp -d)"; register_temp_dir "$mock_home5"
  capture s6 env -u OPENAI_API_KEY -u DEEPSEEK_API_KEY -u OPENCODE_API_KEY -u TAU_API_KEY -u PIZIG_API_KEY -u XIAOMI_API_KEY \
    HOME="$mock_home5" SHELL=/bin/bash "$BIN" setup --offline
  ok "setup with no API key exits 1" "$s6_rc" 1
  contains "doctor report marks api_key fail" "$s6_out" '"name":"api_key","status":"fail"'
  contains "final verdict is ok:false" "$s6_out" '"step":"setup","ok":false'

  # Unknown --provider rides into the doctor step as a failed check (like
  # `tau doctor`), not an arg error.
  local mock_home6; mock_home6="$(mktemp -d)"; register_temp_dir "$mock_home6"
  capture s7 env -u OPENAI_API_KEY -u DEEPSEEK_API_KEY -u OPENCODE_API_KEY -u TAU_API_KEY -u PIZIG_API_KEY \
    HOME="$mock_home6" SHELL=/bin/bash XIAOMI_API_KEY=smoke-key "$BIN" setup --offline --provider acme
  contains "unknown provider fails provider_resolution" "$s7_out" '"name":"provider_resolution","status":"fail"'

  # --client zed writes a fresh settings.json with the tau agent_servers entry.
  local mock_home7; mock_home7="$(mktemp -d)"; register_temp_dir "$mock_home7"
  capture s8 env -u OPENAI_API_KEY -u DEEPSEEK_API_KEY -u OPENCODE_API_KEY -u TAU_API_KEY -u PIZIG_API_KEY \
    HOME="$mock_home7" SHELL=/bin/bash XIAOMI_API_KEY=smoke-key "$BIN" setup --offline --client zed
  ok "setup --client zed exits 0" "$s8_rc" 0
  contains "clients step reports installed" "$s8_out" '"step":"clients","status":"installed"'
  contains "zed entry reports installed" "$s8_out" '"client":"zed"'
  [ -f "$mock_home7/.config/zed/settings.json" ]; ok "zed settings.json written" "$?" 0
  grep -q '"agent_servers"' "$mock_home7/.config/zed/settings.json"; ok "zed settings has agent_servers" "$?" 0
  grep -q '"type": "custom"' "$mock_home7/.config/zed/settings.json"; ok "zed entry has type custom" "$?" 0
  grep -q '"acp", "serve"' "$mock_home7/.config/zed/settings.json"; ok "zed args are acp serve" "$?" 0

  # Re-run detects the existing tau entry -> already_installed, still exit 0.
  capture s9 env -u OPENAI_API_KEY -u DEEPSEEK_API_KEY -u OPENCODE_API_KEY -u TAU_API_KEY -u PIZIG_API_KEY \
    HOME="$mock_home7" SHELL=/bin/bash XIAOMI_API_KEY=smoke-key "$BIN" setup --offline --client zed
  ok "setup --client zed re-run exits 0" "$s9_rc" 0
  contains "zed re-run reports already_installed" "$s9_out" '"status":"already_installed"'

  # An existing settings file without tau is left untouched -> manual + snippet.
  local mock_home8; mock_home8="$(mktemp -d)"; register_temp_dir "$mock_home8"
  mkdir -p "$mock_home8/.config/zed"
  printf '{\n  // keep me\n  "vim_mode": true\n}\n' > "$mock_home8/.config/zed/settings.json"
  capture s10 env -u OPENAI_API_KEY -u DEEPSEEK_API_KEY -u OPENCODE_API_KEY -u TAU_API_KEY -u PIZIG_API_KEY \
    HOME="$mock_home8" SHELL=/bin/bash XIAOMI_API_KEY=smoke-key "$BIN" setup --offline --client zed
  ok "setup --client zed on existing file exits 0" "$s10_rc" 0
  contains "existing file without tau -> manual" "$s10_out" '"status":"manual"'
  contains "manual entry names the snippet" "$s10_out" '"snippet_path":'
  [ -f "$mock_home8/.config/tau/snippets/zed.jsonc" ]; ok "zed snippet file written" "$?" 0
  grep -q '// keep me' "$mock_home8/.config/zed/settings.json"; ok "existing settings untouched" "$?" 0

  # --client nvim never writes into ~/.config/nvim — a lua snippet is emitted.
  local mock_home9; mock_home9="$(mktemp -d)"; register_temp_dir "$mock_home9"
  capture s11 env -u OPENAI_API_KEY -u DEEPSEEK_API_KEY -u OPENCODE_API_KEY -u TAU_API_KEY -u PIZIG_API_KEY \
    HOME="$mock_home9" SHELL=/bin/bash XIAOMI_API_KEY=smoke-key "$BIN" setup --offline --client nvim
  ok "setup --client nvim exits 0" "$s11_rc" 0
  contains "nvim step reports manual" "$s11_out" '"step":"clients","status":"manual"'
  [ -f "$mock_home9/.config/tau/snippets/nvim.lua" ]; ok "nvim lua snippet written" "$?" 0
  grep -q 'acp_providers' "$mock_home9/.config/tau/snippets/nvim.lua"; ok "nvim snippet has avante block" "$?" 0

  # --client all covers every client.
  local mock_home10; mock_home10="$(mktemp -d)"; register_temp_dir "$mock_home10"
  capture s12 env -u OPENAI_API_KEY -u DEEPSEEK_API_KEY -u OPENCODE_API_KEY -u TAU_API_KEY -u PIZIG_API_KEY \
    HOME="$mock_home10" SHELL=/bin/bash XIAOMI_API_KEY=smoke-key "$BIN" setup --offline --client all
  ok "setup --client all exits 0" "$s12_rc" 0
  contains "--client all covers zed" "$s12_out" '"client":"zed"'
  contains "--client all covers nvim" "$s12_out" '"client":"nvim"'
  contains "--client all covers vscode" "$s12_out" '"client":"vscode"'
  contains "--client all covers jetbrains" "$s12_out" '"client":"jetbrains"'
  [ -f "$mock_home10/.config/Code/User/settings.json" ]; ok "vscode settings written" "$?" 0
  grep -q '"acp.agents"' "$mock_home10/.config/Code/User/settings.json"; ok "vscode uses acp.agents key" "$?" 0
  [ -f "$mock_home10/.jetbrains/acp.json" ]; ok "jetbrains acp.json written" "$?" 0

  # Without --client the step detects installed editors but writes nothing.
  local mock_home11; mock_home11="$(mktemp -d)"; register_temp_dir "$mock_home11"
  mkdir -p "$mock_home11/.config/zed"
  capture s13 env -u OPENAI_API_KEY -u DEEPSEEK_API_KEY -u OPENCODE_API_KEY -u TAU_API_KEY -u PIZIG_API_KEY \
    HOME="$mock_home11" SHELL=/bin/bash XIAOMI_API_KEY=smoke-key "$BIN" setup --offline
  contains "no --client detects the zed config dir" "$s13_out" '"detected":["zed"'
  [ ! -f "$mock_home11/.config/zed/settings.json" ]; ok "detection wrote no settings file" "$?" 0

  # ── Unattended mode (--yes / --non-interactive / TAU_* env) ──────────────

  # --yes --non-interactive on a fresh HOME, stdin closed: all steps still
  # run, exit 0, and the verdict records the contract.
  local mock_home12; mock_home12="$(mktemp -d)"; register_temp_dir "$mock_home12"
  local ni_out ni_rc
  ni_out="$(env -u OPENAI_API_KEY -u DEEPSEEK_API_KEY -u OPENCODE_API_KEY -u TAU_API_KEY -u PIZIG_API_KEY \
    HOME="$mock_home12" SHELL=/bin/bash XIAOMI_API_KEY=smoke-key "$BIN" setup --offline --yes --non-interactive </dev/null 2>&1)"
  ni_rc=$?
  ok "setup --yes --non-interactive (stdin closed) exits 0" "$ni_rc" 0
  contains "verdict records non_interactive" "$ni_out" '"non_interactive":true'
  contains "verdict records yes" "$ni_out" '"yes":true'
  contains "init still ran unattended" "$ni_out" '"step":"init","status":"created"'

  # -y is the short alias for --yes.
  local mock_home13; mock_home13="$(mktemp -d)"; register_temp_dir "$mock_home13"
  capture s14 env -u OPENAI_API_KEY -u DEEPSEEK_API_KEY -u OPENCODE_API_KEY -u TAU_API_KEY -u PIZIG_API_KEY \
    HOME="$mock_home13" SHELL=/bin/bash XIAOMI_API_KEY=smoke-key "$BIN" setup --offline -y
  ok "setup -y exits 0" "$s14_rc" 0
  contains "-y verdict records non_interactive" "$s14_out" '"non_interactive":true'
  contains "-y verdict records yes" "$s14_out" '"yes":true'

  # TAU_YES / TAU_NONINTERACTIVE env vars enable the same contract — the
  # dotfiles/devcontainer path where argv comes from a fixed script.
  local mock_home14; mock_home14="$(mktemp -d)"; register_temp_dir "$mock_home14"
  capture s15 env -u OPENAI_API_KEY -u DEEPSEEK_API_KEY -u OPENCODE_API_KEY -u TAU_API_KEY -u PIZIG_API_KEY \
    HOME="$mock_home14" SHELL=/bin/bash XIAOMI_API_KEY=smoke-key TAU_YES=1 "$BIN" setup --offline
  ok "setup with TAU_YES=1 exits 0" "$s15_rc" 0
  contains "TAU_YES verdict records non_interactive" "$s15_out" '"non_interactive":true'
  contains "TAU_YES verdict records yes" "$s15_out" '"yes":true'

  local mock_home15; mock_home15="$(mktemp -d)"; register_temp_dir "$mock_home15"
  capture s16 env -u OPENAI_API_KEY -u DEEPSEEK_API_KEY -u OPENCODE_API_KEY -u TAU_API_KEY -u PIZIG_API_KEY \
    HOME="$mock_home15" SHELL=/bin/bash XIAOMI_API_KEY=smoke-key TAU_NONINTERACTIVE=1 "$BIN" setup --offline
  ok "setup with TAU_NONINTERACTIVE=1 exits 0" "$s16_rc" 0
  contains "TAU_NONINTERACTIVE verdict records non_interactive" "$s16_out" '"non_interactive":true'
  printf '%s' "$s16_out" | grep -q '"yes":true'; ok "TAU_NONINTERACTIVE does not set yes" "$?" 1

  # Falsy env values (0/false/empty) do not enable unattended mode.
  local mock_home16; mock_home16="$(mktemp -d)"; register_temp_dir "$mock_home16"
  capture s17 env -u OPENAI_API_KEY -u DEEPSEEK_API_KEY -u OPENCODE_API_KEY -u TAU_API_KEY -u PIZIG_API_KEY \
    HOME="$mock_home16" SHELL=/bin/bash XIAOMI_API_KEY=smoke-key TAU_YES=0 TAU_NONINTERACTIVE=false "$BIN" setup --offline
  ok "setup with TAU_YES=0 TAU_NONINTERACTIVE=false exits 0" "$s17_rc" 0
  printf '%s' "$s17_out" | grep -q 'non_interactive'; ok "falsy env vars leave verdict plain" "$?" 1

  # TAU_SETUP_SHELL / TAU_SETUP_CLIENT supply --shell/--client without argv.
  local mock_home17; mock_home17="$(mktemp -d)"; register_temp_dir "$mock_home17"
  capture s18 env -u OPENAI_API_KEY -u DEEPSEEK_API_KEY -u OPENCODE_API_KEY -u TAU_API_KEY -u PIZIG_API_KEY \
    HOME="$mock_home17" SHELL=/bin/bash XIAOMI_API_KEY=smoke-key TAU_SETUP_SHELL=fish TAU_SETUP_CLIENT=zed "$BIN" setup --offline --non-interactive
  ok "setup with TAU_SETUP_* env exits 0" "$s18_rc" 0
  contains "TAU_SETUP_SHELL installs fish" "$s18_out" '"shell":"fish"'
  contains "TAU_SETUP_CLIENT configures zed" "$s18_out" '"client":"zed"'
  [ -f "$mock_home17/.config/fish/completions/tau.fish" ]; ok "env-driven fish completion installed" "$?" 0
  [ -f "$mock_home17/.config/zed/settings.json" ]; ok "env-driven zed settings written" "$?" 0

  # Flag beats env: --shell zsh wins over TAU_SETUP_SHELL=fish.
  local mock_home18; mock_home18="$(mktemp -d)"; register_temp_dir "$mock_home18"
  capture s19 env -u OPENAI_API_KEY -u DEEPSEEK_API_KEY -u OPENCODE_API_KEY -u TAU_API_KEY -u PIZIG_API_KEY \
    HOME="$mock_home18" SHELL=/bin/bash XIAOMI_API_KEY=smoke-key TAU_SETUP_SHELL=fish "$BIN" setup --offline --shell zsh
  ok "setup --shell beats TAU_SETUP_SHELL exits 0" "$s19_rc" 0
  contains "flag won: zsh installed" "$s19_out" '"shell":"zsh"'
  printf '%s' "$s19_out" | grep -q '"shell":"fish"'; ok "env value not applied" "$?" 1

  # Invalid env values fail like a bad flag (exit 80).
  TAU_SETUP_SHELL=tcsh "$BIN" setup --offline >/dev/null 2>&1
  ok "TAU_SETUP_SHELL=tcsh -> exit 80" "$?" 80
  TAU_SETUP_CLIENT=emacs "$BIN" setup --offline >/dev/null 2>&1
  ok "TAU_SETUP_CLIENT=emacs -> exit 80" "$?" 80

  # Bad arguments.
  "$BIN" setup --bogus >/dev/null 2>&1; ok "setup --bogus -> exit 80" "$?" 80
  "$BIN" setup --shell tcsh >/dev/null 2>&1; ok "setup --shell tcsh -> exit 80" "$?" 80
  "$BIN" setup --shell >/dev/null 2>&1; ok "setup --shell (missing value) -> exit 80" "$?" 80
  "$BIN" setup --client emacs >/dev/null 2>&1; ok "setup --client emacs -> exit 80" "$?" 80
  "$BIN" setup --client >/dev/null 2>&1; ok "setup --client (missing value) -> exit 80" "$?" 80
}

# Group: runnable client-config examples under examples/clients/ —
# the shipped files must equal what `tau setup --client --yes` writes.
test_group_client_examples() {
  local out rc h ex
  ex="$ROOT/examples/clients"

  note "client-config examples match what tau setup --client writes"

  h="$(mktemp -d)"; register_temp_dir "$h"

  # tau setup --client all --yes writes real settings into a scratch HOME.
  capture ce env -u OPENAI_API_KEY -u DEEPSEEK_API_KEY -u OPENCODE_API_KEY -u TAU_API_KEY -u PIZIG_API_KEY \
    HOME="$h" SHELL=/bin/bash XIAOMI_API_KEY=smoke-key "$BIN" setup --offline --client all --yes
  ok "setup --client all --yes exits 0" "$ce_rc" 0
  contains "clients step reports installed" "$ce_out" '"step":"clients","status":"installed"'

  # The tau config setup wrote passes `tau config validate`.
  out=$("$BIN" config validate "$h/.config/tau/config.json"); rc=$?
  ok "config validate on the setup-written config exits 0" "$rc" 0
  contains "setup-written config reports ok:true" "$out" '"ok":true'

  # Normalize the embedded absolute command path to "tau" and diff each
  # generated settings file byte-for-byte against the shipped example.
  local spec want
  for spec in zed vscode jetbrains; do
    case "$spec" in
      zed)       want="$h/.config/zed/settings.json" ;;
      vscode)    want="$h/.config/Code/User/settings.json" ;;
      jetbrains) want="$h/.jetbrains/acp.json" ;;
    esac
    sed 's|"command": "[^"]*"|"command": "tau"|' "$want" > "$h/norm-$spec.json"
    cmp -s "$h/norm-$spec.json" "$ex/$spec.json"
    ok "$spec.json matches setup --client output" "$?" 0
  done

  # Every shipped example parses as JSON.
  local f
  for f in "$ex"/*.json; do
    python3 -c 'import sys,json;json.load(open(sys.argv[1]))' "$f" 2>/dev/null
    ok "$(basename "$f") parses as JSON" "$?" 0
  done

  # Cursor reuses the VS Code acp.agents shape — its tau entry must be
  # identical to the one in vscode.json.
  python3 -c 'import json,sys
v = json.load(open(sys.argv[1]))["acp.agents"]["tau"]
c = json.load(open(sys.argv[2]))["acp.agents"]["tau"]
sys.exit(0 if v == c else 1)' "$ex/vscode.json" "$ex/cursor.json" 2>/dev/null
  ok "cursor.json carries the same tau entry as vscode.json" "$?" 0

  # Every tau agent entry across the examples speaks the ACP contract:
  # args is exactly ["acp","serve"], nothing else.
  python3 -c 'import glob,json,sys
want = ["acp", "serve"]; found = 0
for p in glob.glob(sys.argv[1] + "/*.json"):
    d = json.load(open(p))
    for section in ("agent_servers", "acp.agents"):
        entry = d.get(section, {}).get("tau")
        if entry is not None:
            found += 1
            if entry.get("args") != want:
                sys.exit(1)
sys.exit(0 if found >= 3 else 1)' "$ex" 2>/dev/null
  ok "every shipped tau entry uses args [acp serve]" "$?" 0

  # Claude Desktop goes through the mcacp MCP->ACP bridge — both halves of
  # the wiring must be present and point at `tau acp serve`.
  python3 -c 'import json,sys
cd = json.load(open(sys.argv[1]))
mc = json.load(open(sys.argv[2]))
ok1 = "mcacp" in cd.get("mcpServers", {})
tau = mc.get("agent_servers", {}).get("tau", {})
sys.exit(0 if ok1 and tau.get("args") == ["acp", "serve"] else 1)' \
    "$ex/claude-desktop.json" "$ex/mcacp.json" 2>/dev/null
  ok "claude-desktop.json + mcacp.json wire the bridge to tau" "$?" 0
}

# Group: Issue #17 goal mode subcommands offline
test_group_goal_offline() {
  local out rc GSESS_OFF sub sname

  note "goal mode subcommands (offline)"

  # --api-key fake on every call: key resolution runs before goal/session
  # validation, so a keyless environment would exit 106 before reaching the
  # paths under test.
  # /goal subcommands require --session
  "$BIN" --api-key fake "/goal status" >/dev/null 2>&1;   ok "/goal status without --session -> exit 80" "$?" 80
  "$BIN" --api-key fake "/goal pause" >/dev/null 2>&1;    ok "/goal pause without --session -> exit 80" "$?" 80
  "$BIN" --api-key fake "/goal resume" >/dev/null 2>&1;   ok "/goal resume without --session -> exit 80" "$?" 80
  "$BIN" --api-key fake "/goal clear" >/dev/null 2>&1;    ok "/goal clear without --session -> exit 80" "$?" 80
  "$BIN" --api-key fake "/goal complete" >/dev/null 2>&1; ok "/goal complete without --session -> exit 80" "$?" 80

  # /goal status with --session, no prior goal -> {"goal":null}
  GSESS_OFF="smoke-goal-offline-$$"
  capture goal_status "$BIN" --api-key fake --session "$GSESS_OFF" --no-tools --no-stream "/goal status" 2>&1
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
    capture goal_sub "$BIN" --api-key fake --session "$sname" --no-tools --no-stream "/goal $sub" 2>&1
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

  # Standardized envelope (task #171): every code carries recoverable, a
  # remediation hint, and the docs link — on both channels.
  if printf '%s' "$err_env_err" | python3 -c 'import sys,json; e=json.load(sys.stdin)["err"]; assert e.get("recoverable") == False; assert e.get("hint"); assert "troubleshooting.md" in e.get("docs","")' 2>/dev/null; then
    ok "envelope 80 has recoverable + hint + docs" 0 0
  else
    ok "envelope 80 missing recoverable/hint/docs" 1 0
    [ "$SMOKE_DEBUG" = "1" ] && diag "envelope 80: $err_env_err"
  fi

  # Envelope footer (task #250): every envelope ends with a stable
  # explain/catalog pointer — a ready-to-run `tau explain <code>` plus the
  # generated docs/errors.md link, on both stderr and fleet's stdout channel.
  if printf '%s' "$err_env_err" | python3 -c 'import sys,json; e=json.load(sys.stdin)["err"]; assert e.get("explain") == "tau explain 80"; assert "docs/errors.md" in e.get("catalog","")' 2>/dev/null; then
    ok "envelope 80 footer has explain + catalog" 0 0
  else
    ok "envelope 80 missing explain/catalog footer" 1 0
    [ "$SMOKE_DEBUG" = "1" ] && diag "envelope 80 footer: $err_env_err"
  fi

  # Error envelope for missing required field (exit 82)
  # fleet run without --goal writes to stdout via fleetRequires (term.out, not
  # term.err). --api-key fake: key resolution precedes the --goal check, so a
  # keyless environment would exit 106 before reaching it.
  capture err_82 "$BIN" fleet run --api-key fake 2>&1 >/dev/null
  if printf '%s' "$err_82_out" | python3 -c 'import sys,json; d=json.load(sys.stdin); assert d.get("err",{}).get("code") == 82' 2>/dev/null; then
    ok "error envelope code 82 exists" 0 0
  else
    ok "error envelope code 82 format invalid" 1 0
    [ "$SMOKE_DEBUG" = "1" ] && diag "error envelope 82: $err_82_out"
  fi
  if printf '%s' "$err_82_out" | python3 -c 'import sys,json; e=json.load(sys.stdin)["err"]; assert e.get("type") == "missing_required_field"; assert e.get("hint"); assert "troubleshooting.md" in e.get("docs","")' 2>/dev/null; then
    ok "envelope 82 has type missing_required_field + hint + docs" 0 0
  else
    ok "envelope 82 missing type/hint/docs" 1 0
    [ "$SMOKE_DEBUG" = "1" ] && diag "envelope 82: $err_82_out"
  fi
  if printf '%s' "$err_82_out" | python3 -c 'import sys,json; e=json.load(sys.stdin)["err"]; assert e.get("explain") == "tau explain 82"; assert "docs/errors.md" in e.get("catalog","")' 2>/dev/null; then
    ok "envelope 82 (stdout) footer has explain + catalog" 0 0
  else
    ok "envelope 82 (stdout) missing explain/catalog footer" 1 0
    [ "$SMOKE_DEBUG" = "1" ] && diag "envelope 82 footer: $err_82_out"
  fi

  # Error envelope for internal error (exit 110) triggered by fake API key
  capture err_110 "$BIN" --api-key fake --provider openai --no-tools --no-stream "x" 2>&1 >/dev/null
  if printf '%s' "$err_110_err" | python3 -c 'import sys,json; d=json.load(sys.stdin); assert d.get("err",{}).get("code") == 110' 2>/dev/null; then
    ok "error envelope code 110 has internal_error" 0 0
  else
    ok "error envelope code 110 format invalid" 1 0
    [ "$SMOKE_DEBUG" = "1" ] && diag "error envelope 110: $err_110_err"
  fi
  if printf '%s' "$err_110_err" | python3 -c 'import sys,json; e=json.load(sys.stdin)["err"]; assert e.get("hint"); assert "troubleshooting.md" in e.get("docs","")' 2>/dev/null; then
    ok "envelope 110 has hint + docs" 0 0
  else
    ok "envelope 110 missing hint/docs" 1 0
    [ "$SMOKE_DEBUG" = "1" ] && diag "envelope 110: $err_110_err"
  fi

  # Error envelope for auth failure (exit 106): docs links the per-provider
  # credential guide, not the generic troubleshooting page. Keyless env +
  # fresh HOME so no config.json or env var can satisfy the auth check —
  # fleet's auth check fires before the --goal validation.
  local kh="$SMOKE_TEMP/keyless-home"
  mkdir -p "$kh"
  capture err_106 env -u XIAOMI_API_KEY -u PIZIG_API_KEY -u OPENAI_API_KEY -u DEEPSEEK_API_KEY -u OPENCODE_API_KEY -u TAU_API_KEY HOME="$kh" "$BIN" fleet run 2>&1 >/dev/null
  if printf '%s' "$err_106_err" | python3 -c 'import sys,json; e=json.load(sys.stdin)["err"]; assert e.get("code") == 106; assert e.get("type") == "AuthFailed"' 2>/dev/null; then
    ok "envelope 106 has type AuthFailed" 0 0
  else
    ok "envelope 106 format invalid" 1 0
    [ "$SMOKE_DEBUG" = "1" ] && diag "envelope 106: $err_106_err"
  fi
  if printf '%s' "$err_106_err" | python3 -c 'import sys,json; e=json.load(sys.stdin)["err"]; assert "docs/providers.md" in e.get("docs","")' 2>/dev/null; then
    ok "envelope 106 docs links providers.md" 0 0
  else
    ok "envelope 106 docs missing providers.md link" 1 0
    [ "$SMOKE_DEBUG" = "1" ] && diag "envelope 106: $err_106_err"
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

# Group: --debug redacted diagnostic log (task #167)
# --debug mirrors its [DEBUG] stderr lines into ~/.config/tau/debug/<ts>.log
# (TAU_DEBUG_LOG overrides). The file copy masks registered keys, Bearer
# tokens, api_key-style JSON fields and *_KEY= env assignments; stderr keeps
# the raw output. A stubbed curl on PATH exercises the provider emitters
# offline.
test_group_debug() {
  local dbg_home="$SMOKE_TEMP/debug-home"
  local stubdir="$SMOKE_TEMP/curl-stub"
  mkdir -p "$dbg_home" "$stubdir"
  local scrub=(env -u XIAOMI_API_KEY -u PIZIG_API_KEY -u TAU_API_KEY -u OPENAI_API_KEY -u DEEPSEEK_API_KEY "HOME=$dbg_home")

  note "--debug diagnostic log file"

  # Keyless run: the log opens before the agent loop, so even the silent
  # exit-106 path leaves a file and a {"debug_log":...} pointer on stderr.
  capture r "${scrub[@]}" "$BIN" --debug --no-stream "hi"
  ok "debug: keyless run exits 106" "$r_rc" 106
  contains "debug: stderr announces debug_log path" "$r_err" '"debug_log":"'
  contains "debug: perf line on stderr" "$r_err" "[DEBUG] perf:"
  local created
  created="$(ls "$dbg_home/.config/tau/debug"/debug-*.log 2>/dev/null | head -1)"
  if [ -n "$created" ] && [ -f "$created" ]; then
    ok "debug: default log file created under ~/.config/tau/debug" 0 0
    local body; body="$(cat "$created")"
    contains "debug: log carries provenance header" "$body" "tau diagnostic log"
    contains "debug: header names provider" "$body" "# provider: xiaomi"
    contains "debug: header flags key_resolved no" "$body" "key_resolved: no"
  else
    ok "debug: default log file created under ~/.config/tau/debug" 1 0
    ok "debug: log carries provenance header" 1 0
    ok "debug: header names provider" 1 0
    ok "debug: header flags key_resolved no" 1 0
  fi

  # TAU_DEBUG_LOG override is honored verbatim.
  local custom="$SMOKE_TEMP/custom-debug.log"
  capture r2 "${scrub[@]}" TAU_DEBUG_LOG="$custom" "$BIN" --debug --no-stream "hi"
  if [ -f "$custom" ]; then
    ok "debug: TAU_DEBUG_LOG override creates file" 0 0
  else
    ok "debug: TAU_DEBUG_LOG override creates file" 1 0
  fi
  contains "debug: override path announced on stderr" "$r2_err" "$custom"

  # Unwritable destination degrades to a warn envelope; the run continues.
  # (/dev/null is a file, so paths under it are unresolvable; a /proc path
  # would exercise a Zig 0.16 Io spin in createDirPath instead.)
  capture r3 "${scrub[@]}" TAU_DEBUG_LOG="/dev/null/nope/tau.log" "$BIN" --debug --no-stream "hi"
  contains "debug: unwritable path emits warn envelope" "$r3_err" '"warn"'
  ok "debug: unwritable log keeps normal exit path" "$r3_rc" 106

  # Redaction e2e (non-streaming): a stub curl echoes the Authorization header
  # into the response body; the log must mask both the literal key and the
  # api_key JSON field — stderr keeps the raw line.
  cat > "$stubdir/curl" <<'STUB'
#!/usr/bin/env bash
auth=""
for a in "$@"; do
  case "$a" in Authorization:*) auth="$a";; esac
done
printf '{"content":"stub saw %s","api_key":"nested-KEYVAL-9","usage":{"total_tokens":7}}' "$auth"
STUB
  chmod +x "$stubdir/curl"
  local rlog="$SMOKE_TEMP/redact.log"
  capture r4 "${scrub[@]}" TAU_API_KEY=SMOKESECRET-777 TAU_DEBUG_LOG="$rlog" PATH="$stubdir:$PATH" "$BIN" --debug --no-stream "hi"
  ok "debug: stubbed run exits 0" "$r4_rc" 0
  contains "debug: stderr keeps raw debug line" "$r4_err" "[DEBUG] Raw API response"
  if [ -f "$rlog" ]; then
    local lbody; lbody="$(cat "$rlog")"
    case "$lbody" in
      *SMOKESECRET-777*) ok "debug: resolved key masked in log" 1 0 ;;
      *)                 ok "debug: resolved key masked in log" 0 0 ;;
    esac
    case "$lbody" in
      *nested-KEYVAL-9*) ok "debug: api_key JSON field masked in log" 1 0 ;;
      *)                 ok "debug: api_key JSON field masked in log" 0 0 ;;
    esac
    contains "debug: log uses REDACTED marker" "$lbody" "***REDACTED***"
    contains "debug: log has raw API line" "$lbody" "[DEBUG] Raw API response"
  else
    ok "debug: resolved key masked in log" 1 0
    ok "debug: api_key JSON field masked in log" 1 0
    ok "debug: log uses REDACTED marker" 1 0
    ok "debug: log has raw API line" 1 0
  fi

  # Redaction e2e (streaming): SSE lines are debug-logged too; the key inside
  # a streamed chunk must still be masked in the file.
  cat > "$stubdir/curl" <<'STUB'
#!/usr/bin/env bash
auth=""
for a in "$@"; do
  case "$a" in Authorization:*) auth="$a";; esac
done
printf 'data: {"choices":[{"delta":{"content":"saw %s"}}],"usage":{"total_tokens":3}}\n\ndata: [DONE]\n\n' "$auth"
STUB
  chmod +x "$stubdir/curl"
  local slog="$SMOKE_TEMP/redact-stream.log"
  capture r5 "${scrub[@]}" TAU_API_KEY=SMOKESECRET-777 TAU_DEBUG_LOG="$slog" PATH="$stubdir:$PATH" "$BIN" --debug "hi"
  ok "debug: stubbed streaming run exits 0" "$r5_rc" 0
  if [ -f "$slog" ]; then
    local sbody; sbody="$(cat "$slog")"
    contains "debug: SSE lines land in log" "$sbody" "[DEBUG] SSE line:"
    case "$sbody" in
      *SMOKESECRET-777*) ok "debug: key masked in streamed log" 1 0 ;;
      *)                 ok "debug: key masked in streamed log" 0 0 ;;
    esac
  else
    ok "debug: SSE lines land in log" 1 0
    ok "debug: key masked in streamed log" 1 0
  fi

  # Error-envelope link: auth failure produces an {"err"} envelope carrying
  # the log path (the literal /goal emitter does the same).
  cat > "$stubdir/curl" <<'STUB'
#!/usr/bin/env bash
printf '{"error":{"message":"invalid_key: bad token"}}'
STUB
  chmod +x "$stubdir/curl"
  local elog="$SMOKE_TEMP/err-link.log"
  capture r6 "${scrub[@]}" TAU_API_KEY=SMOKESECRET-777 TAU_DEBUG_LOG="$elog" PATH="$stubdir:$PATH" "$BIN" --debug --no-stream "hi"
  ok "debug: auth failure exits 106" "$r6_rc" 106
  contains "debug: err envelope links debug_log" "$r6_err" '"debug_log":"'"$elog"'"'

  capture r7 "${scrub[@]}" TAU_API_KEY=SMOKESECRET-777 TAU_DEBUG_LOG="$elog" "$BIN" --debug "/goal status"
  ok "debug: /goal status without session exits 80" "$r7_rc" 80
  contains "debug: literal envelope links debug_log" "$r7_err" '"debug_log":"'
}

# Group: golden error-contract snapshots (Issue #208)
# Byte-locks the agent-facing failure contract: every deterministic error path
# is run fully offline (API keys scrubbed, isolated HOME) and its exit status
# plus exact stdout/stderr bytes are compared against tests/golden/<case>.*.
# The snapshots intentionally pin today's three envelope shapes and channels:
#   stderr {"err":{code,type,message,recoverable}}  (printErrorJson, main.zig)
#   stdout {"err":{code,message}}                  (fleetRequires, helpers.zig)
#   stderr {"err":{code,type,message}}             (goalSubcommand, agent.zig)
# ...plus the silent exits (missing API key -> bare 106, empty streams).
# Regenerate after an intentional contract change:
#   GOLDEN_UPDATE=1 ./scripts/smoke.sh --group golden-errors

# _golden_env <cmd...> — run cmd with every provider key + TAU_ENDPOINT scrubbed
# and HOME pointed at an isolated dir so a contributor's real config.json or
# exported keys cannot leak into a snapshot.
_golden_env() {
  if [ -z "${_GOLDEN_HOME:-}" ]; then
    _GOLDEN_HOME="$(mktemp -d)"
    register_temp_dir "$_GOLDEN_HOME"
  fi
  env -u XIAOMI_API_KEY -u PIZIG_API_KEY -u OPENAI_API_KEY -u DEEPSEEK_API_KEY \
      -u OPENCODE_API_KEY -u TAU_API_KEY -u TAU_ENDPOINT \
      -u TAU_UPDATE_URL -u TAU_NO_UPDATE_CHECK -u TAU_INSTALL_URL \
      -u TAU_INSTALL_DIR -u TAU_BASE_URL -u TAU_YES -u BROWSER \
      HOME="$_GOLDEN_HOME" "$@"
}

# _golden_stream <name.stdout|name.stderr> <actual-file> — byte-compare, or
# regenerate when GOLDEN_UPDATE=1.
_golden_stream() {
  local gold="$GOLDEN_DIR/$1" actual="$2"
  if [ "${GOLDEN_UPDATE:-0}" = "1" ]; then
    mkdir -p "$GOLDEN_DIR"
    cp "$actual" "$gold"
    ok "golden $1 (regenerated)" 0 0
    return
  fi
  if [ ! -f "$gold" ]; then
    diag "missing golden $gold — regenerate with GOLDEN_UPDATE=1"
    ok "golden $1" 1 0
    return
  fi
  if cmp -s "$gold" "$actual"; then
    ok "golden $1" 0 0
  else
    [ "$SMOKE_DEBUG" = "1" ] && { diag "golden mismatch ($gold):"; diff -u "$gold" "$actual" >&2; }
    ok "golden $1" 1 0
  fi
}

# golden_check <name> <want-exit> <cmd...> — capture and pin exit + both streams.
golden_check() {
  local name="$1" want="$2"; shift 2
  local of ef rc
  of="$(mktemp)"; ef="$(mktemp)"
  register_temp_file "$of"
  register_temp_file "$ef"
  _golden_env "$@" >"$of" 2>"$ef"; rc=$?
  ok "golden $name exit" "$rc" "$want"
  _golden_stream "$name.stdout" "$of"
  _golden_stream "$name.stderr" "$ef"
}

test_group_golden_errors() {
  GOLDEN_DIR="$ROOT/tests/golden"
  local closed_port open_port port_f listener_pid wait_i

  # ── argv parsing failures → stderr envelope, exit 80 ──
  golden_check unknown-option            80 "$BIN" --bogus x
  golden_check unknown-provider          80 "$BIN" --provider nope x
  golden_check model-bad-provider        80 "$BIN" --model nope/m x
  golden_check invalid-mode              80 "$BIN" --mode bad x
  golden_check invalid-role              80 "$BIN" --role boss x
  golden_check invalid-temperature       80 "$BIN" --temperature notafloat x
  golden_check missing-flag-value        80 "$BIN" --api-key
  golden_check missing-at-file           80 "$BIN" "@/nonexistent-tau-golden-file" x
  golden_check acp-unknown-arg           80 "$BIN" acp bogus
  golden_check guide-unknown-arg         80 "$BIN" guide --bogus
  golden_check fleet-no-subcommand       80 "$BIN" fleet
  golden_check fleet-unknown-subcommand  80 "$BIN" fleet bogus
  golden_check skills-no-subcommand      80 "$BIN" skills

  # ── runtime validation failures ──
  golden_check skills-load-missing-name  82 "$BIN" skills load
  golden_check skills-load-not-found      1 "$BIN" skills load nosuchskillname
  golden_check agents-md-not-found        1 "$BIN" --load-agents-md /nonexistent-tau-golden-agents x

  # ── auth failures (exit 106): the prompt path is SILENT, the fleet path
  #    prints the remediation-hint envelope — pin both behaviors ──
  golden_check missing-api-key-silent   106 "$BIN" x
  golden_check fleet-run-missing-key    106 "$BIN" fleet run --goal "ship it"

  # ── fleet "requires" envelopes print on STDOUT in the short shape ──
  golden_check fleet-status-missing-id   80 "$BIN" fleet status
  golden_check fleet-cancel-missing-id   80 "$BIN" fleet cancel
  golden_check fleet-logs-missing-id     80 "$BIN" fleet logs
  golden_check fleet-run-missing-goal    82 "$BIN" fleet run --api-key fake

  # ── goal subcommands need --session (third envelope shape, on stderr) ──
  golden_check goal-needs-session        80 "$BIN" --api-key fake "/goal status"

  # ── provider transport failures (105/110) via loopback stubs ──
  if ! command -v curl >/dev/null 2>&1; then
    skip_test "golden endpoint-unreachable" "curl not on PATH"
    skip_test "golden endpoint-timeout" "curl not on PATH"
    skip_test "golden fleet-coordinator-unreachable" "curl not on PATH"
  elif ! command -v python3 >/dev/null 2>&1; then
    skip_test "golden endpoint-unreachable" "python3 required for loopback stub"
    skip_test "golden endpoint-timeout" "python3 required for silent listener"
    skip_test "golden fleet-coordinator-unreachable" "python3 required for loopback stub"
  else
    # A port bound then immediately closed -> deterministic connection refused.
    closed_port="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()' 2>/dev/null)"
    if [ -n "$closed_port" ]; then
      golden_check endpoint-unreachable 110 \
        env TAU_ENDPOINT="http://127.0.0.1:$closed_port/" \
        "$BIN" --api-key fake --no-stream --timeout-ms 10000 x
      golden_check fleet-coordinator-unreachable 110 \
        env TAU_ENDPOINT="http://127.0.0.1:$closed_port/" \
        "$BIN" fleet run --goal "ship it" --api-key fake
    else
      skip_test "golden endpoint-unreachable" "could not reserve a closed loopback port"
      skip_test "golden fleet-coordinator-unreachable" "could not reserve a closed loopback port"
    fi

    # A listener that accepts but never replies -> curl --max-time fires.
    port_f="$SMOKE_TEMP/golden-listener-port"
    python3 - "$port_f" >/dev/null 2>&1 <<'PY' &
import socket, sys, time
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", 0))
s.listen(8)
with open(sys.argv[1], "w") as fh:
    fh.write(str(s.getsockname()[1]))
time.sleep(60)
PY
    listener_pid=$!
    open_port=""
    for wait_i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
      [ -s "$port_f" ] && { open_port="$(cat "$port_f")"; break; }
      sleep 0.2
    done
    if [ -n "$open_port" ]; then
      golden_check endpoint-timeout 105 \
        env TAU_ENDPOINT="http://127.0.0.1:$open_port/" \
        "$BIN" --api-key fake --no-stream --timeout-ms 1500 x
    else
      skip_test "golden endpoint-timeout" "silent listener did not start"
    fi
    kill "$listener_pid" 2>/dev/null || true
  fi
}

# Group: golden onboarding snapshots (Issue #223)
# Byte-locks the whole first-run surface end-to-end — `tau init`, `tau setup`
# (incl. --client), and `tau config edit`: exit codes, the stdout/stderr
# transcript, AND the generated file contents (config.json scaffold, shell rc
# block, editor settings files/snippets). Everything runs offline against a
# scrubbed env and an isolated HOME; the volatile bits (the $HOME path, the
# tau binary path embedded in client configs, and the curl version string in
# the embedded doctor report) are normalized to <HOME>/<TAU>/<VER> before
# comparing. Regenerate after an intentional contract change:
#   GOLDEN_UPDATE=1 ./scripts/smoke.sh --group golden-onboarding

# _golden_fresh_home — point _golden_env at a brand-new isolated HOME so each
# scenario starts on a clean machine.
_golden_fresh_home() {
  _GOLDEN_HOME="$(mktemp -d "$SMOKE_TEMP/golden-home-XXXXXX")"
  register_temp_dir "$_GOLDEN_HOME"
}

# _golden_norm <file> — rewrite volatile paths/versions into placeholders so
# snapshots stay byte-stable across machines and temp dirs.
_golden_norm() {
  sed -i \
    -e "s|$_GOLDEN_HOME|<HOME>|g" \
    -e "s|$_GOLDEN_BIN|<TAU>|g" \
    -e 's|curl available: curl [0-9][0-9.]*|curl available: curl <VER>|g' \
    -e 's|"commit":"[^"]*"|"commit":"<COMMIT>"|g' \
    -e 's|"target":"[^"]*"|"target":"<TARGET>"|g' \
    -e 's|"build_date":"[^"]*"|"build_date":"<DATE>"|g' \
    -e 's|"zig":"[^"]*"|"zig":"<ZIG>"|g' \
    "$1"
}

# golden_check_n <name> <want-exit> <cmd...> — golden_check + normalization,
# for outputs that embed $HOME or the binary's absolute path.
golden_check_n() {
  local name="$1" want="$2"; shift 2
  local of ef rc
  of="$(mktemp)"; ef="$(mktemp)"
  register_temp_file "$of"
  register_temp_file "$ef"
  _golden_env "$@" >"$of" 2>"$ef"; rc=$?
  _golden_norm "$of"; _golden_norm "$ef"
  ok "golden $name exit" "$rc" "$want"
  _golden_stream "$name.stdout" "$of"
  _golden_stream "$name.stderr" "$ef"
}

# golden_file <name> <path> — byte-compare a generated file against
# tests/golden/<name> after normalization.
golden_file() {
  local name="$1" src="$2" tmp
  tmp="$(mktemp)"
  register_temp_file "$tmp"
  if [ ! -f "$src" ]; then
    diag "golden_file: expected file missing: $src"
    ok "golden $name" 1 0
    return
  fi
  cp "$src" "$tmp"
  _golden_norm "$tmp"
  _golden_stream "$name" "$tmp"
}

test_group_golden_onboarding() {
  GOLDEN_DIR="$ROOT/tests/golden"
  _GOLDEN_BIN="$(realpath "$BIN" 2>/dev/null || printf '%s' "$BIN")"

  # ── tau init ──
  _golden_fresh_home
  golden_check_n ob-init              0 "$BIN" init
  golden_file    ob-init.config       "$_GOLDEN_HOME/.config/tau/config.json"
  golden_check_n ob-init-rerun        1 "$BIN" init
  golden_check_n ob-init-force        0 "$BIN" init --force
  golden_check_n ob-init-bogus-flag  80 "$BIN" init --bogus

  _golden_fresh_home
  golden_check_n ob-init-stdout       0 "$BIN" init --stdout
  if [ -f "$_GOLDEN_HOME/.config/tau/config.json" ]; then
    ok "init --stdout wrote no file" 1 0
  else
    ok "init --stdout wrote no file" 0 0
  fi

  _golden_fresh_home
  golden_check_n ob-init-provider     0 "$BIN" init --provider openai
  golden_file    ob-init-openai.config "$_GOLDEN_HOME/.config/tau/config.json"

  _golden_fresh_home
  golden_check_n ob-init-detects-key  0 env OPENAI_API_KEY=sk-golden "$BIN" init
  golden_file    ob-init-key.config   "$_GOLDEN_HOME/.config/tau/config.json"

  golden_check_n ob-init-no-home    110 env -u HOME "$BIN" init

  # ── tau setup ──
  # Arg-validation failures never reach the doctor step — pin unconditionally.
  golden_check_n ob-setup-bad-client 80 "$BIN" setup --client emacs
  golden_check_n ob-setup-bad-shell  80 "$BIN" setup --shell tcsh

  # The doctor step embeds a report whose curl check text depends on the
  # installed curl — with curl present it normalizes to <VER>; without curl
  # the report's status changes, so these snapshots are pinned only when the
  # toolchain the snapshots were generated under is available.
  if ! command -v curl >/dev/null 2>&1; then
    skip_test "golden setup transcript" "curl not on PATH (doctor report differs)"
  else
    _golden_fresh_home
    golden_check_n ob-setup           0 env SHELL=/bin/zsh XIAOMI_API_KEY=smoke-golden-key "$BIN" setup --offline
    golden_file    ob-setup.config    "$_GOLDEN_HOME/.config/tau/config.json"
    golden_file    ob-setup.zshrc     "$_GOLDEN_HOME/.zshrc"
    # The installed completion script is byte-identical to the shipped one.
    if cmp -s "$ROOT/completions/_tau" "$_GOLDEN_HOME/.zsh/completions/_tau"; then
      ok "setup installed _tau identical to completions/_tau" 0 0
    else
      ok "setup installed _tau differs from completions/_tau" 1 0
    fi
    # Idempotent re-run: init reports exists, completions already_installed.
    golden_check_n ob-setup-rerun     0 env SHELL=/bin/zsh XIAOMI_API_KEY=smoke-golden-key "$BIN" setup --offline

    _golden_fresh_home
    golden_check_n ob-setup-keyless   1 env SHELL=/bin/bash "$BIN" setup --offline
    if cmp -s "$ROOT/completions/tau.bash" "$_GOLDEN_HOME/.local/share/bash-completion/completions/tau"; then
      ok "setup installed tau.bash identical to completions/tau.bash" 0 0
    else
      ok "setup installed tau.bash differs from completions/tau.bash" 1 0
    fi

    _golden_fresh_home
    golden_check_n ob-setup-client-zed 0 env SHELL=/bin/bash XIAOMI_API_KEY=smoke-golden-key "$BIN" setup --offline --client zed
    golden_file    ob-setup-zed.json  "$_GOLDEN_HOME/.config/zed/settings.json"

    # An existing editor settings file is never rewritten — a paste-ready
    # snippet lands in ~/.config/tau/snippets/ instead.
    _golden_fresh_home
    mkdir -p "$_GOLDEN_HOME/.config/zed"
    printf '{\n  // user comment must survive\n  "vim_mode": true\n}\n' > "$_GOLDEN_HOME/.config/zed/settings.json"
    golden_check_n ob-setup-zed-existing 0 env SHELL=/bin/bash XIAOMI_API_KEY=smoke-golden-key "$BIN" setup --offline --client zed
    golden_file    ob-setup-zed.snippet "$_GOLDEN_HOME/.config/tau/snippets/zed.jsonc"
    if printf '{\n  // user comment must survive\n  "vim_mode": true\n}\n' | cmp -s - "$_GOLDEN_HOME/.config/zed/settings.json"; then
      ok "existing zed settings left byte-identical" 0 0
    else
      ok "existing zed settings were modified" 1 0
    fi

    _golden_fresh_home
    golden_check_n ob-setup-client-nvim 0 env SHELL=/bin/bash XIAOMI_API_KEY=smoke-golden-key "$BIN" setup --offline --client nvim
    golden_file    ob-setup-nvim.lua  "$_GOLDEN_HOME/.config/tau/snippets/nvim.lua"
  fi

  # ── tau config edit ──  (editor stubbed via TAU_EDITOR; VISUAL/EDITOR are
  # scrubbed so ambient values can't change precedence)
  _golden_fresh_home
  golden_check_n ob-config-edit         0 env -u VISUAL -u EDITOR TAU_EDITOR=true "$BIN" config edit
  golden_file    ob-config-edit.config  "$_GOLDEN_HOME/.config/tau/config.json"

  _golden_fresh_home
  golden_check_n ob-config-edit-text    0 env -u VISUAL -u EDITOR TAU_EDITOR=true "$BIN" config edit --mode text

  _golden_fresh_home
  golden_check_n ob-config-edit-invalid 1 env -u VISUAL -u EDITOR TAU_EDITOR="printf '{\"proivder\":true}' >" "$BIN" config edit
  # The failed save stays on disk so the user can fix and re-run.
  golden_file    ob-config-edit-invalid.config "$_GOLDEN_HOME/.config/tau/config.json"

  _golden_fresh_home
  golden_check_n ob-config-edit-editor-fails 1 env -u VISUAL -u EDITOR TAU_EDITOR=false "$BIN" config edit
  # The scaffold is seeded before the editor runs — it exists even when the
  # editor fails.
  golden_file    ob-config-edit-editor-fails.config "$_GOLDEN_HOME/.config/tau/config.json"

  golden_check_n ob-config-edit-no-home 80 env -u HOME "$BIN" config edit
}

# Group: golden help/completions surface snapshots (Issue #236)
# Byte-locks `tau --help` and `tau --help-json` (the version field is
# normalized to <VER> so releases don't churn the snapshot), plus the set of
# --flags each shipped completion script offers, extracted into a sorted
# one-per-line listing. Structural coverage — every registered flag and
# subcommand must appear in help_text and all four scripts — is pinned by
# unit tests in src/main.zig. Regenerate after an intentional change:
#   GOLDEN_UPDATE=1 ./scripts/smoke.sh --group golden-help

# _completion_flag_golden <shell> <path-under-root> — extract the completed
# long-flag set from a shipped completion script and byte-lock the listing.
_completion_flag_golden() {
  local shell="$1" script="$ROOT/$2" out
  out="$(mktemp)"
  register_temp_file "$out"
  if [ "$shell" = "fish" ]; then
    # fish spells long flags `-l name`; only `complete -c tau` lines define
    # tau flags (`set -l` lines are ordinary variables).
    grep '^complete -c tau' "$script" | grep -oE -- '-l [a-zA-Z][a-zA-Z-]*' \
      | awk '{print "--"$2}' | sort -u > "$out"
  else
    grep -oE -- '--[a-zA-Z][a-zA-Z-]*' "$script" | sort -u > "$out"
  fi
  _golden_stream "completions-$shell.flags" "$out"
}

test_group_golden_help() {
  GOLDEN_DIR="$ROOT/tests/golden"
  golden_check help        0 "$BIN" --help
  golden_check help-short  0 "$BIN" -h

  local of ef rc
  of="$(mktemp)"; ef="$(mktemp)"
  register_temp_file "$of"; register_temp_file "$ef"
  _golden_env "$BIN" --help-json >"$of" 2>"$ef"; rc=$?
  sed -i 's/"version":"[^"]*"/"version":"<VER>"/' "$of"
  ok "golden help-json exit" "$rc" 0
  _golden_stream help-json.stdout "$of"
  _golden_stream help-json.stderr "$ef"

  _completion_flag_golden bash completions/tau.bash
  _completion_flag_golden zsh  completions/_tau
  _completion_flag_golden fish completions/tau.fish
  _completion_flag_golden ps1  completions/tau.ps1
}

# Group: golden snapshots for the maintenance commands (Issue #244)
# Byte-locks the deterministic stdout/stderr of `tau explain`,
# `tau version --check`, `tau bug`, and `tau upgrade` across success,
# offline, and failure paths. Release/installer stubs live under
# $_GOLDEN_HOME so the file:// URLs the commands echo normalize to <HOME>.
# `tau bug`'s bundle-carrying output is intentionally NOT byte-pinned: the
# issue URL percent-encodes the diagnostics bundle (build metadata, curl
# version), so its bytes change every build — its structure, redaction, and
# failure contract are covered by the `bug` group.
# Regenerate after an intentional contract change:
#   GOLDEN_UPDATE=1 ./scripts/smoke.sh --group golden-maintenance
test_group_golden_maintenance() {
  GOLDEN_DIR="$ROOT/tests/golden"
  _GOLDEN_BIN="$(realpath "$BIN" 2>/dev/null || printf '%s' "$BIN")"
  _golden_fresh_home

  # ── tau explain — rendered from src/errors.zig, fully offline ──
  golden_check ex-catalog          0 "$BIN" explain
  golden_check ex-code             0 "$BIN" explain 106
  golden_check ex-type-tag         0 "$BIN" explain authfailed
  golden_check ex-human            0 "$BIN" explain --human 105
  golden_check ex-uncataloged      0 "$BIN" explain 42
  golden_check ex-unknown-name     1 "$BIN" explain bogus
  golden_check ex-code-zero        1 "$BIN" explain 0
  golden_check ex-bad-flag        80 "$BIN" explain --nope

  # ── tau version --check — file:// release stubs, no network ──
  local stubs="$_GOLDEN_HOME/rel"
  mkdir -p "$stubs"
  printf '{"tag_name":"v99.9.9","name":"newer"}' > "$stubs/newer.json"
  printf '{"tag_name":"v0.4.0"}' > "$stubs/same.json"
  printf 'not json' > "$stubs/bad.json"

  golden_check   vc-opt-out        0 env TAU_NO_UPDATE_CHECK=1 "$BIN" version --check
  golden_check   vc-newer          0 env TAU_UPDATE_URL="file://$stubs/newer.json" "$BIN" version --check
  golden_check   vc-same           0 env TAU_UPDATE_URL="file://$stubs/same.json" "$BIN" version --check
  golden_check   vc-text           0 env TAU_UPDATE_URL="file://$stubs/newer.json" "$BIN" version --check --mode text
  golden_check   vc-bad-payload    0 env TAU_UPDATE_URL="file://$stubs/bad.json" "$BIN" version --check
  golden_check_n vc-missing        0 env TAU_UPDATE_URL="file://$stubs/missing.json" "$BIN" version --check

  # ── tau bug — arg validation + the deterministic --no-report surface ──
  golden_check   bug-bad-flag          80 "$BIN" bug --bogus
  golden_check   bug-mutex             80 "$BIN" bug --out x.md --no-report
  golden_check   bug-missing-value     80 "$BIN" bug --title
  golden_check   bug-no-report          0 "$BIN" bug --offline --no-report
  golden_check   bug-no-report-custom   0 "$BIN" bug --offline --no-report \
    --title "crash on --deep" --labels "bug,triage" --body "it broke"

  # ── tau upgrade — offline stubs; install dest pinned under <HOME> ──
  golden_check   ug-bad-flag        80 "$BIN" upgrade --bogus
  golden_check   ug-positional      80 "$BIN" upgrade now
  golden_check   ug-dir-no-value    80 "$BIN" upgrade --dir
  golden_check   ug-opt-out          1 env TAU_NO_UPDATE_CHECK=1 "$BIN" upgrade --yes
  golden_check   ug-up-to-date       0 env TAU_UPDATE_URL="file://$stubs/same.json" "$BIN" upgrade
  golden_check_n ug-lookup-failed    1 env TAU_UPDATE_URL="file://$stubs/missing.json" "$BIN" upgrade --yes
  golden_check_n ug-unconfirmed      1 env TAU_UPDATE_URL="file://$stubs/newer.json" \
    TAU_INSTALL_DIR="$_GOLDEN_HOME/ug-dest" \
    sh -c '"$0" upgrade < /dev/null' "$BIN"
  golden_check_n ug-dry-run          0 env TAU_UPDATE_URL="file://$stubs/newer.json" \
    TAU_INSTALL_DIR="$_GOLDEN_HOME/ug-dest" "$BIN" upgrade --dry-run
  golden_check_n ug-installer-failed 1 env TAU_UPDATE_URL="file://$stubs/newer.json" \
    TAU_INSTALL_URL="file://$stubs/no-such-install.sh" \
    TAU_INSTALL_DIR="$_GOLDEN_HOME/ug-dest" "$BIN" upgrade --yes
}

# Group: generated docs/errors.md drift check
# docs/errors.md is rendered from the Spec catalog in src/errors.zig by
# scripts/gen-errors-doc.py; --check regenerates in memory and fails on drift.
test_group_errors_doc() {
  note "generated docs/errors.md drift check"

  local doc="$ROOT/docs/errors.md"
  local gen="$ROOT/scripts/gen-errors-doc.py"

  if [ -f "$doc" ]; then
    ok "errors-doc: docs/errors.md exists" 0 0
    contains "errors-doc: doc declares itself generated" "$(cat "$doc")" "GENERATED FILE"
  else
    ok "errors-doc: docs/errors.md exists" 1 0
    contains "errors-doc: doc declares itself generated" "" "GENERATED FILE"
  fi

  if ! command -v python3 >/dev/null 2>&1; then
    skip_test "errors-doc: --check passes (no drift)" "python3 not on PATH"
    skip_test "errors-doc: --check detects a stale doc" "python3 not on PATH"
    return 0
  fi

  if python3 "$gen" --check >/dev/null 2>&1; then
    ok "errors-doc: --check passes (no drift)" 0 0
  else
    ok "errors-doc: --check passes (no drift)" 1 0
  fi

  # Prove the drift check isn't vacuous: append junk, expect failure, restore.
  if [ -f "$doc" ]; then
    cp "$doc" "$SMOKE_TEMP/errors.md.bak"
    printf '\n<!-- stale -->\n' >> "$doc"
    if python3 "$gen" --check >/dev/null 2>&1; then
      ok "errors-doc: --check detects a stale doc" 0 1
    else
      ok "errors-doc: --check detects a stale doc" 0 0
    fi
    cp "$SMOKE_TEMP/errors.md.bak" "$doc"
    # Leave the tree clean even if a later check fails.
    python3 "$gen" --check >/dev/null 2>&1 || cp "$SMOKE_TEMP/errors.md.bak" "$doc"
  else
    skip_test "errors-doc: --check detects a stale doc" "docs/errors.md missing"
  fi
}

# Group: tau explain — offline error-catalog lookup
# `tau explain` renders the Spec registry in src/errors.zig (the same source
# gen-errors-doc.py renders docs/errors.md from) with no network or API key.
test_group_explain() {
  note "tau explain (offline error catalog)"

  # Single entry by exit code — JSON by default.
  capture r1 "$BIN" explain 106
  ok "explain: known code exits 0" "$r1_rc" 0
  contains "explain: entry carries code" "$r1_out" '"code":106'
  contains "explain: entry carries type" "$r1_out" '"type":"AuthFailed"'
  contains "explain: entry carries cause" "$r1_out" '"cause":"the provider rejected the API key'
  contains "explain: entry carries hint" "$r1_out" '"hint":"provide an API key'
  contains "explain: entry carries docs link" "$r1_out" '"docs":"https://github.com/javimosch/tau/blob/master/docs/providers.md"'

  # Same entry reachable by wire `type` tag (case-insensitive).
  capture r2 "$BIN" explain authfailed
  ok "explain: type-tag lookup exits 0" "$r2_rc" 0
  contains "explain: type tag resolves to code" "$r2_out" '"code":106'

  # Bare `explain` lists the whole catalog.
  capture r3 "$BIN" explain
  ok "explain: catalog list exits 0" "$r3_rc" 0
  contains "explain: list uses errors envelope" "$r3_out" '"errors":['
  for c in 1 80 82 105 106 110 111; do
    contains "explain: catalog lists code $c" "$r3_out" "\"code\":$c"
  done

  # --human renders prose drawn from the same Spec fields.
  capture r4 "$BIN" explain --human 105
  ok "explain: --human exits 0" "$r4_rc" 0
  contains "explain: --human prints exit+type" "$r4_out" "exit 105  Timeout"
  contains "explain: --human prints cause" "$r4_out" "cause: an HTTP request to the provider endpoint exceeded --timeout-ms"
  contains "explain: --human prints fix" "$r4_out" "fix:   raise --timeout-ms"

  # Codes outside the catalog still resolve to the generic internal_error
  # spec (code preserved) — mirrors the envelope rule in docs/errors.md.
  capture r5 "$BIN" explain 42
  ok "explain: uncataloged code exits 0" "$r5_rc" 0
  contains "explain: fallback preserves code" "$r5_out" '"code":42'
  contains "explain: fallback inherits type" "$r5_out" '"type":"internal_error"'

  # Unknown queries fail closed: not_found envelope on stderr, exit 1.
  capture r6 "$BIN" explain bogus
  ok "explain: unknown name exits 1" "$r6_rc" 1
  contains "explain: unknown name emits not_found" "$r6_err" '"type":"not_found"'
  contains "explain: message points at the catalog" "$r6_err" 'run `tau explain` to list the catalog'

  # Exit 0 is success — never an error.
  capture r7 "$BIN" explain 0
  ok "explain: code 0 exits 1" "$r7_rc" 1
  contains "explain: code 0 emits not_found" "$r7_err" '"type":"not_found"'

  # Bad flags route through the standard invalid_argument envelope.
  capture r8 "$BIN" explain --nope
  ok "explain: bad flag exits 80" "$r8_rc" 80
  contains "explain: bad flag envelope on stderr" "$r8_err" '"type":"invalid_argument"'
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
# Verifies the Critic directive is injected and the model ends with one of the
# terminal verdict sentinels when asked to audit code with read-only tools.
test_group_network_role_critic() {
  local out rc

  note "network: --role critic sentinel"

  if ! $has_key; then
    skip_test "--role critic network" "no API key"
    return
  fi

  out=$($BIN --role critic --tools read,grep,ls "Audit src/main.zig for bugs"); rc=$?
  ok "--role critic exit" "$rc" 0

  if printf '%s' "$out" | grep -qE '<APPROVED>|<BLOCKED>'; then
    ok "--role critic response contains <APPROVED> or <BLOCKED>" 0 0
  else
    ok "--role critic response missing <APPROVED>/<BLOCKED>" 1 0
    [ "$SMOKE_DEBUG" = "1" ] && diag "critic output: $out"
  fi
}

# Group: shell completions coverage (offline drift guard)
# Every flag advertised by --help-json and every subcommand/enum value must
# appear in each shipped completion file (bash, zsh, fish, PowerShell).
test_group_completions() {
  local out flags f missing fl word
  local files="completions/tau.bash completions/_tau completions/tau.fish completions/tau.ps1"

  out=$("$BIN" --help-json)
  flags=$(printf '%s' "$out" | python3 -c 'import sys,json; print("\n".join(f["name"].lstrip("-") for f in json.load(sys.stdin)["flags"]))' 2>/dev/null)
  if [ -n "$flags" ]; then
    ok "--help-json flag list extracted" 0 0
  else
    ok "--help-json flag list extracted" 1 0
    return
  fi

  for f in $files; do
    if [ ! -f "$ROOT/$f" ]; then
      ok "$f exists" 1 0
      continue
    fi
    ok "$f exists" 0 0

    missing=""
    for fl in $flags; do
      grep -Fq -- "$fl" "$ROOT/$f" || missing="$missing $fl"
    done
    if [ -z "$missing" ]; then
      ok "$f covers every --help-json flag" 0 0
    else
      ok "$f missing flags:$missing" 1 0
    fi

    missing=""
    for word in acp fleet skills models guide \
                xiaomi openai deepseek opencode-go text json \
                author critic coordinator none \
                bash ls read write edit grep find calculator; do
      grep -Fqw -- "$word" "$ROOT/$f" || missing="$missing $word"
    done
    if [ -z "$missing" ]; then
      ok "$f covers subcommands and enum values" 0 0
    else
      ok "$f missing words:$missing" 1 0
    fi
  done
}

# Group: release surface — install.sh installer + release workflow drift guards.
# Fully offline: uses --dry-run and TAU_OS/TAU_ARCH overrides, never downloads.
test_group_release() {
  local out rc
  local inst="$ROOT/install.sh"
  local wf="$ROOT/.github/workflows/release.yml"

  note "release: install.sh + workflow surface"

  # ── install.sh basics ──
  [ -f "$inst" ];  ok "install.sh exists" "$?" 0
  [ -x "$inst" ];  ok "install.sh is executable" "$?" 0
  sh -n "$inst" 2>/dev/null;   ok "install.sh passes sh -n syntax check" "$?" 0
  bash -n "$inst" 2>/dev/null; ok "install.sh passes bash -n syntax check" "$?" 0

  out=$("$inst" --help 2>&1); rc=$?
  ok "install.sh --help exit" "$rc" 0
  contains "install.sh --help shows usage" "$out" "--version"

  # ── platform → asset name mapping (dry-run, no network) ──
  out=$(TAU_OS=linux TAU_ARCH=x86_64 "$inst" --dry-run 2>&1); rc=$?
  ok "dry-run linux/x86_64 exit" "$rc" 0
  contains "dry-run linux/x86_64 asset" "$out" "tau-linux-x86_64.tar.gz"
  contains "dry-run default hits latest" "$out" "releases/latest/download/"

  out=$(TAU_OS=darwin TAU_ARCH=arm64 "$inst" --dry-run 2>&1)
  contains "dry-run darwin/arm64 → macos-aarch64" "$out" "tau-macos-aarch64.tar.gz"

  out=$(TAU_OS=darwin TAU_ARCH=x86_64 "$inst" --dry-run 2>&1)
  contains "dry-run darwin/x86_64 → macos-x86_64" "$out" "tau-macos-x86_64.tar.gz"

  out=$(TAU_OS=linux TAU_ARCH=aarch64 "$inst" --dry-run 2>&1)
  contains "dry-run linux/aarch64 asset" "$out" "tau-linux-aarch64.tar.gz"

  # ── version pinning ──
  out=$(TAU_OS=linux TAU_ARCH=x86_64 "$inst" --dry-run --version 1.2.3 2>&1)
  contains "dry-run --version pins tag URL" "$out" "releases/download/v1.2.3/tau-linux-x86_64.tar.gz"

  out=$(TAU_OS=linux TAU_ARCH=x86_64 "$inst" --dry-run --version v1.2.3 2>&1)
  contains "dry-run --version strips leading v" "$out" "releases/download/v1.2.3/"

  # ── TAU_BASE_URL override (the release workflow's smoke job relies on it) ──
  out=$(TAU_BASE_URL=http://127.0.0.1:18923 TAU_OS=linux TAU_ARCH=x86_64 "$inst" --dry-run 2>&1)
  contains "TAU_BASE_URL overrides download base" "$out" "http://127.0.0.1:18923/latest/download/tau-linux-x86_64.tar.gz"

  out=$(TAU_BASE_URL=file:///tmp/staged TAU_OS=darwin TAU_ARCH=arm64 "$inst" --dry-run --version 2.0.0 2>&1)
  contains "TAU_BASE_URL composes with --version" "$out" "file:///tmp/staged/download/v2.0.0/tau-macos-aarch64.tar.gz"

  # ── error paths ──
  TAU_OS=plan9 TAU_ARCH=x "$inst" --dry-run >/dev/null 2>&1
  ok "dry-run rejects unsupported OS" "$?" 1

  "$inst" --bogus-flag >/dev/null 2>&1
  ok "install.sh rejects unknown flag" "$?" 1

  TAU_OS=linux TAU_ARCH=x86_64 "$inst" --dry-run --version notaversion >/dev/null 2>&1
  ok "install.sh rejects malformed --version" "$?" 1

  # ── install.ps1 basics (Windows installer; needs pwsh to exercise) ──
  local ps1="$ROOT/install.ps1"
  [ -f "$ps1" ]; ok "install.ps1 exists" "$?" 0
  if command -v pwsh >/dev/null 2>&1; then
    pwsh -NoProfile -Command "[scriptblock]::Create((Get-Content -LiteralPath '$ps1' -Raw)) | Out-Null" 2>/dev/null
    ok "install.ps1 parses under pwsh" "$?" 0

    out=$(pwsh -NoProfile -File "$ps1" --help 2>&1); rc=$?
    ok "install.ps1 --help exit" "$rc" 0
    contains "install.ps1 --help shows usage" "$out" "-Version"

    out=$(pwsh -NoProfile -File "$ps1" --dry-run 2>&1)
    contains "install.ps1 dry-run targets the windows zip" "$out" "tau-windows-x86_64.zip"
    contains "install.ps1 dry-run default hits latest" "$out" "releases/latest/download/"

    out=$(pwsh -NoProfile -File "$ps1" --dry-run --version 1.2.3 2>&1)
    contains "install.ps1 dry-run --version pins tag URL" "$out" "releases/download/v1.2.3/tau-windows-x86_64.zip"

    out=$(pwsh -NoProfile -File "$ps1" --dry-run --version=v1.2.3 2>&1)
    contains "install.ps1 dry-run --version= strips leading v" "$out" "releases/download/v1.2.3/"

    out=$(TAU_BASE_URL=file:///tmp/staged pwsh -NoProfile -File "$ps1" -DryRun -Version 2.0.0 2>&1)
    contains "install.ps1 TAU_BASE_URL composes with -Version" "$out" "file:///tmp/staged/download/v2.0.0/tau-windows-x86_64.zip"

    pwsh -NoProfile -File "$ps1" --bogus-flag >/dev/null 2>&1
    ok "install.ps1 rejects unknown flag" "$?" 1

    pwsh -NoProfile -File "$ps1" --dry-run --version notaversion >/dev/null 2>&1
    ok "install.ps1 rejects malformed --version" "$?" 1

    TAU_ARCH=arm64 pwsh -NoProfile -File "$ps1" --dry-run >/dev/null 2>&1
    ok "install.ps1 rejects non-x64 arch" "$?" 1
  else
    note "release: skipping install.ps1 checks (pwsh unavailable)"
  fi

  # ── workflow drift guards ──
  [ -f "$wf" ]; ok "release workflow exists" "$?" 0
  if [ -f "$wf" ]; then
    contains "workflow triggers on v* tags" "$(cat "$wf")" 'tags:'
    contains "workflow builds linux-x86_64" "$(cat "$wf")" "linux-x86_64"
    contains "workflow builds linux-aarch64" "$(cat "$wf")" "linux-aarch64"
    contains "workflow builds macos-x86_64" "$(cat "$wf")" "macos-x86_64"
    contains "workflow builds macos-aarch64" "$(cat "$wf")" "macos-aarch64"
    contains "workflow pins zig 0.16.0" "$(cat "$wf")" "0.16.0"
    contains "workflow guards tag vs version.zig" "$(cat "$wf")" "version.zig"
    contains "workflow publishes checksums" "$(cat "$wf")" "SHA256SUMS"

    # ── smoke job drift guards ──
    contains "workflow has a smoke job" "$(cat "$wf")" "  smoke:"
    contains "smoke job needs build" "$(cat "$wf")" "needs: build"
    contains "smoke gates the release" "$(cat "$wf")" "needs: [build, smoke, smoke-windows, smoke-action]"
    contains "smoke covers linux-x86_64" "$(cat "$wf")" "artifact: linux-x86_64"
    contains "smoke covers linux-aarch64" "$(cat "$wf")" "artifact: linux-aarch64"
    contains "smoke covers macos-x86_64" "$(cat "$wf")" "artifact: macos-x86_64"
    contains "smoke covers macos-aarch64" "$(cat "$wf")" "artifact: macos-aarch64"
    contains "smoke installs via install.sh" "$(cat "$wf")" "install.sh --dir"
    contains "smoke redirects install base URL" "$(cat "$wf")" "TAU_BASE_URL"
    contains "smoke verifies --version" "$(cat "$wf")" "tau --version"
    contains "smoke verifies --help" "$(cat "$wf")" "tau --help"

    # ── windows target + smoke-windows job drift guards (task #182) ──
    contains "workflow builds windows-x86_64" "$(cat "$wf")" "x86_64-windows-gnu"
    contains "workflow packages tau.exe as zip" "$(cat "$wf")" "zig-out/bin/tau.exe"
    contains "workflow checksums cover zips" "$(cat "$wf")" "sha256sum *.tar.gz *.zip"
    contains "release job publishes zips" "$(cat "$wf")" "dist/*.zip"
    contains "release notes mention install.ps1" "$(cat "$wf")" "install.ps1 | iex"
    contains "workflow has a smoke-windows job" "$(cat "$wf")" "  smoke-windows:"
    contains "smoke-windows runs on windows-latest" "$(cat "$wf")" "runs-on: windows-latest"
    contains "smoke-windows installs via install.ps1" "$(cat "$wf")" "install.ps1 -Dir"
    contains "smoke-windows stages via file://" "$(cat "$wf")" "file:///"

    # ── winget job drift guards (task #182) ──
    contains "workflow has a winget job" "$(cat "$wf")" "  winget:"
    contains "winget job runs after release" "$(cat "$wf")" "needs: release"
    contains "winget job runs the manifest generator" "$(cat "$wf")" "generate-winget-manifest.sh"
    contains "winget job uploads the manifest artifact" "$(cat "$wf")" "winget-manifest-"
    contains "winget job gates submission on a token" "$(cat "$wf")" "WINGET_PKGS_TOKEN"
    contains "winget job targets winget-pkgs" "$(cat "$wf")" "wingetcreate submit"

    # ── scoop job drift guards (task #182) ──
    contains "workflow has a scoop job" "$(cat "$wf")" "  scoop:"
    contains "scoop job runs the manifest generator" "$(cat "$wf")" "generate-scoop-manifest.sh"
    contains "scoop job gates publish on a token" "$(cat "$wf")" "SCOOP_BUCKET_TOKEN"
    contains "scoop job publishes to the bucket repo" "$(cat "$wf")" "javimosch/scoop-bucket"
    contains "scoop job writes bucket/tau.json" "$(cat "$wf")" "bucket/tau.json"

    # ── smoke-action job drift guards (exercises action.yml via uses: ./) ──
    contains "workflow has a smoke-action job" "$(cat "$wf")" "  smoke-action:"
    contains "smoke-action needs build" "$(cat "$wf")" "needs: build"
    contains "smoke-action uses the local action" "$(cat "$wf")" "uses: ./"
    contains "smoke-action passes base-url" "$(cat "$wf")" "base-url: http://127.0.0.1:"
    contains "smoke-action checks outputs" "$(cat "$wf")" "steps.setup.outputs.tau-path"

    # ── checksum chain drift guards (task #161) ──
    contains "build emits per-asset checksums" "$(cat "$wf")" ".tar.gz.sha256"
    contains "smoke verifies artifact checksum" "$(cat "$wf")" "Verify artifact checksum"
    contains "smoke checks tarball against .sha256" "$(cat "$wf")" 'sha256sum -c "tau-'
    contains "release self-verifies SHA256SUMS.txt" "$(cat "$wf")" "sha256sum -c SHA256SUMS.txt"

    # ── homebrew tap job drift guards (task #175) ──
    contains "workflow has a homebrew job" "$(cat "$wf")" "  homebrew:"
    contains "homebrew job runs after release" "$(cat "$wf")" "needs: release"
    contains "homebrew job gates on tags" "$(cat "$wf")" "github.ref_type == 'tag'"
    contains "homebrew job runs the formula generator" "$(cat "$wf")" "generate-homebrew-formula.sh"
    contains "homebrew job pushes to the tap repo" "$(cat "$wf")" "javimosch/homebrew-tap"
    contains "homebrew job writes Formula/tau.rb" "$(cat "$wf")" "Formula/tau.rb"
    contains "homebrew job uses the tap token secret" "$(cat "$wf")" "HOMEBREW_TAP_TOKEN"
    contains "homebrew job skips pre-release tags" "$(cat "$wf")" 'is a pre-release'
    contains "release notes mention brew install" "$(cat "$wf")" "brew install javimosch/tap/tau"
  fi

  # ── Homebrew formula generator ──
  local gen="$ROOT/scripts/generate-homebrew-formula.sh"
  [ -f "$gen" ];  ok "formula generator exists" "$?" 0
  [ -x "$gen" ];  ok "formula generator is executable" "$?" 0
  sh -n "$gen" 2>/dev/null;   ok "formula generator passes sh -n syntax check" "$?" 0
  bash -n "$gen" 2>/dev/null; ok "formula generator passes bash -n syntax check" "$?" 0

  out=$("$gen" --help 2>&1); rc=$?
  ok "formula generator --help exit" "$rc" 0
  contains "formula generator --help shows usage" "$out" "--version"

  local fdir
  fdir="$(mktemp -d)"
  printf '%064d  %s\n' 11 tau-macos-aarch64.tar.gz  > "$fdir/SHA256SUMS.txt"
  printf '%064d  %s\n' 22 tau-macos-x86_64.tar.gz  >> "$fdir/SHA256SUMS.txt"
  printf '%064d  %s\n' 33 tau-linux-x86_64.tar.gz  >> "$fdir/SHA256SUMS.txt"
  printf '%064d  %s\n' 44 tau-linux-aarch64.tar.gz >> "$fdir/SHA256SUMS.txt"

  out=$("$gen" --version 1.2.3 --sums "$fdir/SHA256SUMS.txt" 2>&1); rc=$?
  ok "formula generator renders" "$rc" 0
  contains "formula class is Tau" "$out" "class Tau < Formula"
  contains "formula carries the version" "$out" 'version "1.2.3"'
  contains "formula is MIT licensed" "$out" 'license "MIT"'
  contains "formula has macos arm block" "$out" "on_arm do"
  contains "formula has macos intel block" "$out" "on_intel do"
  contains "formula has linux block" "$out" "on_linux do"
  contains "formula macos-arm url" "$out" "releases/download/v1.2.3/tau-macos-aarch64.tar.gz"
  contains "formula macos-intel url" "$out" "releases/download/v1.2.3/tau-macos-x86_64.tar.gz"
  contains "formula linux-x86_64 url" "$out" "releases/download/v1.2.3/tau-linux-x86_64.tar.gz"
  contains "formula linux-aarch64 url" "$out" "releases/download/v1.2.3/tau-linux-aarch64.tar.gz"
  contains "formula macos-arm sha" "$out" 'sha256 "0000000000000000000000000000000000000000000000000000000000000011"'
  contains "formula linux-aarch64 sha" "$out" 'sha256 "0000000000000000000000000000000000000000000000000000000000000044"'
  contains "formula installs the tau binary" "$out" 'bin.install "tau"'
  contains "formula test runs --version" "$out" 'tau --version'

  out=$("$gen" --version v2.0.0 --sums "$fdir/SHA256SUMS.txt" 2>&1)
  contains "leading v is stripped from version" "$out" 'version "2.0.0"'

  # fail-closed paths: no blank checksums, no malformed versions
  "$gen" --version 1.0.0 --sums "$fdir/missing.txt" >/dev/null 2>&1
  ok "generator rejects missing manifest" "$?" 1
  printf 'deadbeef  tau-macos-aarch64.tar.gz\n' > "$fdir/partial.txt"
  "$gen" --version 1.0.0 --sums "$fdir/partial.txt" >/dev/null 2>&1
  ok "generator rejects manifest missing assets" "$?" 1
  "$gen" --version notaversion --sums "$fdir/SHA256SUMS.txt" >/dev/null 2>&1
  ok "generator rejects malformed version" "$?" 1
  "$gen" --bogus >/dev/null 2>&1
  ok "generator rejects unknown flag" "$?" 1
  rm -rf "$fdir"

  # ── winget manifest generator ──
  local wgen="$ROOT/scripts/generate-winget-manifest.sh"
  [ -f "$wgen" ];  ok "winget generator exists" "$?" 0
  [ -x "$wgen" ];  ok "winget generator is executable" "$?" 0
  sh -n "$wgen" 2>/dev/null;   ok "winget generator passes sh -n syntax check" "$?" 0
  bash -n "$wgen" 2>/dev/null; ok "winget generator passes bash -n syntax check" "$?" 0

  out=$("$wgen" --help 2>&1); rc=$?
  ok "winget generator --help exit" "$rc" 0
  contains "winget generator --help shows usage" "$out" "--output-dir"

  local wdir
  wdir="$(mktemp -d)"
  printf '%064d  %s\n' 55 tau-windows-x86_64.zip > "$wdir/SHA256SUMS.txt"

  "$wgen" --version 1.2.3 --sums "$wdir/SHA256SUMS.txt" --output-dir "$wdir/out" >/dev/null 2>&1; rc=$?
  ok "winget generator renders" "$rc" 0
  [ -f "$wdir/out/javimosch.tau.yaml" ];              ok "winget version manifest written" "$?" 0
  [ -f "$wdir/out/javimosch.tau.installer.yaml" ];    ok "winget installer manifest written" "$?" 0
  [ -f "$wdir/out/javimosch.tau.locale.en-US.yaml" ]; ok "winget locale manifest written" "$?" 0
  contains "winget version file carries version" "$(cat "$wdir/out/javimosch.tau.yaml")" "PackageVersion: 1.2.3"
  contains "winget installer is a zip" "$(cat "$wdir/out/javimosch.tau.installer.yaml")" "InstallerType: zip"
  contains "winget installer nests a portable exe" "$(cat "$wdir/out/javimosch.tau.installer.yaml")" "RelativeFilePath: tau.exe"
  contains "winget installer url" "$(cat "$wdir/out/javimosch.tau.installer.yaml")" "releases/download/v1.2.3/tau-windows-x86_64.zip"
  contains "winget installer sha" "$(cat "$wdir/out/javimosch.tau.installer.yaml")" 'InstallerSha256: 0000000000000000000000000000000000000000000000000000000000000055'
  contains "winget locale file identifies package" "$(cat "$wdir/out/javimosch.tau.locale.en-US.yaml")" "PackageIdentifier: javimosch.tau"
  if python3 -c 'import yaml' 2>/dev/null; then
    python3 -c 'import sys, yaml; [yaml.safe_load(open(f)) for f in sys.argv[1:]]' "$wdir/out/"*.yaml 2>/dev/null
    ok "winget manifests parse as YAML" "$?" 0
  else
    note "release: skipping winget YAML parse (PyYAML unavailable)"
  fi

  "$wgen" --version 1.0.0 --sums "$wdir/missing.txt" --output-dir "$wdir/o2" >/dev/null 2>&1
  ok "winget generator rejects missing manifest" "$?" 1
  printf 'deadbeef  tau-macos-aarch64.tar.gz\n' > "$wdir/partial.txt"
  "$wgen" --version 1.0.0 --sums "$wdir/partial.txt" --output-dir "$wdir/o3" >/dev/null 2>&1
  ok "winget generator rejects manifest missing the zip" "$?" 1
  "$wgen" --version notaversion --sums "$wdir/SHA256SUMS.txt" --output-dir "$wdir/o4" >/dev/null 2>&1
  ok "winget generator rejects malformed version" "$?" 1
  "$wgen" --bogus >/dev/null 2>&1
  ok "winget generator rejects unknown flag" "$?" 1
  rm -rf "$wdir"

  # ── Scoop manifest generator ──
  local sgen="$ROOT/scripts/generate-scoop-manifest.sh"
  [ -f "$sgen" ];  ok "scoop generator exists" "$?" 0
  [ -x "$sgen" ];  ok "scoop generator is executable" "$?" 0
  sh -n "$sgen" 2>/dev/null;   ok "scoop generator passes sh -n syntax check" "$?" 0
  bash -n "$sgen" 2>/dev/null; ok "scoop generator passes bash -n syntax check" "$?" 0

  out=$("$sgen" --help 2>&1); rc=$?
  ok "scoop generator --help exit" "$rc" 0
  contains "scoop generator --help shows usage" "$out" "--sums"

  local sdir
  sdir="$(mktemp -d)"
  printf '%064d  %s\n' 77 tau-windows-x86_64.zip > "$sdir/SHA256SUMS.txt"

  out=$("$sgen" --version 1.2.3 --sums "$sdir/SHA256SUMS.txt" 2>&1); rc=$?
  ok "scoop generator renders" "$rc" 0
  contains "scoop manifest carries the version" "$out" '"version": "1.2.3"'
  contains "scoop manifest zip url" "$out" "releases/download/v1.2.3/tau-windows-x86_64.zip"
  contains "scoop manifest sha256 hash" "$out" 'sha256:0000000000000000000000000000000000000000000000000000000000000077'
  contains "scoop manifest declares tau.exe bin" "$out" '"bin": "tau.exe"'
  contains "scoop manifest has autoupdate" "$out" '"autoupdate"'
  contains "scoop manifest has checkver" "$out" '"checkver"'
  if command -v python3 >/dev/null 2>&1; then
    printf '%s' "$out" | python3 -m json.tool >/dev/null 2>&1
    ok "scoop manifest is valid JSON" "$?" 0
  fi

  out=$("$sgen" --version v2.0.0 --sums "$sdir/SHA256SUMS.txt" 2>&1)
  contains "scoop generator strips leading v" "$out" '"version": "2.0.0"'

  "$sgen" --version 1.0.0 --sums "$sdir/missing.txt" >/dev/null 2>&1
  ok "scoop generator rejects missing manifest" "$?" 1
  printf 'deadbeef  tau-macos-aarch64.tar.gz\n' > "$sdir/partial.txt"
  "$sgen" --version 1.0.0 --sums "$sdir/partial.txt" >/dev/null 2>&1
  ok "scoop generator rejects manifest missing the zip" "$?" 1
  "$sgen" --version notaversion --sums "$sdir/SHA256SUMS.txt" >/dev/null 2>&1
  ok "scoop generator rejects malformed version" "$?" 1
  "$sgen" --bogus >/dev/null 2>&1
  ok "scoop generator rejects unknown flag" "$?" 1
  rm -rf "$sdir"

  # ── setup-tau composite action (repo-root action.yml) ──
  local act="$ROOT/action.yml"
  [ -f "$act" ]; ok "action.yml exists at repo root" "$?" 0
  if [ -f "$act" ]; then
    contains "action.yml is a composite action" "$(cat "$act")" "using: composite"
    contains "action.yml invokes repo install.sh" "$(cat "$act")" 'GITHUB_ACTION_PATH/install.sh'
    contains "action.yml exposes version input" "$(cat "$act")" "version:"
    contains "action.yml exposes install-dir input" "$(cat "$act")" "install-dir:"
    contains "action.yml exposes base-url input" "$(cat "$act")" "base-url:"
    contains "action.yml maps version input to TAU_VERSION" "$(cat "$act")" "TAU_VERSION"
    contains "action.yml maps install-dir input to TAU_INSTALL_DIR" "$(cat "$act")" "TAU_INSTALL_DIR"
    contains "action.yml maps base-url input to TAU_BASE_URL" "$(cat "$act")" "TAU_BASE_URL"
    contains "action.yml puts install dir on PATH" "$(cat "$act")" "GITHUB_PATH"
    contains "action.yml emits step outputs" "$(cat "$act")" "GITHUB_OUTPUT"
    contains "action.yml surfaces tau-path output" "$(cat "$act")" "tau-path"
    contains "action.yml surfaces version output" "$(cat "$act")" "steps.install.outputs.version"
    contains "action.yml uses bash for the run step" "$(cat "$act")" "shell: bash"

    if python3 -c 'import yaml' 2>/dev/null; then
      python3 -c 'import sys, yaml; yaml.safe_load(open(sys.argv[1]))' "$act" 2>/dev/null
      ok "action.yml parses as YAML" "$?" 0
    else
      note "release: skipping action.yml YAML parse (PyYAML unavailable)"
    fi
  fi

  # ── asset-name contract between workflow and installer ──
  contains "installer emits workflow-style asset names" "$(cat "$inst")" 'tau-$PLATFORM.tar.gz'

  # ── fail-closed checksum contract (task #161) ──
  contains "installer documents TAU_SKIP_CHECKSUM" "$(cat "$inst")" "TAU_SKIP_CHECKSUM"
  contains "installer fail-closes on missing manifest" "$(cat "$inst")" "refusing to install an unverified binary"
  contains "installer reports asset absent from manifest" "$(cat "$inst")" "not listed in \$SUMS"

  # ── offline end-to-end install via file:// (needs a built binary) ──
  # Mirrors the CI smoke job: stage latest/download/<asset> + SHA256SUMS.txt,
  # install through install.sh against TAU_BASE_URL=file://…, run the binary.
  if [ -x "$ROOT/zig-out/bin/tau" ]; then
    local asset_os asset_arch
    case "$(uname -s)" in
      Linux)  asset_os=linux ;;
      Darwin) asset_os=macos ;;
      *)      asset_os="" ;;
    esac
    asset_arch="$(uname -m)"
    case "$asset_arch" in
      amd64) asset_arch=x86_64 ;;
      arm64) asset_arch=aarch64 ;;
      x86_64|aarch64) ;;
      *) asset_arch="" ;;
    esac

    if [ -n "$asset_os" ] && [ -n "$asset_arch" ]; then
      local e2e asset
      e2e="$(mktemp -d)"
      asset="tau-$asset_os-$asset_arch.tar.gz"
      mkdir -p "$e2e/srv/latest/download"
      tar -czf "$e2e/srv/latest/download/$asset" -C "$ROOT/zig-out/bin" tau
      (cd "$e2e/srv/latest/download" && \
        { sha256sum "$asset" 2>/dev/null || shasum -a 256 "$asset"; } > SHA256SUMS.txt)

      out=$(TAU_BASE_URL="file://$e2e/srv" "$inst" --dir "$e2e/bin" 2>&1); rc=$?
      ok "e2e file:// install exit" "$rc" 0
      contains "e2e install reports dest" "$out" "installed tau -> $e2e/bin/tau"
      [ -x "$e2e/bin/tau" ]; ok "e2e installed binary is executable" "$?" 0

      out=$("$e2e/bin/tau" --version 2>&1); rc=$?
      ok "e2e installed tau --version exit" "$rc" 0
      contains "e2e tau --version shape" "$out" "tau "
      out=$("$e2e/bin/tau" --help 2>&1); rc=$?
      ok "e2e installed tau --help exit" "$rc" 0
      contains "e2e tau --help shows usage" "$out" "Usage:"

      # corrupted checksum must abort the install
      printf '%064d  %s\n' 0 "$asset" > "$e2e/srv/latest/download/SHA256SUMS.txt"
      out=$(TAU_BASE_URL="file://$e2e/srv" "$inst" --dir "$e2e/bin2" 2>&1); rc=$?
      ok "e2e rejects checksum mismatch" "$rc" 1
      contains "e2e checksum failure message" "$out" "checksum verification failed"

      # asset absent from the manifest must abort (fail closed)
      printf '%064d  %s\n' 0 "tau-other-thing.tar.gz" > "$e2e/srv/latest/download/SHA256SUMS.txt"
      out=$(TAU_BASE_URL="file://$e2e/srv" "$inst" --dir "$e2e/bin3" 2>&1); rc=$?
      ok "e2e rejects asset missing from manifest" "$rc" 1
      contains "e2e manifest-miss message" "$out" "not listed in SHA256SUMS.txt"

      # no manifest at all must abort (an attacker could strip it to hide tampering)
      rm -f "$e2e/srv/latest/download/SHA256SUMS.txt"
      out=$(TAU_BASE_URL="file://$e2e/srv" "$inst" --dir "$e2e/bin4" 2>&1); rc=$?
      ok "e2e rejects missing checksum manifest" "$rc" 1
      contains "e2e missing-manifest message" "$out" "unverified binary"

      # documented opt-out: bypass installs anyway, with a loud warning
      out=$(TAU_SKIP_CHECKSUM=1 TAU_BASE_URL="file://$e2e/srv" "$inst" --dir "$e2e/bin5" 2>&1); rc=$?
      ok "e2e TAU_SKIP_CHECKSUM bypass exit" "$rc" 0
      contains "e2e skip-checksum warns" "$out" "TAU_SKIP_CHECKSUM=1"
      [ -x "$e2e/bin5/tau" ]; ok "e2e skip-checksum installed binary" "$?" 0

      rm -rf "$e2e"
    else
      note "release: skipping e2e install (unsupported host platform)"
    fi
  else
    note "release: skipping e2e install (no zig-out/bin/tau build present)"
  fi

  # ── offline end-to-end install.ps1 via file:// (needs pwsh + python3) ──
  # Stages a stand-in tau.exe zip + SHA256SUMS.txt, installs through
  # install.ps1 against TAU_BASE_URL=file://…, and exercises the same
  # fail-closed checksum contract as the install.sh e2e above. A real Windows
  # binary run is covered by the release workflow's windows-latest leg.
  if command -v pwsh >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
    local we2e
    we2e="$(mktemp -d)"
    mkdir -p "$we2e/srv/latest/download" "$we2e/stage"
    printf 'not a real exe\n' > "$we2e/stage/tau.exe"
    (cd "$we2e/stage" && python3 -m zipfile -c "$we2e/srv/latest/download/tau-windows-x86_64.zip" tau.exe)
    (cd "$we2e/srv/latest/download" && \
      { sha256sum tau-windows-x86_64.zip 2>/dev/null || shasum -a 256 tau-windows-x86_64.zip; } > SHA256SUMS.txt)

    out=$(TAU_BASE_URL="file://$we2e/srv" pwsh -NoProfile -File "$ps1" -Dir "$we2e/bin" 2>&1); rc=$?
    ok "e2e ps1 file:// install exit" "$rc" 0
    contains "e2e ps1 checksum verified" "$out" "checksum verified against SHA256SUMS.txt"
    [ -f "$we2e/bin/tau.exe" ]; ok "e2e ps1 installed tau.exe" "$?" 0

    # corrupted checksum must abort the install
    printf '%064d  %s\n' 0 tau-windows-x86_64.zip > "$we2e/srv/latest/download/SHA256SUMS.txt"
    out=$(TAU_BASE_URL="file://$we2e/srv" pwsh -NoProfile -File "$ps1" -Dir "$we2e/bin2" 2>&1); rc=$?
    ok "e2e ps1 rejects checksum mismatch" "$rc" 1
    contains "e2e ps1 checksum failure message" "$out" "checksum verification failed"

    # asset absent from the manifest must abort (fail closed)
    printf '%064d  %s\n' 0 tau-other-thing.zip > "$we2e/srv/latest/download/SHA256SUMS.txt"
    out=$(TAU_BASE_URL="file://$we2e/srv" pwsh -NoProfile -File "$ps1" -Dir "$we2e/bin3" 2>&1); rc=$?
    ok "e2e ps1 rejects asset missing from manifest" "$rc" 1
    contains "e2e ps1 manifest-miss message" "$out" "not listed in SHA256SUMS.txt"

    # no manifest at all must abort
    rm -f "$we2e/srv/latest/download/SHA256SUMS.txt"
    out=$(TAU_BASE_URL="file://$we2e/srv" pwsh -NoProfile -File "$ps1" -Dir "$we2e/bin4" 2>&1); rc=$?
    ok "e2e ps1 rejects missing checksum manifest" "$rc" 1
    contains "e2e ps1 missing-manifest message" "$out" "unverified binary"

    # documented opt-out: bypass installs anyway, with a loud warning
    out=$(TAU_SKIP_CHECKSUM=1 TAU_BASE_URL="file://$we2e/srv" pwsh -NoProfile -File "$ps1" -Dir "$we2e/bin5" 2>&1); rc=$?
    ok "e2e ps1 TAU_SKIP_CHECKSUM bypass exit" "$rc" 0
    contains "e2e ps1 skip-checksum warns" "$out" "TAU_SKIP_CHECKSUM=1"
    [ -f "$we2e/bin5/tau.exe" ]; ok "e2e ps1 skip-checksum installed tau.exe" "$?" 0

    rm -rf "$we2e"
  else
    note "release: skipping install.ps1 e2e (pwsh or python3 unavailable)"
  fi
}

# Group: first-run e2e — clean-environment install → setup → selftest contract.
# Pins scripts/e2e-first-run.{sh,ps1} and the ci.yml first-run job wiring, then
# runs the POSIX driver end-to-end against $BIN in a scratch HOME (offline:
# the selftest stub is loopback-only, --offline skips live endpoint checks).
test_group_first_run() {
  local out rc fh
  local shdrv="$ROOT/scripts/e2e-first-run.sh"
  local psdrv="$ROOT/scripts/e2e-first-run.ps1"
  local ci="$ROOT/.github/workflows/ci.yml"
  local rwf="$ROOT/.github/workflows/release.yml"

  note "first-run: e2e drivers + CI wiring"

  # ── POSIX driver surface ──
  [ -f "$shdrv" ];  ok "e2e-first-run.sh exists" "$?" 0
  [ -x "$shdrv" ];  ok "e2e-first-run.sh is executable" "$?" 0
  bash -n "$shdrv" 2>/dev/null; ok "e2e-first-run.sh passes bash -n" "$?" 0
  contains "e2e driver runs unattended setup" "$(cat "$shdrv")" "setup --yes --offline"
  contains "e2e driver runs selftest" "$(cat "$shdrv")" "doctor --offline --selftest"
  contains "e2e driver scrubs provider keys" "$(cat "$shdrv")" "XIAOMI_API_KEY"
  contains "e2e driver uses a scratch HOME" "$(cat "$shdrv")" 'HOME="$FH"'
  contains "e2e driver asserts the selftest check row" "$(cat "$shdrv")" '"name":"selftest","status":"ok"'

  # ── PowerShell driver surface ──
  [ -f "$psdrv" ]; ok "e2e-first-run.ps1 exists" "$?" 0
  contains "ps1 driver runs unattended setup" "$(cat "$psdrv")" "setup --yes --offline"
  contains "ps1 driver runs selftest" "$(cat "$psdrv")" "doctor --offline --selftest"
  contains "ps1 driver asserts the selftest check row" "$(cat "$psdrv")" '"name":"selftest","status":"ok"'
  if command -v pwsh >/dev/null 2>&1; then
    pwsh -NoProfile -Command "[scriptblock]::Create((Get-Content -LiteralPath '$psdrv' -Raw)) | Out-Null" 2>/dev/null
    ok "e2e-first-run.ps1 parses under pwsh" "$?" 0
  else
    note "first-run: skipping ps1 parse check (pwsh unavailable)"
  fi

  # ── ci.yml wiring (drift guards for the first-run job) ──
  [ -f "$ci" ]; ok "ci.yml exists" "$?" 0
  contains "ci has a first-run job" "$(cat "$ci")" "first-run:"
  contains "ci POSIX leg stages latest/download" "$(cat "$ci")" "srv/latest/download"
  contains "ci POSIX leg installs via install.sh" "$(cat "$ci")" "sh ./install.sh --dir"
  contains "ci POSIX leg uses file:// TAU_BASE_URL" "$(cat "$ci")" 'TAU_BASE_URL="file://'
  contains "ci POSIX leg runs the e2e driver" "$(cat "$ci")" "e2e-first-run.sh"
  contains "ci windows leg installs via install.ps1" "$(cat "$ci")" "./install.ps1 -Dir"
  contains "ci windows leg stages via file://" "$(cat "$ci")" "file:///"
  contains "ci windows leg runs the ps1 driver" "$(cat "$ci")" "e2e-first-run.ps1"

  # ── release workflow self-verifies shipped artifacts too ──
  [ -f "$rwf" ]; ok "release.yml exists" "$?" 0
  contains "release smoke asserts the selftest check row" "$(cat "$rwf")" '"name":"selftest","status":"ok"'

  # ── end-to-end: run the POSIX driver against $BIN ──
  if [ -x "$BIN" ]; then
    fh="$(mktemp -d)"
    out=$("$shdrv" "$BIN" "$fh/home" 2>&1); rc=$?
    ok "e2e-first-run.sh exit" "$rc" 0
    contains "e2e-first-run reports PASS" "$out" "e2e-first-run: PASS"
    contains "e2e scaffolded config via setup --yes" "$out" "setup --yes --offline ok"
    contains "e2e keyless selftest reported ok" "$out" "credential-free doctor --selftest reports ok"
    rm -rf "$fh"
  else
    skip_test "e2e-first-run end-to-end" "no built tau binary at $BIN"
  fi
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
