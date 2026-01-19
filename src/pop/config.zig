const std = @import("std");
const posix = std.posix;

/// Notification style configuration
pub const NotificationStyle = struct {
    fg: u8 = 0, // foreground color (palette index)
    bg: u8 = 3, // background color (palette index)
    bold: bool = true,
    padding_x: u8 = 1, // horizontal padding inside box
    padding_y: u8 = 0, // vertical padding inside box
    offset: u8 = 1, // offset from edge
    alignment: []const u8 = "center", // horizontal alignment: left, center, right
    duration_ms: u32 = 3000,
};

/// Confirm dialog style configuration
pub const ConfirmStyle = struct {
    fg: u8 = 0,
    bg: u8 = 4, // blue
    bold: bool = true,
    padding_x: u8 = 2,
    padding_y: u8 = 1,
    yes_label: []const u8 = "Yes",
    no_label: []const u8 = "No",
};

/// Choose/Picker dialog style configuration
pub const ChooseStyle = struct {
    fg: u8 = 7,
    bg: u8 = 0, // black
    highlight_fg: u8 = 0,
    highlight_bg: u8 = 7,
    bold: bool = false,
    padding_x: u8 = 1,
    padding_y: u8 = 0,
    visible_count: u8 = 10,
};

/// Carrier scope settings (MUX + TAB - same settings)
pub const CarrierConfig = struct {
    notification: NotificationStyle = .{
        .offset = 1,
    },
    confirm: ConfirmStyle = .{},
    choose: ChooseStyle = .{},
};

/// Pane scope settings
pub const PaneConfig = struct {
    notification: NotificationStyle = .{
        .offset = 0,
    },
    confirm: ConfirmStyle = .{},
    choose: ChooseStyle = .{},
};

/// Pop configuration - loaded from ~/.config/hexa/pop.json
pub const PopConfig = struct {
    carrier: CarrierConfig = .{},
    pane: PaneConfig = .{},

    _allocator: ?std.mem.Allocator = null,

    pub fn load(allocator: std.mem.Allocator) PopConfig {
        var config = PopConfig{};
        config._allocator = allocator;

        const path = getConfigPath(allocator) catch return config;
        defer allocator.free(path);

        const file = std.fs.openFileAbsolute(path, .{}) catch return config;
        defer file.close();

        const content = file.readToEndAlloc(allocator, 1024 * 1024) catch return config;
        defer allocator.free(content);

        const parsed = std.json.parseFromSlice(JsonPopConfig, allocator, content, .{}) catch return config;
        defer parsed.deinit();

        const json = parsed.value;

        // Apply carrier settings
        if (json.carrier) |c| {
            applyNotificationStyle(&config.carrier.notification, c.notification, allocator);
            applyConfirmStyle(&config.carrier.confirm, c.confirm, allocator);
            applyChooseStyle(&config.carrier.choose, c.choose);
        }

        // Apply pane settings
        if (json.pane) |p| {
            applyNotificationStyle(&config.pane.notification, p.notification, allocator);
            applyConfirmStyle(&config.pane.confirm, p.confirm, allocator);
            applyChooseStyle(&config.pane.choose, p.choose);
        }

        return config;
    }

    pub fn deinit(self: *PopConfig) void {
        // Free any allocated strings if we had an allocator
        _ = self;
    }
};

fn applyNotificationStyle(target: *NotificationStyle, source: ?JsonNotificationStyle, allocator: std.mem.Allocator) void {
    const s = source orelse return;
    if (s.fg) |v| target.fg = @intCast(@min(255, @max(0, v)));
    if (s.bg) |v| target.bg = @intCast(@min(255, @max(0, v)));
    if (s.bold) |v| target.bold = v;
    if (s.padding_x) |v| target.padding_x = @intCast(@min(10, @max(0, v)));
    if (s.padding_y) |v| target.padding_y = @intCast(@min(10, @max(0, v)));
    if (s.offset) |v| target.offset = @intCast(@min(20, @max(0, v)));
    if (s.alignment) |v| target.alignment = allocator.dupe(u8, v) catch "center";
    if (s.duration_ms) |v| target.duration_ms = @intCast(@min(60000, @max(100, v)));
}

fn applyConfirmStyle(target: *ConfirmStyle, source: ?JsonConfirmStyle, allocator: std.mem.Allocator) void {
    const s = source orelse return;
    if (s.fg) |v| target.fg = @intCast(@min(255, @max(0, v)));
    if (s.bg) |v| target.bg = @intCast(@min(255, @max(0, v)));
    if (s.bold) |v| target.bold = v;
    if (s.padding_x) |v| target.padding_x = @intCast(@min(10, @max(0, v)));
    if (s.padding_y) |v| target.padding_y = @intCast(@min(10, @max(0, v)));
    if (s.yes_label) |v| target.yes_label = allocator.dupe(u8, v) catch "Yes";
    if (s.no_label) |v| target.no_label = allocator.dupe(u8, v) catch "No";
}

fn applyChooseStyle(target: *ChooseStyle, source: ?JsonChooseStyle) void {
    const s = source orelse return;
    if (s.fg) |v| target.fg = @intCast(@min(255, @max(0, v)));
    if (s.bg) |v| target.bg = @intCast(@min(255, @max(0, v)));
    if (s.highlight_fg) |v| target.highlight_fg = @intCast(@min(255, @max(0, v)));
    if (s.highlight_bg) |v| target.highlight_bg = @intCast(@min(255, @max(0, v)));
    if (s.bold) |v| target.bold = v;
    if (s.padding_x) |v| target.padding_x = @intCast(@min(10, @max(0, v)));
    if (s.padding_y) |v| target.padding_y = @intCast(@min(10, @max(0, v)));
    if (s.visible_count) |v| target.visible_count = @intCast(@min(50, @max(1, v)));
}

fn getConfigPath(allocator: std.mem.Allocator) ![]const u8 {
    const home = posix.getenv("HOME") orelse return error.NoHome;
    return std.fmt.allocPrint(allocator, "{s}/.config/hexa/pop.json", .{home});
}

// JSON parsing types
const JsonNotificationStyle = struct {
    fg: ?i32 = null,
    bg: ?i32 = null,
    bold: ?bool = null,
    padding_x: ?i32 = null,
    padding_y: ?i32 = null,
    offset: ?i32 = null,
    alignment: ?[]const u8 = null,
    duration_ms: ?i32 = null,
};

const JsonConfirmStyle = struct {
    fg: ?i32 = null,
    bg: ?i32 = null,
    bold: ?bool = null,
    padding_x: ?i32 = null,
    padding_y: ?i32 = null,
    yes_label: ?[]const u8 = null,
    no_label: ?[]const u8 = null,
};

const JsonChooseStyle = struct {
    fg: ?i32 = null,
    bg: ?i32 = null,
    highlight_fg: ?i32 = null,
    highlight_bg: ?i32 = null,
    bold: ?bool = null,
    padding_x: ?i32 = null,
    padding_y: ?i32 = null,
    visible_count: ?i32 = null,
};

const JsonCarrierConfig = struct {
    notification: ?JsonNotificationStyle = null,
    confirm: ?JsonConfirmStyle = null,
    choose: ?JsonChooseStyle = null,
};

const JsonPaneConfig = struct {
    notification: ?JsonNotificationStyle = null,
    confirm: ?JsonConfirmStyle = null,
    choose: ?JsonChooseStyle = null,
};

const JsonPopConfig = struct {
    carrier: ?JsonCarrierConfig = null,
    pane: ?JsonPaneConfig = null,
};
