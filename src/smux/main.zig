const std = @import("std");
const posix = std.posix;

const core = @import("core");
const ghostty = @import("ghostty-vt");

const c = @cImport({
    @cInclude("sys/ioctl.h");
});

const State = struct {
    allocator: std.mem.Allocator,
    pty: core.Pty = undefined,
    terminal: ghostty.Terminal = undefined,
    stream: Stream = undefined,
    cols: u16 = 0,
    rows: u16 = 0,

    const Stream = @TypeOf((@as(*ghostty.Terminal, undefined)).vtStream());

    fn init(self: *State, allocator: std.mem.Allocator) !void {
        const size = getTermSize();

        self.* = .{ .allocator = allocator };

        self.pty = try core.Pty.spawn(posix.getenv("SHELL") orelse "/bin/sh");
        errdefer self.pty.close();
        try self.pty.setSize(size.cols, size.rows);

        // IMPORTANT: do NOT return/copy this terminal after init.
        // Ghostty terminal state expects to live at a stable address.
        self.terminal = try ghostty.Terminal.init(allocator, .{ .cols = size.cols, .rows = size.rows });
        errdefer self.terminal.deinit(allocator);

        // Persistent stream: required for CSI/OSC sequences split across reads.
        self.stream = self.terminal.vtStream();

        self.cols = size.cols;
        self.rows = size.rows;
    }

    fn deinit(self: *State) void {
        self.pty.close();
        self.stream.deinit();
        self.terminal.deinit(self.allocator);
        self.* = undefined;
    }
};

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    var state: State = undefined;
    try state.init(allocator);
    defer state.deinit();

    const stdout = std.fs.File.stdout();

    // Enter alternate screen, clear and hide cursor.
    // We also clear scrollback (CSI 3 J) to avoid old content flashes.
    try stdout.writeAll("\x1b[?1049h\x1b[2J\x1b[3J\x1b[H\x1b[?25l");
    defer stdout.writeAll("\x1b[0m\x1b[?25h\x1b[?1049l") catch {};

    const orig_termios = try enableRawMode(posix.STDIN_FILENO);
    defer disableRawMode(posix.STDIN_FILENO, orig_termios) catch {};

    // NOTE: We rely on poll() before read() so we don't need NONBLOCK.

    var poll_fds = [_]posix.pollfd{
        .{ .fd = posix.STDIN_FILENO, .events = posix.POLL.IN, .revents = 0 },
        .{ .fd = state.pty.master_fd, .events = posix.POLL.IN, .revents = 0 },
    };

    var buf: [65536]u8 = undefined;

    while (true) {
        // Handle resizes.
        const size = getTermSize();
        if (size.cols != state.cols or size.rows != state.rows) {
            state.cols = size.cols;
            state.rows = size.rows;
            try state.pty.setSize(size.cols, size.rows);
            try state.terminal.resize(state.allocator, size.cols, size.rows);
            try stdout.writeAll("\x1b[2J\x1b[H");
        }

        _ = posix.poll(&poll_fds, 50) catch continue;

        // Forward keyboard input to the PTY.
        if ((poll_fds[0].revents & posix.POLL.IN) != 0) {
            const n = posix.read(posix.STDIN_FILENO, &buf) catch |err| switch (err) {
                error.WouldBlock => 0,
                else => return err,
            };
            if (n > 0) {
                _ = try state.pty.write(buf[0..n]);
            }
        }

        var drew: bool = false;

        // Read PTY output and feed ghostty.
        if ((poll_fds[1].revents & posix.POLL.IN) != 0) {
            const n = posix.read(state.pty.master_fd, &buf) catch |err| switch (err) {
                error.WouldBlock => 0,
                else => return err,
            };
            if (n > 0) {
                try state.stream.nextSlice(buf[0..n]);
                drew = true;
            }
        }

        // Exit if child is dead.
        if (state.pty.pollStatus() != null) break;

        // Full redraw using ghostty's own VT formatter.
        if (drew) {
            try render(&state, stdout);
        }
    }
}

fn render(state: *State, stdout: std.fs.File) !void {
    // Full redraw using ghostty's own VT formatter.
    // We build to an allocating writer and then flush in one write.
    var out: std.Io.Writer.Allocating = .init(state.allocator);
    defer out.deinit();

    // Home + clear visible screen.
    try out.writer.writeAll("\x1b[H\x1b[2J");

    var fmt = ghostty.formatter.ScreenFormatter.init(state.terminal.screens.active, .{
        .emit = .vt,
        .unwrap = false,
        .trim = false,
        .codepoint_map = null,
        .background = null,
        .foreground = null,
        .palette = null,
    });
    fmt.content = .{ .selection = null };
    fmt.extra = .all;

    try fmt.format(&out.writer);

    try stdout.writeAll(out.written());
}

fn getTermSize() struct { cols: u16, rows: u16 } {
    var ws: c.winsize = undefined;
    if (c.ioctl(posix.STDOUT_FILENO, c.TIOCGWINSZ, &ws) == 0) {
        return .{
            .cols = if (ws.ws_col > 0) ws.ws_col else 80,
            .rows = if (ws.ws_row > 0) ws.ws_row else 24,
        };
    }
    return .{ .cols = 80, .rows = 24 };
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
    termios.cc[@intFromEnum(posix.V.MIN)] = 1;
    termios.cc[@intFromEnum(posix.V.TIME)] = 0;

    try posix.tcsetattr(fd, .FLUSH, termios);
    return orig;
}

fn disableRawMode(fd: posix.fd_t, orig: posix.termios) !void {
    try posix.tcsetattr(fd, .FLUSH, orig);
}
