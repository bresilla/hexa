const std = @import("std");

/// Prompt detector - identifies command prompts without shell integration
pub const PromptDetector = struct {
    allocator: std.mem.Allocator,
    line_buffer: std.ArrayList(u8) = .empty,
    stripped_buffer: std.ArrayList(u8) = .empty,
    command_running: bool = false,
    output_received: bool = false,

    // Common prompt endings - order matters, check longer first
    const prompt_suffixes = [_][]const u8{
        "$ ",
        "# ",
        "% ",
        "> ",
        "❯ ",
        "→ ",
        "➜ ",
        "╰─$ ",
        "└─$ ",
        "» ",
        "λ ",
        "~$ ",
        "~# ",
    };

    // Patterns that indicate a prompt (anywhere in line)
    const prompt_patterns = [_][]const u8{
        " :: |", // User's prompt style
        "bloxs", // Appears in user's prompt
        "|||", // User's prompt
        "@", // user@host
    };

    pub fn init(allocator: std.mem.Allocator) PromptDetector {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *PromptDetector) void {
        self.line_buffer.deinit(self.allocator);
        self.stripped_buffer.deinit(self.allocator);
    }

    /// Called when user presses Enter - marks command as running
    pub fn userPressedEnter(self: *PromptDetector) void {
        self.command_running = true;
        self.output_received = false;
        self.line_buffer.clearRetainingCapacity();
    }

    /// Process output data, returns true if prompt detected (command finished)
    pub fn processOutput(self: *PromptDetector, data: []const u8) bool {
        if (!self.command_running) return false;

        // Mark that we've received some output
        if (data.len > 0) {
            self.output_received = true;
        }

        for (data) |byte| {
            if (byte == '\n' or byte == '\r') {
                // Check completed line for prompt
                if (self.isPromptLine()) {
                    self.command_running = false;
                    self.line_buffer.clearRetainingCapacity();
                    return true;
                }
                self.line_buffer.clearRetainingCapacity();
            } else {
                self.line_buffer.append(self.allocator, byte) catch {};
            }
        }

        // Check partial line too (prompt shown without trailing newline)
        if (self.line_buffer.items.len > 3 and self.isPromptLine()) {
            self.command_running = false;
            return true;
        }

        return false;
    }

    /// Strip ANSI escape sequences from a line for pattern matching
    fn stripAnsi(self: *PromptDetector, input: []const u8) []const u8 {
        self.stripped_buffer.clearRetainingCapacity();

        var i: usize = 0;
        while (i < input.len) {
            if (input[i] == 0x1b and i + 1 < input.len and input[i + 1] == '[') {
                // CSI sequence: ESC [ ... final_byte
                i += 2;
                while (i < input.len) {
                    const c = input[i];
                    i += 1;
                    // Final byte is in range 0x40-0x7E
                    if (c >= 0x40 and c <= 0x7E) break;
                }
            } else if (input[i] == 0x1b and i + 1 < input.len and input[i + 1] == ']') {
                // OSC sequence: ESC ] ... ST or BEL
                i += 2;
                while (i < input.len) {
                    if (input[i] == 0x07) {
                        i += 1;
                        break;
                    } // BEL
                    if (input[i] == 0x1b and i + 1 < input.len and input[i + 1] == '\\') {
                        i += 2;
                        break;
                    } // ST
                    i += 1;
                }
            } else {
                self.stripped_buffer.append(self.allocator, input[i]) catch {};
                i += 1;
            }
        }

        return self.stripped_buffer.items;
    }

    fn isPromptLine(self: *PromptDetector) bool {
        const raw_line = self.line_buffer.items;
        if (raw_line.len < 2) return false;

        // Strip ANSI codes for pattern matching
        const line = self.stripAnsi(raw_line);
        if (line.len < 2) return false;

        // Check for common prompt suffixes
        for (prompt_suffixes) |suffix| {
            if (std.mem.endsWith(u8, line, suffix)) {
                return true;
            }
        }

        // Check for prompt patterns anywhere in line
        for (prompt_patterns) |pattern| {
            if (std.mem.indexOf(u8, line, pattern) != null) {
                // Line contains a prompt pattern - likely a prompt
                return true;
            }
        }

        // Heuristic: if line is shortish and ends with space after non-alpha
        if (line.len > 3 and line.len < 300) {
            const last = line[line.len - 1];
            const second_last = line[line.len - 2];
            // Ends with "X " where X is not alphanumeric
            if (last == ' ' and !std.ascii.isAlphanumeric(second_last)) {
                return true;
            }
        }

        return false;
    }

    /// Check if a command is currently running
    pub fn isCommandRunning(self: *PromptDetector) bool {
        return self.command_running;
    }
};
