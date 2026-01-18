const std = @import("std");
const segment = @import("segment.zig");
const segments_mod = @import("segments/mod.zig");
const Style = @import("style.zig").Style;

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
            \\    PROMPT="$(pop prompt --status=$exit_status --duration=$duration --jobs=${(M)#jobstates}) "
            \\    RPROMPT="$(pop prompt --right --status=$exit_status)"
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
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--right")) {
            is_right = true;
        } else if (std.mem.startsWith(u8, arg, "--status=")) {
            ctx.exit_status = std.fmt.parseInt(i32, arg[9..], 10) catch null;
        } else if (std.mem.startsWith(u8, arg, "--duration=")) {
            ctx.cmd_duration_ms = std.fmt.parseInt(u64, arg[11..], 10) catch null;
        } else if (std.mem.startsWith(u8, arg, "--jobs=")) {
            ctx.jobs = std.fmt.parseInt(u16, arg[7..], 10) catch 0;
        }
    }

    // Get environment info
    ctx.cwd = std.posix.getenv("PWD") orelse "";
    ctx.home = std.posix.getenv("HOME");

    const stdout = std.fs.File.stdout();

    if (is_right) {
        // Right prompt: time
        try renderSegments(&ctx, &.{"time"}, stdout);
    } else {
        // Left prompt: directory, git, character
        try renderSegments(&ctx, &.{ "directory", "git_branch", "git_status", "character" }, stdout);
    }
}

fn renderSegments(ctx: *segment.Context, segment_names: []const []const u8, stdout: std.fs.File) !void {
    var output_buf: [4096]u8 = undefined;
    var output_len: usize = 0;

    var first = true;

    for (segment_names) |name| {
        if (ctx.renderSegment(name)) |segs| {
            for (segs) |seg| {
                if (!first and output_len < output_buf.len) {
                    output_buf[output_len] = ' ';
                    output_len += 1;
                }
                first = false;

                // Add ANSI color codes
                var ansi_buf: [64]u8 = undefined;
                var ansi_len: usize = 0;

                // Build ANSI sequence
                if (seg.style.bold or seg.style.dim or seg.style.italic or seg.style.underline or
                    seg.style.fg != .none or seg.style.bg != .none)
                {
                    ansi_buf[ansi_len] = '\x1b';
                    ansi_buf[ansi_len + 1] = '[';
                    ansi_len += 2;

                    var need_semi = false;

                    if (seg.style.bold) {
                        ansi_buf[ansi_len] = '1';
                        ansi_len += 1;
                        need_semi = true;
                    }
                    if (seg.style.dim) {
                        if (need_semi) {
                            ansi_buf[ansi_len] = ';';
                            ansi_len += 1;
                        }
                        ansi_buf[ansi_len] = '2';
                        ansi_len += 1;
                        need_semi = true;
                    }
                    if (seg.style.italic) {
                        if (need_semi) {
                            ansi_buf[ansi_len] = ';';
                            ansi_len += 1;
                        }
                        ansi_buf[ansi_len] = '3';
                        ansi_len += 1;
                        need_semi = true;
                    }
                    if (seg.style.underline) {
                        if (need_semi) {
                            ansi_buf[ansi_len] = ';';
                            ansi_len += 1;
                        }
                        ansi_buf[ansi_len] = '4';
                        ansi_len += 1;
                        need_semi = true;
                    }

                    // Foreground color
                    switch (seg.style.fg) {
                        .none => {},
                        .palette => |p| {
                            if (need_semi) {
                                ansi_buf[ansi_len] = ';';
                                ansi_len += 1;
                            }
                            const code = if (p < 8)
                                std.fmt.bufPrint(ansi_buf[ansi_len..], "{d}", .{30 + p}) catch ""
                            else if (p < 16)
                                std.fmt.bufPrint(ansi_buf[ansi_len..], "{d}", .{90 + p - 8}) catch ""
                            else
                                std.fmt.bufPrint(ansi_buf[ansi_len..], "38;5;{d}", .{p}) catch "";
                            ansi_len += code.len;
                            need_semi = true;
                        },
                        .rgb => |rgb| {
                            if (need_semi) {
                                ansi_buf[ansi_len] = ';';
                                ansi_len += 1;
                            }
                            const code = std.fmt.bufPrint(ansi_buf[ansi_len..], "38;2;{d};{d};{d}", .{ rgb.r, rgb.g, rgb.b }) catch "";
                            ansi_len += code.len;
                            need_semi = true;
                        },
                    }

                    // Background color
                    switch (seg.style.bg) {
                        .none => {},
                        .palette => |p| {
                            if (need_semi) {
                                ansi_buf[ansi_len] = ';';
                                ansi_len += 1;
                            }
                            const code = if (p < 8)
                                std.fmt.bufPrint(ansi_buf[ansi_len..], "{d}", .{40 + p}) catch ""
                            else if (p < 16)
                                std.fmt.bufPrint(ansi_buf[ansi_len..], "{d}", .{100 + p - 8}) catch ""
                            else
                                std.fmt.bufPrint(ansi_buf[ansi_len..], "48;5;{d}", .{p}) catch "";
                            ansi_len += code.len;
                        },
                        .rgb => |rgb| {
                            if (need_semi) {
                                ansi_buf[ansi_len] = ';';
                                ansi_len += 1;
                            }
                            const code = std.fmt.bufPrint(ansi_buf[ansi_len..], "48;2;{d};{d};{d}", .{ rgb.r, rgb.g, rgb.b }) catch "";
                            ansi_len += code.len;
                        },
                    }

                    ansi_buf[ansi_len] = 'm';
                    ansi_len += 1;

                    // Copy ANSI to output
                    const to_copy = @min(ansi_len, output_buf.len - output_len);
                    @memcpy(output_buf[output_len..][0..to_copy], ansi_buf[0..to_copy]);
                    output_len += to_copy;
                }

                // Copy text
                const text_to_copy = @min(seg.text.len, output_buf.len - output_len);
                @memcpy(output_buf[output_len..][0..text_to_copy], seg.text[0..text_to_copy]);
                output_len += text_to_copy;

                // Reset
                if (ansi_len > 0 and output_len + 4 <= output_buf.len) {
                    output_buf[output_len] = '\x1b';
                    output_buf[output_len + 1] = '[';
                    output_buf[output_len + 2] = '0';
                    output_buf[output_len + 3] = 'm';
                    output_len += 4;
                }
            }
        }
    }

    if (output_len > 0) {
        try stdout.writeAll(output_buf[0..output_len]);
    }
}
