const std = @import("std");
const Window = @import("window.zig").Window;

pub const Session = struct {
    allocator: std.mem.Allocator,
    name: []const u8,
    windows: std.ArrayList(Window) = .empty,
    active_index: usize = 0,

    pub fn init(allocator: std.mem.Allocator, name: []const u8) !Session {
        var session = Session{
            .allocator = allocator,
            .name = try allocator.dupe(u8, name),
        };
        try session.windows.append(allocator, try Window.init(allocator, 1));
        return session;
    }

    pub fn deinit(self: *Session) void {
        for (self.windows.items) |*window| {
            window.deinit();
        }
        self.windows.deinit(self.allocator);
        self.allocator.free(self.name);
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

    pub fn addWindow(self: *Session) !void {
        const id = self.windows.items.len + 1;
        try self.windows.append(self.allocator, try Window.init(self.allocator, id));
        self.active_index = self.windows.items.len - 1;
    }

    pub fn nextWindow(self: *Session) void {
        if (self.windows.items.len <= 1) return;
        self.active_index = (self.active_index + 1) % self.windows.items.len;
    }

    pub fn prevWindow(self: *Session) void {
        if (self.windows.items.len <= 1) return;
        if (self.active_index == 0) {
            self.active_index = self.windows.items.len - 1;
        } else {
            self.active_index -= 1;
        }
    }
};
