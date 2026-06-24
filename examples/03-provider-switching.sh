#!/usr/bin/env bash
# tau example: provider and model switching
#
# tau ships with four providers out of the box:
#   xiaomi      (default)  mimo-v2.5          256 K context
#   openai                 gpt-4o-mini        128 K context
#   deepseek               deepseek-chat       65 K context
#   opencode-go            deepseek-v4-flash  204 K context
#
# You can switch providers per-call with --provider or --model provider/id.
# A ~/.config/tau/config.json sets a persistent default.
# The --api-key flag (or env vars) supplies credentials.
#
# Prerequisites:
#   - tau binary on PATH (or set TAU_BIN=/path/to/tau)
#   - At least one API key set in the environment:
#       XIAOMI_API_KEY / PIZIG_API_KEY   → xiaomi provider
#       OPENAI_API_KEY                   → openai provider
#       DEEPSEEK_API_KEY                 → deepseek provider
#       OPENCODE_API_KEY                 → opencode-go provider
#       TAU_API_KEY                      → any provider (fallback)
#
# Run:
#   bash examples/03-provider-switching.sh

set -euo pipefail
TAU="${TAU_BIN:-tau}"

# ── helpers ──────────────────────────────────────────────────────────────────

section() { echo; echo "── $* ──"; }
answer() { command -v jq &>/dev/null && jq -r '.content' <<< "$1" || echo "$1"; }

has_key() {
  local var="$1"
  [ -n "${!var:-}" ]
}

PROMPT="What is 2 + 2? Reply with just the number."

# ── 1. Default provider (xiaomi) ─────────────────────────────────────────────
section "1. Default provider (xiaomi / mimo-v2.5)"

# With no --provider flag, tau uses the xiaomi provider.
# Set XIAOMI_API_KEY or PIZIG_API_KEY in your environment.
if has_key XIAOMI_API_KEY || has_key PIZIG_API_KEY; then
  OUT=$("$TAU" --no-tools --no-stream --mode text "$PROMPT")
  echo "xiaomi answer: $OUT"
else
  echo "SKIP: XIAOMI_API_KEY / PIZIG_API_KEY not set."
fi

# ── 2. OpenAI provider ───────────────────────────────────────────────────────
section "2. OpenAI (gpt-4o-mini)"

# --provider openai  selects the provider; the default model is gpt-4o-mini.
if has_key OPENAI_API_KEY; then
  OUT=$("$TAU" --provider openai --no-tools --no-stream --mode text "$PROMPT")
  echo "openai answer: $OUT"
else
  echo "SKIP: OPENAI_API_KEY not set."
fi

# ── 3. DeepSeek provider ─────────────────────────────────────────────────────
section "3. DeepSeek (deepseek-chat)"

if has_key DEEPSEEK_API_KEY; then
  OUT=$("$TAU" --provider deepseek --no-tools --no-stream --mode text "$PROMPT")
  echo "deepseek answer: $OUT"
else
  echo "SKIP: DEEPSEEK_API_KEY not set."
fi

# ── 4. Provider/model shorthand ──────────────────────────────────────────────
section "4. --model shorthand: provider/model-id in one flag"

# --model openai/gpt-4o sets both provider and model ID simultaneously.
# This is handy for one-off overrides without --provider and --model separately.
if has_key OPENAI_API_KEY; then
  OUT=$("$TAU" --model openai/gpt-4o --no-tools --no-stream --mode text "$PROMPT")
  echo "openai/gpt-4o answer: $OUT"
else
  echo "SKIP: OPENAI_API_KEY not set."
fi

# ── 5. Per-call --api-key ────────────────────────────────────────────────────
section "5. Supply an API key inline (per-call)"

# --api-key takes precedence over all env vars and config file keys.
# Useful in CI where the key is injected as a secret for a single call.
if has_key OPENAI_API_KEY; then
  OUT=$("$TAU" --provider openai --api-key "${OPENAI_API_KEY}" \
    --no-tools --no-stream --mode text "$PROMPT")
  echo "explicit key answer: $OUT"
else
  echo "SKIP: OPENAI_API_KEY not set."
fi

# ── 6. Config file default provider ──────────────────────────────────────────
section "6. Persistent config: set a default provider"

# ~/.config/tau/config.json overrides built-in defaults.
# CLI flags always beat the config file.
cat <<'EOF'
To make openai your permanent default, write:

  mkdir -p ~/.config/tau
  cat > ~/.config/tau/config.json <<JSON
  {
    "provider": "openai",
    "model": "gpt-4o-mini",
    "mode": "json"
  }
  JSON

Per-provider keys can also live in config so you don't need env vars at all:

  {
    "provider": "openai",
    "keys": {
      "openai":    "sk-...",
      "deepseek":  "sk-...",
      "xiaomi":    "..."
    }
  }

Key resolution order (highest → lowest):
  1. --api-key flag
  2. config keys[provider]
  3. provider env var  (OPENAI_API_KEY, DEEPSEEK_API_KEY, …)
  4. config api_key    (global fallback in config file)
  5. TAU_API_KEY       (universal env fallback)
EOF

# ── 7. Side-by-side comparison ───────────────────────────────────────────────
section "7. Side-by-side: same prompt, two providers"

COMPARE_PROMPT="Name one strength and one weakness of Python in under 15 words."

run_provider() {
  local name="$1" key_var="$2"
  shift 2
  if has_key "$key_var"; then
    local out
    out=$("$TAU" "$@" --no-tools --no-stream --mode text "$COMPARE_PROMPT" 2>/dev/null) \
      && echo "[$name] $out" \
      || echo "[$name] error"
  else
    echo "[$name] SKIP (${key_var} not set)"
  fi
}

# Run both in the background so they're fetched in parallel.
run_provider "xiaomi"  "XIAOMI_API_KEY" &
run_provider "openai"  "OPENAI_API_KEY" --provider openai &
wait

echo
echo "Done. Both responses printed above (order may vary due to parallel fetch)."

# ── 8. Temperature and max-tokens tuning ─────────────────────────────────────
section "8. Tune temperature and max-tokens per provider"

# Different providers may behave differently at the same temperature.
# --temperature 0.0  → deterministic / factual
# --temperature 1.0  → creative / varied
# --max-tokens       → hard cap on response length
if has_key OPENAI_API_KEY || has_key XIAOMI_API_KEY || has_key DEEPSEEK_API_KEY; then
  PROV="${OPENAI_API_KEY:+openai}${XIAOMI_API_KEY:+xiaomi}${DEEPSEEK_API_KEY:+deepseek}"
  PROV="${PROV%% *}"   # take first match

  echo "Provider: $PROV"
  "$TAU" --provider "$PROV" --temperature 0.2 --max-tokens 60 \
    --no-tools --no-stream --mode text \
    "List three use cases for a JSON-first CLI tool. Be brief."
else
  echo "SKIP: no API key set."
fi
