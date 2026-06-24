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
            acp|fleet|skills|models)
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
        --tools|-t|--exclude-tools|-xt)
            COMPREPLY=($(compgen -W "bash ls read write edit grep find" -- "$cur"))
            return ;;
        --load-agents-md)
            declare -f _filedir &>/dev/null && _filedir
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
                COMPREPLY=($(compgen -W "run status list logs cancel" -- "$cur"))
            else
                COMPREPLY=($(compgen -W "--goal --id --api-key --provider --model \
                    --coordinator-model --worker-model --sequential --parallel \
                    --items --schema" -- "$cur"))
            fi
            ;;

        skills)
            COMPREPLY=($(compgen -W "list search load" -- "$cur"))
            ;;

        models)
            # No additional completions for `models`.
            ;;

        *)
            # Top-level: subcommands + all global flags
            local top_level="acp models skills fleet
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
