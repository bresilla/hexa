const std = @import("std");
const core = @import("core");
const Parser = @import("parser.zig").Parser;
const BlockManager = @import("manager.zig").BlockManager;
const Decorator = @import("decorator.zig").Decorator;
const Keyboard = @import("keyboard.zig");
const Clipboard = @import("clipboard.zig");
const Mouse = @import("mouse.zig");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const shell = if (args.len > 1) args[1] else "/bin/sh";
    const pty_handle = try core.Pty.spawn(shell);
    defer pty_handle.close();

    const orig_termios = try enableRawMode(std.posix.STDIN_FILENO);
    defer disableRawMode(std.posix.STDIN_FILENO, orig_termios) catch {};

    const stdout = std.fs.File.stdout();
    _ = try stdout.write(core.ansi.enableMouseTracking(3));
    _ = try stdout.write(core.ansi.enableSgrMouseMode());
    defer {
        _ = stdout.write(core.ansi.disableMouseTracking()) catch {};
        _ = stdout.write(core.ansi.disableSgrMouseMode()) catch {};
    }

    var parser = Parser.init(allocator);
    var manager = BlockManager.init(allocator);
    defer manager.deinit();
    var decorator = Decorator.init(allocator);
    var keyboard = Keyboard.KeyboardHandler.init();
    var mouse = Mouse.MouseHandler.init();

    const config = @import("config.zig").BoxConfig.load(allocator) catch .{};
    decorator.separator_char = config.separator_char;

    try manager.startBlock();

    var poll_fds = [_]std.posix.pollfd{
        .{ .fd = std.fs.File.stdin().handle, .events = std.posix.POLL.IN, .revents = 0 },
        .{ .fd = pty_handle.master_fd, .events = std.posix.POLL.IN, .revents = 0 },
    };

    var buffer: [8192]u8 = undefined;

    while (true) {
        _ = try std.posix.poll(&poll_fds, -1);

        if (pty_handle.pollStatus()) |_| {
            break;
        }

        if (poll_fds[0].revents & std.posix.POLL.IN != 0) {
            const bytes_read = try std.fs.File.stdin().read(&buffer);
            if (bytes_read > 0) {
                if (Mouse.MouseHandler.isMouse(buffer[0..bytes_read])) {
                    mouse.handle(buffer[0..bytes_read]);
                    continue;
                }

                for (buffer[0..bytes_read]) |byte| {
                    switch (keyboard.handle(byte)) {
                        .copy_latest => {
                            if (manager.latest()) |block| {
                                const osc52 = try Clipboard.buildOsc52(allocator, block.output.items);
                                defer allocator.free(osc52);
                                _ = try stdout.write(osc52);
                            }
                        },
                        .toggle_collapse => {
                            manager.toggleLatestCollapse();
                        },
                        .search_error => {
                            const matches = manager.search("error");
                            const summary = try std.fmt.allocPrint(allocator, "\n[search] {d} matches\n", .{matches});
                            defer allocator.free(summary);
                            _ = try stdout.write(summary);
                        },
                        .none => {
                            _ = try pty_handle.write(&[_]u8{byte});
                        },
                    }
                }
            }
        }

        if (poll_fds[1].revents & std.posix.POLL.IN != 0) {
            const bytes_read = try pty_handle.read(&buffer);
            if (bytes_read > 0) {
                const parsed = try parser.parse(buffer[0..bytes_read]);
                defer allocator.free(parsed.cleaned);
                defer allocator.free(parsed.events);

                if (parsed.cleaned.len > 0) {
                    _ = try stdout.write(parsed.cleaned);
                    try manager.appendOutput(parsed.cleaned);
                }

                for (parsed.events) |event| {
                    switch (event.kind) {
                        .prompt_start => {
                            try manager.startBlock();
                        },
                        .command_end => {
                            manager.finishBlock(event.exit_code);
                            if (manager.latest()) |block| {
                                const decoration = try decorator.render(block, 60);
                                defer allocator.free(decoration);
                                _ = try stdout.write(decoration);
                            }
                        },
                    }
                }
            }
        }

        if (poll_fds[1].revents & (std.posix.POLL.ERR | std.posix.POLL.HUP) != 0) {
            break;
        }
    }
}

fn enableRawMode(fd: std.posix.fd_t) !std.posix.termios {
    var termios = try std.posix.tcgetattr(fd);
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
    termios.cc[@intFromEnum(std.posix.V.MIN)] = 0;
    termios.cc[@intFromEnum(std.posix.V.TIME)] = 1;

    try std.posix.tcsetattr(fd, .FLUSH, termios);
    return orig;
}

fn disableRawMode(fd: std.posix.fd_t, orig: std.posix.termios) !void {
    try std.posix.tcsetattr(fd, .FLUSH, orig);
}
