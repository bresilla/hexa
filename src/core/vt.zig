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

    /// Check if in alternate screen mode
    pub fn inAltScreen(self: *VT) bool {
        return self.terminal.screens.active_key == .alternate;
    }
};
