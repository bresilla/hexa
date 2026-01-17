pub const Action = enum {
    none,
    split_h,
    split_v,
    next_pane,
    close_pane,
};

pub const InputHandler = struct {
    prefix: u8 = 0x01, // ctrl+a
    waiting_prefix: bool = false,

    pub fn init() InputHandler {
        return .{};
    }

    pub fn handle(self: *InputHandler, key: u8) Action {
        if (self.waiting_prefix) {
            self.waiting_prefix = false;
            return switch (key) {
                '|' => .split_h,
                '-' => .split_v,
                'o' => .next_pane,
                'x' => .close_pane,
                else => .none,
            };
        }

        if (key == self.prefix) {
            self.waiting_prefix = true;
            return .none;
        }

        return .none;
    }
};
