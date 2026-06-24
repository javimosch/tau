#!/usr/bin/env bash
# tau example: file editing workflows
#
# Demonstrates using tau's built-in file tools (read, write, edit) to inspect
# and modify files autonomously. tau runs a tool-calling loop — the model
# decides which tools to call and when to stop.
#
# Prerequisites:
#   - tau binary on PATH (or set TAU_BIN=/path/to/tau)
#   - API key in env: TAU_API_KEY, XIAOMI_API_KEY, OPENAI_API_KEY, etc.
#
# Run:
#   bash examples/01-file-editing.sh

set -euo pipefail
TAU="${TAU_BIN:-tau}"

# ── helpers ──────────────────────────────────────────────────────────────────

die() { echo "ERROR: $*" >&2; exit 1; }
section() { echo; echo "── $* ──"; }
# Extract .content from JSON response if jq is available, else print raw JSON.
content() { command -v jq &>/dev/null && jq -r '.content' <<< "$1" || echo "$1"; }

# ── 1. READ a file ───────────────────────────────────────────────────────────
section "1. Read a file"

# Create a sample file to work with.
SAMPLE="$(mktemp)"
trap 'rm -f "$SAMPLE"' EXIT
cat > "$SAMPLE" <<'EOF'
name = "acme-app"
version = "1.0.0"
debug = false
max_connections = 100
EOF

# tau reads the file and summarises it.
# --tools read   : allow only the read tool (no bash, no write)
# --mode text    : human-readable output instead of JSON
echo "Asking tau to summarise $SAMPLE ..."
"$TAU" --tools read --mode text \
  "Read $SAMPLE and list every key-value pair it contains."

# ── 2. WRITE a new file ──────────────────────────────────────────────────────
section "2. Write a new file"

TARGET="$(mktemp -u)"   # path that doesn't exist yet
echo "Asking tau to create $TARGET ..."
OUT=$("$TAU" --tools write \
  "Write a file to $TARGET. Contents must be exactly three lines:
line1: HELLO
line2: WORLD
line3: FROM_TAU")

content "$OUT"

# Verify the file was written.
if grep -q "FROM_TAU" "$TARGET" 2>/dev/null; then
  echo "Verified: file created successfully."
  rm -f "$TARGET"
else
  die "write tool did not produce $TARGET"
fi

# ── 3. EDIT an existing file ─────────────────────────────────────────────────
section "3. Edit an existing file (targeted replacement)"

EDIT_FILE="$(mktemp)"
cat > "$EDIT_FILE" <<'EOF'
# server config
host = "localhost"
port = 8080
log_level = "warn"
EOF
echo "Before edit:"; cat "$EDIT_FILE"; echo

# The edit tool does exact old→new string replacement — safer than regex sed.
# --tools edit : allow only the edit tool
OUT=$("$TAU" --tools edit \
  "Edit $EDIT_FILE: replace the line 'log_level = \"warn\"' with 'log_level = \"info\"'.")
content "$OUT"

echo "After edit:"; cat "$EDIT_FILE"
rm -f "$EDIT_FILE"

# ── 4. Multi-tool: READ then WRITE (refactor workflow) ───────────────────────
section "4. Read → transform → write (multi-tool)"

SRC="$(mktemp)"
DEST="$(mktemp -u)"
cat > "$SRC" <<'EOF'
function calculateTotal(items) {
  var sum = 0;
  for (var i = 0; i < items.length; i++) {
    sum = sum + items[i].price;
  }
  return sum;
}
EOF

echo "Asking tau to modernise the JS in $SRC and write result to $DEST ..."
"$TAU" --tools read,write --mode text \
  "Read $SRC, rewrite the function using modern JS (const, let, arrow functions, reduce),
then write the result to $DEST. Do not change the function name."

if [ -f "$DEST" ]; then
  echo "Output file:"; cat "$DEST"
  rm -f "$DEST"
fi
rm -f "$SRC"

# ── 5. Structured output (JSON mode) ─────────────────────────────────────────
section "5. Read a file, return structured JSON"

DATA_FILE="$(mktemp)"
cat > "$DATA_FILE" <<'EOF'
Alice, Engineering, 95000
Bob, Marketing, 78000
Carol, Engineering, 102000
EOF

echo "Parsing CSV → structured JSON ..."
RESULT=$("$TAU" --tools read --mode json \
  "Read $DATA_FILE. Parse it as CSV with columns: name, department, salary (integer).
Return a JSON object with key 'employees' containing an array of those objects.")
rm -f "$DATA_FILE"

# In JSON mode the model's answer is in the 'content' field.
if command -v jq &>/dev/null; then
  echo "$RESULT" | jq '.content | fromjson'
else
  echo "$RESULT"
fi
