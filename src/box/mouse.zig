const core = @import("core");

pub const MouseHandler = struct {
    pub fn init() MouseHandler {
        return .{};
    }

    pub fn isMouse(input: []const u8) bool {
        return core.mouse.isMouseEvent(input);
    }

    pub fn handle(self: *MouseHandler, input: []const u8) void {
        _ = self;
        _ = input;
    }
};
