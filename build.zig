const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Get ghostty-vt module from dependency
    const ghostty_vt_mod = if (b.lazyDependency("ghostty", .{
        .target = target,
        .optimize = optimize,
    })) |ghostty_dep| ghostty_dep.module("ghostty-vt") else null;

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

    // Build hexa-mux executable
    const mux_root = b.createModule(.{
        .root_source_file = b.path("src/mux/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    mux_root.addImport("core", core_module);
    if (ghostty_vt_mod) |vt| {
        mux_root.addImport("ghostty-vt", vt);
    }
    const mux_exe = b.addExecutable(.{
        .name = "hexa-mux",
        .root_module = mux_root,
    });
    b.installArtifact(mux_exe);

    // Build smux executable (single-pane, full redraw)
    const smux_root = b.createModule(.{
        .root_source_file = b.path("src/smux/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    smux_root.addImport("core", core_module);
    if (ghostty_vt_mod) |vt| {
        smux_root.addImport("ghostty-vt", vt);
    }
    const smux_exe = b.addExecutable(.{
        .name = "smux",
        .root_module = smux_root,
    });
    b.installArtifact(smux_exe);

    // Run step
    const run_mux = b.addRunArtifact(mux_exe);
    run_mux.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_mux.addArgs(args);
    }
    const run_step = b.step("run", "Run hexa-mux");
    run_step.dependOn(&run_mux.step);

    const run_smux = b.addRunArtifact(smux_exe);
    run_smux.step.dependOn(b.getInstallStep());
    const smux_step = b.step("smux", "Run smux");
    smux_step.dependOn(&run_smux.step);
}
