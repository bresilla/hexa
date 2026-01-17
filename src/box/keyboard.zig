pub const Action = enum {
    none,
    copy_latest,
    toggle_collapse,
    search_error,
};

pub const KeyboardHandler = struct {
    pub fn init() KeyboardHandler {
        return .{};
    }

    pub fn handle(self: *KeyboardHandler, key: u8) Action {
        _ = self;
        return switch (key) {
            0x03 => .copy_latest,
            0x1a => .toggle_collapse,
            0x06 => .search_error,
            else => .none,
        };
    }
};
