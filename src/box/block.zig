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
};
