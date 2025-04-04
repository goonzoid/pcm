const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const pcm_mod = b.addModule("pcm", .{
        .root_source_file = b.path("pcm.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lib_unit_tests = b.addTest(.{
        .root_source_file = b.path("pcm.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);

    const example_mod = b.createModule(.{
        .root_source_file = b.path("example/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    example_mod.addImport("pcm", pcm_mod);
    const example_exe = b.addExecutable(.{
        .name = "pcm_example",
        .root_module = example_mod,
    });
    b.installArtifact(example_exe);

    const run_cmd = b.addRunArtifact(example_exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the example");
    run_step.dependOn(&run_cmd.step);
}
