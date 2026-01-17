const std = @import("std");
const Pane = @import("pane.zig").Pane;

const FloatingPane = @import("floating.zig").FloatingPane;

pub const Window = struct {
    allocator: std.mem.Allocator,
    id: usize,
    name: []const u8,
    panes: std.ArrayList(Pane) = .empty,
    floating: std.ArrayList(FloatingPane) = .empty,
    active_index: usize = 0,

    pub fn init(allocator: std.mem.Allocator, id: usize) !Window {
        var window = Window{
            .allocator = allocator,
            .id = id,
            .name = try std.fmt.allocPrint(allocator, "win-{d}", .{id}),
        };
        try window.panes.append(allocator, try Pane.init(allocator, 1));
        return window;
    }

    pub fn deinit(self: *Window) void {
        for (self.panes.items) |*pane| {
            pane.deinit();
        }
        self.panes.deinit(self.allocator);
        self.floating.deinit(self.allocator);
        self.allocator.free(self.name);
    }

    pub fn activePane(self: *Window) *Pane {
        return &self.panes.items[self.active_index];
    }

    pub fn split(self: *Window) !void {
        const id = self.panes.items.len + 1;
        try self.panes.append(self.allocator, try Pane.init(self.allocator, id));
        self.active_index = self.panes.items.len - 1;
    }

    pub fn addFloating(self: *Window, rect: @import("layout.zig").Rect) !void {
        const id = self.floating.items.len + 1;
        try self.floating.append(self.allocator, .{ .id = id, .rect = rect });
    }

    pub fn nextPane(self: *Window) void {
        if (self.panes.items.len == 0) return;
        self.active_index = (self.active_index + 1) % self.panes.items.len;
    }

    pub fn closePane(self: *Window) void {
        if (self.panes.items.len <= 1) return;
        var pane = self.panes.orderedRemove(self.active_index);
        pane.deinit();
        if (self.active_index >= self.panes.items.len) {
            self.active_index = self.panes.items.len - 1;
        }
    }
};
