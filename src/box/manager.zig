const std = @import("std");
const Block = @import("block.zig").Block;

pub const BlockManager = struct {
    allocator: std.mem.Allocator,
    blocks: std.ArrayList(Block) = .empty,
    current: ?usize = null,
    next_id: usize = 1,

    pub fn init(allocator: std.mem.Allocator) BlockManager {
        return BlockManager{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *BlockManager) void {
        for (self.blocks.items) |*block| {
            block.deinit();
        }
        self.blocks.deinit(self.allocator);
    }

    pub fn startBlock(self: *BlockManager) !void {
        const block = try Block.init(self.allocator, self.next_id);
        self.next_id += 1;
        try self.blocks.append(self.allocator, block);
        self.current = self.blocks.items.len - 1;
    }

    pub fn appendOutput(self: *BlockManager, data: []const u8) !void {
        if (self.current) |idx| {
            try self.blocks.items[idx].append(data);
        }
    }

    pub fn finishBlock(self: *BlockManager, exit_code: ?u8) void {
        if (self.current) |idx| {
            self.blocks.items[idx].finish(exit_code);
            self.current = null;
        }
    }

    pub fn latest(self: *BlockManager) ?*Block {
        if (self.blocks.items.len == 0) return null;
        return &self.blocks.items[self.blocks.items.len - 1];
    }

    pub fn toggleLatestCollapse(self: *BlockManager) void {
        if (self.latest()) |block| {
            block.toggleCollapse();
        }
    }

    pub fn search(self: *BlockManager, needle: []const u8) usize {
        var count: usize = 0;
        for (self.blocks.items) |block| {
            if (std.mem.indexOf(u8, block.output.items, needle) != null) {
                count += 1;
            }
        }
        return count;
    }
};
