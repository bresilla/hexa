const std = @import("std");

// Re-export ghostty-vt - this IS our terminal emulation
pub const ghostty = @import("ghostty-vt");
pub const Terminal = ghostty.Terminal;

/// Thin wrapper around ghostty Terminal
pub const VT = struct {
    allocator: std.mem.Allocator,
    terminal: Terminal,
    width: u16,
    height: u16,

    pub fn init(allocator: std.mem.Allocator, width: u16, height: u16) !VT {
        return .{
            .allocator = allocator,
            .terminal = try Terminal.init(allocator, .{
                .cols = width,
                .rows = height,
            }),
            .width = width,
            .height = height,
        };
    }

    pub fn deinit(self: *VT) void {
        self.terminal.deinit(self.allocator);
    }

    /// Process input data through the terminal emulator
    pub fn feed(self: *VT, data: []const u8) !void {
        var stream = self.terminal.vtStream();
        try stream.nextSlice(data);
    }

    /// Resize the virtual terminal
    pub fn resize(self: *VT, width: u16, height: u16) !void {
        if (width == self.width and height == self.height) return;
        try self.terminal.resize(self.allocator, width, height);
        self.width = width;
        self.height = height;
    }

    /// Get cursor position
    pub fn getCursor(self: *VT) struct { x: u16, y: u16 } {
        const cursor = self.terminal.screens.active.cursor;
        return .{ .x = cursor.x, .y = cursor.y };
    }

    /// Get cursor style (returns DECSCUSR value: 0=default, 1=block blink, 2=block, 3=underline blink, 4=underline, 5=bar blink, 6=bar)
    pub fn getCursorStyle(self: *VT) u8 {
        const screen = self.terminal.screens.active;
        const cursor_style = screen.cursor.cursor_style;
        const blink = self.terminal.modes.get(.cursor_blinking);
        // Map ghostty cursor style to DECSCUSR values
        return switch (cursor_style) {
            .block, .block_hollow => if (blink) 1 else 2,
            .underline => if (blink) 3 else 4,
            .bar => if (blink) 5 else 6,
        };
    }

    /// Check if cursor is visible
    pub fn isCursorVisible(self: *VT) bool {
        return self.terminal.modes.get(.cursor_visible);
    }

    /// Check if in alternate screen mode
    pub fn inAltScreen(self: *VT) bool {
        return self.terminal.screens.active_key == .alternate;
    }

    /// Get current working directory (from OSC 7)
    pub fn getPwd(self: *VT) ?[]const u8 {
        if (self.terminal.pwd.items.len == 0) return null;
        return self.terminal.pwd.items;
    }
};
