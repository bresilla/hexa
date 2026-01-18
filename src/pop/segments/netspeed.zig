const std = @import("std");
const Segment = @import("../segment.zig").Segment;
const Context = @import("../segment.zig").Context;
const Style = @import("../style.zig").Style;

// Persistent state for tracking network bytes between calls
var last_rx_bytes: u64 = 0;
var last_tx_bytes: u64 = 0;
var last_time_ns: i128 = 0;
var cached_iface: [32]u8 = undefined;
var cached_iface_len: usize = 0;

/// Netspeed segment - displays network upload/download speed
/// Format: ▲468K | ▼130K
pub fn render(ctx: *Context) ?[]const Segment {
    // Get active interface
    const iface = getActiveInterface() orelse return null;

    // Read current bytes
    const rx_bytes = readSysFile("/sys/class/net/", iface, "/statistics/rx_bytes") orelse return null;
    const tx_bytes = readSysFile("/sys/class/net/", iface, "/statistics/tx_bytes") orelse return null;

    const now_ns = std.time.nanoTimestamp();

    // Calculate speed if we have previous data
    var rx_speed: u64 = 0;
    var tx_speed: u64 = 0;

    if (last_time_ns > 0) {
        const elapsed_ns: u64 = @intCast(now_ns - last_time_ns);
        if (elapsed_ns > 0) {
            const elapsed_sec = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0;
            if (rx_bytes >= last_rx_bytes) {
                rx_speed = @intFromFloat(@as(f64, @floatFromInt(rx_bytes - last_rx_bytes)) / elapsed_sec);
            }
            if (tx_bytes >= last_tx_bytes) {
                tx_speed = @intFromFloat(@as(f64, @floatFromInt(tx_bytes - last_tx_bytes)) / elapsed_sec);
            }
        }
    }

    // Update cached values
    last_rx_bytes = rx_bytes;
    last_tx_bytes = tx_bytes;
    last_time_ns = now_ns;

    // Format the output
    const tx_str = formatBytes(ctx, tx_speed) orelse return null;
    const rx_str = formatBytes(ctx, rx_speed) orelse return null;

    const text = ctx.allocFmt("▲{s} | ▼{s}", .{ tx_str, rx_str }) catch return null;

    return ctx.addSegment(text, Style{}) catch return null;
}

fn getActiveInterface() ?[]const u8 {
    // Check cached
    if (cached_iface_len > 0) {
        return cached_iface[0..cached_iface_len];
    }

    // Read /proc/net/route to find default interface
    const file = std.fs.openFileAbsolute("/proc/net/route", .{}) catch return null;
    defer file.close();

    var buf: [2048]u8 = undefined;
    const len = file.read(&buf) catch return null;
    const content = buf[0..len];

    // Parse lines
    var lines = std.mem.tokenizeScalar(u8, content, '\n');
    _ = lines.next(); // Skip header

    // Find default route (destination 00000000)
    while (lines.next()) |line| {
        var iter = std.mem.tokenizeAny(u8, line, " \t");
        const iface = iter.next() orelse continue;
        const dest = iter.next() orelse continue;

        if (std.mem.eql(u8, dest, "00000000")) {
            // Found default route
            if (iface.len <= cached_iface.len) {
                @memcpy(cached_iface[0..iface.len], iface);
                cached_iface_len = iface.len;
                return cached_iface[0..cached_iface_len];
            }
        }
    }

    return null;
}

fn readSysFile(prefix: []const u8, iface: []const u8, suffix: []const u8) ?u64 {
    var path_buf: [128]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}{s}{s}", .{ prefix, iface, suffix }) catch return null;

    const file = std.fs.openFileAbsolute(path, .{}) catch return null;
    defer file.close();

    var buf: [32]u8 = undefined;
    const len = file.read(&buf) catch return null;
    const str = std.mem.trim(u8, buf[0..len], " \t\n");

    return std.fmt.parseInt(u64, str, 10) catch null;
}

fn formatBytes(ctx: *Context, bytes: u64) ?[]const u8 {
    if (bytes >= 1024 * 1024) {
        const mb = @as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0);
        if (mb >= 100.0) {
            return ctx.allocFmt("{d:>3.0}M", .{mb}) catch return null;
        } else if (mb >= 10.0) {
            return ctx.allocFmt("{d:>4.1}M", .{mb}) catch return null;
        } else {
            return ctx.allocFmt("{d:>4.2}M", .{mb}) catch return null;
        }
    } else {
        const kb = bytes / 1024;
        // Fixed 3-digit width for KB values
        return ctx.allocFmt("{d:>3}K", .{kb}) catch return null;
    }
}
