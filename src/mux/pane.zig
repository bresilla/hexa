const std = @import("std");
const core = @import("core");

pub const Pane = struct {
    allocator: std.mem.Allocator,
    id: usize,
    pty: core.Pty,

    pub fn init(allocator: std.mem.Allocator, id: usize) !Pane {
        return Pane{
            .allocator = allocator,
            .id = id,
            .pty = try core.Pty.spawn("/bin/sh"),
        };
    }

    pub fn deinit(self: *Pane) void {
        self.pty.close();
    }

    pub fn read(self: *Pane, buffer: []u8) !usize {
        return self.pty.read(buffer);
    }

    pub fn write(self: *Pane, data: []const u8) !usize {
        return self.pty.write(data);
    }
};
