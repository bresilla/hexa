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
    // UUID for tracking in ses (32 hex chars)
    uuid: [32]u8 = undefined,
    // Whether this pane is managed by ses
    ses_managed: bool = false,
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
    // Key binding for this float (for matching)
    float_key: u8 = 0,
    // Outer border dimensions (for floating panes with padding)
    border_x: u16 = 0,
    border_y: u16 = 0,
    border_w: u16 = 0,
    border_h: u16 = 0,
    // Per-float style settings
    border_color: core.BorderColor = .{},
    // Float layout percentages (for resize recalculation)
    float_width_pct: u8 = 60,
    float_height_pct: u8 = 60,
    float_pos_x_pct: u8 = 50,
    float_pos_y_pct: u8 = 50,
    float_pad_x: u8 = 1,
    float_pad_y: u8 = 0,
    // For pwd floats: the directory this float is bound to
    pwd_dir: ?[]const u8 = null,
    is_pwd: bool = false,
    // Border style and optional module
    float_style: ?*const core.FloatStyle = null,

    // Tracks whether we saw a clear-screen sequence in the last PTY read.
    did_clear: bool = false,
    // Keep last bytes so we can detect escape sequences across read boundaries.
    esc_tail: [3]u8 = .{ 0, 0, 0 },
    esc_tail_len: u8 = 0,

    pub fn init(self: *Pane, allocator: std.mem.Allocator, id: u16, x: u16, y: u16, width: u16, height: u16) !void {
        return self.initWithCommand(allocator, id, x, y, width, height, null);
    }

    pub fn initWithCommand(self: *Pane, allocator: std.mem.Allocator, id: u16, x: u16, y: u16, width: u16, height: u16, command: ?[]const u8) !void {
        self.* = .{ .allocator = allocator, .id = id, .x = x, .y = y, .width = width, .height = height, .did_clear = false, .esc_tail = .{ 0, 0, 0 }, .esc_tail_len = 0 };

        const cmd = command orelse (posix.getenv("SHELL") orelse "/bin/sh");
        self.pty = try core.Pty.spawn(cmd);
        errdefer self.pty.close();
        try self.pty.setSize(width, height);

        try self.vt.init(allocator, width, height);
        errdefer self.vt.deinit();
    }

    /// Initialize a pane with an fd received from ses daemon
    /// This is used when ses manages the PTY
    pub fn initWithFd(self: *Pane, allocator: std.mem.Allocator, id: u16, x: u16, y: u16, width: u16, height: u16, fd: posix.fd_t, child_pid: posix.pid_t, uuid: [32]u8) !void {
        self.* = .{
            .allocator = allocator,
            .id = id,
            .x = x,
            .y = y,
            .width = width,
            .height = height,
            .did_clear = false,
            .esc_tail = .{ 0, 0, 0 },
            .esc_tail_len = 0,
            .uuid = uuid,
            .ses_managed = true,
        };

        // Create Pty from existing fd
        self.pty = core.Pty.fromFd(fd, child_pid);
        errdefer self.pty.close();
        try self.pty.setSize(width, height);

        try self.vt.init(allocator, width, height);
        errdefer self.vt.deinit();
    }

    pub fn deinit(self: *Pane) void {
        self.pty.close();
        self.vt.deinit();
        // Free pwd_dir if allocated
        if (self.pwd_dir) |dir| {
            self.allocator.free(dir);
        }
    }

    /// Read from PTY and feed to VT. Returns true if data was read.
    pub fn poll(self: *Pane, buffer: []u8) !bool {
        self.did_clear = false;

        const n = self.pty.read(buffer) catch |err| {
            if (err == error.WouldBlock) return false;
            return err;
        };
        if (n == 0) return false;

        const data = buffer[0..n];
        self.did_clear = containsClearSeq(self.esc_tail[0..self.esc_tail_len], data);

        // Update tail with the last up-to-3 bytes.
        const take: usize = @min(@as(usize, 3), data.len);
        if (take > 0) {
            @memcpy(self.esc_tail[0..take], data[data.len - take .. data.len]);
            self.esc_tail_len = @intCast(take);
        }

        try self.vt.feed(data);
        return true;
    }

    fn containsClearSeq(tail: []const u8, data: []const u8) bool {
        // Common clear sequences emitted by shells / terminfo:
        // - ED2: ESC[2J
        // - ED3: ESC[3J (clear scrollback)
        // - ED0: ESC[J or ESC[0J
        // - Home+ED*: ESC[H ...
        // - Form feed: ^L (0x0C)
        return std.mem.indexOfScalar(u8, data, 0x0c) != null or
            containsSeq(tail, data, "\x1b[2J") or
            containsSeq(tail, data, "\x1b[3J") or
            containsSeq(tail, data, "\x1b[J") or
            containsSeq(tail, data, "\x1b[0J") or
            containsSeq(tail, data, "\x1b[H\x1b[2J") or
            containsSeq(tail, data, "\x1b[H\x1b[J") or
            containsSeq(tail, data, "\x1b[H\x1b[0J") or
            containsSeq(tail, data, "\x1b[1;1H\x1b[2J") or
            containsSeq(tail, data, "\x1b[1;1H\x1b[J") or
            containsSeq(tail, data, "\x1b[1;1H\x1b[0J");
    }

    fn containsSeq(tail: []const u8, data: []const u8, seq: []const u8) bool {
        if (std.mem.indexOf(u8, data, seq) != null) return true;
        if (tail.len == 0) return false;

        // Check for a match split across tail+data.
        const max_k = @min(tail.len, seq.len - 1);
        var k: usize = 1;
        while (k <= max_k) : (k += 1) {
            if (std.mem.eql(u8, tail[tail.len - k .. tail.len], seq[0..k]) and
                data.len >= seq.len - k and
                std.mem.eql(u8, data[0 .. seq.len - k], seq[k..seq.len]))
            {
                return true;
            }
        }

        return false;
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

    // Static buffer for readlink result
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;

    /// Get current working directory by reading /proc/<pid>/cwd
    /// This is more reliable than OSC 7 as it works with any shell
    pub fn getRealCwd(self: *Pane) ?[]const u8 {
        var path_buf: [64]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "/proc/{d}/cwd", .{self.pty.child_pid}) catch return null;
        const link = std.posix.readlink(path, &cwd_buf) catch return null;
        return link;
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
