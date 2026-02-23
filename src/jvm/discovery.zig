// JVM process discovery helpers.
// Runs jcmd discovery and selects the target PID/app name using the configured pattern.

const std = @import("std");

pub const TargetProcess = struct {
    pid: u32,
    app_name_buf: [512]u8 = undefined,
    app_name_len: usize = 0,

    pub fn appName(self: *const TargetProcess) []const u8 {
        return self.app_name_buf[0..self.app_name_len];
    }
};

pub fn findTargetProcess(
    allocator: std.mem.Allocator,
    app_pattern: []const u8,
    pinned_pid: ?u32,
) ?TargetProcess {
    const argv = [_][]const u8{ "jcmd", "-l" };
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv[0..],
        .max_output_bytes = 512 * 1024,
    }) catch return null;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (!isExit0(result.term)) return null;
    if (pinned_pid) |pid| {
        return parseTargetProcessByPid(result.stdout, pid);
    }
    return parseTargetProcessByPattern(result.stdout, app_pattern);
}

fn parseTargetProcessByPattern(output: []const u8, app_pattern: []const u8) ?TargetProcess {
    var lines = std.mem.tokenizeScalar(u8, output, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r");
        if (line.len == 0) continue;
        if (app_pattern.len != 0 and std.ascii.indexOfIgnoreCase(line, app_pattern) == null) continue;
        return parseTargetProcessLine(line);
    }
    return null;
}

fn parseTargetProcessByPid(output: []const u8, pinned_pid: u32) ?TargetProcess {
    var lines = std.mem.tokenizeScalar(u8, output, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r");
        if (line.len == 0) continue;
        const candidate = parseTargetProcessLine(line) orelse continue;
        if (candidate.pid == pinned_pid) return candidate;
    }
    return null;
}

fn parseTargetProcessLine(line: []const u8) ?TargetProcess {
    var parts = std.mem.tokenizeAny(u8, line, " \t");
    const pid_str = parts.next() orelse return null;
    const pid = std.fmt.parseInt(u32, pid_str, 10) catch return null;
    var target = TargetProcess{ .pid = pid };
    const app_name = extractAppName(line);
    const n = @min(app_name.len, target.app_name_buf.len);
    if (n != 0) {
        std.mem.copyForwards(u8, target.app_name_buf[0..n], app_name[0..n]);
        target.app_name_len = n;
    }
    return target;
}

fn extractAppName(line: []const u8) []const u8 {
    const first_ws = std.mem.indexOfAny(u8, line, " \t") orelse return "";
    var i = first_ws;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
    if (i >= line.len) return "";
    return line[i..];
}

fn isExit0(term: std.process.Child.Term) bool {
    return switch (term) {
        .Exited => |code| code == 0,
        else => false,
    };
}
