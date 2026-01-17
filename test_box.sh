#!/bin/sh
# Simple test script to run box with proper shell integration
# This sets up the BOX environment variable

export BOX=1
export TERM=xterm-256color

# Source the box integration script for zsh
if [ -n "$ZSH_VERSION" ]; then
    # zsh integration
    precmd() {
        print -Pn '\e]133;A\e\\'
    }
    zle-line-init() {
        print -Pn '\e]133;B\e\\'
    }
    zle -N zle-line-init
    preexec() {
        print -Pn '\e]133;C\e\\'
    }
    __box_precmd() {
        print -Pn '\e]133;D;$?\e\\'
    }
    precmd_functions+=(__box_precmd)
fi

# Run box with zsh
exec ./zig-out/bin/box zsh
