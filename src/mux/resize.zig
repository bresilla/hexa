const std = @import("std");
const core = @import("core");

pub const ResizeAction = enum {
    none,
    resize_h,
    resize_v,
};

pub const ResizeState = struct {
    resizing: bool = false,
    action: ResizeAction = .none,
    pane_index: ?usize = null,
    start_x: u16 = 0,
    start_y: u16 = 0,
};

pub const MouseResizeHandler = struct {
    allocator: std.mem.Allocator,
    resize_state: ResizeState,

    pub fn init(allocator: std.mem.Allocator) MouseResizeHandler {
        return MouseResizeHandler{
            .allocator = allocator,
            .resize_state = .{},
        };
    }

    pub fn handle(self: *MouseResizeHandler, input: []const u8, pane_count: usize) ResizeAction {
        _ = pane_count;
        if (!core.mouse.isMouseEvent(input)) return .none;

        const event = core.mouse.parseSgr(input) catch return .none;

        if (event.button == 0 and event.pressed) {
            // Start resize
            self.resize_state.resizing = true;
            self.resize_state.start_x = event.x;
            self.resize_state.start_y = event.y;
            self.resize_state.pane_index = null;

            // Determine resize direction based on position
            if (event.y == 1) {
                return .resize_v;
            } else {
                return .resize_h;
            }
        } else if (event.button == 0 and !event.pressed) {
            // End resize
            self.resize_state.resizing = false;
            self.resize_state.action = .none;
            return .none;
        } else if (self.resize_state.resizing and event.button == 0 and !event.pressed) {
            // Continue resize
            const dx = if (event.x > self.resize_state.start_x) event.x - self.resize_state.start_x else 0;
            const dy = if (event.y > self.resize_state.start_y) event.y - self.resize_state.start_y else 0;

            if (dx > 0) return .resize_h;
            if (dy > 0) return .resize_v;
        }

        return .none;
    }

    pub fn getResizeDelta(self: *MouseResizeHandler, current_x: u16, current_y: u16) struct { dx: i16, dy: i16 } {
        if (!self.resize_state.resizing) return .{ .dx = 0, .dy = 0 };

        const dx: i16 = @bitCast(@as(i32, current_x) - @as(i32, self.resize_state.start_x));
        const dy: i16 = @bitCast(@as(i32, current_y) - @as(i32, self.resize_state.start_y));

        return .{ .dx = dx, .dy = dy };
    }

    pub fn reset(self: *MouseResizeHandler) void {
        self.resize_state = .{};
    }
};
