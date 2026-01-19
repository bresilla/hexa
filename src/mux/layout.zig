const std = @import("std");
const posix = std.posix;
const core = @import("core");
const Pane = @import("pane.zig").Pane;
const SesClient = @import("ses_client.zig").SesClient;

/// Direction of a split
pub const SplitDir = enum {
    horizontal, // side by side (left | right)
    vertical, // stacked (top / bottom)
};

/// A node in the layout tree - either a pane or a split
pub const LayoutNode = union(enum) {
    pane: u16, // pane id
    split: Split,

    pub const Split = struct {
        dir: SplitDir,
        ratio: f32, // 0.0 to 1.0, position of divider
        first: *LayoutNode,
        second: *LayoutNode,
    };
};

/// Layout manager - handles pane arrangement via binary tree
pub const Layout = struct {
    allocator: std.mem.Allocator,
    root: ?*LayoutNode,
    panes: std.AutoHashMap(u16, *Pane),
    next_pane_id: u16,
    focused_pane_id: u16,
    // Usable area (excluding status bar)
    x: u16,
    y: u16,
    width: u16,
    height: u16,
    // Optional ses client for pane creation
    ses_client: ?*SesClient,
    // Optional pane notification config
    pane_notification_cfg: ?*const core.NotificationStyleConfig,

    pub fn init(allocator: std.mem.Allocator, width: u16, height: u16) Layout {
        return .{
            .allocator = allocator,
            .root = null,
            .panes = std.AutoHashMap(u16, *Pane).init(allocator),
            .next_pane_id = 0,
            .focused_pane_id = 0,
            .x = 0,
            .y = 0,
            .width = width,
            .height = height,
            .ses_client = null,
            .pane_notification_cfg = null,
        };
    }

    /// Set the ses client for pane creation
    pub fn setSesClient(self: *Layout, client: *SesClient) void {
        self.ses_client = client;
    }

    /// Set the pane notification config
    pub fn setPaneNotificationConfig(self: *Layout, cfg: *const core.NotificationStyleConfig) void {
        self.pane_notification_cfg = cfg;
    }

    /// Apply notification config to a pane
    fn configurePaneNotifications(self: *Layout, pane: *Pane) void {
        if (self.pane_notification_cfg) |cfg| {
            pane.configureNotifications(cfg);
        }
    }

    pub fn deinit(self: *Layout) void {
        // Deinit all panes (don't kill in ses - caller handles that)
        var it = self.panes.valueIterator();
        while (it.next()) |pane_ptr| {
            pane_ptr.*.deinit();
            self.allocator.destroy(pane_ptr.*);
        }
        self.panes.deinit();

        // Free layout nodes
        if (self.root) |root| {
            self.freeNode(root);
        }
    }

    fn freeNode(self: *Layout, node: *LayoutNode) void {
        switch (node.*) {
            .pane => {},
            .split => |split| {
                self.freeNode(split.first);
                self.freeNode(split.second);
            },
        }
        self.allocator.destroy(node);
    }

    /// Create the first pane
    pub fn createFirstPane(self: *Layout, cwd: ?[]const u8) !*Pane {
        const id = self.next_pane_id;
        self.next_pane_id += 1;

        const pane = try self.allocator.create(Pane);
        errdefer self.allocator.destroy(pane);

        // Try to create pane via ses if available
        if (self.ses_client) |ses| {
            if (ses.isConnected()) {
                const result = ses.createPane(null, cwd, null, null) catch {
                    // Fall back to local spawn
                    try pane.init(self.allocator, id, self.x, self.y, self.width, self.height);
                    pane.focused = true;
                    self.focused_pane_id = id;
                    try self.panes.put(id, pane);
                    self.configurePaneNotifications(pane);
                    const node = try self.allocator.create(LayoutNode);
                    node.* = .{ .pane = id };
                    self.root = node;
                    return pane;
                };

                // Use fd from ses
                try pane.initWithFd(self.allocator, id, self.x, self.y, self.width, self.height, result.fd, result.pid, result.uuid);
                pane.focused = true;
                self.focused_pane_id = id;
                try self.panes.put(id, pane);
                self.configurePaneNotifications(pane);
                const node = try self.allocator.create(LayoutNode);
                node.* = .{ .pane = id };
                self.root = node;
                return pane;
            }
        }

        // Fall back to local PTY spawn
        try pane.init(self.allocator, id, self.x, self.y, self.width, self.height);

        pane.focused = true;
        self.focused_pane_id = id;

        try self.panes.put(id, pane);
        self.configurePaneNotifications(pane);

        const node = try self.allocator.create(LayoutNode);
        node.* = .{ .pane = id };
        self.root = node;

        return pane;
    }

    /// Split the focused pane
    pub fn splitFocused(self: *Layout, dir: SplitDir, cwd: ?[]const u8) !?*Pane {
        if (self.root == null) return null;

        const focused = self.getFocusedPane() orelse return null;
        const old_id = focused.id;

        // Create new pane
        const new_id = self.next_pane_id;
        self.next_pane_id += 1;

        const new_pane = try self.allocator.create(Pane);
        errdefer self.allocator.destroy(new_pane);

        // Calculate new sizes based on split direction
        const new_width = if (dir == .horizontal) focused.width / 2 else focused.width;
        const new_height = if (dir == .vertical) focused.height / 2 else focused.height;
        const new_x = if (dir == .horizontal) focused.x + focused.width - new_width else focused.x;
        const new_y = if (dir == .vertical) focused.y + focused.height - new_height else focused.y;

        // Try to create pane via ses if available
        if (self.ses_client) |ses| {
            if (ses.isConnected()) {
                if (ses.createPane(null, cwd, null, null)) |result| {
                    try new_pane.initWithFd(self.allocator, new_id, new_x, new_y, new_width, new_height, result.fd, result.pid, result.uuid);
                } else |_| {
                    // Fall back to local spawn
                    try new_pane.init(self.allocator, new_id, new_x, new_y, new_width, new_height);
                }
            } else {
                try new_pane.init(self.allocator, new_id, new_x, new_y, new_width, new_height);
            }
        } else {
            try new_pane.init(self.allocator, new_id, new_x, new_y, new_width, new_height);
        }
        errdefer new_pane.deinit();

        try self.panes.put(new_id, new_pane);
        self.configurePaneNotifications(new_pane);

        // Find and replace the node containing the focused pane
        const node_to_split = self.findNode(self.root.?, old_id) orelse return null;

        // Create new split node
        const first_node = try self.allocator.create(LayoutNode);
        first_node.* = .{ .pane = old_id };

        const second_node = try self.allocator.create(LayoutNode);
        second_node.* = .{ .pane = new_id };

        node_to_split.* = .{
            .split = .{
                .dir = dir,
                .ratio = 0.5,
                .first = first_node,
                .second = second_node,
            },
        };

        // Recalculate all pane positions
        self.recalculateLayout();

        // Focus the new pane (like tmux behavior)
        focused.focused = false;
        new_pane.focused = true;
        self.focused_pane_id = new_id;

        return new_pane;
    }

    fn findNode(self: *Layout, node: *LayoutNode, pane_id: u16) ?*LayoutNode {
        switch (node.*) {
            .pane => |id| {
                if (id == pane_id) return node;
                return null;
            },
            .split => |split| {
                if (self.findNode(split.first, pane_id)) |found| return found;
                if (self.findNode(split.second, pane_id)) |found| return found;
                return null;
            },
        }
    }

    /// Recalculate all pane positions based on layout tree
    pub fn recalculateLayout(self: *Layout) void {
        if (self.root) |root| {
            self.layoutNode(root, self.x, self.y, self.width, self.height);
        }
    }

    fn layoutNode(self: *Layout, node: *LayoutNode, x: u16, y: u16, w: u16, h: u16) void {
        switch (node.*) {
            .pane => |id| {
                if (self.panes.get(id)) |pane| {
                    pane.resize(x, y, w, h) catch {};
                }
            },
            .split => |split| {
                switch (split.dir) {
                    .horizontal => {
                        const first_w = @as(u16, @intFromFloat(@as(f32, @floatFromInt(w)) * split.ratio)) -| 1;
                        const second_w = w -| first_w -| 1; // -1 for border
                        self.layoutNode(split.first, x, y, first_w, h);
                        self.layoutNode(split.second, x + first_w + 1, y, second_w, h);
                    },
                    .vertical => {
                        const first_h = @as(u16, @intFromFloat(@as(f32, @floatFromInt(h)) * split.ratio)) -| 1;
                        const second_h = h -| first_h -| 1; // -1 for border
                        self.layoutNode(split.first, x, y, w, first_h);
                        self.layoutNode(split.second, x, y + first_h + 1, w, second_h);
                    },
                }
            },
        }
    }

    /// Resize the entire layout area
    pub fn resize(self: *Layout, width: u16, height: u16) void {
        self.width = width;
        self.height = height;
        self.recalculateLayout();
    }

    /// Get focused pane
    pub fn getFocusedPane(self: *Layout) ?*Pane {
        return self.panes.get(self.focused_pane_id);
    }

    /// Focus next pane
    pub fn focusNext(self: *Layout) void {
        if (self.panes.count() <= 1) return;

        if (self.getFocusedPane()) |current| {
            current.focused = false;
        }

        // Get all pane IDs and find next
        var ids: std.ArrayList(u16) = .empty;
        defer ids.deinit(self.allocator);

        var it = self.panes.keyIterator();
        while (it.next()) |id| {
            ids.append(self.allocator, id.*) catch continue;
        }

        std.mem.sort(u16, ids.items, {}, std.sort.asc(u16));

        for (ids.items, 0..) |id, i| {
            if (id == self.focused_pane_id) {
                const next_idx = (i + 1) % ids.items.len;
                self.focused_pane_id = ids.items[next_idx];
                break;
            }
        }

        if (self.getFocusedPane()) |new_focus| {
            new_focus.focused = true;
        }
    }

    /// Focus previous pane
    pub fn focusPrev(self: *Layout) void {
        if (self.panes.count() <= 1) return;

        if (self.getFocusedPane()) |current| {
            current.focused = false;
        }

        var ids: std.ArrayList(u16) = .empty;
        defer ids.deinit(self.allocator);

        var it = self.panes.keyIterator();
        while (it.next()) |id| {
            ids.append(self.allocator, id.*) catch continue;
        }

        std.mem.sort(u16, ids.items, {}, std.sort.asc(u16));

        for (ids.items, 0..) |id, i| {
            if (id == self.focused_pane_id) {
                const prev_idx = if (i == 0) ids.items.len - 1 else i - 1;
                self.focused_pane_id = ids.items[prev_idx];
                break;
            }
        }

        if (self.getFocusedPane()) |new_focus| {
            new_focus.focused = true;
        }
    }

    /// Close the focused pane
    pub fn closeFocused(self: *Layout) bool {
        if (self.panes.count() <= 1) return false;

        const id_to_close = self.focused_pane_id;

        // Focus next before removing
        self.focusNext();

        // Remove pane
        if (self.panes.fetchRemove(id_to_close)) |kv| {
            // Tell ses to kill the pane
            if (self.ses_client) |ses| {
                ses.killPane(kv.value.uuid) catch {};
            }
            kv.value.deinit();
            self.allocator.destroy(kv.value);
        }

        // Remove from layout tree and restructure
        if (self.root) |root| {
            self.removeFromTree(root, null, id_to_close);
        }

        self.recalculateLayout();
        return true;
    }

    fn removeFromTree(self: *Layout, node: *LayoutNode, parent: ?*LayoutNode, pane_id: u16) void {
        switch (node.*) {
            .pane => |id| {
                if (id == pane_id and parent != null) {
                    // This is handled by the parent split case
                }
            },
            .split => |split| {
                // Check if either child is the pane to remove
                switch (split.first.*) {
                    .pane => |id| {
                        if (id == pane_id) {
                            // Replace this split with second child
                            const second = split.second.*;
                            self.allocator.destroy(split.first);
                            self.allocator.destroy(split.second);
                            node.* = second;
                            return;
                        }
                    },
                    else => {},
                }
                switch (split.second.*) {
                    .pane => |id| {
                        if (id == pane_id) {
                            // Replace this split with first child
                            const first = split.first.*;
                            self.allocator.destroy(split.first);
                            self.allocator.destroy(split.second);
                            node.* = first;
                            return;
                        }
                    },
                    else => {},
                }
                // Recurse
                self.removeFromTree(split.first, node, pane_id);
                self.removeFromTree(split.second, node, pane_id);
            },
        }
    }

    /// Get iterator over all panes
    pub fn paneIterator(self: *Layout) std.AutoHashMap(u16, *Pane).ValueIterator {
        return self.panes.valueIterator();
    }

    /// Get pane count
    pub fn paneCount(self: *Layout) usize {
        return self.panes.count();
    }

    /// Get index of focused pane in iteration order
    pub fn getFocusedIndex(self: *Layout) usize {
        var ids: [16]u16 = undefined;
        var count: usize = 0;

        var it = self.panes.keyIterator();
        while (it.next()) |id| {
            if (count < 16) {
                ids[count] = id.*;
                count += 1;
            }
        }

        // Sort to get consistent order
        std.mem.sort(u16, ids[0..count], {}, std.sort.asc(u16));

        for (ids[0..count], 0..) |id, i| {
            if (id == self.focused_pane_id) return i;
        }

        return 0;
    }
};
