const std = @import("std");
const posix = std.posix;
const core = @import("core");

const Pane = @import("pane.zig").Pane;
const Layout = @import("layout.zig").Layout;
const SplitDir = @import("layout.zig").SplitDir;

const c = @cImport({
    @cInclude("sys/ioctl.h");
});

const State = struct {
    allocator: std.mem.Allocator,
    config: core.Config,
    layout: Layout,
    floating_panes: std.ArrayList(*Pane),
    active_floating: ?usize,
    running: bool,
    needs_render: bool,
    term_width: u16,
    term_height: u16,
    status_height: u16,

    fn init(allocator: std.mem.Allocator, width: u16, height: u16) State {
        const cfg = core.Config.load(allocator);
        const status_h: u16 = if (cfg.status_enabled) 1 else 0;
        return .{
            .allocator = allocator,
            .config = cfg,
            .layout = Layout.init(allocator, width, height - status_h),
            .floating_panes = .empty,
            .active_floating = null,
            .running = true,
            .needs_render = true,
            .term_width = width,
            .term_height = height,
            .status_height = status_h,
        };
    }

    fn deinit(self: *State) void {
        // Deinit floating panes
        for (self.floating_panes.items) |pane| {
            pane.deinit();
            self.allocator.destroy(pane);
        }
        self.floating_panes.deinit(self.allocator);
        self.layout.deinit();
        self.config.deinit();
    }
};

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    // Get terminal size
    const size = getTermSize();

    // Initialize state
    var state = State.init(allocator, size.cols, size.rows);
    defer state.deinit();

    // Create first pane
    _ = try state.layout.createFirstPane();

    // Enter raw mode
    const orig_termios = try enableRawMode(posix.STDIN_FILENO);
    defer disableRawMode(posix.STDIN_FILENO, orig_termios) catch {};

    // Enter alternate screen, hide cursor
    const stdout = std.fs.File.stdout();
    try stdout.writeAll("\x1b[?1049h\x1b[?25l");
    defer stdout.writeAll("\x1b[?25h\x1b[?1049l") catch {};

    // Build poll fds
    var poll_fds: [17]posix.pollfd = undefined; // stdin + up to 16 panes
    var buffer: [8192]u8 = undefined;

    // Main loop
    while (state.running) {
        // Check for terminal resize
        {
            const new_size = getTermSize();
            if (new_size.cols != state.term_width or new_size.rows != state.term_height) {
                state.term_width = new_size.cols;
                state.term_height = new_size.rows;
                const status_h: u16 = if (state.config.status_enabled) 1 else 0;
                state.status_height = status_h;

                // Resize layout (tiled panes)
                state.layout.resize(new_size.cols, new_size.rows - status_h);

                // Resize floating panes based on their stored percentages
                resizeFloatingPanes(&state);

                state.needs_render = true;
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

        // Check for dead tiled panes
        {
            var any_dead = false;
            var pane_it = state.layout.paneIterator();
            while (pane_it.next()) |pane| {
                if (!pane.*.isAlive()) {
                    any_dead = true;
                    break;
                }
            }
            if (any_dead) {
                if (state.layout.paneCount() > 1) {
                    _ = state.layout.closeFocused();
                    state.needs_render = true;
                } else {
                    state.running = false;
                    continue;
                }
            }
        }

        // Build poll list: stdin + all pane PTYs
        var fd_count: usize = 1;
        poll_fds[0] = .{ .fd = posix.STDIN_FILENO, .events = posix.POLL.IN, .revents = 0 };

        var pane_it = state.layout.paneIterator();
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

        const timeout: i32 = if (state.needs_render) 0 else 100;
        _ = posix.poll(poll_fds[0..fd_count], timeout) catch continue;

        // Handle stdin
        if (poll_fds[0].revents & posix.POLL.IN != 0) {
            const n = posix.read(posix.STDIN_FILENO, &buffer) catch break;
            if (n == 0) break;
            handleInput(&state, buffer[0..n]);
        }

        // Handle PTY output and check for dead panes
        var idx: usize = 1;
        var dead_panes: std.ArrayList(u16) = .empty;
        defer dead_panes.deinit(allocator);

        pane_it = state.layout.paneIterator();
        while (pane_it.next()) |pane| {
            if (idx < fd_count) {
                if (poll_fds[idx].revents & posix.POLL.IN != 0) {
                    if (pane.*.poll(&buffer)) |had_data| {
                        if (had_data) state.needs_render = true;
                    } else |_| {}
                }
                if (poll_fds[idx].revents & posix.POLL.HUP != 0) {
                    dead_panes.append(allocator, pane.*.id) catch {};
                }
                idx += 1;
            }
        }

        // Handle floating pane output and check for dead floating panes
        var dead_floating: std.ArrayList(usize) = .empty;
        defer dead_floating.deinit(allocator);

        for (state.floating_panes.items, 0..) |pane, fi| {
            if (idx < fd_count) {
                if (poll_fds[idx].revents & posix.POLL.IN != 0) {
                    if (pane.poll(&buffer)) |had_data| {
                        if (had_data) state.needs_render = true;
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
            if (state.layout.paneCount() > 1) {
                _ = state.layout.closeFocused();
                state.needs_render = true;
            } else {
                state.running = false;
            }
        }

        // Render
        if (state.needs_render) {
            render(&state, stdout) catch {};
            state.needs_render = false;
        }
    }
}

fn handleInput(state: *State, input: []const u8) void {
    var i: usize = 0;
    while (i < input.len) {
        // Check for Alt+key (ESC followed by key)
        if (input[i] == 0x1b and i + 1 < input.len) {
            const next = input[i + 1];
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

        // Forward remaining input to focused pane
        if (state.active_floating) |idx| {
            const fpane = state.floating_panes.items[idx];
            if (fpane.visible) {
                fpane.write(input[i..]) catch {};
            }
        } else if (state.layout.getFocusedPane()) |pane| {
            pane.write(input[i..]) catch {};
        }
        return;
    }
}

fn handleAltKey(state: *State, key: u8) bool {
    const cfg = &state.config;

    if (key == cfg.key_quit) {
        state.running = false;
        return true;
    }

    if (key == cfg.key_split_h) {
        _ = state.layout.splitFocused(.horizontal) catch null;
        state.needs_render = true;
        return true;
    }

    if (key == cfg.key_split_v) {
        _ = state.layout.splitFocused(.vertical) catch null;
        state.needs_render = true;
        return true;
    }

    if (key == cfg.key_new_pane) {
        _ = state.layout.splitFocused(.horizontal) catch null;
        state.needs_render = true;
        return true;
    }

    if (key == cfg.key_next_pane) {
        state.active_floating = null;
        state.layout.focusNext();
        state.needs_render = true;
        return true;
    }

    if (key == cfg.key_prev_pane) {
        state.active_floating = null;
        state.layout.focusPrev();
        state.needs_render = true;
        return true;
    }

    if (key == cfg.key_close_pane or key == 'w') {
        if (state.active_floating) |idx| {
            const pane = state.floating_panes.orderedRemove(idx);
            pane.deinit();
            state.allocator.destroy(pane);
            state.active_floating = if (state.floating_panes.items.len > 0) 0 else null;
        } else {
            if (!state.layout.closeFocused()) {
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
    // Find existing float by name
    for (state.floating_panes.items, 0..) |pane, i| {
        if (std.mem.eql(u8, pane.name, float_def.name)) {
            // Toggle visibility
            pane.visible = !pane.visible;
            if (pane.visible) {
                state.active_floating = i;
                // If alone mode, hide all other floats
                if (float_def.alone) {
                    for (state.floating_panes.items) |other| {
                        if (!std.mem.eql(u8, other.name, float_def.name)) {
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
    // Not found - create new float with this name and command
    createNamedFloat(state, float_def) catch {};

    // If alone mode, hide all other floats after creation
    if (float_def.alone) {
        for (state.floating_panes.items) |pane| {
            if (!std.mem.eql(u8, pane.name, float_def.name)) {
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

fn createNamedFloat(state: *State, float_def: *const core.FloatDef) !void {
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
    const border_color: u8 = float_def.border_color orelse cfg.float_border_color;
    const show_title: bool = float_def.show_title orelse cfg.float_show_title;

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
    pane.* = try Pane.initWithCommand(state.allocator, id, content_x, content_y, content_w, content_h, float_def.command);
    pane.floating = true;
    pane.focused = true;
    pane.visible = true;
    pane.name = float_def.name;
    // Store outer dimensions and style for border rendering
    pane.border_x = outer_x;
    pane.border_y = outer_y;
    pane.border_w = outer_w;
    pane.border_h = outer_h;
    pane.border_color = border_color;
    pane.show_title = show_title;
    // Store percentages for resize recalculation
    pane.float_width_pct = @intCast(width_pct);
    pane.float_height_pct = @intCast(height_pct);
    pane.float_pos_x_pct = @intCast(pos_x_pct);
    pane.float_pos_y_pct = @intCast(pos_y_pct);
    pane.float_pad_x = @intCast(pad_x_cfg);
    pane.float_pad_y = @intCast(pad_y_cfg);

    try state.floating_panes.append(state.allocator, pane);
    state.active_floating = state.floating_panes.items.len - 1;
}

fn render(state: *State, stdout: std.fs.File) !void {
    const allocator = state.allocator;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);

    // Begin synchronized output (reduces flicker) and hide cursor
    // We don't clear screen - just overwrite content to reduce flicker
    try output.appendSlice(allocator, "\x1b[?2026h\x1b[?25l");

    // Render tiled panes
    var pane_it = state.layout.paneIterator();
    while (pane_it.next()) |pane| {
        try pane.*.render(allocator, &output);
    }

    // Only draw split borders when there are multiple panes
    if (state.layout.paneCount() > 1) {
        try renderSplitBorders(state, allocator, &output);
    }

    // Render visible floating panes (on top)
    for (state.floating_panes.items, 0..) |pane, i| {
        if (!pane.visible) continue;
        try pane.render(allocator, &output);

        const is_active = state.active_floating == i;
        // Use per-pane border settings
        const title = if (pane.show_title) pane.name else "";
        try renderFloatingBorder(allocator, &output, pane.border_x, pane.border_y, pane.border_w, pane.border_h, is_active, title, pane.border_color);
    }

    // Render status bar if enabled
    if (state.config.status_enabled) {
        try renderStatusBar(state, allocator, &output);
    }

    // Position cursor and get style from focused pane
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
    } else if (state.layout.getFocusedPane()) |pane| {
        const pos = pane.getCursorPos();
        cursor_x = pos.x + 1;
        cursor_y = pos.y + 1;
        cursor_style = pane.getCursorStyle();
        cursor_visible = pane.isCursorVisible();
    }

    // Set cursor style (DECSCUSR), position, visibility, and end sync
    try output.writer(allocator).print("\x1b[{d} q\x1b[{d};{d}H", .{ cursor_style, cursor_y, cursor_x });
    if (cursor_visible) {
        try output.appendSlice(allocator, "\x1b[?25h");
    }
    try output.appendSlice(allocator, "\x1b[?2026l");

    try stdout.writeAll(output.items);
}

fn renderSplitBorders(state: *State, allocator: std.mem.Allocator, output: *std.ArrayList(u8)) !void {
    try output.appendSlice(allocator, "\x1b[90m"); // gray

    // Find split lines by checking pane boundaries
    var pane_it = state.layout.paneIterator();
    while (pane_it.next()) |pane| {
        const right_edge = pane.*.x + pane.*.width;
        const bottom_edge = pane.*.y + pane.*.height;

        // Draw vertical separator if pane doesn't reach right edge
        if (right_edge < state.term_width) {
            for (0..pane.*.height) |row| {
                try output.writer(allocator).print("\x1b[{d};{d}H│", .{
                    pane.*.y + @as(u16, @intCast(row)) + 1,
                    right_edge + 1,
                });
            }
        }

        // Draw horizontal separator if pane doesn't reach bottom
        if (bottom_edge < state.term_height - state.status_height) {
            try output.writer(allocator).print("\x1b[{d};{d}H", .{ bottom_edge + 1, pane.*.x + 1 });
            for (0..pane.*.width) |_| {
                try output.appendSlice(allocator, "─");
            }
        }
    }

    try output.appendSlice(allocator, "\x1b[0m");
}

fn renderFloatingBorder(allocator: std.mem.Allocator, output: *std.ArrayList(u8), x: u16, y: u16, w: u16, h: u16, active: bool, name: []const u8, border_color: u8) !void {
    // Use configured color, brighter when active
    if (active) {
        // Bright version of the color (add 8 for bright colors, or use bold)
        try output.writer(allocator).print("\x1b[1;38;5;{d}m", .{border_color});
    } else {
        try output.writer(allocator).print("\x1b[38;5;{d}m", .{border_color});
    }

    // Top border with title
    try output.writer(allocator).print("\x1b[{d};{d}H", .{ y + 1, x + 1 });
    try output.appendSlice(allocator, "╭");

    // Build title with name (if provided)
    if (name.len > 0) {
        var title_buf: [32]u8 = undefined;
        const title = std.fmt.bufPrint(&title_buf, "[ {s} ]", .{name}) catch "[ float ]";
        const title_start = (w -| title.len) / 2;

        for (0..w -| 2) |col| {
            if (col >= title_start and col < title_start + title.len) {
                try output.append(allocator, title[col - title_start]);
            } else {
                try output.appendSlice(allocator, "─");
            }
        }
    } else {
        // No title, just draw the line
        for (0..w -| 2) |_| {
            try output.appendSlice(allocator, "─");
        }
    }
    try output.appendSlice(allocator, "╮");

    // Side borders
    for (1..h -| 1) |row| {
        try output.writer(allocator).print("\x1b[{d};{d}H│", .{ y + @as(u16, @intCast(row)) + 1, x + 1 });
        try output.writer(allocator).print("\x1b[{d};{d}H│", .{ y + @as(u16, @intCast(row)) + 1, x + w });
    }

    // Bottom border
    try output.writer(allocator).print("\x1b[{d};{d}H", .{ y + h, x + 1 });
    try output.appendSlice(allocator, "╰");
    for (0..w -| 2) |_| {
        try output.appendSlice(allocator, "─");
    }
    try output.appendSlice(allocator, "╯");

    try output.appendSlice(allocator, "\x1b[0m");
}

fn renderStatusBar(state: *State, allocator: std.mem.Allocator, output: *std.ArrayList(u8)) !void {
    const y = state.term_height;

    // Background
    try output.writer(allocator).print("\x1b[{d};1H\x1b[44m\x1b[37m", .{y}); // blue bg, white fg

    // Fill with spaces first
    for (0..state.term_width) |_| {
        try output.append(allocator, ' ');
    }

    // Go back to start of line
    try output.writer(allocator).print("\x1b[{d};1H", .{y});

    // Left side: pane info
    const pane_count = state.layout.paneCount();
    const float_count = state.floating_panes.items.len;
    try output.writer(allocator).print(" [{d}]", .{pane_count});
    if (float_count > 0) {
        try output.writer(allocator).print(" +{d}f", .{float_count});
    }

    // Right side: help hints
    const help = " Alt+h/v:split Alt+n:next Alt+q:quit ";
    try output.writer(allocator).print("\x1b[{d};{d}H{s}", .{ y, state.term_width - help.len + 1, help });

    try output.appendSlice(allocator, "\x1b[0m");
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
