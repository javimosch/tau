# PowerShell completion for tau (PowerShell 5.1+ / pwsh 7+)
# -----------------------------------------------------------------------------
# One-time (current session):
#   . ./completions/tau.ps1
#
# Permanent — dot-source it from your profile:
#   Add-Content $PROFILE ". '$PWD/completions/tau.ps1'"
# then restart the shell or run:  . $PROFILE

$TauArgumentCompleter = {
    param($wordToComplete, $commandAst, $cursorPosition)

    $providers   = @('xiaomi', 'openai', 'deepseek', 'opencode-go')
    $modes       = @('text', 'json')
    $roles       = @('author', 'critic', 'coordinator', 'none')
    $tools       = @('bash', 'ls', 'read', 'write', 'edit', 'grep', 'find', 'calculator')
    $subcommands = @('acp', 'fleet', 'skills', 'models', 'guide')
    $acpArgs     = @('start', 'stop', 'status', 'serve', '--acp-socket', '--max-iterations')
    $fleetSubs   = @('run', 'status', 'list', 'logs', 'cancel')
    $fleetFlags  = @('--goal', '--id', '--api-key', '--provider', '--model',
                     '--coordinator-model', '--worker-model', '--sequential', '--parallel',
                     '--items', '--schema')
    $skillSubs   = @('list', 'search', 'load')
    $guideFlags  = @('--human')
    $globalFlags = @(
        '--help', '-h', '--version', '-v', '--help-json',
        '--print', '-p',
        '--mode', '--stream', '--no-stream',
        '--debug', '--dry-run',
        '--provider', '--model', '--api-key',
        '--system-prompt', '--append-system-prompt',
        '--tools', '-t', '--exclude-tools', '-xt', '--no-tools', '-nt',
        '--temperature', '--max-tokens', '--timeout-ms', '--thinking',
        '--context-window', '--no-compact', '--compact-threshold', '--compact-keep-recent',
        '--schema', '--session', '--goal-max-iterations', '--max-iterations',
        '--role', '--scan-agents', '--load-agents-md', '--auto-agents-md'
    )
    # Flags that take a free-form value: suppress completion after them.
    $valueFlags = @('--model', '--api-key', '--system-prompt', '--append-system-prompt',
                    '--session', '--temperature', '--max-tokens', '--timeout-ms',
                    '--context-window', '--compact-threshold', '--compact-keep-recent',
                    '--goal-max-iterations', '--max-iterations', '--acp-socket',
                    '--goal', '--id', '--coordinator-model', '--worker-model', '--items')

    $tooltips = @{
        'acp'                 = 'manage the ACP server (start|stop|status|serve)'
        'fleet'               = 'multi-agent orchestration (run|status|list|logs|cancel)'
        'skills'              = 'skills autodiscovery (list|search|load)'
        'models'              = 'list available providers and models'
        'guide'               = 'print the embedded operator manual'
        'run'                 = 'decompose a goal and dispatch workers'
        'status'              = 'check status of a fleet by id'
        'list'                = 'list all known fleets / skills'
        'logs'                = 'per-worker session hints for a fleet id'
        'cancel'              = 'cancel a running fleet by id'
        'search'              = 'search skills by keyword'
        'load'                = 'load a skill into the system context by name'
        'start'               = 'start the ACP server as a background daemon'
        'stop'                = 'stop the background ACP daemon'
        'serve'               = 'run the JSON-RPC server (stdio or Unix socket)'
        '--help'              = 'show help text'
        '--version'           = 'show version'
        '--help-json'         = 'machine-readable help as JSON'
        '--print'             = 'non-interactive (print-only) mode'
        '--mode'              = 'output mode (text|json)'
        '--stream'            = 'enable streaming output'
        '--no-stream'         = 'disable streaming output'
        '--debug'             = 'show performance stats and tool calls'
        '--dry-run'           = 'report tool calls without executing them'
        '--provider'          = 'LLM provider'
        '--model'             = 'model id or provider/model shorthand'
        '--api-key'           = 'API key (overrides env vars)'
        '--system-prompt'     = 'set (replace) system prompt'
        '--append-system-prompt' = 'append to system prompt (repeatable)'
        '--tools'             = 'tool allowlist, comma-separated'
        '--exclude-tools'     = 'tool denylist, comma-separated'
        '--no-tools'          = 'disable all built-in tools'
        '--temperature'       = 'sampling temperature'
        '--max-tokens'        = 'maximum output tokens'
        '--timeout-ms'        = 'HTTP request timeout in ms'
        '--thinking'          = 'enable reasoning/thinking chunks'
        '--context-window'    = 'override model context window in tokens'
        '--no-compact'        = 'disable automatic context compaction'
        '--compact-threshold' = 'compaction trigger fraction of context'
        '--compact-keep-recent' = 'tokens of recent history kept verbatim'
        '--schema'            = 'JSON Schema (inline JSON or @file)'
        '--session'           = 'named session for conversation persistence'
        '--goal-max-iterations' = 'per-run loop cap for /goal mode'
        '--max-iterations'    = 'tool-loop runaway backstop'
        '--role'              = 'role for adversarial author-critic loop'
        '--scan-agents'       = 'scan cwd for AGENTS.md files'
        '--load-agents-md'    = 'load an AGENTS.md file into system context'
        '--auto-agents-md'    = 'auto-load cwd/AGENTS.md on startup'
        '--acp-socket'        = 'Unix socket path for ACP daemon'
        '--goal'              = 'fleet objective (natural language)'
        '--id'                = 'fleet identifier'
        '--coordinator-model' = 'coordinator agent model override'
        '--worker-model'      = 'worker agent model override'
        '--sequential'        = 'run worker agents sequentially'
        '--parallel'          = 'run worker agents in parallel (default)'
        '--items'             = 'pre-supplied work items, skips coordinator (JSON)'
        '--human'             = 'render the guide as markdown'
    }

    # Emit $candidates filtered by the word being completed.
    $emit = {
        param($candidates, $kind)
        $candidates | Where-Object { $_ -like "$currentWord*" } | ForEach-Object {
            $tip = $tooltips[$_]
            if (-not $tip) { $tip = $_ }
            [System.Management.Automation.CompletionResult]::new($_, $_, $kind, $tip)
        }
    }

    # Words already on the command line; element 0 is the command name itself.
    # $wordToComplete may carry a surrounding quote — normalize to $currentWord.
    $currentWord = $wordToComplete.Trim('"', "'")
    $words = @($commandAst.CommandElements | Select-Object -Skip 1 |
        ForEach-Object { $_.Extent.Text.Trim('"', "'") })
    $context = $words
    if ($context.Count -gt 0 -and $wordToComplete -ne '' -and $context[-1] -eq $currentWord) {
        $context = @($context | Select-Object -SkipLast 1)
    }
    $prev = if ($context.Count -gt 0) { $context[-1] } else { '' }

    # File-path completion: prefer the engine's own filename completer, fall
    # back to Get-ChildItem if CompletionCompleters is unavailable.
    $completeFile = {
        param($word)
        try {
            $r = @([System.Management.Automation.CompletionCompleters]::CompleteFilename($word))
            if ($r.Count -gt 0) { return $r }
        } catch { }
        $dirPart = ''
        $leaf = $word
        if ($word -match '^(.*[\\/])([^\\/]*)$') {
            $dirPart = $Matches[1]
            $leaf = $Matches[2]
        }
        $dir = if ($dirPart) { $dirPart } else { '.' }
        Get-ChildItem -LiteralPath $dir -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like "$leaf*" } | ForEach-Object {
                $text = "$dirPart$($_.Name)$(if ($_.PSIsContainer) { '/' })"
                if ($text -match '\s') { $text = "'$text'" }
                [System.Management.Automation.CompletionResult]::new(
                    $text, $text, 'ProviderItem', $_.FullName)
            }
    }

    # File-path completion with the '@' sigil re-added to every candidate.
    # $rawWord may start with a quote ('@file must be quoted in PowerShell,
    # where bare '@x' is splat syntax); preserve quoting in the result.
    $atFiles = {
        param($rawWord)
        $quote = ''
        $word = $rawWord
        if ($word.Length -ge 2 -and ($word[0] -eq '"' -or $word[0] -eq "'")) {
            $quote = [string]$word[0]
            $word = $word.Substring(1)
            if ($word.EndsWith($quote)) { $word = $word.Substring(0, $word.Length - 1) }
        }
        $path = $word.Substring(1)   # strip the '@' sigil
        & $completeFile $path | ForEach-Object {
            $text = $_.CompletionText
            if ($text.StartsWith('"') -or $text.StartsWith("'")) {
                $text = $text.Substring(0, 1) + '@' + $text.Substring(1)
            } elseif ($quote) {
                $text = "$quote@$text$quote"
            } else {
                $text = '@' + $text
            }
            [System.Management.Automation.CompletionResult]::new(
                $text, '@' + $_.ListItemText, $_.ResultType, $_.ToolTip)
        }
    }

    # ── Flag-argument completions ───────────────────────────────────────────
    switch ($prev) {
        '--provider'       { return & $emit $providers 'ParameterValue' }
        '--mode'           { return & $emit $modes 'ParameterValue' }
        '--role'           { return & $emit $roles 'ParameterValue' }
        { $_ -in '--tools', '-t', '--exclude-tools', '-xt' } {
            return & $emit $tools 'ParameterValue'
        }
        '--load-agents-md' { return & $completeFile $wordToComplete }
        '--schema' {
            if ($currentWord.StartsWith('@')) { return & $atFiles $wordToComplete }
            return
        }
        { $_ -in $valueFlags } { return }
    }

    # ── @file injection at any other position ───────────────────────────────
    if ($currentWord.StartsWith('@')) { return & $atFiles $wordToComplete }

    # ── Subcommand-scoped completions ───────────────────────────────────────
    $sub = ''
    foreach ($w in $context) {
        if ($subcommands -contains $w) { $sub = $w; break }
    }

    switch ($sub) {
        'acp'    { return & $emit $acpArgs 'Command' }
        'skills' { return & $emit $skillSubs 'Command' }
        'guide'  { return & $emit $guideFlags 'ParameterName' }
        'models' { return }
        'fleet'  {
            $fleetSub = ''
            $seenFleet = $false
            foreach ($w in $context) {
                if (-not $seenFleet) {
                    if ($w -eq 'fleet') { $seenFleet = $true }
                    continue
                }
                if ($fleetSubs -contains $w) { $fleetSub = $w; break }
            }
            # Flags are valid before the sub-subcommand too, so offer both.
            if ($fleetSub -eq '') { return & $emit ($fleetSubs + $fleetFlags) 'ParameterName' }
            return & $emit $fleetFlags 'ParameterName'
        }
    }

    # ── Top level: subcommands + global flags ───────────────────────────────
    return & $emit ($subcommands + $globalFlags) 'ParameterName'
}

Register-ArgumentCompleter -Native -CommandName tau -ScriptBlock $TauArgumentCompleter
