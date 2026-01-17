const std = @import("std");
const posix = std.posix;
const Session = @import("session.zig").Session;
const IpcServer = @import("ipc.zig").IpcServer;
const ResizeHandler = @import("resize.zig").MouseResizeHandler;

const c = @cImport({
    @cInclude("sys/ioctl.h");
});

pub const Server = struct {
    allocator: std.mem.Allocator,
    session_manager: @import("session_manager.zig").SessionManager,
    ipc: IpcServer,
    resize_handler: ResizeHandler,
    client_fd: ?posix.fd_t = null,
    last_window_index: ?usize = null,
    last_window_count: usize = 0,
    term_width: u16 = 80,
    term_height: u16 = 24,

    pub fn init(allocator: std.mem.Allocator) !Server {
        var session_manager = @import("session_manager.zig").SessionManager.init(allocator);
        try session_manager.createSession("default");
        return Server{
            .allocator = allocator,
            .session_manager = session_manager,
            .ipc = try IpcServer.init(),
            .resize_handler = ResizeHandler.init(allocator),
        };
    }

    pub fn deinit(self: *Server) void {
        if (self.client_fd) |fd| {
            _ = posix.close(fd);
        }
        self.session_manager.deinit();
        self.ipc.deinit();
    }

    pub fn run(self: *Server) !void {
        // Accept clients in a loop - server stays alive when client detaches
        while (true) {
            const client_fd = self.ipc.accept() catch |err| {
                if (err == error.WouldBlock) continue;
                return err;
            };
            self.client_fd = client_fd;
            self.last_window_index = null;
            self.last_window_count = 0;

            self.handleClient(client_fd) catch |err| {
                // Client disconnected - continue accepting
                if (err == error.BrokenPipe or err == error.ConnectionResetByPeer) {
                    _ = posix.close(client_fd);
                    self.client_fd = null;
                    continue;
                }
                return err;
            };

            _ = posix.close(client_fd);
            self.client_fd = null;
        }
    }

    fn handleClient(self: *Server, client_fd: posix.fd_t) !void {

        // Enable mouse tracking
        _ = try posix.write(client_fd, "\x1b[?1000h");
        _ = try posix.write(client_fd, "\x1b[?1002h");
        _ = try posix.write(client_fd, "\x1b[?1006h");
        defer {
            _ = posix.write(client_fd, "\x1b[?1000l") catch {};
            _ = posix.write(client_fd, "\x1b[?1002l") catch {};
            _ = posix.write(client_fd, "\x1b[?1006l") catch {};
        }

        var poll_fds = [_]posix.pollfd{
            .{ .fd = client_fd, .events = posix.POLL.IN, .revents = 0 },
            .{ .fd = self.session_manager.activeSession().activeWindow().activePane().pty.master_fd, .events = posix.POLL.IN, .revents = 0 },
        };

        var buffer: [8192]u8 = undefined;
        var input = @import("input.zig").InputHandler.init();
        var renderer = @import("render.zig").Renderer.init(self.allocator);

        while (true) {
            // Use a short timeout to periodically check for resize
            _ = try posix.poll(&poll_fds, 100);

            // Check for terminal resize
            self.checkResize();

            if (poll_fds[0].revents & posix.POLL.IN != 0) {
                const bytes = try posix.read(client_fd, &buffer);
                if (bytes == 0) break;

                // Check for mouse events first
                const mouse_result = self.resize_handler.handle(buffer[0..bytes], self.session_manager.activeSession().activeWindow().panes.items.len);
                if (mouse_result != .none) {
                    // Mouse resize detected - for now just reset state
                    // Full resize implementation would update pane dimensions
                }

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
                        .detach => {
                            _ = try posix.write(client_fd, "\r\n[detached]\r\n");
                            return; // Exit handleClient, client will be closed and server continues
                        },
                        .scroll_up => {
                            session.activeWindow().activePane().scrollUp(1);
                        },
                        .scroll_down => {
                            session.activeWindow().activePane().scrollDown(1);
                        },
                        .scroll_page_up => {
                            session.activeWindow().activePane().scrollUp(self.term_height / 2);
                        },
                        .scroll_page_down => {
                            session.activeWindow().activePane().scrollDown(self.term_height / 2);
                        },
                        .scroll_top => {
                            const pane = session.activeWindow().activePane();
                            pane.scrollback.scroll_offset = pane.scrollback.lineCount() -| 1;
                            pane.in_scroll_mode = true;
                        },
                        .scroll_bottom => {
                            session.activeWindow().activePane().exitScrollMode();
                        },
                        .zoom_pane => {
                            const window = session.activeWindow();
                            window.toggleZoom();
                            window.resizePanes(self.term_width, self.term_height);
                            // Clear screen and redraw
                            _ = try posix.write(client_fd, "\x1b[2J\x1b[H");
                            if (window.isZoomed()) {
                                _ = try posix.write(client_fd, "\x1b[7m[ZOOMED]\x1b[0m ");
                            }
                        },
                        .copy_mode => {
                            const pane = session.activeWindow().activePane();
                            pane.enterCopyMode();
                            _ = try posix.write(client_fd, "\x1b7\x1b[1;1H\x1b[7m[copy mode: hjkl move, Space select, y copy, q exit]\x1b[0m\x1b8");
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

            // Efficient tab bar rendering - only render on window/session change
            const session = self.session_manager.activeSession();
            const window_count = session.windows.items.len;
            const window_index = session.active_index;

            if (window_count > 0 and (self.last_window_index != window_index or self.last_window_count != window_count)) {
                self.last_window_index = window_index;
                self.last_window_count = window_count;

                const titles = try session.windowTitles(self.allocator);
                defer self.allocator.free(titles);
                const tab = try renderer.renderTabBar(titles, session.active_index, self.term_width);
                defer self.allocator.free(tab);
                _ = try posix.write(client_fd, tab);
            }
        }
    }

    pub fn updateTerminalSize(self: *Server, width: u16, height: u16) void {
        self.term_width = width;
        self.term_height = height;

        // Propagate to all panes in all sessions
        for (self.session_manager.sessions.items) |*session| {
            for (session.windows.items) |*window| {
                window.resizePanes(width, height);
            }
        }
    }

    // Check if terminal was resized and handle it
    pub fn checkResize(self: *Server) void {
        const core = @import("core");
        const size = core.TermSize.fromStdout();
        if (size.cols != self.term_width or size.rows != self.term_height) {
            self.updateTerminalSize(size.cols, size.rows);
        }
    }

    fn generateSessionName(self: *Server) ![]const u8 {
        return std.fmt.allocPrint(self.allocator, "session-{d}", .{self.session_manager.sessionCount() + 1});
    }
};
