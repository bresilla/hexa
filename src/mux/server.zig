const std = @import("std");
const posix = std.posix;
const Session = @import("session.zig").Session;
const IpcServer = @import("ipc.zig").IpcServer;

pub const Server = struct {
    allocator: std.mem.Allocator,
    session: Session,
    ipc: IpcServer,

    pub fn init(allocator: std.mem.Allocator) !Server {
        return Server{
            .allocator = allocator,
            .session = try Session.init(allocator),
            .ipc = try IpcServer.init(),
        };
    }

    pub fn deinit(self: *Server) void {
        self.session.deinit();
        self.ipc.deinit();
    }

    pub fn run(self: *Server) !void {
        const client_fd = try self.ipc.accept();
        defer _ = posix.close(client_fd);

        var poll_fds = [_]posix.pollfd{
            .{ .fd = client_fd, .events = posix.POLL.IN, .revents = 0 },
            .{ .fd = self.session.activeWindow().activePane().pty.master_fd, .events = posix.POLL.IN, .revents = 0 },
        };

        var buffer: [8192]u8 = undefined;
        var input = @import("input.zig").InputHandler.init();
        var renderer = @import("render.zig").Renderer.init(self.allocator);

        while (true) {
            _ = try posix.poll(&poll_fds, -1);

            if (poll_fds[0].revents & posix.POLL.IN != 0) {
                const bytes = try posix.read(client_fd, &buffer);
                if (bytes == 0) break;

                for (buffer[0..bytes]) |byte| {
                    switch (input.handle(byte)) {
                        .split_h => try self.session.activeWindow().split(),
                        .split_v => try self.session.activeWindow().split(),
                        .next_pane => self.session.activeWindow().nextPane(),
                        .close_pane => self.session.activeWindow().closePane(),
                        .none => _ = try self.session.activeWindow().activePane().write(&[_]u8{byte}),
                    }
                    poll_fds[1].fd = self.session.activeWindow().activePane().pty.master_fd;
                }
            }

            if (poll_fds[1].revents & posix.POLL.IN != 0) {
                const bytes = try self.session.activeWindow().activePane().read(&buffer);
                if (bytes > 0) {
                    _ = try posix.write(client_fd, buffer[0..bytes]);
                }
            }

            if (poll_fds[0].revents & (posix.POLL.ERR | posix.POLL.HUP) != 0) break;

            if (self.session.windows.items.len > 0) {
                const titles = try self.session.windowTitles(self.allocator);
                defer self.allocator.free(titles);
                const tab = try renderer.renderTabBar(titles, self.session.active_index, 80);
                defer self.allocator.free(tab);
                _ = try posix.write(client_fd, tab);
            }
        }
    }
};
