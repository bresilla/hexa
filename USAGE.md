# Blox - Terminal Multiplexer & Block Wrapper

## Quick Start

### Using box (Command Block Wrapper)

**Option 1: Simple PTY Wrapper (No Decorations)**
```bash
BOX=1 ./zig-out/bin/box /bin/sh
```

**Option 2: With Block Decorations (Recommended)**

**For zsh:**
```bash
# Add to ~/.zshrc:
source /doc/code/bloxs/shell/box.zsh

# Run:
BOX=1 TERM=xterm-256color ./zig-out/bin/box zsh
```

**For fish:**
```bash
# Copy to ~/.config/fish/conf.d/box.fish:
cp /doc/code/bloxs/shell/box.fish ~/.config/fish/conf.d/

# Run:
BOX=1 TERM=xterm-256color ./zig-out/bin/box fish
```

**For bash:**
```bash
# Add to ~/.bashrc:
source /doc/code/bloxs/shell/box.bash

# Run:
BOX=1 TERM=xterm-256color ./zig-out/bin/box bash
```

### Using mux (Terminal Multiplexer)

```bash
# Start mux (auto-starts server if needed)
./zig-out/bin/mux

# Attach to running server
./zig-out/bin/mux attach

# Kill server
./zig-out/bin/mux kill

# Show help
./zig-out/bin/mux help
```

---

## What You'll See with box

With OSC 133 integration loaded, each command gets a decoration:

```
$ echo "hello"
hello
════════════════════════════════════════════════════════════════ [📋] [↕] │ 1 │ ✓ 0.0s

$ ls
PLAN.md    build.zig
════════════════════════════════════════════════════════════════ [📋] [↕] │ 2 │ ✓ 0.1s
```

### Box Features

- ✅ Automatic block detection via OSC 133
- ✅ Exit status display (✓/✗)
- ✅ Command duration tracking
- ✅ Clickable copy button [📋]
- ✅ Collapsible blocks [-][+]
- ✅ Search through blocks (Ctrl+F)
- ✅ Copy to clipboard (Ctrl+C)
- ✅ 3 decoration styles (separator, box, minimal)

### Box Configuration

Create `~/.config/blox/box.toml`:

```toml
[style]
type = "separator"    # "separator", "box", "minimal"
separator_char = "="

[decorations]
show_exit_status = true
show_duration = true
show_block_number = true
show_copy_button = true
show_collapse_button = true
```

---

## Mux Keybindings

```
Prefix: Ctrl+A

Prefix+|      Split horizontal
Prefix+-      Split vertical
Prefix+o      Next pane
Prefix+x      Close pane
Prefix+w      Next window/tab
Prefix+W      Previous window/tab
Prefix+n      New window
Prefix+s      New session
Prefix+l      List sessions
Prefix+0-9   Switch to session
Prefix+f      New floating pane
Prefix+F      Close floating pane
```

### Mux Configuration

Create `~/.config/blox/mux.toml`:

```toml
[general]
prefix = "ctrl+a"
mouse = true

[pane]
shell = "zsh"          # or "box zsh" to auto-wrap with box
border_style = "rounded"

[window]
tab_bar = "top"        # "top", "bottom", "none"

[floating]
default_width = "80%"
default_height = "80%"
border_style = "double"
```

---

## Box Inside Mux

To automatically wrap panes with box, set in `~/.config/blox/mux.toml`:

```toml
[pane]
shell = "box zsh"    # Auto-wrap with box decorations
```

Now every new pane will have block decorations!

---

## Troubleshooting

**Q: I see "══════" lines but no blocks?**
A: Your shell doesn't have OSC 133 integration loaded. Source the appropriate shell integration script from `shell/` directory.

**Q: Box says "Error: NotATerminal"**
A: You're not running in a terminal (e.g., piping output). Run box directly in a terminal.

**Q: Decorations look wrong/missing icons?**
A: Your terminal might not support certain Unicode characters. Try the "minimal" style in config.

**Q: Copy button doesn't work?**
A: Your terminal must support OSC 52 clipboard. Most modern terminals support this.

---

## Shell Integration Files

- `shell/box.zsh` - zsh OSC 133 hooks
- `shell/box.fish` - fish OSC 133 hooks
- `shell/box.bash` - bash OSC 133 hooks

These files emit OSC 133 sequences that box detects to know where commands start and end.
