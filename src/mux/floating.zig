const std = @import("std");
const core = @import("core");
const Layout = @import("layout.zig");

pub const FloatingPane = struct {
    id: usize,
    pty: core.Pty,
    rect: Layout.Rect,
    visible: bool = true,

    pub fn init(allocator: std.mem.Allocator, id: usize, rect: Layout.Rect) !FloatingPane {
        _ = allocator;
        return FloatingPane{
            .id = id,
            .pty = try core.Pty.spawn("/bin/sh"),
            .rect = rect,
        };
    }

    pub fn deinit(self: *FloatingPane) void {
        self.pty.close();
    }

    pub fn read(self: *FloatingPane, buffer: []u8) !usize {
        return self.pty.read(buffer);
    }

    pub fn write(self: *FloatingPane, data: []const u8) !usize {
        return self.pty.write(data);
    }

    pub fn move(self: *FloatingPane, x: u16, y: u16) void {
        self.rect.x = x;
        self.rect.y = y;
    }

    pub fn resize(self: *FloatingPane, width: u16, height: u16) void {
        self.rect.width = width;
        self.rect.height = height;
    }
};
