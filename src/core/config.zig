const std = @import("std");
const posix = std.posix;

pub const FloatDef = struct {
    key: u8,
    name: []const u8,
    command: ?[]const u8,
    alone: bool = false, // hide all other floats when this one opens
    // Per-float overrides (null = use default)
    width_percent: ?u8 = null,
    height_percent: ?u8 = null,
    pos_x: ?u8 = null, // position as percent (0=left, 50=center, 100=right)
    pos_y: ?u8 = null, // position as percent (0=top, 50=center, 100=bottom)
    padding_x: ?u8 = null,
    padding_y: ?u8 = null,
    border_color: ?u8 = null,
    show_title: ?bool = null,
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
    float_show_title: bool = true, // show pane name in title bar

    // Named floats
    floats: []FloatDef = &[_]FloatDef{},

    // Status bar
    status_enabled: bool = true,

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

        // Apply float defaults
        if (json.float) |f| {
            if (f.width_percent) |w| {
                config.float_width_percent = @intCast(@min(100, @max(10, w)));
            }
            if (f.height_percent) |h| {
                config.float_height_percent = @intCast(@min(100, @max(10, h)));
            }
            if (f.padding_x) |px| {
                config.float_padding_x = @intCast(@min(10, @max(0, px)));
            }
            if (f.padding_y) |py| {
                config.float_padding_y = @intCast(@min(10, @max(0, py)));
            }
            if (f.border_color) |c| {
                config.float_border_color = @intCast(@min(15, @max(0, c)));
            }
            if (f.show_title) |t| {
                config.float_show_title = t;
            }
        }

        // Apply status settings
        if (json.status) |s| {
            if (s.enabled) |e| {
                config.status_enabled = e;
            }
        }

        // Parse floats array
        if (json.floats) |json_floats| {
            var float_list: std.ArrayList(FloatDef) = .empty;
            for (json_floats) |jf| {
                const key: u8 = if (jf.key.len > 0) jf.key[0] else continue;
                const name = allocator.dupe(u8, jf.name) catch continue;
                const command: ?[]const u8 = if (jf.command) |cmd|
                    allocator.dupe(u8, cmd) catch null
                else
                    null;

                float_list.append(allocator, .{
                    .key = key,
                    .name = name,
                    .command = command,
                    .alone = jf.alone orelse false,
                    .width_percent = if (jf.width_percent) |v| @intCast(@min(100, @max(10, v))) else null,
                    .height_percent = if (jf.height_percent) |v| @intCast(@min(100, @max(10, v))) else null,
                    .pos_x = if (jf.pos_x) |v| @intCast(@min(100, @max(0, v))) else null,
                    .pos_y = if (jf.pos_y) |v| @intCast(@min(100, @max(0, v))) else null,
                    .padding_x = if (jf.padding_x) |v| @intCast(@min(10, @max(0, v))) else null,
                    .padding_y = if (jf.padding_y) |v| @intCast(@min(10, @max(0, v))) else null,
                    .border_color = if (jf.border_color) |v| @intCast(@min(255, @max(0, v))) else null,
                    .show_title = jf.show_title,
                }) catch continue;
            }
            config.floats = float_list.toOwnedSlice(allocator) catch &[_]FloatDef{};
        }

        return config;
    }

    pub fn deinit(self: *Config) void {
        if (self._allocator) |alloc| {
            for (self.floats) |f| {
                alloc.free(f.name);
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

    fn getConfigPath(allocator: std.mem.Allocator) ![]const u8 {
        const config_home = posix.getenv("XDG_CONFIG_HOME");
        if (config_home) |ch| {
            return std.fmt.allocPrint(allocator, "{s}/hexa/config.json", .{ch});
        }

        const home = posix.getenv("HOME") orelse return error.NoHome;
        return std.fmt.allocPrint(allocator, "{s}/.config/hexa/config.json", .{home});
    }
};

// JSON structure for parsing
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
    float: ?struct {
        width_percent: ?i64 = null,
        height_percent: ?i64 = null,
        padding_x: ?i64 = null,
        padding_y: ?i64 = null,
        border_color: ?i64 = null,
        show_title: ?bool = null,
    } = null,
    floats: ?[]const struct {
        key: []const u8,
        name: []const u8,
        command: ?[]const u8 = null,
        alone: ?bool = null,
        width_percent: ?i64 = null,
        height_percent: ?i64 = null,
        pos_x: ?i64 = null,
        pos_y: ?i64 = null,
        padding_x: ?i64 = null,
        padding_y: ?i64 = null,
        border_color: ?i64 = null,
        show_title: ?bool = null,
    } = null,
    status: ?struct {
        enabled: ?bool = null,
    } = null,
};
