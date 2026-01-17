const std = @import("std");

pub const MuxConfig = struct {
    shell: []const u8 = "/bin/sh",

    pub fn load(allocator: std.mem.Allocator) !MuxConfig {
        const path = try resolvePath(allocator);
        defer allocator.free(path);

        const file = std.fs.openFileAbsolute(path, .{}) catch return .{};
        defer file.close();

        const contents = try file.readToEndAlloc(allocator, 64 * 1024);
        defer allocator.free(contents);

        var config = MuxConfig{};
        var it = std.mem.splitScalar(u8, contents, '\n');
        while (it.next()) |line| {
            if (std.mem.startsWith(u8, line, "shell")) {
                if (std.mem.indexOfScalar(u8, line, '"')) |idx| {
                    if (idx + 1 < line.len) {
                        const end = std.mem.indexOfScalarPos(u8, line, idx + 1, '"') orelse line.len;
                        config.shell = try allocator.dupe(u8, line[idx + 1 .. end]);
                    }
                }
            }
        }
        return config;
    }

    fn resolvePath(allocator: std.mem.Allocator) ![]const u8 {
        if (std.posix.getenv("XDG_CONFIG_HOME")) |dir| {
            return std.fs.path.join(allocator, &.{ dir, "blox", "mux.toml" });
        }
        if (std.posix.getenv("HOME")) |dir| {
            return std.fs.path.join(allocator, &.{ dir, ".config", "blox", "mux.toml" });
        }
        return error.ConfigNotFound;
    }
};
