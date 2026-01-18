const std = @import("std");
const Segment = @import("../segment.zig").Segment;
const Context = @import("../segment.zig").Context;
const Style = @import("../style.zig").Style;

// Persistent state for CPU calculation
var last_idle: u64 = 0;
var last_total: u64 = 0;

/// CPU segment - displays CPU usage percentage
/// Format: 94
pub fn render(ctx: *Context) ?[]const Segment {
    // Read /proc/stat
    const file = std.fs.openFileAbsolute("/proc/stat", .{}) catch return null;
    defer file.close();

    var buf: [256]u8 = undefined;
    const len = file.read(&buf) catch return null;
    const str = buf[0..len];

    // Parse first line (cpu aggregate)
    var lines = std.mem.tokenizeScalar(u8, str, '\n');
    const cpu_line = lines.next() orelse return null;

    if (!std.mem.startsWith(u8, cpu_line, "cpu ")) return null;

    // Parse: cpu user nice system idle iowait irq softirq steal guest guest_nice
    var iter = std.mem.tokenizeAny(u8, cpu_line, " ");
    _ = iter.next(); // skip "cpu"

    var values: [10]u64 = undefined;
    var i: usize = 0;
    while (iter.next()) |val| {
        if (i >= 10) break;
        values[i] = std.fmt.parseInt(u64, val, 10) catch 0;
        i += 1;
    }

    if (i < 4) return null;

    // Calculate totals
    // user, nice, system, idle, iowait, irq, softirq, steal
    var total: u64 = 0;
    for (values[0..@min(i, 8)]) |v| {
        total += v;
    }

    const idle = values[3]; // idle is 4th field

    // Calculate percentage
    var cpu_percent: u64 = 0;
    if (last_total > 0 and total > last_total) {
        const total_diff = total - last_total;
        const idle_diff = idle - last_idle;
        if (total_diff > 0) {
            cpu_percent = ((total_diff - idle_diff) * 100) / total_diff;
        }
    }

    // Update cached values
    last_idle = idle;
    last_total = total;

    const text = ctx.allocFmt("{d}", .{cpu_percent}) catch return null;
    return ctx.addSegment(text, Style{}) catch return null;
}
