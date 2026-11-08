# Shell Completions

Tab-complete `tau` flags, options, and subcommands in Bash, Zsh, Fish, or
PowerShell.

| File | Shell |
|---|---|
| `tau.bash` | Bash |
| `_tau` | Zsh |
| `tau.fish` | Fish |
| `tau.ps1` | PowerShell |

## What gets completed

| Context | Completions |
|---|---|
| Top-level | All flags + subcommands (`acp`, `fleet`, `skills`, `models`, `guide`) |
| `--provider` | `xiaomi openai deepseek opencode-go` |
| `--mode` | `text json` |
| `--role` | `author critic coordinator none` |
| `--tools` / `--exclude-tools` | `bash ls read write edit grep find calculator` |
| `--load-agents-md` / `--schema` | File paths |
| `@…` prefix | File paths with `@` prepended |
| `tau acp` | `start stop status serve` |
| `tau fleet` | `run status list logs cancel` + fleet flags |
| `tau skills` | `list search load` |
| `tau guide` | `--human` |

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

## Fish

Fish autoloads `tau.fish` from `~/.config/fish/completions` (or any directory
in `$fish_complete_path`), so the filename must match the command name.

### One-time (current session)

```fish
source completions/tau.fish
```

### Permanent install

```fish
mkdir -p ~/.config/fish/completions
cp completions/tau.fish ~/.config/fish/completions/tau.fish
```

New shells pick it up automatically; no cache rebuild needed.

---

## PowerShell

Works in Windows PowerShell 5.1 and pwsh 7+ (Linux/macOS/Windows).

### One-time (current session)

```powershell
. ./completions/tau.ps1        # or: . .\completions\tau.ps1 on Windows
```

### Permanent install

Dot-source the file from your profile:

```powershell
Add-Content $PROFILE ". '$PWD/completions/tau.ps1'"
```

Then restart the shell or run `. $PROFILE`.

> **Note:** In PowerShell, bare `@name` is splat syntax — `@file` arguments
> must be quoted: `tau '@file.txt'`. The completer still expands
> `tau '@<TAB>` to quoted `@path` candidates.

---

## Verifying it works

```bash
tau --<TAB>        # lists all flags
tau --provider <TAB>   # xiaomi  openai  deepseek  opencode-go
tau fleet <TAB>        # run  status  list  logs  cancel
tau acp <TAB>          # start  stop  status  serve
tau @<TAB>             # local file paths prefixed with @
```
