#! /usr/bin/env bash
# Box shell integration for bash
# Add to ~/.config/blox/box.bash or source this file directly

if [[ -n "$BOX" ]]; then
    # OSC 133 shell integration for box

    # Prompt started (before prompt is displayed)
    precmd() {
        printf '\e]133;A\e\\'
    }

    # Command started (after prompt, before user input)
    # Bash doesn't have a direct hook for this, so we rely on PS1
    PS1='$(printf '\''\e]133;B\e\\%s'\'' "$PS1")'

    # Command output started (after user presses Enter)
    # In bash, we use DEBUG trap for this
    trap '__box_preexec' DEBUG
    __box_preexec() {
        if [[ -n "$COMP_LINE" ]]; then
            # Not a command execution, skip
            return
        fi
        printf '\e]133;C\e\\'
    }

    # Command finished (after command completes)
    __box_precmd() {
        printf '\e]133;D;%d\e\\' $?
    }
    PROMPT_COMMAND='__box_precmd'
fi
