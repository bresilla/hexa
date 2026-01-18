const std = @import("std");
const posix = std.posix;
const core = @import("core");
const ghostty = @import("ghostty-vt");

/// A Pane is a ghostty VT + PTY that can be rendered to a region of the screen
pub const Pane = struct {
    allocator: std.mem.Allocator = undefined,
    id: u16 = 0,
    vt: core.VT = .{},
    pty: core.Pty = undefined,
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

    pub fn init(self: *Pane, allocator: std.mem.Allocator, id: u16, x: u16, y: u16, width: u16, height: u16) !void {
        return self.initWithCommand(allocator, id, x, y, width, height, null);
    }

    pub fn initWithCommand(self: *Pane, allocator: std.mem.Allocator, id: u16, x: u16, y: u16, width: u16, height: u16, command: ?[]const u8) !void {
        self.* = .{ .allocator = allocator, .id = id, .x = x, .y = y, .width = width, .height = height };

        const cmd = command orelse (posix.getenv("SHELL") orelse "/bin/sh");
        self.pty = try core.Pty.spawn(cmd);
        errdefer self.pty.close();
        try self.pty.setSize(width, height);

        try self.vt.init(allocator, width, height);
        errdefer self.vt.deinit();
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

    /// Get the underlying terminal for cursor/mode access
    pub fn getTerminal(self: *Pane) *ghostty.Terminal {
        return &self.vt.terminal;
    }

    /// Get a stable snapshot of the viewport for rendering.
    pub fn getRenderState(self: *Pane) !*const ghostty.RenderState {
        return self.vt.getRenderState();
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

    /// Scroll up by given number of lines
    pub fn scrollUp(self: *Pane, lines: u32) void {
        self.vt.terminal.scrollViewport(.{ .delta = -@as(isize, @intCast(lines)) }) catch {};
    }

    /// Scroll down by given number of lines
    pub fn scrollDown(self: *Pane, lines: u32) void {
        self.vt.terminal.scrollViewport(.{ .delta = @as(isize, @intCast(lines)) }) catch {};
    }

    /// Scroll to top of history
    pub fn scrollToTop(self: *Pane) void {
        self.vt.terminal.scrollViewport(.top) catch {};
    }

    /// Scroll to bottom (current output)
    pub fn scrollToBottom(self: *Pane) void {
        self.vt.terminal.scrollViewport(.bottom) catch {};
    }

    /// Check if we're scrolled (not at bottom)
    pub fn isScrolled(self: *Pane) bool {
        return !self.vt.terminal.screens.active.viewportIsBottom();
    }
};
