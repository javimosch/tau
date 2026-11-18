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
#   2. tau setup --client …             editor wiring for both config paths:
#                                       zed covers direct-ACP clients
#                                       (agent_servers.tau → tau acp serve),
#                                       claude-desktop covers MCP-bridge
#                                       clients (mcpServers.mcacp plus the
#                                       shared ~/.config/mcacp/mcacp.json).
#   3. tau doctor --offline --selftest  fully credential-free (all keys
#                                       scrubbed): asserts the selftest check
#                                       row reports "ok" — the feature's
#                                       promise. The overall verdict exits
#                                       non-zero here because api_key fails
#                                       honestly, so the assertion is on the
#                                       check row, not the exit code.
#   4. tau doctor --offline --selftest  with the fake key resolvable: the whole
#                                       report must go green (exit 0), and the
#                                       per-client wiring rows from step 2
#                                       must verify as ok.
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

# ── 2. Editor client wiring ──────────────────────────────────────────────────
# setup --client resolves every settings path relative to HOME — exercising
# this on every leg is what proves the wiring works with real platform paths
# (the Windows leg is the one that can't be faked by POSIX-only development).
scrub_env XIAOMI_API_KEY=fake-ci HOME="$FH" "$TAU" setup --yes --offline --client zed >"$FH/setup-zed.ndjson" \
  || fail "tau setup --yes --offline --client zed exited $?"

clients_step="$(grep '"step":"clients"' "$FH/setup-zed.ndjson" || true)"
printf '%s' "$clients_step" | grep -q '"status":"installed"' || fail "clients step not installed: $clients_step"
printf '%s' "$clients_step" | grep -q '"client":"zed"'       || fail "clients step missing zed entry: $clients_step"

zed_cfg="$FH/.config/zed/settings.json"
[ -f "$zed_cfg" ] || fail "setup --client zed did not write $zed_cfg"
for needle in '"agent_servers"' '"tau"' '"acp"' '"serve"' '"type": "custom"'; do
  grep -q "$needle" "$zed_cfg" || fail "zed settings missing $needle"
done
echo "e2e-first-run: setup --client zed ok (direct ACP entry installed)"

scrub_env XIAOMI_API_KEY=fake-ci HOME="$FH" "$TAU" setup --yes --offline --client claude-desktop >"$FH/setup-claude.ndjson" \
  || fail "tau setup --yes --offline --client claude-desktop exited $?"

clients_step="$(grep '"step":"clients"' "$FH/setup-claude.ndjson" || true)"
printf '%s' "$clients_step" | grep -q '"status":"installed"'      || fail "clients step not installed: $clients_step"
printf '%s' "$clients_step" | grep -q '"client":"claude-desktop"' || fail "clients step missing claude-desktop entry: $clients_step"

claude_cfg="$FH/.config/Claude/claude_desktop_config.json"
mcacp_cfg="$FH/.config/mcacp/mcacp.json"
[ -f "$claude_cfg" ] || fail "setup --client claude-desktop did not write $claude_cfg"
grep -q '"mcpServers"' "$claude_cfg" || fail "claude_desktop_config missing mcpServers"
grep -q '"mcacp"' "$claude_cfg"      || fail "claude_desktop_config missing mcacp entry"
[ -f "$mcacp_cfg" ] || fail "setup --client claude-desktop did not write $mcacp_cfg"
grep -q '"agent_servers"' "$mcacp_cfg" || fail "mcacp.json missing agent_servers"
grep -q '"tau"' "$mcacp_cfg"           || fail "mcacp.json missing tau entry"
echo "e2e-first-run: setup --client claude-desktop ok (MCP-bridge entry + mcacp.json installed)"

# ── 3. Credential-free selftest ─────────────────────────────────────────────
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

# ── 4. Green report with a resolvable key ───────────────────────────────────
scrub_env XIAOMI_API_KEY=fake-ci HOME="$FH" "$TAU" doctor --offline --selftest >"$FH/doctor-keyed.json" \
  || fail "keyed tau doctor --offline --selftest exited $?"
for needle in '"name":"client_zed","status":"ok"' '"name":"client_claude_desktop","status":"ok"'; do
  grep -q "$needle" "$FH/doctor-keyed.json" || {
    cat "$FH/doctor-keyed.json" >&2
    fail "keyed doctor report missing $needle"
  }
done
echo "e2e-first-run: keyed doctor --selftest verdict ok (client wiring verified)"

echo "e2e-first-run: PASS"
