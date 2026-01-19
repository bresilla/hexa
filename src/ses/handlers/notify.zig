const std = @import("std");
const core = @import("core");
const ipc = core.ipc;
const state = @import("../state.zig");

/// Handle broadcast_notify request
pub fn handleBroadcastNotify(
    ses_state: *state.SesState,
    conn: *ipc.Connection,
    root: std.json.ObjectMap,
    sendError: *const fn (*ipc.Connection, []const u8) anyerror!void,
) !void {
    const message = (root.get("message") orelse return sendError(conn, "missing_message")).string;

    // Build notification message
    var msg_buf: [4096]u8 = undefined;
    const notify_msg = std.fmt.bufPrint(&msg_buf, "{{\"type\":\"notification\",\"message\":\"{s}\"}}\n", .{message}) catch {
        return sendError(conn, "message_too_long");
    };

    // Send to all connected clients (except the one sending the command)
    var sent_count: usize = 0;
    for (ses_state.clients.items) |client| {
        if (client.fd == conn.fd) continue; // Skip sender
        var client_conn = ipc.Connection{ .fd = client.fd };
        client_conn.send(notify_msg) catch continue;
        sent_count += 1;
    }

    // Respond with OK
    var resp_buf: [64]u8 = undefined;
    const resp = std.fmt.bufPrint(&resp_buf, "{{\"type\":\"ok\",\"sent_to\":{d}}}\n", .{sent_count}) catch return;
    try conn.send(resp);
}

/// Handle targeted_notify request
pub fn handleTargetedNotify(
    ses_state: *state.SesState,
    conn: *ipc.Connection,
    root: std.json.ObjectMap,
    sendError: *const fn (*ipc.Connection, []const u8) anyerror!void,
) !void {
    const message = (root.get("message") orelse return sendError(conn, "missing_message")).string;
    const uuid_str = (root.get("uuid") orelse return sendError(conn, "missing_uuid")).string;
    const timeout_ms: ?i64 = if (root.get("timeout_ms")) |v| switch (v) {
        .integer => |i| i,
        else => null,
    } else null;

    // Try to find mux by session_id first
    var found_mux: ?*state.Client = null;

    // Full 32-char match for mux session_id
    if (uuid_str.len == 32) {
        var session_id: [16]u8 = undefined;
        if (std.fmt.hexToBytes(&session_id, uuid_str)) |_| {
            for (ses_state.clients.items) |*client| {
                if (client.session_id) |sid| {
                    if (std.mem.eql(u8, &sid, &session_id)) {
                        found_mux = client;
                        break;
                    }
                }
            }
        } else |_| {}
    }

    // Partial prefix match for mux session_id (e.g., 8-char prefix from --list)
    if (found_mux == null and uuid_str.len >= 4 and uuid_str.len < 32) {
        for (ses_state.clients.items) |*client| {
            if (client.session_id) |sid| {
                const hex_buf: [32]u8 = std.fmt.bytesToHex(&sid, .lower);
                if (std.mem.startsWith(u8, &hex_buf, uuid_str)) {
                    found_mux = client;
                    break;
                }
            }
        }
    }

    if (found_mux) |client| {
        // MUX realm - send notification to this mux (shows at top)
        var msg_buf: [4096]u8 = undefined;
        const notify_msg = if (timeout_ms) |t|
            std.fmt.bufPrint(&msg_buf, "{{\"type\":\"notification\",\"message\":\"{s}\",\"timeout_ms\":{d}}}\n", .{ message, t }) catch {
                return sendError(conn, "message_too_long");
            }
        else
            std.fmt.bufPrint(&msg_buf, "{{\"type\":\"notification\",\"message\":\"{s}\"}}\n", .{message}) catch {
                return sendError(conn, "message_too_long");
            };
        var client_conn = ipc.Connection{ .fd = client.fd };
        client_conn.send(notify_msg) catch {
            return sendError(conn, "send_failed");
        };
        try conn.sendLine("{\"type\":\"ok\",\"realm\":\"mux\"}");
        return;
    }

    // Check for pane UUID - full 32-char match first
    if (uuid_str.len == 32) {
        var pane_uuid: [32]u8 = undefined;
        @memcpy(&pane_uuid, uuid_str[0..32]);

        if (ses_state.panes.get(pane_uuid)) |pane| {
            for (ses_state.clients.items) |*client| {
                for (client.pane_uuids.items) |client_pane_uuid| {
                    if (std.mem.eql(u8, &client_pane_uuid, &pane_uuid)) {
                        var msg_buf: [4096]u8 = undefined;
                        const notify_msg = if (timeout_ms) |t|
                            std.fmt.bufPrint(&msg_buf, "{{\"type\":\"pane_notification\",\"uuid\":\"{s}\",\"message\":\"{s}\",\"timeout_ms\":{d}}}\n", .{ pane_uuid, message, t }) catch {
                                return sendError(conn, "message_too_long");
                            }
                        else
                            std.fmt.bufPrint(&msg_buf, "{{\"type\":\"pane_notification\",\"uuid\":\"{s}\",\"message\":\"{s}\"}}\n", .{ pane_uuid, message }) catch {
                                return sendError(conn, "message_too_long");
                            };
                        var client_conn = ipc.Connection{ .fd = client.fd };
                        client_conn.send(notify_msg) catch {
                            return sendError(conn, "send_failed");
                        };
                        try conn.sendLine("{\"type\":\"ok\",\"realm\":\"pane\"}");
                        return;
                    }
                }
            }
            _ = pane;
            return sendError(conn, "pane_not_attached");
        }
    }

    // Partial prefix match for pane UUID (e.g., 8-char prefix from --list)
    if (uuid_str.len >= 4 and uuid_str.len < 32) {
        for (ses_state.clients.items) |*client| {
            for (client.pane_uuids.items) |pane_uuid| {
                if (std.mem.startsWith(u8, &pane_uuid, uuid_str)) {
                    var msg_buf: [4096]u8 = undefined;
                    const notify_msg = if (timeout_ms) |t|
                        std.fmt.bufPrint(&msg_buf, "{{\"type\":\"pane_notification\",\"uuid\":\"{s}\",\"message\":\"{s}\",\"timeout_ms\":{d}}}\n", .{ pane_uuid, message, t }) catch {
                            return sendError(conn, "message_too_long");
                        }
                    else
                        std.fmt.bufPrint(&msg_buf, "{{\"type\":\"pane_notification\",\"uuid\":\"{s}\",\"message\":\"{s}\"}}\n", .{ pane_uuid, message }) catch {
                            return sendError(conn, "message_too_long");
                        };
                    var client_conn = ipc.Connection{ .fd = client.fd };
                    client_conn.send(notify_msg) catch {
                        return sendError(conn, "send_failed");
                    };
                    try conn.sendLine("{\"type\":\"ok\",\"realm\":\"pane\"}");
                    return;
                }
            }
        }
    }

    // Try as TAB notification - broadcast to all muxes, let them check if they own the tab
    // Tab UUIDs are typically 8-char prefixes in output
    if (uuid_str.len >= 4) {
        var msg_buf: [4096]u8 = undefined;
        const notify_msg = if (timeout_ms) |t|
            std.fmt.bufPrint(&msg_buf, "{{\"type\":\"tab_notification\",\"uuid\":\"{s}\",\"message\":\"{s}\",\"timeout_ms\":{d}}}\n", .{ uuid_str, message, t }) catch {
                return sendError(conn, "message_too_long");
            }
        else
            std.fmt.bufPrint(&msg_buf, "{{\"type\":\"tab_notification\",\"uuid\":\"{s}\",\"message\":\"{s}\"}}\n", .{ uuid_str, message }) catch {
                return sendError(conn, "message_too_long");
            };

        var sent = false;
        for (ses_state.clients.items) |*client| {
            var client_conn = ipc.Connection{ .fd = client.fd };
            client_conn.send(notify_msg) catch continue;
            sent = true;
        }

        if (sent) {
            try conn.sendLine("{\"type\":\"ok\",\"realm\":\"tab\"}");
            return;
        }
    }

    // UUID not found
    try conn.sendLine("{\"type\":\"not_found\"}");
}

/// Handle status request
pub fn handleStatus(
    allocator: std.mem.Allocator,
    ses_state: *state.SesState,
    conn: *ipc.Connection,
    root: std.json.ObjectMap,
    sendError: *const fn (*ipc.Connection, []const u8) anyerror!void,
) !void {
    // Check if full mode is requested
    const full_mode = if (root.get("full")) |f| f.bool else false;

    // Use dynamic allocation for large responses in full mode
    const buf_size: usize = if (full_mode) 131072 else 32768;
    const json_buf = allocator.alloc(u8, buf_size) catch {
        return sendError(conn, "alloc_failed");
    };
    defer allocator.free(json_buf);

    var stream = std.io.fixedBufferStream(json_buf);
    var writer = stream.writer();

    try writer.writeAll("{\"type\":\"status\",\"clients\":[");

    // Iterate over clients (connected muxes)
    for (ses_state.clients.items, 0..) |client, ci| {
        if (ci > 0) try writer.writeAll(",");

        // Include session_id and session_name
        const sess_name = client.session_name orelse "unknown";
        if (client.session_id) |sid| {
            const hex_id: [32]u8 = std.fmt.bytesToHex(&sid, .lower);
            try writer.print("{{\"id\":{d},\"session_id\":\"{s}\",\"session_name\":\"{s}\",\"panes\":[", .{ client.id, &hex_id, sess_name });
        } else {
            try writer.print("{{\"id\":{d},\"session_name\":\"{s}\",\"panes\":[", .{ client.id, sess_name });
        }

        // List panes for this client
        var first_pane = true;
        for (client.pane_uuids.items) |uuid| {
            if (ses_state.panes.get(uuid)) |pane| {
                if (!first_pane) try writer.writeAll(",");
                first_pane = false;
                try writer.print("{{\"uuid\":\"{s}\",\"pid\":{d}", .{
                    uuid,
                    pane.child_pid,
                });
                if (pane.sticky_pwd) |pwd| {
                    try writer.print(",\"sticky_pwd\":\"{s}\"", .{pwd});
                }
                try writer.writeAll("}");
            }
        }
        try writer.writeAll("]");

        // Include mux_state if full mode and available
        if (full_mode) {
            if (client.last_mux_state) |mux_state| {
                try writer.writeAll(",\"mux_state\":\"");
                // Escape the mux state JSON string
                for (mux_state) |c| {
                    switch (c) {
                        '"' => try writer.writeAll("\\\""),
                        '\\' => try writer.writeAll("\\\\"),
                        '\n' => try writer.writeAll("\\n"),
                        '\r' => try writer.writeAll("\\r"),
                        '\t' => try writer.writeAll("\\t"),
                        else => try writer.writeByte(c),
                    }
                }
                try writer.writeAll("\"");
            }
        }
        try writer.writeAll("}");
    }

    // Detached sessions
    try writer.writeAll("],\"detached_sessions\":[");
    var sess_iter = ses_state.detached_sessions.iterator();
    var first_sess = true;
    while (sess_iter.next()) |entry| {
        if (!first_sess) try writer.writeAll(",");
        first_sess = false;
        const hex_id: [32]u8 = std.fmt.bytesToHex(&entry.key_ptr.*, .lower);
        const detached = entry.value_ptr;
        try writer.print("{{\"session_id\":\"{s}\",\"session_name\":\"{s}\",\"pane_count\":{d}", .{
            &hex_id,
            detached.session_name,
            detached.pane_uuids.len,
        });

        // Include mux_state if full mode
        if (full_mode) {
            try writer.writeAll(",\"mux_state\":\"");
            // Escape the mux state JSON string
            for (detached.mux_state_json) |c| {
                switch (c) {
                    '"' => try writer.writeAll("\\\""),
                    '\\' => try writer.writeAll("\\\\"),
                    '\n' => try writer.writeAll("\\n"),
                    '\r' => try writer.writeAll("\\r"),
                    '\t' => try writer.writeAll("\\t"),
                    else => try writer.writeByte(c),
                }
            }
            try writer.writeAll("\"");
        }
        try writer.writeAll("}");
    }

    // Orphaned panes (truly orphaned, not part of session)
    try writer.writeAll("],\"orphaned\":[");
    var first_orphan = true;
    var pane_iter = ses_state.panes.iterator();
    while (pane_iter.next()) |entry| {
        const pane = entry.value_ptr;
        if (pane.state == .orphaned) {
            if (!first_orphan) try writer.writeAll(",");
            first_orphan = false;
            try writer.print("{{\"uuid\":\"{s}\",\"pid\":{d}}}", .{
                entry.key_ptr.*,
                pane.child_pid,
            });
        }
    }

    // Sticky panes (waiting for same pwd+key)
    try writer.writeAll("],\"sticky\":[");
    var first_sticky = true;
    pane_iter = ses_state.panes.iterator();
    while (pane_iter.next()) |entry| {
        const pane = entry.value_ptr;
        if (pane.state == .sticky) {
            if (!first_sticky) try writer.writeAll(",");
            first_sticky = false;
            try writer.print("{{\"uuid\":\"{s}\",\"pid\":{d}", .{
                entry.key_ptr.*,
                pane.child_pid,
            });
            if (pane.sticky_pwd) |pwd| {
                try writer.print(",\"pwd\":\"{s}\"", .{pwd});
            }
            if (pane.sticky_key) |key| {
                try writer.print(",\"key\":\"{c}\"", .{key});
            }
            try writer.writeAll("}");
        }
    }

    try writer.writeAll("]}\n");
    try conn.send(stream.getWritten());
}
