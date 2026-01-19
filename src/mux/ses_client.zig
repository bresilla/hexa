const std = @import("std");
const posix = std.posix;
const core = @import("core");

/// Client for communicating with the ses daemon
pub const SesClient = struct {
    allocator: std.mem.Allocator,
    conn: ?core.ipc.Connection,
    just_started_daemon: bool,

    pub fn init(allocator: std.mem.Allocator) SesClient {
        return .{
            .allocator = allocator,
            .conn = null,
            .just_started_daemon = false,
        };
    }

    pub fn deinit(self: *SesClient) void {
        if (self.conn) |*c| {
            // Send disconnect message before closing
            c.sendLine("{\"type\":\"disconnect\"}") catch {};
            c.close();
        }
    }

    /// Connect to the ses daemon, starting it if necessary
    pub fn connect(self: *SesClient) !void {
        const socket_path = try core.ipc.getSesSocketPath(self.allocator);
        defer self.allocator.free(socket_path);

        // Try to connect to existing daemon first
        if (core.ipc.Client.connect(socket_path)) |client| {
            self.conn = client.toConnection();
            self.just_started_daemon = false;
            return;
        } else |err| {
            if (err != error.ConnectionRefused and err != error.FileNotFound) {
                return err;
            }
        }

        // Daemon not running, start it
        try self.startSes();
        self.just_started_daemon = true;

        // Wait for daemon to be ready
        std.Thread.sleep(200 * std.time.ns_per_ms);

        // Retry connection
        const client = try core.ipc.Client.connect(socket_path);
        self.conn = client.toConnection();
    }

    /// Start the ses daemon
    fn startSes(self: *SesClient) !void {
        _ = self;
        // Fork and exec hexa-ses --daemon
        var child = std.process.Child.init(&[_][]const u8{ "hexa-ses", "--daemon" }, std.heap.page_allocator);
        child.spawn() catch |err| {
            std.debug.print("Failed to start ses daemon: {}\n", .{err});
            return err;
        };
        // Don't wait - it daemonizes itself
        _ = child.wait() catch {};
    }

    /// Check if connected to ses
    pub fn isConnected(self: *SesClient) bool {
        return self.conn != null;
    }

    /// Create a new pane via ses
    /// Returns the pane UUID and master fd
    pub fn createPane(self: *SesClient, shell: ?[]const u8, cwd: ?[]const u8, sticky_pwd: ?[]const u8, sticky_key: ?u8) !struct { uuid: [32]u8, fd: posix.fd_t, pid: posix.pid_t } {
        const conn = &(self.conn orelse return error.NotConnected);

        // Build request JSON
        var buf: [1024]u8 = undefined;
        var stream = std.io.fixedBufferStream(&buf);
        var writer = stream.writer();

        try writer.writeAll("{\"type\":\"create_pane\"");
        if (shell) |s| {
            try writer.print(",\"shell\":\"{s}\"", .{s});
        }
        if (cwd) |dir| {
            try writer.print(",\"cwd\":\"{s}\"", .{dir});
        }
        if (sticky_pwd) |pwd| {
            try writer.print(",\"sticky_pwd\":\"{s}\"", .{pwd});
        }
        if (sticky_key) |key| {
            try writer.print(",\"sticky_key\":\"{c}\"", .{key});
        }
        try writer.writeAll("}");

        try conn.sendLine(stream.getWritten());

        // Receive response with fd
        var resp_buf: [512]u8 = undefined;
        const result = try conn.recvWithFd(&resp_buf);

        if (result.fd == null) {
            return error.NoFdReceived;
        }

        // Parse response JSON
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, resp_buf[0..result.len], .{}) catch {
            return error.InvalidResponse;
        };
        defer parsed.deinit();

        const root = parsed.value.object;
        const msg_type = (root.get("type") orelse return error.InvalidResponse).string;

        if (std.mem.eql(u8, msg_type, "error")) {
            return error.SesError;
        }

        if (!std.mem.eql(u8, msg_type, "pane_created")) {
            return error.UnexpectedResponse;
        }

        const uuid_str = (root.get("uuid") orelse return error.InvalidResponse).string;
        const pid = (root.get("pid") orelse return error.InvalidResponse).integer;

        var uuid: [32]u8 = undefined;
        if (uuid_str.len == 32) {
            @memcpy(&uuid, uuid_str[0..32]);
        } else {
            return error.InvalidUuid;
        }

        return .{
            .uuid = uuid,
            .fd = result.fd.?,
            .pid = @intCast(pid),
        };
    }

    /// Find a sticky pane (for pwd floats)
    pub fn findStickyPane(self: *SesClient, pwd: []const u8, key: u8) !?struct { uuid: [32]u8, fd: posix.fd_t, pid: posix.pid_t } {
        const conn = &(self.conn orelse return error.NotConnected);

        // Build request
        var buf: [512]u8 = undefined;
        const msg = try std.fmt.bufPrint(&buf, "{{\"type\":\"find_sticky\",\"pwd\":\"{s}\",\"key\":\"{c}\"}}", .{ pwd, key });
        try conn.sendLine(msg);

        // Receive response
        var resp_buf: [512]u8 = undefined;
        const result = try conn.recvWithFd(&resp_buf);

        // Parse response
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, resp_buf[0..result.len], .{}) catch {
            return error.InvalidResponse;
        };
        defer parsed.deinit();

        const root = parsed.value.object;
        const msg_type = (root.get("type") orelse return error.InvalidResponse).string;

        if (std.mem.eql(u8, msg_type, "pane_not_found")) {
            return null;
        }

        if (!std.mem.eql(u8, msg_type, "pane_found")) {
            return error.UnexpectedResponse;
        }

        if (result.fd == null) {
            return error.NoFdReceived;
        }

        const uuid_str = (root.get("uuid") orelse return error.InvalidResponse).string;
        const pid = (root.get("pid") orelse return error.InvalidResponse).integer;

        var uuid: [32]u8 = undefined;
        if (uuid_str.len == 32) {
            @memcpy(&uuid, uuid_str[0..32]);
        } else {
            return error.InvalidUuid;
        }

        return .{
            .uuid = uuid,
            .fd = result.fd.?,
            .pid = @intCast(pid),
        };
    }

    /// Orphan a pane (manual suspend)
    pub fn orphanPane(self: *SesClient, uuid: [32]u8) !void {
        const conn = &(self.conn orelse return error.NotConnected);

        var buf: [128]u8 = undefined;
        const msg = try std.fmt.bufPrint(&buf, "{{\"type\":\"orphan_pane\",\"uuid\":\"{s}\"}}", .{uuid});
        try conn.sendLine(msg);

        // Wait for OK response
        var resp_buf: [256]u8 = undefined;
        const line = try conn.recvLine(&resp_buf);
        if (line == null) return error.ConnectionClosed;
    }

    /// Kill a pane
    pub fn killPane(self: *SesClient, uuid: [32]u8) !void {
        const conn = &(self.conn orelse return error.NotConnected);

        var buf: [128]u8 = undefined;
        const msg = try std.fmt.bufPrint(&buf, "{{\"type\":\"kill_pane\",\"uuid\":\"{s}\"}}", .{uuid});
        try conn.sendLine(msg);

        // Wait for OK response
        var resp_buf: [256]u8 = undefined;
        const line = try conn.recvLine(&resp_buf);
        if (line == null) return error.ConnectionClosed;
    }

    /// Ping ses to check if it's alive
    pub fn ping(self: *SesClient) !bool {
        const conn = &(self.conn orelse return false);

        try conn.sendLine("{\"type\":\"ping\"}");

        var resp_buf: [64]u8 = undefined;
        const line = conn.recvLine(&resp_buf) catch return false;
        if (line == null) return false;

        return std.mem.indexOf(u8, line.?, "pong") != null;
    }

    /// Adopt an orphaned pane
    pub fn adoptPane(self: *SesClient, uuid: [32]u8) !struct { uuid: [32]u8, fd: posix.fd_t, pid: posix.pid_t } {
        const conn = &(self.conn orelse return error.NotConnected);

        var buf: [128]u8 = undefined;
        const msg = try std.fmt.bufPrint(&buf, "{{\"type\":\"adopt_pane\",\"uuid\":\"{s}\"}}", .{uuid});
        try conn.sendLine(msg);

        // Receive response with fd
        var resp_buf: [512]u8 = undefined;
        const result = try conn.recvWithFd(&resp_buf);

        if (result.fd == null) {
            return error.NoFdReceived;
        }

        // Parse response JSON
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, resp_buf[0..result.len], .{}) catch {
            return error.InvalidResponse;
        };
        defer parsed.deinit();

        const root = parsed.value.object;
        const msg_type = (root.get("type") orelse return error.InvalidResponse).string;

        if (std.mem.eql(u8, msg_type, "error")) {
            return error.SesError;
        }

        if (!std.mem.eql(u8, msg_type, "pane_found")) {
            return error.UnexpectedResponse;
        }

        const pid = (root.get("pid") orelse return error.InvalidResponse).integer;

        return .{
            .uuid = uuid,
            .fd = result.fd.?,
            .pid = @intCast(pid),
        };
    }

    /// List orphaned panes
    pub fn listOrphanedPanes(self: *SesClient, out_buf: []OrphanedPaneInfo) !usize {
        const conn = &(self.conn orelse return error.NotConnected);

        try conn.sendLine("{\"type\":\"list_orphaned\"}");

        var resp_buf: [4096]u8 = undefined;
        const line = try conn.recvLine(&resp_buf);
        if (line == null) return error.ConnectionClosed;

        // Parse response JSON
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, line.?, .{}) catch {
            return error.InvalidResponse;
        };
        defer parsed.deinit();

        const root = parsed.value.object;
        const msg_type = (root.get("type") orelse return error.InvalidResponse).string;

        if (!std.mem.eql(u8, msg_type, "orphaned_panes")) {
            return error.UnexpectedResponse;
        }

        const panes = (root.get("panes") orelse return error.InvalidResponse).array;
        var count: usize = 0;

        for (panes.items) |pane_val| {
            if (count >= out_buf.len) break;
            const pane = pane_val.object;

            const uuid_str = (pane.get("uuid") orelse continue).string;
            if (uuid_str.len != 32) continue;

            var info: OrphanedPaneInfo = undefined;
            @memcpy(&info.uuid, uuid_str[0..32]);
            info.pid = @intCast((pane.get("pid") orelse continue).integer);

            out_buf[count] = info;
            count += 1;
        }

        return count;
    }

    /// Detach session - keeps panes grouped for later reattach
    /// Sends full mux state JSON for storage
    /// Returns session_id (hex string)
    /// Detach session with a specific session ID (mux UUID)
    /// The session_id should be a 32-char hex string (the mux's UUID)
    pub fn detachSession(self: *SesClient, session_id: [32]u8, mux_state_json: []const u8) !void {
        const conn = &(self.conn orelse return error.NotConnected);

        // Build message with session_id and mux state as escaped JSON string
        // {"type":"detach_session","session_id":"<uuid>","mux_state":"<escaped_json>"}
        // Allocate buffer for the full message (doubled for escaping)
        const msg_size = 128 + mux_state_json.len * 2;
        const msg_buf = self.allocator.alloc(u8, msg_size) catch return error.OutOfMemory;
        defer self.allocator.free(msg_buf);

        var stream = std.io.fixedBufferStream(msg_buf);
        var writer = stream.writer();
        writer.print("{{\"type\":\"detach_session\",\"session_id\":\"{s}\",\"mux_state\":\"", .{session_id}) catch return error.WriteError;
        // Escape the JSON string
        for (mux_state_json) |c| {
            switch (c) {
                '"' => writer.writeAll("\\\"") catch return error.WriteError,
                '\\' => writer.writeAll("\\\\") catch return error.WriteError,
                '\n' => writer.writeAll("\\n") catch return error.WriteError,
                '\r' => writer.writeAll("\\r") catch return error.WriteError,
                '\t' => writer.writeAll("\\t") catch return error.WriteError,
                else => writer.writeByte(c) catch return error.WriteError,
            }
        }
        writer.writeAll("\"}") catch return error.WriteError;

        try conn.sendLine(stream.getWritten());

        var resp_buf: [256]u8 = undefined;
        const line = try conn.recvLine(&resp_buf);
        if (line == null) return error.ConnectionClosed;

        // Parse response
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, line.?, .{}) catch {
            return error.InvalidResponse;
        };
        defer parsed.deinit();

        const root = parsed.value.object;
        const msg_type = (root.get("type") orelse return error.InvalidResponse).string;

        if (std.mem.eql(u8, msg_type, "error")) {
            return error.DetachFailed;
        }

        if (!std.mem.eql(u8, msg_type, "session_detached")) {
            return error.UnexpectedResponse;
        }
    }

    /// Result of reattaching a session
    pub const ReattachResult = struct {
        mux_state_json: []const u8, // Owned - caller must free with allocator
        pane_uuids: [][32]u8, // Owned - caller must free
    };

    /// Reattach to a detached session
    /// Returns the full mux state and list of pane UUIDs to adopt
    pub fn reattachSession(self: *SesClient, session_id: []const u8) !?ReattachResult {
        const conn = &(self.conn orelse return error.NotConnected);

        // Build request
        var buf: [128]u8 = undefined;
        const msg = try std.fmt.bufPrint(&buf, "{{\"type\":\"reattach\",\"session_id\":\"{s}\"}}", .{session_id});
        try conn.sendLine(msg);

        // Response can be large, allocate dynamically
        var resp_buf: [65536]u8 = undefined;
        const line = try conn.recvLine(&resp_buf);
        if (line == null) return error.ConnectionClosed;

        // Parse response
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, line.?, .{}) catch {
            return error.InvalidResponse;
        };
        defer parsed.deinit();

        const root = parsed.value.object;
        const msg_type = (root.get("type") orelse return error.InvalidResponse).string;

        if (std.mem.eql(u8, msg_type, "error")) {
            return null;
        }

        if (!std.mem.eql(u8, msg_type, "session_reattached")) {
            return error.UnexpectedResponse;
        }

        // Get mux state (it's a JSON string that was escaped in the response)
        const mux_state_str = (root.get("mux_state") orelse return error.InvalidResponse).string;
        // Copy to owned memory
        const mux_state_json = self.allocator.dupe(u8, mux_state_str) catch return error.OutOfMemory;
        errdefer self.allocator.free(mux_state_json);

        // Get pane UUIDs
        const panes_array = (root.get("panes") orelse return error.InvalidResponse).array;
        var pane_uuids = self.allocator.alloc([32]u8, panes_array.items.len) catch return error.OutOfMemory;
        errdefer self.allocator.free(pane_uuids);

        for (panes_array.items, 0..) |pane_val, i| {
            const uuid_str = pane_val.string;
            if (uuid_str.len == 32) {
                @memcpy(&pane_uuids[i], uuid_str[0..32]);
            }
        }

        return .{
            .mux_state_json = mux_state_json,
            .pane_uuids = pane_uuids,
        };
    }

    /// List detached sessions
    pub fn listSessions(self: *SesClient, out_buf: []DetachedSessionInfo) !usize {
        const conn = &(self.conn orelse return error.NotConnected);

        try conn.sendLine("{\"type\":\"list_sessions\"}");

        var resp_buf: [4096]u8 = undefined;
        const line = try conn.recvLine(&resp_buf);
        if (line == null) return error.ConnectionClosed;

        // Parse response
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, line.?, .{}) catch {
            return error.InvalidResponse;
        };
        defer parsed.deinit();

        const root = parsed.value.object;
        const msg_type = (root.get("type") orelse return error.InvalidResponse).string;

        if (!std.mem.eql(u8, msg_type, "sessions")) {
            return error.UnexpectedResponse;
        }

        const sessions = (root.get("sessions") orelse return error.InvalidResponse).array;
        var count: usize = 0;

        for (sessions.items) |sess_val| {
            if (count >= out_buf.len) break;
            const sess = sess_val.object;

            const sid_str = (sess.get("session_id") orelse continue).string;
            if (sid_str.len != 32) continue;

            var info: DetachedSessionInfo = undefined;
            @memcpy(&info.session_id, sid_str[0..32]);
            info.pane_count = @intCast((sess.get("pane_count") orelse continue).integer);

            out_buf[count] = info;
            count += 1;
        }

        return count;
    }
};

pub const OrphanedPaneInfo = struct {
    uuid: [32]u8,
    pid: posix.pid_t,
};

pub const DetachedSessionInfo = struct {
    session_id: [32]u8,
    pane_count: usize,
};
