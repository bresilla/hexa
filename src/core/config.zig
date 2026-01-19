const std = @import("std");
const posix = std.posix;

/// Output definition for status modules (style + format pair)
pub const OutputDef = struct {
    style: []const u8 = "",
    format: []const u8 = "$output",
};

/// Status bar module definition
pub const StatusModule = struct {
    name: []const u8,
    // Array of outputs (each with style + format)
    outputs: []const OutputDef = &[_]OutputDef{},
    // Optional for custom modules
    command: ?[]const u8 = null,
    when: ?[]const u8 = null,
    // For panes module
    active_style: []const u8 = "bg:1 fg:0",
    inactive_style: []const u8 = "bg:237 fg:250",
    separator: []const u8 = " | ",
    separator_style: []const u8 = "fg:7",
};

/// Status bar config
pub const StatusConfig = struct {
    enabled: bool = true,
    left: []const StatusModule = &[_]StatusModule{},
    center: []const StatusModule = &[_]StatusModule{},
    right: []const StatusModule = &[_]StatusModule{},
};

pub const FloatStylePosition = enum {
    topleft,
    topcenter,
    topright,
    bottomleft,
    bottomcenter,
    bottomright,
};

pub const FloatStyle = struct {
    // Border appearance
    top_left: u21 = 0x256D, // ╭
    top_right: u21 = 0x256E, // ╮
    bottom_left: u21 = 0x2570, // ╰
    bottom_right: u21 = 0x256F, // ╯
    horizontal: u21 = 0x2500, // ─
    vertical: u21 = 0x2502, // │
    // Optional module in border
    position: ?FloatStylePosition = null,
    module: ?StatusModule = null,
};

pub const FloatDef = struct {
    key: u8,
    command: ?[]const u8,
    alone: bool = false, // hide all other floats when this one opens
    pwd: bool = false, // if true, each directory gets its own instance
    sticky: bool = false, // if true, preserved by ses daemon across mux restarts
    // Per-float overrides (null = use default)
    width_percent: ?u8 = null,
    height_percent: ?u8 = null,
    pos_x: ?u8 = null, // position as percent (0=left, 50=center, 100=right)
    pos_y: ?u8 = null, // position as percent (0=top, 50=center, 100=bottom)
    padding_x: ?u8 = null,
    padding_y: ?u8 = null,
    // Border color (per-float override)
    color: ?BorderColor = null,
    // Border style and optional module
    style: ?FloatStyle = null,
};

/// Border color config (active/passive)
pub const BorderColor = struct {
    active: u8 = 1,
    passive: u8 = 237,
};

/// Split border style with junction characters
pub const SplitStyle = struct {
    vertical: u21 = 0x2502, // │
    horizontal: u21 = 0x2500, // ─
    cross: u21 = 0x253C, // ┼
    top_t: u21 = 0x252C, // ┬
    bottom_t: u21 = 0x2534, // ┴
    left_t: u21 = 0x251C, // ├
    right_t: u21 = 0x2524, // ┤
};

/// Splits configuration
pub const SplitsConfig = struct {
    // Keys
    key_split_h: u8 = 'h',
    key_split_v: u8 = 'v',
    // Border color
    color: BorderColor = .{},
    // Simple separator (when no style)
    separator_v: u21 = 0x2502, // │
    separator_h: u21 = 0x2500, // ─
    // Full border style (if set, uses junctions)
    style: ?SplitStyle = null,
};

/// Panes configuration (includes status bar)
pub const PanesConfig = struct {
    // Keys
    key_new: u8 = 't',
    key_next: u8 = 'n',
    key_prev: u8 = 'p',
    key_close: u8 = 'x',
    key_detach: u8 = 'd',
    // Status bar
    status: StatusConfig = .{},
};

/// Notification configuration
pub const NotificationConfig = struct {
    fg: u8 = 0, // foreground color (palette index)
    bg: u8 = 3, // background color (palette index)
    bold: bool = true,
    padding_x: u8 = 1,
    padding_y: u8 = 0,
    margin_x: u8 = 2,
    margin_y: u8 = 1,
    duration_ms: u32 = 3000,
    position: []const u8 = "bottom_center",
};

pub const Config = struct {
    // Global keybindings (Alt + key)
    key_quit: u8 = 'q',
    key_disown: u8 = 'z',
    key_adopt: u8 = 'a',

    // Floating pane defaults
    float_width_percent: u8 = 60,
    float_height_percent: u8 = 60,
    float_padding_x: u8 = 1, // left/right padding inside border
    float_padding_y: u8 = 0, // top/bottom padding inside border
    float_color: BorderColor = .{}, // border colors (active/passive)

    // Named floats
    floats: []FloatDef = &[_]FloatDef{},

    // Splits
    splits: SplitsConfig = .{},

    // Panes (includes status)
    panes: PanesConfig = .{},

    // Notifications
    notifications: NotificationConfig = .{},

    // Internal
    _allocator: ?std.mem.Allocator = null,

    pub fn load(allocator: std.mem.Allocator) Config {
        var config = Config{};
        config._allocator = allocator;

        const path = getConfigPath(allocator) catch return config;
        defer allocator.free(path);

        const file = std.fs.openFileAbsolute(path, .{}) catch return config;
        defer file.close();

        const content = file.readToEndAlloc(allocator, 1024 * 1024) catch return config;
        defer allocator.free(content);

        const parsed = std.json.parseFromSlice(JsonConfig, allocator, content, .{}) catch return config;
        defer parsed.deinit();

        const json = parsed.value;

        // Apply global keybindings
        if (json.keys) |keys| {
            if (keys.quit) |k| {
                if (k.len > 0) config.key_quit = k[0];
            }
            if (keys.disown) |k| {
                if (k.len > 0) config.key_disown = k[0];
            }
            if (keys.adopt) |k| {
                if (k.len > 0) config.key_adopt = k[0];
            }
        }

        // Parse panes config
        if (json.panes) |p| {
            // Keys
            if (p.keys) |keys| {
                if (keys.new) |k| if (k.len > 0) {
                    config.panes.key_new = k[0];
                };
                if (keys.next) |k| if (k.len > 0) {
                    config.panes.key_next = k[0];
                };
                if (keys.prev) |k| if (k.len > 0) {
                    config.panes.key_prev = k[0];
                };
                if (keys.close) |k| if (k.len > 0) {
                    config.panes.key_close = k[0];
                };
                if (keys.detach) |k| if (k.len > 0) {
                    config.panes.key_detach = k[0];
                };
            }
            // Status bar
            if (p.status) |s| {
                if (s.enabled) |e| {
                    config.panes.status.enabled = e;
                }
                if (s.left) |left_mods| {
                    config.panes.status.left = parseStatusModules(allocator, left_mods);
                }
                if (s.center) |center_mods| {
                    config.panes.status.center = parseStatusModules(allocator, center_mods);
                }
                if (s.right) |right_mods| {
                    config.panes.status.right = parseStatusModules(allocator, right_mods);
                }
            }
        }

        // Parse floats array (first keyless entry = defaults)
        if (json.floats) |json_floats| {
            var float_list: std.ArrayList(FloatDef) = .empty;

            // Check for defaults (first entry without key)
            var def_width: ?u8 = null;
            var def_height: ?u8 = null;
            var def_pos_x: ?u8 = null;
            var def_pos_y: ?u8 = null;
            var def_pad_x: ?u8 = null;
            var def_pad_y: ?u8 = null;
            var def_color: ?BorderColor = null;

            for (json_floats, 0..) |jf, idx| {
                // First entry without key = defaults
                if (idx == 0 and jf.key.len == 0) {
                    if (jf.width) |v| def_width = @intCast(@min(100, @max(10, v)));
                    if (jf.height) |v| def_height = @intCast(@min(100, @max(10, v)));
                    if (jf.pos_x) |v| def_pos_x = @intCast(@min(100, @max(0, v)));
                    if (jf.pos_y) |v| def_pos_y = @intCast(@min(100, @max(0, v)));
                    if (jf.padding_x) |v| def_pad_x = @intCast(@min(10, @max(0, v)));
                    if (jf.padding_y) |v| def_pad_y = @intCast(@min(10, @max(0, v)));
                    if (jf.color) |jc| {
                        var c = BorderColor{};
                        if (jc.active) |a| c.active = @intCast(@min(255, @max(0, a)));
                        if (jc.passive) |p| c.passive = @intCast(@min(255, @max(0, p)));
                        def_color = c;
                    }
                    // Apply defaults to config
                    if (def_width) |w| config.float_width_percent = w;
                    if (def_height) |h| config.float_height_percent = h;
                    if (def_pad_x) |p| config.float_padding_x = p;
                    if (def_pad_y) |p| config.float_padding_y = p;
                    if (def_color) |c| config.float_color = c;
                    continue;
                }

                const key: u8 = if (jf.key.len > 0) jf.key[0] else continue;
                const command: ?[]const u8 = if (jf.command) |cmd|
                    allocator.dupe(u8, cmd) catch null
                else
                    null;

                // Parse color if present
                const color: ?BorderColor = if (jf.color) |jc| blk: {
                    var c = BorderColor{};
                    if (jc.active) |a| c.active = @intCast(@min(255, @max(0, a)));
                    if (jc.passive) |p| c.passive = @intCast(@min(255, @max(0, p)));
                    break :blk c;
                } else null;

                // Parse style if present
                const style: ?FloatStyle = if (jf.style) |js| blk: {
                    var result = FloatStyle{};

                    // Border appearance
                    if (js.top_left) |s| if (s.len > 0) {
                        result.top_left = std.unicode.utf8Decode(s) catch 0x256D;
                    };
                    if (js.top_right) |s| if (s.len > 0) {
                        result.top_right = std.unicode.utf8Decode(s) catch 0x256E;
                    };
                    if (js.bottom_left) |s| if (s.len > 0) {
                        result.bottom_left = std.unicode.utf8Decode(s) catch 0x2570;
                    };
                    if (js.bottom_right) |s| if (s.len > 0) {
                        result.bottom_right = std.unicode.utf8Decode(s) catch 0x256F;
                    };
                    if (js.horizontal) |s| if (s.len > 0) {
                        result.horizontal = std.unicode.utf8Decode(s) catch 0x2500;
                    };
                    if (js.vertical) |s| if (s.len > 0) {
                        result.vertical = std.unicode.utf8Decode(s) catch 0x2502;
                    };

                    // Optional module
                    if (js.position) |pos_str| {
                        result.position = std.meta.stringToEnum(FloatStylePosition, pos_str);
                    }
                    if (js.name) |mod_name| {
                        var outputs: []const OutputDef = &[_]OutputDef{};
                        if (js.outputs) |json_outputs| {
                            var output_list: std.ArrayList(OutputDef) = .empty;
                            for (json_outputs) |jo| {
                                output_list.append(allocator, .{
                                    .style = if (jo.style) |st| allocator.dupe(u8, st) catch "" else "",
                                    .format = if (jo.format) |ft| allocator.dupe(u8, ft) catch "$output" else "$output",
                                }) catch continue;
                            }
                            outputs = output_list.toOwnedSlice(allocator) catch &[_]OutputDef{};
                        }
                        result.module = .{
                            .name = allocator.dupe(u8, mod_name) catch "",
                            .outputs = outputs,
                            .command = if (js.command) |cmd| allocator.dupe(u8, cmd) catch null else null,
                            .when = if (js.when) |w| allocator.dupe(u8, w) catch null else null,
                        };
                    }

                    break :blk result;
                } else null;

                float_list.append(allocator, .{
                    .key = key,
                    .command = command,
                    .alone = jf.alone orelse false,
                    .pwd = jf.pwd orelse false,
                    .sticky = jf.sticky orelse false,
                    .width_percent = if (jf.width) |v| @intCast(@min(100, @max(10, v))) else def_width,
                    .height_percent = if (jf.height) |v| @intCast(@min(100, @max(10, v))) else def_height,
                    .pos_x = if (jf.pos_x) |v| @intCast(@min(100, @max(0, v))) else def_pos_x,
                    .pos_y = if (jf.pos_y) |v| @intCast(@min(100, @max(0, v))) else def_pos_y,
                    .padding_x = if (jf.padding_x) |v| @intCast(@min(10, @max(0, v))) else def_pad_x,
                    .padding_y = if (jf.padding_y) |v| @intCast(@min(10, @max(0, v))) else def_pad_y,
                    .color = color orelse def_color,
                    .style = style,
                }) catch continue;
            }
            config.floats = float_list.toOwnedSlice(allocator) catch &[_]FloatDef{};
        }

        // Parse splits config
        if (json.splits) |sp| {
            // Keys
            if (sp.keys) |keys| {
                if (keys.split_h) |k| if (k.len > 0) {
                    config.splits.key_split_h = k[0];
                };
                if (keys.split_v) |k| if (k.len > 0) {
                    config.splits.key_split_v = k[0];
                };
            }
            // Color
            if (sp.color) |jc| {
                if (jc.active) |a| config.splits.color.active = @intCast(@min(255, @max(0, a)));
                if (jc.passive) |p| config.splits.color.passive = @intCast(@min(255, @max(0, p)));
            }
            // Simple separators
            if (sp.separator_v) |s| if (s.len > 0) {
                config.splits.separator_v = std.unicode.utf8Decode(s) catch 0x2502;
            };
            if (sp.separator_h) |s| if (s.len > 0) {
                config.splits.separator_h = std.unicode.utf8Decode(s) catch 0x2500;
            };
            // Full style
            if (sp.style) |js| {
                var style = SplitStyle{};
                if (js.vertical) |s| if (s.len > 0) {
                    style.vertical = std.unicode.utf8Decode(s) catch 0x2502;
                };
                if (js.horizontal) |s| if (s.len > 0) {
                    style.horizontal = std.unicode.utf8Decode(s) catch 0x2500;
                };
                if (js.cross) |s| if (s.len > 0) {
                    style.cross = std.unicode.utf8Decode(s) catch 0x253C;
                };
                if (js.top_t) |s| if (s.len > 0) {
                    style.top_t = std.unicode.utf8Decode(s) catch 0x252C;
                };
                if (js.bottom_t) |s| if (s.len > 0) {
                    style.bottom_t = std.unicode.utf8Decode(s) catch 0x2534;
                };
                if (js.left_t) |s| if (s.len > 0) {
                    style.left_t = std.unicode.utf8Decode(s) catch 0x251C;
                };
                if (js.right_t) |s| if (s.len > 0) {
                    style.right_t = std.unicode.utf8Decode(s) catch 0x2524;
                };
                config.splits.style = style;
            }
        }

        // Parse notifications config
        if (json.notifications) |n| {
            if (n.fg) |v| config.notifications.fg = @intCast(@min(255, @max(0, v)));
            if (n.bg) |v| config.notifications.bg = @intCast(@min(255, @max(0, v)));
            if (n.bold) |v| config.notifications.bold = v;
            if (n.padding_x) |v| config.notifications.padding_x = @intCast(@min(10, @max(0, v)));
            if (n.padding_y) |v| config.notifications.padding_y = @intCast(@min(10, @max(0, v)));
            if (n.margin_x) |v| config.notifications.margin_x = @intCast(@min(10, @max(0, v)));
            if (n.margin_y) |v| config.notifications.margin_y = @intCast(@min(10, @max(0, v)));
            if (n.duration_ms) |v| config.notifications.duration_ms = @intCast(@min(60000, @max(100, v)));
            if (n.position) |v| config.notifications.position = allocator.dupe(u8, v) catch "bottom_center";
        }

        return config;
    }

    pub fn deinit(self: *Config) void {
        if (self._allocator) |alloc| {
            for (self.floats) |f| {
                if (f.command) |cmd| {
                    alloc.free(cmd);
                }
            }
            if (self.floats.len > 0) {
                alloc.free(self.floats);
            }
        }
    }

    pub fn getFloatByKey(self: *const Config, key: u8) ?*const FloatDef {
        for (self.floats) |*f| {
            if (f.key == key) return f;
        }
        return null;
    }

    fn parseStatusModules(allocator: std.mem.Allocator, json_mods: []const JsonStatusModule) []const StatusModule {
        var list: std.ArrayList(StatusModule) = .empty;
        for (json_mods) |jm| {
            // Parse outputs array
            var outputs: []const OutputDef = &[_]OutputDef{};
            if (jm.outputs) |json_outputs| {
                var output_list: std.ArrayList(OutputDef) = .empty;
                for (json_outputs) |jo| {
                    output_list.append(allocator, .{
                        .style = if (jo.style) |s| allocator.dupe(u8, s) catch "" else "",
                        .format = if (jo.format) |f| allocator.dupe(u8, f) catch "$output" else "$output",
                    }) catch continue;
                }
                outputs = output_list.toOwnedSlice(allocator) catch &[_]OutputDef{};
            }

            list.append(allocator, .{
                .name = allocator.dupe(u8, jm.name) catch continue,
                .outputs = outputs,
                .command = if (jm.command) |c| allocator.dupe(u8, c) catch null else null,
                .when = if (jm.when) |w| allocator.dupe(u8, w) catch null else null,
                .active_style = if (jm.active_style) |s| allocator.dupe(u8, s) catch "bg:1 fg:0" else "bg:1 fg:0",
                .inactive_style = if (jm.inactive_style) |s| allocator.dupe(u8, s) catch "bg:237 fg:250" else "bg:237 fg:250",
                .separator = if (jm.separator) |s| allocator.dupe(u8, s) catch " | " else " | ",
                .separator_style = if (jm.separator_style) |s| allocator.dupe(u8, s) catch "fg:7" else "fg:7",
            }) catch continue;
        }
        return list.toOwnedSlice(allocator) catch &[_]StatusModule{};
    }

    fn getConfigPath(allocator: std.mem.Allocator) ![]const u8 {
        const config_home = posix.getenv("XDG_CONFIG_HOME");
        if (config_home) |ch| {
            return std.fmt.allocPrint(allocator, "{s}/hexa/mux.json", .{ch});
        }

        const home = posix.getenv("HOME") orelse return error.NoHome;
        return std.fmt.allocPrint(allocator, "{s}/.config/hexa/mux.json", .{home});
    }
};

// JSON structure for parsing
const JsonBorderColor = struct {
    active: ?i64 = null,
    passive: ?i64 = null,
};

const JsonFloatStyle = struct {
    // Border appearance
    top_left: ?[]const u8 = null,
    top_right: ?[]const u8 = null,
    bottom_left: ?[]const u8 = null,
    bottom_right: ?[]const u8 = null,
    horizontal: ?[]const u8 = null,
    vertical: ?[]const u8 = null,
    // Optional module in border
    position: ?[]const u8 = null, // topleft, topcenter, topright, bottomleft, bottomcenter, bottomright
    name: ?[]const u8 = null, // module name (e.g. "time", "cpu")
    outputs: ?[]const JsonOutput = null,
    command: ?[]const u8 = null,
    when: ?[]const u8 = null,
};

const JsonFloatPane = struct {
    key: []const u8 = "",
    command: ?[]const u8 = null,
    alone: ?bool = null,
    pwd: ?bool = null,
    sticky: ?bool = null,
    width: ?i64 = null,
    height: ?i64 = null,
    pos_x: ?i64 = null,
    pos_y: ?i64 = null,
    padding_x: ?i64 = null,
    padding_y: ?i64 = null,
    color: ?JsonBorderColor = null,
    style: ?JsonFloatStyle = null,
};

const JsonSplitStyle = struct {
    vertical: ?[]const u8 = null,
    horizontal: ?[]const u8 = null,
    cross: ?[]const u8 = null,
    top_t: ?[]const u8 = null,
    bottom_t: ?[]const u8 = null,
    left_t: ?[]const u8 = null,
    right_t: ?[]const u8 = null,
};

const JsonSplitsConfig = struct {
    keys: ?struct {
        split_h: ?[]const u8 = null,
        split_v: ?[]const u8 = null,
    } = null,
    color: ?JsonBorderColor = null,
    separator_v: ?[]const u8 = null,
    separator_h: ?[]const u8 = null,
    style: ?JsonSplitStyle = null,
};

const JsonPanesConfig = struct {
    keys: ?struct {
        new: ?[]const u8 = null,
        next: ?[]const u8 = null,
        prev: ?[]const u8 = null,
        close: ?[]const u8 = null,
        detach: ?[]const u8 = null,
    } = null,
    status: ?struct {
        enabled: ?bool = null,
        left: ?[]const JsonStatusModule = null,
        center: ?[]const JsonStatusModule = null,
        right: ?[]const JsonStatusModule = null,
    } = null,
};

const JsonNotificationConfig = struct {
    fg: ?i64 = null,
    bg: ?i64 = null,
    bold: ?bool = null,
    padding_x: ?i64 = null,
    padding_y: ?i64 = null,
    margin_x: ?i64 = null,
    margin_y: ?i64 = null,
    duration_ms: ?i64 = null,
    position: ?[]const u8 = null,
};

const JsonConfig = struct {
    keys: ?struct {
        quit: ?[]const u8 = null,
        disown: ?[]const u8 = null,
        adopt: ?[]const u8 = null,
    } = null,
    floats: ?[]const JsonFloatPane = null,
    splits: ?JsonSplitsConfig = null,
    panes: ?JsonPanesConfig = null,
    notifications: ?JsonNotificationConfig = null,
};

const JsonOutput = struct {
    style: ?[]const u8 = null,
    format: ?[]const u8 = null,
};

const JsonStatusModule = struct {
    name: []const u8,
    outputs: ?[]const JsonOutput = null,
    command: ?[]const u8 = null,
    when: ?[]const u8 = null,
    active_style: ?[]const u8 = null,
    inactive_style: ?[]const u8 = null,
    separator: ?[]const u8 = null,
    separator_style: ?[]const u8 = null,
};
