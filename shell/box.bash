# Box shell integration for bash
# Add to ~/.bashrc or source this file directly

if [[ -n "$BOX" ]]; then
    # OSC 133 shell integration for box

    # Store original PROMPT_COMMAND
    __box_original_prompt_command="$PROMPT_COMMAND"

    # Prompt started (before prompt is displayed)
    __box_prompt_start() {
        printf '\e]133;A\e\\'
    }

    # Command finished (after command completes)
    __box_command_end() {
        local exit_code=$?
        printf '\e]133;D;%d\e\\' "$exit_code"
        return $exit_code
    }

    # Combined prompt command
    __box_prompt_command() {
        __box_command_end
        __box_prompt_start
        # Run original prompt command if it exists
        if [[ -n "$__box_original_prompt_command" ]]; then
            eval "$__box_original_prompt_command"
        fi
    }

    PROMPT_COMMAND=__box_prompt_command

    # Command output started (after user presses Enter)
    # Using DEBUG trap to detect when a command is about to run
    __box_preexec_enabled=1
    __box_preexec() {
        # Skip if disabled or during prompt command
        [[ -z "$__box_preexec_enabled" ]] && return
        # Skip completion
        [[ -n "$COMP_LINE" ]] && return
        # Skip prompt command itself
        [[ "$BASH_COMMAND" == "__box_prompt_command" ]] && return
        [[ "$BASH_COMMAND" == "__box_command_end" ]] && return
        [[ "$BASH_COMMAND" == "__box_prompt_start" ]] && return

        printf '\e]133;C\e\\'
        # Disable until next prompt to avoid multiple emissions
        __box_preexec_enabled=
    }

    # Re-enable preexec after prompt
    __box_reenable_preexec() {
        __box_preexec_enabled=1
    }

    trap '__box_preexec' DEBUG

    # Update prompt command to re-enable preexec
    __box_prompt_command() {
        __box_command_end
        __box_prompt_start
        __box_reenable_preexec
        if [[ -n "$__box_original_prompt_command" ]]; then
            eval "$__box_original_prompt_command"
        fi
    }

    # Initial prompt start
    __box_prompt_start
fi
