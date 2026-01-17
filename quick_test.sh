#!/bin/sh
# Quick test to verify box works

echo "=== Box Test ==="
echo ""
echo "Running box with zsh (with OSC 133 integration)"
echo "You should see decorations between commands after they complete"
echo ""
echo "Try these commands:"
echo "  echo 'hello'"
echo "  ls -la"
echo "  echo 'world'"
echo ""
echo "Expected: Each command gets a decoration like: ═════[1] ═══"
echo ""
echo "Press Ctrl+C to exit"
echo ""

BOX=1 TERM=xterm-256color ./zig-out/bin/box zsh -i -c '
    precmd() {
        print -Pn "\e]133;A\e\\"
    }
    zle-line-init() {
        print -Pn "\e]133;B\e\\"
    }
    zle -N zle-line-init
    preexec() {
        print -Pn "\e]133;C\e\\"
    }
    __box_precmd() {
        print -Pn "\e]133;D;$?\e\\"
    }
    precmd_functions+=(__box_precmd)
'
