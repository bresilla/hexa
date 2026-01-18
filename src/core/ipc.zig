const std = @import("std");
const posix = std.posix;

const c = @cImport({
    @cInclude("sys/socket.h");
    @cInclude("sys/un.h");
    @cInclude("unistd.h");
});

/// Unix domain socket server for IPC
pub const Server = struct {
    fd: posix.fd_t,
    path: []const u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, path: []const u8) !Server {
        // Create socket
        const fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
        errdefer posix.close(fd);

        // Remove existing socket file if present
        std.fs.cwd().deleteFile(path) catch {};

        // Ensure parent directory exists
        if (std.fs.path.dirname(path)) |dir| {
            std.fs.cwd().makePath(dir) catch {};
        }

        // Bind to path
        var addr: posix.sockaddr.un = .{
            .family = posix.AF.UNIX,
            .path = undefined,
        };
        @memset(&addr.path, 0);
        const path_len = @min(path.len, addr.path.len - 1);
        @memcpy(addr.path[0..path_len], path[0..path_len]);

        try posix.bind(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un));

        // Listen for connections
        try posix.listen(fd, 16);

        // Store path for cleanup
        const owned_path = try allocator.dupe(u8, path);

        return Server{
            .fd = fd,
            .path = owned_path,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Server) void {
        posix.close(self.fd);
        std.fs.cwd().deleteFile(self.path) catch {};
        self.allocator.free(self.path);
    }

    pub fn accept(self: *Server) !Connection {
        const client_fd = try posix.accept(self.fd, null, null, 0);
        return Connection{ .fd = client_fd };
    }

    /// Non-blocking accept, returns null if no connection pending
    pub fn tryAccept(self: *Server) !?Connection {
        // Use accept with SOCK_NONBLOCK flag directly
        const client_fd = posix.accept(self.fd, null, null, posix.SOCK.NONBLOCK) catch |err| {
            if (err == error.WouldBlock) return null;
            return err;
        };
        return Connection{ .fd = client_fd };
    }

    pub fn getFd(self: Server) posix.fd_t {
        return self.fd;
    }
};

/// Client connection to a Unix domain socket
pub const Client = struct {
    fd: posix.fd_t,

    pub fn connect(path: []const u8) !Client {
        const fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
        errdefer posix.close(fd);

        var addr: posix.sockaddr.un = .{
            .family = posix.AF.UNIX,
            .path = undefined,
        };
        @memset(&addr.path, 0);
        const path_len = @min(path.len, addr.path.len - 1);
        @memcpy(addr.path[0..path_len], path[0..path_len]);

        try posix.connect(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un));

        return Client{ .fd = fd };
    }

    pub fn close(self: *Client) void {
        posix.close(self.fd);
    }

    pub fn toConnection(self: Client) Connection {
        return Connection{ .fd = self.fd };
    }
};

/// A connection that can send/receive data and file descriptors
pub const Connection = struct {
    fd: posix.fd_t,

    pub fn close(self: *Connection) void {
        posix.close(self.fd);
    }

    pub fn getFd(self: Connection) posix.fd_t {
        return self.fd;
    }

    /// Send data without file descriptor
    pub fn send(self: *Connection, data: []const u8) !void {
        var total_sent: usize = 0;
        while (total_sent < data.len) {
            const sent = try posix.write(self.fd, data[total_sent..]);
            if (sent == 0) return error.ConnectionClosed;
            total_sent += sent;
        }
    }

    /// Receive data without file descriptor
    pub fn recv(self: *Connection, buf: []u8) !usize {
        return posix.read(self.fd, buf);
    }

    /// Send a line (data + newline)
    pub fn sendLine(self: *Connection, data: []const u8) !void {
        try self.send(data);
        try self.send("\n");
    }

    /// Receive a line (up to newline, newline not included in result)
    pub fn recvLine(self: *Connection, buf: []u8) !?[]const u8 {
        var i: usize = 0;
        while (i < buf.len) {
            const n = posix.read(self.fd, buf[i .. i + 1]) catch |err| {
                if (err == error.WouldBlock) {
                    if (i == 0) return null;
                    continue;
                }
                return err;
            };
            if (n == 0) {
                if (i == 0) return null;
                return buf[0..i];
            }
            if (buf[i] == '\n') {
                return buf[0..i];
            }
            i += 1;
        }
        return buf[0..i];
    }

    /// Send data along with a file descriptor using SCM_RIGHTS
    pub fn sendWithFd(self: *Connection, data: []const u8, fd_to_send: posix.fd_t) !void {
        var iov: c.struct_iovec = .{
            .iov_base = @constCast(data.ptr),
            .iov_len = data.len,
        };

        // Control message buffer for SCM_RIGHTS - use CMSG_SPACE macro equivalent
        const cmsg_align = comptime @alignOf(c.struct_cmsghdr);
        const cmsg_hdr_size = comptime @sizeOf(c.struct_cmsghdr);
        const cmsg_data_size = comptime @sizeOf(c_int);
        const cmsg_space = comptime std.mem.alignForward(usize, cmsg_hdr_size + cmsg_data_size, cmsg_align);
        var cmsg_buf: [cmsg_space]u8 align(cmsg_align) = undefined;

        // Set up control message header
        const cmsg: *c.struct_cmsghdr = @ptrCast(&cmsg_buf);
        cmsg.cmsg_len = cmsg_hdr_size + cmsg_data_size;
        cmsg.cmsg_level = c.SOL_SOCKET;
        cmsg.cmsg_type = c.SCM_RIGHTS;

        // Copy fd into control message data area (after the header)
        const cmsg_data: *c_int = @ptrCast(@alignCast(&cmsg_buf[cmsg_hdr_size]));
        cmsg_data.* = fd_to_send;

        var msg: c.struct_msghdr = .{
            .msg_name = null,
            .msg_namelen = 0,
            .msg_iov = &iov,
            .msg_iovlen = 1,
            .msg_control = &cmsg_buf,
            .msg_controllen = cmsg_space,
            .msg_flags = 0,
        };

        const result = c.sendmsg(self.fd, &msg, 0);
        if (result < 0) {
            return error.SendFailed;
        }
        if (result == 0) return error.ConnectionClosed;
    }

    /// Receive data along with a file descriptor using SCM_RIGHTS
    pub fn recvWithFd(self: *Connection, buf: []u8) !struct { len: usize, fd: ?posix.fd_t } {
        var iov: c.struct_iovec = .{
            .iov_base = buf.ptr,
            .iov_len = buf.len,
        };

        // Control message buffer for SCM_RIGHTS - use CMSG_SPACE macro equivalent
        const cmsg_align = comptime @alignOf(c.struct_cmsghdr);
        const cmsg_hdr_size = comptime @sizeOf(c.struct_cmsghdr);
        const cmsg_data_size = comptime @sizeOf(c_int);
        const cmsg_space = comptime std.mem.alignForward(usize, cmsg_hdr_size + cmsg_data_size, cmsg_align);
        var cmsg_buf: [cmsg_space]u8 align(cmsg_align) = undefined;

        var msg: c.struct_msghdr = .{
            .msg_name = null,
            .msg_namelen = 0,
            .msg_iov = &iov,
            .msg_iovlen = 1,
            .msg_control = &cmsg_buf,
            .msg_controllen = cmsg_space,
            .msg_flags = 0,
        };

        const result = c.recvmsg(self.fd, &msg, 0);
        if (result < 0) {
            return error.RecvFailed;
        }
        const len: usize = @intCast(result);
        if (len == 0) return .{ .len = 0, .fd = null };

        // Check if we received a file descriptor
        var received_fd: ?posix.fd_t = null;
        if (msg.msg_controllen >= cmsg_hdr_size) {
            const cmsg: *c.struct_cmsghdr = @ptrCast(@alignCast(msg.msg_control));
            if (cmsg.cmsg_level == c.SOL_SOCKET and cmsg.cmsg_type == c.SCM_RIGHTS) {
                const fd_ptr: *const c_int = @ptrCast(@alignCast(&cmsg_buf[cmsg_hdr_size]));
                received_fd = fd_ptr.*;
            }
        }

        return .{ .len = len, .fd = received_fd };
    }
};

/// SCM_RIGHTS constant for passing file descriptors
const SCM_RIGHTS: c_int = 1;

/// Generate a random UUID (16 bytes as hex string = 32 chars)
pub fn generateUuid() [32]u8 {
    var uuid: [16]u8 = undefined;
    std.crypto.random.bytes(&uuid);

    var hex: [32]u8 = undefined;
    const hex_chars = "0123456789abcdef";
    for (uuid, 0..) |byte, i| {
        hex[i * 2] = hex_chars[byte >> 4];
        hex[i * 2 + 1] = hex_chars[byte & 0x0f];
    }
    return hex;
}

/// Get the socket directory path
pub fn getSocketDir(allocator: std.mem.Allocator) ![]const u8 {
    // Use XDG_RUNTIME_DIR if available, otherwise /tmp
    const runtime_dir = std.posix.getenv("XDG_RUNTIME_DIR") orelse "/tmp";
    return std.fmt.allocPrint(allocator, "{s}/hexa", .{runtime_dir});
}

/// Get the default ses socket path
pub fn getSesSocketPath(allocator: std.mem.Allocator) ![]const u8 {
    const dir = try getSocketDir(allocator);
    defer allocator.free(dir);
    return std.fmt.allocPrint(allocator, "{s}/ses.sock", .{dir});
}

/// Check if ses is running by trying to connect
pub fn isSesRunning(allocator: std.mem.Allocator) bool {
    const path = getSesSocketPath(allocator) catch return false;
    defer allocator.free(path);

    var client = Client.connect(path) catch return false;
    client.close();
    return true;
}

/// Get a mux socket path for a given UUID
pub fn getMuxSocketPath(allocator: std.mem.Allocator, uuid: []const u8) ![]const u8 {
    const dir = try getSocketDir(allocator);
    defer allocator.free(dir);
    return std.fmt.allocPrint(allocator, "{s}/mux-{s}.sock", .{ dir, uuid });
}
