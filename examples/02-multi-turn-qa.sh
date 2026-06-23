#!/usr/bin/env bash
# tau example: multi-turn Q&A with sessions
#
# tau is non-interactive by default — each invocation is a single shot.
# The --session flag persists conversation history to
#   ~/.config/tau/sessions/<name>.json
# so you can have a real back-and-forth by re-using the same session name.
#
# Prerequisites:
#   - tau binary on PATH (or set TAU_BIN=/path/to/tau)
#   - API key in env: TAU_API_KEY, XIAOMI_API_KEY, OPENAI_API_KEY, etc.
#
# Run:
#   bash examples/02-multi-turn-qa.sh

set -euo pipefail
TAU="${TAU_BIN:-tau}"

# ── helpers ──────────────────────────────────────────────────────────────────

section() { echo; echo "── $* ──"; }
# Print .content from a JSON response (falls back to raw if jq missing).
answer() { command -v jq &>/dev/null && jq -r '.content' <<< "$1" || echo "$1"; }

# Use a unique session name so this example doesn't pollute existing sessions.
SESSION="tau-example-qa-$$"

# Clean up the session file when the script exits.
cleanup() { rm -f "$HOME/.config/tau/sessions/${SESSION}.json"; }
trap cleanup EXIT

# ── 1. First turn: establish context ─────────────────────────────────────────
section "Turn 1: establish context"

# --session persists this turn. --no-tools keeps it fast (no tool-calling loop).
# --mode text gives us plain prose instead of JSON.
echo "Sending turn 1 ..."
"$TAU" --session "$SESSION" --no-tools --mode text \
  "I'm building a REST API for a task manager. Users can create, update, and delete tasks.
Each task has: id (UUID), title (string), status (todo|in_progress|done), and due_date (ISO 8601).
Remember this schema — I'll ask questions about it."

# ── 2. Second turn: follow-up question ───────────────────────────────────────
section "Turn 2: follow-up question (model remembers the schema)"

echo "Sending turn 2 ..."
"$TAU" --session "$SESSION" --no-tools --mode text \
  "What HTTP status codes should I return when:
  a) a task is created successfully?
  b) a task ID is not found?
  c) the request body has a missing required field?"

# ── 3. Third turn: ask for code ───────────────────────────────────────────────
section "Turn 3: ask for a concrete implementation"

echo "Sending turn 3 ..."
"$TAU" --session "$SESSION" --no-tools --mode text \
  "Write a minimal Express.js route handler for POST /tasks that validates the schema
and returns the right status codes you just described. Keep it under 30 lines."

# ── 4. Inspect the session file ──────────────────────────────────────────────
section "Session file inspection"

SESS_FILE="$HOME/.config/tau/sessions/${SESSION}.json"
if [ -f "$SESS_FILE" ]; then
  MSG_COUNT=$(python3 -c "import json; d=json.load(open('$SESS_FILE')); print(len(d['messages']))")
  echo "Session saved to: $SESS_FILE"
  echo "Message count: $MSG_COUNT  (3 turns × 2 = 6 messages)"
else
  echo "Session file not found — check your tau version or HOME path."
fi

# ── 5. Goal mode: autonomous multi-step task ─────────────────────────────────
section "5. Goal mode — autonomous multi-turn work"

# /goal tells tau to keep calling tools and making model turns until the
# objective is complete. It emits <GOAL_MET> internally when done (stripped
# from output). The session records the whole trajectory.
GOAL_SESSION="tau-example-goal-$$"
GOAL_FILE="$(mktemp)"
trap 'rm -f "$GOAL_FILE"; rm -f "$HOME/.config/tau/sessions/${GOAL_SESSION}.json"' EXIT

echo "Launching goal mode: create and populate $GOAL_FILE ..."
"$TAU" --session "$GOAL_SESSION" --tools write,read --mode text \
  "/goal Write a file at $GOAL_FILE that contains a valid JSON array of 3 objects,
each with keys 'id' (1, 2, 3) and 'label' (string). Then read it back to confirm it is valid JSON."

echo "Goal output:"
cat "$GOAL_FILE" 2>/dev/null || echo "(file not found)"

# ── 6. Resume a paused goal ──────────────────────────────────────────────────
section "6. /goal status — inspect goal state"

# /goal status reads the session and returns the current goal without making
# a new LLM call. Useful for polling in CI pipelines or automation scripts.
DEMO_SESSION="tau-example-goal-demo-$$"
trap 'rm -f "$HOME/.config/tau/sessions/${DEMO_SESSION}.json"' EXIT

# Seed a goal ...
"$TAU" --session "$DEMO_SESSION" --no-tools --mode json \
  "/goal Write a README for a fictional project called Zap." > /dev/null

# ... then check its status.
STATUS=$("$TAU" --session "$DEMO_SESSION" --no-tools "/goal status")
echo "Goal status response:"
if command -v jq &>/dev/null; then
  echo "$STATUS" | jq '.'
else
  echo "$STATUS"
fi

# Other lifecycle commands (not run here to keep the demo fast):
#   tau --session my-project "/goal pause"    # suspend the goal
#   tau --session my-project "/goal resume"   # pick up where you left off
#   tau --session my-project "/goal clear"    # wipe goal state, keep history
