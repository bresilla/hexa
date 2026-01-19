const std = @import("std");
const posix = std.posix;
const core = @import("core");
const ipc = core.ipc;
const state = @import("../state.zig");

/// Handle pop_confirm request
pub fn handlePopConfirm(
    ses_state: *state.SesState,
    pending_pop_requests: *std.AutoHashMap(posix.fd_t, posix.fd_t),
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

    // Find target mux by session_id
    const found_mux = findMuxByUuid(ses_state, uuid_str) orelse {
        return sendError(conn, "mux_not_found");
    };

    // Send pop_confirm request to mux (include target_uuid for scope detection)
    var msg_buf: [4096]u8 = undefined;
    const pop_msg = if (timeout_ms) |t|
        std.fmt.bufPrint(&msg_buf, "{{\"type\":\"pop_confirm\",\"message\":\"{s}\",\"target_uuid\":\"{s}\",\"timeout_ms\":{d}}}\n", .{ message, uuid_str, t }) catch {
            return sendError(conn, "message_too_long");
        }
    else
        std.fmt.bufPrint(&msg_buf, "{{\"type\":\"pop_confirm\",\"message\":\"{s}\",\"target_uuid\":\"{s}\"}}\n", .{ message, uuid_str }) catch {
            return sendError(conn, "message_too_long");
        };
    var mux_conn = ipc.Connection{ .fd = found_mux.fd };
    mux_conn.send(pop_msg) catch {
        return sendError(conn, "send_failed");
    };

    // Store the pending request: mux_fd -> cli_fd
    // When mux sends pop_response, we'll forward it to this CLI connection
    try pending_pop_requests.put(found_mux.fd, conn.fd);
    // Don't send response yet - CLI will wait until mux sends pop_response
}

/// Handle pop_choose request
pub fn handlePopChoose(
    ses_state: *state.SesState,
    pending_pop_requests: *std.AutoHashMap(posix.fd_t, posix.fd_t),
    conn: *ipc.Connection,
    root: std.json.ObjectMap,
    sendError: *const fn (*ipc.Connection, []const u8) anyerror!void,
) !void {
    const message = (root.get("message") orelse return sendError(conn, "missing_message")).string;
    const uuid_str = (root.get("uuid") orelse return sendError(conn, "missing_uuid")).string;
    const items_val = root.get("items") orelse return sendError(conn, "missing_items");
    if (items_val != .array) return sendError(conn, "invalid_items");
    const timeout_ms: ?i64 = if (root.get("timeout_ms")) |v| switch (v) {
        .integer => |i| i,
        else => null,
    } else null;

    // Find target mux by session_id
    const found_mux = findMuxByUuid(ses_state, uuid_str) orelse {
        return sendError(conn, "mux_not_found");
    };

    // Build items JSON
    var items_buf: [4096]u8 = undefined;
    var items_len: usize = 0;
    items_buf[items_len] = '[';
    items_len += 1;

    for (items_val.array.items, 0..) |item, i| {
        if (i > 0) {
            items_buf[items_len] = ',';
            items_len += 1;
        }
        if (item == .string) {
            items_buf[items_len] = '"';
            items_len += 1;
            const str = item.string;
            if (items_len + str.len + 10 > items_buf.len) {
                return sendError(conn, "items_too_long");
            }
            @memcpy(items_buf[items_len..][0..str.len], str);
            items_len += str.len;
            items_buf[items_len] = '"';
            items_len += 1;
        }
    }
    items_buf[items_len] = ']';
    items_len += 1;

    // Send pop_choose request to mux
    var msg_buf: [8192]u8 = undefined;
    const pop_msg = if (timeout_ms) |t|
        std.fmt.bufPrint(&msg_buf, "{{\"type\":\"pop_choose\",\"message\":\"{s}\",\"items\":{s},\"timeout_ms\":{d}}}\n", .{ message, items_buf[0..items_len], t }) catch {
            return sendError(conn, "message_too_long");
        }
    else
        std.fmt.bufPrint(&msg_buf, "{{\"type\":\"pop_choose\",\"message\":\"{s}\",\"items\":{s}}}\n", .{ message, items_buf[0..items_len] }) catch {
            return sendError(conn, "message_too_long");
        };
    var mux_conn = ipc.Connection{ .fd = found_mux.fd };
    mux_conn.send(pop_msg) catch {
        return sendError(conn, "send_failed");
    };

    // Store the pending request
    try pending_pop_requests.put(found_mux.fd, conn.fd);
    // Don't send response yet - CLI will wait until mux sends pop_response
}

/// Handle pop_response from mux
pub fn handlePopResponse(
    pending_pop_requests: *std.AutoHashMap(posix.fd_t, posix.fd_t),
    conn: *ipc.Connection,
    root: std.json.ObjectMap,
) !void {
    // This is a response from a mux to a pending pop request
    // Find the CLI connection that's waiting for this response
    const cli_fd = pending_pop_requests.get(conn.fd) orelse {
        // No pending request from this mux - ignore
        return;
    };

    // Remove from pending
    _ = pending_pop_requests.remove(conn.fd);

    // Forward the response to the CLI
    var cli_conn = ipc.Connection{ .fd = cli_fd };

    // Build response JSON based on what's in root
    var resp_buf: [256]u8 = undefined;
    if (root.get("confirmed")) |confirmed_val| {
        const confirmed = confirmed_val.bool;
        const resp = std.fmt.bufPrint(&resp_buf, "{{\"type\":\"pop_response\",\"confirmed\":{}}}\n", .{confirmed}) catch return;
        cli_conn.send(resp) catch {};
    } else if (root.get("selected")) |selected_val| {
        const selected = selected_val.integer;
        const resp = std.fmt.bufPrint(&resp_buf, "{{\"type\":\"pop_response\",\"selected\":{d}}}\n", .{selected}) catch return;
        cli_conn.send(resp) catch {};
    } else if (root.get("cancelled")) |_| {
        const resp = std.fmt.bufPrint(&resp_buf, "{{\"type\":\"pop_response\",\"cancelled\":true}}\n", .{}) catch return;
        cli_conn.send(resp) catch {};
    }
}

/// Helper to find a mux client by UUID prefix (mux session_id or pane UUID)
pub fn findMuxByUuid(ses_state: *state.SesState, uuid_str: []const u8) ?*state.Client {
    // Full 32-char match for mux session_id
    if (uuid_str.len == 32) {
        var session_id: [16]u8 = undefined;
        if (std.fmt.hexToBytes(&session_id, uuid_str)) |_| {
            for (ses_state.clients.items) |*client| {
                if (client.session_id) |sid| {
                    if (std.mem.eql(u8, &sid, &session_id)) {
                        return client;
                    }
                }
            }
        } else |_| {}

        // Try as pane UUID - find the mux that owns this pane
        var pane_uuid: [32]u8 = undefined;
        @memcpy(&pane_uuid, uuid_str[0..32]);
        for (ses_state.clients.items) |*client| {
            for (client.pane_uuids.items) |client_pane_uuid| {
                if (std.mem.eql(u8, &client_pane_uuid, &pane_uuid)) {
                    return client;
                }
            }
        }
    }

    // Partial prefix match for mux session_id
    if (uuid_str.len >= 4 and uuid_str.len < 32) {
        for (ses_state.clients.items) |*client| {
            if (client.session_id) |sid| {
                const hex_buf: [32]u8 = std.fmt.bytesToHex(&sid, .lower);
                if (std.mem.startsWith(u8, &hex_buf, uuid_str)) {
                    return client;
                }
            }
        }

        // Try as pane UUID prefix
        for (ses_state.clients.items) |*client| {
            for (client.pane_uuids.items) |pane_uuid| {
                if (std.mem.startsWith(u8, &pane_uuid, uuid_str)) {
                    return client;
                }
            }
        }
    }

    // UUID not found - might be a tab UUID (mux-internal, not tracked by ses)
    // Return first available mux and let it check if UUID matches one of its tabs
    if (ses_state.clients.items.len > 0) {
        return &ses_state.clients.items[0];
    }

    return null;
}
