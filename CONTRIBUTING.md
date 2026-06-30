# Contributing to tau

Thank you for contributing to tau. This document covers everything you need to go from a fresh checkout to an open PR.

---

## Prerequisites

| Requirement | Version | Notes |
|-------------|---------|-------|
| [Zig](https://ziglang.org/download/) | **0.16.0 exactly** | `zig version` must print `0.16.0` |
| `curl` | any recent | tau uses it for HTTP; must be on `PATH` |
| `git` | any recent | for cloning and branching |

> **Zig version is strict.** tau's `build.zig` targets 0.16.0 — other versions will fail to compile.

---

## Build from source

```bash
# 1. Clone
git clone https://github.com/javimosch/tau.git
cd tau

# 2. Compile
zig build                 # debug build (default)
zig build -Doptimize=ReleaseSafe   # optimized build

# 3. Binary lands at:
./zig-out/bin/tau --help
```

Put the binary on your `PATH` for convenience:

```bash
export PATH="$PWD/zig-out/bin:$PATH"
```

---

## Running tests

### Unit tests

```bash
zig build test
```

All tests live under `src/` and are auto-discovered via `src/main.zig`. A passing run prints the count and exits `0`. If any test crashes, the suite exits `1` and prints the failing test name.

**Known pre-existing issue:** `scanAgentsMd returns empty for bad path` in `src/agents_md.zig` was fixed in PR #55. If you see an ABRT for a *different* test name, that is a new failure and needs investigation.

### Smoke tests

Smoke tests exercise the compiled binary end-to-end:

```bash
# Offline CLI tests only (fast, no API key required)
./scripts/smoke.sh

# Also run real LLM calls (requires TAU_API_KEY or OPENAI_API_KEY)
./scripts/smoke.sh --net

# Run only specific test groups
./scripts/smoke.sh --group help,flags,role

# List all available test groups
./scripts/smoke.sh --list-groups
```

Useful environment variables for debugging smoke failures:

| Variable | Effect |
|----------|--------|
| `SMOKE_VERBOSE=1` | Print each test name as it runs |
| `SMOKE_DEBUG=1` | Verbose debug output |
| `TAU_BIN=/path/to/tau` | Override which binary is tested |

### Resource benchmark

```bash
./scripts/benchmark-resources.sh
```

Outputs CSV: max RSS, user CPU, sys CPU, and wall time per operation. Run this before and after performance-sensitive changes.

---

## Project layout

```
src/
  main.zig          # entry point and test root (all tests imported here)
  args.zig          # CLI flag parsing
  config.zig        # config resolution (file + env + flags)
  configfile.zig    # ~/.config/tau/config.json parsing
  agent.zig         # core agent/tool-calling loop
  acp.zig           # ACP server (JSON-RPC over stdio)
  providers/        # provider adapter modules
  tools/
    bash.zig        # bash tool
    read.zig  write.zig  edit.zig  ls.zig  grep.zig  find.zig
    registry.zig    # tool lookup and allowlist/denylist
  llm/
    provider.zig    # provider routing and HTTP serialization
build.zig           # Zig build script
scripts/            # smoke.sh, benchmark-resources.sh
completions/        # bash (tau.bash) and zsh (_tau) completion scripts
examples/           # annotated real-world workflow scripts
docs/               # changelog, roadmap, architecture notes
```

---

## PR workflow

### 1. Branch

Branch off `master` with a short, descriptive name:

```bash
git checkout master && git pull
git checkout -b feat/my-change       # new feature
git checkout -b fix/config-fallback  # bug fix
git checkout -b test/tools-bash      # tests only
git checkout -b docs/contributing    # docs only
```

### 2. Make your change

- **Match the existing style.** tau is Zig 0.16.0 throughout; follow the patterns in the file you're editing.
- **Keep PRs focused.** One logical change per PR makes review faster.
- **Add tests** for new logic. Unit tests go in the same file as the code they test, inside `test "..." { ... }` blocks. They are auto-discovered from `src/main.zig` — no registration needed.
- **Do not break existing tests.** `zig build test` must pass before you push.

### 3. Verify

```bash
zig build           # compiles clean
zig build test      # all tests pass
./scripts/smoke.sh  # offline smoke tests pass
```

### 4. Commit

Write commit messages in the imperative: `add`, `fix`, `test`, `docs`, not `added`, `fixed`.

```bash
git add <specific files>   # never `git add -A` — avoid bundling unrelated work
git commit -m "test: add unit tests for tools/bash.zig covering success, exit codes, stderr, timeout"
```

### 5. Push and open a PR

```bash
git push -u origin your-branch
gh pr create \
  --title "test: add unit tests for tools/bash.zig" \
  --body-file /tmp/pr_body.md   # write your description to a file first
```

**PR description must include:**
- What changed and why
- How you verified it (`zig build test` output, smoke test result, or manual steps)
- Reference to any related issue or task

### 6. After your PR is open

- Do not merge, approve, or review your own PR.
- Address review comments with new commits (do not force-push to rewrite history after review starts).
- Once the reviewer approves, they will merge.

---

## Code guidelines

- **No stray `git add -A`.** Stage only the files relevant to your task.
- **No comments explaining what the code does** — good names do that. Add a comment only when the *why* is non-obvious (a hidden constraint, a specific bug workaround).
- **No half-finished implementations.** If something is not ready, leave it out of the PR.
- **Exit codes are semantic.** Use the existing codes in `src/args.zig`; do not invent new ones without discussion.

---

## Getting help

- Open an issue on GitHub to discuss a bug or feature before writing code.
- Check `docs/roadmap.md` for planned work — you may find a natural place to contribute.
- For build environment problems, verify `zig version` is exactly `0.16.0` first.
