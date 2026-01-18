const std = @import("std");
const posix = std.posix;
const core = @import("core");
const ghostty = @import("ghostty-vt");

/// A Pane is a ghostty VT + PTY that can be rendered to a region of the screen
pub const Pane = struct {
    allocator: std.mem.Allocator,
    id: u16,
    vt: core.VT,
    pty: core.Pty,
    // Position and size in the terminal
    x: u16,
    y: u16,
    width: u16,
    height: u16,
    // Is this pane focused?
    focused: bool = false,
    // Is this a floating pane?
    floating: bool = false,
    // Is this pane visible? (for floating panes that can be toggled)
    visible: bool = true,
    // Name/ID for the pane
    name: []const u8 = "float",
    // Outer border dimensions (for floating panes with padding)
    border_x: u16 = 0,
    border_y: u16 = 0,
    border_w: u16 = 0,
    border_h: u16 = 0,
    // Per-float style settings
    border_color: u8 = 1,
    show_title: bool = true,
    // Float layout percentages (for resize recalculation)
    float_width_pct: u8 = 60,
    float_height_pct: u8 = 60,
    float_pos_x_pct: u8 = 50,
    float_pos_y_pct: u8 = 50,
    float_pad_x: u8 = 1,
    float_pad_y: u8 = 0,

    pub fn init(allocator: std.mem.Allocator, id: u16, x: u16, y: u16, width: u16, height: u16) !Pane {
        return initWithCommand(allocator, id, x, y, width, height, null);
    }

    pub fn initWithCommand(allocator: std.mem.Allocator, id: u16, x: u16, y: u16, width: u16, height: u16, command: ?[]const u8) !Pane {
        const cmd = command orelse (posix.getenv("SHELL") orelse "/bin/sh");
        var pty = try core.Pty.spawn(cmd);
        errdefer pty.close();

        try pty.setSize(width, height);

        var vt = try core.VT.init(allocator, width, height);
        errdefer vt.deinit();

        return Pane{
            .allocator = allocator,
            .id = id,
            .vt = vt,
            .pty = pty,
            .x = x,
            .y = y,
            .width = width,
            .height = height,
        };
    }

    pub fn deinit(self: *Pane) void {
        self.pty.close();
        self.vt.deinit();
    }

    /// Read from PTY and feed to VT. Returns true if data was read.
    pub fn poll(self: *Pane, buffer: []u8) !bool {
        const n = self.pty.read(buffer) catch |err| {
            if (err == error.WouldBlock) return false;
            return err;
        };
        if (n == 0) return false;
        try self.vt.feed(buffer[0..n]);
        return true;
    }

    /// Write input to PTY
    pub fn write(self: *Pane, data: []const u8) !void {
        _ = try self.pty.write(data);
    }

    /// Resize the pane
    pub fn resize(self: *Pane, x: u16, y: u16, width: u16, height: u16) !void {
        self.x = x;
        self.y = y;
        if (width != self.width or height != self.height) {
            self.width = width;
            self.height = height;
            try self.vt.resize(width, height);
            try self.pty.setSize(width, height);
        }
    }

    /// Get the PTY file descriptor for polling
    pub fn getFd(self: *Pane) posix.fd_t {
        return self.pty.master_fd;
    }

    /// Check if shell has exited
    pub fn isAlive(self: *Pane) bool {
        return self.pty.pollStatus() == null;
    }

    /// Render pane contents to output buffer at the pane's position
    pub fn render(self: *Pane, allocator: std.mem.Allocator, output: *std.ArrayList(u8)) !void {
        const screen = self.vt.terminal.screens.active;
        var row_pin = screen.pages.getTopLeft(.viewport);

        for (0..self.height) |row| {
            const y = self.y + @as(u16, @intCast(row));

            // Move cursor to start of row
            try output.writer(allocator).print("\x1b[{d};{d}H", .{ y + 1, self.x + 1 });

            const rac = row_pin.rowAndCell();
            const page = row_pin.node.data;
            const cells = page.getCells(rac.row);

            var last_style_id: u16 = 0;
            var cols_written: u16 = 0;

            for (cells, 0..) |cell, col| {
                if (col >= self.width) break;

                // Skip spacer cells (follow wide characters)
                if (cell.wide == .spacer_tail or cell.wide == .spacer_head) {
                    cols_written += 1;
                    continue;
                }

                cols_written += 1;
                // Wide characters take 2 columns
                if (cell.wide == .wide) {
                    cols_written += 1;
                }

                // Handle style changes
                if (cell.style_id != last_style_id) {
                    if (cell.style_id == 0) {
                        try output.appendSlice(allocator, "\x1b[0m");
                    } else {
                        const style = page.styles.get(page.memory, cell.style_id);
                        try appendStyle(allocator, output, style);
                    }
                    last_style_id = cell.style_id;
                }

                // Output character
                const cp = cell.codepoint();
                if (cp == 0 or cp == ' ') {
                    try output.append(allocator, ' ');
                } else if (cp < 128) {
                    try output.append(allocator, @intCast(cp));
                } else {
                    var buf: [4]u8 = undefined;
                    const len = std.unicode.utf8Encode(cp, &buf) catch 1;
                    try output.appendSlice(allocator, buf[0..len]);
                }
            }

            // Pad remaining width with spaces
            while (cols_written < self.width) : (cols_written += 1) {
                try output.append(allocator, ' ');
            }

            // Reset style at end of row
            try output.appendSlice(allocator, "\x1b[0m");

            // Move to next row in VT
            if (row_pin.down(1)) |next| {
                row_pin = next;
            } else break;
        }
    }

    /// Get cursor position relative to screen
    pub fn getCursorPos(self: *Pane) struct { x: u16, y: u16 } {
        const cursor = self.vt.getCursor();
        return .{
            .x = self.x + cursor.x,
            .y = self.y + cursor.y,
        };
    }

    /// Get cursor style (DECSCUSR value)
    pub fn getCursorStyle(self: *Pane) u8 {
        return self.vt.getCursorStyle();
    }

    /// Check if cursor should be visible
    pub fn isCursorVisible(self: *Pane) bool {
        return self.vt.isCursorVisible();
    }

    /// Get current working directory (from OSC 7)
    pub fn getPwd(self: *Pane) ?[]const u8 {
        return self.vt.getPwd();
    }
};

fn appendStyle(allocator: std.mem.Allocator, output: *std.ArrayList(u8), style: anytype) !void {
    try output.appendSlice(allocator, "\x1b[0");

    if (style.flags.bold) try output.appendSlice(allocator, ";1");
    if (style.flags.faint) try output.appendSlice(allocator, ";2");
    if (style.flags.italic) try output.appendSlice(allocator, ";3");

    // Handle different underline styles
    switch (style.flags.underline) {
        .none => {},
        .single => try output.appendSlice(allocator, ";4"),
        .double => try output.appendSlice(allocator, ";4:2"),
        .curly => try output.appendSlice(allocator, ";4:3"),
        .dotted => try output.appendSlice(allocator, ";4:4"),
        .dashed => try output.appendSlice(allocator, ";4:5"),
    }

    if (style.flags.blink) try output.appendSlice(allocator, ";5");
    if (style.flags.inverse) try output.appendSlice(allocator, ";7");
    if (style.flags.invisible) try output.appendSlice(allocator, ";8");
    if (style.flags.strikethrough) try output.appendSlice(allocator, ";9");
    if (style.flags.overline) try output.appendSlice(allocator, ";53");

    // Foreground color
    switch (style.fg_color) {
        .none => {},
        .palette => |idx| try output.writer(allocator).print(";38;5;{d}", .{idx}),
        .rgb => |rgb| try output.writer(allocator).print(";38;2;{d};{d};{d}", .{ rgb.r, rgb.g, rgb.b }),
    }

    // Background color
    switch (style.bg_color) {
        .none => {},
        .palette => |idx| try output.writer(allocator).print(";48;5;{d}", .{idx}),
        .rgb => |rgb| try output.writer(allocator).print(";48;2;{d};{d};{d}", .{ rgb.r, rgb.g, rgb.b }),
    }

    // Underline color
    switch (style.underline_color) {
        .none => {},
        .palette => |idx| try output.writer(allocator).print(";58;5;{d}", .{idx}),
        .rgb => |rgb| try output.writer(allocator).print(";58;2;{d};{d};{d}", .{ rgb.r, rgb.g, rgb.b }),
    }

    try output.append(allocator, 'm');
}
