#!/bin/sh
# examples/quickstart/quickstart.sh — zero-config tour of tau.
#
# Runs three real tau invocations against a stub model server
# (stub/curl, a curl-compatible shim shadowed onto PATH). No API key,
# no config file, no network — everything below is the real binary doing
# real work; only the model responses are canned.
#
#   sh examples/quickstart/quickstart.sh
#
# TAU_BIN=/path/to/tau overrides which binary is exercised.
set -eu

DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$DIR/../.." && pwd)

# ── Resolve the tau binary ────────────────────────────────────────────────
if [ -n "${TAU_BIN:-}" ] && [ -x "$TAU_BIN" ]; then
  TAU=$TAU_BIN
elif [ -x "$ROOT/zig-out/bin/tau" ]; then
  TAU=$ROOT/zig-out/bin/tau
elif command -v tau >/dev/null 2>&1; then
  TAU=$(command -v tau)
elif command -v zig >/dev/null 2>&1; then
  echo "== No tau binary found — running 'zig build' first =="
  (cd "$ROOT" && zig build)
  TAU=$ROOT/zig-out/bin/tau
else
  echo "quickstart: no tau binary found." >&2
  echo "  Build one with 'zig build' in the repo root, or set TAU_BIN=/path/to/tau." >&2
  exit 1
fi

# ── Hermetic sandbox: scratch HOME + stub curl first on PATH ─────────────
WORK=$(mktemp -d "${TMPDIR:-/tmp}/tau-quickstart.XXXXXX")
trap 'rm -rf "$WORK"' EXIT INT TERM
HOME="$WORK/home"; export HOME
mkdir -p "$HOME"
PATH="$DIR/stub:$PATH"; export PATH
TAU_API_KEY="tau-quickstart-stub"; export TAU_API_KEY

say()  { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }
run()  { printf '$ %s\n' "$*"; "$@"; }

say "Step 1/3 — plain chat, default JSON stream (no tools, no credentials)"
run "$TAU" --no-tools "Say hello in one short sentence."

say "Step 2/3 — agentic tool loop (stub asks for read, tau executes it)"
run "$TAU" --mode text --tools read "Read examples/quickstart/hello.txt and tell me what it says."

say "Step 3/3 — tau as an ACP agent: JSON-RPC over stdio"
printf '$ printf <initialize+session/new+session/prompt> | %s acp serve\n' "$(basename "$TAU")"
# The trailing `| cat` keeps tau's stdout a pipe: `acp serve` uses a buffered
# writer that falls back to positional writes when fd 1 is a seekable file,
# which would clobber this script's earlier output under `sh quickstart.sh >log`.
{
  printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1,"clientCapabilities":{"fs":{"readTextFile":false,"writeTextFile":false}}}}'
  printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"session/new","params":{"cwd":"'"$ROOT"'"}}'
  printf '%s\n' '{"jsonrpc":"2.0","id":3,"method":"session/prompt","params":{"sessionId":"quickstart","prompt":[{"type":"text","text":"Say hello from ACP in one sentence."}]}}'
} | "$TAU" acp serve | cat

say "What just happened"
cat <<EOF
Every response above came from examples/quickstart/stub/curl — a stub model
server that answers tau's curl subprocess over stdout. The binary, request
envelopes, SSE parsing, tool dispatch, and ACP session handling were all real.

Ready for a live model? Export a key and rerun any step without the stub:

  export TAU_API_KEY="your-key"        # or OPENAI_API_KEY / DEEPSEEK_API_KEY / XIAOMI_API_KEY
  tau --mode text "Say hello"

Docs: README.md · docs/configuration.md · docs/acp.md · examples/README.md
EOF
