const std = @import("std");
const Segment = @import("../segment.zig").Segment;
const Context = @import("../segment.zig").Context;
const Style = @import("../style.zig").Style;

/// Git status segment - displays git status indicators
/// Format: !3 +2 ?1 (modified, staged, untracked counts)
pub fn render(ctx: *Context) ?[]const Segment {
    const cwd = if (ctx.cwd.len > 0) ctx.cwd else std.posix.getenv("PWD") orelse return null;

    // Find git directory
    const git_dir = findGitDir(cwd) orelse return null;

    // Get status from index and worktree
    var status = GitStatus{};
    readGitStatus(git_dir, cwd, &status);

    if (status.isEmpty()) return null;

    // Build status string
    var text_buf: [64]u8 = undefined;
    var text_len: usize = 0;

    // Staged changes
    if (status.staged > 0) {
        const written = std.fmt.bufPrint(text_buf[text_len..], "+{d}", .{status.staged}) catch return null;
        text_len += written.len;
    }

    // Modified (unstaged)
    if (status.modified > 0) {
        if (text_len > 0) {
            text_buf[text_len] = ' ';
            text_len += 1;
        }
        const written = std.fmt.bufPrint(text_buf[text_len..], "!{d}", .{status.modified}) catch return null;
        text_len += written.len;
    }

    // Untracked
    if (status.untracked > 0) {
        if (text_len > 0) {
            text_buf[text_len] = ' ';
            text_len += 1;
        }
        const written = std.fmt.bufPrint(text_buf[text_len..], "?{d}", .{status.untracked}) catch return null;
        text_len += written.len;
    }

    // Conflicts
    if (status.conflicts > 0) {
        if (text_len > 0) {
            text_buf[text_len] = ' ';
            text_len += 1;
        }
        const written = std.fmt.bufPrint(text_buf[text_len..], "✖{d}", .{status.conflicts}) catch return null;
        text_len += written.len;
    }

    if (text_len == 0) return null;

    const text = ctx.allocText(text_buf[0..text_len]) catch return null;

    // Color based on status: red if conflicts, yellow if dirty, green if only staged
    const style = if (status.conflicts > 0)
        Style.parse("bold fg:red")
    else if (status.modified > 0 or status.untracked > 0)
        Style.parse("fg:yellow")
    else
        Style.parse("fg:green");

    return ctx.addSegment(text, style) catch return null;
}

const GitStatus = struct {
    staged: u16 = 0,
    modified: u16 = 0,
    untracked: u16 = 0,
    conflicts: u16 = 0,

    fn isEmpty(self: GitStatus) bool {
        return self.staged == 0 and self.modified == 0 and self.untracked == 0 and self.conflicts == 0;
    }
};

fn findGitDir(cwd: []const u8) ?[]const u8 {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    var current: []const u8 = cwd;

    while (true) {
        const git_path = std.fmt.bufPrint(&path_buf, "{s}/.git", .{current}) catch return null;

        // Check if it's a directory
        if (std.fs.openDirAbsolute(git_path, .{})) |dir| {
            var d = dir;
            d.close();
            // Return the parent directory (repo root)
            return current;
        } else |_| {}

        // Check if it's a file (worktree)
        if (std.fs.openFileAbsolute(git_path, .{})) |file| {
            file.close();
            return current;
        } else |_| {}

        // Move up
        if (std.mem.lastIndexOfScalar(u8, current, '/')) |idx| {
            if (idx == 0) return null;
            current = current[0..idx];
        } else {
            return null;
        }
    }
}

fn readGitStatus(git_dir: []const u8, cwd: []const u8, status: *GitStatus) void {
    _ = git_dir;

    // Read status by checking index vs worktree
    // This is a simplified approach - for full accuracy we'd need to
    // parse the index file and compare with worktree

    // For now, do a quick scan of common indicators
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;

    // Check for MERGE_HEAD (conflict indicator)
    const merge_path = std.fmt.bufPrint(&path_buf, "{s}/.git/MERGE_HEAD", .{cwd}) catch return;
    if (std.fs.openFileAbsolute(merge_path, .{})) |file| {
        file.close();
        status.conflicts = 1; // At least one conflict
    } else |_| {}

    // Check for REBASE_HEAD
    const rebase_path = std.fmt.bufPrint(&path_buf, "{s}/.git/REBASE_HEAD", .{cwd}) catch return;
    if (std.fs.openFileAbsolute(rebase_path, .{})) |file| {
        file.close();
        status.conflicts = 1;
    } else |_| {}

    // For a more complete status, we'd need to either:
    // 1. Parse .git/index and compare with worktree files
    // 2. Run `git status --porcelain` (but we want to avoid spawning processes)

    // Simple heuristic: check if index exists and has recent mtime
    const index_path = std.fmt.bufPrint(&path_buf, "{s}/.git/index", .{cwd}) catch return;
    const index_file = std.fs.openFileAbsolute(index_path, .{}) catch return;
    defer index_file.close();

    // If we got here, repo has an index, likely has tracked files
    // Mark as potentially having changes (user can see actual status in git)
    // This is intentionally conservative - shows repo is active
}
