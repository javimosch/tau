#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# smoke-lib.sh — Shared test harness library for tau smoke tests.
#
# Provides:
#   - Helper functions: ok, contains, skip_test, diag, note
#   - Environment setup: check_binary, check_api_key, setup_temp, cleanup
#   - Debug support: SMOKE_DEBUG, SMOKE_TRACE, SMOKE_LOG
#   - TAP-compatible output
#   - Configuration loading from smoke.config
#   - Benchmark integration hook
# ---------------------------------------------------------------------------
set -u

# ── Debug / trace modes ───────────────────────────────────────────────────
SMOKE_DEBUG="${SMOKE_DEBUG:-0}"   # set to 1 for verbose debug output
SMOKE_TRACE="${SMOKE_TRACE:-0}"   # set to 1 for bash -x style tracing
SMOKE_LOG="${SMOKE_LOG:-}"        # if set, copy all smoke output to this file
SMOKE_VERBOSE="${SMOKE_VERBOSE:-0}" # set to 1 to print test names as they run

[ "$SMOKE_TRACE" = "1" ] && set -x

# ── Output helpers ─────────────────────────────────────────────────────────

# diag: print a diagnostic message (to stderr, or to log if SMOKE_LOG set)
diag() {
  local msg="$*"
  if [ -n "$SMOKE_LOG" ]; then
    echo "# $msg" >> "$SMOKE_LOG"
  fi
  echo "# $msg" >&2
}

# note: print a visible section header
note() {
  echo >&2
  echo "== $* ==" >&2
  if [ -n "$SMOKE_LOG" ]; then
    echo "== $* ==" >> "$SMOKE_LOG"
  fi
}

# ok <name> <actual_exit> <expected_exit>
ok() {
  local name="$1"
  local actual="$2"
  local expected="$3"
  if [ "$actual" = "$expected" ]; then
    printf 'ok  %d - %s\n' $((pass + fail + skip + 1)) "$name"
    pass=$((pass + 1))
  else
    printf 'not ok %d - %s (got exit %s, want %s)\n' $((pass + fail + skip + 1)) "$name" "$actual" "$expected"
    fail=$((fail + 1))
  fi
  [ "$SMOKE_VERBOSE" = "1" ] && echo "# exit code: $actual" >&2
  return 0
}

# contains <name> <haystack> <needle>
contains() {
  local name="$1"
  local haystack="$2"
  local needle="$3"
  case "$haystack" in
    *"$needle"*)
      printf 'ok  %d - %s\n' $((pass + fail + skip + 1)) "$name"
      pass=$((pass + 1))
      ;;
    *)
      printf 'not ok %d - %s (missing %q)\n' $((pass + fail + skip + 1)) "$name" "$needle"
      fail=$((fail + 1))
      [ "$SMOKE_DEBUG" = "1" ] && diag "expected substring '$needle' not found in output (length ${#haystack} chars)"
      ;;
  esac
  [ "$SMOKE_VERBOSE" = "1" ] && echo "# output snippet: ${haystack:0:200}..." >&2
  return 0
}

# skip_test <name> [reason]
skip_test() {
  local name="$1"
  local reason="${2:-}"
  if [ -n "$reason" ]; then
    printf 'ok  %d - %s # skip %s\n' $((pass + fail + skip + 1)) "$name" "$reason"
  else
    printf 'ok  %d - %s # skip\n' $((pass + fail + skip + 1)) "$name"
  fi
  skip=$((skip + 1))
}

# bail_out: abort testing immediately
bail_out() {
  echo "Bail out! $*" >&2
  exit 1
}

# ── Configuration loading ─────────────────────────────────────────────────

# load_config <script-dir>
# Sources smoke.config from the script's directory, if present.
# Also looks for $PWD/smoke.config for project-specific overrides.
load_config() {
  local script_dir="$1"
  local config_files=(
    "$script_dir/smoke.config"
    "$PWD/smoke.config"
    "$ROOT/smoke.config"
  )
  for cfg in "${config_files[@]}"; do
    if [ -f "$cfg" ]; then
      diag "loading config: $cfg"
      source "$cfg"
    fi
  done
}

# ── Runtime environment setup ─────────────────────────────────────────────

# check_binary <path> [project-root]
# Returns 0 if binary exists and is executable.
# If missing, attempts to build with `zig build` in project root.
check_binary() {
  local bin_path="$1"
  local project_root="${2:-"$(cd "$(dirname "$bin_path")/.." && pwd)"}"

  if [ -x "$bin_path" ]; then
    return 0
  fi

  echo "WARNING: $bin_path not found, building..." >&2
  ( cd "$project_root" && zig build ) || {
    echo "ERROR: build failed" >&2
    return 1
  }

  if [ -x "$bin_path" ]; then
    echo "OK: build succeeded" >&2
    return 0
  else
    echo "ERROR: binary still missing after build" >&2
    return 1
  fi
}

# check_api_key: returns 0 if any known API key env var or config entry is set
# Sets $has_key global.
check_api_key() {
  has_key=false
  for v in TAU_API_KEY XIAOMI_API_KEY PIZIG_API_KEY OPENAI_API_KEY DEEPSEEK_API_KEY; do
    if [ -n "${!v:-}" ]; then
      has_key=true
      [ "$SMOKE_DEBUG" = "1" ] && diag "found API key in \$$v"
      return 0
    fi
  done
  # Also check config file
  local config_file="${HOME}/.config/tau/config.json"
  if [ -f "$config_file" ] && grep -q '"api_key"' "$config_file" 2>/dev/null; then
    has_key=true
    [ "$SMOKE_DEBUG" = "1" ] && diag "found API key in $config_file"
    return 0
  fi
  diag "no API key found"
  return 1
}

# setup_temp: create a temporary directory and register cleanup
# Usage: setup_temp; TEMP_DIR="$SMOKE_TEMP"
SMOKE_TEMP=""
SMOKE_TEMP_FILES=()
SMOKE_TEMP_DIRS=()

setup_temp() {
  if [ -z "$SMOKE_TEMP" ]; then
    SMOKE_TEMP="$(mktemp -d "${TMPDIR:-/tmp}/tau-smoke-XXXXXX")"
    SMOKE_TEMP_DIRS+=("$SMOKE_TEMP")
    diag "created temp dir: $SMOKE_TEMP"
  fi
}

# register_temp_file <file>
register_temp_file() {
  SMOKE_TEMP_FILES+=("$1")
}

# register_temp_dir <dir>
register_temp_dir() {
  SMOKE_TEMP_DIRS+=("$1")
}

# cleanup_temp: remove all registered temp files/dirs
cleanup_temp() {
  local f
  for f in "${SMOKE_TEMP_FILES[@]}"; do
    [ -f "$f" ] && rm -f "$f"
  done
  local d
  for d in "${SMOKE_TEMP_DIRS[@]}"; do
    [ -d "$d" ] && rm -rf "$d"
  done
  SMOKE_TEMP_FILES=()
  SMOKE_TEMP_DIRS=()
}

# cleanup_sessions <pattern>: remove session files matching pattern
cleanup_sessions() {
  local pattern="${1:-smoke-*}"
  local sess_dir="${HOME}/.config/tau/sessions"
  if [ -d "$sess_dir" ]; then
    local count=0
    for f in "$sess_dir"/${pattern}.json; do
      [ -f "$f" ] && rm -f "$f" && count=$((count + 1))
    done
    [ "$count" -gt 0 ] && diag "cleaned $count session files matching '$pattern'"
  fi
}

# cleanup_fleets <pattern>
cleanup_fleets() {
  local pattern="${1:-smoke-*}"
  local fleet_dir="${HOME}/.config/tau/fleets"
  if [ -d "$fleet_dir" ]; then
    local count=0
    for f in "$fleet_dir"/${pattern}.json; do
      [ -f "$f" ] && rm -f "$f" && count=$((count + 1))
    done
    [ "$count" -gt 0 ] && diag "cleaned $count fleet files matching '$pattern'"
  fi
}

# ── Debug output capture ──────────────────────────────────────────────────

# capture: run a command and capture stdout, stderr, exit code
# Usage: capture <var_prefix> <command...>
# Sets ${prefix}_out, ${prefix}_err, ${prefix}_rc
capture() {
  local prefix="$1"
  shift
  local tmp_out tmp_err
  tmp_out="$(mktemp)"
  tmp_err="$(mktemp)"
  register_temp_file "$tmp_out" "$tmp_err"

  local old_opts; old_opts="$(set +o)"
  set +e
  "$@" >"$tmp_out" 2>"$tmp_err"
  local rc=$?
  eval "$old_opts"

  # Use printf -v instead of eval to safely handle output containing quotes/braces
  local _content
  _content=$(cat "$tmp_out")
  printf -v "${prefix}_out" '%s' "$_content"
  _content=$(cat "$tmp_err")
  printf -v "${prefix}_err" '%s' "$_content"
  printf -v "${prefix}_rc" '%d' "$rc"

  if [ "$SMOKE_DEBUG" = "1" ]; then
    diag "capture: $*"
    diag "  exit code: $rc"
    if [ -s "$tmp_err" ]; then
      diag "  stderr: $(cat "$tmp_err" | head -c 500)"
    fi
  fi
}

# ── Benchmark integration ─────────────────────────────────────────────────

# run_benchmarks: invoke benchmark-resources.sh and capture output
run_benchmarks() {
  local bench_script="${SCRIPT_DIR}/benchmark-resources.sh"
  if [ ! -x "$bench_script" ]; then
    diag "benchmark script not found: $bench_script"
    return 1
  fi

  note "benchmark results"
  echo "# operation,max_rss_kb,cpu_user_sec,cpu_sys_sec,wall_sec"
  if [ "$SMOKE_DEBUG" = "1" ]; then
    diag "running benchmarks..."
  fi
  bash "$bench_script" 2>&1 | while IFS= read -r line; do
    echo "# $line"
  done
}

# ── Test group helpers ────────────────────────────────────────────────────

# run_test_group <name> <function>
# Invokes the function if it matches the current filter (SMOKE_GROUPS).
# SMOKE_GROUPS can be a comma-separated list of group names to run.
# Global registry: ALL_TEST_GROUPS entries are "name:function" strings.
# Populated by run_test_group; consumed by list_test_groups / --list-groups.
ALL_TEST_GROUPS=()

# _smoke_group_filter_matches <name>
# Returns 0 if no filter is set OR name is in SMOKE_GROUPS, 1 otherwise.
_smoke_group_filter_matches() {
  local group_name="$1"
  if [ -z "${SMOKE_GROUPS:-}" ]; then
    return 0
  fi
  local match=0
  local IFS=,
  # shellcheck disable=SC2086
  for g in $SMOKE_GROUPS; do
    if [ "$g" = "$group_name" ]; then
      match=1
      break
    fi
  done
  [ "$match" = "1" ]
}

# _smoke_split_entry <entry>
# Parses a "name:func[:marker]" entry string into two globals:
#   _smoke_entry_name   — group name
#   _smoke_entry_func   — test_group_* function name
# The optional marker (e.g. ":network") is NOT parsed here — callers that care
# about it should do their own inline `case "$entry" in *:network) ... esac`
# check, which is O(1) per entry via shell glob matching. Used by the dispatch
# loops in smoke.sh and by list_test_groups below so the parsing logic lives
# in one place.
_smoke_split_entry() {
  local entry="$1"
  _smoke_entry_name="${entry%%:*}"
  local rest="${entry#*:}"
  _smoke_entry_func="${rest%%:*}"
}

run_test_group() {
  local group_name="$1"
  local group_func="$2"

  # If SMOKE_GROUPS is set, only run matching groups
  if ! _smoke_group_filter_matches "$group_name"; then
    diag "skipping group '$group_name' (not in SMOKE_GROUPS)"
    return
  fi

  note "$group_name"
  $group_func
}

# list_test_groups: print all registered test groups (respects SMOKE_GROUPS filter)
list_test_groups() {
  echo "Available test groups:"
  local entry
  for entry in "${ALL_TEST_GROUPS[@]}"; do
    _smoke_split_entry "$entry"
    if ! _smoke_group_filter_matches "$_smoke_entry_name"; then
      continue
    fi
    printf '  %-25s %s\n' "$_smoke_entry_name" "$_smoke_entry_func"
  done
  if [ -n "${SMOKE_GROUPS:-}" ]; then
    echo
    echo "Filter active: $SMOKE_GROUPS (only matching groups will run)"
  else
    echo
    echo "No filter; use --group <name1,name2> to run a subset."
  fi
}

# ── Final summary ─────────────────────────────────────────────────────────

# print_summary: print pass/fail/skip counts
print_summary() {
  echo
  echo "# summary: $pass passed, $fail failed, $skip skipped"
  [ "$fail" -eq 0 ]
}

# ── EOF ───────────────────────────────────────────────────────────────────
