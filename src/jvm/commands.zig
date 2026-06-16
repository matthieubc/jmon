// Imperative JVM commands used by the TUI and sampler.
// Executes jcmd actions and Java attach helpers against the attached process.

const std = @import("std");
const process = @import("../process.zig");

pub fn runFullGc(allocator: std.mem.Allocator, io: std.Io, pid: u32) bool {
    var pid_buf: [20]u8 = undefined;
    const pid_str = std.fmt.bufPrint(&pid_buf, "{d}", .{pid}) catch return false;
    const argv = [_][]const u8{ "jcmd", pid_str, "GC.run" };
    const result = process.run(allocator, io, argv[0..], 32 * 1024) catch return false;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    return process.isExit0(result.term);
}

pub fn attachDbAgent(allocator: std.mem.Allocator, io: std.Io, pid: u32, agent_jar: []const u8) bool {
    if (agent_jar.len == 0) return false;

    const agent_jar_path = allocator.dupe(u8, agent_jar) catch return false;
    defer allocator.free(agent_jar_path);

    var pid_buf: [20]u8 = undefined;
    const pid_str = std.fmt.bufPrint(&pid_buf, "{d}", .{pid}) catch return false;
    const argv = [_][]const u8{
        "java",
        "--add-modules",
        "jdk.attach",
        "-cp",
        agent_jar_path,
        "io.jmon.dbagent.AttachMain",
        pid_str,
        agent_jar_path,
    };
    const result = process.run(allocator, io, argv[0..], 128 * 1024) catch return false;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    return process.isExit0(result.term);
}
