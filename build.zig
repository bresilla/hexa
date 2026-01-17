const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Create core module
    const core_module = b.createModule(.{
        .root_source_file = b.path("src/core/mod.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // Build box executable
    const box_root = b.createModule(.{
        .root_source_file = b.path("src/box/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    box_root.addImport("core", core_module);
    const box_exe = b.addExecutable(.{
        .name = "box",
        .root_module = box_root,
    });
    b.installArtifact(box_exe);

    // Build mux executable
    const mux_root = b.createModule(.{
        .root_source_file = b.path("src/mux/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    mux_root.addImport("core", core_module);
    const mux_exe = b.addExecutable(.{
        .name = "mux",
        .root_module = mux_root,
    });
    b.installArtifact(mux_exe);

    // Run steps
    const run_box = b.addRunArtifact(box_exe);
    run_box.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_box.addArgs(args);
    }
    const run_box_step = b.step("run-box", "Run the box executable");
    run_box_step.dependOn(&run_box.step);

    const run_mux = b.addRunArtifact(mux_exe);
    run_mux.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_mux.addArgs(args);
    }
    const run_mux_step = b.step("run-mux", "Run the mux executable");
    run_mux_step.dependOn(&run_mux.step);
}
