#!/usr/bin/env python3
"""Extract runnable `tau ...` command snippets from Markdown docs.

Every fenced ```bash/```sh/```shell block in the given files is scanned for
lines whose first token is `tau` or `./zig-out/bin/tau` — the exact commands a
reader would copy-paste. Backslash line-continuations are joined first so
multi-line invocations come out as one command. The leading token is
normalized to `tau` so callers can resolve it via PATH/TAU_BIN.

Output: TSV rows of `<file>:<line>\t<command>` on stdout — one per snippet,
in document order. Shell placeholders like `<id>` are passed through
verbatim; the runner substitutes a live value before executing.

Usage:
  scripts/extract-doc-snippets.py [doc.md ...]   (default: README.md)

Stdlib only. Exits 1 when no snippets are found.
"""
import re
import sys

FENCE_RE = re.compile(r"```(bash|sh|shell)\s*\n(.*?)```", re.S)
CMD_RE = re.compile(r"^(?:\./zig-out/bin/)?tau(?=\s|$)")


def commands_in(block):
    """Yield (start_line_offset, command) for each tau snippet in a block.

    Offsets are 0-based physical lines inside the fenced block; the command
    text is the joined logical line (backslash continuations collapsed).
    """
    buf = ""
    start = 0
    for i, raw in enumerate(block.split("\n")):
        line = raw if not buf else buf + raw.lstrip()
        if not buf:
            start = i
        if line.rstrip().endswith("\\"):
            buf = line.rstrip()[:-1] + " "
            continue
        s = line.strip()
        if CMD_RE.match(s):
            yield start, CMD_RE.sub("tau", s, count=1)
        buf = ""
    if buf:
        s = buf.strip()
        if CMD_RE.match(s):
            yield start, CMD_RE.sub("tau", s, count=1)


def extract(path):
    """Yield (lineno, command) for every tau snippet in the file."""
    text = open(path, encoding="utf-8").read()
    for m in FENCE_RE.finditer(text):
        # Line number (1-based) of the first line inside the fence.
        base = text.count("\n", 0, m.start(2)) + 1
        for offset, cmd in commands_in(m.group(2)):
            yield base + offset, cmd


def main(argv):
    paths = argv[1:] or ["README.md"]
    found = 0
    for path in paths:
        for lineno, cmd in extract(path):
            found += 1
            sys.stdout.write(f"{path}:{lineno}\t{cmd}\n")
    if not found:
        sys.stderr.write("extract-doc-snippets: no tau commands found\n")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
