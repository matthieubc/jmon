// Linux process memory probes.
// Reads process RSS from /proc for the physical memory approximation used by jmon.

const std = @import("std");
const types = @import("../types.zig");

pub fn readPhysicalFootprintBytes(allocator: std.mem.Allocator, pid: u32) ?u64 {
    var path_buf: [64]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/proc/{d}/status", .{pid}) catch return null;

    const file = std.fs.openFileAbsolute(path, .{}) catch return null;
    defer file.close();

    const contents = file.readToEndAlloc(allocator, 128 * 1024) catch return null;
    defer allocator.free(contents);

    return parseVmRssBytes(contents);
}

pub fn readHostCpuCoreTicks(allocator: std.mem.Allocator) ?types.HostCpuCoreTicksSample {
    const file = std.fs.openFileAbsolute("/proc/stat", .{}) catch return null;
    defer file.close();

    const contents = file.readToEndAlloc(allocator, 256 * 1024) catch return null;
    defer allocator.free(contents);

    return parseCpuCoreTicks(contents);
}

pub fn readProcessDiskIoCounters(allocator: std.mem.Allocator, pid: u32) ?types.ProcessDiskIoCounters {
    var path_buf: [64]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/proc/{d}/io", .{pid}) catch return null;

    const file = std.fs.openFileAbsolute(path, .{}) catch return null;
    defer file.close();

    const contents = file.readToEndAlloc(allocator, 64 * 1024) catch return null;
    defer allocator.free(contents);

    return parseProcessDiskIoCounters(contents);
}

fn parseVmRssBytes(status: []const u8) ?u64 {
    var lines = std.mem.tokenizeScalar(u8, status, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r");
        if (!std.mem.startsWith(u8, line, "VmRSS:")) continue;

        var it = std.mem.tokenizeAny(u8, line["VmRSS:".len..], " \t");
        const value_tok = it.next() orelse return null;
        const value_kb = std.fmt.parseInt(u64, value_tok, 10) catch return null;
        return std.math.mul(u64, value_kb, 1024) catch null;
    }
    return null;
}

fn parseCpuCoreTicks(stat: []const u8) ?types.HostCpuCoreTicksSample {
    var sample = types.HostCpuCoreTicksSample{};
    var lines = std.mem.tokenizeScalar(u8, stat, '\n');

    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r");
        if (!std.mem.startsWith(u8, line, "cpu")) continue;
        if (line.len < 4) continue;
        if (line[3] == ' ') continue; // aggregate `cpu` line
        if (sample.len >= types.max_cpu_cores) break;

        var fields = std.mem.tokenizeAny(u8, line, " \t");
        _ = fields.next() orelse continue; // cpuN label

        var idx: usize = 0;
        var total: u64 = 0;
        var idle_total: u64 = 0;
        while (fields.next()) |tok| : (idx += 1) {
            const value = std.fmt.parseInt(u64, tok, 10) catch break;
            total += value;
            if (idx == 3 or idx == 4) idle_total += value; // idle + iowait
        }
        if (total == 0) continue;

        sample.total_ticks[sample.len] = total;
        sample.idle_ticks[sample.len] = idle_total;
        sample.len += 1;
    }

    if (sample.len == 0) return null;
    return sample;
}

fn parseProcessDiskIoCounters(contents: []const u8) ?types.ProcessDiskIoCounters {
    var out = types.ProcessDiskIoCounters{};
    var have_read = false;
    var have_write = false;

    var lines = std.mem.tokenizeScalar(u8, contents, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r");
        if (std.mem.startsWith(u8, line, "read_bytes:")) {
            out.read_bytes = parseIoCounterLine(line["read_bytes:".len..]) orelse return null;
            have_read = true;
        } else if (std.mem.startsWith(u8, line, "write_bytes:")) {
            out.write_bytes = parseIoCounterLine(line["write_bytes:".len..]) orelse return null;
            have_write = true;
        }
    }

    if (!have_read or !have_write) return null;
    return out;
}

fn parseIoCounterLine(value_part: []const u8) ?u64 {
    const trimmed = std.mem.trim(u8, value_part, " \t");
    if (trimmed.len == 0) return null;
    return std.fmt.parseInt(u64, trimmed, 10) catch null;
}
