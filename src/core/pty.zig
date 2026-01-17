const std = @import("std");
const posix = std.posix;
const c = @cImport({
    @cInclude("pty.h");
    @cInclude("unistd.h");
    @cInclude("stdlib.h");
});

pub const Pty = struct {
    master_fd: posix.fd_t,
    child_pid: posix.pid_t,

    pub fn spawn(shell: []const u8) !Pty {
        var master_fd: c_int = 0;
        var slave_fd: c_int = 0;

        if (c.openpty(&master_fd, &slave_fd, null, null, null) != 0) {
            return error.OpenPtyFailed;
        }

        const pid = try posix.fork();
        if (pid == 0) {
            _ = posix.setsid() catch posix.exit(1);

            posix.dup2(@intCast(slave_fd), posix.STDIN_FILENO) catch posix.exit(1);
            posix.dup2(@intCast(slave_fd), posix.STDOUT_FILENO) catch posix.exit(1);
            posix.dup2(@intCast(slave_fd), posix.STDERR_FILENO) catch posix.exit(1);
            _ = posix.close(@intCast(slave_fd));
            _ = posix.close(@intCast(master_fd));

            const shell_z = std.heap.c_allocator.dupeZ(u8, shell) catch posix.exit(1);
            var argv = [_:null]?[*:0]const u8{ shell_z, null };
            var envp = [_:null]?[*:0]const u8{null};

            posix.execvpeZ(shell_z, &argv, &envp) catch posix.exit(1);
            unreachable;
        }

        _ = posix.close(@intCast(slave_fd));

        return Pty{
            .master_fd = @intCast(master_fd),
            .child_pid = pid,
        };
    }

    pub fn read(self: Pty, buffer: []u8) !usize {
        return posix.read(self.master_fd, buffer);
    }

    pub fn write(self: Pty, data: []const u8) !usize {
        return posix.write(self.master_fd, data);
    }

    pub fn pollStatus(self: Pty) ?u32 {
        const result = posix.waitpid(self.child_pid, posix.W.NOHANG);
        if (result.pid == 0) return null;
        return result.status;
    }

    pub fn close(self: Pty) void {
        _ = posix.close(self.master_fd);
        _ = posix.waitpid(self.child_pid, 0);
    }
};
