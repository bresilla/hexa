const std = @import("std");

pub const MouseEvent = struct {
    x: u16,
    y: u16,
    button: u8,
    pressed: bool,
};

pub fn isMouseEvent(input: []const u8) bool {
    return input.len >= 3 and input[0] == 0x1b and input[1] == '[';
}

pub fn parseSgr(input: []const u8) !MouseEvent {
    var parts = std.mem.splitScalar(u8, input, ';');
    const first = parts.next() orelse return error.InvalidFormat;
    if (first.len < 3 or first[0] != 0x1b or first[1] != '[' or first[2] != '<') {
        return error.InvalidFormat;
    }
    const button = try std.fmt.parseInt(u8, first[3..], 10);
    const x = try std.fmt.parseInt(u16, parts.next() orelse return error.InvalidFormat, 10);
    const y_token = parts.next() orelse return error.InvalidFormat;
    const pressed = y_token[y_token.len - 1] == 'M';
    const y = try std.fmt.parseInt(u16, y_token[0 .. y_token.len - 1], 10);
    return MouseEvent{
        .x = x,
        .y = y,
        .button = button,
        .pressed = pressed,
    };
}
