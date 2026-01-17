const std = @import("std");
const Window = @import("window.zig").Window;

pub const Session = struct {
    allocator: std.mem.Allocator,
    windows: std.ArrayList(Window) = .empty,
    active_index: usize = 0,

    pub fn init(allocator: std.mem.Allocator) !Session {
        var session = Session{
            .allocator = allocator,
        };
        try session.windows.append(allocator, try Window.init(allocator, 1));
        return session;
    }

    pub fn deinit(self: *Session) void {
        for (self.windows.items) |*window| {
            window.deinit();
        }
        self.windows.deinit(self.allocator);
    }

    pub fn activeWindow(self: *Session) *Window {
        return &self.windows.items[self.active_index];
    }

    pub fn windowTitles(self: *Session, allocator: std.mem.Allocator) ![][]const u8 {
        const list = try allocator.alloc([]const u8, self.windows.items.len);
        for (self.windows.items, 0..) |window, i| {
            list[i] = window.name;
        }
        return list;
    }
};
