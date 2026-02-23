// Imperative JVM commands used by the TUI.
// Executes jcmd actions such as requesting a full GC on the attached process.

const std = @import("std");

pub fn runFullGc(allocator: std.mem.Allocator, pid: u32) bool {
    var pid_buf: [20]u8 = undefined;
    const pid_str = std.fmt.bufPrint(&pid_buf, "{d}", .{pid}) catch return false;
    const argv = [_][]const u8{ "jcmd", pid_str, "GC.run" };
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv[0..],
        .max_output_bytes = 32 * 1024,
    }) catch return false;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    return switch (result.term) {
        .Exited => |code| code == 0,
        else => false,
    };
}
