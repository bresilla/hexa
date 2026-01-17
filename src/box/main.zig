const std = @import("std");
const posix = std.posix;
const core = @import("core");

const c = @cImport({
    @cInclude("sys/ioctl.h");
});

fn getTerminalWidth() u16 {
    var ws: c.winsize = undefined;
    if (c.ioctl(posix.STDOUT_FILENO, c.TIOCGWINSZ, &ws) == 0) {
        return if (ws.ws_col > 0) ws.ws_col else 80;
    }
    return 80;
}

fn printHelp() void {
    std.debug.print(
        \\box - Terminal block wrapper
        \\
        \\Usage:
        \\  box              Start box with default shell ($SHELL)
        \\  box <shell>      Start box with specified shell
        \\  box help         Show this help
        \\
        \\Box shows a decoration line after each command completes.
        \\Full-screen apps (vim, htop, etc.) work normally.
        \\
    , .{});
}

/// Simple prompt detector
const PromptDetector = struct {
    line_buf: [512]u8 = undefined,
    line_len: usize = 0,
    command_running: bool = false,
    in_alt_screen: bool = false,

    // Check for alternate screen sequences in output
    fn checkAltScreen(self: *PromptDetector, data: []const u8) void {
        // Look for ESC[?1049h (enter) or ESC[?1049l (exit)
        // Also ESC[?47h/l and ESC[?1047h/l
        for (data, 0..) |byte, i| {
            if (byte == 0x1b and i + 4 < data.len) {
                if (data[i + 1] == '[' and data[i + 2] == '?') {
                    // Check for 1049h, 1049l, 47h, 47l, 1047h, 1047l
                    const rest = data[i + 3 ..];
                    if (std.mem.startsWith(u8, rest, "1049h") or
                        std.mem.startsWith(u8, rest, "47h") or
                        std.mem.startsWith(u8, rest, "1047h"))
                    {
                        self.in_alt_screen = true;
                    } else if (std.mem.startsWith(u8, rest, "1049l") or
                        std.mem.startsWith(u8, rest, "47l") or
                        std.mem.startsWith(u8, rest, "1047l"))
                    {
                        self.in_alt_screen = false;
                    }
                }
            }
        }
    }

    fn userPressedEnter(self: *PromptDetector) void {
        if (!self.in_alt_screen) {
            self.command_running = true;
            self.line_len = 0;
        }
    }

    fn processOutput(self: *PromptDetector, data: []const u8) bool {
        self.checkAltScreen(data);

        if (!self.command_running or self.in_alt_screen) return false;

        for (data) |byte| {
            if (byte == '\n' or byte == '\r') {
                if (self.isPromptLine()) {
                    self.command_running = false;
                    self.line_len = 0;
                    return true;
                }
                self.line_len = 0;
            } else if (self.line_len < self.line_buf.len) {
                self.line_buf[self.line_len] = byte;
                self.line_len += 1;
            }
        }

        // Check partial line (prompt without trailing newline)
        if (self.line_len > 3 and self.isPromptLine()) {
            self.command_running = false;
            return true;
        }

        return false;
    }

    fn isPromptLine(self: *PromptDetector) bool {
        if (self.line_len < 2) return false;
        const line = self.line_buf[0..self.line_len];

        // Common prompt endings
        const suffixes = [_][]const u8{ "$ ", "# ", "% ", "> ", "❯ ", "→ ", "➜ ", "» ", "λ " };
        for (suffixes) |suffix| {
            if (std.mem.endsWith(u8, line, suffix)) return true;
        }

        // Heuristic: ends with non-alphanumeric + space
        if (line.len > 3) {
            const last = line[line.len - 1];
            const second_last = line[line.len - 2];
            if (last == ' ' and !std.ascii.isAlphanumeric(second_last)) {
                return true;
            }
        }

        return false;
    }
};

/// Render a simple decoration line
fn renderDecoration(allocator: std.mem.Allocator, block_id: usize, width: u16) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator, "\r\n\x1b[90m"); // dim gray
    try buf.writer(allocator).print("─── #{d} ", .{block_id});

    const used: usize = 6 + (if (block_id < 10) @as(usize, 1) else if (block_id < 100) @as(usize, 2) else @as(usize, 3));
    const remaining = if (width > used) width - used else 0;
    for (0..remaining) |_| {
        try buf.appendSlice(allocator, "─");
    }
    try buf.appendSlice(allocator, "\x1b[0m\r\n");

    return try buf.toOwnedSlice(allocator);
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len > 1) {
        if (std.mem.eql(u8, args[1], "help") or std.mem.eql(u8, args[1], "--help") or std.mem.eql(u8, args[1], "-h")) {
            printHelp();
            return;
        }
    }

    const shell = if (args.len > 1) args[1] else posix.getenv("SHELL") orelse "/bin/sh";

    if (!posix.isatty(posix.STDIN_FILENO)) {
        std.debug.print("Error: box requires a terminal (TTY) to run\n", .{});
        std.process.exit(1);
    }

    const pty_handle = try core.Pty.spawnWithEnv(shell);
    defer pty_handle.close();

    const orig_termios = try enableRawMode(posix.STDIN_FILENO);
    defer disableRawMode(posix.STDIN_FILENO, orig_termios) catch {};

    const stdout = std.fs.File.stdout();
    const stdin = std.fs.File.stdin();

    var poll_fds = [_]posix.pollfd{
        .{ .fd = stdin.handle, .events = posix.POLL.IN, .revents = 0 },
        .{ .fd = pty_handle.master_fd, .events = posix.POLL.IN, .revents = 0 },
    };

    var buffer: [8192]u8 = undefined;
    var last_size = core.TermSize.fromStdout();

    var prompt_detector: PromptDetector = .{};
    var block_id: usize = 0;

    while (true) {
        _ = try posix.poll(&poll_fds, 100);

        // Handle terminal resize
        const current_size = core.TermSize.fromStdout();
        if (current_size.cols != last_size.cols or current_size.rows != last_size.rows) {
            last_size = current_size;
            pty_handle.setSize(current_size.cols, current_size.rows) catch {};
        }

        if (pty_handle.pollStatus()) |_| break;

        // Handle input - pass through, but detect Enter
        if (poll_fds[0].revents & posix.POLL.IN != 0) {
            const bytes_read = try stdin.read(&buffer);
            if (bytes_read > 0) {
                // Check for Enter key to mark command start
                for (buffer[0..bytes_read]) |byte| {
                    if (byte == '\r' or byte == '\n') {
                        prompt_detector.userPressedEnter();
                        block_id += 1;
                    }
                }
                _ = try pty_handle.write(buffer[0..bytes_read]);
            }
        }

        // Handle output - pass through, detect prompt for decoration
        if (poll_fds[1].revents & posix.POLL.IN != 0) {
            const bytes_read = try pty_handle.read(&buffer);
            if (bytes_read > 0) {
                _ = try stdout.write(buffer[0..bytes_read]);

                // Show decoration when command finishes (prompt detected)
                if (prompt_detector.processOutput(buffer[0..bytes_read])) {
                    const decoration = try renderDecoration(allocator, block_id, getTerminalWidth());
                    defer allocator.free(decoration);
                    _ = try stdout.write(decoration);
                }
            }
        }

        if (poll_fds[1].revents & (posix.POLL.ERR | posix.POLL.HUP) != 0) break;
    }
}

fn enableRawMode(fd: posix.fd_t) !posix.termios {
    var termios = try posix.tcgetattr(fd);
    const orig = termios;

    termios.iflag.BRKINT = false;
    termios.iflag.ICRNL = false;
    termios.iflag.INPCK = false;
    termios.iflag.ISTRIP = false;
    termios.iflag.IXON = false;
    termios.oflag.OPOST = false;
    termios.cflag.CSIZE = .CS8;
    termios.lflag.ECHO = false;
    termios.lflag.ICANON = false;
    termios.lflag.IEXTEN = false;
    termios.lflag.ISIG = false;
    termios.cc[@intFromEnum(posix.V.MIN)] = 0;
    termios.cc[@intFromEnum(posix.V.TIME)] = 1;

    try posix.tcsetattr(fd, .FLUSH, termios);
    return orig;
}

fn disableRawMode(fd: posix.fd_t, orig: posix.termios) !void {
    try posix.tcsetattr(fd, .FLUSH, orig);
}
