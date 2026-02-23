// Build script for the jmon executable.
// Defines the target, dependencies, and platform links used by Zig build commands.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const clap = b.dependency("clap", .{});

    const exe = b.addExecutable(.{
        .name = "jmon",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addImport("clap", clap.module("clap"));
    if (target.result.os.tag == .macos) {
        exe.linkSystemLibrary("proc");
    }

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run jmon");
    run_step.dependOn(&run_cmd.step);
}
