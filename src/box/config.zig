const std = @import("std");

pub const BoxConfig = struct {
    separator_char: u8 = '=',
    style: []const u8 = "separator",

    pub fn load(allocator: std.mem.Allocator) !BoxConfig {
        const path = try resolvePath(allocator);
        defer allocator.free(path);

        const file = std.fs.openFileAbsolute(path, .{}) catch return .{};
        defer file.close();

        const contents = try file.readToEndAlloc(allocator, 64 * 1024);
        defer allocator.free(contents);

        var config = BoxConfig{};
        var it = std.mem.splitScalar(u8, contents, '\n');
        while (it.next()) |line| {
            if (std.mem.startsWith(u8, line, "separator_char")) {
                if (std.mem.indexOfScalar(u8, line, '"')) |idx| {
                    if (idx + 1 < line.len) config.separator_char = line[idx + 1];
                }
            } else if (std.mem.startsWith(u8, line, "style")) {
                if (std.mem.indexOfScalar(u8, line, '"')) |idx| {
                    const end = std.mem.indexOfScalarPos(u8, line, idx + 1, '"') orelse line.len;
                    if (idx + 1 < end) config.style = try allocator.dupe(u8, line[idx + 1 .. end]);
                }
            }
        }
        return config;
    }

    fn resolvePath(allocator: std.mem.Allocator) ![]const u8 {
        if (std.posix.getenv("XDG_CONFIG_HOME")) |dir| {
            return std.fs.path.join(allocator, &.{ dir, "blox", "box.toml" });
        }
        if (std.posix.getenv("HOME")) |dir| {
            return std.fs.path.join(allocator, &.{ dir, ".config", "blox", "box.toml" });
        }
        return error.ConfigNotFound;
    }
};
