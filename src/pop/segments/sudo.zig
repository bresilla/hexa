const std = @import("std");
const Segment = @import("../segment.zig").Segment;
const Context = @import("../segment.zig").Context;
const Style = @import("../style.zig").Style;

/// Sudo segment - displays indicator if sudo credentials are cached
/// Format:
pub fn render(ctx: *Context) ?[]const Segment {
    // Check if SUDO_USER is set (we're in a sudo session)
    if (std.posix.getenv("SUDO_USER")) |_| {
        const text = ctx.allocText("") catch return null;
        return ctx.addSegment(text, Style.parse("bold fg:yellow")) catch return null;
    }

    // Alternative: check if running as root
    if (std.posix.getenv("USER")) |user| {
        if (std.mem.eql(u8, user, "root")) {
            const text = ctx.allocText("#") catch return null;
            return ctx.addSegment(text, Style.parse("bold fg:red")) catch return null;
        }
    }

    return null;
}
