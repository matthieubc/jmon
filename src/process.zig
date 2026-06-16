// Child-process helpers for jmon probes.
// Wraps Zig 0.16 process execution so JVM command probes share output limits and cleanup shape.

const std = @import("std");

pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    argv: []const []const u8,
    max_output_bytes: usize,
) !std.process.RunResult {
    return std.process.run(allocator, io, .{
        .argv = argv,
        .stdout_limit = .limited(max_output_bytes),
        .stderr_limit = .limited(max_output_bytes),
    });
}

pub fn isExit0(term: std.process.Child.Term) bool {
    return switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
}
