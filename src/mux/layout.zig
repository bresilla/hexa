const std = @import("std");

pub const Rect = struct {
    x: u16,
    y: u16,
    width: u16,
    height: u16,
};

pub const LayoutEngine = struct {
    pub fn horizontal(allocator: std.mem.Allocator, count: usize, width: u16, height: u16) ![]Rect {
        const rects = try allocator.alloc(Rect, count);
        if (count == 0) return rects;
        const pane_width = width / @as(u16, @intCast(count));
        var offset: u16 = 0;
        for (rects, 0..) |*rect, i| {
            const w = if (i + 1 == count) width - offset else pane_width;
            rect.* = .{ .x = offset, .y = 0, .width = w, .height = height };
            offset += w;
        }
        return rects;
    }

    pub fn vertical(allocator: std.mem.Allocator, count: usize, width: u16, height: u16) ![]Rect {
        const rects = try allocator.alloc(Rect, count);
        if (count == 0) return rects;
        const pane_height = height / @as(u16, @intCast(count));
        var offset: u16 = 0;
        for (rects, 0..) |*rect, i| {
            const h = if (i + 1 == count) height - offset else pane_height;
            rect.* = .{ .x = 0, .y = offset, .width = width, .height = h };
            offset += h;
        }
        return rects;
    }
};
