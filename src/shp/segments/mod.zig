const std = @import("std");
const Segment = @import("../segment.zig").Segment;
const Context = @import("../segment.zig").Context;

// System stats segments (for mux status bar)
pub const time = @import("time.zig");
pub const netspeed = @import("netspeed.zig");
pub const uptime = @import("uptime.zig");
pub const cpu = @import("cpu.zig");
pub const memory = @import("memory.zig");
pub const battery = @import("battery.zig");

// Shell context segments (for prompt)
pub const directory = @import("directory.zig");
pub const hostname = @import("hostname.zig");
pub const username = @import("username.zig");

// Git segments
pub const git_branch = @import("git_branch.zig");
pub const git_status = @import("git_status.zig");

// Shell state segments
pub const status = @import("status.zig");
pub const sudo = @import("sudo.zig");
pub const character = @import("character.zig");
pub const duration = @import("duration.zig");
pub const jobs = @import("jobs.zig");

// Custom segments (shell command runner)
pub const custom = @import("custom.zig");

/// Segment render function type
pub const SegmentFn = *const fn (ctx: *Context) ?[]const Segment;

/// Registry of built-in segments
pub const registry = std.StaticStringMap(SegmentFn).initComptime(.{
    // System stats (mux status bar)
    .{ "time", time.render },
    .{ "netspeed", netspeed.render },
    .{ "uptime", uptime.render },
    .{ "cpu", cpu.render },
    .{ "mem", memory.render },
    .{ "memory", memory.render },
    .{ "battery", battery.render },

    // Shell context (prompt)
    .{ "directory", directory.render },
    .{ "dir", directory.render },
    .{ "hostname", hostname.render },
    .{ "host", hostname.render },
    .{ "username", username.render },
    .{ "user", username.render },

    // Git
    .{ "git_branch", git_branch.render },
    .{ "git", git_branch.render },
    .{ "git_status", git_status.render },

    // Shell state
    .{ "status", status.render },
    .{ "sudo", sudo.render },
    .{ "character", character.render },
    .{ "char", character.render },
    .{ "duration", duration.render },
    .{ "jobs", jobs.render },
});
