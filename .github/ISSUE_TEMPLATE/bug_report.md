---
name: Bug report
about: Something in tau isn't working as expected
labels: bug
---

## What happened

<!-- A clear description of the bug. -->

## Expected behaviour

<!-- What you expected tau to do instead. -->

## Steps to reproduce

```
# Minimal command that triggers the bug
tau ...
```

## Environment

- tau version (`tau --version`): 
- OS / distro: 
- Zig version (if built from source): 
- Provider / model: 

## Relevant output

<details>
<summary>Error / log output</summary>

```
paste output here
```

</details>

## Diagnostic log (optional but very helpful)

Re-run the failing command with `--debug`:

```
tau --debug <your command>
```

tau writes a **redacted** diagnostic log to `~/.config/tau/debug/<timestamp>.log`
(the exact path is printed on stderr as `{"debug_log":"<path>"}` and included
in the `{"err":...}` envelope's `debug_log` field). API keys and Bearer tokens
are masked with `***REDACTED***` — please still review the file before
attaching, then drag it into this issue.
