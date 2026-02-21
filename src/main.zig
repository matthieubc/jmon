const app = @import("app.zig");
const cli = @import("cli.zig");
const std = @import("std");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const stdout = std.fs.File.stdout().deprecatedWriter();

    const parsed = try cli.parseOptions(allocator);
    if (parsed == null) return;
    const options = parsed.?;
    defer options.deinit(allocator);

    try app.run(allocator, stdout, options.options);
}
