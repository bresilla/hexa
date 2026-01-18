const std = @import("std");
const posix = std.posix;
const core = @import("core");
const pop = @import("pop");

const Pane = @import("pane.zig").Pane;
const Layout = @import("layout.zig").Layout;
const SplitDir = @import("layout.zig").SplitDir;
const render = @import("render.zig");
const Renderer = render.Renderer;

const c = @cImport({
    @cInclude("sys/ioctl.h");
});

/// A tab contains a layout with panes
const Tab = struct {
    layout: Layout,
    name: []const u8,

    fn init(allocator: std.mem.Allocator, width: u16, height: u16, name: []const u8) Tab {
        return .{
            .layout = Layout.init(allocator, width, height),
            .name = name,
        };
    }

    fn deinit(self: *Tab) void {
        self.layout.deinit();
    }
};

const State = struct {
    allocator: std.mem.Allocator,
    config: core.Config,
    tabs: std.ArrayList(Tab),
    active_tab: usize,
    floating_panes: std.ArrayList(*Pane),
    active_floating: ?usize,
    running: bool,
    needs_render: bool,
    force_full_render: bool,
    term_width: u16,
    term_height: u16,
    status_height: u16,
    layout_width: u16,
    layout_height: u16,
    renderer: Renderer,

    fn init(allocator: std.mem.Allocator, width: u16, height: u16) !State {
        const cfg = core.Config.load(allocator);
        const status_h: u16 = if (cfg.status.enabled) 1 else 0;
        const layout_h = height - status_h;
        return .{
            .allocator = allocator,
            .config = cfg,
            .tabs = .empty,
            .active_tab = 0,
            .floating_panes = .empty,
            .active_floating = null,
            .running = true,
            .needs_render = true,
            .force_full_render = true,
            .term_width = width,
            .term_height = height,
            .status_height = status_h,
            .layout_width = width,
            .layout_height = layout_h,
            .renderer = try Renderer.init(allocator, width, height),
        };
    }

    fn deinit(self: *State) void {
        // Deinit floating panes
        for (self.floating_panes.items) |pane| {
            pane.deinit();
            self.allocator.destroy(pane);
        }
        self.floating_panes.deinit(self.allocator);
        // Deinit all tabs
        for (self.tabs.items) |*tab| {
            tab.deinit();
        }
        self.tabs.deinit(self.allocator);
        self.config.deinit();
        self.renderer.deinit();
    }

    /// Get the current tab's layout
    fn currentLayout(self: *State) *Layout {
        return &self.tabs.items[self.active_tab].layout;
    }

    /// Create a new tab with one pane
    fn createTab(self: *State) !void {
        var tab = Tab.init(self.allocator, self.layout_width, self.layout_height, "tab");
        _ = try tab.layout.createFirstPane();
        try self.tabs.append(self.allocator, tab);
        self.active_tab = self.tabs.items.len - 1;
        self.renderer.invalidate();
        self.force_full_render = true;
    }

    /// Close the current tab
    fn closeCurrentTab(self: *State) bool {
        if (self.tabs.items.len <= 1) return false;
        var tab = self.tabs.orderedRemove(self.active_tab);
        tab.deinit();
        if (self.active_tab >= self.tabs.items.len) {
            self.active_tab = self.tabs.items.len - 1;
        }
        self.renderer.invalidate();
        self.force_full_render = true;
        return true;
    }

    /// Switch to next tab
    fn nextTab(self: *State) void {
        if (self.tabs.items.len > 1) {
            self.active_tab = (self.active_tab + 1) % self.tabs.items.len;
            self.renderer.invalidate();
            self.force_full_render = true;
        }
    }

    /// Switch to previous tab
    fn prevTab(self: *State) void {
        if (self.tabs.items.len > 1) {
            self.active_tab = if (self.active_tab == 0) self.tabs.items.len - 1 else self.active_tab - 1;
            self.renderer.invalidate();
            self.force_full_render = true;
        }
    }
};

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    // Redirect stderr to /dev/null to suppress ghostty warnings
    // that would otherwise corrupt the display
    const devnull = std.fs.openFileAbsolute("/dev/null", .{ .mode = .write_only }) catch null;
    if (devnull) |f| {
        posix.dup2(f.handle, posix.STDERR_FILENO) catch {};
        f.close();
    }

    // Get terminal size
    const size = getTermSize();

    // Initialize state
    var state = try State.init(allocator, size.cols, size.rows);
    defer state.deinit();

    // Create first tab with one pane
    try state.createTab();

    // Enter raw mode
    const orig_termios = try enableRawMode(posix.STDIN_FILENO);
    defer disableRawMode(posix.STDIN_FILENO, orig_termios) catch {};

    // Enter alternate screen and reset it
    const stdout = std.fs.File.stdout();
    // Sequence:
    // ESC[?1049h    - Enter alternate screen buffer (FIRST - before any reset)
    // ESC[2J        - Clear entire alternate screen
    // ESC[H         - Cursor to home position (1,1)
    // ESC[0m        - Reset all SGR attributes
    // ESC(B         - Set G0 charset to ASCII (US-ASCII)
    // ESC)0         - Set G1 charset to DEC Special Graphics
    // SI (0x0F)     - Shift In - select G0 charset
    // ESC[?25l      - Hide cursor
    // ESC[?1000h    - Enable mouse click tracking
    // ESC[?1006h    - Enable SGR mouse mode
    // Also clear scrollback (CSI 3 J) so we don't see prior content.
    try stdout.writeAll("\x1b[?1049h\x1b[2J\x1b[3J\x1b[H\x1b[0m\x1b(B\x1b)0\x0f\x1b[?25l\x1b[?1000h\x1b[?1006h");
    // On exit: disable mouse, show cursor, reset attributes, leave alternate screen
    defer stdout.writeAll("\x1b[?1006l\x1b[?1000l\x1b[0m\x1b[?25h\x1b[?1049l") catch {};

    // Build poll fds
    var poll_fds: [17]posix.pollfd = undefined; // stdin + up to 16 panes
    var buffer: [32768]u8 = undefined; // Larger buffer for efficiency

    // Frame timing
    var last_render: i64 = std.time.milliTimestamp();

    // Main loop
    while (state.running) {
        // Check for terminal resize
        {
            const new_size = getTermSize();
            if (new_size.cols != state.term_width or new_size.rows != state.term_height) {
                state.term_width = new_size.cols;
                state.term_height = new_size.rows;
                const status_h: u16 = if (state.config.status.enabled) 1 else 0;
                state.status_height = status_h;
                state.layout_width = new_size.cols;
                state.layout_height = new_size.rows - status_h;

                // Resize all tabs
                for (state.tabs.items) |*tab| {
                    tab.layout.resize(state.layout_width, state.layout_height);
                }

                // Resize floating panes based on their stored percentages
                resizeFloatingPanes(&state);

                // Resize renderer and force full redraw
                state.renderer.resize(new_size.cols, new_size.rows) catch {};
                state.renderer.invalidate();
                state.needs_render = true;
                state.force_full_render = true;
            }
        }

        // Proactively check for dead floating panes before polling
        {
            var fi: usize = 0;
            while (fi < state.floating_panes.items.len) {
                if (!state.floating_panes.items[fi].isAlive()) {
                    // Check if this was the active float
                    const was_active = if (state.active_floating) |af| af == fi else false;

                    const pane = state.floating_panes.orderedRemove(fi);
                    pane.deinit();
                    state.allocator.destroy(pane);
                    state.needs_render = true;

                    // Clear focus if this was the active float
                    if (was_active) {
                        state.active_floating = null;
                    }
                    // Don't increment fi, next item shifted into this position
                } else {
                    fi += 1;
                }
            }
            // Ensure active_floating is valid
            if (state.active_floating) |af| {
                if (af >= state.floating_panes.items.len) {
                    state.active_floating = if (state.floating_panes.items.len > 0)
                        state.floating_panes.items.len - 1
                    else
                        null;
                }
            }
        }

        // Check for dead tiled panes in current tab
        {
            var any_dead = false;
            var pane_it = state.currentLayout().paneIterator();
            while (pane_it.next()) |pane| {
                if (!pane.*.isAlive()) {
                    any_dead = true;
                    break;
                }
            }
            if (any_dead) {
                if (state.currentLayout().paneCount() > 1) {
                    // Multiple panes in tab - just close this one
                    _ = state.currentLayout().closeFocused();
                    state.needs_render = true;
                } else if (state.tabs.items.len > 1) {
                    // Only 1 pane but multiple tabs - close this tab
                    _ = state.closeCurrentTab();
                    state.needs_render = true;
                } else {
                    // Last pane in last tab - exit
                    state.running = false;
                    continue;
                }
            }
        }

        // Build poll list: stdin + all pane PTYs
        var fd_count: usize = 1;
        poll_fds[0] = .{ .fd = posix.STDIN_FILENO, .events = posix.POLL.IN, .revents = 0 };

        var pane_it = state.currentLayout().paneIterator();
        while (pane_it.next()) |pane| {
            if (fd_count < poll_fds.len) {
                poll_fds[fd_count] = .{ .fd = pane.*.getFd(), .events = posix.POLL.IN, .revents = 0 };
                fd_count += 1;
            }
        }

        // Add floating panes
        for (state.floating_panes.items) |pane| {
            if (fd_count < poll_fds.len) {
                poll_fds[fd_count] = .{ .fd = pane.getFd(), .events = posix.POLL.IN, .revents = 0 };
                fd_count += 1;
            }
        }

        // Calculate poll timeout - wait for next frame or input
        const now = std.time.milliTimestamp();
        const since_render = now - last_render;
        const timeout: i32 = if (!state.needs_render) 100 else if (since_render >= 16) 0 else @intCast(16 - since_render);
        _ = posix.poll(poll_fds[0..fd_count], timeout) catch continue;

        // Handle stdin
        if (poll_fds[0].revents & posix.POLL.IN != 0) {
            const n = posix.read(posix.STDIN_FILENO, &buffer) catch break;
            if (n == 0) break;
            handleInput(&state, buffer[0..n]);
        }

        // Handle PTY output
        var idx: usize = 1;
        var dead_panes: std.ArrayList(u16) = .empty;
        defer dead_panes.deinit(allocator);

        pane_it = state.currentLayout().paneIterator();
        while (pane_it.next()) |pane| {
            if (idx < fd_count) {
                if (poll_fds[idx].revents & posix.POLL.IN != 0) {
                    if (pane.*.poll(&buffer)) |had_data| {
                        if (had_data) state.needs_render = true;
                        if (pane.*.did_clear) {
                            state.force_full_render = true;
                            state.renderer.invalidate();
                        }
                    } else |_| {}
                }
                if (poll_fds[idx].revents & posix.POLL.HUP != 0) {
                    dead_panes.append(allocator, pane.*.id) catch {};
                }
                idx += 1;
            }
        }

        // Handle floating pane output
        var dead_floating: std.ArrayList(usize) = .empty;
        defer dead_floating.deinit(allocator);

        for (state.floating_panes.items, 0..) |pane, fi| {
            if (idx < fd_count) {
                if (poll_fds[idx].revents & posix.POLL.IN != 0) {
                    if (pane.poll(&buffer)) |had_data| {
                        if (had_data) state.needs_render = true;
                        if (pane.did_clear) {
                            state.force_full_render = true;
                            state.renderer.invalidate();
                        }
                    } else |_| {}
                }
                if (poll_fds[idx].revents & posix.POLL.HUP != 0) {
                    dead_floating.append(allocator, fi) catch {};
                }
                idx += 1;
            }
        }

        // Remove dead floating panes (in reverse order to preserve indices)
        var i: usize = dead_floating.items.len;
        while (i > 0) {
            i -= 1;
            const fi = dead_floating.items[i];
            // Check if this was the active float before removing
            const was_active = if (state.active_floating) |af| af == fi else false;

            const pane = state.floating_panes.orderedRemove(fi);
            pane.deinit();
            state.allocator.destroy(pane);
            state.needs_render = true;

            // Clear focus if this was the active float
            if (was_active) {
                state.active_floating = null;
            }
        }
        // Ensure active_floating is still valid
        if (state.active_floating) |af| {
            if (af >= state.floating_panes.items.len) {
                state.active_floating = null;
            }
        }

        // Remove dead panes
        for (dead_panes.items) |_| {
            if (state.currentLayout().paneCount() > 1) {
                // Multiple panes in tab - just close this one
                _ = state.currentLayout().closeFocused();
                state.needs_render = true;
            } else if (state.tabs.items.len > 1) {
                // Only 1 pane but multiple tabs - close this tab
                _ = state.closeCurrentTab();
                state.needs_render = true;
            } else {
                // Last pane in last tab - exit
                state.running = false;
            }
        }

        // Render with frame rate limiting (max 60fps)
        if (state.needs_render) {
            const render_now = std.time.milliTimestamp();
            if (render_now - last_render >= 16) { // ~60fps
                renderTo(&state, stdout) catch {};
                state.needs_render = false;
                state.force_full_render = false;
                last_render = render_now;
            }
        }
    }
}

fn handleInput(state: *State, input: []const u8) void {
    var i: usize = 0;
    while (i < input.len) {
        // Check for Alt+key (ESC followed by key)
        if (input[i] == 0x1b and i + 1 < input.len) {
            const next = input[i + 1];
            // Check for CSI sequences (ESC [)
            if (next == '[' and i + 2 < input.len) {
                // Handle scroll keys
                if (handleScrollKeys(state, input[i..])) |consumed| {
                    i += consumed;
                    continue;
                }
            }
            // Make sure it's not an actual escape sequence (like arrow keys)
            if (next != '[' and next != 'O') {
                if (handleAltKey(state, next)) {
                    i += 2;
                    continue;
                }
            }
        }

        // Check for Ctrl+Q to quit
        if (input[i] == 0x11) {
            state.running = false;
            return;
        }

        // If pane is scrolled and user types, scroll to bottom first
        if (state.active_floating) |idx| {
            const fpane = state.floating_panes.items[idx];
            if (fpane.visible) {
                if (fpane.isScrolled()) {
                    fpane.scrollToBottom();
                    state.needs_render = true;
                }
                fpane.write(input[i..]) catch {};
            }
        } else if (state.currentLayout().getFocusedPane()) |pane| {
            if (pane.isScrolled()) {
                pane.scrollToBottom();
                state.needs_render = true;
            }
            pane.write(input[i..]) catch {};
        }
        return;
    }
}

/// Handle scroll-related escape sequences
/// Returns number of bytes consumed, or null if not a scroll sequence
fn handleScrollKeys(state: *State, input: []const u8) ?usize {
    // Must start with ESC [
    if (input.len < 3 or input[0] != 0x1b or input[1] != '[') return null;

    // Get the focused pane
    const pane = if (state.active_floating) |idx|
        state.floating_panes.items[idx]
    else
        state.currentLayout().getFocusedPane() orelse return null;

    // SGR mouse wheel: ESC [ < 64 ; x ; y M (up) or ESC [ < 65 ; x ; y M (down)
    if (input.len >= 4 and input[2] == '<') {
        // Find the 'M' or 'm' terminator
        var end: usize = 3;
        while (end < input.len and input[end] != 'M' and input[end] != 'm') : (end += 1) {}
        if (end >= input.len) return null;

        // Parse button number (first number after '<')
        var btn: u8 = 0;
        var i: usize = 3;
        while (i < end and input[i] >= '0' and input[i] <= '9') : (i += 1) {
            btn = btn * 10 + (input[i] - '0');
        }

        // Button 64 = wheel up, 65 = wheel down
        if (btn == 64) {
            pane.scrollUp(3);
            state.needs_render = true;
            return end + 1;
        } else if (btn == 65) {
            pane.scrollDown(3);
            state.needs_render = true;
            return end + 1;
        }
        // Other mouse events - consume but don't act
        return end + 1;
    }

    // Page Up: ESC [ 5 ~
    if (input.len >= 4 and input[2] == '5' and input[3] == '~') {
        pane.scrollUp(pane.height / 2);
        state.needs_render = true;
        return 4;
    }

    // Page Down: ESC [ 6 ~
    if (input.len >= 4 and input[2] == '6' and input[3] == '~') {
        pane.scrollDown(pane.height / 2);
        state.needs_render = true;
        return 4;
    }

    // Shift+Page Up: ESC [ 5 ; 2 ~
    if (input.len >= 6 and input[2] == '5' and input[3] == ';' and input[4] == '2' and input[5] == '~') {
        pane.scrollUp(pane.height);
        state.needs_render = true;
        return 6;
    }

    // Shift+Page Down: ESC [ 6 ; 2 ~
    if (input.len >= 6 and input[2] == '6' and input[3] == ';' and input[4] == '2' and input[5] == '~') {
        pane.scrollDown(pane.height);
        state.needs_render = true;
        return 6;
    }

    // Home (scroll to top): ESC [ H or ESC [ 1 ~
    if (input.len >= 3 and input[2] == 'H') {
        pane.scrollToTop();
        state.needs_render = true;
        return 3;
    }
    if (input.len >= 4 and input[2] == '1' and input[3] == '~') {
        pane.scrollToTop();
        state.needs_render = true;
        return 4;
    }

    // End (scroll to bottom): ESC [ F or ESC [ 4 ~
    if (input.len >= 3 and input[2] == 'F') {
        pane.scrollToBottom();
        state.needs_render = true;
        return 3;
    }
    if (input.len >= 4 and input[2] == '4' and input[3] == '~') {
        pane.scrollToBottom();
        state.needs_render = true;
        return 4;
    }

    // Shift+Up: ESC [ 1 ; 2 A - scroll up one line
    if (input.len >= 6 and input[2] == '1' and input[3] == ';' and input[4] == '2' and input[5] == 'A') {
        pane.scrollUp(1);
        state.needs_render = true;
        return 6;
    }

    // Shift+Down: ESC [ 1 ; 2 B - scroll down one line
    if (input.len >= 6 and input[2] == '1' and input[3] == ';' and input[4] == '2' and input[5] == 'B') {
        pane.scrollDown(1);
        state.needs_render = true;
        return 6;
    }

    return null;
}

fn handleAltKey(state: *State, key: u8) bool {
    const cfg = &state.config;

    if (key == cfg.key_quit) {
        state.running = false;
        return true;
    }

    if (key == cfg.key_split_h) {
        _ = state.currentLayout().splitFocused(.horizontal) catch null;
        state.needs_render = true;
        return true;
    }

    if (key == cfg.key_split_v) {
        _ = state.currentLayout().splitFocused(.vertical) catch null;
        state.needs_render = true;
        return true;
    }

    // Alt+t = new tab
    if (key == cfg.key_new_pane) {
        state.active_floating = null;
        state.createTab() catch {};
        state.needs_render = true;
        return true;
    }

    // Alt+n = next tab
    if (key == cfg.key_next_pane) {
        state.active_floating = null;
        state.nextTab();
        state.needs_render = true;
        return true;
    }

    // Alt+p = previous tab
    if (key == cfg.key_prev_pane) {
        state.active_floating = null;
        state.prevTab();
        state.needs_render = true;
        return true;
    }

    // Alt+x or Alt+w = close current tab (or quit if last tab)
    if (key == cfg.key_close_pane or key == 'w') {
        if (state.active_floating) |idx| {
            const pane = state.floating_panes.orderedRemove(idx);
            pane.deinit();
            state.allocator.destroy(pane);
            state.active_floating = if (state.floating_panes.items.len > 0) 0 else null;
        } else {
            // Close current tab, or quit if it's the last one
            if (!state.closeCurrentTab()) {
                state.running = false;
            }
        }
        state.needs_render = true;
        return true;
    }

    // Alt+space - toggle floating focus (always space)
    if (key == ' ') {
        if (state.floating_panes.items.len > 0) {
            if (state.active_floating) |_| {
                state.active_floating = null;
            } else {
                state.active_floating = 0;
            }
            state.needs_render = true;
        }
        return true;
    }

    // Check for named float keys from config
    if (cfg.getFloatByKey(key)) |float_def| {
        toggleNamedFloat(state, float_def);
        state.needs_render = true;
        return true;
    }

    return false;
}

fn toggleNamedFloat(state: *State, float_def: *const core.FloatDef) void {
    // Get current directory from focused pane (for pwd floats)
    // Use getRealCwd which reads /proc/<pid>/cwd for accurate directory
    var current_dir: ?[]const u8 = null;
    if (state.currentLayout().getFocusedPane()) |focused| {
        current_dir = focused.getRealCwd();
    }

    // Find existing float by key (and directory if pwd)
    for (state.floating_panes.items, 0..) |pane, i| {
        if (pane.float_key == float_def.key) {
            // For pwd floats, also check directory match
            if (float_def.pwd and pane.is_pwd) {
                // Both dirs must exist and match, or both be null
                const dirs_match = if (pane.pwd_dir) |pane_dir| blk: {
                    if (current_dir) |curr| {
                        break :blk std.mem.eql(u8, pane_dir, curr);
                    }
                    break :blk false;
                } else current_dir == null;

                if (!dirs_match) continue;
            }

            // Toggle visibility
            pane.visible = !pane.visible;
            if (pane.visible) {
                state.active_floating = i;
                // If alone mode, hide all other floats
                if (float_def.alone) {
                    for (state.floating_panes.items) |other| {
                        if (other.float_key != float_def.key) {
                            other.visible = false;
                        }
                    }
                }
                // For pwd floats, hide other instances of same float (different dirs)
                if (float_def.pwd) {
                    for (state.floating_panes.items, 0..) |other, j| {
                        if (j != i and other.float_key == float_def.key) {
                            other.visible = false;
                        }
                    }
                }
            } else {
                state.active_floating = null;
            }
            return;
        }
    }

    // Not found - create new float
    createNamedFloat(state, float_def, current_dir) catch {};

    // If alone mode, hide all other floats after creation
    if (float_def.alone) {
        for (state.floating_panes.items) |pane| {
            if (pane.float_key != float_def.key) {
                pane.visible = false;
            }
        }
    }
    // For pwd floats, hide other instances of same float (different dirs)
    if (float_def.pwd) {
        const new_idx = state.floating_panes.items.len - 1;
        for (state.floating_panes.items, 0..) |pane, i| {
            if (i != new_idx and pane.float_key == float_def.key) {
                pane.visible = false;
            }
        }
    }
}

fn resizeFloatingPanes(state: *State) void {
    const avail_h = state.term_height - state.status_height;

    for (state.floating_panes.items) |pane| {
        // Recalculate outer frame size based on stored percentages
        const outer_w: u16 = state.term_width * pane.float_width_pct / 100;
        const outer_h: u16 = avail_h * pane.float_height_pct / 100;

        // Recalculate position
        const max_x = state.term_width -| outer_w;
        const max_y = avail_h -| outer_h;
        const outer_x: u16 = max_x * pane.float_pos_x_pct / 100;
        const outer_y: u16 = max_y * pane.float_pos_y_pct / 100;

        // Calculate content area
        const pad_x: u16 = 1 + pane.float_pad_x;
        const pad_y: u16 = 1 + pane.float_pad_y;
        const content_x = outer_x + pad_x;
        const content_y = outer_y + pad_y;
        const content_w = outer_w -| (pad_x * 2);
        const content_h = outer_h -| (pad_y * 2);

        // Update pane position and size
        pane.resize(content_x, content_y, content_w, content_h) catch {};

        // Update border dimensions
        pane.border_x = outer_x;
        pane.border_y = outer_y;
        pane.border_w = outer_w;
        pane.border_h = outer_h;
    }
}

fn createNamedFloat(state: *State, float_def: *const core.FloatDef, current_dir: ?[]const u8) !void {
    const pane = try state.allocator.create(Pane);
    errdefer state.allocator.destroy(pane);

    const cfg = &state.config;

    // Use per-float settings or fall back to defaults
    const width_pct: u16 = float_def.width_percent orelse cfg.float_width_percent;
    const height_pct: u16 = float_def.height_percent orelse cfg.float_height_percent;
    const pos_x_pct: u16 = float_def.pos_x orelse 50; // default center
    const pos_y_pct: u16 = float_def.pos_y orelse 50; // default center
    const pad_x_cfg: u16 = float_def.padding_x orelse cfg.float_padding_x;
    const pad_y_cfg: u16 = float_def.padding_y orelse cfg.float_padding_y;
    const border_color: u8 = if (float_def.style) |s| s.color else cfg.float_border_color;

    // Calculate outer frame size
    const avail_h = state.term_height - state.status_height;
    const outer_w = state.term_width * width_pct / 100;
    const outer_h = avail_h * height_pct / 100;

    // Calculate position based on pos_x/pos_y percentages
    // 0% = left/top edge, 50% = centered, 100% = right/bottom edge
    const max_x = state.term_width -| outer_w;
    const max_y = avail_h -| outer_h;
    const outer_x = max_x * pos_x_pct / 100;
    const outer_y = max_y * pos_y_pct / 100;

    // Content area: 1 cell border + configurable padding
    const pad_x: u16 = 1 + pad_x_cfg;
    const pad_y: u16 = 1 + pad_y_cfg;
    const content_x = outer_x + pad_x;
    const content_y = outer_y + pad_y;
    const content_w = outer_w -| (pad_x * 2);
    const content_h = outer_h -| (pad_y * 2);

    const id: u16 = @intCast(100 + state.floating_panes.items.len);
    try pane.initWithCommand(state.allocator, id, content_x, content_y, content_w, content_h, float_def.command);
    pane.floating = true;
    pane.focused = true;
    pane.visible = true;
    pane.float_key = float_def.key;
    // Store outer dimensions and style for border rendering
    pane.border_x = outer_x;
    pane.border_y = outer_y;
    pane.border_w = outer_w;
    pane.border_h = outer_h;
    pane.border_color = border_color;
    // Store percentages for resize recalculation
    pane.float_width_pct = @intCast(width_pct);
    pane.float_height_pct = @intCast(height_pct);
    pane.float_pos_x_pct = @intCast(pos_x_pct);
    pane.float_pos_y_pct = @intCast(pos_y_pct);
    pane.float_pad_x = @intCast(pad_x_cfg);
    pane.float_pad_y = @intCast(pad_y_cfg);

    // For pwd floats, store the directory and duplicate it
    if (float_def.pwd) {
        pane.is_pwd = true;
        if (current_dir) |dir| {
            pane.pwd_dir = state.allocator.dupe(u8, dir) catch null;
        }
    }

    // Store style reference (includes border and optional module)
    if (float_def.style) |*style| {
        pane.float_style = style;
        pane.border_color = style.color;
    }

    try state.floating_panes.append(state.allocator, pane);
    state.active_floating = state.floating_panes.items.len - 1;
}

fn renderTo(state: *State, stdout: std.fs.File) !void {
    const renderer = &state.renderer;

    // Begin a new frame
    renderer.beginFrame();

    // Draw tiled panes into the cell buffer
    var pane_it = state.currentLayout().paneIterator();
    while (pane_it.next()) |pane| {
        const render_state = pane.*.getRenderState() catch continue;
        renderer.drawRenderState(render_state, pane.*.x, pane.*.y, pane.*.width, pane.*.height);

        const is_scrolled = pane.*.isScrolled();

        // Draw scroll indicator if pane is scrolled
        if (is_scrolled) {
            drawScrollIndicator(renderer, pane.*.x, pane.*.y, pane.*.width);
        }
    }

    // Draw split borders when there are multiple panes
    if (state.currentLayout().paneCount() > 1) {
        drawSplitBorders(state, renderer);
    }

    // Draw visible floating panes (on top of tiled panes)
    // Draw inactive floats first, then active one last so it's on top
    for (state.floating_panes.items, 0..) |pane, i| {
        if (!pane.visible) continue;
        if (state.active_floating == i) continue; // Skip active, draw it last

        drawFloatingBorder(renderer, pane.border_x, pane.border_y, pane.border_w, pane.border_h, false, "", pane.border_color, pane.float_style);

        const render_state = pane.getRenderState() catch continue;
        renderer.drawRenderState(render_state, pane.x, pane.y, pane.width, pane.height);

        if (pane.isScrolled()) {
            drawScrollIndicator(renderer, pane.x, pane.y, pane.width);
        }
    }

    // Draw active float last so it's on top
    if (state.active_floating) |idx| {
        const pane = state.floating_panes.items[idx];
        if (pane.visible) {
            drawFloatingBorder(renderer, pane.border_x, pane.border_y, pane.border_w, pane.border_h, true, "", pane.border_color, pane.float_style);

            if (pane.getRenderState()) |render_state| {
                renderer.drawRenderState(render_state, pane.x, pane.y, pane.width, pane.height);
            } else |_| {}

            if (pane.isScrolled()) {
                drawScrollIndicator(renderer, pane.x, pane.y, pane.width);
            }
        }
    }

    // Draw status bar if enabled
    if (state.config.status.enabled) {
        drawStatusBar(state, renderer);
    }

    // End frame with differential render
    const output = try renderer.endFrame(state.force_full_render);

    // Get cursor info
    var cursor_x: u16 = 1;
    var cursor_y: u16 = 1;
    var cursor_style: u8 = 0;
    var cursor_visible: bool = true;

    if (state.active_floating) |idx| {
        const pane = state.floating_panes.items[idx];
        const pos = pane.getCursorPos();
        cursor_x = pos.x + 1;
        cursor_y = pos.y + 1;
        cursor_style = pane.getCursorStyle();
        cursor_visible = pane.isCursorVisible();
    } else if (state.currentLayout().getFocusedPane()) |pane| {
        const pos = pane.getCursorPos();
        cursor_x = pos.x + 1;
        cursor_y = pos.y + 1;
        cursor_style = pane.getCursorStyle();
        cursor_visible = pane.isCursorVisible();
    }

    // Build cursor sequences
    var cursor_buf: [64]u8 = undefined;
    var cursor_len: usize = 0;

    const style_seq = std.fmt.bufPrint(cursor_buf[cursor_len..], "\x1b[{d} q", .{cursor_style}) catch "";
    cursor_len += style_seq.len;

    const pos_seq = std.fmt.bufPrint(cursor_buf[cursor_len..], "\x1b[{d};{d}H", .{ cursor_y, cursor_x }) catch "";
    cursor_len += pos_seq.len;

    if (cursor_visible) {
        const show_seq = "\x1b[?25h";
        @memcpy(cursor_buf[cursor_len..][0..show_seq.len], show_seq);
        cursor_len += show_seq.len;
    }

    // Write everything as a single iovec list.
    //
    // IMPORTANT: terminal writes can be partial. If we don't fully flush the
    // whole frame, the outer terminal can see truncated CSI/SGR sequences,
    // which matches the observed "38;5;240m" / "[m" garbage artifacts.
    var iovecs = [_]std.posix.iovec_const{
        .{ .base = output.ptr, .len = output.len },
        .{ .base = &cursor_buf, .len = cursor_len },
    };
    try stdout.writevAll(iovecs[0..]);
}

fn drawSplitBorders(state: *State, renderer: *Renderer) void {
    const border_cell = render.Cell{
        .char = '│',
        .fg = .{ .palette = 8 }, // gray
    };
    const h_border_cell = render.Cell{
        .char = '─',
        .fg = .{ .palette = 8 }, // gray
    };

    // Find split lines by checking pane boundaries
    var pane_it = state.currentLayout().paneIterator();
    while (pane_it.next()) |pane| {
        const right_edge = pane.*.x + pane.*.width;
        const bottom_edge = pane.*.y + pane.*.height;

        // Draw vertical separator if pane doesn't reach right edge
        if (right_edge < state.term_width) {
            for (0..pane.*.height) |row| {
                renderer.setCell(right_edge, pane.*.y + @as(u16, @intCast(row)), border_cell);
            }
        }

        // Draw horizontal separator if pane doesn't reach bottom
        if (bottom_edge < state.term_height - state.status_height) {
            for (0..pane.*.width) |col| {
                renderer.setCell(pane.*.x + @as(u16, @intCast(col)), bottom_edge, h_border_cell);
            }
        }
    }
}

fn drawScrollIndicator(renderer: *Renderer, pane_x: u16, pane_y: u16, pane_width: u16) void {
    // Display a scroll indicator at top-right of pane
    const indicator = " \xe2\x96\xb2\xe2\x96\xb2\xe2\x96\xb2 "; // " ▲▲▲ "
    const indicator_chars = [_]u21{ ' ', 0x25b2, 0x25b2, 0x25b2, ' ' };

    // Position at top-right corner (inside pane bounds)
    const indicator_len: u16 = 5;
    const x_pos = pane_x + pane_width -| indicator_len;

    // Yellow background (palette 3), black text (palette 0)
    for (indicator_chars, 0..) |char, i| {
        renderer.setCell(x_pos + @as(u16, @intCast(i)), pane_y, .{
            .char = char,
            .fg = .{ .palette = 0 }, // black
            .bg = .{ .palette = 3 }, // yellow
        });
    }
    _ = indicator;
}

fn drawFloatingBorder(renderer: *Renderer, x: u16, y: u16, w: u16, h: u16, active: bool, name: []const u8, border_color: u8, style: ?*const core.FloatStyle) void {
    const fg: render.Color = .{ .palette = border_color };
    const bold = active;

    // Get border characters from style or use defaults
    const top_left: u21 = if (style) |s| s.top_left else 0x256D;
    const top_right: u21 = if (style) |s| s.top_right else 0x256E;
    const bottom_left: u21 = if (style) |s| s.bottom_left else 0x2570;
    const bottom_right: u21 = if (style) |s| s.bottom_right else 0x256F;
    const horizontal: u21 = if (style) |s| s.horizontal else 0x2500;
    const vertical: u21 = if (style) |s| s.vertical else 0x2502;

    // Clear the interior with spaces first
    for (1..h -| 1) |row| {
        for (1..w -| 1) |col| {
            renderer.setCell(x + @as(u16, @intCast(col)), y + @as(u16, @intCast(row)), .{
                .char = ' ',
            });
        }
    }

    // Top-left corner
    renderer.setCell(x, y, .{ .char = top_left, .fg = fg, .bold = bold });

    // Top border with optional title (centered)
    if (name.len > 0) {
        var title_buf: [32]u8 = undefined;
        const title = std.fmt.bufPrint(&title_buf, "[ {s} ]", .{name}) catch "[ float ]";
        const title_start = @as(usize, (w -| 2) -| title.len) / 2;

        for (0..w -| 2) |col| {
            const char: u21 = if (col >= title_start and col < title_start + title.len)
                title[col - title_start]
            else
                horizontal;
            renderer.setCell(x + @as(u16, @intCast(col)) + 1, y, .{ .char = char, .fg = fg, .bold = bold });
        }
    } else {
        for (0..w -| 2) |col| {
            renderer.setCell(x + @as(u16, @intCast(col)) + 1, y, .{ .char = horizontal, .fg = fg, .bold = bold });
        }
    }

    // Top-right corner
    renderer.setCell(x + w - 1, y, .{ .char = top_right, .fg = fg, .bold = bold });

    // Side borders
    for (1..h -| 1) |row| {
        renderer.setCell(x, y + @as(u16, @intCast(row)), .{ .char = vertical, .fg = fg, .bold = bold });
        renderer.setCell(x + w - 1, y + @as(u16, @intCast(row)), .{ .char = vertical, .fg = fg, .bold = bold });
    }

    // Bottom-left corner
    renderer.setCell(x, y + h - 1, .{ .char = bottom_left, .fg = fg, .bold = bold });

    // Bottom border
    for (0..w -| 2) |col| {
        renderer.setCell(x + @as(u16, @intCast(col)) + 1, y + h - 1, .{ .char = horizontal, .fg = fg, .bold = bold });
    }

    // Bottom-right corner
    renderer.setCell(x + w - 1, y + h - 1, .{ .char = bottom_right, .fg = fg, .bold = bold });

    // Render module in border if present
    if (style) |s| {
        if (s.module) |*module| {
            if (s.position) |pos| {
                // Run the module to get output
                var output_buf: [256]u8 = undefined;
                const output = runStatusModule(module, &output_buf) catch "";
                if (output.len == 0) return;

                // Render styled output
                const segments = renderModuleOutput(module, output);

                // Calculate position based on style position
                const total_len = segments.total_len;
                var draw_x: u16 = undefined;
                var draw_y: u16 = undefined;

                switch (pos) {
                    .topleft => {
                        draw_x = x + 2;
                        draw_y = y;
                    },
                    .topcenter => {
                        draw_x = x + @as(u16, @intCast((w -| total_len) / 2));
                        draw_y = y;
                    },
                    .topright => {
                        draw_x = x + w -| 2 -| @as(u16, @intCast(total_len));
                        draw_y = y;
                    },
                    .bottomleft => {
                        draw_x = x + 2;
                        draw_y = y + h - 1;
                    },
                    .bottomcenter => {
                        draw_x = x + @as(u16, @intCast((w -| total_len) / 2));
                        draw_y = y + h - 1;
                    },
                    .bottomright => {
                        draw_x = x + w -| 2 -| @as(u16, @intCast(total_len));
                        draw_y = y + h - 1;
                    },
                }

                // Draw each segment with its style
                var cur_x = draw_x;
                for (segments.items[0..segments.count]) |seg| {
                    for (seg.text) |ch| {
                        renderer.setCell(cur_x, draw_y, .{
                            .char = ch,
                            .fg = seg.fg,
                            .bg = seg.bg,
                            .bold = seg.bold,
                            .italic = seg.italic,
                        });
                        cur_x += 1;
                    }
                }
            }
        }
    }
}

const RenderedSegment = struct {
    text: []const u8,
    fg: render.Color,
    bg: render.Color,
    bold: bool,
    italic: bool,
};

const RenderedSegments = struct {
    items: [16]RenderedSegment,
    buffers: [16][64]u8, // Each segment gets its own buffer
    count: usize,
    total_len: usize,
};

fn renderModuleOutput(module: *const core.StatusModule, output: []const u8) RenderedSegments {
    var result = RenderedSegments{
        .items = undefined,
        .buffers = undefined,
        .count = 0,
        .total_len = 0,
    };

    for (module.outputs) |out| {
        if (result.count >= 16) break;

        // Replace $output in format with actual output
        var text_len: usize = 0;
        var i: usize = 0;
        while (i < out.format.len and text_len < 64) {
            if (i + 6 < out.format.len and std.mem.eql(u8, out.format[i .. i + 7], "$output")) {
                const copy_len = @min(output.len, 64 - text_len);
                @memcpy(result.buffers[result.count][text_len .. text_len + copy_len], output[0..copy_len]);
                text_len += copy_len;
                i += 7;
            } else {
                result.buffers[result.count][text_len] = out.format[i];
                text_len += 1;
                i += 1;
            }
        }

        // Parse style
        const style = pop.Style.parse(out.style);

        result.items[result.count] = .{
            .text = result.buffers[result.count][0..text_len],
            .fg = if (style.fg != .none) styleColorToRender(style.fg) else .none,
            .bg = if (style.bg != .none) styleColorToRender(style.bg) else .none,
            .bold = style.bold,
            .italic = style.italic,
        };
        result.total_len += text_len;
        result.count += 1;
    }

    return result;
}

fn styleColorToRender(col: pop.Color) render.Color {
    return switch (col) {
        .none => .none,
        .palette => |p| .{ .palette = p },
        .rgb => |rgb| .{ .rgb = .{ .r = rgb.r, .g = rgb.g, .b = rgb.b } },
    };
}

fn runStatusModule(module: *const core.StatusModule, buf: []u8) ![]const u8 {
    // For custom commands, run them
    if (module.command) |cmd| {
        const result = std.process.Child.run(.{
            .allocator = std.heap.page_allocator,
            .argv = &.{ "/bin/sh", "-c", cmd },
        }) catch return "";
        defer std.heap.page_allocator.free(result.stdout);
        defer std.heap.page_allocator.free(result.stderr);

        // Copy to buffer, strip trailing newline
        var len = result.stdout.len;
        while (len > 0 and (result.stdout[len - 1] == '\n' or result.stdout[len - 1] == '\r')) {
            len -= 1;
        }
        const copy_len = @min(len, buf.len);
        @memcpy(buf[0..copy_len], result.stdout[0..copy_len]);
        return buf[0..copy_len];
    }

    // For built-in modules, delegate to status module system
    // For now just return module name as placeholder
    const copy_len = @min(module.name.len, buf.len);
    @memcpy(buf[0..copy_len], module.name[0..copy_len]);
    return buf[0..copy_len];
}

fn drawStatusBar(state: *State, renderer: *Renderer) void {
    const y = state.term_height - 1;
    const width = state.term_width;
    const cfg = &state.config.status;

    // Clear status bar
    for (0..width) |xi| {
        renderer.setCell(@intCast(xi), y, .{ .char = ' ' });
    }

    // Create pop context
    var ctx = pop.Context.init(state.allocator);
    defer ctx.deinit();
    ctx.terminal_width = width;

    // Collect tab names for center section (shows tabs, not panes within a tab)
    var tab_names: [16][]const u8 = undefined;
    var tab_count: usize = 0;
    for (state.tabs.items) |*tab| {
        if (tab_count < 16) {
            // Use the focused pane's pwd as tab name
            if (tab.layout.getFocusedPane()) |pane| {
                const pwd = pane.getPwd();
                tab_names[tab_count] = if (pwd) |p| std.fs.path.basename(p) else "tab";
            } else {
                tab_names[tab_count] = "tab";
            }
            tab_count += 1;
        }
    }
    ctx.pane_names = tab_names[0..tab_count];
    ctx.active_pane = state.active_tab;
    ctx.session_name = "hexa";

    // === DRAW LEFT SECTION ===
    var left_x: u16 = 0;
    for (cfg.left) |mod| {
        left_x = drawModule(renderer, &ctx, mod, left_x, y);
    }

    // === CALCULATE RIGHT WIDTH ===
    var right_width: u16 = 0;
    for (cfg.right) |mod| {
        right_width += calcModuleWidth(&ctx, mod);
    }
    const right_start = width -| right_width;

    // === DRAW RIGHT SECTION ===
    var rx: u16 = right_start;
    for (cfg.right) |mod| {
        rx = drawModule(renderer, &ctx, mod, rx, y);
    }

    // === CALCULATE CENTER WIDTH ===
    var center_width: u16 = 0;
    for (cfg.center) |mod| {
        if (std.mem.eql(u8, mod.name, "panes")) {
            for (ctx.pane_names, 0..) |pane_name, i| {
                if (i > 0) center_width += @as(u16, @intCast(mod.separator.len));
                center_width += 2 + @as(u16, @intCast(pane_name.len)) + 2; // arrows + space + name + space
            }
        }
    }

    // === DRAW CENTER SECTION (truly centered) ===
    const center_start = (width -| center_width) / 2;
    if (center_start > left_x + 2 and center_start + center_width < right_start -| 2) {
        var cx: u16 = center_start;
        for (cfg.center) |mod| {
            if (std.mem.eql(u8, mod.name, "panes")) {
                const active_style = pop.Style.parse(mod.active_style);
                const inactive_style = pop.Style.parse(mod.inactive_style);
                const sep_style = pop.Style.parse(mod.separator_style);

                for (ctx.pane_names, 0..) |pane_name, i| {
                    if (i > 0) {
                        cx = drawStyledText(renderer, cx, y, mod.separator, sep_style);
                    }
                    const is_active = i == ctx.active_pane;
                    const style = if (is_active) active_style else inactive_style;
                    const arrow_fg = if (is_active) active_style.bg else inactive_style.bg;
                    const arrow_style = pop.Style{ .fg = arrow_fg };

                    cx = drawStyledText(renderer, cx, y, "", arrow_style);
                    cx = drawStyledText(renderer, cx, y, " ", style);
                    cx = drawStyledText(renderer, cx, y, pane_name, style);
                    cx = drawStyledText(renderer, cx, y, " ", style);
                    cx = drawStyledText(renderer, cx, y, "", arrow_style);
                }
            }
        }
    }
}

fn drawModule(renderer: *Renderer, ctx: *pop.Context, mod: core.config.StatusModule, start_x: u16, y: u16) u16 {
    var x = start_x;

    // Get the output text for this module
    var output_text: []const u8 = "";

    // Special handling for "session"
    if (std.mem.eql(u8, mod.name, "session")) {
        output_text = ctx.session_name;
    } else {
        // Render segment to get output text
        if (ctx.renderSegment(mod.name)) |segs| {
            if (segs.len > 0) {
                output_text = segs[0].text;
            }
        }
    }

    // Draw each output in the array
    for (mod.outputs) |out| {
        const style = pop.Style.parse(out.style);
        x = drawFormatted(renderer, x, y, out.format, output_text, style);
    }

    return x;
}

fn drawFormatted(renderer: *Renderer, start_x: u16, y: u16, format: []const u8, output: []const u8, style: pop.Style) u16 {
    var x = start_x;
    var i: usize = 0;

    while (i < format.len) {
        // Look for $output
        if (i + 7 <= format.len and std.mem.eql(u8, format[i..][0..7], "$output")) {
            x = drawStyledText(renderer, x, y, output, style);
            i += 7;
        } else {
            // Draw single char (handle UTF-8)
            const len = std.unicode.utf8ByteSequenceLength(format[i]) catch 1;
            const end = @min(i + len, format.len);
            x = drawStyledText(renderer, x, y, format[i..end], style);
            i = end;
        }
    }
    return x;
}

fn calcModuleWidth(ctx: *pop.Context, mod: core.config.StatusModule) u16 {
    var width: u16 = 0;

    // Get the output text for this module
    var output_text: []const u8 = "";

    // Special handling for "session"
    if (std.mem.eql(u8, mod.name, "session")) {
        output_text = ctx.session_name;
    } else {
        // Render segment to get output text
        if (ctx.renderSegment(mod.name)) |segs| {
            if (segs.len > 0) {
                output_text = segs[0].text;
            }
        }
    }

    // Sum width of all outputs
    for (mod.outputs) |out| {
        width += calcFormattedWidth(out.format, output_text);
    }

    return width;
}

fn calcFormattedWidth(format: []const u8, output: []const u8) u16 {
    var width: u16 = 0;
    var i: usize = 0;

    while (i < format.len) {
        if (i + 7 <= format.len and std.mem.eql(u8, format[i..][0..7], "$output")) {
            // Count output chars
            var j: usize = 0;
            while (j < output.len) {
                const len = std.unicode.utf8ByteSequenceLength(output[j]) catch 1;
                j += len;
                width += 1;
            }
            i += 7;
        } else {
            const len = std.unicode.utf8ByteSequenceLength(format[i]) catch 1;
            i += len;
            width += 1;
        }
    }
    return width;
}

fn drawSegment(renderer: *Renderer, x: u16, y: u16, seg: pop.Segment, default_style: pop.Style) u16 {
    const style = if (seg.style.isEmpty()) default_style else seg.style;
    return drawStyledText(renderer, x, y, seg.text, style);
}

fn drawStyledText(renderer: *Renderer, start_x: u16, y: u16, text: []const u8, style: pop.Style) u16 {
    var x = start_x;
    var i: usize = 0;

    while (i < text.len) {
        // Decode UTF-8 codepoint
        const len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        const codepoint = std.unicode.utf8Decode(text[i..][0..len]) catch ' ';

        var cell = render.Cell{
            .char = codepoint,
            .bold = style.bold,
            .italic = style.italic,
        };

        // Convert pop.Color to render.Color
        switch (style.fg) {
            .none => {},
            .palette => |p| cell.fg = .{ .palette = p },
            .rgb => |rgb| cell.fg = .{ .rgb = .{ .r = rgb.r, .g = rgb.g, .b = rgb.b } },
        }
        switch (style.bg) {
            .none => {},
            .palette => |p| cell.bg = .{ .palette = p },
            .rgb => |rgb| cell.bg = .{ .rgb = .{ .r = rgb.r, .g = rgb.g, .b = rgb.b } },
        }

        renderer.setCell(x, y, cell);
        x += 1;
        i += len;
    }

    return x;
}

fn getTermSize() struct { cols: u16, rows: u16 } {
    var ws: c.winsize = undefined;
    if (c.ioctl(posix.STDOUT_FILENO, c.TIOCGWINSZ, &ws) == 0) {
        return .{
            .cols = if (ws.ws_col > 0) ws.ws_col else 80,
            .rows = if (ws.ws_row > 0) ws.ws_row else 24,
        };
    }
    return .{ .cols = 80, .rows = 24 };
}

fn enableRawMode(fd: posix.fd_t) !posix.termios {
    var termios = try posix.tcgetattr(fd);
    const orig = termios;

    termios.iflag.BRKINT = false;
    termios.iflag.ICRNL = false;
    termios.iflag.INPCK = false;
    termios.iflag.ISTRIP = false;
    termios.iflag.IXON = false;
    termios.oflag.OPOST = false;
    termios.cflag.CSIZE = .CS8;
    termios.lflag.ECHO = false;
    termios.lflag.ICANON = false;
    termios.lflag.IEXTEN = false;
    termios.lflag.ISIG = false;
    termios.cc[@intFromEnum(posix.V.MIN)] = 1;
    termios.cc[@intFromEnum(posix.V.TIME)] = 0;

    try posix.tcsetattr(fd, .FLUSH, termios);
    return orig;
}

fn disableRawMode(fd: posix.fd_t, orig: posix.termios) !void {
    try posix.tcsetattr(fd, .FLUSH, orig);
}
