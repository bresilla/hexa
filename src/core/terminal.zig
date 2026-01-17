pub const TerminalState = struct {
    cursor_row: u16 = 1,
    cursor_col: u16 = 1,
    cursor_visible: bool = true,
    alt_screen: bool = false,

    pub fn reset(self: *TerminalState) void {
        self.* = .{};
    }

    pub fn move(self: *TerminalState, row: u16, col: u16) void {
        self.cursor_row = row;
        self.cursor_col = col;
    }
};
