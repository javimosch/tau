#!/usr/bin/env bash
# Resource usage benchmark for tau.
# Measures RAM (RSS) and CPU time for various operations.
#
# Usage:
#   scripts/benchmark-resources.sh
#
# Outputs CSV to stdout for easy analysis.

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/zig-out/bin/tau"

if [ ! -x "$BIN" ]; then
  echo "building tau..."
  ( cd "$ROOT" && zig build ) || { echo "build failed"; exit 1; }
fi

echo "operation,max_rss_kb,cpu_user_sec,cpu_sys_sec,wall_sec"

# Helper: run a command and capture resource usage
benchmark() {
  local name="$1"
  local cmd="$2"
  local tmpfile

  tmpfile=$(mktemp)
  # Use /usr/bin/time to get resource metrics
  # Format: max RSS (KB), user CPU time, system CPU time, elapsed wall time
  /usr/bin/time -f "%M %U %S %e" bash -c "$cmd" > /dev/null 2> "$tmpfile"
  local metrics=$(cat "$tmpfile")
  rm -f "$tmpfile"

  local max_rss_kb=$(echo "$metrics" | awk '{print $1}')
  local cpu_user=$(echo "$metrics" | awk '{print $2}')
  local cpu_sys=$(echo "$metrics" | awk '{print $3}')
  local wall=$(echo "$metrics" | awk '{print $4}')

  echo "${name},${max_rss_kb},${cpu_user},${cpu_sys},${wall}"
}

# ── Test 1: Single-shot chat (no tools, no session) ────────────────────────
benchmark "single-shot" "$BIN --no-tools --no-stream -p 'Say hello in one word'"

# ── Test 2: Tool-calling (bash) ─────────────────────────────────────────────
benchmark "tool-bash" "$BIN --tools bash --no-stream -p 'Run: bash \"echo test\"'"

# ── Test 3: Session persistence (load + save) ───────────────────────────────
SESS="bench-session-$$"
SESS_FILE="$HOME/.config/tau/sessions/${SESS}.json"

# First turn (creates session)
benchmark "session-create" "$BIN --session $SESS --no-tools --no-stream -p 'My name is Alice'"

# Second turn (loads session, recalls, saves)
benchmark "session-recall" "$BIN --session $SESS --no-tools --no-stream -p 'What is my name?'"

rm -f "$SESS_FILE"

# ── Test 4: Idle startup (just --help, no API call) ─────────────────────────
benchmark "startup" "$BIN --help > /dev/null"
