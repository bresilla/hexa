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
    pub fn createPane(self: *SesClient, shell: ?[]const u8, sticky_pwd: ?[]const u8, sticky_key: ?u8) !struct { uuid: [32]u8, fd: posix.fd_t, pid: posix.pid_t } {
        const conn = &(self.conn orelse return error.NotConnected);

        // Build request JSON
        var buf: [512]u8 = undefined;
        var stream = std.io.fixedBufferStream(&buf);
        var writer = stream.writer();

        try writer.writeAll("{\"type\":\"create_pane\"");
        if (shell) |s| {
            try writer.print(",\"shell\":\"{s}\"", .{s});
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
};
