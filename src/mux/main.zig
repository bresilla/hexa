const std = @import("std");
const posix = std.posix;
const core = @import("core");
const pop = @import("pop");

const Pane = @import("pane.zig").Pane;
const layout_mod = @import("layout.zig");
const Layout = layout_mod.Layout;
const LayoutNode = layout_mod.LayoutNode;
const SplitDir = @import("layout.zig").SplitDir;
const render = @import("render.zig");
const Renderer = render.Renderer;
const ses_client = @import("ses_client.zig");
const SesClient = ses_client.SesClient;
const OrphanedPaneInfo = ses_client.OrphanedPaneInfo;
const notification = @import("notification.zig");
const NotificationManager = notification.NotificationManager;

const c = @cImport({
    @cInclude("sys/ioctl.h");
    @cInclude("stdlib.h");
});

/// A tab contains a layout with panes
const Tab = struct {
    layout: Layout,
    name: []const u8,

    fn init(allocator: std.mem.Allocator, width: u16, height: u16, name: []const u8) Tab {
        return .{
            .layout = Layout.init(allocator, width, height),
            .name = name,
        };
    }

    fn deinit(self: *Tab) void {
        self.layout.deinit();
    }
};

const State = struct {
    allocator: std.mem.Allocator,
    config: core.Config,
    tabs: std.ArrayList(Tab),
    active_tab: usize,
    floating_panes: std.ArrayList(*Pane),
    active_floating: ?usize,
    running: bool,
    detach_mode: bool,
    needs_render: bool,
    force_full_render: bool,
    term_width: u16,
    term_height: u16,
    status_height: u16,
    layout_width: u16,
    layout_height: u16,
    renderer: Renderer,
    ses_client: SesClient,
    notifications: NotificationManager,
    uuid: [32]u8,
    session_name: []const u8,
    session_name_owned: ?[]const u8, // If set, points to owned memory that must be freed
    ipc_server: ?core.ipc.Server,
    socket_path: ?[]const u8,

    fn init(allocator: std.mem.Allocator, width: u16, height: u16) !State {
        const cfg = core.Config.load(allocator);
        const status_h: u16 = if (cfg.panes.status.enabled) 1 else 0;
        const layout_h = height - status_h;

        // Generate UUID and session name for this mux instance
        const uuid = core.ipc.generateUuid();
        const session_name = core.ipc.generateSessionName();

        // Create IPC server socket
        const socket_path = core.ipc.getMuxSocketPath(allocator, &uuid) catch null;
        var ipc_server: ?core.ipc.Server = null;
        if (socket_path) |path| {
            ipc_server = core.ipc.Server.init(allocator, path) catch null;
        }

        return .{
            .allocator = allocator,
            .config = cfg,
            .tabs = .empty,
            .active_tab = 0,
            .floating_panes = .empty,
            .active_floating = null,
            .running = true,
            .detach_mode = false,
            .needs_render = true,
            .force_full_render = true,
            .term_width = width,
            .term_height = height,
            .status_height = status_h,
            .layout_width = width,
            .layout_height = layout_h,
            .renderer = try Renderer.init(allocator, width, height),
            .ses_client = SesClient.init(allocator, uuid, session_name, true), // keepalive=true by default
            .notifications = NotificationManager.initWithConfig(allocator, cfg.notifications.mux),
            .uuid = uuid,
            .session_name = session_name,
            .session_name_owned = null,
            .ipc_server = ipc_server,
            .socket_path = socket_path,
        };
    }

    fn deinit(self: *State) void {
        // Deinit floating panes
        for (self.floating_panes.items) |pane| {
            // In detach mode, panes are already handled by ses - don't kill
            // Otherwise: sticky floats become sticky in ses, non-sticky get killed
            if (!self.detach_mode and self.ses_client.isConnected()) {
                if (pane.sticky) {
                    // Sticky floats persist as sticky panes in ses
                    self.ses_client.orphanPane(pane.uuid) catch {};
                } else {
                    self.ses_client.killPane(pane.uuid) catch {};
                }
            }
            pane.deinit();
            self.allocator.destroy(pane);
        }
        self.floating_panes.deinit(self.allocator);

        // Deinit all tabs - kill panes in ses if not detaching
        for (self.tabs.items) |*tab| {
            if (!self.detach_mode and self.ses_client.isConnected()) {
                var pane_it = tab.layout.panes.valueIterator();
                while (pane_it.next()) |pane_ptr| {
                    self.ses_client.killPane(pane_ptr.*.uuid) catch {};
                }
            }
            tab.deinit();
        }
        self.tabs.deinit(self.allocator);
        self.config.deinit();
        self.renderer.deinit();
        self.ses_client.deinit();
        self.notifications.deinit();
        if (self.ipc_server) |*srv| {
            srv.deinit();
        }
        if (self.socket_path) |path| {
            self.allocator.free(path);
        }
        if (self.session_name_owned) |owned| {
            self.allocator.free(owned);
        }
    }

    /// Get the current tab's layout
    fn currentLayout(self: *State) *Layout {
        return &self.tabs.items[self.active_tab].layout;
    }

    /// Create a new tab with one pane
    fn createTab(self: *State) !void {
        // Get cwd from currently focused pane, or use mux's cwd for first tab
        var cwd: ?[]const u8 = null;
        var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
        if (self.tabs.items.len > 0) {
            if (self.currentLayout().getFocusedPane()) |focused| {
                cwd = focused.getRealCwd();
            }
        } else {
            // First tab - use mux's current directory
            cwd = std.posix.getcwd(&cwd_buf) catch null;
        }

        var tab = Tab.init(self.allocator, self.layout_width, self.layout_height, "tab");
        // Set ses client if connected (for new tabs after startup)
        if (self.ses_client.isConnected()) {
            tab.layout.setSesClient(&self.ses_client);
        }
        // Set pane notification config
        tab.layout.setPaneNotificationConfig(&self.config.notifications.pane);
        _ = try tab.layout.createFirstPane(cwd);
        try self.tabs.append(self.allocator, tab);
        self.active_tab = self.tabs.items.len - 1;
        self.renderer.invalidate();
        self.force_full_render = true;
        self.syncStateToSes();
    }

    /// Close the current tab
    fn closeCurrentTab(self: *State) bool {
        if (self.tabs.items.len <= 1) return false;
        var tab = self.tabs.orderedRemove(self.active_tab);
        tab.deinit();
        if (self.active_tab >= self.tabs.items.len) {
            self.active_tab = self.tabs.items.len - 1;
        }
        self.renderer.invalidate();
        self.force_full_render = true;
        self.syncStateToSes();
        return true;
    }

    /// Switch to next tab
    fn nextTab(self: *State) void {
        if (self.tabs.items.len > 1) {
            self.active_tab = (self.active_tab + 1) % self.tabs.items.len;
            self.renderer.invalidate();
            self.force_full_render = true;
        }
    }

    /// Switch to previous tab
    fn prevTab(self: *State) void {
        if (self.tabs.items.len > 1) {
            self.active_tab = if (self.active_tab == 0) self.tabs.items.len - 1 else self.active_tab - 1;
            self.renderer.invalidate();
            self.force_full_render = true;
        }
    }

    /// Adopt first orphaned pane, replacing current focused pane
    fn adoptOrphanedPane(self: *State) bool {
        if (!self.ses_client.isConnected()) return false;

        // Get list of orphaned panes
        var panes: [32]OrphanedPaneInfo = undefined;
        const count = self.ses_client.listOrphanedPanes(&panes) catch return false;
        if (count == 0) return false;

        // Adopt the first one
        const result = self.ses_client.adoptPane(panes[0].uuid) catch return false;

        // Get the current focused pane and replace it
        if (self.active_floating) |idx| {
            const old_pane = self.floating_panes.items[idx];
            // Replace with adopted pane
            old_pane.replaceWithFd(result.fd, result.pid, result.uuid) catch return false;
        } else if (self.currentLayout().getFocusedPane()) |pane| {
            pane.replaceWithFd(result.fd, result.pid, result.uuid) catch return false;
        } else {
            return false;
        }

        self.renderer.invalidate();
        self.force_full_render = true;
        return true;
    }

    /// Serialize entire mux state to JSON for detach
    fn serializeState(self: *State) ![]const u8 {
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(self.allocator);
        const writer = buf.writer(self.allocator);

        try writer.writeAll("{");

        // Mux UUID and session name (persistent identity)
        try writer.print("\"uuid\":\"{s}\",", .{self.uuid});
        try writer.print("\"session_name\":\"{s}\",", .{self.session_name});

        // Active tab/float
        try writer.print("\"active_tab\":{d},", .{self.active_tab});
        if (self.active_floating) |af| {
            try writer.print("\"active_floating\":{d},", .{af});
        } else {
            try writer.writeAll("\"active_floating\":null,");
        }

        // Tabs
        try writer.writeAll("\"tabs\":[");
        for (self.tabs.items, 0..) |*tab, ti| {
            if (ti > 0) try writer.writeAll(",");
            try writer.writeAll("{");
            try writer.print("\"name\":\"{s}\",", .{tab.name});
            try writer.print("\"focused_pane_id\":{d},", .{tab.layout.focused_pane_id});
            try writer.print("\"next_pane_id\":{d},", .{tab.layout.next_pane_id});

            // Layout tree
            try writer.writeAll("\"tree\":");
            if (tab.layout.root) |root| {
                try self.serializeLayoutNode(writer, root);
            } else {
                try writer.writeAll("null");
            }

            // Panes in this tab
            try writer.writeAll(",\"panes\":[");
            var first_pane = true;
            var pit = tab.layout.panes.iterator();
            while (pit.next()) |entry| {
                const pane = entry.value_ptr.*;
                if (!first_pane) try writer.writeAll(",");
                first_pane = false;
                try self.serializePane(writer, pane);
            }
            try writer.writeAll("]");

            try writer.writeAll("}");
        }
        try writer.writeAll("],");

        // Floating panes
        try writer.writeAll("\"floats\":[");
        for (self.floating_panes.items, 0..) |pane, fi| {
            if (fi > 0) try writer.writeAll(",");
            try self.serializePane(writer, pane);
        }
        try writer.writeAll("]");

        try writer.writeAll("}");

        return buf.toOwnedSlice(self.allocator);
    }

    fn serializeLayoutNode(self: *State, writer: anytype, node: *LayoutNode) !void {
        _ = self;
        switch (node.*) {
            .pane => |id| {
                try writer.print("{{\"type\":\"pane\",\"id\":{d}}}", .{id});
            },
            .split => |split| {
                const dir_str: []const u8 = if (split.dir == .horizontal) "horizontal" else "vertical";
                try writer.print("{{\"type\":\"split\",\"dir\":\"{s}\",\"ratio\":{d},\"first\":", .{ dir_str, split.ratio });
                try serializeLayoutNode(undefined, writer, split.first);
                try writer.writeAll(",\"second\":");
                try serializeLayoutNode(undefined, writer, split.second);
                try writer.writeAll("}");
            },
        }
    }

    fn serializePane(self: *State, writer: anytype, pane: *Pane) !void {
        _ = self;
        try writer.writeAll("{");
        try writer.print("\"id\":{d},", .{pane.id});
        try writer.print("\"uuid\":\"{s}\",", .{pane.uuid});
        try writer.print("\"x\":{d},\"y\":{d},\"width\":{d},\"height\":{d},", .{ pane.x, pane.y, pane.width, pane.height });
        try writer.print("\"focused\":{},", .{pane.focused});
        try writer.print("\"floating\":{},", .{pane.floating});
        try writer.print("\"visible\":{},", .{pane.visible});
        try writer.print("\"float_key\":{d},", .{pane.float_key});
        try writer.print("\"border_x\":{d},\"border_y\":{d},\"border_w\":{d},\"border_h\":{d},", .{ pane.border_x, pane.border_y, pane.border_w, pane.border_h });
        try writer.print("\"float_width_pct\":{d},\"float_height_pct\":{d},", .{ pane.float_width_pct, pane.float_height_pct });
        try writer.print("\"float_pos_x_pct\":{d},\"float_pos_y_pct\":{d},", .{ pane.float_pos_x_pct, pane.float_pos_y_pct });
        try writer.print("\"float_pad_x\":{d},\"float_pad_y\":{d},", .{ pane.float_pad_x, pane.float_pad_y });
        try writer.print("\"is_pwd\":{},", .{pane.is_pwd});
        try writer.print("\"sticky\":{}", .{pane.sticky});
        if (pane.pwd_dir) |pwd| {
            try writer.print(",\"pwd_dir\":\"{s}\"", .{pwd});
        }
        try writer.writeAll("}");
    }

    /// Reattach to a detached session, restoring full state
    fn reattachSession(self: *State, session_id_prefix: []const u8) bool {
        if (!self.ses_client.isConnected()) return false;

        // Try to reattach session (server supports prefix matching)
        const result = self.ses_client.reattachSession(session_id_prefix) catch return false;
        if (result == null) return false;

        const reattach_result = result.?;
        defer {
            self.allocator.free(reattach_result.mux_state_json);
            self.allocator.free(reattach_result.pane_uuids);
        }

        // Parse the mux state JSON
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, reattach_result.mux_state_json, .{}) catch return false;
        defer parsed.deinit();

        const root = parsed.value.object;

        // Restore mux UUID (persistent identity)
        if (root.get("uuid")) |uuid_val| {
            const uuid_str = uuid_val.string;
            if (uuid_str.len == 32) {
                @memcpy(&self.uuid, uuid_str[0..32]);
            }
        }

        // Restore session name (must dupe since parsed JSON will be freed)
        if (root.get("session_name")) |name_val| {
            // Free previous owned name if any
            if (self.session_name_owned) |old| {
                self.allocator.free(old);
            }
            // Dupe the name from JSON
            const duped = self.allocator.dupe(u8, name_val.string) catch return false;
            self.session_name = duped;
            self.session_name_owned = duped;
        }

        // Re-register with ses using restored UUID and session_name
        self.ses_client.updateSession(self.uuid, self.session_name) catch {};

        // Restore active tab/floating
        if (root.get("active_tab")) |at| {
            self.active_tab = @intCast(at.integer);
        }
        if (root.get("active_floating")) |af| {
            self.active_floating = if (af == .null) null else @intCast(af.integer);
        }

        // Build a map of UUID -> fd for pane adoption
        var uuid_fd_map = std.AutoHashMap([32]u8, struct { fd: std.posix.fd_t, pid: std.posix.pid_t }).init(self.allocator);
        defer uuid_fd_map.deinit();

        for (reattach_result.pane_uuids) |uuid| {
            // Adopt each pane to get its fd
            const adopt_result = self.ses_client.adoptPane(uuid) catch continue;
            uuid_fd_map.put(uuid, .{ .fd = adopt_result.fd, .pid = adopt_result.pid }) catch continue;
        }

        // Restore tabs
        if (root.get("tabs")) |tabs_arr| {
            for (tabs_arr.array.items) |tab_val| {
                const tab_obj = tab_val.object;
                const name_json = (tab_obj.get("name") orelse continue).string;
                const focused_pane_id: u16 = @intCast((tab_obj.get("focused_pane_id") orelse continue).integer);
                const next_pane_id: u16 = @intCast((tab_obj.get("next_pane_id") orelse continue).integer);

                // Dupe the name since parsed JSON will be freed
                const name = self.allocator.dupe(u8, name_json) catch continue;
                var tab = Tab.init(self.allocator, self.layout_width, self.layout_height, name);
                if (self.ses_client.isConnected()) {
                    tab.layout.setSesClient(&self.ses_client);
                }
                tab.layout.setPaneNotificationConfig(&self.config.notifications.pane);
                tab.layout.focused_pane_id = focused_pane_id;
                tab.layout.next_pane_id = next_pane_id;

                // Restore panes
                if (tab_obj.get("panes")) |panes_arr| {
                    for (panes_arr.array.items) |pane_val| {
                        const pane_obj = pane_val.object;
                        const pane_id: u16 = @intCast((pane_obj.get("id") orelse continue).integer);
                        const uuid_str = (pane_obj.get("uuid") orelse continue).string;
                        if (uuid_str.len != 32) continue;

                        // Convert to [32]u8 for lookup
                        var uuid_arr: [32]u8 = undefined;
                        @memcpy(&uuid_arr, uuid_str[0..32]);

                        // Look up fd for this pane
                        if (uuid_fd_map.get(uuid_arr)) |fd_info| {
                            const pane = self.allocator.create(Pane) catch continue;

                            pane.initWithFd(self.allocator, pane_id, 0, 0, self.layout_width, self.layout_height, fd_info.fd, fd_info.pid, uuid_arr) catch {
                                self.allocator.destroy(pane);
                                continue;
                            };

                            // Restore pane properties
                            pane.focused = if (pane_obj.get("focused")) |f| (f == .bool and f.bool) else false;

                            tab.layout.panes.put(pane_id, pane) catch {
                                pane.deinit();
                                self.allocator.destroy(pane);
                                continue;
                            };
                        }
                    }
                }

                // Restore layout tree
                if (tab_obj.get("tree")) |tree_val| {
                    if (tree_val != .null) {
                        tab.layout.root = self.deserializeLayoutNode(tree_val.object) catch null;
                    }
                }

                self.tabs.append(self.allocator, tab) catch continue;
            }
        }

        // Restore floating panes
        if (root.get("floats")) |floats_arr| {
            for (floats_arr.array.items) |pane_val| {
                const pane_obj = pane_val.object;
                const uuid_str = (pane_obj.get("uuid") orelse continue).string;
                if (uuid_str.len != 32) continue;

                var uuid_arr: [32]u8 = undefined;
                @memcpy(&uuid_arr, uuid_str[0..32]);

                if (uuid_fd_map.get(uuid_arr)) |fd_info| {
                    const pane = self.allocator.create(Pane) catch continue;

                    pane.initWithFd(self.allocator, 0, 0, 0, self.layout_width, self.layout_height, fd_info.fd, fd_info.pid, uuid_arr) catch {
                        self.allocator.destroy(pane);
                        continue;
                    };

                    // Restore float properties
                    pane.floating = true;
                    pane.visible = if (pane_obj.get("visible")) |v| (v != .bool or v.bool) else true;
                    pane.float_key = if (pane_obj.get("float_key")) |fk| @intCast(fk.integer) else 0;
                    pane.float_width_pct = if (pane_obj.get("float_width_pct")) |wp| @intCast(wp.integer) else 60;
                    pane.float_height_pct = if (pane_obj.get("float_height_pct")) |hp| @intCast(hp.integer) else 60;
                    pane.float_pos_x_pct = if (pane_obj.get("float_pos_x_pct")) |xp| @intCast(xp.integer) else 50;
                    pane.float_pos_y_pct = if (pane_obj.get("float_pos_y_pct")) |yp| @intCast(yp.integer) else 50;
                    pane.float_pad_x = if (pane_obj.get("float_pad_x")) |px| @intCast(px.integer) else 1;
                    pane.float_pad_y = if (pane_obj.get("float_pad_y")) |py| @intCast(py.integer) else 0;
                    pane.is_pwd = if (pane_obj.get("is_pwd")) |ip| (ip == .bool and ip.bool) else false;
                    pane.sticky = if (pane_obj.get("sticky")) |s| (s == .bool and s.bool) else false;

                    // Configure pane notifications
                    pane.configureNotifications(&self.config.notifications.pane);

                    self.floating_panes.append(self.allocator, pane) catch {
                        pane.deinit();
                        self.allocator.destroy(pane);
                        continue;
                    };
                }
            }
        }

        // Recalculate all layouts for current terminal size
        for (self.tabs.items) |*tab| {
            tab.layout.resize(self.layout_width, self.layout_height);
        }

        // Recalculate floating pane positions
        resizeFloatingPanes(self);

        self.renderer.invalidate();
        self.force_full_render = true;
        return self.tabs.items.len > 0;
    }

    fn deserializeLayoutNode(self: *State, obj: std.json.ObjectMap) !*LayoutNode {
        const node = try self.allocator.create(LayoutNode);
        errdefer self.allocator.destroy(node);

        const node_type = (obj.get("type") orelse return error.InvalidNode).string;

        if (std.mem.eql(u8, node_type, "pane")) {
            const id: u16 = @intCast((obj.get("id") orelse return error.InvalidNode).integer);
            node.* = .{ .pane = id };
        } else if (std.mem.eql(u8, node_type, "split")) {
            const dir_str = (obj.get("dir") orelse return error.InvalidNode).string;
            const dir: SplitDir = if (std.mem.eql(u8, dir_str, "horizontal")) .horizontal else .vertical;
            const ratio_val = obj.get("ratio") orelse return error.InvalidNode;
            const ratio: f32 = switch (ratio_val) {
                .float => @floatCast(ratio_val.float),
                .integer => @floatFromInt(ratio_val.integer),
                else => return error.InvalidNode,
            };
            const first_obj = (obj.get("first") orelse return error.InvalidNode).object;
            const second_obj = (obj.get("second") orelse return error.InvalidNode).object;

            const first = try self.deserializeLayoutNode(first_obj);
            errdefer self.allocator.destroy(first);
            const second = try self.deserializeLayoutNode(second_obj);

            node.* = .{ .split = .{
                .dir = dir,
                .ratio = ratio,
                .first = first,
                .second = second,
            } };
        } else {
            return error.InvalidNode;
        }

        return node;
    }

    /// Attach to orphaned pane by UUID prefix (for --attach CLI)
    fn attachOrphanedPane(self: *State, uuid_prefix: []const u8) bool {
        if (!self.ses_client.isConnected()) return false;

        // Get list of orphaned panes and find matching UUID
        var panes: [32]OrphanedPaneInfo = undefined;
        const count = self.ses_client.listOrphanedPanes(&panes) catch return false;

        for (panes[0..count]) |p| {
            if (std.mem.startsWith(u8, &p.uuid, uuid_prefix)) {
                // Found matching pane, adopt it
                const result = self.ses_client.adoptPane(p.uuid) catch return false;

                // Create a new tab with this pane
                var tab = Tab.init(self.allocator, self.layout_width, self.layout_height, "attached");
                if (self.ses_client.isConnected()) {
                    tab.layout.setSesClient(&self.ses_client);
                }
                tab.layout.setPaneNotificationConfig(&self.config.notifications.pane);

                // Create pane with adopted fd
                const pane = self.allocator.create(Pane) catch return false;
                pane.initWithFd(self.allocator, 0, 0, 0, self.layout_width, self.layout_height, result.fd, result.pid, result.uuid) catch {
                    self.allocator.destroy(pane);
                    return false;
                };
                pane.focused = true;
                pane.configureNotifications(&self.config.notifications.pane);

                // Add pane to layout manually
                tab.layout.panes.put(0, pane) catch {
                    pane.deinit();
                    self.allocator.destroy(pane);
                    return false;
                };
                const node = self.allocator.create(LayoutNode) catch return false;
                node.* = .{ .pane = 0 };
                tab.layout.root = node;
                tab.layout.next_pane_id = 1;

                self.tabs.append(self.allocator, tab) catch return false;
                self.active_tab = self.tabs.items.len - 1;
                self.renderer.invalidate();
                self.force_full_render = true;
                return true;
            }
        }
        return false;
    }

    /// Sync current state to ses for crash recovery
    fn syncStateToSes(self: *State) void {
        if (!self.ses_client.isConnected()) return;

        const mux_state_json = self.serializeState() catch return;
        defer self.allocator.free(mux_state_json);

        self.ses_client.syncState(mux_state_json) catch {};
    }
};

/// Arguments for mux commands
pub const MuxArgs = struct {
    name: ?[]const u8 = null,
    attach: ?[]const u8 = null,
    notify_message: ?[]const u8 = null,
    list: bool = false,
};

/// Entry point for mux - can be called directly from unified CLI
pub fn run(mux_args: MuxArgs) !void {
    const allocator = std.heap.page_allocator;

    // Handle --notify: send to parent mux and exit
    if (mux_args.notify_message) |msg| {
        sendNotifyToParentMux(allocator, msg);
        return;
    }

    // Handle --list: show detached sessions and orphaned panes
    if (mux_args.list) {
        // Temporary connection for listing - generate a dummy UUID and name
        const tmp_uuid = core.ipc.generateUuid();
        const tmp_name = core.ipc.generateSessionName();
        var ses = SesClient.init(allocator, tmp_uuid, tmp_name, false); // keepalive=false for temp connection
        defer ses.deinit();
        ses.connect() catch {
            std.debug.print("Could not connect to ses daemon\n", .{});
            return;
        };

        // List detached sessions
        var sessions: [16]ses_client.DetachedSessionInfo = undefined;
        const sess_count = ses.listSessions(&sessions) catch 0;
        if (sess_count > 0) {
            std.debug.print("Detached sessions:\n", .{});
            for (sessions[0..sess_count]) |s| {
                const name = s.session_name[0..s.session_name_len];
                std.debug.print("  {s} [{s}] {d} panes - attach with: hexa mux attach {s}\n", .{ name, s.session_id[0..8], s.pane_count, name });
            }
        }

        // List orphaned panes
        var panes: [32]OrphanedPaneInfo = undefined;
        const count = ses.listOrphanedPanes(&panes) catch 0;
        if (count > 0) {
            std.debug.print("Orphaned panes (disowned):\n", .{});
            for (panes[0..count]) |p| {
                std.debug.print("  [{s}] pid={d}\n", .{ p.uuid[0..8], p.pid });
            }
        }

        if (sess_count == 0 and count == 0) {
            std.debug.print("No detached sessions or orphaned panes\n", .{});
        }
        return;
    }

    // Handle --attach: attach to detached session by name or UUID prefix
    if (mux_args.attach) |uuid_arg| {
        if (uuid_arg.len < 3) {
            std.debug.print("Session name/UUID too short (need at least 3 chars)\n", .{});
            return;
        }
        // Will be handled after state init
    }

    // Redirect stderr to /dev/null to suppress ghostty warnings
    // that would otherwise corrupt the display
    const devnull = std.fs.openFileAbsolute("/dev/null", .{ .mode = .write_only }) catch null;
    if (devnull) |f| {
        posix.dup2(f.handle, posix.STDERR_FILENO) catch {};
        f.close();
    }

    // Get terminal size
    const size = getTermSize();

    // Initialize state
    var state = try State.init(allocator, size.cols, size.rows);
    defer state.deinit();

    // Set custom session name if provided
    if (mux_args.name) |custom_name| {
        const duped = allocator.dupe(u8, custom_name) catch null;
        if (duped) |d| {
            state.session_name = d;
            state.session_name_owned = d;
        }
    }

    // Set HEXA_MUX_SOCKET environment for child processes
    if (state.socket_path) |path| {
        const path_z = allocator.dupeZ(u8, path) catch null;
        if (path_z) |p| {
            _ = c.setenv("HEXA_MUX_SOCKET", p.ptr, 1);
            allocator.free(p);
        }
    }

    // Connect to ses daemon FIRST (start it if needed)
    state.ses_client.connect() catch {};

    // Show notification if we just started the daemon
    if (state.ses_client.just_started_daemon) {
        state.notifications.showFor("ses daemon started", 2000);
    }

    // Handle --attach: try session first, then orphaned pane
    if (mux_args.attach) |uuid_prefix| {
        // First try to reattach a detached session
        if (state.reattachSession(uuid_prefix)) {
            state.notifications.show("Session reattached");
        } else if (state.attachOrphanedPane(uuid_prefix)) {
            // Fall back to orphaned pane
            state.notifications.show("Attached to orphaned pane");
        } else {
            // Fallback to creating new tab
            try state.createTab();
            state.notifications.show("Session/pane not found, created new");
        }
    } else {
        // Create first tab with one pane (will use ses if connected)
        try state.createTab();
    }

    // Continue with main loop
    try runMainLoop(&state);
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    // Parse command line arguments
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var mux_args = MuxArgs{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if ((std.mem.eql(u8, arg, "--notify") or std.mem.eql(u8, arg, "-n")) and i + 1 < args.len) {
            i += 1;
            mux_args.notify_message = args[i];
        } else if (std.mem.eql(u8, arg, "--list") or std.mem.eql(u8, arg, "-l")) {
            mux_args.list = true;
        } else if ((std.mem.eql(u8, arg, "--attach") or std.mem.eql(u8, arg, "-a")) and i + 1 < args.len) {
            i += 1;
            mux_args.attach = args[i];
        } else if ((std.mem.eql(u8, arg, "--name") or std.mem.eql(u8, arg, "-N")) and i + 1 < args.len) {
            i += 1;
            mux_args.name = args[i];
        }
    }

    try run(mux_args);
}

fn runMainLoop(state: *State) !void {
    const allocator = state.allocator;

    // Enter raw mode
    const orig_termios = try enableRawMode(posix.STDIN_FILENO);
    defer disableRawMode(posix.STDIN_FILENO, orig_termios) catch {};

    // Enter alternate screen and reset it
    const stdout = std.fs.File.stdout();
    // Sequence:
    // ESC[?1049h    - Enter alternate screen buffer (FIRST - before any reset)
    // ESC[2J        - Clear entire alternate screen
    // ESC[H         - Cursor to home position (1,1)
    // ESC[0m        - Reset all SGR attributes
    // ESC(B         - Set G0 charset to ASCII (US-ASCII)
    // ESC)0         - Set G1 charset to DEC Special Graphics
    // SI (0x0F)     - Shift In - select G0 charset
    // ESC[?25l      - Hide cursor
    // ESC[?1000h    - Enable mouse click tracking
    // ESC[?1006h    - Enable SGR mouse mode
    // Also clear scrollback (CSI 3 J) so we don't see prior content.
    try stdout.writeAll("\x1b[?1049h\x1b[2J\x1b[3J\x1b[H\x1b[0m\x1b(B\x1b)0\x0f\x1b[?25l\x1b[?1000h\x1b[?1006h");
    // On exit: disable mouse, show cursor, reset attributes, leave alternate screen
    defer stdout.writeAll("\x1b[?1006l\x1b[?1000l\x1b[0m\x1b[?25h\x1b[?1049l") catch {};

    // Build poll fds
    var poll_fds: [17]posix.pollfd = undefined; // stdin + up to 16 panes
    var buffer: [32768]u8 = undefined; // Larger buffer for efficiency

    // Frame timing
    var last_render: i64 = std.time.milliTimestamp();
    var last_status_update: i64 = last_render;
    const status_update_interval: i64 = 250; // Update status bar every 250ms

    // Main loop
    while (state.running) {
        // Check for terminal resize
        {
            const new_size = getTermSize();
            if (new_size.cols != state.term_width or new_size.rows != state.term_height) {
                state.term_width = new_size.cols;
                state.term_height = new_size.rows;
                const status_h: u16 = if (state.config.panes.status.enabled) 1 else 0;
                state.status_height = status_h;
                state.layout_width = new_size.cols;
                state.layout_height = new_size.rows - status_h;

                // Resize all tabs
                for (state.tabs.items) |*tab| {
                    tab.layout.resize(state.layout_width, state.layout_height);
                }

                // Resize floating panes based on their stored percentages
                resizeFloatingPanes(state);

                // Resize renderer and force full redraw
                state.renderer.resize(new_size.cols, new_size.rows) catch {};
                state.renderer.invalidate();
                state.needs_render = true;
                state.force_full_render = true;
            }
        }

        // Proactively check for dead floating panes before polling
        {
            var fi: usize = 0;
            while (fi < state.floating_panes.items.len) {
                if (!state.floating_panes.items[fi].isAlive()) {
                    // Check if this was the active float
                    const was_active = if (state.active_floating) |af| af == fi else false;

                    const pane = state.floating_panes.orderedRemove(fi);

                    // Kill in ses (dead panes don't need to be orphaned)
                    if (state.ses_client.isConnected()) {
                        state.ses_client.killPane(pane.uuid) catch {};
                    }

                    pane.deinit();
                    state.allocator.destroy(pane);
                    state.needs_render = true;
                    state.syncStateToSes();

                    // Clear focus if this was the active float
                    if (was_active) {
                        state.active_floating = null;
                    }
                    // Don't increment fi, next item shifted into this position
                } else {
                    fi += 1;
                }
            }
            // Ensure active_floating is valid
            if (state.active_floating) |af| {
                if (af >= state.floating_panes.items.len) {
                    state.active_floating = if (state.floating_panes.items.len > 0)
                        state.floating_panes.items.len - 1
                    else
                        null;
                }
            }
        }

        // Check for dead tiled panes in current tab
        {
            var any_dead = false;
            var pane_it = state.currentLayout().paneIterator();
            while (pane_it.next()) |pane| {
                if (!pane.*.isAlive()) {
                    any_dead = true;
                    break;
                }
            }
            if (any_dead) {
                if (state.currentLayout().paneCount() > 1) {
                    // Multiple panes in tab - just close this one
                    _ = state.currentLayout().closeFocused();
                    state.needs_render = true;
                    state.syncStateToSes();
                } else if (state.tabs.items.len > 1) {
                    // Only 1 pane but multiple tabs - close this tab
                    _ = state.closeCurrentTab();
                    state.needs_render = true;
                } else {
                    // Last pane in last tab - kill pane in ses and exit
                    if (state.currentLayout().getFocusedPane()) |pane| {
                        if (state.ses_client.isConnected()) {
                            state.ses_client.killPane(pane.uuid) catch {};
                        }
                    }
                    state.running = false;
                    continue;
                }
            }
        }

        // Build poll list: stdin + all pane PTYs
        var fd_count: usize = 1;
        poll_fds[0] = .{ .fd = posix.STDIN_FILENO, .events = posix.POLL.IN, .revents = 0 };

        var pane_it = state.currentLayout().paneIterator();
        while (pane_it.next()) |pane| {
            if (fd_count < poll_fds.len) {
                poll_fds[fd_count] = .{ .fd = pane.*.getFd(), .events = posix.POLL.IN, .revents = 0 };
                fd_count += 1;
            }
        }

        // Add floating panes
        for (state.floating_panes.items) |pane| {
            if (fd_count < poll_fds.len) {
                poll_fds[fd_count] = .{ .fd = pane.getFd(), .events = posix.POLL.IN, .revents = 0 };
                fd_count += 1;
            }
        }

        // Add ses connection fd if connected
        var ses_fd_idx: ?usize = null;
        if (state.ses_client.conn) |conn| {
            if (fd_count < poll_fds.len) {
                ses_fd_idx = fd_count;
                poll_fds[fd_count] = .{ .fd = conn.fd, .events = posix.POLL.IN, .revents = 0 };
                fd_count += 1;
            }
        }

        // Add IPC server fd for incoming connections
        var ipc_fd_idx: ?usize = null;
        if (state.ipc_server) |srv| {
            if (fd_count < poll_fds.len) {
                ipc_fd_idx = fd_count;
                poll_fds[fd_count] = .{ .fd = srv.fd, .events = posix.POLL.IN, .revents = 0 };
                fd_count += 1;
            }
        }

        // Calculate poll timeout - wait for next frame, status update, or input
        const now = std.time.milliTimestamp();
        const since_render = now - last_render;
        const since_status = now - last_status_update;
        const until_status: i64 = @max(0, status_update_interval - since_status);
        const frame_timeout: i32 = if (!state.needs_render) 100 else if (since_render >= 16) 0 else @intCast(16 - since_render);
        const timeout: i32 = @intCast(@min(frame_timeout, until_status));
        _ = posix.poll(poll_fds[0..fd_count], timeout) catch continue;

        // Check if status bar needs periodic update
        const now2 = std.time.milliTimestamp();
        if (now2 - last_status_update >= status_update_interval) {
            state.needs_render = true;
            last_status_update = now2;
        }

        // Handle stdin
        if (poll_fds[0].revents & posix.POLL.IN != 0) {
            const n = posix.read(posix.STDIN_FILENO, &buffer) catch break;
            if (n == 0) break;
            handleInput(state, buffer[0..n]);
        }

        // Handle ses messages
        if (ses_fd_idx) |sidx| {
            if (poll_fds[sidx].revents & posix.POLL.IN != 0) {
                handleSesMessage(state, &buffer);
            }
        }

        // Handle IPC connections (for --notify)
        if (ipc_fd_idx) |iidx| {
            if (poll_fds[iidx].revents & posix.POLL.IN != 0) {
                handleIpcConnection(state, &buffer);
            }
        }

        // Handle PTY output
        var idx: usize = 1;
        var dead_panes: std.ArrayList(u16) = .empty;
        defer dead_panes.deinit(allocator);

        pane_it = state.currentLayout().paneIterator();
        while (pane_it.next()) |pane| {
            if (idx < fd_count) {
                if (poll_fds[idx].revents & posix.POLL.IN != 0) {
                    if (pane.*.poll(&buffer)) |had_data| {
                        if (had_data) state.needs_render = true;
                        if (pane.*.did_clear) {
                            state.force_full_render = true;
                            state.renderer.invalidate();
                        }
                    } else |_| {}
                }
                if (poll_fds[idx].revents & posix.POLL.HUP != 0) {
                    dead_panes.append(allocator, pane.*.id) catch {};
                }
                idx += 1;
            }
        }

        // Handle floating pane output
        var dead_floating: std.ArrayList(usize) = .empty;
        defer dead_floating.deinit(allocator);

        for (state.floating_panes.items, 0..) |pane, fi| {
            if (idx < fd_count) {
                if (poll_fds[idx].revents & posix.POLL.IN != 0) {
                    if (pane.poll(&buffer)) |had_data| {
                        if (had_data) state.needs_render = true;
                        if (pane.did_clear) {
                            state.force_full_render = true;
                            state.renderer.invalidate();
                        }
                    } else |_| {}
                }
                if (poll_fds[idx].revents & posix.POLL.HUP != 0) {
                    dead_floating.append(allocator, fi) catch {};
                }
                idx += 1;
            }
        }

        // Remove dead floating panes (in reverse order to preserve indices)
        var df_idx: usize = dead_floating.items.len;
        while (df_idx > 0) {
            df_idx -= 1;
            const fi = dead_floating.items[df_idx];
            // Check if this was the active float before removing
            const was_active = if (state.active_floating) |af| af == fi else false;

            const pane = state.floating_panes.orderedRemove(fi);
            pane.deinit();
            state.allocator.destroy(pane);
            state.needs_render = true;

            // Clear focus if this was the active float
            if (was_active) {
                state.active_floating = null;
            }
        }
        // Ensure active_floating is still valid
        if (state.active_floating) |af| {
            if (af >= state.floating_panes.items.len) {
                state.active_floating = null;
            }
        }

        // Remove dead panes
        for (dead_panes.items) |_| {
            if (state.currentLayout().paneCount() > 1) {
                // Multiple panes in tab - just close this one
                _ = state.currentLayout().closeFocused();
                state.needs_render = true;
            } else if (state.tabs.items.len > 1) {
                // Only 1 pane but multiple tabs - close this tab
                _ = state.closeCurrentTab();
                state.needs_render = true;
            } else {
                // Last pane in last tab - exit
                state.running = false;
            }
        }

        // Update MUX realm notifications
        if (state.notifications.update()) {
            state.needs_render = true;
        }

        // Update PANE realm notifications (tiled panes)
        var notif_pane_it = state.currentLayout().paneIterator();
        while (notif_pane_it.next()) |pane| {
            if (pane.*.updateNotifications()) {
                state.needs_render = true;
            }
        }

        // Update PANE realm notifications (floating panes)
        for (state.floating_panes.items) |pane| {
            if (pane.updateNotifications()) {
                state.needs_render = true;
            }
        }

        // Render with frame rate limiting (max 60fps)
        if (state.needs_render) {
            const render_now = std.time.milliTimestamp();
            if (render_now - last_render >= 16) { // ~60fps
                renderTo(state, stdout) catch {};
                state.needs_render = false;
                state.force_full_render = false;
                last_render = render_now;
            }
        }
    }
}

fn handleInput(state: *State, input: []const u8) void {
    var i: usize = 0;
    while (i < input.len) {
        // Check for Alt+key (ESC followed by key)
        if (input[i] == 0x1b and i + 1 < input.len) {
            const next = input[i + 1];
            // Check for CSI sequences (ESC [)
            if (next == '[' and i + 2 < input.len) {
                // Handle scroll keys
                if (handleScrollKeys(state, input[i..])) |consumed| {
                    i += consumed;
                    continue;
                }
            }
            // Make sure it's not an actual escape sequence (like arrow keys)
            if (next != '[' and next != 'O') {
                if (handleAltKey(state, next)) {
                    i += 2;
                    continue;
                }
            }
        }

        // Check for Ctrl+Q to quit
        if (input[i] == 0x11) {
            state.running = false;
            return;
        }

        // If pane is scrolled and user types, scroll to bottom first
        if (state.active_floating) |idx| {
            const fpane = state.floating_panes.items[idx];
            if (fpane.visible) {
                if (fpane.isScrolled()) {
                    fpane.scrollToBottom();
                    state.needs_render = true;
                }
                fpane.write(input[i..]) catch {};
            }
        } else if (state.currentLayout().getFocusedPane()) |pane| {
            if (pane.isScrolled()) {
                pane.scrollToBottom();
                state.needs_render = true;
            }
            pane.write(input[i..]) catch {};
        }
        return;
    }
}

fn handleSesMessage(state: *State, buffer: []u8) void {
    const conn = &(state.ses_client.conn orelse return);

    // Try to read a line from ses
    const line = conn.recvLine(buffer) catch return;
    if (line == null) return;

    // Parse JSON message
    const parsed = std.json.parseFromSlice(std.json.Value, state.allocator, line.?, .{}) catch return;
    defer parsed.deinit();

    const root = parsed.value.object;
    const msg_type = (root.get("type") orelse return).string;

    // Handle MUX realm notification (broadcast or targeted to this mux)
    if (std.mem.eql(u8, msg_type, "notify") or std.mem.eql(u8, msg_type, "notification")) {
        if (root.get("message")) |msg_val| {
            const msg = msg_val.string;
            // Duplicate message since we'll free parsed
            const msg_copy = state.allocator.dupe(u8, msg) catch return;
            state.notifications.showWithOptions(
                msg_copy,
                state.notifications.default_duration_ms,
                state.notifications.default_style,
                true,
            );
            state.needs_render = true;
        }
    }
    // Handle PANE realm notification (targeted to specific pane)
    else if (std.mem.eql(u8, msg_type, "pane_notification")) {
        const uuid_str = (root.get("uuid") orelse return).string;
        if (uuid_str.len != 32) return;

        var target_uuid: [32]u8 = undefined;
        @memcpy(&target_uuid, uuid_str[0..32]);

        const msg = (root.get("message") orelse return).string;
        const msg_copy = state.allocator.dupe(u8, msg) catch return;

        // Find the pane and show notification on it
        var found = false;

        // Check tiled panes in all tabs
        for (state.tabs.items) |*tab| {
            var pane_it = tab.layout.paneIterator();
            while (pane_it.next()) |pane| {
                if (std.mem.eql(u8, &pane.*.uuid, &target_uuid)) {
                    pane.*.notifications.showWithOptions(
                        msg_copy,
                        pane.*.notifications.default_duration_ms,
                        pane.*.notifications.default_style,
                        true,
                    );
                    found = true;
                    break;
                }
            }
            if (found) break;
        }

        // Check floating panes if not found
        if (!found) {
            for (state.floating_panes.items) |pane| {
                if (std.mem.eql(u8, &pane.uuid, &target_uuid)) {
                    pane.notifications.showWithOptions(
                        msg_copy,
                        pane.notifications.default_duration_ms,
                        pane.notifications.default_style,
                        true,
                    );
                    found = true;
                    break;
                }
            }
        }

        if (!found) {
            // Pane not found, free the copy
            state.allocator.free(msg_copy);
        }
        state.needs_render = true;
    }
}

fn sendNotifyToParentMux(_: std.mem.Allocator, message: []const u8) void {
    // Get parent mux socket from environment
    const socket_path = std.posix.getenv("HEXA_MUX_SOCKET") orelse {
        _ = posix.write(posix.STDERR_FILENO, "Not inside a hexa-mux session (HEXA_MUX_SOCKET not set)\n") catch {};
        return;
    };

    // Connect to parent mux
    var client = core.ipc.Client.connect(socket_path) catch {
        _ = posix.write(posix.STDERR_FILENO, "Failed to connect to mux\n") catch {};
        return;
    };
    defer client.close();

    var conn = client.toConnection();

    // Send notify message
    var buf: [1024]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "{{\"type\":\"notify\",\"message\":\"{s}\"}}", .{message}) catch return;
    conn.sendLine(msg) catch {};
}

fn handleIpcConnection(state: *State, buffer: []u8) void {
    const server = &(state.ipc_server orelse return);

    // Try to accept a connection (non-blocking)
    const conn_opt = server.tryAccept() catch return;
    if (conn_opt == null) return;

    var conn = conn_opt.?;
    defer conn.close();

    // Read message
    const line = conn.recvLine(buffer) catch return;
    if (line == null) return;

    // Parse JSON message
    const parsed = std.json.parseFromSlice(std.json.Value, state.allocator, line.?, .{}) catch return;
    defer parsed.deinit();

    const root = parsed.value.object;
    const msg_type = (root.get("type") orelse return).string;

    if (std.mem.eql(u8, msg_type, "notify")) {
        if (root.get("message")) |msg_val| {
            const msg = msg_val.string;
            const msg_copy = state.allocator.dupe(u8, msg) catch return;
            state.notifications.showWithOptions(
                msg_copy,
                state.notifications.default_duration_ms,
                state.notifications.default_style,
                true,
            );
            state.needs_render = true;
        }
    }
}

/// Handle scroll-related escape sequences
/// Returns number of bytes consumed, or null if not a scroll sequence
fn handleScrollKeys(state: *State, input: []const u8) ?usize {
    // Must start with ESC [
    if (input.len < 3 or input[0] != 0x1b or input[1] != '[') return null;

    // Get the focused pane
    const pane = if (state.active_floating) |idx|
        state.floating_panes.items[idx]
    else
        state.currentLayout().getFocusedPane() orelse return null;

    // SGR mouse format: ESC [ < btn ; x ; y M (press) or m (release)
    if (input.len >= 4 and input[2] == '<') {
        // Find the 'M' or 'm' terminator
        var end: usize = 3;
        while (end < input.len and input[end] != 'M' and input[end] != 'm') : (end += 1) {}
        if (end >= input.len) return null;

        const is_release = input[end] == 'm';

        // Parse: btn ; x ; y
        var btn: u16 = 0;
        var mouse_x: u16 = 0;
        var mouse_y: u16 = 0;
        var field: u8 = 0;
        var i: usize = 3;
        while (i < end) : (i += 1) {
            if (input[i] == ';') {
                field += 1;
            } else if (input[i] >= '0' and input[i] <= '9') {
                const digit = input[i] - '0';
                switch (field) {
                    0 => btn = btn * 10 + digit,
                    1 => mouse_x = mouse_x * 10 + digit,
                    2 => mouse_y = mouse_y * 10 + digit,
                    else => {},
                }
            }
        }

        // Convert from 1-based to 0-based coordinates
        if (mouse_x > 0) mouse_x -= 1;
        if (mouse_y > 0) mouse_y -= 1;

        // Button 64 = wheel up, 65 = wheel down
        if (btn == 64) {
            pane.scrollUp(3);
            state.needs_render = true;
            return end + 1;
        } else if (btn == 65) {
            pane.scrollDown(3);
            state.needs_render = true;
            return end + 1;
        }

        // Left click (btn 0) on release - focus pane at position
        if (btn == 0 and is_release) {
            // Check floating panes first (they're on top)
            var clicked_float: ?usize = null;
            for (state.floating_panes.items, 0..) |fp, fi| {
                if (fp.visible and mouse_x >= fp.x and mouse_x < fp.x + fp.width and
                    mouse_y >= fp.y and mouse_y < fp.y + fp.height)
                {
                    clicked_float = fi;
                    // Don't break - later floats are on top
                }
            }

            if (clicked_float) |fi| {
                state.active_floating = fi;
                state.needs_render = true;
            } else {
                // Check tiled panes in current tab
                state.active_floating = null;
                var pane_it = state.currentLayout().paneIterator();
                while (pane_it.next()) |p| {
                    if (mouse_x >= p.*.x and mouse_x < p.*.x + p.*.width and
                        mouse_y >= p.*.y and mouse_y < p.*.y + p.*.height)
                    {
                        state.currentLayout().focused_pane_id = p.*.id;
                        state.needs_render = true;
                        break;
                    }
                }
            }
            return end + 1;
        }

        // Other mouse events - consume but don't act
        return end + 1;
    }

    // Page Up: ESC [ 5 ~
    if (input.len >= 4 and input[2] == '5' and input[3] == '~') {
        pane.scrollUp(pane.height / 2);
        state.needs_render = true;
        return 4;
    }

    // Page Down: ESC [ 6 ~
    if (input.len >= 4 and input[2] == '6' and input[3] == '~') {
        pane.scrollDown(pane.height / 2);
        state.needs_render = true;
        return 4;
    }

    // Shift+Page Up: ESC [ 5 ; 2 ~
    if (input.len >= 6 and input[2] == '5' and input[3] == ';' and input[4] == '2' and input[5] == '~') {
        pane.scrollUp(pane.height);
        state.needs_render = true;
        return 6;
    }

    // Shift+Page Down: ESC [ 6 ; 2 ~
    if (input.len >= 6 and input[2] == '6' and input[3] == ';' and input[4] == '2' and input[5] == '~') {
        pane.scrollDown(pane.height);
        state.needs_render = true;
        return 6;
    }

    // Home (scroll to top): ESC [ H or ESC [ 1 ~
    if (input.len >= 3 and input[2] == 'H') {
        pane.scrollToTop();
        state.needs_render = true;
        return 3;
    }
    if (input.len >= 4 and input[2] == '1' and input[3] == '~') {
        pane.scrollToTop();
        state.needs_render = true;
        return 4;
    }

    // End (scroll to bottom): ESC [ F or ESC [ 4 ~
    if (input.len >= 3 and input[2] == 'F') {
        pane.scrollToBottom();
        state.needs_render = true;
        return 3;
    }
    if (input.len >= 4 and input[2] == '4' and input[3] == '~') {
        pane.scrollToBottom();
        state.needs_render = true;
        return 4;
    }

    // Shift+Up: ESC [ 1 ; 2 A - scroll up one line
    if (input.len >= 6 and input[2] == '1' and input[3] == ';' and input[4] == '2' and input[5] == 'A') {
        pane.scrollUp(1);
        state.needs_render = true;
        return 6;
    }

    // Shift+Down: ESC [ 1 ; 2 B - scroll down one line
    if (input.len >= 6 and input[2] == '1' and input[3] == ';' and input[4] == '2' and input[5] == 'B') {
        pane.scrollDown(1);
        state.needs_render = true;
        return 6;
    }

    return null;
}

fn handleAltKey(state: *State, key: u8) bool {
    const cfg = &state.config;

    if (key == cfg.key_quit) {
        state.running = false;
        return true;
    }

    // Disown pane - orphans current pane in ses, adopt with Alt+a
    if (key == cfg.key_disown) {
        if (state.active_floating) |idx| {
            const pane = state.floating_panes.items[idx];
            if (pane.pty.external_process) {
                state.ses_client.orphanPane(pane.uuid) catch {};
                state.notifications.show("Pane disowned (adopt with Alt+a)");
            }
            _ = state.floating_panes.orderedRemove(idx);
            pane.deinit();
            state.allocator.destroy(pane);
            state.active_floating = if (state.floating_panes.items.len > 0) 0 else null;
        } else if (state.currentLayout().getFocusedPane()) |pane| {
            if (pane.pty.external_process) {
                state.ses_client.orphanPane(pane.uuid) catch {};
                state.notifications.show("Pane disowned (adopt with Alt+a)");
            }
            if (!state.currentLayout().closeFocused()) {
                if (!state.closeCurrentTab()) {
                    state.running = false;
                }
            }
        }
        state.needs_render = true;
        return true;
    }

    // Adopt first orphaned pane, replace current pane
    if (key == cfg.key_adopt) {
        if (state.adoptOrphanedPane()) {
            state.notifications.show("Adopted orphaned pane");
            state.needs_render = true;
        } else {
            state.notifications.show("No orphaned panes");
        }
        return true;
    }

    // Split keys
    const split_h_key = cfg.splits.key_split_h;
    const split_v_key = cfg.splits.key_split_v;

    if (key == split_h_key) {
        const cwd = if (state.currentLayout().getFocusedPane()) |p| p.getRealCwd() else null;
        _ = state.currentLayout().splitFocused(.horizontal, cwd) catch null;
        state.needs_render = true;
        state.syncStateToSes();
        return true;
    }

    if (key == split_v_key) {
        const cwd = if (state.currentLayout().getFocusedPane()) |p| p.getRealCwd() else null;
        _ = state.currentLayout().splitFocused(.vertical, cwd) catch null;
        state.needs_render = true;
        state.syncStateToSes();
        return true;
    }

    // Alt+t = new tab
    if (key == cfg.panes.key_new) {
        state.active_floating = null;
        state.createTab() catch {};
        state.needs_render = true;
        return true;
    }

    // Alt+n = next tab
    if (key == cfg.panes.key_next) {
        state.active_floating = null;
        state.nextTab();
        state.needs_render = true;
        return true;
    }

    // Alt+p = previous tab
    if (key == cfg.panes.key_prev) {
        state.active_floating = null;
        state.prevTab();
        state.needs_render = true;
        return true;
    }

    // Alt+x or Alt+w = close current tab (or quit if last tab)
    if (key == cfg.panes.key_close or key == 'w') {
        if (state.active_floating) |idx| {
            const pane = state.floating_panes.orderedRemove(idx);
            pane.deinit();
            state.allocator.destroy(pane);
            state.active_floating = if (state.floating_panes.items.len > 0) 0 else null;
        } else {
            // Close current tab, or quit if it's the last one
            if (!state.closeCurrentTab()) {
                state.running = false;
            }
        }
        state.needs_render = true;
        return true;
    }

    // Alt+d = detach whole mux - keeps all panes alive in ses for --attach
    if (key == cfg.panes.key_detach) {
        // Always set detach_mode to prevent killing panes on exit
        state.detach_mode = true;

        // Serialize entire mux state
        const mux_state_json = state.serializeState() catch {
            state.notifications.showFor("Failed to serialize state", 2000);
            state.running = false;
            return true;
        };
        defer state.allocator.free(mux_state_json);

        // Detach session with our UUID - panes stay grouped with full state
        state.ses_client.detachSession(state.uuid, mux_state_json) catch {
            std.debug.print("\nDetach failed - panes orphaned\n", .{});
            state.running = false;
            return true;
        };
        // Print session_id (our UUID) so user can reattach
        std.debug.print("\nSession detached: {s}\nReattach with: hexa-mux --attach {s}\n", .{ state.uuid, state.uuid[0..8] });
        state.running = false;
        return true;
    }

    // Alt+space - toggle floating focus (always space)
    if (key == ' ') {
        if (state.floating_panes.items.len > 0) {
            if (state.active_floating) |_| {
                state.active_floating = null;
            } else {
                state.active_floating = 0;
            }
            state.needs_render = true;
        }
        return true;
    }

    // Check for named float keys from config
    if (cfg.getFloatByKey(key)) |float_def| {
        toggleNamedFloat(state, float_def);
        state.needs_render = true;
        return true;
    }

    return false;
}

fn toggleNamedFloat(state: *State, float_def: *const core.FloatDef) void {
    // Get current directory from focused pane (for pwd floats)
    // Use getRealCwd which reads /proc/<pid>/cwd for accurate directory
    var current_dir: ?[]const u8 = null;
    if (state.currentLayout().getFocusedPane()) |focused| {
        current_dir = focused.getRealCwd();
    }

    // Find existing float by key (and directory if pwd)
    for (state.floating_panes.items, 0..) |pane, i| {
        if (pane.float_key == float_def.key) {
            // For pwd floats, also check directory match
            if (float_def.pwd and pane.is_pwd) {
                // Both dirs must exist and match, or both be null
                const dirs_match = if (pane.pwd_dir) |pane_dir| blk: {
                    if (current_dir) |curr| {
                        break :blk std.mem.eql(u8, pane_dir, curr);
                    }
                    break :blk false;
                } else current_dir == null;

                if (!dirs_match) continue;
            }

            // Toggle visibility
            pane.visible = !pane.visible;
            if (pane.visible) {
                state.active_floating = i;
                // If alone mode, hide all other floats
                if (float_def.alone) {
                    for (state.floating_panes.items) |other| {
                        if (other.float_key != float_def.key) {
                            other.visible = false;
                        }
                    }
                }
                // For pwd floats, hide other instances of same float (different dirs)
                if (float_def.pwd) {
                    for (state.floating_panes.items, 0..) |other, j| {
                        if (j != i and other.float_key == float_def.key) {
                            other.visible = false;
                        }
                    }
                }
            } else {
                state.active_floating = null;
            }
            return;
        }
    }

    // Not found - create new float
    createNamedFloat(state, float_def, current_dir) catch {};

    // If alone mode, hide all other floats after creation
    if (float_def.alone) {
        for (state.floating_panes.items) |pane| {
            if (pane.float_key != float_def.key) {
                pane.visible = false;
            }
        }
    }
    // For pwd floats, hide other instances of same float (different dirs)
    if (float_def.pwd) {
        const new_idx = state.floating_panes.items.len - 1;
        for (state.floating_panes.items, 0..) |pane, i| {
            if (i != new_idx and pane.float_key == float_def.key) {
                pane.visible = false;
            }
        }
    }
}

fn resizeFloatingPanes(state: *State) void {
    const avail_h = state.term_height - state.status_height;

    for (state.floating_panes.items) |pane| {
        // Recalculate outer frame size based on stored percentages
        const outer_w: u16 = state.term_width * pane.float_width_pct / 100;
        const outer_h: u16 = avail_h * pane.float_height_pct / 100;

        // Recalculate position
        const max_x = state.term_width -| outer_w;
        const max_y = avail_h -| outer_h;
        const outer_x: u16 = max_x * pane.float_pos_x_pct / 100;
        const outer_y: u16 = max_y * pane.float_pos_y_pct / 100;

        // Calculate content area
        const pad_x: u16 = 1 + pane.float_pad_x;
        const pad_y: u16 = 1 + pane.float_pad_y;
        const content_x = outer_x + pad_x;
        const content_y = outer_y + pad_y;
        const content_w = outer_w -| (pad_x * 2);
        const content_h = outer_h -| (pad_y * 2);

        // Update pane position and size
        pane.resize(content_x, content_y, content_w, content_h) catch {};

        // Update border dimensions
        pane.border_x = outer_x;
        pane.border_y = outer_y;
        pane.border_w = outer_w;
        pane.border_h = outer_h;
    }
}

fn createNamedFloat(state: *State, float_def: *const core.FloatDef, current_dir: ?[]const u8) !void {
    const pane = try state.allocator.create(Pane);
    errdefer state.allocator.destroy(pane);

    const cfg = &state.config;

    // Use per-float settings or fall back to defaults
    const width_pct: u16 = float_def.width_percent orelse cfg.float_width_percent;
    const height_pct: u16 = float_def.height_percent orelse cfg.float_height_percent;
    const pos_x_pct: u16 = float_def.pos_x orelse 50; // default center
    const pos_y_pct: u16 = float_def.pos_y orelse 50; // default center
    const pad_x_cfg: u16 = float_def.padding_x orelse cfg.float_padding_x;
    const pad_y_cfg: u16 = float_def.padding_y orelse cfg.float_padding_y;
    const border_color = float_def.color orelse cfg.float_color;

    // Calculate outer frame size
    const avail_h = state.term_height - state.status_height;
    const outer_w = state.term_width * width_pct / 100;
    const outer_h = avail_h * height_pct / 100;

    // Calculate position based on pos_x/pos_y percentages
    // 0% = left/top edge, 50% = centered, 100% = right/bottom edge
    const max_x = state.term_width -| outer_w;
    const max_y = avail_h -| outer_h;
    const outer_x = max_x * pos_x_pct / 100;
    const outer_y = max_y * pos_y_pct / 100;

    // Content area: 1 cell border + configurable padding
    const pad_x: u16 = 1 + pad_x_cfg;
    const pad_y: u16 = 1 + pad_y_cfg;
    const content_x = outer_x + pad_x;
    const content_y = outer_y + pad_y;
    const content_w = outer_w -| (pad_x * 2);
    const content_h = outer_h -| (pad_y * 2);

    const id: u16 = @intCast(100 + state.floating_panes.items.len);

    // Try to create pane via ses if available
    if (state.ses_client.isConnected()) {
        if (state.ses_client.createPane(float_def.command, current_dir, null, null)) |result| {
            try pane.initWithFd(state.allocator, id, content_x, content_y, content_w, content_h, result.fd, result.pid, result.uuid);
        } else |_| {
            // Fall back to local spawn
            try pane.initWithCommand(state.allocator, id, content_x, content_y, content_w, content_h, float_def.command);
        }
    } else {
        try pane.initWithCommand(state.allocator, id, content_x, content_y, content_w, content_h, float_def.command);
    }
    pane.floating = true;
    pane.focused = true;
    pane.visible = true;
    pane.float_key = float_def.key;
    // Store outer dimensions and style for border rendering
    pane.border_x = outer_x;
    pane.border_y = outer_y;
    pane.border_w = outer_w;
    pane.border_h = outer_h;
    pane.border_color = border_color;
    // Store percentages for resize recalculation
    pane.float_width_pct = @intCast(width_pct);
    pane.float_height_pct = @intCast(height_pct);
    pane.float_pos_x_pct = @intCast(pos_x_pct);
    pane.float_pos_y_pct = @intCast(pos_y_pct);
    pane.float_pad_x = @intCast(pad_x_cfg);
    pane.float_pad_y = @intCast(pad_y_cfg);

    // For pwd floats, store the directory and duplicate it
    if (float_def.pwd) {
        pane.is_pwd = true;
        if (current_dir) |dir| {
            pane.pwd_dir = state.allocator.dupe(u8, dir) catch null;
        }
    }

    // Store style reference (includes border characters and optional module)
    if (float_def.style) |*style| {
        pane.float_style = style;
    }

    // Configure pane notifications
    pane.configureNotifications(&state.config.notifications.pane);

    try state.floating_panes.append(state.allocator, pane);
    state.active_floating = state.floating_panes.items.len - 1;
    state.syncStateToSes();
}

fn renderTo(state: *State, stdout: std.fs.File) !void {
    const renderer = &state.renderer;

    // Begin a new frame
    renderer.beginFrame();

    // Draw tiled panes into the cell buffer
    var pane_it = state.currentLayout().paneIterator();
    while (pane_it.next()) |pane| {
        const render_state = pane.*.getRenderState() catch continue;
        renderer.drawRenderState(render_state, pane.*.x, pane.*.y, pane.*.width, pane.*.height);

        const is_scrolled = pane.*.isScrolled();

        // Draw scroll indicator if pane is scrolled
        if (is_scrolled) {
            drawScrollIndicator(renderer, pane.*.x, pane.*.y, pane.*.width);
        }

        // Draw pane-local notification (PANE realm - bottom of pane)
        if (pane.*.hasActiveNotification()) {
            pane.*.notifications.renderInBounds(renderer, pane.*.x, pane.*.y, pane.*.width, pane.*.height, false);
        }
    }

    // Draw split borders when there are multiple panes
    if (state.currentLayout().paneCount() > 1) {
        drawSplitBorders(state, renderer);
    }

    // Draw visible floating panes (on top of tiled panes)
    // Draw inactive floats first, then active one last so it's on top
    for (state.floating_panes.items, 0..) |pane, i| {
        if (!pane.visible) continue;
        if (state.active_floating == i) continue; // Skip active, draw it last

        drawFloatingBorder(renderer, pane.border_x, pane.border_y, pane.border_w, pane.border_h, false, "", pane.border_color, pane.float_style);

        const render_state = pane.getRenderState() catch continue;
        renderer.drawRenderState(render_state, pane.x, pane.y, pane.width, pane.height);

        if (pane.isScrolled()) {
            drawScrollIndicator(renderer, pane.x, pane.y, pane.width);
        }

        // Draw pane-local notification (PANE realm - bottom of pane)
        if (pane.hasActiveNotification()) {
            pane.notifications.renderInBounds(renderer, pane.x, pane.y, pane.width, pane.height, false);
        }
    }

    // Draw active float last so it's on top
    if (state.active_floating) |idx| {
        const pane = state.floating_panes.items[idx];
        if (pane.visible) {
            drawFloatingBorder(renderer, pane.border_x, pane.border_y, pane.border_w, pane.border_h, true, "", pane.border_color, pane.float_style);

            if (pane.getRenderState()) |render_state| {
                renderer.drawRenderState(render_state, pane.x, pane.y, pane.width, pane.height);
            } else |_| {}

            if (pane.isScrolled()) {
                drawScrollIndicator(renderer, pane.x, pane.y, pane.width);
            }

            // Draw pane-local notification (PANE realm - bottom of pane)
            if (pane.hasActiveNotification()) {
                pane.notifications.renderInBounds(renderer, pane.x, pane.y, pane.width, pane.height, false);
            }
        }
    }

    // Draw status bar if enabled
    if (state.config.panes.status.enabled) {
        drawStatusBar(state, renderer);
    }

    // Draw notifications overlay
    state.notifications.render(renderer, state.term_width, state.term_height);

    // End frame with differential render
    const output = try renderer.endFrame(state.force_full_render);

    // Get cursor info
    var cursor_x: u16 = 1;
    var cursor_y: u16 = 1;
    var cursor_style: u8 = 0;
    var cursor_visible: bool = true;

    if (state.active_floating) |idx| {
        const pane = state.floating_panes.items[idx];
        const pos = pane.getCursorPos();
        cursor_x = pos.x + 1;
        cursor_y = pos.y + 1;
        cursor_style = pane.getCursorStyle();
        cursor_visible = pane.isCursorVisible();
    } else if (state.currentLayout().getFocusedPane()) |pane| {
        const pos = pane.getCursorPos();
        cursor_x = pos.x + 1;
        cursor_y = pos.y + 1;
        cursor_style = pane.getCursorStyle();
        cursor_visible = pane.isCursorVisible();
    }

    // Build cursor sequences
    var cursor_buf: [64]u8 = undefined;
    var cursor_len: usize = 0;

    const style_seq = std.fmt.bufPrint(cursor_buf[cursor_len..], "\x1b[{d} q", .{cursor_style}) catch "";
    cursor_len += style_seq.len;

    const pos_seq = std.fmt.bufPrint(cursor_buf[cursor_len..], "\x1b[{d};{d}H", .{ cursor_y, cursor_x }) catch "";
    cursor_len += pos_seq.len;

    if (cursor_visible) {
        const show_seq = "\x1b[?25h";
        @memcpy(cursor_buf[cursor_len..][0..show_seq.len], show_seq);
        cursor_len += show_seq.len;
    }

    // Write everything as a single iovec list.
    //
    // IMPORTANT: terminal writes can be partial. If we don't fully flush the
    // whole frame, the outer terminal can see truncated CSI/SGR sequences,
    // which matches the observed "38;5;240m" / "[m" garbage artifacts.
    var iovecs = [_]std.posix.iovec_const{
        .{ .base = output.ptr, .len = output.len },
        .{ .base = &cursor_buf, .len = cursor_len },
    };
    try stdout.writevAll(iovecs[0..]);
}

fn drawSplitBorders(state: *State, renderer: *Renderer) void {
    const splits = &state.config.splits;
    const content_height = state.term_height - state.status_height;

    // Get characters and color from config
    const v_char: u21 = if (splits.style) |s| s.vertical else splits.separator_v;
    const h_char: u21 = if (splits.style) |s| s.horizontal else splits.separator_h;
    const color: u8 = splits.color.passive; // splits use passive color

    // Junction characters (only used if style is set)
    const cross_char: u21 = if (splits.style) |s| s.cross else v_char;
    const top_t: u21 = if (splits.style) |s| s.top_t else v_char;
    const bottom_t: u21 = if (splits.style) |s| s.bottom_t else v_char;
    const left_t: u21 = if (splits.style) |s| s.left_t else h_char;
    const right_t: u21 = if (splits.style) |s| s.right_t else h_char;

    // Collect vertical and horizontal line positions
    var v_lines: [64]u16 = undefined;
    var v_line_count: usize = 0;
    var h_lines: [64]u16 = undefined;
    var h_line_count: usize = 0;

    var pane_it = state.currentLayout().paneIterator();
    while (pane_it.next()) |pane| {
        const right_edge = pane.*.x + pane.*.width;
        const bottom_edge = pane.*.y + pane.*.height;

        // Record vertical line position
        if (right_edge < state.term_width and v_line_count < v_lines.len) {
            // Check if already recorded
            var found = false;
            for (v_lines[0..v_line_count]) |x| {
                if (x == right_edge) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                v_lines[v_line_count] = right_edge;
                v_line_count += 1;
            }
        }

        // Record horizontal line position
        if (bottom_edge < content_height and h_line_count < h_lines.len) {
            var found = false;
            for (h_lines[0..h_line_count]) |y| {
                if (y == bottom_edge) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                h_lines[h_line_count] = bottom_edge;
                h_line_count += 1;
            }
        }
    }

    // Draw vertical lines
    for (v_lines[0..v_line_count]) |x| {
        for (0..content_height) |row| {
            const y: u16 = @intCast(row);
            var char = v_char;

            // Check for junctions with horizontal lines
            if (splits.style != null) {
                for (h_lines[0..h_line_count]) |hy| {
                    if (y == hy) {
                        // Check if this is a cross, top_t, or bottom_t
                        const at_top = (y == 0);
                        const at_bottom = (y == content_height - 1);
                        if (at_top) {
                            char = top_t;
                        } else if (at_bottom) {
                            char = bottom_t;
                        } else {
                            char = cross_char;
                        }
                        break;
                    }
                }
            }

            renderer.setCell(x, y, .{ .char = char, .fg = .{ .palette = color } });
        }
    }

    // Draw horizontal lines
    for (h_lines[0..h_line_count]) |y| {
        for (0..state.term_width) |col| {
            const x: u16 = @intCast(col);

            // Skip if already drawn by vertical line (junction)
            var is_junction = false;
            for (v_lines[0..v_line_count]) |vx| {
                if (x == vx) {
                    is_junction = true;
                    break;
                }
            }
            if (is_junction) continue;

            var char = h_char;

            // Check for edge junctions
            if (splits.style != null) {
                const at_left = (x == 0);
                const at_right = (x == state.term_width - 1);
                if (at_left) {
                    char = left_t;
                } else if (at_right) {
                    char = right_t;
                }
            }

            renderer.setCell(x, y, .{ .char = char, .fg = .{ .palette = color } });
        }
    }
}

fn drawScrollIndicator(renderer: *Renderer, pane_x: u16, pane_y: u16, pane_width: u16) void {
    // Display a scroll indicator at top-right of pane
    const indicator = " \xe2\x96\xb2\xe2\x96\xb2\xe2\x96\xb2 "; // " ▲▲▲ "
    const indicator_chars = [_]u21{ ' ', 0x25b2, 0x25b2, 0x25b2, ' ' };

    // Position at top-right corner (inside pane bounds)
    const indicator_len: u16 = 5;
    const x_pos = pane_x + pane_width -| indicator_len;

    // Yellow background (palette 3), black text (palette 0)
    for (indicator_chars, 0..) |char, i| {
        renderer.setCell(x_pos + @as(u16, @intCast(i)), pane_y, .{
            .char = char,
            .fg = .{ .palette = 0 }, // black
            .bg = .{ .palette = 3 }, // yellow
        });
    }
    _ = indicator;
}

fn drawFloatingBorder(renderer: *Renderer, x: u16, y: u16, w: u16, h: u16, active: bool, name: []const u8, border_color: core.BorderColor, style: ?*const core.FloatStyle) void {
    const color = if (active) border_color.active else border_color.passive;
    const fg: render.Color = .{ .palette = color };
    const bold = active;

    // Get border characters from style or use defaults
    const top_left: u21 = if (style) |s| s.top_left else 0x256D;
    const top_right: u21 = if (style) |s| s.top_right else 0x256E;
    const bottom_left: u21 = if (style) |s| s.bottom_left else 0x2570;
    const bottom_right: u21 = if (style) |s| s.bottom_right else 0x256F;
    const horizontal: u21 = if (style) |s| s.horizontal else 0x2500;
    const vertical: u21 = if (style) |s| s.vertical else 0x2502;

    // Clear the interior with spaces first
    for (1..h -| 1) |row| {
        for (1..w -| 1) |col| {
            renderer.setCell(x + @as(u16, @intCast(col)), y + @as(u16, @intCast(row)), .{
                .char = ' ',
            });
        }
    }

    // Top-left corner
    renderer.setCell(x, y, .{ .char = top_left, .fg = fg, .bold = bold });

    // Top border with optional title (centered)
    if (name.len > 0) {
        var title_buf: [32]u8 = undefined;
        const title = std.fmt.bufPrint(&title_buf, "[ {s} ]", .{name}) catch "[ float ]";
        const title_start = @as(usize, (w -| 2) -| title.len) / 2;

        for (0..w -| 2) |col| {
            const char: u21 = if (col >= title_start and col < title_start + title.len)
                title[col - title_start]
            else
                horizontal;
            renderer.setCell(x + @as(u16, @intCast(col)) + 1, y, .{ .char = char, .fg = fg, .bold = bold });
        }
    } else {
        for (0..w -| 2) |col| {
            renderer.setCell(x + @as(u16, @intCast(col)) + 1, y, .{ .char = horizontal, .fg = fg, .bold = bold });
        }
    }

    // Top-right corner
    renderer.setCell(x + w - 1, y, .{ .char = top_right, .fg = fg, .bold = bold });

    // Side borders
    for (1..h -| 1) |row| {
        renderer.setCell(x, y + @as(u16, @intCast(row)), .{ .char = vertical, .fg = fg, .bold = bold });
        renderer.setCell(x + w - 1, y + @as(u16, @intCast(row)), .{ .char = vertical, .fg = fg, .bold = bold });
    }

    // Bottom-left corner
    renderer.setCell(x, y + h - 1, .{ .char = bottom_left, .fg = fg, .bold = bold });

    // Bottom border
    for (0..w -| 2) |col| {
        renderer.setCell(x + @as(u16, @intCast(col)) + 1, y + h - 1, .{ .char = horizontal, .fg = fg, .bold = bold });
    }

    // Bottom-right corner
    renderer.setCell(x + w - 1, y + h - 1, .{ .char = bottom_right, .fg = fg, .bold = bold });

    // Render module in border if present
    if (style) |s| {
        if (s.module) |*module| {
            if (s.position) |pos| {
                // Run the module to get output
                var output_buf: [256]u8 = undefined;
                const output = runStatusModule(module, &output_buf) catch "";
                if (output.len == 0) return;

                // Render styled output
                const segments = renderModuleOutput(module, output);

                // Calculate position based on style position
                const total_len = segments.total_len;
                var draw_x: u16 = undefined;
                var draw_y: u16 = undefined;

                switch (pos) {
                    .topleft => {
                        draw_x = x + 2;
                        draw_y = y;
                    },
                    .topcenter => {
                        draw_x = x + @as(u16, @intCast((w -| total_len) / 2));
                        draw_y = y;
                    },
                    .topright => {
                        draw_x = x + w -| 2 -| @as(u16, @intCast(total_len));
                        draw_y = y;
                    },
                    .bottomleft => {
                        draw_x = x + 2;
                        draw_y = y + h - 1;
                    },
                    .bottomcenter => {
                        draw_x = x + @as(u16, @intCast((w -| total_len) / 2));
                        draw_y = y + h - 1;
                    },
                    .bottomright => {
                        draw_x = x + w -| 2 -| @as(u16, @intCast(total_len));
                        draw_y = y + h - 1;
                    },
                }

                // Draw each segment with its style
                var cur_x = draw_x;
                for (segments.items[0..segments.count]) |seg| {
                    for (seg.text) |ch| {
                        renderer.setCell(cur_x, draw_y, .{
                            .char = ch,
                            .fg = seg.fg,
                            .bg = seg.bg,
                            .bold = seg.bold,
                            .italic = seg.italic,
                        });
                        cur_x += 1;
                    }
                }
            }
        }
    }
}

const RenderedSegment = struct {
    text: []const u8,
    fg: render.Color,
    bg: render.Color,
    bold: bool,
    italic: bool,
};

const RenderedSegments = struct {
    items: [16]RenderedSegment,
    buffers: [16][64]u8, // Each segment gets its own buffer
    count: usize,
    total_len: usize,
};

fn renderModuleOutput(module: *const core.StatusModule, output: []const u8) RenderedSegments {
    var result = RenderedSegments{
        .items = undefined,
        .buffers = undefined,
        .count = 0,
        .total_len = 0,
    };

    for (module.outputs) |out| {
        if (result.count >= 16) break;

        // Replace $output in format with actual output
        var text_len: usize = 0;
        var i: usize = 0;
        while (i < out.format.len and text_len < 64) {
            if (i + 6 < out.format.len and std.mem.eql(u8, out.format[i .. i + 7], "$output")) {
                const copy_len = @min(output.len, 64 - text_len);
                @memcpy(result.buffers[result.count][text_len .. text_len + copy_len], output[0..copy_len]);
                text_len += copy_len;
                i += 7;
            } else {
                result.buffers[result.count][text_len] = out.format[i];
                text_len += 1;
                i += 1;
            }
        }

        // Parse style
        const style = pop.Style.parse(out.style);

        result.items[result.count] = .{
            .text = result.buffers[result.count][0..text_len],
            .fg = if (style.fg != .none) styleColorToRender(style.fg) else .none,
            .bg = if (style.bg != .none) styleColorToRender(style.bg) else .none,
            .bold = style.bold,
            .italic = style.italic,
        };
        result.total_len += text_len;
        result.count += 1;
    }

    return result;
}

fn styleColorToRender(col: pop.Color) render.Color {
    return switch (col) {
        .none => .none,
        .palette => |p| .{ .palette = p },
        .rgb => |rgb| .{ .rgb = .{ .r = rgb.r, .g = rgb.g, .b = rgb.b } },
    };
}

fn runStatusModule(module: *const core.StatusModule, buf: []u8) ![]const u8 {
    // For custom commands, run them
    if (module.command) |cmd| {
        const result = std.process.Child.run(.{
            .allocator = std.heap.page_allocator,
            .argv = &.{ "/bin/sh", "-c", cmd },
        }) catch return "";
        defer std.heap.page_allocator.free(result.stdout);
        defer std.heap.page_allocator.free(result.stderr);

        // Copy to buffer, strip trailing newline
        var len = result.stdout.len;
        while (len > 0 and (result.stdout[len - 1] == '\n' or result.stdout[len - 1] == '\r')) {
            len -= 1;
        }
        const copy_len = @min(len, buf.len);
        @memcpy(buf[0..copy_len], result.stdout[0..copy_len]);
        return buf[0..copy_len];
    }

    // For built-in modules, delegate to status module system
    // For now just return module name as placeholder
    const copy_len = @min(module.name.len, buf.len);
    @memcpy(buf[0..copy_len], module.name[0..copy_len]);
    return buf[0..copy_len];
}

fn drawStatusBar(state: *State, renderer: *Renderer) void {
    const y = state.term_height - 1;
    const width = state.term_width;
    const cfg = &state.config.panes.status;

    // Clear status bar
    for (0..width) |xi| {
        renderer.setCell(@intCast(xi), y, .{ .char = ' ' });
    }

    // Create pop context
    var ctx = pop.Context.init(state.allocator);
    defer ctx.deinit();
    ctx.terminal_width = width;

    // Collect tab names for center section (shows tabs, not panes within a tab)
    var tab_names: [16][]const u8 = undefined;
    var tab_count: usize = 0;
    for (state.tabs.items) |*tab| {
        if (tab_count < 16) {
            // Use the focused pane's pwd as tab name
            if (tab.layout.getFocusedPane()) |pane| {
                const pwd = pane.getPwd();
                tab_names[tab_count] = if (pwd) |p| std.fs.path.basename(p) else "tab";
            } else {
                tab_names[tab_count] = "tab";
            }
            tab_count += 1;
        }
    }
    ctx.pane_names = tab_names[0..tab_count];
    ctx.active_pane = state.active_tab;
    ctx.session_name = state.session_name;

    // === DRAW LEFT SECTION ===
    var left_x: u16 = 0;
    for (cfg.left) |mod| {
        left_x = drawModule(renderer, &ctx, mod, left_x, y);
    }

    // === CALCULATE RIGHT WIDTH ===
    var right_width: u16 = 0;
    for (cfg.right) |mod| {
        right_width += calcModuleWidth(&ctx, mod);
    }
    const right_start = width -| right_width;

    // === DRAW RIGHT SECTION ===
    var rx: u16 = right_start;
    for (cfg.right) |mod| {
        rx = drawModule(renderer, &ctx, mod, rx, y);
    }

    // === CALCULATE CENTER WIDTH ===
    var center_width: u16 = 0;
    for (cfg.center) |mod| {
        if (std.mem.eql(u8, mod.name, "panes")) {
            for (ctx.pane_names, 0..) |pane_name, i| {
                if (i > 0) center_width += @as(u16, @intCast(mod.separator.len));
                center_width += 2 + @as(u16, @intCast(pane_name.len)) + 2; // arrows + space + name + space
            }
        }
    }

    // === DRAW CENTER SECTION (truly centered) ===
    const center_start = (width -| center_width) / 2;
    if (center_start > left_x + 2 and center_start + center_width < right_start -| 2) {
        var cx: u16 = center_start;
        for (cfg.center) |mod| {
            if (std.mem.eql(u8, mod.name, "panes")) {
                const active_style = pop.Style.parse(mod.active_style);
                const inactive_style = pop.Style.parse(mod.inactive_style);
                const sep_style = pop.Style.parse(mod.separator_style);

                for (ctx.pane_names, 0..) |pane_name, i| {
                    if (i > 0) {
                        cx = drawStyledText(renderer, cx, y, mod.separator, sep_style);
                    }
                    const is_active = i == ctx.active_pane;
                    const style = if (is_active) active_style else inactive_style;
                    const arrow_fg = if (is_active) active_style.bg else inactive_style.bg;
                    const arrow_style = pop.Style{ .fg = arrow_fg };

                    cx = drawStyledText(renderer, cx, y, "", arrow_style);
                    cx = drawStyledText(renderer, cx, y, " ", style);
                    cx = drawStyledText(renderer, cx, y, pane_name, style);
                    cx = drawStyledText(renderer, cx, y, " ", style);
                    cx = drawStyledText(renderer, cx, y, "", arrow_style);
                }
            }
        }
    }
}

fn drawModule(renderer: *Renderer, ctx: *pop.Context, mod: core.config.StatusModule, start_x: u16, y: u16) u16 {
    var x = start_x;

    // Get the output text for this module
    var output_text: []const u8 = "";

    // Special handling for "session"
    if (std.mem.eql(u8, mod.name, "session")) {
        output_text = ctx.session_name;
    } else {
        // Render segment to get output text
        if (ctx.renderSegment(mod.name)) |segs| {
            if (segs.len > 0) {
                output_text = segs[0].text;
            }
        }
    }

    // Draw each output in the array
    for (mod.outputs) |out| {
        const style = pop.Style.parse(out.style);
        x = drawFormatted(renderer, x, y, out.format, output_text, style);
    }

    return x;
}

fn drawFormatted(renderer: *Renderer, start_x: u16, y: u16, format: []const u8, output: []const u8, style: pop.Style) u16 {
    var x = start_x;
    var i: usize = 0;

    while (i < format.len) {
        // Look for $output
        if (i + 7 <= format.len and std.mem.eql(u8, format[i..][0..7], "$output")) {
            x = drawStyledText(renderer, x, y, output, style);
            i += 7;
        } else {
            // Draw single char (handle UTF-8)
            const len = std.unicode.utf8ByteSequenceLength(format[i]) catch 1;
            const end = @min(i + len, format.len);
            x = drawStyledText(renderer, x, y, format[i..end], style);
            i = end;
        }
    }
    return x;
}

fn calcModuleWidth(ctx: *pop.Context, mod: core.config.StatusModule) u16 {
    var width: u16 = 0;

    // Get the output text for this module
    var output_text: []const u8 = "";

    // Special handling for "session"
    if (std.mem.eql(u8, mod.name, "session")) {
        output_text = ctx.session_name;
    } else {
        // Render segment to get output text
        if (ctx.renderSegment(mod.name)) |segs| {
            if (segs.len > 0) {
                output_text = segs[0].text;
            }
        }
    }

    // Sum width of all outputs
    for (mod.outputs) |out| {
        width += calcFormattedWidth(out.format, output_text);
    }

    return width;
}

fn calcFormattedWidth(format: []const u8, output: []const u8) u16 {
    var width: u16 = 0;
    var i: usize = 0;

    while (i < format.len) {
        if (i + 7 <= format.len and std.mem.eql(u8, format[i..][0..7], "$output")) {
            // Count output chars
            var j: usize = 0;
            while (j < output.len) {
                const len = std.unicode.utf8ByteSequenceLength(output[j]) catch 1;
                j += len;
                width += 1;
            }
            i += 7;
        } else {
            const len = std.unicode.utf8ByteSequenceLength(format[i]) catch 1;
            i += len;
            width += 1;
        }
    }
    return width;
}

fn drawSegment(renderer: *Renderer, x: u16, y: u16, seg: pop.Segment, default_style: pop.Style) u16 {
    const style = if (seg.style.isEmpty()) default_style else seg.style;
    return drawStyledText(renderer, x, y, seg.text, style);
}

fn drawStyledText(renderer: *Renderer, start_x: u16, y: u16, text: []const u8, style: pop.Style) u16 {
    var x = start_x;
    var i: usize = 0;

    while (i < text.len) {
        // Decode UTF-8 codepoint
        const len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        const codepoint = std.unicode.utf8Decode(text[i..][0..len]) catch ' ';

        var cell = render.Cell{
            .char = codepoint,
            .bold = style.bold,
            .italic = style.italic,
        };

        // Convert pop.Color to render.Color
        switch (style.fg) {
            .none => {},
            .palette => |p| cell.fg = .{ .palette = p },
            .rgb => |rgb| cell.fg = .{ .rgb = .{ .r = rgb.r, .g = rgb.g, .b = rgb.b } },
        }
        switch (style.bg) {
            .none => {},
            .palette => |p| cell.bg = .{ .palette = p },
            .rgb => |rgb| cell.bg = .{ .rgb = .{ .r = rgb.r, .g = rgb.g, .b = rgb.b } },
        }

        renderer.setCell(x, y, cell);
        x += 1;
        i += len;
    }

    return x;
}

fn getTermSize() struct { cols: u16, rows: u16 } {
    var ws: c.winsize = undefined;
    if (c.ioctl(posix.STDOUT_FILENO, c.TIOCGWINSZ, &ws) == 0) {
        return .{
            .cols = if (ws.ws_col > 0) ws.ws_col else 80,
            .rows = if (ws.ws_row > 0) ws.ws_row else 24,
        };
    }
    return .{ .cols = 80, .rows = 24 };
}

fn enableRawMode(fd: posix.fd_t) !posix.termios {
    var termios = try posix.tcgetattr(fd);
    const orig = termios;

    termios.iflag.BRKINT = false;
    termios.iflag.ICRNL = false;
    termios.iflag.INPCK = false;
    termios.iflag.ISTRIP = false;
    termios.iflag.IXON = false;
    termios.oflag.OPOST = false;
    termios.cflag.CSIZE = .CS8;
    termios.lflag.ECHO = false;
    termios.lflag.ICANON = false;
    termios.lflag.IEXTEN = false;
    termios.lflag.ISIG = false;
    termios.cc[@intFromEnum(posix.V.MIN)] = 1;
    termios.cc[@intFromEnum(posix.V.TIME)] = 0;

    try posix.tcsetattr(fd, .FLUSH, termios);
    return orig;
}

fn disableRawMode(fd: posix.fd_t, orig: posix.termios) !void {
    try posix.tcsetattr(fd, .FLUSH, orig);
}
