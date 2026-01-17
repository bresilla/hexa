# Blox - Terminal Multiplexer & Block Wrapper

Blox is a modern terminal toolkit written in Zig, consisting of two independent but composable components:

- **mux** - Full tmux replacement with tabs, panes, and floating panes
- **box** - Command block wrapper with Warp-like interactivity

Each can be used standalone, or together (box running inside mux).

## Installation

```bash
# Build
zig build

# Install
zig build install --prefix ~/.local
```

## Usage

### Standalone mux

```bash
mux                    # Start new session or attach
mux attach             # Attach to existing session
mux list               List all sessions
mux new-window         Create new window
mux split-h            Split horizontal
mux split-v            Split vertical
mux float              Create floating pane
```

### Standalone box

```bash
box                    # Wrap current shell
box zsh                # Wrap specific shell
```

### Combined (box inside mux)

```bash
mux                    # Start mux
# Inside mux pane:
box                    # Each pane can run box
```

Or configure mux to auto-wrap panes with box:

```toml
# ~/.config/blox/mux.toml
[pane]
shell = "box zsh"        # Auto-wrap with box
```

## Shell Integration

For box to work properly, enable shell integration:

### zsh
Add to `~/.zshrc`:
```bash
source /path/to/blox/shell/box.zsh
```

### fish
Copy to `~/.config/fish/conf.d/box.fish`

## Configuration

### ~/.config/blox/box.toml

```toml
[style]
type = "separator"
separator_char = "="

[decorations]
show_exit_status = true
show_duration = true
show_block_number = true
show_copy_button = true
show_collapse_button = true
```

### ~/.config/blox/mux.toml

```toml
[general]
prefix = "ctrl+a"
mouse = true

[pane]
shell = "zsh"

[window]
tab_bar = "top"

[floating]
default_width = 80
default_height = 24
```

## Implementation Status

### Phase 1: Core Infrastructure ✅
- [x] Project setup (build.zig, dependencies)
- [x] Core PTY utilities
- [x] Basic terminal I/O
- [x] ANSI escape sequence helpers
- [x] Mouse protocol handling
- [x] Terminal state management

### Phase 2: box MVP ✅
- [x] PTY passthrough
- [x] Simple VT parser (basic OSC 133 detection)
- [x] Basic separator injection
- [x] Exit code display
- [x] Block data structures

### Phase 3: box Interactivity 🚧
- [x] Mouse tracking
- [x] Clickable regions
- [x] Keyboard navigation
- [x] Configurable styles
- [ ] Full libghostty-vt integration (pending)

### Phase 4: mux MVP ✅
- [x] Server/client architecture
- [x] Single session, single window
- [x] Basic pane splits
- [x] PTY per pane
- [x] IPC communication

### Phase 5: mux Full Features ✅
- [x] Multiple sessions (basic)
- [x] Multiple windows (tabs)
- [x] Floating panes
- [x] Basic detach/attach
- [x] Layout engine

### Phase 6: Integration 🚧
- [ ] box inside mux (basic integration exists)
- [ ] Shared configuration
- [ ] Combined binary option

## Building

```bash
# Build both
zig build

# Build only mux
zig build mux

# Build only box
zig build box

# Run tests
zig build test

# Install
zig build install --prefix ~/.local
```

## License

MIT License
