const std = @import("std");
const core = @import("core");

pub const MouseAction = enum {
    none,
    copy_latest,
    toggle_collapse,
};

pub const ClickableRegion = struct {
    block_id: usize,
    action: MouseAction,
    x_start: u16,
    x_end: u16,
    y: u16,
};

pub const MouseHandler = struct {
    allocator: std.mem.Allocator,
    regions: std.ArrayList(ClickableRegion) = .empty,

    pub fn init(allocator: std.mem.Allocator) MouseHandler {
        return MouseHandler{ .allocator = allocator };
    }

    pub fn deinit(self: *MouseHandler) void {
        self.regions.deinit(self.allocator);
    }

    pub fn isMouse(input: []const u8) bool {
        return core.mouse.isMouseEvent(input);
    }

    pub fn handle(self: *MouseHandler, input: []const u8) MouseAction {
        const event = core.mouse.parseSgr(input) catch return .none;
        if (!event.pressed) return .none;

        for (self.regions.items) |region| {
            if (event.x >= region.x_start and event.x <= region.x_end and event.y == region.y) {
                return region.action;
            }
        }
        return .none;
    }

    pub fn addRegion(self: *MouseHandler, block_id: usize, action: MouseAction, x_start: u16, x_end: u16, y: u16) !void {
        try self.regions.append(self.allocator, .{
            .block_id = block_id,
            .action = action,
            .x_start = x_start,
            .x_end = x_end,
            .y = y,
        });
    }

    pub fn clearRegions(self: *MouseHandler) void {
        self.regions.clearRetainingCapacity();
    }
};
