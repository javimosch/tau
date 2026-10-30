# fish completion for tau
# -----------------------------------------------------------------------------
# One-time (current session):
#   source completions/tau.fish
#
# Permanent — user:
#   mkdir -p ~/.config/fish/completions
#   cp completions/tau.fish ~/.config/fish/completions/tau.fish
#
# fish autoloads <name>.fish from ~/.config/fish/completions and every
# directory in $fish_complete_path, so the file must be named tau.fish.

# ── Context helpers ─────────────────────────────────────────────────────────

# True while no top-level subcommand token is on the command line.
function __tau_no_subcommand
    set -l tokens (commandline -opc)
    set -e tokens[1]
    for t in $tokens
        switch $t
            case acp fleet skills models guide init config doctor setup bug version upgrade explain
                return 1
        end
    end
    return 0
end

# True once the given subcommand ($argv[1]) appears on the command line.
function __tau_using_subcommand
    set -l tokens (commandline -opc)
    set -e tokens[1]
    contains -- $argv[1] $tokens
end

# True when `tau fleet` is on the line but no run|status|list|logs|cancel yet.
function __tau_fleet_needs_mode
    set -l tokens (commandline -opc)
    set -e tokens[1]
    set -l seen_fleet 0
    for t in $tokens
        if test $seen_fleet -eq 0
            test "$t" = fleet; and set seen_fleet 1
            continue
        end
        switch $t
            case run status list logs cancel
                return 1
        end
    end
    test $seen_fleet -eq 1
end

# Complete @file arguments: strip the '@', use the builtin file completer,
# then re-add the '@' sigil to every candidate.
function __tau_at_files
    set -l token (commandline -ct)
    string match -q '@*' -- $token; or return
    set -l prefix (string sub -s 2 -- $token)
    set -l escaped (string escape -- $prefix)
    for line in (complete --do-complete="cat $escaped")
        set -l parts (string split -m1 \t -- $line)
        if test (count $parts) -eq 2
            printf '@%s\t%s\n' $parts[1] $parts[2]
        else
            printf '@%s\n' $parts[1]
        end
    end
end

# ── Completion entries ──────────────────────────────────────────────────────

# Prompts are free text; file paths are offered only via -F options and the
# @file handler below.
complete -c tau -f

# @file injection — active in any position once the token starts with '@'.
complete -c tau -a '(__tau_at_files)'

# ── Top level: subcommands + global flags ───────────────────────────────────
set -l top '__tau_no_subcommand'

complete -c tau -n $top -f -a acp -d 'manage the ACP server (start|stop|status|serve)'
complete -c tau -n $top -f -a fleet -d 'multi-agent orchestration (run|status|list|logs|cancel)'
complete -c tau -n $top -f -a skills -d 'skills autodiscovery (list|search|load)'
complete -c tau -n $top -f -a models -d 'list available providers and models'
complete -c tau -n $top -f -a guide -d 'print the embedded operator manual'
complete -c tau -n $top -f -a init -d 'write a commented starter config'
complete -c tau -n $top -f -a config -d 'inspect and edit the config file (show|validate|set|get|unset|edit|schema)'
complete -c tau -n $top -f -a doctor -d 'validate setup (config, provider, key, connectivity)'
complete -c tau -n $top -f -a setup -d 'one-shot onboarding (init + completions + doctor)'
complete -c tau -n $top -f -a bug -d 'file a pre-filled GitHub issue with doctor diagnostics'
complete -c tau -n $top -f -a version -d 'print version (--verbose adds build metadata)'
complete -c tau -n $top -f -a upgrade -d 'self-update in place via the verified install.sh'
complete -c tau -n $top -f -a explain -d 'offline error-catalog lookup (cause + remediation)'

complete -c tau -n $top -s h -l help -d 'show help text'
complete -c tau -n $top -s v -l version -d 'show version'
complete -c tau -n $top -l help-json -d 'machine-readable help as JSON'
complete -c tau -n $top -s p -l print -d 'non-interactive (print-only) mode'
complete -c tau -n $top -l mode -x -a 'text json' -d 'output mode'
complete -c tau -n $top -l stream -d 'enable streaming output'
complete -c tau -n $top -l no-stream -d 'disable streaming output'
complete -c tau -n $top -l debug -d 'show performance stats and tool calls'
complete -c tau -n $top -l dry-run -d 'report tool calls without executing them'
complete -c tau -n $top -l provider -x -a 'xiaomi openai deepseek opencode-go' -d 'LLM provider'
complete -c tau -n $top -l model -x -d 'model id or provider/model shorthand'
complete -c tau -n $top -l api-key -x -d 'API key (overrides env vars)'
complete -c tau -n $top -l system-prompt -x -d 'set (replace) system prompt'
complete -c tau -n $top -l append-system-prompt -x -d 'append to system prompt (repeatable)'
complete -c tau -n $top -s t -l tools -x -a 'bash ls read write edit grep find calculator' -d 'tool allowlist, comma-separated'
complete -c tau -n $top -o xt -l exclude-tools -x -a 'bash ls read write edit grep find calculator' -d 'tool denylist, comma-separated'
complete -c tau -n $top -o nt -l no-tools -d 'disable all built-in tools'
complete -c tau -n $top -l temperature -x -d 'sampling temperature (0.0-2.0)'
complete -c tau -n $top -l max-tokens -x -d 'maximum output tokens'
complete -c tau -n $top -l timeout-ms -x -d 'HTTP request timeout in ms (default 120000)'
complete -c tau -n $top -l thinking -d 'enable reasoning/thinking chunks'
complete -c tau -n $top -l context-window -x -d 'override model context window in tokens'
complete -c tau -n $top -l no-compact -d 'disable automatic context compaction'
complete -c tau -n $top -l compact-threshold -x -d 'compaction trigger fraction of context (0-1)'
complete -c tau -n $top -l compact-keep-recent -x -d 'tokens of recent history kept verbatim'
complete -c tau -n $top -l schema -r -a '(__tau_at_files)' -d 'JSON Schema for structured output (inline JSON or @file)'
complete -c tau -n $top -l session -x -d 'named session for conversation persistence'
complete -c tau -n $top -l goal-max-iterations -x -d 'per-run loop cap for /goal mode'
complete -c tau -n $top -l max-iterations -x -d 'tool-loop runaway backstop'
complete -c tau -n $top -l role -x -a 'author critic coordinator none' -d 'role for adversarial author-critic loop'
complete -c tau -n $top -l scan-agents -d 'scan cwd for AGENTS.md files'
complete -c tau -n $top -l load-agents-md -rF -d 'load an AGENTS.md file into system context'
complete -c tau -n $top -l auto-agents-md -d 'auto-load cwd/AGENTS.md on startup'

# ── tau acp ─────────────────────────────────────────────────────────────────
set -l acp '__tau_using_subcommand acp'

complete -c tau -n $acp -f -a start -d 'start the ACP server as a background daemon'
complete -c tau -n $acp -f -a stop -d 'stop the background ACP daemon'
complete -c tau -n $acp -f -a status -d 'report ACP daemon status (JSON)'
complete -c tau -n $acp -f -a serve -d 'run the JSON-RPC server (stdio or Unix socket)'
complete -c tau -n $acp -l acp-socket -rF -d 'Unix socket path for ACP daemon'
complete -c tau -n $acp -l max-iterations -x -d 'runaway-loop backstop'

# ── tau fleet ───────────────────────────────────────────────────────────────
set -l fleet '__tau_using_subcommand fleet'

complete -c tau -n "$fleet; and __tau_fleet_needs_mode" -f -a run -d 'decompose a goal and dispatch workers'
complete -c tau -n "$fleet; and __tau_fleet_needs_mode" -f -a status -d 'check status of a fleet by id'
complete -c tau -n "$fleet; and __tau_fleet_needs_mode" -f -a list -d 'list all known fleets'
complete -c tau -n "$fleet; and __tau_fleet_needs_mode" -f -a logs -d 'per-worker session hints for a fleet id'
complete -c tau -n "$fleet; and __tau_fleet_needs_mode" -f -a cancel -d 'cancel a running fleet by id'

complete -c tau -n $fleet -l goal -x -d 'fleet objective (natural language)'
complete -c tau -n $fleet -l id -x -d 'fleet identifier'
complete -c tau -n $fleet -l api-key -x -d 'API key'
complete -c tau -n $fleet -l provider -x -a 'xiaomi openai deepseek opencode-go' -d 'LLM provider'
complete -c tau -n $fleet -l model -x -d 'model id'
complete -c tau -n $fleet -l coordinator-model -x -d 'coordinator agent model override'
complete -c tau -n $fleet -l worker-model -x -d 'worker agent model override'
complete -c tau -n $fleet -l sequential -d 'run worker agents sequentially'
complete -c tau -n $fleet -l parallel -d 'run worker agents in parallel (default)'
complete -c tau -n $fleet -l items -x -d 'pre-supplied work items, skips coordinator (JSON)'
complete -c tau -n $fleet -l schema -r -a '(__tau_at_files)' -d 'JSON Schema for work-item breakdown (inline or @file)'

# ── tau skills / tau guide / tau models ─────────────────────────────────────
set -l skills '__tau_using_subcommand skills'
complete -c tau -n $skills -f -a list -d 'list all discoverable skills'
complete -c tau -n $skills -f -a search -d 'search skills by keyword'
complete -c tau -n $skills -f -a load -d 'load a skill into the system context by name'

complete -c tau -n '__tau_using_subcommand guide' -f -l human -d 'render the guide as markdown'

# ── tau config ──────────────────────────────────────────────────────────────
set -l config '__tau_using_subcommand config'
complete -c tau -n $config -f -a show -d 'print the resolved effective config (keys redacted)'
complete -c tau -n $config -f -a validate -d 'check a config file (CI/pre-commit)'
complete -c tau -n $config -f -a set -d 'set a config key to a value'
complete -c tau -n $config -f -a get -d 'print a config key value (secrets redacted)'
complete -c tau -n $config -f -a unset -d 'remove a config key'
complete -c tau -n $config -f -a edit -d 'open the config in $EDITOR (validates on save)'
complete -c tau -n $config -f -a schema -d 'print the config file JSON Schema (draft 2020-12)'
complete -c tau -n $config -f -l mode -x -a 'text json' -d 'output mode'
complete -c tau -n $config -f -l json -d 'stable JSON output (show|validate)'
complete -c tau -n $config -f -l raw -d 'print secret values unredacted (config get)'

# ── tau init / tau doctor / tau setup ───────────────────────────────────────
set -l init '__tau_using_subcommand init'
complete -c tau -n $init -f -l force -d 'overwrite an existing config file'
complete -c tau -n $init -f -l stdout -d 'print the starter config without writing it'
complete -c tau -n $init -f -l provider -x -a 'xiaomi openai deepseek opencode-go' -d 'scaffold for a specific provider'

set -l doctor '__tau_using_subcommand doctor'
complete -c tau -n $doctor -f -l offline -d 'skip network checks'
complete -c tau -n $doctor -f -l deep -d 'run an authenticated probe (spends ~1 token)'
complete -c tau -n $doctor -f -l probe -d 'live-verify connectivity and credentials for every provider'
complete -c tau -n $doctor -f -l selftest -d 'credential-free end-to-end session against a loopback stub'
complete -c tau -n $doctor -f -l fix -d 'remediate fixable checks (prompts per fix)'
complete -c tau -n $doctor -f -l yes -d 'apply --fix remediations without prompting'
complete -c tau -n $doctor -f -s y -d 'apply --fix remediations without prompting'
complete -c tau -n $doctor -f -l json -d 'stream NDJSON check/fix events + done:true verdict'
complete -c tau -n $doctor -f -l report -d 'markdown diagnostics bundle for bug reports'
complete -c tau -n $doctor -f -l shell -x -a 'bash zsh fish pwsh all' -d 'completions shell (default: detect $SHELL)'
complete -c tau -n $doctor -f -l provider -x -a 'xiaomi openai deepseek opencode-go' -d 'diagnose an override provider'
complete -c tau -n $doctor -f -l model -x -d 'diagnose an override model'
complete -c tau -n $doctor -f -l api-key -x -d 'diagnose an override API key'

set -l setup '__tau_using_subcommand setup'
complete -c tau -n $setup -f -l shell -x -a 'bash zsh fish pwsh all' -d 'completions shell (default: detect $SHELL)'
complete -c tau -n $setup -f -l client -x -a 'zed nvim vscode jetbrains windsurf gemini claude-desktop all' -d 'configure editor ACP client'
complete -c tau -n $setup -f -l offline -d 'skip network checks in the doctor step'
complete -c tau -n $setup -f -l deep -d 'run an authenticated probe in the doctor step'
complete -c tau -n $setup -f -s y -l yes -d 'unattended: approve all write steps'
complete -c tau -n $setup -f -l non-interactive -d 'unattended contract for scripts/CI'
complete -c tau -n $setup -f -l dry-run -d 'preview write steps; change nothing'
complete -c tau -n $setup -f -l provider -x -a 'xiaomi openai deepseek opencode-go' -d 'seed scaffold + diagnose provider'
complete -c tau -n $setup -f -l model -x -d 'diagnose an override model'
complete -c tau -n $setup -f -l api-key -x -d 'diagnose an override API key'

set -l bug '__tau_using_subcommand bug'
complete -c tau -n $bug -f -l title -x -d 'issue title (default "Bug report")'
complete -c tau -n $bug -f -l body -x -d 'description placed above the bundle'
complete -c tau -n $bug -f -l labels -x -d 'issue labels csv (default bug)'
complete -c tau -n $bug -f -l open -d 'open the issue URL in the system browser'
complete -c tau -n $bug -f -l out -r -d 'write the diagnostics bundle to a file'
complete -c tau -n $bug -f -l no-report -d 'omit the diagnostics bundle'
complete -c tau -n $bug -f -l offline -d 'skip network checks'
complete -c tau -n $bug -f -l deep -d 'run an authenticated probe (spends ~1 token)'
complete -c tau -n $bug -f -l shell -x -a 'bash zsh fish pwsh all' -d 'completions shell (default: detect $SHELL)'
complete -c tau -n $bug -f -l provider -x -a 'xiaomi openai deepseek opencode-go' -d 'diagnose an override provider'
complete -c tau -n $bug -f -l model -x -d 'diagnose an override model'
complete -c tau -n $bug -f -l api-key -x -d 'diagnose an override API key'

set -l version '__tau_using_subcommand version'
complete -c tau -n $version -f -l verbose -d 'include build metadata (commit, target, build date, zig version)'
complete -c tau -n $version -f -l check -d 'non-blocking update check against the latest release'
complete -c tau -n $version -f -l json -d 'emit the stable {"name","version",...} object'
complete -c tau -n $version -f -l mode -x -a 'text json' -d 'output mode'

set -l upgrade '__tau_using_subcommand upgrade'
complete -c tau -n $upgrade -f -s y -l yes -d 'upgrade without prompting'
complete -c tau -n $upgrade -f -l dir -x -d 'install destination (default: the running binary dir)'
complete -c tau -n $upgrade -f -l dry-run -d 'print the resolved plan; install nothing'

set -l explain '__tau_using_subcommand explain'
# Exit codes mirror the stable catalog in src/errors.zig.
complete -c tau -n $explain -f -a '1 80 82 105 106 110 111' -d 'error code or type'
complete -c tau -n $explain -f -l json -d 'emit the stable schema-checked JSON form'
complete -c tau -n $explain -f -l human -d 'render the entry as prose instead of JSON'

# `tau models` takes no further arguments.
