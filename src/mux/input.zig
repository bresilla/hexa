pub const Action = enum {
    none,
    split_h,
    split_v,
    next_pane,
    close_pane,
    next_window,
    prev_window,
    new_window,
    new_session,
    list_sessions,
    switch_session,
    new_float,
    close_float,
    detach,
    scroll_up,
    scroll_down,
    scroll_page_up,
    scroll_page_down,
    scroll_top,
    scroll_bottom,
    zoom_pane,
    copy_mode,
};

pub const InputHandler = struct {
    prefix: u8 = 0x01, // ctrl+a
    waiting_prefix: bool = false,
    switch_session_index: ?usize = null,

    pub fn init() InputHandler {
        return .{};
    }

    pub fn handle(self: *InputHandler, key: u8) Action {
        if (self.switch_session_index) |*idx| {
            if (key >= '0' and key <= '9') {
                idx.* = idx.* * 10 + (key - '0');
                return .none;
            } else if (key == '\r' or key == '\n') {
                const idx_val = idx.*;
                self.switch_session_index = null;
                if (idx_val > 0) {
                    return .switch_session;
                }
                return .none;
            } else {
                self.switch_session_index = null;
            }
        }

        if (self.waiting_prefix) {
            self.waiting_prefix = false;
            if (key == '|') return .split_h;
            if (key == '-') return .split_v;
            if (key == 'o') return .next_pane;
            if (key == 'x') return .close_pane;
            if (key == 'n') return .new_window;
            if (key == 'w') return .next_window;
            if (key == 'W') return .prev_window;
            if (key == 's') return .new_session;
            if (key == 'l') return .list_sessions;
            if (key == 'f') return .new_float;
            if (key == 'F') return .close_float;
            if (key == 'd') return .detach;
            if (key == 'z') return .zoom_pane;
            if (key == '[') return .copy_mode; // Enter scroll/copy mode
            if (key == 'k') return .scroll_up;
            if (key == 'j') return .scroll_down;
            if (key == 'u') return .scroll_page_up; // Page up (half screen)
            if (key == 'D') return .scroll_page_down; // Page down (half screen)
            if (key == 'g') return .scroll_top;
            if (key == 'G') return .scroll_bottom;
            if (key >= '0' and key <= '9') {
                self.switch_session_index = key - '0';
                return .none;
            }
            return .none;
        }

        if (key == self.prefix) {
            self.waiting_prefix = true;
            return .none;
        }

        return .none;
    }

    pub fn getSwitchSessionIndex(self: *InputHandler) ?usize {
        const idx = self.switch_session_index;
        self.switch_session_index = null;
        return idx;
    }
};
