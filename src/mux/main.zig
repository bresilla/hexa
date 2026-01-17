const std = @import("std");
const posix = std.posix;
const IpcClient = @import("ipc.zig").IpcClient;
const Server = @import("server.zig").Server;

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len > 1 and std.mem.eql(u8, args[1], "server")) {
        var server = try Server.init(allocator);
        defer server.deinit();
        try server.run();
        return;
    }

    var client = IpcClient.connect() catch |err| {
        if (err == error.ConnectionRefused or err == error.FileNotFound) {
            const pid = try posix.fork();
            if (pid == 0) {
                var server = try Server.init(allocator);
                defer server.deinit();
                try server.run();
                posix.exit(0);
            }
            std.Thread.sleep(200_000_000);
            return main();
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
