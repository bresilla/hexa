const std = @import("std");
const Layout = @import("layout.zig");

// Box drawing characters (Unicode)
const BOX_HORIZONTAL = "─";
const BOX_VERTICAL = "│";
const BOX_TOP_LEFT = "┌";
const BOX_TOP_RIGHT = "┐";
const BOX_BOTTOM_LEFT = "└";
const BOX_BOTTOM_RIGHT = "┘";
const BOX_CROSS = "┼";
const BOX_T_DOWN = "┬";
const BOX_T_UP = "┴";
const BOX_T_RIGHT = "├";
const BOX_T_LEFT = "┤";

pub const Renderer = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Renderer {
        return .{ .allocator = allocator };
    }

    pub fn renderHeader(self: *Renderer, title: []const u8, width: u16) ![]u8 {
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(self.allocator);
        try output.append(self.allocator, '\r');
        try output.append(self.allocator, '\n');
        try output.appendSlice(self.allocator, title);
        const remaining = if (width > title.len) width - title.len else 0;
        try output.appendNTimes(self.allocator, ' ', remaining);
        return try output.toOwnedSlice(self.allocator);
    }

    pub fn renderTabBar(self: *Renderer, titles: []const []const u8, active: usize, width: u16) ![]u8 {
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(self.allocator);

        // Save cursor position and move to top
        try output.appendSlice(self.allocator, "\x1b7\x1b[1;1H");

        // Highlight active tab with reverse video
        for (titles, 0..) |title, idx| {
            if (idx == active) {
                try output.appendSlice(self.allocator, "\x1b[7m[");
                try output.appendSlice(self.allocator, title);
                try output.appendSlice(self.allocator, "]\x1b[0m ");
            } else {
                try output.appendSlice(self.allocator, " ");
                try output.appendSlice(self.allocator, title);
                try output.appendSlice(self.allocator, "  ");
            }
        }

        const used = output.items.len - 10; // Subtract escape sequence length
        const remaining = if (width > used) width - @as(u16, @intCast(used)) else 0;
        try output.appendNTimes(self.allocator, ' ', remaining);

        // Restore cursor position
        try output.appendSlice(self.allocator, "\x1b8");

        return try output.toOwnedSlice(self.allocator);
    }

    pub fn renderBorders(self: *Renderer, rects: []const Layout.Rect) ![]u8 {
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(self.allocator);

        for (rects) |rect| {
            _ = try output.writer(self.allocator).print("\x1b[{d};{d}H+", .{ rect.y + 1, rect.x + 1 });
            if (rect.width > 1) {
                try output.appendNTimes(self.allocator, '-', rect.width - 1);
            }
        }

        return try output.toOwnedSlice(self.allocator);
    }

    // Render full pane borders with box drawing characters
    pub fn renderPaneBorders(self: *Renderer, rects: []const Layout.Rect, active_pane: usize) ![]u8 {
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(self.allocator);

        for (rects, 0..) |rect, pane_idx| {
            const is_active = pane_idx == active_pane;
            const color = if (is_active) "\x1b[36m" else "\x1b[90m"; // Cyan for active, gray for inactive

            try output.appendSlice(self.allocator, color);

            // Top border
            _ = try output.writer(self.allocator).print("\x1b[{d};{d}H", .{ rect.y + 1, rect.x + 1 });
            try output.appendSlice(self.allocator, BOX_TOP_LEFT);
            var i: u16 = 1;
            while (i < rect.width -| 1) : (i += 1) {
                try output.appendSlice(self.allocator, BOX_HORIZONTAL);
            }
            if (rect.width > 1) {
                try output.appendSlice(self.allocator, BOX_TOP_RIGHT);
            }

            // Side borders
            var y: u16 = 1;
            while (y < rect.height -| 1) : (y += 1) {
                // Left border
                _ = try output.writer(self.allocator).print("\x1b[{d};{d}H", .{ rect.y + y + 1, rect.x + 1 });
                try output.appendSlice(self.allocator, BOX_VERTICAL);

                // Right border
                if (rect.width > 1) {
                    _ = try output.writer(self.allocator).print("\x1b[{d};{d}H", .{ rect.y + y + 1, rect.x + rect.width });
                    try output.appendSlice(self.allocator, BOX_VERTICAL);
                }
            }

            // Bottom border
            if (rect.height > 1) {
                _ = try output.writer(self.allocator).print("\x1b[{d};{d}H", .{ rect.y + rect.height, rect.x + 1 });
                try output.appendSlice(self.allocator, BOX_BOTTOM_LEFT);
                i = 1;
                while (i < rect.width -| 1) : (i += 1) {
                    try output.appendSlice(self.allocator, BOX_HORIZONTAL);
                }
                if (rect.width > 1) {
                    try output.appendSlice(self.allocator, BOX_BOTTOM_RIGHT);
                }
            }

            try output.appendSlice(self.allocator, "\x1b[0m"); // Reset color
        }

        return try output.toOwnedSlice(self.allocator);
    }

    // Set scroll region for a pane to confine output
    pub fn setScrollRegion(self: *Renderer, rect: Layout.Rect) ![]u8 {
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(self.allocator);

        // Set scroll region (top;bottom)
        // Account for border (1 char on each side)
        const top = rect.y + 2; // After top border
        const bottom = rect.y + rect.height - 1; // Before bottom border

        if (bottom > top) {
            _ = try output.writer(self.allocator).print("\x1b[{d};{d}r", .{ top, bottom });
            // Move cursor to scroll region
            _ = try output.writer(self.allocator).print("\x1b[{d};{d}H", .{ top, rect.x + 2 });
        }

        return try output.toOwnedSlice(self.allocator);
    }

    // Reset scroll region to full screen
    pub fn resetScrollRegion(self: *Renderer) ![]u8 {
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(self.allocator);
        try output.appendSlice(self.allocator, "\x1b[r");
        return try output.toOwnedSlice(self.allocator);
    }

    // Render status line at bottom of screen
    pub fn renderStatusLine(self: *Renderer, session_name: []const u8, window_name: []const u8, pane_id: usize, is_zoomed: bool, width: u16, height: u16) ![]u8 {
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(self.allocator);

        // Save cursor and move to bottom line
        _ = try output.writer(self.allocator).print("\x1b7\x1b[{d};1H", .{height});

        // Background color for status line
        try output.appendSlice(self.allocator, "\x1b[48;5;236m\x1b[38;5;250m");

        // Left side: session and window info
        try output.appendSlice(self.allocator, " [");
        try output.appendSlice(self.allocator, session_name);
        try output.appendSlice(self.allocator, "] ");
        try output.appendSlice(self.allocator, window_name);

        if (is_zoomed) {
            try output.appendSlice(self.allocator, " \x1b[33m*Z*\x1b[38;5;250m");
        }

        // Pane info
        _ = try output.writer(self.allocator).print(" | Pane {d}", .{pane_id});

        // Fill rest of line with spaces
        const used = output.items.len - 20; // Approximate escape sequence overhead
        var remaining = if (width > used) width - @as(u16, @intCast(used)) else 0;
        while (remaining > 0) : (remaining -= 1) {
            try output.append(self.allocator, ' ');
        }

        // Reset colors and restore cursor
        try output.appendSlice(self.allocator, "\x1b[0m\x1b8");

        return try output.toOwnedSlice(self.allocator);
    }

    // Render a combined header with time
    pub fn renderHeaderWithTime(self: *Renderer, title: []const u8, width: u16) ![]u8 {
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(self.allocator);

        try output.appendSlice(self.allocator, "\x1b[1;1H\x1b[48;5;24m\x1b[37m");
        try output.appendSlice(self.allocator, " ");
        try output.appendSlice(self.allocator, title);

        // Fill with spaces
        const title_len = title.len + 1;
        var remaining = if (width > title_len) width - @as(u16, @intCast(title_len)) else 0;
        while (remaining > 0) : (remaining -= 1) {
            try output.append(self.allocator, ' ');
        }

        try output.appendSlice(self.allocator, "\x1b[0m");

        return try output.toOwnedSlice(self.allocator);
    }
};
