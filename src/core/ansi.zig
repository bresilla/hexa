const std = @import("std");

pub const CSI = "\x1b[";
pub const OSC = "\x1b]";
pub const ST = "\x1b\\";

pub fn osc133(marker: u8, exit_code: ?u8) []const u8 {
    if (exit_code) |code| {
        return std.fmt.comptimePrint("{s}133;{c};{d}{s}", .{ OSC, marker, code, ST });
    }
    return std.fmt.comptimePrint("{s}133;{c}{s}", .{ OSC, marker, ST });
}

pub fn enableMouseTracking(mode: u3) []const u8 {
    return switch (mode) {
        1 => "\x1b[?1000h",
        2 => "\x1b[?1002h",
        3 => "\x1b[?1003h",
        else => "\x1b[?1000h",
    };
}

pub fn disableMouseTracking() []const u8 {
    return "\x1b[?1000l\x1b[?1002l\x1b[?1003l";
}

pub fn enableSgrMouseMode() []const u8 {
    return "\x1b[?1006h";
}

pub fn disableSgrMouseMode() []const u8 {
    return "\x1b[?1006l";
}

pub fn clearLine() []const u8 {
    return "\x1b[2K";
}

pub fn clearScreen() []const u8 {
    return "\x1b[2J";
}
