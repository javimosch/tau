# Shell Completions

Tab-complete `tau` flags, options, and subcommands in Bash or Zsh.

## What gets completed

| Context | Completions |
|---|---|
| Top-level | All flags + subcommands (`acp`, `fleet`, `skills`, `models`) |
| `--provider` | `xiaomi openai deepseek opencode-go` |
| `--mode` | `text json` |
| `--role` | `author critic coordinator none` |
| `--tools` / `--exclude-tools` | `bash ls read write edit grep find` |
| `--load-agents-md` / `--schema` | File paths |
| `@…` prefix | File paths with `@` prepended |
| `tau acp` | `start stop status serve` |
| `tau fleet` | `run status list logs cancel` + fleet flags |
| `tau skills` | `list search load` |

---

## Bash

### One-time (current session)

```bash
source completions/tau.bash
```

### Permanent — user install

```bash
mkdir -p ~/.local/share/bash-completion/completions
cp completions/tau.bash ~/.local/share/bash-completion/completions/tau
```

Bash auto-sources files in that directory when `bash-completion` is active (most
Linux distros and Homebrew on macOS do this by default).

### Permanent — system-wide

```bash
sudo cp completions/tau.bash /etc/bash_completion.d/tau
```

---

## Zsh

The zsh file follows the `_command` naming convention required by `compinit`.

### One-time (current session)

```zsh
source completions/_tau
compdef _tau tau
```

### Permanent install

1. Pick (or create) a completions directory and register it in `$fpath` **before** the
   `compinit` call in `~/.zshrc`:

   ```zsh
   mkdir -p ~/.zsh/completions
   # In ~/.zshrc, before `compinit`:
   fpath=(~/.zsh/completions $fpath)
   ```

2. Copy the file (the `_tau` name is required for autoloading):

   ```zsh
   cp completions/_tau ~/.zsh/completions/_tau
   ```

3. Rebuild the completion cache:

   ```zsh
   rm -f ~/.zcompdump && compinit
   ```

### Oh My Zsh

Drop the file into the custom completions directory:

```zsh
cp completions/_tau ~/.oh-my-zsh/completions/_tau
```

Then restart your shell or run `exec zsh`.

---

## Verifying it works

```bash
tau --<TAB>        # lists all flags
tau --provider <TAB>   # xiaomi  openai  deepseek  opencode-go
tau fleet <TAB>        # run  status  list  logs  cancel
tau acp <TAB>          # start  stop  status  serve
tau @<TAB>             # local file paths prefixed with @
```
