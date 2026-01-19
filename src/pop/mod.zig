// Pop - Prompt and status bar segment system
// Used by both mux status bar and shell prompt

pub const style = @import("style.zig");
pub const format = @import("format.zig");
pub const segment = @import("segment.zig");
pub const segments = @import("segments/mod.zig");
pub const entry = @import("main.zig");

pub const Style = style.Style;
pub const Color = style.Color;
pub const FormatParser = format.FormatParser;
pub const Segment = segment.Segment;
pub const Context = segment.Context;

// Re-export entry point types for CLI
pub const PopArgs = entry.PopArgs;
pub const run = entry.run;

/// Render a format string with the given context
pub fn render(allocator: std.mem.Allocator, format_str: []const u8, ctx: *Context) ![]Segment {
    var parser = FormatParser.init(allocator, format_str);
    return parser.render(ctx);
}

/// Render a format string to ANSI output
pub fn renderToAnsi(allocator: std.mem.Allocator, format_str: []const u8, ctx: *Context, writer: anytype) !void {
    const segs = try render(allocator, format_str, ctx);
    defer allocator.free(segs);

    for (segs) |seg| {
        try seg.style.toAnsi(writer);
        try writer.writeAll(seg.text);
    }
    try Style.reset(writer);
}

const std = @import("std");
