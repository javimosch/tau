#!/usr/bin/env python3
"""Run a command attached to a fresh pseudo-terminal and capture the merged
pty stream.

smoke.sh uses this to exercise TTY-only code paths — the interactive [y/N]
confirmation prompts in `tau upgrade` and `tau doctor --fix`, and the
NO_COLOR/CLICOLOR color policy that only engages on TTY streams.

Usage:
    pty-run.py <capture-file> <feed> <cmd> [args...]

<feed> is written to the pty master immediately; the line discipline buffers
it until the child reads, so answers can be queued up front (e.g. "n\nn\n"
declines two prompts). The child's stdin/stdout/stderr are all the pty
slave — commands that need a non-TTY stream (e.g. to snapshot a plain
stderr) can redirect it themselves via `sh -c '... 2>file'`.

The merged session transcript (incl. input echo) lands in <capture-file>;
this script exits with the child's exit status, or 124 on the 30s timeout.

POSIX only — callers must gate on `hasattr(os, "fork")` before invoking
(Windows has no pty.fork).
"""

import os
import pty
import select
import sys
import time

TIMEOUT_S = 30


def _exitcode(status):
    if status is None:
        return 124
    if os.WIFEXITED(status):
        return os.WEXITSTATUS(status)
    if os.WIFSIGNALED(status):
        return 128 + os.WTERMSIG(status)
    return 1


def main():
    if len(sys.argv) < 4:
        print("usage: pty-run.py <capture-file> <feed> <cmd> [args...]", file=sys.stderr)
        return 2
    cap, feed, cmd = sys.argv[1], sys.argv[2].encode(), sys.argv[3:]

    pid, fd = pty.fork()
    if pid == 0:
        try:
            os.execvpe(cmd[0], cmd, os.environ)
        except BaseException:
            os._exit(127)

    buf = bytearray()
    if feed:
        try:
            os.write(fd, feed)
        except OSError:
            pass

    status = None
    deadline = time.monotonic() + TIMEOUT_S
    while time.monotonic() < deadline:
        r, _, _ = select.select([fd], [], [], 0.25)
        if r:
            try:
                chunk = os.read(fd, 65536)
            except OSError:
                break  # EIO: slave closed, child gone
            if not chunk:
                break
            buf += chunk
            continue
        # Idle slice: if the child already exited, drain what remains and stop.
        done, st = os.waitpid(pid, os.WNOHANG)
        if done:
            status = st
            while True:
                try:
                    chunk = os.read(fd, 65536)
                except OSError:
                    break
                if not chunk:
                    break
                buf += chunk
            break

    if status is None:
        try:
            os.kill(pid, 15)
        except OSError:
            pass
        try:
            _, status = os.waitpid(pid, 0)
        except ChildProcessError:
            pass

    with open(cap, "wb") as fh:
        fh.write(bytes(buf))
    return _exitcode(status)


if __name__ == "__main__":
    sys.exit(main())
