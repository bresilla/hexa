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
    color: u8 = 1,
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
    // Per-float overrides (null = use default)
    width_percent: ?u8 = null,
    height_percent: ?u8 = null,
    pos_x: ?u8 = null, // position as percent (0=left, 50=center, 100=right)
    pos_y: ?u8 = null, // position as percent (0=top, 50=center, 100=bottom)
    padding_x: ?u8 = null,
    padding_y: ?u8 = null,
    // Border style and optional module
    style: ?FloatStyle = null,
};

pub const Config = struct {
    // Keybindings (Alt + key)
    key_quit: u8 = 'q',
    key_split_h: u8 = 'h',
    key_split_v: u8 = 'v',
    key_new_pane: u8 = 't',
    key_next_pane: u8 = 'n',
    key_prev_pane: u8 = 'p',
    key_close_pane: u8 = 'x',

    // Floating pane defaults
    float_width_percent: u8 = 60,
    float_height_percent: u8 = 60,
    float_padding_x: u8 = 1, // left/right padding inside border
    float_padding_y: u8 = 0, // top/bottom padding inside border
    float_border_color: u8 = 1, // palette color for border (0-15)

    // Named floats
    floats: []FloatDef = &[_]FloatDef{},

    // Status bar
    status: StatusConfig = .{},

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

        // Apply keybindings
        if (json.keys) |keys| {
            if (keys.quit) |k| {
                if (k.len > 0) config.key_quit = k[0];
            }
            if (keys.split_h) |k| {
                if (k.len > 0) config.key_split_h = k[0];
            }
            if (keys.split_v) |k| {
                if (k.len > 0) config.key_split_v = k[0];
            }
            if (keys.new_pane) |k| {
                if (k.len > 0) config.key_new_pane = k[0];
            }
            if (keys.next_pane) |k| {
                if (k.len > 0) config.key_next_pane = k[0];
            }
            if (keys.prev_pane) |k| {
                if (k.len > 0) config.key_prev_pane = k[0];
            }
            if (keys.close_pane) |k| {
                if (k.len > 0) config.key_close_pane = k[0];
            }
        }

        // Apply status settings
        if (json.status) |s| {
            if (s.enabled) |e| {
                config.status.enabled = e;
            }
            // Parse left modules
            if (s.left) |left_mods| {
                config.status.left = parseStatusModules(allocator, left_mods);
            }
            // Parse center modules
            if (s.center) |center_mods| {
                config.status.center = parseStatusModules(allocator, center_mods);
            }
            // Parse right modules
            if (s.right) |right_mods| {
                config.status.right = parseStatusModules(allocator, right_mods);
            }
        }

        // Parse floats array
        if (json.floats) |json_floats| {
            var float_list: std.ArrayList(FloatDef) = .empty;
            for (json_floats) |jf| {
                const key: u8 = if (jf.key.len > 0) jf.key[0] else continue;
                const command: ?[]const u8 = if (jf.command) |cmd|
                    allocator.dupe(u8, cmd) catch null
                else
                    null;

                // Parse style if present
                const style: ?FloatStyle = if (jf.style) |js| blk: {
                    var result = FloatStyle{};

                    // Border appearance
                    if (js.color) |col| result.color = @intCast(@min(255, @max(0, col)));
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
                    .width_percent = if (jf.width) |v| @intCast(@min(100, @max(10, v))) else null,
                    .height_percent = if (jf.height) |v| @intCast(@min(100, @max(10, v))) else null,
                    .pos_x = if (jf.pos_x) |v| @intCast(@min(100, @max(0, v))) else null,
                    .pos_y = if (jf.pos_y) |v| @intCast(@min(100, @max(0, v))) else null,
                    .padding_x = if (jf.padding_x) |v| @intCast(@min(10, @max(0, v))) else null,
                    .padding_y = if (jf.padding_y) |v| @intCast(@min(10, @max(0, v))) else null,
                    .style = style,
                }) catch continue;
            }
            config.floats = float_list.toOwnedSlice(allocator) catch &[_]FloatDef{};
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
const JsonFloatStyle = struct {
    // Border appearance
    color: ?i64 = null,
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
    key: []const u8,
    command: ?[]const u8 = null,
    alone: ?bool = null,
    pwd: ?bool = null,
    width: ?i64 = null,
    height: ?i64 = null,
    pos_x: ?i64 = null,
    pos_y: ?i64 = null,
    padding_x: ?i64 = null,
    padding_y: ?i64 = null,
    style: ?JsonFloatStyle = null,
};

const JsonConfig = struct {
    keys: ?struct {
        quit: ?[]const u8 = null,
        split_h: ?[]const u8 = null,
        split_v: ?[]const u8 = null,
        new_pane: ?[]const u8 = null,
        next_pane: ?[]const u8 = null,
        prev_pane: ?[]const u8 = null,
        close_pane: ?[]const u8 = null,
    } = null,
    floats: ?[]const JsonFloatPane = null,
    status: ?struct {
        enabled: ?bool = null,
        left: ?[]const JsonStatusModule = null,
        center: ?[]const JsonStatusModule = null,
        right: ?[]const JsonStatusModule = null,
    } = null,
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
