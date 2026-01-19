const std = @import("std");
const core = @import("core");
const ipc = core.ipc;
const state = @import("../state.zig");

/// Handle register request
pub fn handleRegister(
    ses_state: *state.SesState,
    conn: *ipc.Connection,
    client_id: usize,
    root: std.json.ObjectMap,
    sendError: *const fn (*ipc.Connection, []const u8) anyerror!void,
) !void {
    // Get keepalive preference (default true)
    const keepalive = if (root.get("keepalive")) |k| k.bool else true;

    // Get session_id (mux's UUID)
    const session_id_hex = (root.get("session_id") orelse return sendError(conn, "missing_session_id")).string;
    if (session_id_hex.len != 32) {
        return sendError(conn, "invalid_session_id");
    }

    var session_id: [16]u8 = undefined;
    _ = std.fmt.hexToBytes(&session_id, session_id_hex) catch {
        return sendError(conn, "invalid_session_id");
    };

    // Get session_name (Pokemon name)
    const session_name = if (root.get("session_name")) |n| n.string else "unknown";

    // Update client settings
    if (ses_state.getClient(client_id)) |client| {
        client.keepalive = keepalive;
        client.session_id = session_id;
        // Free old name if exists and store new one
        if (client.session_name) |old| {
            client.allocator.free(old);
        }
        client.session_name = client.allocator.dupe(u8, session_name) catch null;
    }

    try conn.sendLine("{\"type\":\"registered\"}");
}

/// Handle sync_state request
pub fn handleSyncState(
    ses_state: *state.SesState,
    conn: *ipc.Connection,
    client_id: usize,
    root: std.json.ObjectMap,
    sendError: *const fn (*ipc.Connection, []const u8) anyerror!void,
) !void {
    const mux_state = (root.get("mux_state") orelse return sendError(conn, "missing_mux_state")).string;

    // Update client's stored state
    if (ses_state.getClient(client_id)) |client| {
        client.updateMuxState(mux_state) catch {
            return sendError(conn, "state_update_failed");
        };
    }

    try conn.sendLine("{\"type\":\"state_synced\"}");
}

/// Handle detach_session request
pub fn handleDetachSession(
    allocator: std.mem.Allocator,
    ses_state: *state.SesState,
    conn: *ipc.Connection,
    client_id: usize,
    root: std.json.ObjectMap,
    sendError: *const fn (*ipc.Connection, []const u8) anyerror!void,
) !void {
    _ = allocator;
    // Get the session_id (mux UUID) and mux state JSON from the message
    const session_id_hex = (root.get("session_id") orelse return sendError(conn, "missing_session_id")).string;
    const mux_state = (root.get("mux_state") orelse return sendError(conn, "missing_mux_state")).string;

    // Convert 32-char hex to 16 bytes
    if (session_id_hex.len != 32) {
        return sendError(conn, "invalid_session_id");
    }
    var session_id: [16]u8 = undefined;
    _ = std.fmt.hexToBytes(&session_id, session_id_hex) catch {
        return sendError(conn, "invalid_session_id");
    };

    // Get session_name from client
    const session_name = if (ses_state.getClient(client_id)) |client|
        client.session_name orelse "unknown"
    else
        "unknown";

    if (ses_state.detachSession(client_id, session_id, session_name, mux_state)) {
        var buf: [128]u8 = undefined;
        const response = try std.fmt.bufPrint(&buf, "{{\"type\":\"session_detached\",\"session_id\":\"{s}\"}}\n", .{
            session_id_hex,
        });
        try conn.send(response);
    } else {
        try sendError(conn, "client_not_found");
    }
}

/// Handle reattach request
pub fn handleReattach(
    allocator: std.mem.Allocator,
    ses_state: *state.SesState,
    conn: *ipc.Connection,
    client_id: usize,
    root: std.json.ObjectMap,
    sendError: *const fn (*ipc.Connection, []const u8) anyerror!void,
) !void {
    const session_id_prefix = (root.get("session_id") orelse return sendError(conn, "missing_session_id")).string;
    if (session_id_prefix.len < 1 or session_id_prefix.len > 32) return sendError(conn, "invalid_session_id");

    // Find session by UUID prefix OR by session name match
    var matched_session_id: ?[16]u8 = null;
    var match_count: usize = 0;

    var iter = ses_state.detached_sessions.iterator();
    while (iter.next()) |entry| {
        const key_ptr = entry.key_ptr;
        const detached = entry.value_ptr;
        const hex_id: [32]u8 = std.fmt.bytesToHex(key_ptr, .lower);

        // Match by UUID prefix
        if (std.mem.startsWith(u8, &hex_id, session_id_prefix)) {
            matched_session_id = key_ptr.*;
            match_count += 1;
        }
        // Match by session name (case insensitive)
        else if (std.ascii.eqlIgnoreCase(detached.session_name, session_id_prefix)) {
            matched_session_id = key_ptr.*;
            match_count += 1;
        }
        // Partial name match (starts with)
        else if (session_id_prefix.len >= 3 and detached.session_name.len >= session_id_prefix.len) {
            var match = true;
            for (session_id_prefix, 0..) |c, i| {
                if (std.ascii.toLower(c) != std.ascii.toLower(detached.session_name[i])) {
                    match = false;
                    break;
                }
            }
            if (match) {
                matched_session_id = key_ptr.*;
                match_count += 1;
            }
        }
    }

    if (match_count == 0) {
        return sendError(conn, "session_not_found");
    }
    if (match_count > 1) {
        return sendError(conn, "ambiguous_session_id");
    }

    const session_id = matched_session_id.?;

    const result = ses_state.reattachSession(session_id, client_id) catch {
        return sendError(conn, "reattach_failed");
    };

    if (result == null) {
        return sendError(conn, "session_not_found");
    }

    const reattach_result = result.?;
    defer {
        allocator.free(reattach_result.mux_state_json);
        allocator.free(reattach_result.pane_uuids);
    }

    // Send response with mux state and pane UUIDs
    // Use dynamic allocation for large mux states
    // mux_state needs to be escaped since it's a JSON string containing JSON
    const estimated_size = reattach_result.mux_state_json.len * 2 + 1024;
    const json_buf = allocator.alloc(u8, estimated_size) catch {
        return sendError(conn, "alloc_failed");
    };
    defer allocator.free(json_buf);

    var stream = std.io.fixedBufferStream(json_buf);
    var writer = stream.writer();

    try writer.writeAll("{\"type\":\"session_reattached\",\"mux_state\":\"");
    // Escape the mux state JSON string (escape quotes and backslashes)
    for (reattach_result.mux_state_json) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => try writer.writeByte(c),
        }
    }
    try writer.writeAll("\",\"panes\":[");

    for (reattach_result.pane_uuids, 0..) |uuid, i| {
        if (i > 0) try writer.writeAll(",");
        try writer.print("\"{s}\"", .{uuid});
    }

    try writer.print("],\"count\":{d}}}\n", .{reattach_result.pane_uuids.len});
    try conn.send(stream.getWritten());
}

/// Handle list_sessions request
pub fn handleListSessions(
    allocator: std.mem.Allocator,
    ses_state: *state.SesState,
    conn: *ipc.Connection,
    sendError: *const fn (*ipc.Connection, []const u8) anyerror!void,
) !void {
    const sessions = ses_state.listDetachedSessions(allocator) catch {
        return sendError(conn, "list_failed");
    };
    defer allocator.free(sessions);

    var json_buf: [4096]u8 = undefined;
    var stream = std.io.fixedBufferStream(&json_buf);
    var writer = stream.writer();

    try writer.writeAll("{\"type\":\"sessions\",\"sessions\":[");

    for (sessions, 0..) |s, i| {
        if (i > 0) try writer.writeAll(",");
        const hex_id: [32]u8 = std.fmt.bytesToHex(&s.session_id, .lower);
        try writer.print("{{\"session_id\":\"{s}\",\"session_name\":\"{s}\",\"pane_count\":{d}}}", .{
            &hex_id,
            s.session_name,
            s.pane_count,
        });
    }

    try writer.writeAll("]}\n");
    try conn.send(stream.getWritten());
}
