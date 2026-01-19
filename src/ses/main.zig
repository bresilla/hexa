const std = @import("std");
const posix = std.posix;
const core = @import("core");
const ipc = core.ipc;
const state = @import("state.zig");
const server = @import("server.zig");

pub fn main() !void {
    // Use page_allocator for arg parsing before fork (survives fork cleanly)
    const page_alloc = std.heap.page_allocator;

    const args = try std.process.argsAlloc(page_alloc);
    defer std.process.argsFree(page_alloc, args);

    // Check for command modes
    var daemon_mode = false;
    var list_mode = false;
    var notify_message: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--daemon") or std.mem.eql(u8, arg, "-d")) {
            daemon_mode = true;
        } else if (std.mem.eql(u8, arg, "--list") or std.mem.eql(u8, arg, "-l")) {
            list_mode = true;
        } else if (std.mem.eql(u8, arg, "--notify") or std.mem.eql(u8, arg, "-n")) {
            // Next arg is the message
            if (i + 1 < args.len) {
                i += 1;
                notify_message = args[i];
            } else {
                print("Error: --notify requires a message argument\n", .{});
                return;
            }
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try printUsage();
            return;
        }
    }

    // Notify mode - send notification to all connected muxes (use page_alloc, no fork)
    if (notify_message) |msg| {
        try sendNotify(page_alloc, msg);
        return;
    }

    // List mode - connect to running daemon and show status (use page_alloc, no fork)
    if (list_mode) {
        try listStatus(page_alloc);
        return;
    }

    // Daemonize BEFORE creating GPA
    if (daemon_mode) {
        try daemonize();
    }

    // Now create GPA AFTER fork - this ensures clean allocator state
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize state
    var ses_state = state.SesState.init(allocator);
    defer ses_state.deinit();

    // Initialize server
    var srv = server.Server.init(allocator, &ses_state) catch |err| {
        if (!daemon_mode) {
            std.debug.print("ses: server init failed: {}\n", .{err});
        }
        return err;
    };
    defer srv.deinit();

    // Set up signal handlers
    setupSignalHandlers(&srv);

    // Print socket path if not daemon
    if (!daemon_mode) {
        const socket_path = ipc.getSesSocketPath(allocator) catch "";
        defer if (socket_path.len > 0) allocator.free(socket_path);
        std.debug.print("ses: listening on {s}\n", .{socket_path});
    }

    // Run server
    srv.run() catch |err| {
        if (!daemon_mode) {
            std.debug.print("Server error: {}\n", .{err});
        }
        return err;
    };
}

fn print(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    _ = posix.write(posix.STDOUT_FILENO, msg) catch {};
}

fn printUsage() !void {
    print(
        \\hexa-ses - PTY session server
        \\
        \\Usage: hexa-ses [OPTIONS]
        \\
        \\Options:
        \\  -d, --daemon       Run as a background daemon
        \\  -l, --list         List connected muxes and their panes
        \\  -n, --notify MSG   Send notification to all connected muxes
        \\  -h, --help         Show this help message
        \\
        \\The ses server holds PTY file descriptors to keep processes alive
        \\when mux clients disconnect. It is automatically started by mux
        \\if not already running.
        \\
    , .{});
}

fn sendNotify(allocator: std.mem.Allocator, message: []const u8) !void {
    // Connect to running daemon
    const socket_path = try ipc.getSesSocketPath(allocator);
    defer allocator.free(socket_path);

    var client = ipc.Client.connect(socket_path) catch |err| {
        if (err == error.ConnectionRefused or err == error.FileNotFound) {
            print("ses daemon is not running\n", .{});
            return;
        }
        return err;
    };
    defer client.close();

    var conn = client.toConnection();

    // Send broadcast_notify request
    var buf: [4096]u8 = undefined;
    const request = std.fmt.bufPrint(&buf, "{{\"type\":\"broadcast_notify\",\"message\":\"{s}\"}}", .{message}) catch {
        print("Message too long\n", .{});
        return;
    };
    try conn.sendLine(request);

    // Receive response
    var resp_buf: [256]u8 = undefined;
    const line = try conn.recvLine(&resp_buf);
    if (line) |resp| {
        if (std.mem.indexOf(u8, resp, "\"ok\"") != null) {
            print("Notification sent\n", .{});
        } else {
            print("Failed to send notification\n", .{});
        }
    }
}

fn listStatus(allocator: std.mem.Allocator) !void {
    // Connect to running daemon
    const socket_path = try ipc.getSesSocketPath(allocator);
    defer allocator.free(socket_path);

    var client = ipc.Client.connect(socket_path) catch |err| {
        if (err == error.ConnectionRefused or err == error.FileNotFound) {
            print("ses daemon is not running\n", .{});
            return;
        }
        return err;
    };
    defer client.close();

    var conn = client.toConnection();

    // Send status request
    try conn.sendLine("{\"type\":\"status\"}");

    // Receive response
    var buf: [16384]u8 = undefined;
    const line = try conn.recvLine(&buf);
    if (line == null) {
        print("No response from daemon\n", .{});
        return;
    }

    // Parse and display
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, line.?, .{}) catch {
        print("Invalid response from daemon\n", .{});
        return;
    };
    defer parsed.deinit();

    const root = parsed.value.object;

    // Print clients (connected muxes)
    if (root.get("clients")) |clients_val| {
        const clients = clients_val.array;
        print("Connected muxes: {d}\n", .{clients.items.len});

        for (clients.items) |client_val| {
            const c = client_val.object;
            const id = c.get("id").?.integer;
            const panes = c.get("panes").?.array;

            print("  Mux #{d} ({d} panes)\n", .{ id, panes.items.len });

            for (panes.items) |pane_val| {
                const p = pane_val.object;
                const uuid = p.get("uuid").?.string;
                const pid = p.get("pid").?.integer;

                print("    [{s}] pid={d}", .{ uuid[0..8], pid });

                if (p.get("sticky_pwd")) |pwd| {
                    print(" pwd={s}", .{pwd.string});
                }
                print("\n", .{});
            }
        }
    }

    // Print detached sessions
    if (root.get("detached_sessions")) |sessions_val| {
        const sessions = sessions_val.array;
        if (sessions.items.len > 0) {
            print("\nDetached sessions: {d}\n", .{sessions.items.len});

            for (sessions.items) |sess_val| {
                const s = sess_val.object;
                const sid = s.get("session_id").?.string;
                const pane_count = s.get("pane_count").?.integer;

                print("  [{s}] {d} panes - reattach: hexa-mux -a {s}\n", .{ sid[0..8], pane_count, sid[0..8] });
            }
        }
    }

    // Print orphaned panes (disowned)
    if (root.get("orphaned")) |orphaned_val| {
        const orphaned = orphaned_val.array;
        if (orphaned.items.len > 0) {
            print("\nOrphaned panes (disowned): {d}\n", .{orphaned.items.len});

            for (orphaned.items) |pane_val| {
                const p = pane_val.object;
                const uuid = p.get("uuid").?.string;
                const pid = p.get("pid").?.integer;

                print("  [{s}] pid={d}\n", .{ uuid[0..8], pid });
            }
        }
    }

    // Print sticky panes
    if (root.get("sticky")) |sticky_val| {
        const sticky = sticky_val.array;
        if (sticky.items.len > 0) {
            print("\nSticky panes: {d}\n", .{sticky.items.len});

            for (sticky.items) |pane_val| {
                const p = pane_val.object;
                const uuid = p.get("uuid").?.string;
                const pid = p.get("pid").?.integer;

                print("  [{s}] pid={d}", .{ uuid[0..8], pid });

                if (p.get("pwd")) |pwd| {
                    print(" pwd={s}", .{pwd.string});
                }
                if (p.get("key")) |key| {
                    print(" key={s}", .{key.string});
                }
                print("\n", .{});
            }
        }
    }
}

fn daemonize() !void {
    // First fork
    const pid1 = try posix.fork();
    if (pid1 != 0) {
        // Parent exits
        posix.exit(0);
    }

    // Create new session
    _ = posix.setsid() catch {};

    // Second fork (prevent reacquiring terminal)
    const pid2 = try posix.fork();
    if (pid2 != 0) {
        // First child exits
        posix.exit(0);
    }

    // We are now the daemon process

    // Redirect stdin/stdout/stderr to /dev/null
    const devnull = posix.open("/dev/null", .{ .ACCMODE = .RDWR }, 0) catch return;
    posix.dup2(devnull, posix.STDIN_FILENO) catch {};
    posix.dup2(devnull, posix.STDOUT_FILENO) catch {};
    posix.dup2(devnull, posix.STDERR_FILENO) catch {};
    if (devnull > 2) {
        posix.close(devnull);
    }

    // Change to root directory
    std.posix.chdir("/") catch {};
}

var global_server: ?*server.Server = null;

fn setupSignalHandlers(srv: *server.Server) void {
    global_server = srv;

    // Ignore SIGPIPE - we handle closed connections gracefully
    const sigpipe_action = std.os.linux.Sigaction{
        .handler = .{ .handler = std.os.linux.SIG.IGN },
        .mask = std.os.linux.sigemptyset(),
        .flags = 0,
    };
    _ = std.os.linux.sigaction(posix.SIG.PIPE, &sigpipe_action, null);

    // Set up SIGTERM and SIGINT handlers
    const sigterm_action = std.os.linux.Sigaction{
        .handler = .{ .handler = signalHandler },
        .mask = std.os.linux.sigemptyset(),
        .flags = 0,
    };

    _ = std.os.linux.sigaction(posix.SIG.TERM, &sigterm_action, null);
    _ = std.os.linux.sigaction(posix.SIG.INT, &sigterm_action, null);
}

fn signalHandler(sig: c_int) callconv(.c) void {
    _ = sig;
    if (global_server) |srv| {
        srv.stop();
    }
}

// Module exports for use by mux
pub const SesState = state.SesState;
pub const Pane = state.Pane;
pub const PaneState = state.PaneState;
pub const Client = state.Client;
pub const Server = server.Server;
