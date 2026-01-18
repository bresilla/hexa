const std = @import("std");
const posix = std.posix;
const core = @import("core");
const ipc = core.ipc;

/// Pane state - minimal, just keeps process alive
pub const PaneState = enum {
    attached, // mux is connected and owns this pane
    half_orphaned, // sticky pwd float, waiting for same pwd+key
    orphaned, // fully detached, any mux can adopt
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

    // Which client owns this pane (null if orphaned)
    attached_to: ?usize,

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

/// Main ses state - the PTY holder
pub const SesState = struct {
    allocator: std.mem.Allocator,
    panes: std.AutoHashMap([32]u8, Pane),
    clients: std.ArrayList(Client),
    next_client_id: usize,
    orphan_timeout_hours: u32,

    pub fn init(allocator: std.mem.Allocator) SesState {
        return .{
            .allocator = allocator,
            .panes = std.AutoHashMap([32]u8, Pane).init(allocator),
            .clients = .empty,
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
            pane.state = .half_orphaned;
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
        sticky_pwd: ?[]const u8,
        sticky_key: ?u8,
    ) !*Pane {
        // Spawn PTY
        const pty = try core.Pty.spawn(shell);

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
            if (pane.state == .half_orphaned) {
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

        // Add to client's pane list
        if (self.getClient(client_id)) |client| {
            try client.appendUuid(uuid);
        }

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
            if (pane.state == .orphaned or pane.state == .half_orphaned) {
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
            if (pane.state == .orphaned or pane.state == .half_orphaned) {
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
