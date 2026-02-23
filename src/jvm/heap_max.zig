// Heap max detection from JVM command line flags.
// Reads the Java process command and parses -Xmx into bytes.

const std = @import("std");

pub fn readHeapMaxBytesFromPs(allocator: std.mem.Allocator, pid: u32) ?u64 {
    var pid_buf: [20]u8 = undefined;
    const pid_str = std.fmt.bufPrint(&pid_buf, "{d}", .{pid}) catch return null;
    const argv = [_][]const u8{ "ps", "-p", pid_str, "-o", "command=" };
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv[0..],
        .max_output_bytes = 128 * 1024,
    }) catch return null;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (!isExit0(result.term)) return null;
    return parseXmxFromCommandLine(result.stdout);
}

fn parseXmxFromCommandLine(raw: []const u8) ?u64 {
    const cmd = std.mem.trim(u8, raw, " \t\r\n");
    if (cmd.len == 0) return null;

    var it = std.mem.tokenizeAny(u8, cmd, " \t");
    while (it.next()) |tok| {
        if (tok.len < 5) continue;
        if (!std.mem.startsWith(u8, tok, "-Xmx")) continue;
        return parseJvmSizeBytes(tok[4..]);
    }
    return null;
}

fn parseJvmSizeBytes(value_raw: []const u8) ?u64 {
    const value = std.mem.trim(u8, value_raw, "\"'");
    if (value.len == 0) return null;

    var multiplier: u64 = 1;
    var digits = value;
    const last = value[value.len - 1];
    if (std.ascii.isAlphabetic(last)) {
        digits = value[0 .. value.len - 1];
        multiplier = switch (std.ascii.toLower(last)) {
            'k' => 1024,
            'm' => 1024 * 1024,
            'g' => 1024 * 1024 * 1024,
            't' => 1024 * 1024 * 1024 * 1024,
            else => return null,
        };
    }
    if (digits.len == 0) return null;

    const base = std.fmt.parseInt(u64, digits, 10) catch return null;
    return std.math.mul(u64, base, multiplier) catch null;
}

fn isExit0(term: std.process.Child.Term) bool {
    return switch (term) {
        .Exited => |code| code == 0,
        else => false,
    };
}
