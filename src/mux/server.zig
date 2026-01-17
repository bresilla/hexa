const std = @import("std");
const posix = std.posix;
const Session = @import("session.zig").Session;
const IpcServer = @import("ipc.zig").IpcServer;

pub const Server = struct {
    allocator: std.mem.Allocator,
    session_manager: @import("session_manager.zig").SessionManager,
    ipc: IpcServer,

    pub fn init(allocator: std.mem.Allocator) !Server {
        var session_manager = @import("session_manager.zig").SessionManager.init(allocator);
        try session_manager.createSession("default");
        return Server{
            .allocator = allocator,
            .session_manager = session_manager,
            .ipc = try IpcServer.init(),
        };
    }

    pub fn deinit(self: *Server) void {
        self.session_manager.deinit();
        self.ipc.deinit();
    }

    pub fn run(self: *Server) !void {
        const client_fd = try self.ipc.accept();
        defer _ = posix.close(client_fd);

        var poll_fds = [_]posix.pollfd{
            .{ .fd = client_fd, .events = posix.POLL.IN, .revents = 0 },
            .{ .fd = self.session_manager.activeSession().activeWindow().activePane().pty.master_fd, .events = posix.POLL.IN, .revents = 0 },
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
                    const session = self.session_manager.activeSession();
                    switch (input.handle(byte)) {
                        .split_h => try session.activeWindow().split(),
                        .split_v => try session.activeWindow().split(),
                        .next_pane => session.activeWindow().nextPane(),
                        .close_pane => session.activeWindow().closePane(),
                        .next_window => session.nextWindow(),
                        .prev_window => session.prevWindow(),
                        .new_window => try session.addWindow(),
                        .new_session => try self.session_manager.createSession(try self.generateSessionName()),
                        .new_float => try session.activeWindow().addFloating(40, 10),
                        .close_float => session.activeWindow().closeFloating(),
                        .list_sessions => {
                            const session_list = try self.session_manager.listSessions(self.allocator);
                            defer {
                                for (session_list) |s| self.allocator.free(s);
                                self.allocator.free(session_list);
                            }
                            for (session_list) |s| {
                                _ = try posix.write(client_fd, s);
                                _ = try posix.write(client_fd, "\n");
                            }
                        },
                        .switch_session => if (input.getSwitchSessionIndex()) |idx| {
                            if (self.session_manager.attachSession(idx - 1)) {
                                const msg = try std.fmt.allocPrint(self.allocator, "\nSwitched to session {d}\n", .{idx});
                                defer self.allocator.free(msg);
                                _ = try posix.write(client_fd, msg);
                            }
                        },
                        .none => _ = try session.activeWindow().activePane().write(&[_]u8{byte}),
                    }
                    if (session.activeWindow().activeFloatingPane()) |float| {
                        poll_fds[1].fd = float.pty.master_fd;
                    } else {
                        poll_fds[1].fd = session.activeWindow().activePane().pty.master_fd;
                    }
                }
            }

            if (poll_fds[1].revents & posix.POLL.IN != 0) {
                const bytes_read: usize = blk: {
                    const session = self.session_manager.activeSession();
                    if (session.activeWindow().activeFloatingPane()) |float| {
                        break :blk try float.read(&buffer);
                    } else {
                        break :blk try session.activeWindow().activePane().read(&buffer);
                    }
                };
                if (bytes_read > 0) {
                    _ = try posix.write(client_fd, buffer[0..bytes_read]);
                }
            }

            if (poll_fds[0].revents & (posix.POLL.ERR | posix.POLL.HUP) != 0) break;

            const session = self.session_manager.activeSession();
            if (session.windows.items.len > 0) {
                const titles = try session.windowTitles(self.allocator);
                defer self.allocator.free(titles);
                const tab = try renderer.renderTabBar(titles, session.active_index, 80);
                defer self.allocator.free(tab);
                _ = try posix.write(client_fd, tab);
            }
        }
    }

    fn generateSessionName(self: *Server) ![]const u8 {
        return std.fmt.allocPrint(self.allocator, "session-{d}", .{self.session_manager.sessionCount() + 1});
    }
};
