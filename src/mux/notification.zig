const std = @import("std");
const render = @import("render.zig");
const Renderer = render.Renderer;
const Color = render.Color;

/// Position of the notification overlay
pub const Position = enum {
    top_left,
    top_center,
    top_right,
    center,
    bottom_left,
    bottom_center,
    bottom_right,
};

/// Style configuration for notifications
pub const Style = struct {
    fg: Color = .{ .palette = 0 }, // black text
    bg: Color = .{ .palette = 3 }, // yellow background
    bold: bool = true,
    padding_x: u16 = 1, // horizontal padding inside box
    padding_y: u16 = 0, // vertical padding inside box
    margin_x: u16 = 2, // margin from screen edge
    margin_y: u16 = 1, // margin from screen edge
    border: bool = true,
    border_char: u8 = ' ', // border character (space = solid bg)
};

/// A single notification
pub const Notification = struct {
    message: []const u8,
    expires_at: i64,
    owned: bool, // true if message needs to be freed
    position: Position,
    style: Style,

    pub fn isExpired(self: Notification) bool {
        return std.time.milliTimestamp() >= self.expires_at;
    }
};

/// Notification manager - handles queue of notifications
pub const NotificationManager = struct {
    allocator: std.mem.Allocator,
    current: ?Notification,
    queue: std.ArrayList(Notification),
    default_position: Position,
    default_style: Style,
    default_duration_ms: i64,

    pub fn init(allocator: std.mem.Allocator) NotificationManager {
        return .{
            .allocator = allocator,
            .current = null,
            .queue = .empty,
            .default_position = .bottom_center,
            .default_style = .{},
            .default_duration_ms = 3000,
        };
    }

    pub fn deinit(self: *NotificationManager) void {
        // Free current notification if owned
        if (self.current) |notif| {
            if (notif.owned) {
                self.allocator.free(notif.message);
            }
        }
        // Free queued notifications
        for (self.queue.items) |notif| {
            if (notif.owned) {
                self.allocator.free(notif.message);
            }
        }
        self.queue.deinit(self.allocator);
    }

    /// Show a notification with default settings
    pub fn show(self: *NotificationManager, message: []const u8) void {
        self.showWithOptions(message, self.default_duration_ms, self.default_position, self.default_style, false);
    }

    /// Show a notification for a specific duration
    pub fn showFor(self: *NotificationManager, message: []const u8, duration_ms: i64) void {
        self.showWithOptions(message, duration_ms, self.default_position, self.default_style, false);
    }

    /// Show a notification with full options
    pub fn showWithOptions(
        self: *NotificationManager,
        message: []const u8,
        duration_ms: i64,
        position: Position,
        style: Style,
        owned: bool,
    ) void {
        const notif = Notification{
            .message = message,
            .expires_at = std.time.milliTimestamp() + duration_ms,
            .owned = owned,
            .position = position,
            .style = style,
        };

        // If no current notification, show immediately
        if (self.current == null) {
            self.current = notif;
        } else {
            // Queue it (might fail, that's ok)
            self.queue.append(self.allocator, notif) catch {};
        }
    }

    /// Update notification state - call each frame
    /// Returns true if display needs refresh
    pub fn update(self: *NotificationManager) bool {
        if (self.current) |notif| {
            if (notif.isExpired()) {
                // Clean up expired notification
                if (notif.owned) {
                    self.allocator.free(notif.message);
                }
                // Pop next from queue
                if (self.queue.items.len > 0) {
                    self.current = self.queue.orderedRemove(0);
                } else {
                    self.current = null;
                }
                return true; // needs refresh
            }
        }
        return false;
    }

    /// Check if there's an active notification
    pub fn hasActive(self: *NotificationManager) bool {
        return self.current != null;
    }

    /// Render the notification overlay
    pub fn render(self: *NotificationManager, renderer: *Renderer, screen_width: u16, screen_height: u16) void {
        const notif = self.current orelse return;
        const style = notif.style;

        // Calculate box dimensions
        const msg_len: u16 = @intCast(@min(notif.message.len, screen_width -| style.margin_x * 2 -| style.padding_x * 2));
        const box_width = msg_len + style.padding_x * 2;
        const box_height: u16 = 1 + style.padding_y * 2;

        // Calculate position
        const pos = self.calculatePosition(notif.position, box_width, box_height, screen_width, screen_height, style);

        // Draw background/border box
        var yi: u16 = 0;
        while (yi < box_height) : (yi += 1) {
            var xi: u16 = 0;
            while (xi < box_width) : (xi += 1) {
                renderer.setCell(pos.x + xi, pos.y + yi, .{
                    .char = ' ',
                    .fg = style.fg,
                    .bg = style.bg,
                });
            }
        }

        // Draw message text (centered in box)
        const text_y = pos.y + style.padding_y;
        const text_x = pos.x + style.padding_x;
        for (0..msg_len) |i| {
            renderer.setCell(text_x + @as(u16, @intCast(i)), text_y, .{
                .char = notif.message[i],
                .fg = style.fg,
                .bg = style.bg,
                .bold = style.bold,
            });
        }
    }

    fn calculatePosition(
        self: *NotificationManager,
        position: Position,
        box_width: u16,
        box_height: u16,
        screen_width: u16,
        screen_height: u16,
        style: Style,
    ) struct { x: u16, y: u16 } {
        _ = self;
        const x: u16 = switch (position) {
            .top_left, .bottom_left => style.margin_x,
            .top_center, .center, .bottom_center => (screen_width -| box_width) / 2,
            .top_right, .bottom_right => screen_width -| box_width -| style.margin_x,
        };

        const y: u16 = switch (position) {
            .top_left, .top_center, .top_right => style.margin_y,
            .center => (screen_height -| box_height) / 2,
            .bottom_left, .bottom_center, .bottom_right => screen_height -| box_height -| style.margin_y -| 1, // -1 for status bar
        };

        return .{ .x = x, .y = y };
    }

    /// Clear all notifications
    pub fn clear(self: *NotificationManager) void {
        if (self.current) |notif| {
            if (notif.owned) {
                self.allocator.free(notif.message);
            }
        }
        self.current = null;

        for (self.queue.items) |notif| {
            if (notif.owned) {
                self.allocator.free(notif.message);
            }
        }
        self.queue.clearRetainingCapacity();
    }
};
