pub const Action = enum {
    none,
    copy_latest,
    toggle_collapse,
    search_error,
    nav_prev, // Ctrl+Up - navigate to previous block
    nav_next, // Ctrl+Down - navigate to next block
    export_block, // Ctrl+E - export current block
    passthrough,
    passthrough_with_action, // Pass through AND do an action
};

pub const KeyboardHandler = struct {
    escape_seq: [8]u8 = undefined,
    escape_len: usize = 0,
    in_escape: bool = false,
    pending_action: Action = .none,

    pub fn init() KeyboardHandler {
        return .{};
    }

    /// Get any buffered escape sequence bytes that should be written to PTY
    pub fn getBufferedEscape(self: *KeyboardHandler) ?[]const u8 {
        if (self.escape_len > 0) {
            const result = self.escape_seq[0..self.escape_len];
            return result;
        }
        return null;
    }

    pub fn handle(self: *KeyboardHandler, key: u8) Action {
        // Handle escape sequences for arrow keys
        if (self.in_escape) {
            if (self.escape_len < self.escape_seq.len) {
                self.escape_seq[self.escape_len] = key;
                self.escape_len += 1;
            }

            // Check for complete sequences
            if (self.escape_len >= 2) {
                // CSI sequence: ESC [ ...
                if (self.escape_seq[0] == '[') {
                    // Ctrl+Up: ESC [ 1 ; 5 A - DON'T pass to shell, handle locally
                    if (self.escape_len == 5 and
                        self.escape_seq[1] == '1' and
                        self.escape_seq[2] == ';' and
                        self.escape_seq[3] == '5' and
                        self.escape_seq[4] == 'A')
                    {
                        self.in_escape = false;
                        self.escape_len = 0;
                        return .nav_prev;
                    }
                    // Ctrl+Down: ESC [ 1 ; 5 B - DON'T pass to shell, handle locally
                    if (self.escape_len == 5 and
                        self.escape_seq[1] == '1' and
                        self.escape_seq[2] == ';' and
                        self.escape_seq[3] == '5' and
                        self.escape_seq[4] == 'B')
                    {
                        self.in_escape = false;
                        self.escape_len = 0;
                        return .nav_next;
                    }

                    // Normal arrow keys or other sequences - pass through entirely
                    if (key == 'A' or key == 'B' or key == 'C' or key == 'D' or
                        key == 'H' or key == 'F' or key == '~')
                    {
                        self.in_escape = false;
                        // Keep escape_len so caller can get the full sequence
                        return .passthrough_with_action;
                    }
                }

                // Timeout - pass through if we've collected enough chars
                if (self.escape_len >= 6) {
                    self.in_escape = false;
                    return .passthrough_with_action;
                }
            }

            return .none; // Still collecting escape sequence
        }

        // Start of escape sequence
        if (key == 0x1b) {
            self.in_escape = true;
            self.escape_len = 0;
            return .none;
        }

        return switch (key) {
            0x03 => .copy_latest, // Ctrl+C
            0x1a => .toggle_collapse, // Ctrl+Z
            0x06 => .search_error, // Ctrl+F
            0x05 => .export_block, // Ctrl+E
            else => .passthrough,
        };
    }

    pub fn clearBuffer(self: *KeyboardHandler) void {
        self.escape_len = 0;
    }
};
