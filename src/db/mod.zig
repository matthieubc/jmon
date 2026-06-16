// DB agent metrics reader.
// Loads per-PID DB metrics exported by the Java agent from a local temp file.

const std = @import("std");
const file = @import("../file.zig");

pub const DbMetrics = struct {
    sql_per_s: u32 = 0,
    errors_per_s: u32 = 0,
    in_flight: u32 = 0,
    latency_avg_ms_x10: u32 = 0,
    latency_p95_ms_x10: u32 = 0,
    latency_max_ms_x10: u32 = 0,
    datasource_count: u16 = 0,
};

pub fn readMetrics(allocator: std.mem.Allocator, io: std.Io, pid: u32) ?DbMetrics {
    var path_buf: [128]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/tmp/jmon-db-agent-{d}.metrics", .{pid}) catch return null;

    const contents = file.readAbsoluteAlloc(allocator, io, path, 128 * 1024) catch return null;
    defer allocator.free(contents);

    return parseMetrics(contents, pid);
}

fn parseMetrics(contents: []const u8, expected_pid: u32) ?DbMetrics {
    var out = DbMetrics{};
    var seen_pid = false;
    var pid_match = false;

    var lines = std.mem.tokenizeScalar(u8, contents, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r");
        if (line.len == 0) continue;

        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = line[0..eq];
        const value = std.mem.trim(u8, line[eq + 1 ..], " \t");

        if (std.mem.eql(u8, key, "pid")) {
            const pid = parseU32(value) orelse return null;
            seen_pid = true;
            pid_match = pid == expected_pid;
            continue;
        }
        if (std.mem.eql(u8, key, "sql_per_sec")) {
            out.sql_per_s = parseU32(value) orelse return null;
            continue;
        }
        if (std.mem.eql(u8, key, "errors_per_sec")) {
            out.errors_per_s = parseU32(value) orelse return null;
            continue;
        }
        if (std.mem.eql(u8, key, "in_flight")) {
            out.in_flight = parseU32(value) orelse return null;
            continue;
        }
        if (std.mem.eql(u8, key, "lat_avg_ms_x10")) {
            out.latency_avg_ms_x10 = parseU32(value) orelse return null;
            continue;
        }
        if (std.mem.eql(u8, key, "lat_p95_ms_x10")) {
            out.latency_p95_ms_x10 = parseU32(value) orelse return null;
            continue;
        }
        if (std.mem.eql(u8, key, "lat_max_ms_x10")) {
            out.latency_max_ms_x10 = parseU32(value) orelse return null;
            continue;
        }
        if (std.mem.eql(u8, key, "datasource_count")) {
            out.datasource_count = parseU16(value) orelse return null;
            continue;
        }
    }

    if (seen_pid and !pid_match) return null;
    return out;
}

fn parseU32(raw: []const u8) ?u32 {
    const value = std.fmt.parseInt(u64, raw, 10) catch return null;
    return @as(u32, @intCast(@min(value, std.math.maxInt(u32))));
}

fn parseU16(raw: []const u8) ?u16 {
    const value = std.fmt.parseInt(u64, raw, 10) catch return null;
    return @as(u16, @intCast(@min(value, std.math.maxInt(u16))));
}
