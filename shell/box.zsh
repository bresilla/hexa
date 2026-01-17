//! Box shell integration for zsh
/// Add to ~/.zshrc or source this file directly

if [[ -n "$BOX" ]]; then
    # OSC 133 shell integration for box

    # Prompt started (before prompt is displayed)
    precmd() {
        print -Pn "\e]133;A\e\\"
    }

    # Command started (after prompt, before user input)
    zle-line-init() {
        print -Pn "\e]133;B\e\\"
    }
    zle -N zle-line-init

    # Command output started (after user presses Enter)
    preexec() {
        print -Pn "\e]133;C\e\\"
    }

    # Command finished (after command completes)
    __box_precmd() {
        print -Pn "\e]133;D;$?\e\\"
    }
    precmd_functions+=(__box_precmd)
fi
