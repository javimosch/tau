#!/bin/sh
# scripts/fuzz.sh — bounded coverage-guided fuzz run over tau's input parsers.
#
# Harnesses live next to the code under test (each is a `std.testing.fuzz`
# unit test, so the seed corpus also runs under plain `zig build test`):
#
#   src/args.zig        — argv flag/positional/subcommand parsing
#   src/configfile.zig  — config.json loading (JSONC strip + typed parse)
#   src/configedit.zig  — `config set|get|unset` document splices/coercion
#   src/acp.zig         — newline-delimited JSON-RPC frame handling
#
# Usage: scripts/fuzz.sh [LIMIT]
#   LIMIT is the per-target run budget (default 10000; K/M/G suffixes ok).
#   `zig build test --fuzz` (no limit) runs forever — wrap it in `timeout`.
#
# Constraints (Zig 0.16):
#   * --fuzz requires a POSIX 64-bit host (not implemented on Windows).
#   * The fuzz-mode rebuild of the 0.16.0 test runner trips a stdlib type
#     bug in Debug mode, so the fuzz binary is compiled ReleaseSafe.
#   * ZIG env var overrides the zig binary (CI passes an absolute path).
set -eu
cd "$(dirname "$0")/.."

ZIG_BIN="${ZIG:-zig}"
exec "$ZIG_BIN" build test "--fuzz=${1:-10000}" -Doptimize=ReleaseSafe
