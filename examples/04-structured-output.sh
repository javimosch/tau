#!/usr/bin/env bash
# tau example: structured output with --schema
#
# --schema <json|@file> constrains the model's reply to a JSON document
# matching a JSON Schema (sent to the provider as response_format). The
# result still arrives in the usual envelope — .content holds the JSON
# document as a string, so you can pipe it straight into jq or a parser.
#
# This is the reliable way to get machine-readable answers out of a model
# instead of parsing prose.
#
# Prerequisites:
#   - tau binary on PATH (or set TAU_BIN=/path/to/tau)
#   - API key in env: TAU_API_KEY, XIAOMI_API_KEY, OPENAI_API_KEY, etc.
#
# Run:
#   bash examples/04-structured-output.sh

set -euo pipefail
TAU="${TAU_BIN:-tau}"

# ── helpers ──────────────────────────────────────────────────────────────────

section() { echo; echo "── $* ──"; }

has_key() { [ -n "${!1:-}" ]; }

any_key() {
  has_key TAU_API_KEY || has_key XIAOMI_API_KEY || has_key PIZIG_API_KEY || \
    has_key OPENAI_API_KEY || has_key DEEPSEEK_API_KEY || has_key OPENCODE_API_KEY
}

if ! any_key; then
  echo "SKIP: no provider API key set (need TAU_API_KEY, XIAOMI_API_KEY,"
  echo "      OPENAI_API_KEY, DEEPSEEK_API_KEY, or OPENCODE_API_KEY)."
  exit 0
fi

# The schema used throughout: an object with an "employees" array.
SCHEMA='{
  "type": "object",
  "properties": {
    "employees": {
      "type": "array",
      "items": {
        "type": "object",
        "properties": {
          "name":       { "type": "string" },
          "department": { "type": "string" },
          "salary":     { "type": "integer" }
        },
        "required": ["name", "department", "salary"]
      }
    }
  },
  "required": ["employees"]
}'

PROMPT="List 3 employees as a JSON object with their name, department, and salary."

# ── 1. Inline --schema: .content is guaranteed-parseable JSON ────────────────
section "1. Inline --schema — .content is a JSON document"

# --mode json (default) wraps the reply in the standard envelope; the
# model's schema-conforming document is the .content string.
OUT=$("$TAU" --no-tools --no-stream --mode json \
  --schema "$SCHEMA" "$PROMPT")

echo "Raw envelope:"
echo "$OUT"

# ── 2. Decode .content with jq ───────────────────────────────────────────────
section "2. Decode .content — jq treats it as real JSON"

if command -v jq &>/dev/null; then
  echo "$OUT" | jq -r '.content' | jq '.'
  echo
  echo "Engineering employees only:"
  echo "$OUT" | jq -r '.content' | jq -r '.employees[] | select(.department == "Engineering") | .name'
else
  echo "(jq not installed — .content is still a JSON string you can parse"
  echo " in any language: python3 -c 'import json,sys; print(json.loads(json.load(sys.stdin)[\"content\"]))')"
fi

# ── 3. --mode text: raw JSON on stdout, no envelope ──────────────────────────
section "3. --mode text — stdout IS the JSON document"

# With --mode text there is no envelope at all, so the pipe is even shorter.
if command -v jq &>/dev/null; then
  "$TAU" --no-tools --no-stream --mode text \
    --schema "$SCHEMA" "$PROMPT" | jq -c '.employees'
else
  "$TAU" --no-tools --no-stream --mode text \
    --schema "$SCHEMA" "$PROMPT"
fi

# ── 4. --schema @file: keep the schema in a file ─────────────────────────────
section "4. --schema @file — schema lives next to the script"

# Larger schemas are easier to review and reuse as files. @path reads the
# file contents at launch; a missing file exits 80 with an error envelope.
SCHEMA_FILE="$(mktemp)"
trap 'rm -f "$SCHEMA_FILE"' EXIT
printf '%s' "$SCHEMA" > "$SCHEMA_FILE"

echo "Schema file: $SCHEMA_FILE"
"$TAU" --no-tools --no-stream --mode text \
  --schema "@$SCHEMA_FILE" "$PROMPT"

# ── 5. Failure surface: a bad @file path ─────────────────────────────────────
section "5. Error handling — unreadable schema file exits 80"

rc=0
ERR_OUT=$("$TAU" --no-tools --no-stream \
  --schema "@/nonexistent/schema.json" "$PROMPT" 2>&1 >/dev/null) || rc=$?
if [ "$rc" -eq 0 ]; then
  echo "unexpected success"
else
  echo "exit code: $rc (80 = invalid argument)"
  echo "$ERR_OUT" | head -1
fi

# ── 6. Practical pipeline: feed structured data to the next stage ────────────
section "6. Compose it — JSON out of tau, into your pipeline"

# Because .content is real JSON, downstream steps need no regex scraping.
if command -v jq &>/dev/null; then
  AVG=$("$TAU" --no-tools --no-stream --mode text \
    --schema "$SCHEMA" "$PROMPT" | jq '[.employees[].salary] | add / length')
  echo "Average salary: $AVG"
fi

cat <<'EOF'

Caveats:
  - --schema relies on provider-side structured output (response_format).
    Providers that do not implement it may ignore the constraint or fail —
    test with your provider before depending on it in CI.
  - tau does not re-validate the reply against the schema locally; validate
    in your pipeline if the contract must be airtight.
  - --dry-run skips response_format on planning turns but honours --schema
    on the final turn.
EOF
