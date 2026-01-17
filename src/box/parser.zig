const std = @import("std");
const ansi = @import("core").ansi;

pub const EventType = enum {
    prompt_start, // A - prompt started
    command_input, // B - command input (after prompt, before user input)
    command_output_start, // C - command output started (after Enter)
    command_end, // D - command finished
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
            // Check for OSC 133 sequence: ESC ] 1 3 3 ; X ST
            if (i + 6 < data.len and
                data[i] == 0x1b and
                data[i + 1] == ']' and
                data[i + 2] == '1' and
                data[i + 3] == '3' and
                data[i + 4] == '3' and
                data[i + 5] == ';')
            {
                i += 6; // Skip ESC ] 1 3 3 ;

                if (i < data.len and data[i] == 'A') {
                    i += 1;
                    try events.append(self.allocator, .{ .kind = .prompt_start });
                } else if (i < data.len and data[i] == 'B') {
                    i += 1;
                    try events.append(self.allocator, .{ .kind = .command_input });
                } else if (i < data.len and data[i] == 'C') {
                    i += 1;
                    try events.append(self.allocator, .{ .kind = .command_output_start });
                } else if (i < data.len and data[i] == 'D') {
                    i += 1;
                    var exit_code: ?u8 = null;

                    // Skip the ';' separator before exit code
                    if (i < data.len and data[i] == ';') {
                        i += 1;
                    }

                    // Check for exit code (digits)
                    if (i < data.len and data[i] >= '0' and data[i] <= '9') {
                        const start = i;
                        while (i < data.len and data[i] >= '0' and data[i] <= '9') {
                            i += 1;
                        }
                        if (start < i) {
                            exit_code = std.fmt.parseInt(u8, data[start..i], 10) catch null;
                        }
                    }

                    try events.append(self.allocator, .{ .kind = .command_end, .exit_code = exit_code });
                } else {
                    i += 1; // Skip unknown marker
                }

                // Skip ST (ESC \) if present
                if (i + 1 < data.len and data[i] == 0x1b and data[i + 1] == '\\') {
                    i += 2;
                }

                continue;
            }

            // Add byte to cleaned output
            try cleaned.append(self.allocator, data[i]);
            i += 1;
        }

        return ParseResult{
            .cleaned = try cleaned.toOwnedSlice(self.allocator),
            .events = try events.toOwnedSlice(self.allocator),
        };
    }
};
