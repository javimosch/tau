#!/usr/bin/env bash
# tau example: non-interactive CI usage
#
# A copy-pasteable pattern for running tau inside any CI system (GitHub
# Actions, GitLab CI, Jenkins, ...). The recipe:
#
#   --no-stream   single JSON object on stdout — no NDJSON parsing needed
#   --mode json   machine-parseable output (the default, stated for clarity)
#   --no-tools    deterministic and sandbox-safe: no shell or file access
#   --timeout-ms  bounded runtime so a stuck request fails the step
#   exit codes    mapped to actionable CI messages below
#
# Credentials: set exactly one provider key as a CI secret.
#   XIAOMI_API_KEY / PIZIG_API_KEY / OPENAI_API_KEY / DEEPSEEK_API_KEY /
#   OPENCODE_API_KEY / TAU_API_KEY   (TAU_API_KEY works for any provider)
#
# Run locally the same way CI does:
#   TAU_BIN=./zig-out/bin/tau bash examples/ci/run.sh

set -euo pipefail
TAU="${TAU_BIN:-tau}"
OUT_FILE="${TAU_OUT:-tau-output.md}"
ERR_FILE="$(mktemp)"
trap 'rm -f "$ERR_FILE"' EXIT

say()  { echo "[tau-ci] $*"; }
fail() { echo "::error:: $*" >&2; exit 1; }

# --- 1. Preflight: binary and credentials -----------------------------------
command -v "$TAU" >/dev/null 2>&1 || fail "tau not found — install it or set TAU_BIN=/path/to/tau"

have_key=0
for v in XIAOMI_API_KEY PIZIG_API_KEY OPENAI_API_KEY DEEPSEEK_API_KEY OPENCODE_API_KEY TAU_API_KEY; do
  if [ -n "${!v:-}" ]; then have_key=1; break; fi
done
[ "$have_key" = 1 ] || fail "no provider API key in env — set e.g. XIAOMI_API_KEY as a CI secret"

# --- 2. Build the prompt from CI context ------------------------------------
# Feed tau whatever your pipeline already has: a git log, a diff, a failing
# test log. Here: turn the 20 most recent commits into draft release notes.
CONTEXT="$(git log -20 --pretty='- %s' 2>/dev/null || true)"
[ -n "$CONTEXT" ] || CONTEXT="(no git history available)"

PROMPT="You are writing draft release notes. Group these commit messages under 'Added', 'Fixed', and 'Other' markdown headings, one bullet per line, no preamble:

$CONTEXT"

# --- 3. Run tau non-interactively -------------------------------------------
say "running tau (--no-stream --no-tools --timeout-ms 60000) ..."
set +e
RAW="$("$TAU" --no-stream --mode json --no-tools --timeout-ms 60000 "$PROMPT" 2>"$ERR_FILE")"
rc=$?
set -e

# --- 4. Map exit codes to CI-friendly failures -------------------------------
case "$rc" in
  0)   ;;
  80)  fail "invalid arguments (exit 80) — check the tau flags in this script" ;;
  82)  fail "missing required field (exit 82)" ;;
  105) fail "request timed out (exit 105) — retry or raise --timeout-ms" ;;
  106) fail "auth failed (exit 106) — check the API key secret. Note: tau exits 106 silently when no key is found" ;;
  111) fail "unimplemented (exit 111) — feature not supported by this tau build" ;;
  *)   fail "tau failed (exit $rc): $(cat "$ERR_FILE")" ;;
esac

# stderr can still carry {"warn":{...}} envelopes on success — surface them.
if [ -s "$ERR_FILE" ]; then
  say "stderr:"
  sed 's/^/  /' "$ERR_FILE" >&2
fi

# --- 5. Extract .content and publish it --------------------------------------
say "parsing JSON response ..."
if command -v python3 >/dev/null 2>&1; then
  CONTENT="$(printf '%s' "$RAW" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("content",""))')" \
    || fail "tau returned non-JSON output"
elif command -v jq >/dev/null 2>&1; then
  CONTENT="$(printf '%s' "$RAW" | jq -r '.content // ""')" || fail "tau returned non-JSON output"
else
  fail "need python3 or jq to parse tau's output"
fi

printf '%s\n' "$CONTENT" > "$OUT_FILE"
say "wrote $OUT_FILE ($(printf '%s' "$CONTENT" | wc -l) lines)"

# GitHub Actions: also surface the result in the job summary when available.
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  printf '%s\n' "$CONTENT" >> "$GITHUB_STEP_SUMMARY"
  say "appended to \$GITHUB_STEP_SUMMARY"
fi
