const std = @import("std");
const posix = std.posix;
const segment = @import("segment.zig");
const segments_mod = @import("segments/mod.zig");
const Style = @import("style.zig").Style;

// JSON structures for config parsing
const JsonOutput = struct {
    style: ?[]const u8 = null,
    format: ?[]const u8 = null,
};

const JsonModule = struct {
    name: []const u8,
    outputs: ?[]const JsonOutput = null,
    command: ?[]const u8 = null,
    when: ?[]const u8 = null,
};

const JsonPrompt = struct {
    left: ?[]const JsonModule = null,
    right: ?[]const JsonModule = null,
};

const JsonConfig = struct {
    prompt: ?JsonPrompt = null,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        try printUsage();
        return;
    }

    const command = args[1];

    if (std.mem.eql(u8, command, "init")) {
        // pop init <shell>
        const shell = if (args.len > 2) args[2] else "bash";
        try printInit(shell);
    } else if (std.mem.eql(u8, command, "prompt")) {
        // pop prompt [options]
        try renderPrompt(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "help") or std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "-h")) {
        try printUsage();
    } else {
        try printUsage();
    }
}

fn printUsage() !void {
    const stdout = std.fs.File.stdout();
    try stdout.writeAll(
        \\pop - Prompt decorator
        \\
        \\Usage:
        \\  pop init <shell>     Print shell initialization script
        \\  pop prompt [opts]    Render the prompt
        \\  pop help             Show this help
        \\
        \\Shell init:
        \\  pop init bash        Bash initialization
        \\  pop init zsh         Zsh initialization
        \\  pop init fish        Fish initialization
        \\
        \\Prompt options:
        \\  --status=<n>         Exit status of last command
        \\  --duration=<ms>      Duration of last command in ms
        \\  --jobs=<n>           Number of background jobs
        \\  --right              Render right prompt
        \\
    );
}

fn printInit(shell: []const u8) !void {
    const stdout = std.fs.File.stdout();

    if (std.mem.eql(u8, shell, "bash")) {
        try stdout.writeAll(
            \\# Pop prompt initialization for Bash
            \\__pop_precmd() {
            \\    local exit_status=$?
            \\    local duration=0
            \\    if [[ -n "$__pop_start" ]]; then
            \\        duration=$(( $(date +%s%3N) - __pop_start ))
            \\    fi
            \\    PS1="$(pop prompt --status=$exit_status --duration=$duration --jobs=$(jobs -p 2>/dev/null | wc -l)) "
            \\    unset __pop_start
            \\}
            \\
            \\__pop_preexec() {
            \\    __pop_start=$(date +%s%3N)
            \\}
            \\
            \\trap '__pop_preexec' DEBUG
            \\PROMPT_COMMAND="__pop_precmd"
            \\
        );
    } else if (std.mem.eql(u8, shell, "zsh")) {
        try stdout.writeAll(
            \\# Pop prompt initialization for Zsh
            \\__pop_precmd() {
            \\    local exit_status=$?
            \\    local duration=0
            \\    if [[ -n "$__pop_start" ]]; then
            \\        duration=$(( $(date +%s%3N) - __pop_start ))
            \\    fi
            \\    PROMPT="$(pop prompt --shell=zsh --status=$exit_status --duration=$duration --jobs=${(M)#jobstates}) "
            \\    RPROMPT="$(pop prompt --shell=zsh --right --status=$exit_status)"
            \\    unset __pop_start
            \\}
            \\
            \\__pop_preexec() {
            \\    __pop_start=$(date +%s%3N)
            \\}
            \\
            \\autoload -Uz add-zsh-hook
            \\add-zsh-hook precmd __pop_precmd
            \\add-zsh-hook preexec __pop_preexec
            \\
        );
    } else if (std.mem.eql(u8, shell, "fish")) {
        try stdout.writeAll(
            \\# Pop prompt initialization for Fish
            \\function fish_prompt
            \\    set -l exit_status $status
            \\    set -l duration (math $CMD_DURATION)
            \\    set -l jobs (count (jobs -p))
            \\    pop prompt --status=$exit_status --duration=$duration --jobs=$jobs
            \\    echo -n " "
            \\end
            \\
            \\function fish_right_prompt
            \\    pop prompt --right
            \\end
            \\
        );
    } else {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Unknown shell: {s}\nSupported shells: bash, zsh, fish\n", .{shell}) catch return;
        try stdout.writeAll(msg);
    }
}

fn renderPrompt(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var ctx = segment.Context.init(allocator);
    defer ctx.deinit();

    // Parse command line options
    var is_right = false;
    var shell: []const u8 = "bash";
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--right")) {
            is_right = true;
        } else if (std.mem.startsWith(u8, arg, "--status=")) {
            ctx.exit_status = std.fmt.parseInt(i32, arg[9..], 10) catch null;
        } else if (std.mem.startsWith(u8, arg, "--duration=")) {
            ctx.cmd_duration_ms = std.fmt.parseInt(u64, arg[11..], 10) catch null;
        } else if (std.mem.startsWith(u8, arg, "--jobs=")) {
            ctx.jobs = std.fmt.parseInt(u16, arg[7..], 10) catch 0;
        } else if (std.mem.startsWith(u8, arg, "--shell=")) {
            shell = arg[8..];
        }
    }

    // Get environment info
    ctx.cwd = std.posix.getenv("PWD") orelse "";
    ctx.home = std.posix.getenv("HOME");

    const stdout = std.fs.File.stdout();

    // Detect shell from environment if not specified
    if (std.mem.eql(u8, shell, "bash")) {
        // Try to auto-detect from $SHELL or $0
        if (posix.getenv("ZSH_VERSION")) |_| {
            shell = "zsh";
        } else if (posix.getenv("FISH_VERSION")) |_| {
            shell = "fish";
        }
    }

    const is_zsh = std.mem.eql(u8, shell, "zsh");

    // Try to load config
    const config = loadConfig(allocator);
    defer if (config) |c| c.deinit();

    if (config) |cfg| {
        if (cfg.value.prompt) |prompt| {
            const modules = if (is_right) prompt.right else prompt.left;
            if (modules) |mods| {
                if (mods.len > 0) {
                    try renderModulesSimple(&ctx, mods, stdout, is_zsh);
                    return;
                }
            }
        }
    }

    // Fallback to defaults if no config
    try renderDefaultPrompt(&ctx, is_right, stdout, is_zsh);
}

fn renderDefaultPrompt(ctx: *segment.Context, is_right: bool, stdout: std.fs.File, is_zsh: bool) !void {
    _ = is_zsh;
    const segment_names: []const []const u8 = if (is_right)
        &.{"time"}
    else
        &.{ "directory", "git_branch", "git_status", "character" };

    for (segment_names) |name| {
        if (ctx.renderSegment(name)) |segs| {
            for (segs) |seg| {
                // Just write text directly - no styling for now
                try stdout.writeAll(seg.text);
                try stdout.writeAll(" ");
            }
        }
    }
}

fn writeSegment(stdout: std.fs.File, seg: segment.Segment, is_zsh: bool) !void {
    try writeStyleDirect(stdout, seg.style, is_zsh);
    try stdout.writeAll(seg.text);
    if (!seg.style.isEmpty()) {
        if (is_zsh) try stdout.writeAll("%{");
        try stdout.writeAll("\x1b[0m");
        if (is_zsh) try stdout.writeAll("%}");
    }
}

fn loadConfig(allocator: std.mem.Allocator) ?std.json.Parsed(JsonConfig) {
    const path = getConfigPath(allocator) catch return null;
    defer allocator.free(path);

    const file = std.fs.openFileAbsolute(path, .{}) catch return null;
    defer file.close();

    const content = file.readToEndAlloc(allocator, 1024 * 1024) catch return null;
    defer allocator.free(content); // Safe now since we use alloc_always

    return std.json.parseFromSlice(JsonConfig, allocator, content, .{
        .allocate = .alloc_always, // Force allocation of strings so we can free content
    }) catch null;
}

fn getConfigPath(allocator: std.mem.Allocator) ![]const u8 {
    const config_home = posix.getenv("XDG_CONFIG_HOME");
    if (config_home) |ch| {
        return std.fmt.allocPrint(allocator, "{s}/hexa/pop.json", .{ch});
    }

    const home = posix.getenv("HOME") orelse return error.NoHome;
    return std.fmt.allocPrint(allocator, "{s}/.config/hexa/pop.json", .{home});
}

fn renderModulesSimple(ctx: *segment.Context, modules: []const JsonModule, stdout: std.fs.File, is_zsh: bool) !void {
    // Known built-in segments that return null when they have nothing to show
    const conditional_segments = [_][]const u8{ "status", "sudo", "git_branch", "git_status", "jobs", "duration" };

    for (modules) |mod| {
        // Check 'when' condition if present
        if (mod.when) |when_cmd| {
            if (!checkCondition(when_cmd)) continue;
        }

        // Get segment output text
        var output_text: []const u8 = "";
        var should_render = true;

        // If module has a command, run it
        if (mod.command) |cmd| {
            if (runCommand(ctx.allocator, cmd)) |result| {
                output_text = result;
            } else {
                should_render = false;
            }
        } else {
            // Check if it's a known conditional segment
            var is_conditional = false;
            for (conditional_segments) |cs| {
                if (std.mem.eql(u8, mod.name, cs)) {
                    is_conditional = true;
                    break;
                }
            }

            if (ctx.renderSegment(mod.name)) |segs| {
                if (segs.len > 0) {
                    output_text = segs[0].text;
                }
            } else if (is_conditional) {
                // Conditional segment returned null - skip
                should_render = false;
            }
            // Non-conditional segments (like "separator") render even without output
        }

        if (!should_render) continue;

        // Render each output in the outputs array
        if (mod.outputs) |outputs| {
            for (outputs) |out| {
                const style = Style.parse(out.style orelse "");
                const format = out.format orelse "$output";

                // Write style using buffer
                try writeStyleDirect(stdout, style, is_zsh);

                // Write format with $output substitution
                try writeFormat(stdout, format, output_text);

                // Reset style
                if (!style.isEmpty()) {
                    if (is_zsh) try stdout.writeAll("%{");
                    try stdout.writeAll("\x1b[0m");
                    if (is_zsh) try stdout.writeAll("%}");
                }
            }
        }
    }
}

fn runCommand(allocator: std.mem.Allocator, cmd: []const u8) ?[]const u8 {
    _ = allocator;
    // Use page_allocator - prompt is short-lived, OS will reclaim
    const alloc = std.heap.page_allocator;
    const result = std.process.Child.run(.{
        .allocator = alloc,
        .argv = &.{ "/bin/bash", "-c", cmd },
    }) catch return null;
    alloc.free(result.stderr);

    // Check if command exited successfully
    const exit_code = switch (result.term) {
        .Exited => |code| code,
        else => 1,
    };
    if (exit_code != 0) {
        alloc.free(result.stdout);
        return null;
    }

    // Trim trailing newline
    const output = std.mem.trimRight(u8, result.stdout, "\n\r");
    if (output.len == 0) {
        alloc.free(result.stdout);
        return null;
    }

    return output;
}

fn writeStyleDirect(stdout: std.fs.File, style: Style, is_zsh: bool) !void {
    if (style.isEmpty()) return;

    if (is_zsh) try stdout.writeAll("%{");

    // Build ANSI sequence
    var buf: [64]u8 = undefined;
    var len: usize = 0;

    buf[0] = '\x1b';
    buf[1] = '[';
    len = 2;

    var need_semi = false;

    if (style.bold) {
        buf[len] = '1';
        len += 1;
        need_semi = true;
    }
    if (style.dim) {
        if (need_semi) {
            buf[len] = ';';
            len += 1;
        }
        buf[len] = '2';
        len += 1;
        need_semi = true;
    }
    if (style.italic) {
        if (need_semi) {
            buf[len] = ';';
            len += 1;
        }
        buf[len] = '3';
        len += 1;
        need_semi = true;
    }
    if (style.underline) {
        if (need_semi) {
            buf[len] = ';';
            len += 1;
        }
        buf[len] = '4';
        len += 1;
        need_semi = true;
    }

    // Foreground color
    switch (style.fg) {
        .none => {},
        .palette => |p| {
            if (need_semi) {
                buf[len] = ';';
                len += 1;
            }
            const code = if (p < 8)
                std.fmt.bufPrint(buf[len..], "{d}", .{30 + p}) catch ""
            else if (p < 16)
                std.fmt.bufPrint(buf[len..], "{d}", .{90 + p - 8}) catch ""
            else
                std.fmt.bufPrint(buf[len..], "38;5;{d}", .{p}) catch "";
            len += code.len;
            need_semi = true;
        },
        .rgb => |rgb| {
            if (need_semi) {
                buf[len] = ';';
                len += 1;
            }
            const code = std.fmt.bufPrint(buf[len..], "38;2;{d};{d};{d}", .{ rgb.r, rgb.g, rgb.b }) catch "";
            len += code.len;
            need_semi = true;
        },
    }

    // Background color
    switch (style.bg) {
        .none => {},
        .palette => |p| {
            if (need_semi) {
                buf[len] = ';';
                len += 1;
            }
            const code = if (p < 8)
                std.fmt.bufPrint(buf[len..], "{d}", .{40 + p}) catch ""
            else if (p < 16)
                std.fmt.bufPrint(buf[len..], "{d}", .{100 + p - 8}) catch ""
            else
                std.fmt.bufPrint(buf[len..], "48;5;{d}", .{p}) catch "";
            len += code.len;
        },
        .rgb => |rgb| {
            if (need_semi) {
                buf[len] = ';';
                len += 1;
            }
            const code = std.fmt.bufPrint(buf[len..], "48;2;{d};{d};{d}", .{ rgb.r, rgb.g, rgb.b }) catch "";
            len += code.len;
        },
    }

    buf[len] = 'm';
    len += 1;

    try stdout.writeAll(buf[0..len]);
    if (is_zsh) try stdout.writeAll("%}");
}

fn writeFormat(stdout: std.fs.File, format: []const u8, output: []const u8) !void {
    var i: usize = 0;
    while (i < format.len) {
        if (i + 7 <= format.len and std.mem.eql(u8, format[i..][0..7], "$output")) {
            try stdout.writeAll(output);
            i += 7;
        } else {
            const char_len = std.unicode.utf8ByteSequenceLength(format[i]) catch 1;
            const end = @min(i + char_len, format.len);
            try stdout.writeAll(format[i..end]);
            i = end;
        }
    }
}

fn checkCondition(cmd: []const u8) bool {
    // Use bash for [[ ]] support
    const result = std.process.Child.run(.{
        .allocator = std.heap.page_allocator,
        .argv = &.{ "/bin/bash", "-c", cmd },
    }) catch return false;
    defer std.heap.page_allocator.free(result.stdout);
    defer std.heap.page_allocator.free(result.stderr);
    return switch (result.term) {
        .Exited => |code| code == 0,
        else => false,
    };
}

