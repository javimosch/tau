#!/usr/bin/env bash
# e2e-first-run.sh — clean-environment first-run e2e.
#
# Drives the documented first-run path against an already-installed tau
# binary in a scratch HOME with every credential source scrubbed. CI invokes
# this after installing the just-built binary through install.sh (POSIX legs)
# so the whole install → onboard → verify chain is exercised end to end.
#
#   1. tau setup --yes --offline        unattended onboarding. --offline keeps
#                                       the run hermetic (no live endpoint
#                                       check); a fake key stands in for a
#                                       user who already exported one — the
#                                       api_key check only tests resolution.
#   2. tau doctor --offline --selftest  fully credential-free (all keys
#                                       scrubbed): asserts the selftest check
#                                       row reports "ok" — the feature's
#                                       promise. The overall verdict exits
#                                       non-zero here because api_key fails
#                                       honestly, so the assertion is on the
#                                       check row, not the exit code.
#   3. tau doctor --offline --selftest  with the fake key resolvable: the whole
#                                       report must go green (exit 0).
#
# Usage: scripts/e2e-first-run.sh <path-to-tau> [scratch-home]
#   <path-to-tau>   installed tau binary to exercise
#   [scratch-home]  clean HOME to use (default: mktemp -d)
set -euo pipefail

TAU="${1:?usage: e2e-first-run.sh <path-to-tau> [scratch-home]}"
FH="${2:-$(mktemp -d)}"
mkdir -p "$FH"

KEYVARS="XIAOMI_API_KEY PIZIG_API_KEY OPENAI_API_KEY DEEPSEEK_API_KEY OPENCODE_API_KEY TAU_API_KEY"
scrub_env() {
  local args=() k
  for k in $KEYVARS; do args+=(-u "$k"); done
  env "${args[@]}" "$@"
}

fail() {
  echo "e2e-first-run: FAIL — $*" >&2
  exit 1
}

echo "e2e-first-run: home=$FH bin=$TAU"

# ── 1. Unattended onboarding ────────────────────────────────────────────────
scrub_env XIAOMI_API_KEY=fake-ci HOME="$FH" "$TAU" setup --yes --offline >"$FH/setup.ndjson" \
  || fail "tau setup --yes --offline exited $?"

[ -f "$FH/.config/tau/config.json" ] \
  || fail "setup did not scaffold $FH/.config/tau/config.json"

verdict="$(tail -n 1 "$FH/setup.ndjson")"
printf '%s' "$verdict" | grep -q '"step":"setup"'          || fail "setup verdict line missing: $verdict"
printf '%s' "$verdict" | grep -q '"ok":true'               || fail "setup verdict not ok: $verdict"
printf '%s' "$verdict" | grep -q '"yes":true'              || fail "setup verdict missing yes:true: $verdict"
printf '%s' "$verdict" | grep -q '"non_interactive":true'  || fail "setup verdict missing non_interactive:true: $verdict"
echo "e2e-first-run: setup --yes --offline ok (config scaffolded, verdict ok)"

# ── 2. Credential-free selftest ─────────────────────────────────────────────
set +e
scrub_env HOME="$FH" "$TAU" doctor --offline --selftest >"$FH/doctor-keyless.json" 2>"$FH/doctor-keyless.err"
rc=$?
set -e
grep -q '"name":"selftest","status":"ok"' "$FH/doctor-keyless.json" || {
  echo "e2e-first-run: doctor-keyless exit=$rc" >&2
  cat "$FH/doctor-keyless.json" "$FH/doctor-keyless.err" >&2
  fail "keyless selftest check did not report ok"
}
echo "e2e-first-run: credential-free doctor --selftest reports ok (verdict exit=$rc, expected non-zero with no key)"

# ── 3. Green report with a resolvable key ───────────────────────────────────
scrub_env XIAOMI_API_KEY=fake-ci HOME="$FH" "$TAU" doctor --offline --selftest >"$FH/doctor-keyed.json" \
  || fail "keyed tau doctor --offline --selftest exited $?"
echo "e2e-first-run: keyed doctor --selftest verdict ok"

echo "e2e-first-run: PASS"
