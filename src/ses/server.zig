const std = @import("std");
const posix = std.posix;
const core = @import("core");
const ipc = core.ipc;
const state = @import("state.zig");

/// Message types from mux to ses
pub const RequestType = enum {
    create_pane,
    find_sticky,
    reconnect,
    disconnect,
    orphan_pane,
    list_orphaned,
    adopt_pane,
    kill_pane,
    ping,
};

/// Message types from ses to mux
pub const ResponseType = enum {
    pane_created,
    pane_found,
    pane_not_found,
    reconnected,
    pane_exited,
    orphaned_panes,
    ok,
    @"error",
    pong,
};

/// Server that handles mux connections
pub const Server = struct {
    allocator: std.mem.Allocator,
    socket: ipc.Server,
    ses_state: *state.SesState,
    running: bool,

    pub fn init(allocator: std.mem.Allocator, ses_state: *state.SesState) !Server {
        const socket_path = try ipc.getSesSocketPath(allocator);
        defer allocator.free(socket_path);

        const socket = try ipc.Server.init(allocator, socket_path);

        return Server{
            .allocator = allocator,
            .socket = socket,
            .ses_state = ses_state,
            .running = true,
        };
    }

    pub fn deinit(self: *Server) void {
        self.socket.deinit();
    }

    /// Main server loop - handles connections and messages
    pub fn run(self: *Server) !void {
        var poll_fds: std.ArrayList(posix.pollfd) = .empty;
        defer poll_fds.deinit(self.allocator);

        // Add server socket
        try poll_fds.append(self.allocator, .{
            .fd = self.socket.getFd(),
            .events = posix.POLL.IN,
            .revents = 0,
        });

        while (self.running) {
            // Reset revents
            for (poll_fds.items) |*pfd| {
                pfd.revents = 0;
            }

            // Poll with timeout for cleanup tasks
            const ready = posix.poll(poll_fds.items, 10000) catch |err| {
                if (err == error.Interrupted) continue;
                return err;
            };

            if (ready == 0) {
                // Timeout - do periodic cleanup
                self.ses_state.cleanupOrphanedPanes();
                continue;
            }

            // Check server socket for new connections
            if (poll_fds.items[0].revents & posix.POLL.IN != 0) {
                if (self.socket.tryAccept() catch null) |conn| {
                    // Don't add as client yet - wait until they create a pane
                    // This prevents --list and other queries from being counted as muxes
                    try poll_fds.append(self.allocator, .{
                        .fd = conn.fd,
                        .events = posix.POLL.IN,
                        .revents = 0,
                    });
                }
            }

            // Check client sockets
            var i: usize = 1;
            while (i < poll_fds.items.len) {
                const pfd = &poll_fds.items[i];

                if (pfd.revents & (posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR) != 0) {
                    var conn = ipc.Connection{ .fd = pfd.fd };

                    // Find client ID for this fd
                    var client_id: ?usize = null;
                    for (self.ses_state.clients.items) |client| {
                        if (client.fd == pfd.fd) {
                            client_id = client.id;
                            break;
                        }
                    }

                    if (pfd.revents & posix.POLL.IN != 0) {
                        // Try to read message (large buffer for mux state JSON)
                        var buf: [65536]u8 = undefined;
                        const line = conn.recvLine(&buf) catch null;

                        if (line) |msg| {
                            // Handle message - pass optional client_id
                            // Some messages (status, ping) don't need a registered client
                            // Others (create_pane) will register the client
                            self.handleMessage(&conn, client_id, pfd.fd, msg) catch |err| {
                                self.sendError(&conn, @errorName(err)) catch {};
                            };
                        } else {
                            // Connection closed
                            if (client_id) |cid| {
                                self.ses_state.removeClient(cid);
                            }
                            conn.close();
                            _ = poll_fds.orderedRemove(i);
                            continue;
                        }
                    }

                    if (pfd.revents & (posix.POLL.HUP | posix.POLL.ERR) != 0) {
                        // Connection error or hangup
                        if (client_id) |cid| {
                            self.ses_state.removeClient(cid);
                        }
                        conn.close();
                        _ = poll_fds.orderedRemove(i);
                        continue;
                    }
                }

                i += 1;
            }
        }
    }

    /// Handle a message from a client
    /// client_id is optional - queries like status/ping don't need a registered client
    /// For operations that need a client (create_pane, etc.), we register on first use
    fn handleMessage(self: *Server, conn: *ipc.Connection, client_id: ?usize, fd: posix.fd_t, msg: []const u8) !void {
        // Parse JSON message
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, msg, .{}) catch {
            try self.sendError(conn, "invalid_json");
            return;
        };
        defer parsed.deinit();

        const root = parsed.value.object;
        const msg_type = root.get("type") orelse {
            try self.sendError(conn, "missing_type");
            return;
        };

        const type_str = msg_type.string;

        // Read-only queries - don't need a registered client
        if (std.mem.eql(u8, type_str, "ping")) {
            try conn.sendLine("{\"type\":\"pong\"}");
            return;
        } else if (std.mem.eql(u8, type_str, "status")) {
            try self.handleStatus(conn, root);
            return;
        } else if (std.mem.eql(u8, type_str, "list_orphaned")) {
            try self.handleListOrphaned(conn);
            return;
        } else if (std.mem.eql(u8, type_str, "disconnect")) {
            // Graceful disconnect - mux already handled cleanup (killed panes, etc.)
            // Just remove client without auto-detach (that's only for crashes)
            if (client_id) |cid| {
                self.ses_state.removeClientGraceful(cid);
            }
            try conn.sendLine("{\"type\":\"ok\"}");
            return;
        }

        // Operations that need a client - register if not already registered
        const cid = client_id orelse blk: {
            // Register this connection as a new client
            const new_id = try self.ses_state.addClient(fd);
            break :blk new_id;
        };

        if (std.mem.eql(u8, type_str, "register")) {
            try self.handleRegister(conn, cid, root);
        } else if (std.mem.eql(u8, type_str, "sync_state")) {
            try self.handleSyncState(conn, cid, root);
        } else if (std.mem.eql(u8, type_str, "create_pane")) {
            try self.handleCreatePane(conn, cid, root);
        } else if (std.mem.eql(u8, type_str, "find_sticky")) {
            try self.handleFindSticky(conn, cid, root);
        } else if (std.mem.eql(u8, type_str, "reconnect")) {
            try self.handleReconnect(conn, cid, root);
        } else if (std.mem.eql(u8, type_str, "orphan_pane")) {
            try self.handleOrphanPane(conn, root);
        } else if (std.mem.eql(u8, type_str, "adopt_pane")) {
            try self.handleAdoptPane(conn, cid, root);
        } else if (std.mem.eql(u8, type_str, "kill_pane")) {
            try self.handleKillPane(conn, root);
        } else if (std.mem.eql(u8, type_str, "broadcast_notify")) {
            try self.handleBroadcastNotify(conn, root);
        } else if (std.mem.eql(u8, type_str, "detach_session")) {
            try self.handleDetachSession(conn, cid, root);
        } else if (std.mem.eql(u8, type_str, "reattach")) {
            try self.handleReattach(conn, cid, root);
        } else if (std.mem.eql(u8, type_str, "list_sessions")) {
            try self.handleListSessions(conn);
        } else {
            try self.sendError(conn, "unknown_type");
        }
    }

    fn handleRegister(self: *Server, conn: *ipc.Connection, client_id: usize, root: std.json.ObjectMap) !void {
        // Get keepalive preference (default true)
        const keepalive = if (root.get("keepalive")) |k| k.bool else true;

        // Get session_id (mux's UUID)
        const session_id_hex = (root.get("session_id") orelse return self.sendError(conn, "missing_session_id")).string;
        if (session_id_hex.len != 32) {
            return self.sendError(conn, "invalid_session_id");
        }

        var session_id: [16]u8 = undefined;
        _ = std.fmt.hexToBytes(&session_id, session_id_hex) catch {
            return self.sendError(conn, "invalid_session_id");
        };

        // Get session_name (Pokemon name)
        const session_name = if (root.get("session_name")) |n| n.string else "unknown";

        // Update client settings
        if (self.ses_state.getClient(client_id)) |client| {
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

    fn handleSyncState(self: *Server, conn: *ipc.Connection, client_id: usize, root: std.json.ObjectMap) !void {
        const mux_state = (root.get("mux_state") orelse return self.sendError(conn, "missing_mux_state")).string;

        // Update client's stored state
        if (self.ses_state.getClient(client_id)) |client| {
            client.updateMuxState(mux_state) catch {
                return self.sendError(conn, "state_update_failed");
            };
        }

        try conn.sendLine("{\"type\":\"state_synced\"}");
    }

    fn handleCreatePane(self: *Server, conn: *ipc.Connection, client_id: usize, root: std.json.ObjectMap) !void {
        // Get shell (default to $SHELL or /bin/sh)
        const shell = if (root.get("shell")) |s| s.string else (std.posix.getenv("SHELL") orelse "/bin/sh");

        // Get working directory
        const cwd: ?[]const u8 = if (root.get("cwd")) |c| c.string else null;

        // Get sticky options
        const sticky_pwd: ?[]const u8 = if (root.get("sticky_pwd")) |p| p.string else null;
        const sticky_key: ?u8 = if (root.get("sticky_key")) |k|
            if (k.string.len > 0) k.string[0] else null
        else
            null;

        // Create pane
        const pane = try self.ses_state.createPane(client_id, shell, cwd, sticky_pwd, sticky_key);

        // Send response with fd
        var response_buf: [256]u8 = undefined;
        const response = try std.fmt.bufPrint(&response_buf, "{{\"type\":\"pane_created\",\"uuid\":\"{s}\",\"pid\":{d}}}\n", .{
            pane.uuid,
            pane.child_pid,
        });

        try conn.sendWithFd(response, pane.master_fd);
    }

    fn handleFindSticky(self: *Server, conn: *ipc.Connection, client_id: usize, root: std.json.ObjectMap) !void {
        const pwd = (root.get("pwd") orelse return self.sendError(conn, "missing_pwd")).string;
        const key_str = (root.get("key") orelse return self.sendError(conn, "missing_key")).string;
        if (key_str.len == 0) return self.sendError(conn, "empty_key");
        const key = key_str[0];

        if (self.ses_state.findStickyPane(pwd, key)) |pane| {
            // Attach pane to this client
            _ = try self.ses_state.attachPane(pane.uuid, client_id);

            // Send response with fd
            var response_buf: [256]u8 = undefined;
            const response = try std.fmt.bufPrint(&response_buf, "{{\"type\":\"pane_found\",\"uuid\":\"{s}\",\"pid\":{d}}}\n", .{
                pane.uuid,
                pane.child_pid,
            });

            try conn.sendWithFd(response, pane.master_fd);
        } else {
            try conn.sendLine("{\"type\":\"pane_not_found\"}");
        }
    }

    fn handleReconnect(self: *Server, conn: *ipc.Connection, client_id: usize, root: std.json.ObjectMap) !void {
        const uuids_val = root.get("pane_uuids") orelse return self.sendError(conn, "missing_pane_uuids");
        const uuids = uuids_val.array;

        const FoundPane = struct { uuid: [32]u8, pid: posix.pid_t, fd: posix.fd_t };
        var found_panes: std.ArrayList(FoundPane) = .empty;
        defer found_panes.deinit(self.allocator);

        for (uuids.items) |uuid_val| {
            const uuid_str = uuid_val.string;
            if (uuid_str.len != 32) continue;

            var uuid: [32]u8 = undefined;
            @memcpy(&uuid, uuid_str[0..32]);

            if (self.ses_state.getPane(uuid)) |pane| {
                // Re-attach if orphaned
                if (pane.state != .attached) {
                    _ = self.ses_state.attachPane(uuid, client_id) catch continue;
                }
                try found_panes.append(self.allocator, .{
                    .uuid = uuid,
                    .pid = pane.child_pid,
                    .fd = pane.master_fd,
                });
            }
        }

        // Build response JSON
        var json_buf: [4096]u8 = undefined;
        var stream = std.io.fixedBufferStream(&json_buf);
        var writer = stream.writer();

        try writer.writeAll("{\"type\":\"reconnected\",\"panes\":[");
        for (found_panes.items, 0..) |p, i| {
            if (i > 0) try writer.writeAll(",");
            try writer.print("{{\"uuid\":\"{s}\",\"pid\":{d}}}", .{ p.uuid, p.pid });
        }
        try writer.writeAll("]}\n");

        // Send response - for simplicity, send fds one at a time after the JSON
        try conn.send(stream.getWritten());

        // Send each fd with a small message
        for (found_panes.items) |p| {
            var fd_msg: [64]u8 = undefined;
            const msg = try std.fmt.bufPrint(&fd_msg, "fd:{s}\n", .{p.uuid});
            try conn.sendWithFd(msg, p.fd);
        }
    }

    fn handleOrphanPane(self: *Server, conn: *ipc.Connection, root: std.json.ObjectMap) !void {
        const uuid_str = (root.get("uuid") orelse return self.sendError(conn, "missing_uuid")).string;
        if (uuid_str.len != 32) return self.sendError(conn, "invalid_uuid");

        var uuid: [32]u8 = undefined;
        @memcpy(&uuid, uuid_str[0..32]);

        try self.ses_state.suspendPane(uuid);
        try conn.sendLine("{\"type\":\"ok\"}");
    }

    fn handleListOrphaned(self: *Server, conn: *ipc.Connection) !void {
        const orphaned = try self.ses_state.getOrphanedPanes(self.allocator);
        defer self.allocator.free(orphaned);

        var json_buf: [8192]u8 = undefined;
        var stream = std.io.fixedBufferStream(&json_buf);
        var writer = stream.writer();

        try writer.writeAll("{\"type\":\"orphaned_panes\",\"panes\":[");
        for (orphaned, 0..) |pane, i| {
            if (i > 0) try writer.writeAll(",");
            try writer.print("{{\"uuid\":\"{s}\"", .{pane.uuid});
            if (pane.sticky_pwd) |pwd| {
                try writer.print(",\"sticky_pwd\":\"{s}\"", .{pwd});
            }
            if (pane.sticky_key) |key| {
                try writer.print(",\"sticky_key\":\"{c}\"", .{key});
            }
            const state_str = switch (pane.state) {
                .attached => "attached",
                .detached => "detached",
                .sticky => "sticky",
                .orphaned => "orphaned",
            };
            try writer.print(",\"state\":\"{s}\"}}", .{state_str});
        }
        try writer.writeAll("]}\n");

        try conn.send(stream.getWritten());
    }

    fn handleAdoptPane(self: *Server, conn: *ipc.Connection, client_id: usize, root: std.json.ObjectMap) !void {
        const uuid_str = (root.get("uuid") orelse return self.sendError(conn, "missing_uuid")).string;
        if (uuid_str.len != 32) return self.sendError(conn, "invalid_uuid");

        var uuid: [32]u8 = undefined;
        @memcpy(&uuid, uuid_str[0..32]);

        const pane = try self.ses_state.attachPane(uuid, client_id);

        // Send response with fd
        var response_buf: [256]u8 = undefined;
        const response = try std.fmt.bufPrint(&response_buf, "{{\"type\":\"pane_found\",\"uuid\":\"{s}\",\"pid\":{d}}}\n", .{
            pane.uuid,
            pane.child_pid,
        });

        try conn.sendWithFd(response, pane.master_fd);
    }

    fn handleKillPane(self: *Server, conn: *ipc.Connection, root: std.json.ObjectMap) !void {
        const uuid_str = (root.get("uuid") orelse return self.sendError(conn, "missing_uuid")).string;
        if (uuid_str.len != 32) return self.sendError(conn, "invalid_uuid");

        var uuid: [32]u8 = undefined;
        @memcpy(&uuid, uuid_str[0..32]);

        try self.ses_state.killPane(uuid);
        try conn.sendLine("{\"type\":\"ok\"}");
    }

    fn handleBroadcastNotify(self: *Server, conn: *ipc.Connection, root: std.json.ObjectMap) !void {
        const message = (root.get("message") orelse return self.sendError(conn, "missing_message")).string;

        // Build notification message
        var msg_buf: [4096]u8 = undefined;
        const notify_msg = std.fmt.bufPrint(&msg_buf, "{{\"type\":\"notification\",\"message\":\"{s}\"}}\n", .{message}) catch {
            return self.sendError(conn, "message_too_long");
        };

        // Send to all connected clients (except the one sending the command)
        var sent_count: usize = 0;
        for (self.ses_state.clients.items) |client| {
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

    fn handleStatus(self: *Server, conn: *ipc.Connection, root: std.json.ObjectMap) !void {
        // Check if full mode is requested
        const full_mode = if (root.get("full")) |f| f.bool else false;

        // Use dynamic allocation for large responses in full mode
        const buf_size: usize = if (full_mode) 131072 else 32768;
        const json_buf = self.allocator.alloc(u8, buf_size) catch {
            return self.sendError(conn, "alloc_failed");
        };
        defer self.allocator.free(json_buf);

        var stream = std.io.fixedBufferStream(json_buf);
        var writer = stream.writer();

        try writer.writeAll("{\"type\":\"status\",\"clients\":[");

        // Iterate over clients (connected muxes)
        for (self.ses_state.clients.items, 0..) |client, ci| {
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
            for (client.pane_uuids.items, 0..) |uuid, pi| {
                if (pi > 0) try writer.writeAll(",");
                if (self.ses_state.panes.get(uuid)) |pane| {
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
        var sess_iter = self.ses_state.detached_sessions.iterator();
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
        var pane_iter = self.ses_state.panes.iterator();
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
        pane_iter = self.ses_state.panes.iterator();
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

    fn sendError(self: *Server, conn: *ipc.Connection, msg: []const u8) !void {
        _ = self;
        var buf: [256]u8 = undefined;
        const response = try std.fmt.bufPrint(&buf, "{{\"type\":\"error\",\"message\":\"{s}\"}}\n", .{msg});
        try conn.send(response);
    }

    fn handleDetachSession(self: *Server, conn: *ipc.Connection, client_id: usize, root: std.json.ObjectMap) !void {
        // Get the session_id (mux UUID) and mux state JSON from the message
        const session_id_hex = (root.get("session_id") orelse return self.sendError(conn, "missing_session_id")).string;
        const mux_state = (root.get("mux_state") orelse return self.sendError(conn, "missing_mux_state")).string;

        // Convert 32-char hex to 16 bytes
        if (session_id_hex.len != 32) {
            return self.sendError(conn, "invalid_session_id");
        }
        var session_id: [16]u8 = undefined;
        _ = std.fmt.hexToBytes(&session_id, session_id_hex) catch {
            return self.sendError(conn, "invalid_session_id");
        };

        // Get session_name from client
        const session_name = if (self.ses_state.getClient(client_id)) |client|
            client.session_name orelse "unknown"
        else
            "unknown";

        if (self.ses_state.detachSession(client_id, session_id, session_name, mux_state)) {
            var buf: [128]u8 = undefined;
            const response = try std.fmt.bufPrint(&buf, "{{\"type\":\"session_detached\",\"session_id\":\"{s}\"}}\n", .{
                session_id_hex,
            });
            try conn.send(response);
        } else {
            try self.sendError(conn, "client_not_found");
        }
    }

    fn handleReattach(self: *Server, conn: *ipc.Connection, client_id: usize, root: std.json.ObjectMap) !void {
        const session_id_prefix = (root.get("session_id") orelse return self.sendError(conn, "missing_session_id")).string;
        if (session_id_prefix.len < 1 or session_id_prefix.len > 32) return self.sendError(conn, "invalid_session_id");

        // Find session by UUID prefix OR by session name match
        var matched_session_id: ?[16]u8 = null;
        var match_count: usize = 0;

        var iter = self.ses_state.detached_sessions.iterator();
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
            return self.sendError(conn, "session_not_found");
        }
        if (match_count > 1) {
            return self.sendError(conn, "ambiguous_session_id");
        }

        const session_id = matched_session_id.?;

        const result = self.ses_state.reattachSession(session_id, client_id) catch {
            return self.sendError(conn, "reattach_failed");
        };

        if (result == null) {
            return self.sendError(conn, "session_not_found");
        }

        const reattach_result = result.?;
        defer {
            self.allocator.free(reattach_result.mux_state_json);
            self.allocator.free(reattach_result.pane_uuids);
        }

        // Send response with mux state and pane UUIDs
        // Use dynamic allocation for large mux states
        // mux_state needs to be escaped since it's a JSON string containing JSON
        const estimated_size = reattach_result.mux_state_json.len * 2 + 1024;
        const json_buf = self.allocator.alloc(u8, estimated_size) catch {
            return self.sendError(conn, "alloc_failed");
        };
        defer self.allocator.free(json_buf);

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

    fn handleListSessions(self: *Server, conn: *ipc.Connection) !void {
        const sessions = self.ses_state.listDetachedSessions(self.allocator) catch {
            return self.sendError(conn, "list_failed");
        };
        defer self.allocator.free(sessions);

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

    pub fn stop(self: *Server) void {
        self.running = false;
    }
};
