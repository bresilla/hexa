const std = @import("std");
const posix = std.posix;
const core = @import("core");

// Scrollback buffer for terminal history
pub const Scrollback = struct {
    allocator: std.mem.Allocator,
    lines: std.ArrayList([]u8) = .empty,
    max_lines: usize = 10000,
    scroll_offset: usize = 0, // 0 = bottom (live), >0 = scrolled up

    pub fn init(allocator: std.mem.Allocator) Scrollback {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Scrollback) void {
        for (self.lines.items) |line| {
            self.allocator.free(line);
        }
        self.lines.deinit(self.allocator);
    }

    // Add data to scrollback (splits by newlines)
    pub fn append(self: *Scrollback, data: []const u8) !void {
        var start: usize = 0;
        for (data, 0..) |byte, i| {
            if (byte == '\n') {
                const line = data[start..i];
                try self.addLine(line);
                start = i + 1;
            }
        }
        // Handle remaining data without newline
        if (start < data.len) {
            try self.addLine(data[start..]);
        }
    }

    fn addLine(self: *Scrollback, line: []const u8) !void {
        // Remove oldest line if at capacity
        if (self.lines.items.len >= self.max_lines) {
            const old = self.lines.orderedRemove(0);
            self.allocator.free(old);
        }

        const copy = try self.allocator.dupe(u8, line);
        try self.lines.append(self.allocator, copy);
    }

    // Scroll up (towards older content)
    pub fn scrollUp(self: *Scrollback, amount: usize) void {
        const max_offset = if (self.lines.items.len > 0) self.lines.items.len - 1 else 0;
        self.scroll_offset = @min(self.scroll_offset + amount, max_offset);
    }

    // Scroll down (towards newer content)
    pub fn scrollDown(self: *Scrollback, amount: usize) void {
        self.scroll_offset = self.scroll_offset -| amount;
    }

    // Jump to bottom (live view)
    pub fn scrollToBottom(self: *Scrollback) void {
        self.scroll_offset = 0;
    }

    // Check if at bottom
    pub fn isAtBottom(self: *Scrollback) bool {
        return self.scroll_offset == 0;
    }

    // Get visible lines for rendering (returns slice of lines)
    pub fn getVisibleLines(self: *Scrollback, visible_rows: usize) []const []u8 {
        if (self.lines.items.len == 0) return &[_][]u8{};

        const total = self.lines.items.len;
        const end_idx = total -| self.scroll_offset;
        const start_idx = end_idx -| visible_rows;

        return self.lines.items[start_idx..end_idx];
    }

    pub fn lineCount(self: *Scrollback) usize {
        return self.lines.items.len;
    }
};

// Copy mode state for text selection
pub const CopyMode = struct {
    active: bool = false,
    cursor_x: usize = 0,
    cursor_y: usize = 0,
    selection_start_x: ?usize = null,
    selection_start_y: ?usize = null,
    selection_active: bool = false,

    pub fn startSelection(self: *CopyMode) void {
        self.selection_start_x = self.cursor_x;
        self.selection_start_y = self.cursor_y;
        self.selection_active = true;
    }

    pub fn clearSelection(self: *CopyMode) void {
        self.selection_start_x = null;
        self.selection_start_y = null;
        self.selection_active = false;
    }

    pub fn moveCursor(self: *CopyMode, dx: i32, dy: i32, max_x: usize, max_y: usize) void {
        if (dx < 0) {
            self.cursor_x = self.cursor_x -| @as(usize, @intCast(-dx));
        } else {
            self.cursor_x = @min(self.cursor_x + @as(usize, @intCast(dx)), max_x);
        }
        if (dy < 0) {
            self.cursor_y = self.cursor_y -| @as(usize, @intCast(-dy));
        } else {
            self.cursor_y = @min(self.cursor_y + @as(usize, @intCast(dy)), max_y);
        }
    }
};

pub const Pane = struct {
    allocator: std.mem.Allocator,
    id: usize,
    pty: core.Pty,
    scrollback: Scrollback,
    in_scroll_mode: bool = false,
    copy_mode: CopyMode = .{},

    pub fn init(allocator: std.mem.Allocator, id: usize) !Pane {
        const shell = posix.getenv("SHELL") orelse "/bin/sh";
        return Pane{
            .allocator = allocator,
            .id = id,
            .pty = try core.Pty.spawn(shell),
            .scrollback = Scrollback.init(allocator),
        };
    }

    pub fn deinit(self: *Pane) void {
        self.scrollback.deinit();
        self.pty.close();
    }

    pub fn read(self: *Pane, buffer: []u8) !usize {
        const n = try self.pty.read(buffer);
        if (n > 0) {
            // Store in scrollback
            self.scrollback.append(buffer[0..n]) catch {};
        }
        return n;
    }

    pub fn write(self: *Pane, data: []const u8) !usize {
        return self.pty.write(data);
    }

    // Scroll control
    pub fn scrollUp(self: *Pane, amount: usize) void {
        self.scrollback.scrollUp(amount);
        self.in_scroll_mode = true;
    }

    pub fn scrollDown(self: *Pane, amount: usize) void {
        self.scrollback.scrollDown(amount);
        if (self.scrollback.isAtBottom()) {
            self.in_scroll_mode = false;
        }
    }

    pub fn exitScrollMode(self: *Pane) void {
        self.scrollback.scrollToBottom();
        self.in_scroll_mode = false;
    }

    // Copy mode operations
    pub fn enterCopyMode(self: *Pane) void {
        self.copy_mode.active = true;
        self.copy_mode.cursor_x = 0;
        self.copy_mode.cursor_y = 0;
        self.in_scroll_mode = true;
    }

    pub fn exitCopyMode(self: *Pane) void {
        self.copy_mode.active = false;
        self.copy_mode.clearSelection();
        self.exitScrollMode();
    }

    pub fn toggleSelection(self: *Pane) void {
        if (self.copy_mode.selection_active) {
            self.copy_mode.clearSelection();
        } else {
            self.copy_mode.startSelection();
        }
    }

    // Get selected text from scrollback
    pub fn getSelectedText(self: *Pane) ?[]const u8 {
        if (!self.copy_mode.selection_active) return null;
        _ = self.copy_mode.selection_start_y orelse return null;
        const end_y = self.copy_mode.cursor_y;

        // For simplicity, return the line at cursor position
        // A full implementation would handle multi-line selection
        const lines = self.scrollback.lines.items;
        if (end_y < lines.len) {
            return lines[end_y];
        }
        return null;
    }

    // Copy mode cursor movement
    pub fn copyModeMoveUp(self: *Pane) void {
        if (self.copy_mode.cursor_y > 0) {
            self.copy_mode.cursor_y -= 1;
        } else {
            self.scrollUp(1);
        }
    }

    pub fn copyModeMoveDown(self: *Pane, max_visible: usize) void {
        if (self.copy_mode.cursor_y < max_visible - 1) {
            self.copy_mode.cursor_y += 1;
        } else {
            self.scrollDown(1);
        }
    }

    pub fn copyModeMoveLeft(self: *Pane) void {
        self.copy_mode.cursor_x = self.copy_mode.cursor_x -| 1;
    }

    pub fn copyModeMoveRight(self: *Pane, max_width: usize) void {
        self.copy_mode.cursor_x = @min(self.copy_mode.cursor_x + 1, max_width);
    }
};
