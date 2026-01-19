const std = @import("std");
const argonaut = @import("argonaut");
const core = @import("core");
const ipc = core.ipc;
const mux = @import("mux");
const ses = @import("ses");
const pop = @import("pop");

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

    const com_info = try com_cmd.newCommand("info", "Show current pane info");

    const com_notify = try com_cmd.newCommand("notify", "Send notification");
    const com_notify_uuid = try com_notify.string("u", "uuid", null);
    const com_notify_broadcast = try com_notify.flag("b", "broadcast", null);
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
    const pop_prompt_shell = try pop_prompt.string("S", "shell", null);
    const pop_prompt_jobs = try pop_prompt.int("j", "jobs", null);

    const pop_init = try pop_cmd.newCommand("init", "Print shell initialization script");
    const pop_init_shell = try pop_init.stringPositional(null);

    // Check for help flag manually to avoid argonaut segfault
    var has_help = false;
    var found_com = false;
    var found_ses = false;
    var found_mux = false;
    var found_pop = false;
    var found_list = false;
    var found_notify = false;
    var found_daemon = false;
    var found_info = false;
    var found_new = false;
    var found_attach = false;
    var found_prompt = false;
    var found_init = false;

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) has_help = true;
        if (std.mem.eql(u8, arg, "com")) found_com = true;
        if (std.mem.eql(u8, arg, "ses")) found_ses = true;
        if (std.mem.eql(u8, arg, "mux")) found_mux = true;
        if (std.mem.eql(u8, arg, "pop")) found_pop = true;
        if (std.mem.eql(u8, arg, "list")) found_list = true;
        if (std.mem.eql(u8, arg, "info")) found_info = true;
        if (std.mem.eql(u8, arg, "notify")) found_notify = true;
        if (std.mem.eql(u8, arg, "daemon")) found_daemon = true;
        if (std.mem.eql(u8, arg, "info")) found_info = true;
        if (std.mem.eql(u8, arg, "new")) found_new = true;
        if (std.mem.eql(u8, arg, "attach")) found_attach = true;
        if (std.mem.eql(u8, arg, "prompt")) found_prompt = true;
        if (std.mem.eql(u8, arg, "init")) found_init = true;
    }

    if (has_help) {
        // Show help for the most specific command found (manual strings to avoid argonaut crash)
        if (found_com and found_notify) {
            print("Usage: hexa com notify [OPTIONS] <message>\n\nSend notification (defaults to current pane if inside mux)\n\nOptions:\n  -u, --uuid <UUID>  Target specific mux or pane\n  -b, --broadcast    Broadcast to all muxes\n", .{});
        } else if (found_com and found_info) {
            print("Usage: hexa com info\n\nShow information about current pane (only works inside mux)\n", .{});
        } else if (found_com and found_list) {
            print("Usage: hexa com list [OPTIONS]\n\nList all sessions and panes\n\nOptions:\n  -d, --details  Show extra details\n", .{});
        } else if (found_ses and found_daemon) {
            print("Usage: hexa ses daemon\n\nStart the session daemon\n", .{});
        } else if (found_ses and found_info) {
            print("Usage: hexa ses info\n\nShow daemon status and socket path\n", .{});
        } else if (found_mux and found_new) {
            print("Usage: hexa mux new [OPTIONS]\n\nCreate new multiplexer session\n\nOptions:\n  -n, --name <NAME>  Session name\n", .{});
        } else if (found_mux and found_attach) {
            print("Usage: hexa mux attach <name>\n\nAttach to existing session by name or UUID prefix\n", .{});
        } else if (found_pop and found_prompt) {
            print("Usage: hexa pop prompt [OPTIONS]\n\nRender shell prompt\n\nOptions:\n  -s, --status <N>    Exit status of last command\n  -d, --duration <N>  Duration of last command in ms\n  -r, --right         Render right prompt\n  -S, --shell <SHELL> Shell type (bash, zsh, fish)\n  -j, --jobs <N>      Number of background jobs\n", .{});
        } else if (found_pop and found_init) {
            print("Usage: hexa pop init <shell>\n\nPrint shell initialization script\n\nSupported shells: bash, zsh, fish\n", .{});
        } else if (found_com) {
            print("Usage: hexa com <command>\n\nCommunication with sessions and panes\n\nCommands:\n  list    List all sessions and panes\n  info    Show current pane info\n  notify  Send notification\n", .{});
        } else if (found_ses) {
            print("Usage: hexa ses <command>\n\nSession daemon management\n\nCommands:\n  daemon  Start the session daemon\n  info    Show daemon info\n", .{});
        } else if (found_mux) {
            print("Usage: hexa mux <command>\n\nTerminal multiplexer\n\nCommands:\n  new     Create new multiplexer session\n  attach  Attach to existing session\n", .{});
        } else if (found_pop) {
            print("Usage: hexa pop <command>\n\nPrompt and status bar renderer\n\nCommands:\n  prompt  Render shell prompt\n  init    Print shell initialization script\n", .{});
        } else {
            print("Usage: hexa <command>\n\nHexa terminal multiplexer\n\nCommands:\n  com  Communication with sessions and panes\n  ses  Session daemon management\n  mux  Terminal multiplexer\n  pop  Prompt and status bar renderer\n", .{});
        }
        return;
    }

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
        } else if (com_info.happened) {
            try runComInfo(allocator);
        } else if (com_notify.happened) {
            try runComNotify(allocator, com_notify_uuid.*, com_notify_broadcast.*, com_notify_msg.*);
        }
    } else if (ses_cmd.happened) {
        // Check which ses subcommand
        for (ses_cmd.commands.items) |cmd| {
            if (cmd.happened) {
                if (std.mem.eql(u8, cmd.name, "daemon")) {
                    try runSesDaemon();
                } else if (std.mem.eql(u8, cmd.name, "info")) {
                    try runSesInfo(allocator);
                }
                return;
            }
        }
    } else if (mux_cmd.happened) {
        if (mux_new.happened) {
            try runMuxNew(mux_new_name.*);
        } else if (mux_attach.happened) {
            try runMuxAttach(mux_attach_name.*);
        }
    } else if (pop_cmd.happened) {
        if (pop_prompt.happened) {
            try runPopPrompt(pop_prompt_status.*, pop_prompt_duration.*, pop_prompt_right.*, pop_prompt_shell.*, pop_prompt_jobs.*);
        } else if (pop_init.happened) {
            try runPopInit(pop_init_shell.*);
        }
    }
}

// ============================================================================
// COM handlers
// ============================================================================

fn runComList(allocator: std.mem.Allocator, details: bool) !void {
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
    // Only request full mode (with mux_state) if details flag is set
    if (details) {
        try conn.sendLine("{\"type\":\"status\",\"full\":true}");
    } else {
        try conn.sendLine("{\"type\":\"status\"}");
    }

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

fn runComInfo(allocator: std.mem.Allocator) !void {
    // Get pane UUID from environment
    const pane_uuid = std.posix.getenv("HEXA_PANE_UUID");
    const mux_socket = std.posix.getenv("HEXA_MUX_SOCKET");

    if (pane_uuid == null and mux_socket == null) {
        print("Not inside a hexa mux session\n", .{});
        return;
    }

    print("Pane Info:\n", .{});
    if (pane_uuid) |uuid| {
        print("  UUID: {s}\n", .{uuid});
    }
    if (mux_socket) |socket| {
        print("  Mux socket: {s}\n", .{socket});
    }

    // Query ses daemon for more info about this pane
    if (pane_uuid) |uuid| {
        const socket_path = try ipc.getSesSocketPath(allocator);
        defer allocator.free(socket_path);

        var client = ipc.Client.connect(socket_path) catch |err| {
            if (err == error.ConnectionRefused or err == error.FileNotFound) {
                print("  (ses daemon not running)\n", .{});
                return;
            }
            return err;
        };
        defer client.close();

        var conn = client.toConnection();

        // Request pane info
        var buf: [256]u8 = undefined;
        const msg = try std.fmt.bufPrint(&buf, "{{\"type\":\"pane_info\",\"uuid\":\"{s}\"}}", .{uuid});
        try conn.sendLine(msg);

        var resp_buf: [4096]u8 = undefined;
        if (try conn.recvLine(&resp_buf)) |r| {
            const parsed = std.json.parseFromSlice(std.json.Value, allocator, r, .{}) catch return;
            defer parsed.deinit();

            const obj = parsed.value.object;

            if (obj.get("type")) |t| {
                if (std.mem.eql(u8, t.string, "error")) {
                    if (obj.get("message")) |m| {
                        print("  Error: {s}\n", .{m.string});
                    }
                    return;
                }
            }

            if (obj.get("pid")) |pid| {
                print("  PID: {d}\n", .{pid.integer});
            }
            if (obj.get("state")) |state| {
                print("  State: {s}\n", .{state.string});
            }
            // Auxiliary info (synced from mux)
            if (obj.get("pane_type")) |pt| {
                switch (pt) {
                    .string => |s| print("  Type: {s}\n", .{s}),
                    else => {},
                }
            }
            if (obj.get("is_focused")) |f| {
                switch (f) {
                    .bool => |b| print("  Focused: {s}\n", .{if (b) "yes" else "no"}),
                    else => {},
                }
            }
            if (obj.get("created_from")) |cf| {
                switch (cf) {
                    .string => |s| {
                        if (s.len >= 8) {
                            print("  Created from: {s}\n", .{s[0..8]});
                        }
                    },
                    else => {}, // null or other - don't print
                }
            }
            if (obj.get("focused_from")) |ff| {
                switch (ff) {
                    .string => |s| {
                        if (s.len >= 8) {
                            print("  Focused from: {s}\n", .{s[0..8]});
                        }
                    },
                    else => {}, // null or other - don't print
                }
            }
            if (obj.get("sticky_pwd")) |pwd| {
                print("  Sticky PWD: {s}\n", .{pwd.string});
            }
            if (obj.get("sticky_key")) |key| {
                print("  Sticky Key: {s}\n", .{key.string});
            }
            if (obj.get("session_name")) |name| {
                print("  Session: {s}\n", .{name.string});
            }
            if (obj.get("session_id")) |sid| {
                print("  Session ID: {s}\n", .{sid.string});
            }
            if (obj.get("created_at")) |ts| {
                print("  Created: {d}\n", .{ts.integer});
            }
            if (obj.get("orphaned_at")) |ts| {
                print("  Orphaned at: {d}\n", .{ts.integer});
            }
        }
    }
}

fn runComNotify(allocator: std.mem.Allocator, uuid: []const u8, broadcast: bool, message: []const u8) !void {
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

    // Determine target: explicit uuid > current pane > broadcast
    var target_uuid: ?[]const u8 = null;
    if (uuid.len > 0) {
        target_uuid = uuid;
    } else if (!broadcast) {
        // Check if we're inside a pane
        target_uuid = std.posix.getenv("HEXA_PANE_UUID");
    }

    if (target_uuid) |t| {
        const msg = try std.fmt.bufPrint(&buf, "{{\"type\":\"targeted_notify\",\"uuid\":\"{s}\",\"message\":\"{s}\"}}", .{ t, message });
        try conn.sendLine(msg);
    } else {
        const msg = try std.fmt.bufPrint(&buf, "{{\"type\":\"broadcast_notify\",\"message\":\"{s}\"}}", .{message});
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

fn runSesDaemon() !void {
    // Call ses run() directly
    try ses.run(.{ .daemon = true });
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

fn runMuxNew(name: []const u8) !void {
    // Call mux run() directly
    try mux.run(.{
        .name = if (name.len > 0) name else null,
    });
}

fn runMuxAttach(name: []const u8) !void {
    if (name.len > 0) {
        // Call mux run() directly with attach option
        try mux.run(.{
            .attach = name,
        });
    } else {
        print("Error: session name required\n", .{});
    }
}

// ============================================================================
// POP handlers
// ============================================================================

fn runPopPrompt(status: i64, duration: i64, right: bool, shell: []const u8, jobs: i64) !void {
    try pop.run(.{
        .prompt = true,
        .status = status,
        .duration = duration,
        .right = right,
        .shell = if (shell.len > 0) shell else null,
        .jobs = jobs,
    });
}

fn runPopInit(shell: []const u8) !void {
    if (shell.len > 0) {
        try pop.run(.{ .init_shell = shell });
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

    // Get floats array for tab-bound float lookup
    const floats_arr = if (root.get("floats")) |fv| fv.array.items else &[_]std.json.Value{};

    // Tabs
    if (root.get("tabs")) |tabs_val| {
        const tabs = tabs_val.array;
        const active = if (root.get("active_tab")) |at| @as(usize, @intCast(at.integer)) else 0;

        for (tabs.items, 0..) |tab_val, ti| {
            const tab = tab_val.object;
            const name = if (tab.get("name")) |n| n.string else "tab";
            const marker = if (ti == active) "*" else " ";
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

            // Print tab-bound floats for this tab
            for (floats_arr, 0..) |float_val, fi| {
                const float = float_val.object;
                if (float.get("parent_tab")) |pt| {
                    if (pt == .integer and @as(usize, @intCast(pt.integer)) == ti) {
                        const uuid = if (float.get("uuid")) |u| u.string else "?";
                        const visible = if (float.get("visible")) |v| v.bool else false;
                        const vm = if (visible) "*" else " ";
                        print("{s}  {s} Float {d} [{s}]\n", .{ indent, vm, fi, uuid[0..@min(8, uuid.len)] });
                    }
                }
            }
        }
    }

    // Global floats (no parent_tab)
    var has_global_floats = false;
    for (floats_arr) |float_val| {
        const float = float_val.object;
        if (float.get("parent_tab") == null) {
            has_global_floats = true;
            break;
        }
    }

    if (has_global_floats) {
        print("{s}Floats (global):\n", .{indent});
        for (floats_arr, 0..) |float_val, i| {
            const float = float_val.object;
            if (float.get("parent_tab") == null) {
                const uuid = if (float.get("uuid")) |u| u.string else "?";
                const visible = if (float.get("visible")) |v| v.bool else false;
                const vm = if (visible) "*" else " ";
                print("{s}  {s} Float {d} [{s}]\n", .{ indent, vm, i, uuid[0..@min(8, uuid.len)] });
            }
        }
    }
}
