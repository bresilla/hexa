const std = @import("std");
const Pane = @import("pane.zig").Pane;
const FloatingPane = @import("floating.zig").FloatingPane;
const Layout = @import("layout.zig");

pub const Window = struct {
    allocator: std.mem.Allocator,
    id: usize,
    name: []const u8,
    panes: std.ArrayList(Pane) = .empty,
    floating: std.ArrayList(FloatingPane) = .empty,
    active_index: usize = 0,
    active_floating: ?usize = null,
    zoomed_pane: ?usize = null, // If set, this pane is fullscreen

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
        for (self.floating.items) |*float| {
            float.deinit();
        }
        self.floating.deinit(self.allocator);
        self.allocator.free(self.name);
    }

    pub fn activePane(self: *Window) *Pane {
        if (self.active_floating != null) {
            unreachable;
        }
        return &self.panes.items[self.active_index];
    }

    pub fn activeFloatingPane(self: *Window) ?*FloatingPane {
        if (self.active_floating) |idx| {
            if (idx < self.floating.items.len) {
                return &self.floating.items[idx];
            }
        }
        return null;
    }

    pub fn split(self: *Window) !void {
        const id = self.panes.items.len + 1;
        try self.panes.append(self.allocator, try Pane.init(self.allocator, id));
        self.active_index = self.panes.items.len - 1;
    }

    pub fn addFloating(self: *Window, width: u16, height: u16) !void {
        const rect = Layout.Rect{
            .x = 5,
            .y = 3,
            .width = width,
            .height = height,
        };
        const id = self.floating.items.len + 1;
        try self.floating.append(self.allocator, try FloatingPane.init(self.allocator, id, rect));
        self.active_floating = self.floating.items.len - 1;
    }

    pub fn closeFloating(self: *Window) void {
        if (self.active_floating) |idx| {
            var float = self.floating.orderedRemove(idx);
            float.deinit();
            self.active_floating = null;
        }
    }

    pub fn nextPane(self: *Window) void {
        if (self.active_floating != null) {
            self.active_floating = null;
            return;
        }
        if (self.panes.items.len == 0) return;
        self.active_index = (self.active_index + 1) % self.panes.items.len;
    }

    pub fn prevPane(self: *Window) void {
        if (self.active_floating != null) {
            self.active_floating = null;
            return;
        }
        if (self.panes.items.len <= 1) return;
        if (self.active_index == 0) {
            self.active_index = self.panes.items.len - 1;
        } else {
            self.active_index -= 1;
        }
    }

    pub fn closePane(self: *Window) void {
        if (self.panes.items.len <= 1) return;
        var pane = self.panes.orderedRemove(self.active_index);
        pane.deinit();
        if (self.active_index >= self.panes.items.len) {
            self.active_index = self.panes.items.len - 1;
        }
    }

    // Resize all panes in this window based on total terminal size
    pub fn resizePanes(self: *Window, total_width: u16, total_height: u16) void {
        if (self.panes.items.len == 0) return;

        // If a pane is zoomed, give it full size
        if (self.zoomed_pane) |zoomed_idx| {
            if (zoomed_idx < self.panes.items.len) {
                const pane_height = total_height -| 2;
                self.panes.items[zoomed_idx].pty.setSize(total_width, pane_height) catch {};
            }
            return;
        }

        // Calculate layout (horizontal split for now)
        const pane_count = self.panes.items.len;
        const pane_width = total_width / @as(u16, @intCast(pane_count));
        const pane_height = total_height -| 2; // Reserve space for tab bar and status

        for (self.panes.items) |*pane| {
            pane.pty.setSize(pane_width, pane_height) catch {};
        }

        // Resize floating panes too
        for (self.floating.items) |*float| {
            float.pty.setSize(float.rect.width -| 2, float.rect.height -| 2) catch {};
        }
    }

    // Toggle zoom for the active pane
    pub fn toggleZoom(self: *Window) void {
        if (self.zoomed_pane != null) {
            self.zoomed_pane = null;
        } else {
            self.zoomed_pane = self.active_index;
        }
    }

    // Check if window is currently zoomed
    pub fn isZoomed(self: *Window) bool {
        return self.zoomed_pane != null;
    }
};
