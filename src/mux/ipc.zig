const std = @import("std");
const posix = std.posix;

pub const SocketPath = struct {
    pub fn get() []const u8 {
        return "/tmp/blox-mux.sock";
    }
};

pub const IpcServer = struct {
    fd: posix.fd_t,

    pub fn init() !IpcServer {
        const path = SocketPath.get();
        std.fs.deleteFileAbsolute(path) catch |err| {
            if (err != error.FileNotFound) return err;
        };

        const fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
        const addr = try std.net.Address.initUnix(path);

        try posix.bind(fd, @ptrCast(&addr.any), addr.getOsSockLen());
        try posix.listen(fd, 8);
        return IpcServer{ .fd = fd };
    }

    pub fn accept(self: *IpcServer) !posix.fd_t {
        return posix.accept(self.fd, null, null, 0);
    }

    pub fn deinit(self: *IpcServer) void {
        _ = posix.close(self.fd);
    }
};

pub const IpcClient = struct {
    fd: posix.fd_t,

    pub fn connect() !IpcClient {
        const path = SocketPath.get();
        const fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
        const addr = try std.net.Address.initUnix(path);

        try posix.connect(fd, @ptrCast(&addr.any), addr.getOsSockLen());
        return IpcClient{ .fd = fd };
    }

    pub fn deinit(self: *IpcClient) void {
        _ = posix.close(self.fd);
    }
};
