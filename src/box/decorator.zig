const std = @import("std");
const Block = @import("block.zig").Block;

pub const Decorator = struct {
    allocator: std.mem.Allocator,
    separator_char: u8 = '=',

    pub fn init(allocator: std.mem.Allocator) Decorator {
        return Decorator{ .allocator = allocator };
    }

    pub fn render(self: *const Decorator, block: *const Block, width: usize) ![]u8 {
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(self.allocator);

        var info: std.ArrayList(u8) = .empty;
        defer info.deinit(self.allocator);

        const status = if (block.exit_code orelse 0 == 0) "ok" else "err";
        try info.writer(self.allocator).print("│ {d} │ {s}{d}", .{ block.id, status, block.exit_code orelse 0 });
        if (block.collapsed) {
            try info.writer(self.allocator).writeAll(" [collapsed]");
        }

        if (block.durationSeconds()) |duration| {
            try info.writer(self.allocator).print(" {d:.1}s", .{duration});
        }

        const fill = if (width > info.items.len) width - info.items.len else 0;
        try output.append(self.allocator, '\n');
        try output.appendNTimes(self.allocator, self.separator_char, fill);
        try output.appendSlice(self.allocator, info.items);
        try output.append(self.allocator, '\n');

        return try output.toOwnedSlice(self.allocator);
    }
};
