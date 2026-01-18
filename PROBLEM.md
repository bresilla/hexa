# Bloxs Mux Rendering Problem

## Summary

The terminal multiplexer has persistent rendering corruption issues where escape sequence fragments appear as visible text, and scrolling behavior affects rendering quality.

## Symptoms

1. **Escape sequence fragments appearing as text**
   - Examples: `38;5;240m`, `236m`, `[m`, `(B`, `0m`
   - These are parts of SGR (Select Graphic Rendition) color sequences
   - The `ESC[` prefix appears to be missing or not interpreted

2. **Random characters appearing**
   - Single characters like `5`, `1`, `H`, `¬¬`
   - Background color blocks with numbers inside: `██5███`

3. **Scrolling-dependent behavior (KEY CLUE)**
   - Scrolling UP (viewing older content) FIXES the weird rendering
   - Scrolling DOWN (viewing newer content / bottom) ADDS more garbage
   - This pattern is consistent and reproducible

4. **Screen not clearing properly on startup**
   - Old terminal content visible when mux starts
   - Terminal state appears corrupted before mux takes over

5. **"Broken TV" effect**
   - Terminal rendered from wrong position (1/3 offset)
   - Content wraps around incorrectly
   - Whole terminal shifts when cursor moves

## Architecture

```
┌─────────────────────────────────────────┐
│  Outer Terminal (ghostty/kitty/etc)     │
│  ┌───────────────────────────────────┐  │
│  │  Bloxs Mux                        │  │
│  │  ┌─────────────────────────────┐  │  │
│  │  │  Ghostty VT Parser          │  │  │
│  │  │  (parses PTY output)        │  │  │
│  │  └─────────────────────────────┘  │  │
│  │            ↓                      │  │
│  │  ┌─────────────────────────────┐  │  │
│  │  │  Cell Buffer                │  │  │
│  │  │  (stores parsed cells)      │  │  │
│  │  └─────────────────────────────┘  │  │
│  │            ↓                      │  │
│  │  ┌─────────────────────────────┐  │  │
│  │  │  Renderer                   │  │  │
│  │  │  (generates escape seqs)    │  │  │
│  │  └─────────────────────────────┘  │  │
│  │            ↓                      │  │
│  │       stdout.writeAll()           │  │
│  └───────────────────────────────────┘  │
└─────────────────────────────────────────┘
```

## Data Flow

1. Child process (shell/nvim) writes escape sequences to PTY
2. Mux reads from PTY into buffer
3. Ghostty VT parser processes the escape sequences
4. Parser updates internal cell grid with characters and styles
5. Renderer reads cells from ghostty's PageList
6. Renderer generates NEW escape sequences for the outer terminal
7. Output written to stdout

## Key Observation

**When tmux runs INSIDE the mux, rendering works correctly.**

This means:
- The outer terminal can display escape sequences correctly
- tmux's rendering approach works
- The issue is specific to how our mux reads/generates output

## What tmux Does Differently

1. Uses `TERM=screen-256color` or `TERM=tmux-256color`
2. Has its own terminfo with specific capabilities
3. Completely rewrites all output (never passes through raw data)
4. Has battle-tested escape sequence generation

## Attempted Fixes

### 1. Coordinate System Changes
- Tried `.viewport` vs `.active` coordinates for reading cells
- `.viewport` = what's visible (changes when scrolled)
- `.active` = the editable screen area (fixed)
- Neither completely fixed the issue

### 2. Escape Sequence Generation
- Fixed `writeCSIFmt` to format BEFORE writing (prevent partial sequences)
- Moved sync end (`?2026l`) into renderer for atomic output
- Tried removing charset reset sequences
- Used explicit `ESC` byte (0x1B) instead of string escapes

### 3. Terminal Reset on Startup
- Added `ESC c` (RIS - Reset to Initial State)
- Added `ESC[2J` (clear screen)
- Added `ESC[H` (cursor home)
- Added charset reset (`ESC(B`, `SI`)

### 4. Output Atomicity
- Combined output and cursor buffer into single `writev()` call
- Ensured synchronized update begin/end in same buffer

### 5. Cursor Positioning
- Tried cursor tracking (only position when needed)
- Tried explicit positioning for every cell
- Tried positioning at start of each row

### 6. Differential Rendering
- Disabled (always full redraw) to eliminate as variable

## Current Theory

The scrolling behavior suggests the issue is in **how we read cells from ghostty's PageList**:

1. When scrolled UP (viewing history), we read committed/stable data → works
2. When at bottom (active area), we read potentially unstable data → corrupted

Possible causes:
- Reading uninitialized rows at bottom of active area
- Race condition between VT parser updating and renderer reading
- Incorrect handling of the viewport/active area boundary
- Style ID lookup returning garbage for some cells

## Code Locations

- `src/mux/render.zig` - Renderer that generates escape sequences
- `src/mux/pane.zig` - Pane wrapper around ghostty VT
- `src/mux/main.zig` - Main loop, handles I/O and rendering
- `src/core/pty.zig` - PTY spawning (sets `TERM=xterm-256color`)

## Cell Reading Code

```zig
const cell_result = pages.getCell(.{ .viewport = .{ .x = x, .y = y } });

if (cell_result) |cell_info| {
    const cell = cell_info.cell.*;
    const page = cell_info.node.data;

    render_cell.char = cell.codepoint();

    if (cell.style_id != 0) {
        const style = page.styles.get(page.memory, cell.style_id);
        // ... extract colors and attributes
    }
}
```

## Questions to Investigate

1. Is `pages.getCell()` returning valid data for all viewport positions?
2. Are there uninitialized rows at the bottom of the active area?
3. Is `style_id` ever invalid, causing garbage style lookups?
4. Is there a race between the VT parser and renderer?
5. Should we be using a different API to read the screen content?
6. Does ghostty have a "safe" way to snapshot the screen for rendering?

## Environment

- Platform: Linux
- Build: Zig with ReleaseFast optimization
- VT Parser: ghostty-vt library
- Inner TERM: xterm-256color
