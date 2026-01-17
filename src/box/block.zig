const std = @import("std");

pub const Block = struct {
    id: usize,
    allocator: std.mem.Allocator,
    output: std.ArrayList(u8) = .empty,
    exit_code: ?u8 = null,
    start_time: std.time.Instant,
    end_time: ?std.time.Instant = null,
    collapsed: bool = false,

    pub fn init(allocator: std.mem.Allocator, id: usize) !Block {
        return Block{
            .id = id,
            .allocator = allocator,
            .start_time = try std.time.Instant.now(),
        };
    }

    pub fn deinit(self: *Block) void {
        self.output.deinit(self.allocator);
    }

    pub fn append(self: *Block, data: []const u8) !void {
        try self.output.appendSlice(self.allocator, data);
    }

    pub fn finish(self: *Block, exit_code: ?u8) void {
        self.exit_code = exit_code;
        self.end_time = std.time.Instant.now() catch null;
    }

    pub fn toggleCollapse(self: *Block) void {
        self.collapsed = !self.collapsed;
    }

    pub fn durationSeconds(self: *const Block) ?f64 {
        if (self.end_time) |end| {
            return @as(f64, @floatFromInt(end.since(self.start_time))) / 1_000_000_000.0;
        }
        return null;
    }

    // Export block to markdown format
    pub fn toMarkdown(self: *const Block, allocator: std.mem.Allocator) ![]u8 {
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(allocator);

        // Header with block ID and exit code
        _ = try output.writer(allocator).print("## Block {d}\n\n", .{self.id});

        // Exit status
        if (self.exit_code) |code| {
            if (code == 0) {
                try output.appendSlice(allocator, "**Status:** Success (exit code 0)\n\n");
            } else {
                _ = try output.writer(allocator).print("**Status:** Failed (exit code {d})\n\n", .{code});
            }
        } else {
            try output.appendSlice(allocator, "**Status:** Unknown\n\n");
        }

        // Duration
        if (self.durationSeconds()) |duration| {
            _ = try output.writer(allocator).print("**Duration:** {d:.2}s\n\n", .{duration});
        }

        // Output in code block
        try output.appendSlice(allocator, "```\n");
        try output.appendSlice(allocator, self.output.items);
        if (self.output.items.len > 0 and self.output.items[self.output.items.len - 1] != '\n') {
            try output.append(allocator, '\n');
        }
        try output.appendSlice(allocator, "```\n\n");

        return try output.toOwnedSlice(allocator);
    }

    // Export block output as plain text
    pub fn toPlainText(self: *const Block) []const u8 {
        return self.output.items;
    }
};
