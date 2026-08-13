const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe });

    // --- Blocklist validator CLI ---
    const exe = b.addExecutable(.{
        .name = "qwave-blocklist",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Validate the blocklist JSON");
    run_step.dependOn(&run_cmd.step);

    // --- Packet filter static library ---
    const lib = b.addLibrary(.{
        .name = "qpacket",
        .linkage = .static,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/packet.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    // The XcodeGen preBuildScript uses `zig build-lib` directly (same pattern
    // as the WireGuard Go bridge), so we install the artifact here for
    // `zig build lib` to copy to zig-out/.
    b.installArtifact(lib);

    const lib_step = b.step("lib", "Build the qpacket static library");
    lib_step.dependOn(b.getInstallStep());

    // --- Tests ---
    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    const lib_tests = b.addTest(.{ .root_module = lib.root_module });
    const run_exe_tests = b.addRunArtifact(exe_tests);
    const run_lib_tests = b.addRunArtifact(lib_tests);
    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_exe_tests.step);
    test_step.dependOn(&run_lib_tests.step);
}