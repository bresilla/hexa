const std = @import("std");
const posix = std.posix;
const core = @import("core");
const ipc = core.ipc;

/// Pane state - minimal, just keeps process alive
pub const PaneState = enum {
    attached, // mux is connected and owns this pane
    detached, // part of detached session, waiting for reattach
    sticky, // sticky pwd float, waiting for same pwd+key
    orphaned, // fully orphaned, any mux can adopt
};

/// Minimal pane structure - just what's needed to keep process alive
pub const Pane = struct {
    uuid: [32]u8,
    master_fd: posix.fd_t,
    child_pid: posix.pid_t,
    state: PaneState,

    // For sticky pwd floats
    sticky_pwd: ?[]const u8,
    sticky_key: ?u8,

    // Which client owns this pane (null if orphaned/detached)
    attached_to: ?usize,

    // Session ID for detached panes (so they can be reattached together)
    session_id: ?[16]u8,

    // Timestamps
    created_at: i64,
    orphaned_at: ?i64,

    allocator: std.mem.Allocator,

    pub fn deinit(self: *Pane) void {
        if (self.sticky_pwd) |pwd| {
            self.allocator.free(pwd);
        }
    }
};

/// Client connection state
pub const Client = struct {
    id: usize,
    fd: posix.fd_t,
    pane_uuids: std.ArrayList([32]u8),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, id: usize, fd: posix.fd_t) Client {
        return .{
            .id = id,
            .fd = fd,
            .pane_uuids = .empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Client) void {
        self.pane_uuids.deinit(self.allocator);
    }

    pub fn appendUuid(self: *Client, uuid: [32]u8) !void {
        try self.pane_uuids.append(self.allocator, uuid);
    }
};

/// Detached session info (for listing)
pub const DetachedSession = struct {
    session_id: [16]u8,
    pane_count: usize,
};

/// Full detached mux state - stores the entire layout for reattachment
pub const DetachedMuxState = struct {
    session_id: [16]u8,
    mux_state_json: []const u8, // Full serialized mux state
    pane_uuids: [][32]u8, // List of pane UUIDs in this session
    detached_at: i64,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *DetachedMuxState) void {
        self.allocator.free(self.mux_state_json);
        self.allocator.free(self.pane_uuids);
    }
};

/// Main ses state - the PTY holder
pub const SesState = struct {
    allocator: std.mem.Allocator,
    panes: std.AutoHashMap([32]u8, Pane),
    clients: std.ArrayList(Client),
    detached_sessions: std.AutoHashMap([16]u8, DetachedMuxState),
    next_client_id: usize,
    orphan_timeout_hours: u32,

    pub fn init(allocator: std.mem.Allocator) SesState {
        return .{
            .allocator = allocator,
            .panes = std.AutoHashMap([32]u8, Pane).init(allocator),
            .clients = .empty,
            .detached_sessions = std.AutoHashMap([16]u8, DetachedMuxState).init(allocator),
            .next_client_id = 1,
            .orphan_timeout_hours = 24,
        };
    }

    pub fn deinit(self: *SesState) void {
        // Close all panes
        var pane_iter = self.panes.valueIterator();
        while (pane_iter.next()) |pane| {
            posix.close(pane.master_fd);
            // Note: we don't kill processes here, they'll get SIGHUP when fd closes
            var p = pane;
            p.deinit();
        }
        self.panes.deinit();

        // Cleanup detached sessions
        var sess_iter = self.detached_sessions.valueIterator();
        while (sess_iter.next()) |sess| {
            var s = sess;
            s.deinit();
        }
        self.detached_sessions.deinit();

        // Cleanup clients
        for (self.clients.items) |*client| {
            client.deinit();
        }
        self.clients.deinit(self.allocator);
    }

    /// Add a new client connection
    pub fn addClient(self: *SesState, fd: posix.fd_t) !usize {
        const id = self.next_client_id;
        self.next_client_id += 1;

        try self.clients.append(self.allocator, Client.init(self.allocator, id, fd));
        return id;
    }

    /// Remove a client and orphan its panes
    pub fn removeClient(self: *SesState, client_id: usize) void {
        // Find and remove client
        var client_index: ?usize = null;
        for (self.clients.items, 0..) |*client, i| {
            if (client.id == client_id) {
                // Orphan all panes owned by this client
                for (client.pane_uuids.items) |uuid| {
                    if (self.panes.getPtr(uuid)) |pane| {
                        self.orphanPane(pane);
                    }
                }
                client.deinit();
                client_index = i;
                break;
            }
        }

        if (client_index) |idx| {
            _ = self.clients.orderedRemove(idx);
        }
    }

    /// Detach a client's session with a specific session ID (mux's UUID)
    /// Stores the full mux state for later restoration
    /// If the session already exists (re-detach), it updates the existing state
    /// Returns true on success, false if client not found
    pub fn detachSession(self: *SesState, client_id: usize, session_id: [16]u8, mux_state_json: []const u8) bool {
        // Find client
        var client_index: ?usize = null;
        var pane_uuids_list: std.ArrayList([32]u8) = .empty;

        for (self.clients.items, 0..) |*client, i| {
            if (client.id == client_id) {
                // Mark all panes as detached with session_id and collect UUIDs
                for (client.pane_uuids.items) |uuid| {
                    if (self.panes.getPtr(uuid)) |pane| {
                        pane.state = .detached;
                        pane.session_id = session_id;
                        pane.attached_to = null;
                        pane_uuids_list.append(self.allocator, uuid) catch continue;
                    }
                }
                client.deinit();
                client_index = i;
                break;
            }
        }

        if (client_index) |idx| {
            _ = self.clients.orderedRemove(idx);

            // If session already exists (re-detach), remove old state first
            if (self.detached_sessions.fetchRemove(session_id)) |old| {
                var old_state = old.value;
                old_state.deinit();
            }

            // Store the full mux state
            const owned_json = self.allocator.dupe(u8, mux_state_json) catch return true;
            const owned_uuids = pane_uuids_list.toOwnedSlice(self.allocator) catch {
                self.allocator.free(owned_json);
                return true;
            };

            const detached_state = DetachedMuxState{
                .session_id = session_id,
                .mux_state_json = owned_json,
                .pane_uuids = owned_uuids,
                .detached_at = std.time.timestamp(),
                .allocator = self.allocator,
            };

            self.detached_sessions.put(session_id, detached_state) catch {
                self.allocator.free(owned_json);
                self.allocator.free(owned_uuids);
            };

            return true;
        } else {
            pane_uuids_list.deinit(self.allocator);
        }
        return false;
    }

    /// Result of reattaching a session
    pub const ReattachResult = struct {
        mux_state_json: []const u8, // The full mux state to restore
        pane_uuids: [][32]u8, // UUIDs of panes to adopt
    };

    /// Reattach to a detached session - returns mux state and pane UUIDs
    /// Note: Panes remain in "detached" state until adoptPane is called for each
    pub fn reattachSession(self: *SesState, session_id: [16]u8, client_id: usize) !?ReattachResult {
        _ = client_id; // Client will adopt panes individually

        // Find the detached session
        const detached = self.detached_sessions.fetchRemove(session_id) orelse return null;
        const detached_state = detached.value;

        // Clear session_id from panes (they're no longer part of a detached session)
        // But keep them as "detached" state - adoptPane will mark them as attached
        for (detached_state.pane_uuids) |uuid| {
            if (self.panes.getPtr(uuid)) |pane| {
                pane.session_id = null;
            }
        }

        // Return the stored state (caller takes ownership)
        return .{
            .mux_state_json = detached_state.mux_state_json,
            .pane_uuids = detached_state.pane_uuids,
        };
    }

    /// List detached sessions
    pub fn listDetachedSessions(self: *SesState, allocator: std.mem.Allocator) ![]DetachedSession {
        var result: std.ArrayList(DetachedSession) = .empty;
        errdefer result.deinit(allocator);

        var iter = self.detached_sessions.valueIterator();
        while (iter.next()) |detached| {
            try result.append(allocator, .{
                .session_id = detached.session_id,
                .pane_count = detached.pane_uuids.len,
            });
        }

        return result.toOwnedSlice(allocator);
    }

    /// Get client by ID
    pub fn getClient(self: *SesState, client_id: usize) ?*Client {
        for (self.clients.items) |*client| {
            if (client.id == client_id) return client;
        }
        return null;
    }

    /// Orphan a pane (either half or full depending on sticky)
    fn orphanPane(self: *SesState, pane: *Pane) void {
        _ = self;
        const now = std.time.timestamp();

        if (pane.sticky_pwd != null and pane.sticky_key != null) {
            // Sticky pwd float - becomes half-orphaned
            pane.state = .sticky;
        } else {
            // Regular pane - becomes fully orphaned
            pane.state = .orphaned;
        }

        pane.attached_to = null;
        pane.orphaned_at = now;
    }

    /// Create a new pane with PTY
    pub fn createPane(
        self: *SesState,
        client_id: usize,
        shell: []const u8,
        cwd: ?[]const u8,
        sticky_pwd: ?[]const u8,
        sticky_key: ?u8,
    ) !*Pane {
        // Spawn PTY with optional working directory
        const pty = try core.Pty.spawnWithCwd(shell, cwd);

        // Generate UUID
        const uuid = ipc.generateUuid();

        // Copy sticky_pwd if provided
        const owned_pwd: ?[]const u8 = if (sticky_pwd) |pwd|
            try self.allocator.dupe(u8, pwd)
        else
            null;

        const now = std.time.timestamp();

        const pane = Pane{
            .uuid = uuid,
            .master_fd = pty.master_fd,
            .child_pid = pty.child_pid,
            .state = .attached,
            .sticky_pwd = owned_pwd,
            .sticky_key = sticky_key,
            .attached_to = client_id,
            .session_id = null,
            .created_at = now,
            .orphaned_at = null,
            .allocator = self.allocator,
        };

        try self.panes.put(uuid, pane);

        // Add to client's pane list
        if (self.getClient(client_id)) |client| {
            try client.appendUuid(uuid);
        }

        return self.panes.getPtr(uuid).?;
    }

    /// Find a half-orphaned sticky pane matching pwd and key
    pub fn findStickyPane(self: *SesState, pwd: []const u8, key: u8) ?*Pane {
        var iter = self.panes.valueIterator();
        while (iter.next()) |pane| {
            if (pane.state == .sticky) {
                if (pane.sticky_pwd) |spwd| {
                    if (pane.sticky_key) |skey| {
                        if (skey == key and std.mem.eql(u8, spwd, pwd)) {
                            return @constCast(pane);
                        }
                    }
                }
            }
        }
        return null;
    }

    /// Attach an orphaned pane to a client
    pub fn attachPane(self: *SesState, uuid: [32]u8, client_id: usize) !*Pane {
        const pane = self.panes.getPtr(uuid) orelse return error.PaneNotFound;

        if (pane.state == .attached) {
            return error.PaneAlreadyAttached;
        }

        pane.state = .attached;
        pane.attached_to = client_id;
        pane.orphaned_at = null;

        // Add to client's pane list - fail if client not found
        const client = self.getClient(client_id) orelse return error.ClientNotFound;
        try client.appendUuid(uuid);

        return pane;
    }

    /// Manually orphan a pane (user requested suspend)
    pub fn suspendPane(self: *SesState, uuid: [32]u8) !void {
        const pane = self.panes.getPtr(uuid) orelse return error.PaneNotFound;

        // Remove from client's list
        if (pane.attached_to) |client_id| {
            if (self.getClient(client_id)) |client| {
                var i: usize = 0;
                while (i < client.pane_uuids.items.len) {
                    if (std.mem.eql(u8, &client.pane_uuids.items[i], &uuid)) {
                        _ = client.pane_uuids.orderedRemove(i);
                    } else {
                        i += 1;
                    }
                }
            }
        }

        // Manual suspend = fully orphaned (even if sticky)
        pane.state = .orphaned;
        pane.attached_to = null;
        pane.orphaned_at = std.time.timestamp();
    }

    /// Kill a pane
    pub fn killPane(self: *SesState, uuid: [32]u8) !void {
        var pane = self.panes.fetchRemove(uuid) orelse return error.PaneNotFound;

        // Close fd (sends SIGHUP to process)
        posix.close(pane.value.master_fd);

        // Clean up
        pane.value.deinit();
    }

    /// Get all orphaned panes
    pub fn getOrphanedPanes(self: *SesState, allocator: std.mem.Allocator) ![]Pane {
        var result: std.ArrayList(Pane) = .empty;
        errdefer result.deinit(allocator);

        var iter = self.panes.valueIterator();
        while (iter.next()) |pane| {
            if (pane.state == .orphaned or pane.state == .sticky) {
                try result.append(allocator, pane.*);
            }
        }

        return result.toOwnedSlice(allocator);
    }

    /// Clean up timed-out orphaned panes
    pub fn cleanupOrphanedPanes(self: *SesState) void {
        const now = std.time.timestamp();
        const timeout_secs = @as(i64, @intCast(self.orphan_timeout_hours)) * 3600;

        var to_remove: std.ArrayList([32]u8) = .empty;
        defer to_remove.deinit(self.allocator);

        var iter = self.panes.iterator();
        while (iter.next()) |entry| {
            const pane = entry.value_ptr;
            if (pane.state == .orphaned or pane.state == .sticky) {
                if (pane.orphaned_at) |orphaned_time| {
                    if (now - orphaned_time > timeout_secs) {
                        to_remove.append(self.allocator, entry.key_ptr.*) catch continue;
                    }
                }
            }
        }

        for (to_remove.items) |uuid| {
            self.killPane(uuid) catch {};
        }
    }

    /// Check if a pane's process is still alive
    pub fn checkPaneAlive(self: *SesState, uuid: [32]u8) bool {
        const pane = self.panes.get(uuid) orelse return false;

        // Try non-blocking waitpid
        const result = posix.waitpid(pane.child_pid, posix.W.NOHANG);
        return result.pid == 0; // 0 means still running
    }

    /// Get pane by UUID
    pub fn getPane(self: *SesState, uuid: [32]u8) ?*Pane {
        return self.panes.getPtr(uuid);
    }
};
