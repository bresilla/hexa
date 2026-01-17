const std = @import("std");
const ansi = @import("core").ansi;

pub const EventType = enum {
    prompt_start,
    command_end,
};

pub const Event = struct {
    kind: EventType,
    exit_code: ?u8 = null,
};

pub const ParseResult = struct {
    cleaned: []u8,
    events: []Event,
};

pub const Parser = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Parser {
        return Parser{ .allocator = allocator };
    }

    pub fn parse(self: *Parser, data: []const u8) !ParseResult {
        var cleaned: std.ArrayList(u8) = .empty;
        var events: std.ArrayList(Event) = .empty;
        var i: usize = 0;

        while (i < data.len) {
            if (i + 4 < data.len and data[i] == 0x1b and data[i + 1] == ']' and data[i + 2] == '1' and data[i + 3] == '3' and data[i + 4] == '3') {
                i += 5;
                if (i < data.len and data[i] == ';') i += 1;
                if (i >= data.len) break;
                const marker = data[i];
                i += 1;
                var exit_code: ?u8 = null;
                if (i < data.len and data[i] == ';') {
                    i += 1;
                    const start = i;
                    while (i < data.len and data[i] >= '0' and data[i] <= '9') : (i += 1) {}
                    if (i > start) {
                        exit_code = try std.fmt.parseInt(u8, data[start..i], 10);
                    }
                }
                while (i + 1 < data.len and !(data[i] == 0x1b and data[i + 1] == '\\')) : (i += 1) {}
                if (i + 1 < data.len) i += 2;

                switch (marker) {
                    'A' => try events.append(self.allocator, .{ .kind = .prompt_start }),
                    'D' => try events.append(self.allocator, .{ .kind = .command_end, .exit_code = exit_code }),
                    else => {},
                }
                continue;
            }

            try cleaned.append(self.allocator, data[i]);
            i += 1;
        }

        return ParseResult{
            .cleaned = try cleaned.toOwnedSlice(self.allocator),
            .events = try events.toOwnedSlice(self.allocator),
        };
    }
};
