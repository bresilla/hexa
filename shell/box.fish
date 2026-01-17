//! Box shell integration for fish
/// Add to ~/.config/fish/conf.d/box.fish

if set -q BOX
    # Prompt started
    function __box_prompt --on-event fish_prompt
        printf "\e]133;A\e\\"
    end

    # Command started (before user input)
    function __box_pre --on-event fish_preexec
        printf "\e]133;B\e\\"
    end

    # Command output started
    function __box_preexec --on-event fish_preexec
        printf "\e]133;C\e\\"
    end

    # Command finished
    function __box_postexec --on-event fish_postexec
        printf "\e]133;D;%d\e\\" $status
    end
end
