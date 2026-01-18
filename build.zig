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

    // Create pop module (prompt/status bar segments)
    const pop_module = b.createModule(.{
        .root_source_file = b.path("src/pop/mod.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Build pop executable (standalone prompt)
    const pop_exe = b.addExecutable(.{
        .name = "pop",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/pop/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(pop_exe);

    // Run pop step
    const run_pop = b.addRunArtifact(pop_exe);
    run_pop.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_pop.addArgs(args);
    }
    const run_pop_step = b.step("pop", "Run pop prompt");
    run_pop_step.dependOn(&run_pop.step);

    // Build hexa-mux executable
    const mux_root = b.createModule(.{
        .root_source_file = b.path("src/mux/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    mux_root.addImport("core", core_module);
    mux_root.addImport("pop", pop_module);
    if (ghostty_vt_mod) |vt| {
        mux_root.addImport("ghostty-vt", vt);
    }
    const mux_exe = b.addExecutable(.{
        .name = "hexa-mux",
        .root_module = mux_root,
    });
    b.installArtifact(mux_exe);

    // Run step
    const run_mux = b.addRunArtifact(mux_exe);
    run_mux.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_mux.addArgs(args);
    }
    const run_step = b.step("run", "Run hexa-mux");
    run_step.dependOn(&run_mux.step);
}
