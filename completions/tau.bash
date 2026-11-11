# bash completion for tau
# -----------------------------------------------------------------------------
# One-time (current session):
#   source completions/tau.bash
#
# Permanent — user:
#   mkdir -p ~/.local/share/bash-completion/completions
#   cp completions/tau.bash ~/.local/share/bash-completion/completions/tau
#
# Permanent — system-wide:
#   sudo cp completions/tau.bash /etc/bash_completion.d/tau

_tau_complete() {
    local cur prev words cword
    # Prefer bash-completion's _init_completion when available.
    if declare -f _init_completion &>/dev/null; then
        _init_completion || return
    else
        COMPREPLY=()
        cur="${COMP_WORDS[COMP_CWORD]}"
        prev="${COMP_WORDS[COMP_CWORD-1]}"
        words=("${COMP_WORDS[@]}")
        cword=$COMP_CWORD
    fi

    # Detect the first subcommand already on the line.
    local subcommand="" i
    for ((i = 1; i < cword; i++)); do
        case "${words[i]}" in
            acp|fleet|skills|models|init|config|guide|doctor|setup|completions|bug|version|upgrade|explain)
                subcommand="${words[i]}"
                break
                ;;
        esac
    done

    # ------------------------------------------------------------------
    # Value completions for flags that take an argument
    # ------------------------------------------------------------------
    case "$prev" in
        --provider)
            COMPREPLY=($(compgen -W "xiaomi openai deepseek opencode-go" -- "$cur"))
            return ;;
        --mode)
            COMPREPLY=($(compgen -W "text json" -- "$cur"))
            return ;;
        --role)
            COMPREPLY=($(compgen -W "author critic coordinator none" -- "$cur"))
            return ;;
        --shell)
            COMPREPLY=($(compgen -W "bash zsh fish pwsh all" -- "$cur"))
            return ;;
        --tools|-t|--exclude-tools|-xt)
            COMPREPLY=($(compgen -W "bash ls read write edit grep find calculator" -- "$cur"))
            return ;;
        --load-agents-md)
            declare -f _filedir &>/dev/null && _filedir
            return ;;
        --dir)
            declare -f _filedir &>/dev/null && _filedir -d
            return ;;
        --schema)
            if [[ "$cur" == @* ]]; then
                local path="${cur#@}"
                local -a files
                files=($(compgen -f -- "$path"))
                COMPREPLY=("${files[@]/#/@}")
            fi
            return ;;
        # Flags whose values are free-form — offer nothing.
        --model|--api-key|--system-prompt|--append-system-prompt|--session|\
        --temperature|--max-tokens|--timeout-ms|--context-window|\
        --compact-threshold|--compact-keep-recent|--goal-max-iterations|\
        --max-iterations|--acp-socket|--goal|--id|--coordinator-model|\
        --worker-model|--items)
            return ;;
    esac

    # ------------------------------------------------------------------
    # @file prefix — complete path and re-add the '@' sigil
    # ------------------------------------------------------------------
    if [[ "$cur" == @* ]]; then
        local path="${cur#@}"
        local -a files
        files=($(compgen -f -- "$path"))
        COMPREPLY=("${files[@]/#/@}")
        return
    fi

    # ------------------------------------------------------------------
    # Positional / subcommand completions
    # ------------------------------------------------------------------
    case "$subcommand" in
        acp)
            COMPREPLY=($(compgen -W "start stop status serve --acp-socket --max-iterations" -- "$cur"))
            ;;

        fleet)
            # Discover the fleet sub-subcommand already on the line.
            local fleet_sub="" found_fleet=0
            for ((i = 1; i < cword; i++)); do
                if [[ "${words[i]}" == "fleet" ]]; then
                    found_fleet=1
                elif [[ $found_fleet -eq 1 && "${words[i]}" != --* ]]; then
                    fleet_sub="${words[i]}"
                    break
                fi
            done
            if [[ -z "$fleet_sub" ]]; then
                # Flags are valid before the sub-subcommand too, so offer both.
                COMPREPLY=($(compgen -W "run status list logs cancel \
                    --goal --id --api-key --provider --model \
                    --coordinator-model --worker-model --sequential --parallel \
                    --items --schema" -- "$cur"))
            else
                COMPREPLY=($(compgen -W "--goal --id --api-key --provider --model \
                    --coordinator-model --worker-model --sequential --parallel \
                    --items --schema" -- "$cur"))
            fi
            ;;

        skills)
            COMPREPLY=($(compgen -W "list search load" -- "$cur"))
            ;;

        config)
            COMPREPLY=($(compgen -W "show validate set get unset edit schema --mode --raw --json" -- "$cur"))
            ;;

        init)
            COMPREPLY=($(compgen -W "--force --stdout --provider --json" -- "$cur"))
            ;;

        doctor)
            COMPREPLY=($(compgen -W "--offline --deep --probe --selftest --fix --yes -y --json --report --shell --provider --model --api-key" -- "$cur"))
            ;;

        bug)
            COMPREPLY=($(compgen -W "--title --body --labels --open --out --no-report --attach-report --offline --deep --shell --provider --model --api-key --json" -- "$cur"))
            ;;

        setup)
            COMPREPLY=($(compgen -W "--shell --client --offline --deep --provider --model --api-key --yes -y --non-interactive --dry-run --remove --uninstall --import --detect --json" -- "$cur"))
            ;;

        completions)
            COMPREPLY=($(compgen -W "install --shell --dry-run --json" -- "$cur"))
            ;;

        guide)
            COMPREPLY=($(compgen -W "--human" -- "$cur"))
            ;;

        models)
            # No additional completions for `models`.
            ;;

        version)
            COMPREPLY=($(compgen -W "--verbose --check --json --mode" -- "$cur"))
            ;;

        upgrade)
            COMPREPLY=($(compgen -W "--yes -y --dir --dry-run --verify-signature --json" -- "$cur"))
            ;;

        explain)
            # Codes mirror src/errors.zig; config keys mirror docs/config.md;
            # doctor.* ids mirror the CheckSpec catalog in src/doctorcatalog.zig;
            # TAU_* names mirror the Spec registry in src/envvars.zig.
            COMPREPLY=($(compgen -W '1 80 82 105 106 110 111 $schema provider model api_key keys mode stream thinking debug temperature max_tokens timeout_ms context_window auto_compact compact_threshold compact_keep_recent compact_keep_recent_tokens goal_max_iterations goal_max_continues keys.xiaomi keys.openai keys.deepseek keys.opencode-go doctor.config_deprecated_keys doctor.config_file doctor.config_permissions doctor.plaintext_secrets doctor.config_secret_permissions doctor.shell_completions doctor.provider_resolution doctor.api_key doctor.curl doctor.proxy_env doctor.tls_ca doctor.endpoint_reachable doctor.auth_probe doctor.client_wiring doctor.client_permissions doctor.provider_probes doctor.update_available doctor.selftest doctor.client_zed doctor.client_nvim doctor.client_emacs doctor.client_vscode doctor.client_cursor doctor.client_jetbrains doctor.client_windsurf doctor.client_gemini doctor.client_claude_desktop doctor.client_opencode doctor.client_cline doctor.client_goose doctor.client_continue doctor.client_roo_code doctor.client_kilo_code doctor.client_amazonq doctor.client_codex doctor.probe_xiaomi doctor.probe_xiaomi_auth doctor.probe_openai doctor.probe_openai_auth doctor.probe_deepseek doctor.probe_deepseek_auth doctor.probe_opencode-go doctor.probe_opencode-go_auth TAU_API_KEY TAU_ENDPOINT TAU_DEBUG_LOG TAU_EDITOR TAU_YES TAU_NONINTERACTIVE TAU_SETUP_SHELL TAU_SETUP_CLIENT TAU_SETUP_IMPORT TAU_NO_UPDATE_CHECK TAU_UPDATE_URL TAU_INSTALL_URL TAU_CHANGELOG_URL TAU_INSTALL_DIR TAU_VERIFY_SIGSTORE TAU_VERSION TAU_BASE_URL TAU_OS TAU_ARCH TAU_SKIP_CHECKSUM TAU_BIN TAU_TOOLS TAU_THINKING TAU_DEBUG --human --json' -- "$cur"))
            ;;

        *)
            # Top-level: subcommands + all global flags
            local top_level="acp models skills fleet init config guide doctor setup completions bug version upgrade explain
                --help -h --version -v --help-json
                --print -p
                --mode --stream --no-stream
                --debug --dry-run
                --provider --model --api-key
                --system-prompt --append-system-prompt
                --tools -t --exclude-tools -xt --no-tools -nt
                --temperature --max-tokens --timeout-ms --thinking
                --context-window --no-compact --compact-threshold --compact-keep-recent
                --schema
                --session --goal-max-iterations --max-iterations
                --role
                --scan-agents --load-agents-md --auto-agents-md"
            COMPREPLY=($(compgen -W "$top_level" -- "$cur"))
            ;;
    esac
}

complete -F _tau_complete tau
