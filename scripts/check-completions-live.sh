#!/usr/bin/env bash
# check-completions-live.sh — run the shipped completion scripts inside real
# bash/zsh/fish/pwsh sessions and verify they source cleanly and return
# candidates.
#
#   check-completions-live.sh [--require-all] <tau-binary>
#
# Per shell the driver checks:
#   1. the shipped script loads in that shell without errors,
#   2. a real completion invocation returns flag candidates (e.g. `tau --m`
#      offers `--mode`, `--max-tokens`),
#   3. dynamic `tau completions candidates` wiring returns live config keys
#      for `tau config get <TAB>`.
#
# bash is exercised by invoking the completion function the way readline
# calls it (COMP_WORDS/COMP_CWORD in, COMPREPLY out). zsh is exercised inside
# a real interactive session through scripts/lib/zsh-completions-probe.zsh
# (compsys only runs inside a widget context). fish uses its documented
# `complete --do-complete` evaluator and pwsh uses `TabExpansion2` — the same
# entry points their shells call at TAB time.
#
# Shells that are not installed are SKIPped (exit stays 0) unless
# --require-all is given — CI uses that flag after installing all four.
#
# Output: `PASS|SKIP|FAIL <shell>: <check>` lines; exit 1 if anything fails.

set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPDIR="$ROOT/completions"
PROBE="$ROOT/scripts/lib/zsh-completions-probe.zsh"

REQUIRE_ALL=0
BIN=""
for arg in "$@"; do
    case "$arg" in
        --require-all) REQUIRE_ALL=1 ;;
        *) BIN="$arg" ;;
    esac
done
if [ -z "$BIN" ]; then
    echo "usage: $0 [--require-all] <tau-binary>" >&2
    exit 2
fi
if command -v cygpath >/dev/null 2>&1; then BIN="$(cygpath "$BIN")"; fi
BIN="$(cd "$(dirname "$BIN")" && pwd)/$(basename "$BIN")"
if [ ! -x "$BIN" ]; then
    echo "not executable: $BIN" >&2
    exit 2
fi

FAILS=0
SKIPS=0
pass() { printf 'PASS %s: %s\n' "$1" "$2"; }
skip() { printf 'SKIP %s: %s\n' "$1" "$2"; SKIPS=$((SKIPS + 1)); }
fail() { printf 'FAIL %s: %s (%s)\n' "$1" "$2" "$3"; FAILS=$((FAILS + 1)); }

# The shipped scripts resolve `command tau` at completion time for the
# dynamic config-key candidates — put a `tau`-named shim on PATH pointing at
# the binary under test.
SHIMDIR="$(mktemp -d)"
ln -sf "$BIN" "$SHIMDIR/tau"
case "$(uname -s 2>/dev/null)" in
    MINGW*|MSYS*|CYGWIN*)
        # Windows pwsh resolves `tau` via PATHEXT — an extensionless shim
        # never executes. A tau.cmd next to it runs via cmd.exe instead.
        bin_win="$BIN"; command -v cygpath >/dev/null 2>&1 && bin_win="$(cygpath -w "$BIN")"
        printf '@"%s" %%*\r\n' "$bin_win" > "$SHIMDIR/tau.cmd"
        ;;
esac

# Seeded HOME: config-get/get-style candidates reflect the live config file.
LIVE_HOME="$(mktemp -d)"
mkdir -p "$LIVE_HOME/.config/tau"
printf '{\n  "provider": "openai",\n  "keys": {"openai": "sk-x"},\n  "mode": "text"\n}\n' \
    > "$LIVE_HOME/.config/tau/config.json"

trap 'rm -rf "$SHIMDIR" "$LIVE_HOME"' EXIT

SHELL_ENV=(env HOME="$LIVE_HOME" PATH="$SHIMDIR:$PATH")

have() { command -v "$1" >/dev/null 2>&1; }

# contains <needle> <haystack>
has() { case "$2" in *"$1"*) return 0 ;; *) return 1 ;; esac; }

missing() {
    if [ "$REQUIRE_ALL" -eq 1 ]; then
        fail "$1" "shell available" "not installed (required)"
    else
        skip "$1" "not installed"
    fi
}

# ── bash ───────────────────────────────────────────────────────────────────
b_src=$("${SHELL_ENV[@]}" bash --noprofile --norc -c '
    source "$1" || exit 3
' _ "$COMPDIR/tau.bash" 2>&1)
if [ $? -eq 0 ] && [ -z "$b_src" ]; then
    pass bash "sources cleanly"
else
    fail bash "sources cleanly" "$(printf '%s' "$b_src" | head -1)"
fi

b_out=$("${SHELL_ENV[@]}" bash --noprofile --norc -c '
    source "$1" || exit 3
    COMP_LINE="tau --m"; COMP_POINT=${#COMP_LINE}
    COMP_WORDS=(tau --m); COMP_CWORD=1
    _tau_complete || exit 4
    printf "%s\n" "${COMPREPLY[@]}"
' _ "$COMPDIR/tau.bash" 2>&1)
if has "--mode" "$b_out" && has "--max-tokens" "$b_out"; then
    pass bash "flag candidates"
else
    fail bash "flag candidates" "$(printf '%s' "$b_out" | head -3 | tr '\n' ' ')"
fi

b_out=$("${SHELL_ENV[@]}" bash --noprofile --norc -c '
    source "$1" || exit 3
    COMP_LINE="tau config get "; COMP_POINT=${#COMP_LINE}
    COMP_WORDS=(tau config get ""); COMP_CWORD=3
    _tau_complete || exit 4
    printf "%s\n" "${COMPREPLY[@]}"
' _ "$COMPDIR/tau.bash" 2>&1)
if has "provider" "$b_out" && has "keys.openai" "$b_out"; then
    pass bash "dynamic config-key candidates"
else
    fail bash "dynamic config-key candidates" "$(printf '%s' "$b_out" | head -3 | tr '\n' ' ')"
fi

# ── zsh ────────────────────────────────────────────────────────────────────
if ! have zsh; then
    missing zsh
else
    # Clean load = compinit registers _comps[tau] via the fpath autoload path
    # (sourcing _tau directly runs _tau "$@" outside a widget — not the
    # install path).
    z_out=$("${SHELL_ENV[@]}" zsh -fc '
        fpath+=("$1")
        autoload -Uz compinit
        compinit -i -d "$2" 2>/dev/null
        print -r -- "${_comps[tau]-MISSING}"
    ' _ "$COMPDIR" "$LIVE_HOME/.zcompdump" 2>&1)
    if [ "$z_out" = "_tau" ]; then
        pass zsh "sources cleanly (compinit registers _tau)"
    else
        fail zsh "sources cleanly" "$(printf '%s' "$z_out" | head -1)"
    fi

    z_out=$("${SHELL_ENV[@]}" zsh "$PROBE" "$COMPDIR" "tau --m" 2>&1)
    if has "--mode" "$z_out" && has "--max-tokens" "$z_out" && ! has "bad option" "$z_out"; then
        pass zsh "flag candidates"
    else
        fail zsh "flag candidates" "$(printf '%s' "$z_out" | tail -3 | tr '\n' ' ')"
    fi

    z_out=$("${SHELL_ENV[@]}" zsh "$PROBE" "$COMPDIR" "tau " 2>&1)
    if has "doctor" "$z_out" && has "setup" "$z_out" && ! has "bad option" "$z_out"; then
        pass zsh "subcommand candidates"
    else
        fail zsh "subcommand candidates" "$(printf '%s' "$z_out" | tail -3 | tr '\n' ' ')"
    fi

    z_out=$("${SHELL_ENV[@]}" zsh "$PROBE" "$COMPDIR" "tau config get " 2>&1)
    if has "provider" "$z_out" && has "keys.openai" "$z_out"; then
        pass zsh "dynamic config-key candidates"
    else
        fail zsh "dynamic config-key candidates" "$(printf '%s' "$z_out" | tail -3 | tr '\n' ' ')"
    fi
fi

# ── fish ───────────────────────────────────────────────────────────────────
if ! have fish; then
    missing fish
else
    f_out=$("${SHELL_ENV[@]}" fish -c 'source $argv[1]' -- "$COMPDIR/tau.fish" 2>&1)
    if [ $? -eq 0 ] && [ -z "$f_out" ]; then
        pass fish "sources cleanly"
    else
        fail fish "sources cleanly" "$(printf '%s' "$f_out" | head -1)"
    fi

    f_out=$("${SHELL_ENV[@]}" fish -c 'source $argv[1]; complete --do-complete="tau --m"' -- "$COMPDIR/tau.fish" 2>&1)
    if has "--mode" "$f_out" && has "--max-tokens" "$f_out"; then
        pass fish "flag candidates"
    else
        fail fish "flag candidates" "$(printf '%s' "$f_out" | head -3 | tr '\n' ' ')"
    fi

    f_out=$("${SHELL_ENV[@]}" fish -c 'source $argv[1]; complete --do-complete="tau config get "' -- "$COMPDIR/tau.fish" 2>&1)
    if has "provider" "$f_out" && has "keys.openai" "$f_out"; then
        pass fish "dynamic config-key candidates"
    else
        fail fish "dynamic config-key candidates" "$(printf '%s' "$f_out" | head -3 | tr '\n' ' ')"
    fi
fi

# ── pwsh ───────────────────────────────────────────────────────────────────
if ! have pwsh; then
    missing pwsh
else
    # The script path goes through an env var: a trailing -Command arg gets
    # glued into the command string instead of landing in $args/$input.
    p_out=$(env HOME="$LIVE_HOME" PATH="$SHIMDIR:$PATH" TAU_COMPLETION_PS1="$COMPDIR/tau.ps1" \
        pwsh -NoProfile -Command '. $env:TAU_COMPLETION_PS1' 2>&1)
    if [ $? -eq 0 ] && [ -z "$p_out" ]; then
        pass pwsh "sources cleanly"
    else
        fail pwsh "sources cleanly" "$(printf '%s' "$p_out" | head -1)"
    fi

    p_out=$(env HOME="$LIVE_HOME" PATH="$SHIMDIR:$PATH" TAU_COMPLETION_PS1="$COMPDIR/tau.ps1" \
        pwsh -NoProfile -Command '
            . $env:TAU_COMPLETION_PS1
            $r = TabExpansion2 -inputScript "tau --m" -cursorColumn 7
            $r.CompletionMatches | ForEach-Object { $_.CompletionText }
        ' 2>&1)
    if has "--mode" "$p_out" && has "--max-tokens" "$p_out"; then
        pass pwsh "flag candidates"
    else
        fail pwsh "flag candidates" "$(printf '%s' "$p_out" | head -3 | tr '\n' ' ')"
    fi

    p_out=$(env HOME="$LIVE_HOME" PATH="$SHIMDIR:$PATH" TAU_COMPLETION_PS1="$COMPDIR/tau.ps1" \
        pwsh -NoProfile -Command '
            . $env:TAU_COMPLETION_PS1
            $r = TabExpansion2 -inputScript "tau config get " -cursorColumn 15
            $r.CompletionMatches | ForEach-Object { $_.CompletionText }
        ' 2>&1)
    if has "provider" "$p_out" && has "keys.openai" "$p_out"; then
        pass pwsh "dynamic config-key candidates"
    else
        fail pwsh "dynamic config-key candidates" "$(printf '%s' "$p_out" | head -3 | tr '\n' ' ')"
    fi
fi

# ── summary ────────────────────────────────────────────────────────────────
if [ "$FAILS" -eq 0 ]; then
    echo "completions-live: all checks passed${SKIPS:+ ($SKIPS skipped)}"
    exit 0
fi
echo "completions-live: $FAILS check(s) failed"
exit 1
