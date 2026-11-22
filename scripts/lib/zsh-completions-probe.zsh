#!/usr/bin/env zsh
# Drive a REAL interactive zsh through the compsys completion path and print
# the resulting transcript on stdout.
#
#   zsh-completions-probe.zsh <completion-dir> <command-line>
#
# <completion-dir> is prepended to fpath inside the session, compinit is run
# against a scratch dump file, then <command-line> + a literal TAB is sent to
# the ZLE widget — exactly what a user pressing TAB at the prompt triggers.
# stdout gets the pty transcript (prompt echoes + candidate list); the caller
# greps it for expected candidates. Exit status: 0 when the session ran,
# 77/78 when zpty or the child could not start, 79 when the session never
# became ready.
#
# Environment is inherited — callers that exercise the dynamic
# `completions candidates` lookups put `tau` on PATH and a seeded config on
# HOME before invoking this script.

emulate -L zsh
zmodload zsh/zpty || exit 77

local name="taucomp$$" compdir="$1" line="$2"
local transcript="" chunk="" tries=0

zpty -b "$name" zsh -f -i 2>/dev/null || exit 78

# Prompt is intentionally not customised — candidate text is all we assert on.
zpty -w "$name" "fpath=($compdir \$fpath)"
zpty -w "$name" 'autoload -Uz compinit; compinit -i -d ${TMPDIR:-/tmp}/.tau-probe-zcompdump 2>/dev/null; print -r -- __TAU_READY__'

while (( tries++ < 40 )); do
  if zpty -r -t "$name" chunk 2>/dev/null; then
    transcript+="$chunk"
    [[ "$transcript" == *__TAU_READY__* ]] && break
  fi
  sleep 0.1
done
if [[ "$transcript" != *__TAU_READY__* ]]; then
  zpty -d "$name" 2>/dev/null
  print -u2 "zsh session never became ready"
  exit 79
fi

zpty -w "$name" "${line}"$'\t'
# Give the completion machinery a beat, then drain whatever it rendered.
sleep 1.5
tries=0
while (( tries++ < 20 )); do
  if zpty -r -t "$name" chunk 2>/dev/null; then
    transcript+="$chunk"
  fi
  sleep 0.1
done

zpty -w "$name" 'exit'
zpty -d "$name" 2>/dev/null
print -r -- "$transcript"
