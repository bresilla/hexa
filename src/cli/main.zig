const std = @import("std");
const argonaut = @import("argonaut");
const core = @import("core");
const ipc = core.ipc;

const print = std.debug.print;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    // Create main parser
    const parser = try argonaut.newParser(allocator, "hexa", "Hexa terminal multiplexer");
    defer parser.deinit();

    // Top-level subcommands only
    const com_cmd = try parser.newCommand("com", "Communication with sessions and panes");
    const ses_cmd = try parser.newCommand("ses", "Session daemon management");
    const mux_cmd = try parser.newCommand("mux", "Terminal multiplexer");
    const pop_cmd = try parser.newCommand("pop", "Prompt and status bar renderer");

    // COM subcommands
    const com_list = try com_cmd.newCommand("list", "List all sessions and panes");
    const com_list_details = try com_list.flag("d", "details", null);

    const com_notify = try com_cmd.newCommand("notify", "Send notification");
    const com_notify_uuid = try com_notify.string("u", "uuid", null);
    const com_notify_msg = try com_notify.stringPositional(null);

    // SES subcommands
    _ = try ses_cmd.newCommand("daemon", "Start the session daemon");
    _ = try ses_cmd.newCommand("info", "Show daemon info");

    // MUX subcommands
    const mux_new = try mux_cmd.newCommand("new", "Create new multiplexer session");
    const mux_new_name = try mux_new.string("n", "name", null);

    const mux_attach = try mux_cmd.newCommand("attach", "Attach to existing session");
    const mux_attach_name = try mux_attach.stringPositional(null);

    // POP subcommands
    const pop_prompt = try pop_cmd.newCommand("prompt", "Render shell prompt");
    const pop_prompt_status = try pop_prompt.int("s", "status", null);
    const pop_prompt_duration = try pop_prompt.int("d", "duration", null);
    const pop_prompt_right = try pop_prompt.flag("r", "right", null);

    const pop_init = try pop_cmd.newCommand("init", "Print shell initialization script");
    const pop_init_shell = try pop_init.stringPositional(null);

    // Parse
    parser.parse(args) catch |err| {
        if (err == error.HelpRequested) return;
        if (err == error.SubCommandRequired) {
            // Show help for the deepest command that happened
            if (pop_cmd.happened) {
                const help = try pop_cmd.usage(null);
                print("{s}\n", .{help});
            } else if (mux_cmd.happened) {
                const help = try mux_cmd.usage(null);
                print("{s}\n", .{help});
            } else if (ses_cmd.happened) {
                const help = try ses_cmd.usage(null);
                print("{s}\n", .{help});
            } else if (com_cmd.happened) {
                const help = try com_cmd.usage(null);
                print("{s}\n", .{help});
            } else {
                const help = try parser.usage(null);
                print("{s}\n", .{help});
            }
            return;
        }
        return err;
    };

    // Route to handlers
    if (com_cmd.happened) {
        if (com_list.happened) {
            try runComList(allocator, com_list_details.*);
        } else if (com_notify.happened) {
            try runComNotify(allocator, com_notify_uuid.*, com_notify_msg.*);
        }
    } else if (ses_cmd.happened) {
        // Check which ses subcommand
        for (ses_cmd.commands.items) |cmd| {
            if (cmd.happened) {
                if (std.mem.eql(u8, cmd.name, "daemon")) {
                    try runSesDaemon(allocator);
                } else if (std.mem.eql(u8, cmd.name, "info")) {
                    try runSesInfo(allocator);
                }
                return;
            }
        }
    } else if (mux_cmd.happened) {
        if (mux_new.happened) {
            try runMuxNew(allocator, mux_new_name.*);
        } else if (mux_attach.happened) {
            try runMuxAttach(allocator, mux_attach_name.*);
        }
    } else if (pop_cmd.happened) {
        if (pop_prompt.happened) {
            try runPopPrompt(allocator, pop_prompt_status.*, pop_prompt_duration.*, pop_prompt_right.*);
        } else if (pop_init.happened) {
            try runPopInit(allocator, pop_init_shell.*);
        }
    }
}

// ============================================================================
// COM handlers
// ============================================================================

fn runComList(allocator: std.mem.Allocator, details: bool) !void {
    _ = details;

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
    try conn.sendLine("{\"type\":\"status\",\"full\":true}");

    var buf: [65536]u8 = undefined;
    const line = try conn.recvLine(&buf);
    if (line == null) {
        print("No response from daemon\n", .{});
        return;
    }

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, line.?, .{}) catch {
        print("Invalid response from daemon\n", .{});
        return;
    };
    defer parsed.deinit();

    const root = parsed.value.object;

    // Connected muxes
    if (root.get("clients")) |clients_val| {
        const clients = clients_val.array;
        if (clients.items.len > 0) {
            print("Connected muxes: {d}\n", .{clients.items.len});
            for (clients.items) |client_val| {
                const c = client_val.object;
                const id = c.get("id").?.integer;
                const panes = c.get("panes").?.array;
                const name = if (c.get("session_name")) |n| n.string else "unknown";
                const sid = if (c.get("session_id")) |s| s.string else null;

                if (sid) |session_id| {
                    print("  {s} [{s}] (mux #{d}, {d} panes)\n", .{ name, session_id[0..8], id, panes.items.len });
                } else {
                    print("  {s} (mux #{d}, {d} panes)\n", .{ name, id, panes.items.len });
                }

                if (c.get("mux_state")) |mux_state_val| {
                    printMuxTree(allocator, mux_state_val.string, "    ");
                }
            }
        }
    }

    // Detached sessions
    if (root.get("detached_sessions")) |sessions_val| {
        const sessions = sessions_val.array;
        if (sessions.items.len > 0) {
            print("\nDetached sessions: {d}\n", .{sessions.items.len});
            for (sessions.items) |sess_val| {
                const s = sess_val.object;
                const sid = s.get("session_id").?.string;
                const pane_count = s.get("pane_count").?.integer;
                const name = if (s.get("session_name")) |n| n.string else "unknown";

                print("  {s} [{s}] {d} panes - reattach: hexa mux attach {s}\n", .{ name, sid[0..8], pane_count, name });

                if (s.get("mux_state")) |mux_state_val| {
                    printMuxTree(allocator, mux_state_val.string, "    ");
                }
            }
        }
    }

    // Orphaned panes
    if (root.get("orphaned")) |orphaned_val| {
        const orphaned = orphaned_val.array;
        if (orphaned.items.len > 0) {
            print("\nOrphaned panes: {d}\n", .{orphaned.items.len});
            for (orphaned.items) |pane_val| {
                const p = pane_val.object;
                const uuid = p.get("uuid").?.string;
                const pid = p.get("pid").?.integer;
                print("  [{s}] pid={d}\n", .{ uuid[0..8], pid });
            }
        }
    }
}

fn runComNotify(allocator: std.mem.Allocator, uuid: []const u8, message: []const u8) !void {
    if (message.len == 0) {
        print("Error: message is required\n", .{});
        return;
    }

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

    var buf: [4096]u8 = undefined;
    if (uuid.len > 0) {
        const msg = try std.fmt.bufPrint(&buf, "{{\"type\":\"targeted_notify\",\"uuid\":\"{s}\",\"message\":\"{s}\"}}", .{ uuid, message });
        try conn.sendLine(msg);
    } else {
        const msg = try std.fmt.bufPrint(&buf, "{{\"type\":\"notify\",\"message\":\"{s}\"}}", .{message});
        try conn.sendLine(msg);
    }

    var resp_buf: [1024]u8 = undefined;
    if (try conn.recvLine(&resp_buf)) |r| {
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, r, .{}) catch return;
        defer parsed.deinit();

        if (parsed.value.object.get("type")) |t| {
            if (std.mem.eql(u8, t.string, "not_found")) {
                print("Target UUID not found\n", .{});
            } else if (std.mem.eql(u8, t.string, "ok")) {
                if (parsed.value.object.get("realm")) |realm| {
                    print("Notification sent to {s}\n", .{realm.string});
                } else {
                    print("Notification sent\n", .{});
                }
            }
        }
    }
}

// ============================================================================
// SES handlers
// ============================================================================

fn runSesDaemon(allocator: std.mem.Allocator) !void {
    // Spawn hexa-ses daemon
    var child = std.process.Child.init(&.{"hexa-ses"}, allocator);
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    _ = try child.spawnAndWait();
}

fn runSesInfo(allocator: std.mem.Allocator) !void {
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

    print("ses daemon running at: {s}\n", .{socket_path});
}

// ============================================================================
// MUX handlers
// ============================================================================

fn runMuxNew(allocator: std.mem.Allocator, name: []const u8) !void {
    if (name.len > 0) {
        var child = std.process.Child.init(&.{ "hexa-mux", "--name", name }, allocator);
        child.stdin_behavior = .Inherit;
        child.stdout_behavior = .Inherit;
        child.stderr_behavior = .Inherit;
        _ = try child.spawnAndWait();
    } else {
        var child = std.process.Child.init(&.{"hexa-mux"}, allocator);
        child.stdin_behavior = .Inherit;
        child.stdout_behavior = .Inherit;
        child.stderr_behavior = .Inherit;
        _ = try child.spawnAndWait();
    }
}

fn runMuxAttach(allocator: std.mem.Allocator, name: []const u8) !void {
    if (name.len > 0) {
        var child = std.process.Child.init(&.{ "hexa-mux", "-a", name }, allocator);
        child.stdin_behavior = .Inherit;
        child.stdout_behavior = .Inherit;
        child.stderr_behavior = .Inherit;
        _ = try child.spawnAndWait();
    } else {
        print("Error: session name required\n", .{});
    }
}

// ============================================================================
// POP handlers
// ============================================================================

fn runPopPrompt(allocator: std.mem.Allocator, status: i64, duration: i64, right: bool) !void {
    var status_buf: [32]u8 = undefined;
    var duration_buf: [32]u8 = undefined;

    // Build args array
    var args: [6][]const u8 = undefined;
    var argc: usize = 0;

    args[argc] = "pop";
    argc += 1;
    args[argc] = "prompt";
    argc += 1;

    if (status != 0) {
        args[argc] = std.fmt.bufPrint(&status_buf, "--status={d}", .{status}) catch "--status=0";
        argc += 1;
    }
    if (duration != 0) {
        args[argc] = std.fmt.bufPrint(&duration_buf, "--duration={d}", .{duration}) catch "--duration=0";
        argc += 1;
    }
    if (right) {
        args[argc] = "--right";
        argc += 1;
    }

    var child = std.process.Child.init(args[0..argc], allocator);
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    _ = try child.spawnAndWait();
}

fn runPopInit(allocator: std.mem.Allocator, shell: []const u8) !void {
    if (shell.len > 0) {
        var child = std.process.Child.init(&.{ "pop", "init", shell }, allocator);
        child.stdin_behavior = .Inherit;
        child.stdout_behavior = .Inherit;
        child.stderr_behavior = .Inherit;
        _ = try child.spawnAndWait();
    } else {
        print("Error: shell name required (bash, zsh, fish)\n", .{});
    }
}

// ============================================================================
// Helpers
// ============================================================================

fn printMuxTree(allocator: std.mem.Allocator, json: []const u8, indent: []const u8) void {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json, .{}) catch return;
    defer parsed.deinit();

    const root = parsed.value.object;

    // Tabs
    if (root.get("tabs")) |tabs_val| {
        const tabs = tabs_val.array;
        const active = if (root.get("active_tab")) |at| @as(usize, @intCast(at.integer)) else 0;

        for (tabs.items, 0..) |tab_val, i| {
            const tab = tab_val.object;
            const name = if (tab.get("name")) |n| n.string else "tab";
            const marker = if (i == active) "*" else " ";
            print("{s}{s} Tab: {s}\n", .{ indent, marker, name });

            if (tab.get("panes")) |panes_val| {
                for (panes_val.array.items) |pane_val| {
                    const pane = pane_val.object;
                    const uuid = if (pane.get("uuid")) |u| u.string else "?";
                    const pid = if (pane.get("id")) |id| @as(i64, id.integer) else 0;
                    const focused = if (pane.get("focused")) |f| f.bool else false;
                    const fm = if (focused) ">" else " ";
                    print("{s}  {s} Pane {d} [{s}]\n", .{ indent, fm, pid, uuid[0..@min(8, uuid.len)] });
                }
            }
        }
    }

    // Floats
    if (root.get("floats")) |floats_val| {
        const floats = floats_val.array;
        if (floats.items.len > 0) {
            print("{s}Floats:\n", .{indent});
            for (floats.items, 0..) |float_val, i| {
                const float = float_val.object;
                const uuid = if (float.get("uuid")) |u| u.string else "?";
                const visible = if (float.get("visible")) |v| v.bool else false;
                const vm = if (visible) "*" else " ";
                print("{s}  {s} Float {d} [{s}]\n", .{ indent, vm, i, uuid[0..@min(8, uuid.len)] });
            }
        }
    }
}
