const std = @import("std");
const Session = @import("session.zig").Session;

pub const SessionManager = struct {
    allocator: std.mem.Allocator,
    sessions: std.ArrayList(Session) = .empty,
    active_index: usize = 0,

    pub fn init(allocator: std.mem.Allocator) SessionManager {
        return SessionManager{ .allocator = allocator };
    }

    pub fn deinit(self: *SessionManager) void {
        for (self.sessions.items) |*session| {
            session.deinit();
        }
        self.sessions.deinit(self.allocator);
    }

    pub fn createSession(self: *SessionManager, name: []const u8) !void {
        try self.sessions.append(self.allocator, try Session.init(self.allocator, name));
        self.active_index = self.sessions.items.len - 1;
    }

    pub fn attachSession(self: *SessionManager, index: usize) bool {
        if (index >= self.sessions.items.len) return false;
        self.active_index = index;
        return true;
    }

    pub fn activeSession(self: *SessionManager) *Session {
        return &self.sessions.items[self.active_index];
    }

    pub fn listSessions(self: *SessionManager, allocator: std.mem.Allocator) ![][]const u8 {
        const list = try allocator.alloc([]const u8, self.sessions.items.len);
        for (self.sessions.items, 0..) |session, i| {
            const marker = if (i == self.active_index) "*" else " ";
            list[i] = try std.fmt.allocPrint(allocator, "{s} {s}", .{ marker, session.name });
        }
        return list;
    }

    pub fn sessionCount(self: *SessionManager) usize {
        return self.sessions.items.len;
    }
};
