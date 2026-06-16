// File helpers for jmon probes.
// Provides compact absolute-path reads through Zig 0.16 I/O readers.

const std = @import("std");

pub fn readAbsoluteAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    max_bytes: usize,
) ![]u8 {
    var file = try std.Io.Dir.openFileAbsolute(io, path, .{});
    defer file.close(io);

    var buffer: [4096]u8 = undefined;
    var reader = file.readerStreaming(io, &buffer);
    return reader.interface.allocRemaining(allocator, .limited(max_bytes));
}
