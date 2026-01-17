const std = @import("std");
const Block = @import("block.zig").Block;
const MouseHandler = @import("mouse.zig");

pub const ButtonRegion = struct {
    action: MouseHandler.MouseAction,
    x_start: u16,
    x_end: u16,
};

pub const RenderResult = struct {
    output: []u8,
    buttons: []ButtonRegion,
    y: u16,
};

pub const Style = enum {
    separator,
    box,
    minimal,
};

pub const Decorator = struct {
    allocator: std.mem.Allocator,
    style: Style = .separator,
    separator_char: u8 = '=',
    show_copy_button: bool = true,
    show_collapse_button: bool = true,
    cursor_row: u16 = 1,

    pub fn init(allocator: std.mem.Allocator) Decorator {
        return Decorator{ .allocator = allocator };
    }

    pub fn render(self: *Decorator, block: *const Block, width: usize, mouse: *MouseHandler.MouseHandler) !RenderResult {
        switch (self.style) {
            .separator => return self.renderSeparator(block, width, mouse),
            .box => return self.renderBox(block, width, mouse),
            .minimal => return self.renderMinimal(block, width, mouse),
        }
    }

    fn renderSeparator(self: *Decorator, block: *const Block, width: usize, mouse: *MouseHandler.MouseHandler) !RenderResult {
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(self.allocator);
        var buttons: std.ArrayList(ButtonRegion) = .empty;
        defer buttons.deinit(self.allocator);

        try output.append(self.allocator, '\n');

        const status = if (block.exit_code orelse 0 == 0) "✓" else "✗";
        try output.appendSlice(self.allocator, status);
        try output.append(self.allocator, ' ');

        try output.writer(self.allocator).print("│{d}│", .{block.id});
        try output.append(self.allocator, ' ');

        if (block.durationSeconds()) |duration| {
            try output.writer(self.allocator).print("{d:.1}s", .{duration});
            try output.append(self.allocator, ' ');
        }

        const collapse_symbol = if (block.collapsed) "[+]" else "[-]";
        if (self.show_collapse_button) {
            const x_start: u16 = @intCast(output.items.len);
            try output.appendSlice(self.allocator, collapse_symbol);
            try output.append(self.allocator, ' ');
            try buttons.append(self.allocator, .{
                .action = .toggle_collapse,
                .x_start = x_start,
                .x_end = @intCast(output.items.len - 1),
            });
        }

        const copy_symbol = "[📋]";
        if (self.show_copy_button) {
            const x_start: u16 = @intCast(output.items.len);
            try output.appendSlice(self.allocator, copy_symbol);
            try output.append(self.allocator, ' ');
            try buttons.append(self.allocator, .{
                .action = .copy_latest,
                .x_start = x_start,
                .x_end = @intCast(output.items.len - 1),
            });
        }

        const remaining = if (width > output.items.len - 1) width - (output.items.len - 1) else 0;
        try output.appendNTimes(self.allocator, self.separator_char, remaining);
        try output.append(self.allocator, '\n');

        const y = self.cursor_row;
        self.cursor_row += 2;

        for (buttons.items) |btn| {
            try mouse.addRegion(block.id, btn.action, btn.x_start, btn.x_end, y);
        }

        return RenderResult{
            .output = try output.toOwnedSlice(self.allocator),
            .buttons = try buttons.toOwnedSlice(self.allocator),
            .y = y,
        };
    }

    fn renderBox(self: *Decorator, block: *const Block, width: usize, mouse: *MouseHandler.MouseHandler) !RenderResult {
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(self.allocator);
        var buttons: std.ArrayList(ButtonRegion) = .empty;
        defer buttons.deinit(self.allocator);

        const status = if (block.exit_code orelse 0 == 0) "✓" else "✗";
        const duration_text = if (block.durationSeconds()) |d| try std.fmt.allocPrint(self.allocator, " {d:.1}s", .{d}) else "";
        defer if (duration_text.len > 0) self.allocator.free(duration_text);

        const collapse_symbol = if (block.collapsed) "[+]" else "[-]";

        var line1: std.ArrayList(u8) = .empty;
        defer line1.deinit(self.allocator);
        try line1.appendSlice(self.allocator, "┌─");
        try line1.writer(self.allocator).print("{s} {d}{s}", .{ status, block.id, duration_text });

        if (self.show_collapse_button) {
            const x_start: u16 = @intCast(line1.items.len);
            try line1.appendSlice(self.allocator, collapse_symbol);
            try line1.append(self.allocator, ' ');
            try buttons.append(self.allocator, .{
                .action = .toggle_collapse,
                .x_start = x_start,
                .x_end = @intCast(line1.items.len - 1),
            });
        }

        if (self.show_copy_button) {
            const x_start: u16 = @intCast(line1.items.len);
            try line1.appendSlice(self.allocator, "[📋]");
            try line1.append(self.allocator, ' ');
            try buttons.append(self.allocator, .{
                .action = .copy_latest,
                .x_start = x_start,
                .x_end = @intCast(line1.items.len - 1),
            });
        }

        const fill = if (width > line1.items.len + 2) width - line1.items.len - 2 else 0;
        var i: usize = 0;
        while (i < fill) : (i += 1) {
            try line1.appendSlice(self.allocator, "─");
        }
        try line1.appendSlice(self.allocator, "┐\n");

        try output.appendSlice(self.allocator, "│\n");
        try output.appendSlice(self.allocator, line1.items);
        try output.appendSlice(self.allocator, "│\n");

        const y = self.cursor_row;
        self.cursor_row += 3;

        for (buttons.items) |btn| {
            try mouse.addRegion(block.id, btn.action, btn.x_start, btn.x_end, y + 1);
        }

        return RenderResult{
            .output = try output.toOwnedSlice(self.allocator),
            .buttons = try buttons.toOwnedSlice(self.allocator),
            .y = y,
        };
    }

    fn renderMinimal(self: *Decorator, block: *const Block, width: usize, mouse: *MouseHandler.MouseHandler) !RenderResult {
        _ = width;
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(self.allocator);
        var buttons: std.ArrayList(ButtonRegion) = .empty;
        defer buttons.deinit(self.allocator);

        try output.append(self.allocator, '\n');

        const status = if (block.exit_code orelse 0 == 0) "✓" else "✗";
        try output.appendSlice(self.allocator, status);

        if (block.durationSeconds()) |duration| {
            try output.writer(self.allocator).print(" {d:.1}s", .{duration});
        }

        const collapse_symbol = if (block.collapsed) "[+]" else "[-]";
        if (self.show_collapse_button) {
            const x_start: u16 = @intCast(output.items.len);
            try output.append(self.allocator, ' ');
            try output.appendSlice(self.allocator, collapse_symbol);
            try buttons.append(self.allocator, .{
                .action = .toggle_collapse,
                .x_start = x_start,
                .x_end = @intCast(output.items.len - 1),
            });
        }

        const copy_symbol = "[📋]";
        if (self.show_copy_button) {
            const x_start: u16 = @intCast(output.items.len);
            try output.append(self.allocator, ' ');
            try output.appendSlice(self.allocator, copy_symbol);
            try buttons.append(self.allocator, .{
                .action = .copy_latest,
                .x_start = x_start,
                .x_end = @intCast(output.items.len - 1),
            });
        }

        try output.append(self.allocator, '\n');

        const y = self.cursor_row;
        self.cursor_row += 2;

        for (buttons.items) |btn| {
            try mouse.addRegion(block.id, btn.action, btn.x_start, btn.x_end, y);
        }

        return RenderResult{
            .output = try output.toOwnedSlice(self.allocator),
            .buttons = try buttons.toOwnedSlice(self.allocator),
            .y = y,
        };
    }

    pub fn resetCursor(self: *Decorator) void {
        self.cursor_row = 1;
    }
};
