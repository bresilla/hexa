const std = @import("std");
const Layout = @import("layout.zig");

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

        for (titles, 0..) |title, idx| {
            const prefix = if (idx == active) "[" else " ";
            const suffix = if (idx == active) "]" else " ";
            try output.appendSlice(self.allocator, prefix);
            try output.appendSlice(self.allocator, title);
            try output.appendSlice(self.allocator, suffix);
            try output.append(self.allocator, ' ');
        }

        const remaining = if (width > output.items.len) width - output.items.len else 0;
        try output.appendNTimes(self.allocator, ' ', remaining);
        try output.append(self.allocator, '\n');

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
};
