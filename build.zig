const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Get ghostty-vt module from dependency
    const ghostty_vt_mod = if (b.lazyDependency("ghostty", .{
        .target = target,
        .optimize = optimize,
    })) |ghostty_dep| ghostty_dep.module("ghostty-vt") else null;

    // Get argonaut module from dependency
    const argonaut_mod = if (b.lazyDependency("argonaut", .{
        .target = target,
        .optimize = optimize,
    })) |argonaut_dep| argonaut_dep.module("argonaut") else null;

    // Create core module
    const core_module = b.createModule(.{
        .root_source_file = b.path("src/core/mod.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    if (ghostty_vt_mod) |vt| {
        core_module.addImport("ghostty-vt", vt);
    }

    // Create pop module (prompt/status bar segments)
    const pop_module = b.createModule(.{
        .root_source_file = b.path("src/pop/mod.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Create mux module for unified CLI
    const mux_module = b.createModule(.{
        .root_source_file = b.path("src/mux/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    mux_module.addImport("core", core_module);
    mux_module.addImport("pop", pop_module);
    if (ghostty_vt_mod) |vt| {
        mux_module.addImport("ghostty-vt", vt);
    }

    // Create ses module for unified CLI
    const ses_module = b.createModule(.{
        .root_source_file = b.path("src/ses/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    ses_module.addImport("core", core_module);

    // Build unified hexa CLI executable
    const cli_root = b.createModule(.{
        .root_source_file = b.path("src/cli/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    cli_root.addImport("core", core_module);
    cli_root.addImport("mux", mux_module);
    cli_root.addImport("ses", ses_module);
    cli_root.addImport("pop", pop_module);
    if (argonaut_mod) |arg| {
        cli_root.addImport("argonaut", arg);
    }
    const cli_exe = b.addExecutable(.{
        .name = "hexa",
        .root_module = cli_root,
    });
    b.installArtifact(cli_exe);

    // Run hexa step
    const run_hexa = b.addRunArtifact(cli_exe);
    run_hexa.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_hexa.addArgs(args);
    }
    const run_step = b.step("run", "Run hexa");
    run_step.dependOn(&run_hexa.step);
}
