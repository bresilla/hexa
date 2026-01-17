const std = @import("std");
const posix = std.posix;
const IpcClient = @import("ipc.zig").IpcClient;
const Server = @import("server.zig").Server;
const SocketPath = @import("ipc.zig").SocketPath;

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len > 1) {
        if (std.mem.eql(u8, args[1], "server")) {
            var server = try Server.init(allocator);
            defer server.deinit();
            try server.run();
            return;
        }
        if (std.mem.eql(u8, args[1], "attach")) {
            return attachClient();
        }
        if (std.mem.eql(u8, args[1], "kill")) {
            try killServer();
            return;
        }
        if (std.mem.eql(u8, args[1], "help")) {
            printHelp();
            return;
        }
    }

    const client = IpcClient.connect() catch |err| {
        if (err == error.ConnectionRefused or err == error.FileNotFound) {
            if (IpcClient.isServerRunning()) {
                std.debug.print("Server is running but connection failed\n", .{});
                return err;
            }
            const pid = try posix.fork();
            if (pid == 0) {
                var server = try Server.init(allocator);
                defer server.deinit();
                try server.run();
                posix.exit(0);
            }
            std.Thread.sleep(200_000_000);
            return attachClient();
        }
        return err;
    };
    defer client.deinit();

    const orig_termios = try enableRawMode(posix.STDIN_FILENO);
    defer disableRawMode(posix.STDIN_FILENO, orig_termios) catch {};

    const stdout = std.fs.File.stdout();
    var poll_fds = [_]posix.pollfd{
        .{ .fd = std.fs.File.stdin().handle, .events = posix.POLL.IN, .revents = 0 },
        .{ .fd = client.fd, .events = posix.POLL.IN, .revents = 0 },
    };

    var buffer: [8192]u8 = undefined;

    while (true) {
        _ = try posix.poll(&poll_fds, -1);

        if (poll_fds[0].revents & posix.POLL.IN != 0) {
            const bytes = try std.fs.File.stdin().read(&buffer);
            if (bytes == 0) break;
            _ = try posix.write(client.fd, buffer[0..bytes]);
        }

        if (poll_fds[1].revents & posix.POLL.IN != 0) {
            const bytes = try posix.read(client.fd, &buffer);
            if (bytes == 0) break;
            _ = try stdout.write(buffer[0..bytes]);
        }
    }
}

fn attachClient() !void {
    var client = try IpcClient.connect();
    defer client.deinit();

    const orig_termios = try enableRawMode(posix.STDIN_FILENO);
    defer disableRawMode(posix.STDIN_FILENO, orig_termios) catch {};

    const stdout = std.fs.File.stdout();
    var poll_fds = [_]posix.pollfd{
        .{ .fd = std.fs.File.stdin().handle, .events = posix.POLL.IN, .revents = 0 },
        .{ .fd = client.fd, .events = posix.POLL.IN, .revents = 0 },
    };

    var buffer: [8192]u8 = undefined;

    while (true) {
        _ = try posix.poll(&poll_fds, -1);

        if (poll_fds[0].revents & posix.POLL.IN != 0) {
            const bytes = try std.fs.File.stdin().read(&buffer);
            if (bytes == 0) break;
            _ = try posix.write(client.fd, buffer[0..bytes]);
        }

        if (poll_fds[1].revents & posix.POLL.IN != 0) {
            const bytes = try posix.read(client.fd, &buffer);
            if (bytes == 0) break;
            _ = try stdout.write(buffer[0..bytes]);
        }
    }
}

fn killServer() !void {
    const path = SocketPath.get();
    std.fs.deleteFileAbsolute(path) catch |err| {
        if (err != error.FileNotFound) return err;
    };
    std.debug.print("Server socket removed\n", .{});
}

fn printHelp() void {
    std.debug.print(
        \\mux - Terminal multiplexer
        \\
        \\Usage:
        \\  mux              Start mux (forks server in background if needed)
        \\  mux attach       Attach to running mux server
        \\  mux server       Run mux server (usually runs in background)
        \\  mux kill         Kill mux server
        \\  mux help         Show this help
        \\
        \\Key bindings (prefix: Ctrl+A):
        \\  Panes:
        \\    prefix+|       Split horizontal
        \\    prefix+-       Split vertical
        \\    prefix+o       Next pane
        \\    prefix+x       Close pane
        \\    prefix+z       Zoom/unzoom pane (fullscreen)
        \\
        \\  Windows:
        \\    prefix+n       New window
        \\    prefix+w       Next window
        \\    prefix+W       Previous window
        \\
        \\  Sessions:
        \\    prefix+s       New session
        \\    prefix+l       List sessions
        \\    prefix+0-9     Switch to session
        \\    prefix+d       Detach from session
        \\
        \\  Floating:
        \\    prefix+f       New floating pane
        \\    prefix+F       Close floating pane
        \\
        \\  Scrollback:
        \\    prefix+[       Enter copy/scroll mode
        \\    prefix+k       Scroll up
        \\    prefix+j       Scroll down
        \\    prefix+u       Page up
        \\    prefix+D       Page down
        \\    prefix+g       Scroll to top
        \\    prefix+G       Scroll to bottom
        \\
    , .{});
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
