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
                    const client_id = try self.ses_state.addClient(conn.fd);
                    try poll_fds.append(self.allocator, .{
                        .fd = conn.fd,
                        .events = posix.POLL.IN,
                        .revents = 0,
                    });
                    _ = client_id;
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
                        // Try to read message
                        var buf: [4096]u8 = undefined;
                        const line = conn.recvLine(&buf) catch null;

                        if (line) |msg| {
                            if (client_id) |cid| {
                                self.handleMessage(&conn, cid, msg) catch |err| {
                                    self.sendError(&conn, @errorName(err)) catch {};
                                };
                            }
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
    fn handleMessage(self: *Server, conn: *ipc.Connection, client_id: usize, msg: []const u8) !void {
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

        if (std.mem.eql(u8, type_str, "create_pane")) {
            try self.handleCreatePane(conn, client_id, root);
        } else if (std.mem.eql(u8, type_str, "find_sticky")) {
            try self.handleFindSticky(conn, client_id, root);
        } else if (std.mem.eql(u8, type_str, "reconnect")) {
            try self.handleReconnect(conn, client_id, root);
        } else if (std.mem.eql(u8, type_str, "disconnect")) {
            try self.handleDisconnect(conn, client_id, root);
        } else if (std.mem.eql(u8, type_str, "orphan_pane")) {
            try self.handleOrphanPane(conn, root);
        } else if (std.mem.eql(u8, type_str, "list_orphaned")) {
            try self.handleListOrphaned(conn);
        } else if (std.mem.eql(u8, type_str, "adopt_pane")) {
            try self.handleAdoptPane(conn, client_id, root);
        } else if (std.mem.eql(u8, type_str, "kill_pane")) {
            try self.handleKillPane(conn, root);
        } else if (std.mem.eql(u8, type_str, "ping")) {
            try conn.sendLine("{\"type\":\"pong\"}");
        } else if (std.mem.eql(u8, type_str, "status")) {
            try self.handleStatus(conn);
        } else if (std.mem.eql(u8, type_str, "broadcast_notify")) {
            try self.handleBroadcastNotify(conn, root);
        } else {
            try self.sendError(conn, "unknown_type");
        }
    }

    fn handleCreatePane(self: *Server, conn: *ipc.Connection, client_id: usize, root: std.json.ObjectMap) !void {
        // Get shell (default to $SHELL or /bin/sh)
        const shell = if (root.get("shell")) |s| s.string else (std.posix.getenv("SHELL") orelse "/bin/sh");

        // Get sticky options
        const sticky_pwd: ?[]const u8 = if (root.get("sticky_pwd")) |p| p.string else null;
        const sticky_key: ?u8 = if (root.get("sticky_key")) |k|
            if (k.string.len > 0) k.string[0] else null
        else
            null;

        // Create pane
        const pane = try self.ses_state.createPane(client_id, shell, sticky_pwd, sticky_key);

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

    fn handleDisconnect(self: *Server, conn: *ipc.Connection, client_id: usize, root: std.json.ObjectMap) !void {
        _ = root;
        // Client is disconnecting gracefully - orphan their panes
        self.ses_state.removeClient(client_id);
        try conn.sendLine("{\"type\":\"ok\"}");
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
                .half_orphaned => "half_orphaned",
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

    fn handleStatus(self: *Server, conn: *ipc.Connection) !void {
        var json_buf: [16384]u8 = undefined;
        var stream = std.io.fixedBufferStream(&json_buf);
        var writer = stream.writer();

        try writer.writeAll("{\"type\":\"status\",\"clients\":[");

        // Iterate over clients
        for (self.ses_state.clients.items, 0..) |client, ci| {
            if (ci > 0) try writer.writeAll(",");
            try writer.print("{{\"id\":{d},\"panes\":[", .{client.id});

            // List panes for this client
            for (client.pane_uuids.items, 0..) |uuid, pi| {
                if (pi > 0) try writer.writeAll(",");
                if (self.ses_state.panes.get(uuid)) |pane| {
                    const state_str = switch (pane.state) {
                        .attached => "attached",
                        .half_orphaned => "half_orphaned",
                        .orphaned => "orphaned",
                    };
                    try writer.print("{{\"uuid\":\"{s}\",\"pid\":{d},\"state\":\"{s}\"", .{
                        uuid,
                        pane.child_pid,
                        state_str,
                    });
                    if (pane.sticky_pwd) |pwd| {
                        try writer.print(",\"sticky_pwd\":\"{s}\"", .{pwd});
                    }
                    try writer.writeAll("}");
                }
            }
            try writer.writeAll("]}");
        }

        try writer.writeAll("],\"orphaned\":[");

        // List orphaned panes (not attached to any client)
        var first_orphan = true;
        var pane_iter = self.ses_state.panes.iterator();
        while (pane_iter.next()) |entry| {
            const pane = entry.value_ptr;
            if (pane.state != .attached) {
                if (!first_orphan) try writer.writeAll(",");
                first_orphan = false;

                const state_str = switch (pane.state) {
                    .attached => "attached",
                    .half_orphaned => "half_orphaned",
                    .orphaned => "orphaned",
                };
                try writer.print("{{\"uuid\":\"{s}\",\"pid\":{d},\"state\":\"{s}\"", .{
                    entry.key_ptr.*,
                    pane.child_pid,
                    state_str,
                });
                if (pane.sticky_pwd) |pwd| {
                    try writer.print(",\"sticky_pwd\":\"{s}\"", .{pwd});
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

    pub fn stop(self: *Server) void {
        self.running = false;
    }
};
