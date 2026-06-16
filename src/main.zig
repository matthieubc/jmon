// Process entrypoint for jmon.
// Creates the allocator, parses CLI options, and hands execution to the app runtime.

const app = @import("app.zig");
const cli = @import("cli.zig");
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(io, &stdout_buffer);
    defer stdout_writer.flush() catch {};

    const parsed = try cli.parseOptions(allocator, io, init.minimal.args);
    if (parsed == null) return;
    const options = parsed.?;
    defer options.deinit(allocator);

    try app.run(allocator, io, &stdout_writer.interface, options.options);
    try stdout_writer.flush();
}
