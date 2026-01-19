const std = @import("std");
const core = @import("core");
const shp = @import("shp");
const render = @import("render.zig");
const Pane = @import("pane.zig").Pane;

pub const Renderer = render.Renderer;

pub const RenderedSegment = struct {
    text: []const u8,
    fg: render.Color,
    bg: render.Color,
    bold: bool,
    italic: bool,
};

pub const RenderedSegments = struct {
    items: [16]RenderedSegment,
    buffers: [16][64]u8,
    count: usize,
    total_len: usize,
};

pub fn renderModuleOutput(module: *const core.StatusModule, output: []const u8) RenderedSegments {
    var result = RenderedSegments{
        .items = undefined,
        .buffers = undefined,
        .count = 0,
        .total_len = 0,
    };

    for (module.outputs) |out| {
        if (result.count >= 16) break;

        var text_len: usize = 0;
        var i: usize = 0;
        while (i < out.format.len and text_len < 64) {
            if (i + 6 < out.format.len and std.mem.eql(u8, out.format[i .. i + 7], "$output")) {
                const copy_len = @min(output.len, 64 - text_len);
                @memcpy(result.buffers[result.count][text_len .. text_len + copy_len], output[0..copy_len]);
                text_len += copy_len;
                i += 7;
            } else {
                result.buffers[result.count][text_len] = out.format[i];
                text_len += 1;
                i += 1;
            }
        }

        const style = shp.Style.parse(out.style);

        result.items[result.count] = .{
            .text = result.buffers[result.count][0..text_len],
            .fg = if (style.fg != .none) styleColorToRender(style.fg) else .none,
            .bg = if (style.bg != .none) styleColorToRender(style.bg) else .none,
            .bold = style.bold,
            .italic = style.italic,
        };
        result.total_len += text_len;
        result.count += 1;
    }

    return result;
}

pub fn styleColorToRender(col: shp.Color) render.Color {
    return switch (col) {
        .none => .none,
        .palette => |p| .{ .palette = p },
        .rgb => |rgb| .{ .rgb = .{ .r = rgb.r, .g = rgb.g, .b = rgb.b } },
    };
}

pub fn runStatusModule(module: *const core.StatusModule, buf: []u8) ![]const u8 {
    if (module.command) |cmd| {
        const result = std.process.Child.run(.{
            .allocator = std.heap.page_allocator,
            .argv = &.{ "/bin/sh", "-c", cmd },
        }) catch return "";
        defer std.heap.page_allocator.free(result.stdout);
        defer std.heap.page_allocator.free(result.stderr);

        var len = result.stdout.len;
        while (len > 0 and (result.stdout[len - 1] == '\n' or result.stdout[len - 1] == '\r')) {
            len -= 1;
        }
        const copy_len = @min(len, buf.len);
        @memcpy(buf[0..copy_len], result.stdout[0..copy_len]);
        return buf[0..copy_len];
    }

    const copy_len = @min(module.name.len, buf.len);
    @memcpy(buf[0..copy_len], module.name[0..copy_len]);
    return buf[0..copy_len];
}

pub fn draw(
    renderer: *Renderer,
    allocator: std.mem.Allocator,
    config: *const core.Config,
    term_width: u16,
    term_height: u16,
    tabs: anytype,
    active_tab: usize,
    session_name: []const u8,
) void {
    const y = term_height - 1;
    const width = term_width;
    const cfg = &config.tabs.status;

    // Clear status bar
    for (0..width) |xi| {
        renderer.setCell(@intCast(xi), y, .{ .char = ' ' });
    }

    // Create shp context
    var ctx = shp.Context.init(allocator);
    defer ctx.deinit();
    ctx.terminal_width = width;

    // Find the tabs module to check tab_title setting
    var use_basename = true;
    for (cfg.center) |mod| {
        if (std.mem.eql(u8, mod.name, "tabs")) {
            use_basename = std.mem.eql(u8, mod.tab_title, "basename");
            break;
        }
    }

    // Collect tab titles for center section
    var tab_names: [16][]const u8 = undefined;
    var tab_count: usize = 0;
    for (tabs.items) |*tab| {
        if (tab_count < 16) {
            if (use_basename) {
                if (tab.layout.getFocusedPane()) |pane| {
                    const pwd = pane.getRealCwd();
                    tab_names[tab_count] = if (pwd) |p| std.fs.path.basename(p) else tab.name;
                } else {
                    tab_names[tab_count] = tab.name;
                }
            } else {
                tab_names[tab_count] = tab.name;
            }
            tab_count += 1;
        }
    }
    ctx.tab_names = tab_names[0..tab_count];
    ctx.active_tab = active_tab;
    ctx.session_name = session_name;

    // === DRAW LEFT SECTION ===
    var left_x: u16 = 0;
    for (cfg.left) |mod| {
        left_x = drawModule(renderer, &ctx, mod, left_x, y);
    }

    // === CALCULATE RIGHT WIDTH ===
    var right_width: u16 = 0;
    for (cfg.right) |mod| {
        right_width += calcModuleWidth(&ctx, mod);
    }
    const right_start = width -| right_width;

    // === DRAW RIGHT SECTION ===
    var rx: u16 = right_start;
    for (cfg.right) |mod| {
        rx = drawModule(renderer, &ctx, mod, rx, y);
    }

    // === CALCULATE CENTER WIDTH ===
    var center_width: u16 = 0;
    for (cfg.center) |mod| {
        if (std.mem.eql(u8, mod.name, "tabs")) {
            for (ctx.tab_names, 0..) |tab_name, i| {
                if (i > 0) center_width += @as(u16, @intCast(mod.separator.len));
                center_width += 2 + @as(u16, @intCast(tab_name.len)) + 2;
            }
        }
    }

    // === DRAW CENTER SECTION (truly centered) ===
    const center_start = (width -| center_width) / 2;
    if (center_start > left_x + 2 and center_start + center_width < right_start -| 2) {
        var cx: u16 = center_start;
        for (cfg.center) |mod| {
            if (std.mem.eql(u8, mod.name, "tabs")) {
                const active_style = shp.Style.parse(mod.active_style);
                const inactive_style = shp.Style.parse(mod.inactive_style);
                const sep_style = shp.Style.parse(mod.separator_style);

                for (ctx.tab_names, 0..) |tab_name, i| {
                    if (i > 0) {
                        cx = drawStyledText(renderer, cx, y, mod.separator, sep_style);
                    }
                    const is_active = i == ctx.active_tab;
                    const style = if (is_active) active_style else inactive_style;
                    const arrow_fg = if (is_active) active_style.bg else inactive_style.bg;
                    const arrow_style = shp.Style{ .fg = arrow_fg };

                    cx = drawStyledText(renderer, cx, y, "", arrow_style);
                    cx = drawStyledText(renderer, cx, y, " ", style);
                    cx = drawStyledText(renderer, cx, y, tab_name, style);
                    cx = drawStyledText(renderer, cx, y, " ", style);
                    cx = drawStyledText(renderer, cx, y, "", arrow_style);
                }
            }
        }
    }
}

pub fn drawModule(renderer: *Renderer, ctx: *shp.Context, mod: core.config.StatusModule, start_x: u16, y: u16) u16 {
    var x = start_x;

    var output_text: []const u8 = "";

    if (std.mem.eql(u8, mod.name, "session")) {
        output_text = ctx.session_name;
    } else {
        if (ctx.renderSegment(mod.name)) |segs| {
            if (segs.len > 0) {
                output_text = segs[0].text;
            }
        }
    }

    for (mod.outputs) |out| {
        const style = shp.Style.parse(out.style);
        x = drawFormatted(renderer, x, y, out.format, output_text, style);
    }

    return x;
}

pub fn drawFormatted(renderer: *Renderer, start_x: u16, y: u16, format: []const u8, output: []const u8, style: shp.Style) u16 {
    var x = start_x;
    var i: usize = 0;

    while (i < format.len) {
        if (i + 7 <= format.len and std.mem.eql(u8, format[i..][0..7], "$output")) {
            x = drawStyledText(renderer, x, y, output, style);
            i += 7;
        } else {
            const len = std.unicode.utf8ByteSequenceLength(format[i]) catch 1;
            const end = @min(i + len, format.len);
            x = drawStyledText(renderer, x, y, format[i..end], style);
            i = end;
        }
    }
    return x;
}

pub fn calcModuleWidth(ctx: *shp.Context, mod: core.config.StatusModule) u16 {
    var width: u16 = 0;

    var output_text: []const u8 = "";

    if (std.mem.eql(u8, mod.name, "session")) {
        output_text = ctx.session_name;
    } else {
        if (ctx.renderSegment(mod.name)) |segs| {
            if (segs.len > 0) {
                output_text = segs[0].text;
            }
        }
    }

    for (mod.outputs) |out| {
        width += calcFormattedWidth(out.format, output_text);
    }

    return width;
}

pub fn calcFormattedWidth(format: []const u8, output: []const u8) u16 {
    var width: u16 = 0;
    var i: usize = 0;

    while (i < format.len) {
        if (i + 7 <= format.len and std.mem.eql(u8, format[i..][0..7], "$output")) {
            var j: usize = 0;
            while (j < output.len) {
                const len = std.unicode.utf8ByteSequenceLength(output[j]) catch 1;
                j += len;
                width += 1;
            }
            i += 7;
        } else {
            const len = std.unicode.utf8ByteSequenceLength(format[i]) catch 1;
            i += len;
            width += 1;
        }
    }
    return width;
}

pub fn drawSegment(renderer: *Renderer, x: u16, y: u16, seg: shp.Segment, default_style: shp.Style) u16 {
    const style = if (seg.style.isEmpty()) default_style else seg.style;
    return drawStyledText(renderer, x, y, seg.text, style);
}

pub fn drawStyledText(renderer: *Renderer, start_x: u16, y: u16, text: []const u8, style: shp.Style) u16 {
    var x = start_x;
    var i: usize = 0;

    while (i < text.len) {
        const len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        const codepoint = std.unicode.utf8Decode(text[i..][0..len]) catch ' ';

        var cell = render.Cell{
            .char = codepoint,
            .bold = style.bold,
            .italic = style.italic,
        };

        switch (style.fg) {
            .none => {},
            .palette => |p| cell.fg = .{ .palette = p },
            .rgb => |rgb| cell.fg = .{ .rgb = .{ .r = rgb.r, .g = rgb.g, .b = rgb.b } },
        }
        switch (style.bg) {
            .none => {},
            .palette => |p| cell.bg = .{ .palette = p },
            .rgb => |rgb| cell.bg = .{ .rgb = .{ .r = rgb.r, .g = rgb.g, .b = rgb.b } },
        }

        renderer.setCell(x, y, cell);
        x += 1;
        i += len;
    }

    return x;
}
