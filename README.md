<p align="center">
  <img src="https://img.shields.io/badge/version-0.2.0-blue" alt="Version">
  <img src="https://img.shields.io/badge/license-MIT-green" alt="License">
  <img src="https://img.shields.io/badge/zig-0.16.0-orange" alt="Zig">
</p>

<h1 align="center">tau ⎯ Agent-First AI CLI</h1>

<p align="center">
  <b>Non-interactive Zig reimplementation of pi.</b><br>
  <b>Built for AI agents, not humans.</b>
</p>

> Think: "pi, but deterministic and JSON-first"

## ⚡ TL;DR

> Single-shot AI CLI with tool-calling, goal mode, and sessions — designed for agents.

```bash
# Single-shot chat (JSON by default)
tau "List the files in src/"

# Tool-calling loop (agents use this)
tau --tools bash,read "Use tools to analyze the codebase"

# Goal mode: autonomous work until complete
tau --session myproject "/goal add a --version flag and verify it builds"

# Check goal status
tau --session myproject "/goal status"
```

👉 JSON output by default — add `--mode text` for human-readable output
👉 Semantic exit codes — scripts and agents handle failures deterministically
👉 Sessions + goal mode — persistent state across invocations

## The Problem

AI agents need deterministic, predictable interfaces:
- **Interactive CLIs** → agents can't use TUIs or prompts
- **Inconsistent output** → parsing text responses is fragile
- **No state persistence** → every invocation starts from scratch
- **No autonomous workflows** → agents need humans to drive each step

Without tau, agents struggle to:
1. Execute single-shot commands reliably
2. Use tools in a loop with proper feedback
3. Maintain context across multiple invocations
4. Work autonomously toward complex objectives

## The Solution

tau gives agents what they need:
- **Non-interactive only** — no TUI, no prompts, no hidden retries
- **JSON by default** — deterministic structured output
- **Tool-calling loop** — agents can use bash, read, write, edit, ls, grep, find
- **Goal mode** — autonomous work until objective is complete
- **Sessions** — persistent conversation + goal state
- **Semantic exit codes** — `0` success, `80` invalid arg, `82` missing field, `105` timeout, `106` auth failed, `110` internal

With tau:
1. **Execute** single-shot commands with `tau "prompt"` — JSON output by default
2. **Use tools** with `--tools <csv>` — model calls tools, results fed back automatically
3. **Set goals** with `/goal <objective>` — agent works autonomously until complete
4. **Persist state** with `--session <name>` — resume conversations and goals later
5. **Compact context** automatically — LLM summarization when history grows too large

---

## ⚡ Quick Start

```bash
# Build
zig build
# Binary: zig-out/bin/tau

# Single-shot chat (JSON by default)
./zig-out/bin/tau "What is Zig?"

# Tool-calling (model uses tools automatically)
./zig-out/bin/tau --tools bash,read "Analyze the project structure"

# Goal mode: autonomous work
./zig-out/bin/tau --session work "/goal refactor the config module"

# Check goal status
./zig-out/bin/tau --session work "/goal status"

# Human-readable output
./zig-out/bin/tau --mode text "Explain this error"

# Streaming (text mode only, no tools)
./zig-out/bin/tau --stream "Count to 10"
```

---

## For Humans

| Instead of... | You do... |
|--------------|-----------|
| Interactive pi sessions | `tau "prompt"` — single-shot, no TUI |
| Parsing text responses | JSON by default, `--mode text` for readable |
| Manual tool execution | `--tools <csv>` — model calls tools automatically |
| Starting from scratch every time | `--session <name>` — persistent conversation |

What this means day-to-day:
- **No interactive prompts** — just pass the prompt and get JSON back
- **No output parsing** — structured JSON every time
- **No manual tool loops** — the agent handles tool calling automatically
- **No context loss** — sessions persist conversation and goal state

> 💡 **Important**: tau is JSON-first by default. Add `--mode text` for human-readable output.

## For AI Agents

- 🔍 **Deterministic** — JSON output by default, semantic exit codes, no hidden behavior
- 🛠️ **Tool-calling** — Built-in tools: bash, read, write, edit, ls, grep, find
- 🎯 **Goal mode** — `/goal <objective>` → autonomous work until complete
- 💾 **Sessions** — `--session <name>` → persistent conversation + goal state
- 🧠 **Context compaction** — Auto-summarization when history exceeds threshold
- 🚨 **Predictable errors** — Standard exit codes: `80` invalid arg, `82` missing field, `105` timeout, `106` auth failed, `110` internal
- 📡 **Streaming** — Real SSE token-by-token streaming (chat mode only)

```bash
# Agent workflow: single-shot → tools → goal → session
tau "prompt"                    # JSON response
tau --tools bash,read "task"    # Tool-calling loop
tau --session s "/goal obj"     # Goal mode with persistence
tau --session s "/goal status"  # Check progress
```

---

## What You Get

tau gives agents a deterministic, non-interactive AI CLI:

- 🎯 **Single-shot only** — No TUI, no prompts, no interactive mode
- 📦 **JSON by default** — Structured output for scripts and agents
- 🛠️ **Tool-calling loop** — 7 built-in tools with automatic execution
- 🎯 **Goal mode** — Autonomous work until objective is complete
- 💾 **Sessions** — Persistent conversation + goal state across invocations
- 🧠 **Context compaction** — LLM summarization at configurable threshold
- 🚨 **Semantic exit codes** — Deterministic error handling
- 📡 **Streaming** — Real SSE token-by-token output

---

## 🛠️ CLI Usage Examples

```bash
# Single-shot chat (JSON by default)
tau "What is Zig?"
tau --model openai/gpt-4o-mini "Explain this error"

# Tool-calling
tau --tools bash "Run: echo hello"
tau --tools read,write "Read file.txt and modify it"
tau --tools ls,grep "List src/ and search for TODO"

# Goal mode
tau --session project "/goal add tests for the config module"
tau --session project "/goal status"
tau --session project "/goal pause"
tau --session project "/goal resume"

# Sessions
tau --session work1 "Remember: the build uses zig 0.16"
tau --session work1 "What zig version?"

# Human-readable output
tau --mode text "Explain this in simple terms"

# Streaming (chat mode only)
tau --stream "Count to 10 slowly"
```

---

## 🏗️ Architecture

### Core Design

tau is a **non-interactive, agent-first** reimplementation of pi in Zig:

- **Single-shot only** — No interactive TUI, no REPL, no prompts
- **JSON-first** — Default output mode for machine consumption
- **Tool-calling loop** — Model calls tools, results fed back until final answer
- **Goal mode** — Autonomous work with `/goal <objective>` syntax
- **Sessions** — Persistent state in `~/.config/tau/sessions/<name>.json`
- **Context compaction** — LLM summarization at configurable threshold

### Tool System

Built-in tools (all JSON-schema'd for the model):

| Tool | Purpose |
|------|---------|
| `bash` | Execute shell commands |
| `read` | Read file contents |
| `write` | Write files |
| `edit` | Edit files (old_string → new_string) |
| `ls` | List directory contents |
| `grep` | Search files with regex |
| `find` | Find files by pattern |

Tools are allowlisted/denylisted via `--tools <csv>` / `--exclude-tools <csv>` / `--no-tools`.

### Goal Mode

Goal mode enables autonomous work:

```bash
tau --session myproject "/goal add a --version flag and verify it builds"
```

- Model works in a tool-calling loop until it outputs `<GOAL_MET>`
- Bounded by `--goal-max-iterations` (default: 50)
- Goal state persists in sessions
- Subcommands: `/goal status`, `/goal pause`, `/goal resume`, `/goal clear`, `/goal complete`

### Sessions

Sessions persist conversation + goal state:

```bash
tau --session work1 "Remember: the build uses zig 0.16"
tau --session work1 "What zig version?"  # Recalls from history
```

- Stored in `~/.config/tau/sessions/<name>.json`
- Includes full message history + goal state
- Supports goal mode across invocations

### Context Compaction

Auto-compact when history grows too large:

- Trigger: estimated tokens > `--compact-threshold` (default: 0.5) of context window
- Action: LLM summarizes older history, keeps recent tail verbatim
- Configurable via `--compact-threshold`, `--compact-keep-recent`, `--no-compact`

---

## 📤 Output Envelope + Exit Codes

### Output Modes

| Mode | Command | Output |
|------|---------|--------|
| **json** (default) | `tau "prompt"` | `{"version","model","content","done":true}` |
| **text** | `tau --mode text "prompt"` | Plain text on stdout |
| **stream** | `tau --stream "prompt"` | SSE token-by-token (chat mode only) |

Streaming output:
- Text mode: raw token deltas
- JSON mode: NDJSON `{"chunk":..,"done":false}` → final `{"model":..,"done":true}`

### Exit Codes

| Code | Meaning |
|------|---------|
| `0` | Success |
| `80` | Invalid argument |
| `82` | Missing required field |
| `105` | Connection timeout |
| `106` | Auth failed |
| `110` | Internal error |
| `111` | Unimplemented |

---

## ⚙️ Configuration

### Config File

Optional config at `~/.config/tau/config.json`:

```json
{
  "provider": "openai",
  "model": "gpt-4o-mini",
  "mode": "json",
  "stream": true,
  "auto_compact": true,
  "compact_threshold": 0.5
}
```

CLI flags override config file values.

### Providers

| Provider | Endpoint | Env var(s) | Default model |
|----------|----------|------------|---------------|
| `xiaomi` (default) | `…xiaomimimo.com/v1/chat/completions` | `TAU_API_KEY`, `XIAOMI_API_KEY` | `mimo-v2.5` |
| `openai` | `api.openai.com/v1/chat/completions` | `OPENAI_API_KEY` | `gpt-4o-mini` |
| `deepseek` | `api.deepseek.com/v1/chat/completions` | `DEEPSEEK_API_KEY` | `deepseek-chat` |

Key resolution: `--api-key` → provider env var → provider builtin key.

---

## 📦 Build & Install

```bash
# Build
zig build
# Binary: zig-out/bin/tau

# Run tests
zig build test

# Smoke tests (offline)
./scripts/smoke.sh

# Smoke tests (with network, requires API key)
./scripts/smoke.sh --net
```

Requires Zig 0.16.0 and `curl` on PATH.

---

## 🔧 Troubleshooting

| Symptom | Likely Cause | Fix |
|---------|--------------|-----|
| Empty response with no args | Expected behavior (shows help) | Use `tau --help` or provide a prompt |
| Auth failed (exit 106) | No API key | Set `TAU_API_KEY` or provider-specific env var |
| Timeout (exit 105) | Request too slow | Increase `--timeout-ms` (default: 120000) |
| Tool not found | Tool name mismatch | Check tool name in tool_calls |

---

## 🧱 Tech Stack

| Layer | Technology |
|-------|-----------|
| Runtime | Zig 0.16.0 |
| HTTP | `curl` via `std.process.run` |
| JSON | Custom escape/unescape + field extraction |
| Tools | Built-in: bash, read, write, edit, ls, grep, find |
| Storage | `~/.config/tau/config.json`, `~/.config/tau/sessions/` |
| Output | JSON by default, text mode available |
| Exit codes | Semantic (Square-style) |

---

## ⚡ Performance

tau is designed to be lightweight — Zig's zero-overhead and compiled binary nature result in minimal resource usage compared to Node.js-based agents.

### Resource Usage (measured on Linux)

| Operation | Max RSS | User CPU | Sys CPU | Wall Time |
|-----------|---------|----------|---------|-----------|
| Single-shot chat | ~13.3 MB | 0.04s | 0.00s | 2.6s |
| Tool-calling (bash) | ~13.6 MB | 0.09s | 0.01s | 4.0s |
| Session create | ~13.5 MB | 0.04s | 0.00s | 4.9s |
| Session recall | ~13.6 MB | 0.04s | 0.01s | 3.8s |
| Startup (--help) | ~4.6 MB | 0.00s | 0.00s | <0.01s |

*Measured with `/usr/bin/time` on x86_64 Linux, xiaomi mimo-v2.5 model. Wall time includes network latency.*

### Comparison to Other Agent CLIs

| CLI | Runtime | Typical RSS | Notes |
|-----|---------|-------------|-------|
| **tau** | Zig (compiled) | ~13 MB | Zero-overhead, single binary |
| pi | Python | ~50-100 MB | Python runtime overhead |
| opencode | Node.js | ~100-200 MB | V8 + TypeScript runtime |
| devin | Node.js | ~100-200 MB | Electron/V8 overhead |

**Why tau is lighter:**
- **No runtime VM** — Zig compiles to native machine code
- **Single binary** — No node_modules, no virtualenv, no runtime dependencies
- **Minimal memory footprint** — ~13 MB vs 50-200 MB for interpreted runtimes
- **Fast startup** — ~4.6 MB RSS at idle, instant CLI help

### Benchmarking

Run the resource benchmark script:

```bash
./scripts/benchmark-resources.sh
```

Outputs CSV with max RSS (KB), user CPU time, system CPU time, and wall time for each operation.

---

Run the resource benchmark script:

```bash
./scripts/benchmark-resources.sh
```

Outputs CSV with max RSS (KB), user CPU time, system CPU time, and wall time for each operation.

---

## 🌐 Status

| Capability | State |
|------------|-------|
| CLI argument parsing | ✅ done |
| Provider abstraction (xiaomi / openai / deepseek) | ✅ done |
| Output modes `text` / `json` | ✅ done |
| Streaming (`--stream`, real SSE token-by-token) | ✅ done |
| `@file` inclusion, system prompt | ✅ done |
| Proper JSON request escaping + response decoding | ✅ done |
| Semantic exit codes | ✅ done |
| Built-in tools (read/write/edit/bash/ls/grep/find) | ✅ done |
| **Tool-calling loop** (schemas sent + tool execution) | ✅ done |
| Config file (`~/.config/tau/config.json`) | ✅ done |
| Session persistence (`--session <name>`) | ✅ done |
| Goal mode (`/goal` + status/pause/resume/clear/complete) | ✅ done |
| Auto context compaction (LLM summarization at threshold) | ✅ done |

---

## License

MIT — <a href="https://www.linkedin.com/in/arancibiajav/" target="_blank">Javier Leandro Arancibia</a>
