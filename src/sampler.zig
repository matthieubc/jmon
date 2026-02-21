const std = @import("std");
const types = @import("types.zig");

const JstatGc = struct {
    heap_used_bytes: u64,
    heap_committed_bytes: u64,
    ygc: u64,
    fgc: u64,
    gct_s: f64,
};

const TargetProcess = struct {
    pid: u32,
    app_name_buf: [512]u8 = undefined,
    app_name_len: usize = 0,

    fn appName(self: *const TargetProcess) []const u8 {
        return self.app_name_buf[0..self.app_name_len];
    }
};

pub fn collectSnapshot(
    allocator: std.mem.Allocator,
    app_pattern: []const u8,
    sample: u64,
    runtime: *types.RuntimeState,
) types.Snapshot {
    var snapshot = types.Snapshot{
        .ts_unix_s = std.time.timestamp(),
        .sample = sample,
        .state = .SEARCHING,
        .app_pattern = app_pattern,
        .pid = null,
        .attached_app = null,
        .mem_used_bytes = 0,
        .mem_committed_bytes = 0,
        .mem_max_bytes = 0,
        .cpu_total_pct = 0,
        .gc_time_pct = 0,
        .io_disk_bps = 0,
        .io_net_bps = 0,
        .finding_count = 0,
    };

    const target = findTargetProcess(allocator, app_pattern) orelse {
        snapshot.state = if (runtime.was_attached) .LOST else .SEARCHING;
        runtime.was_attached = false;
        runtime.prev_gc = null;
        runtime.attached_app_len = 0;
        return snapshot;
    };

    snapshot.state = .ATTACHED;
    snapshot.pid = target.pid;
    snapshot.attached_app = setAttachedApp(runtime, target.appName());
    runtime.was_attached = true;

    if (readJstatGc(allocator, target.pid)) |gc| {
        snapshot.mem_used_bytes = gc.heap_used_bytes;
        snapshot.mem_committed_bytes = gc.heap_committed_bytes;

        const now_ms = std.time.milliTimestamp();
        if (runtime.prev_gc) |prev| {
            if (prev.pid == target.pid and now_ms > prev.ts_ms and gc.gct_s >= prev.gct_s) {
                const delta_ms = @as(f64, @floatFromInt(now_ms - prev.ts_ms));
                const delta_gc_ms = (gc.gct_s - prev.gct_s) * 1000.0;
                snapshot.gc_time_pct = toPct(delta_gc_ms * 100.0 / delta_ms);
            }
        }

        runtime.prev_gc = .{
            .pid = target.pid,
            .ts_ms = now_ms,
            .ygc = gc.ygc,
            .fgc = gc.fgc,
            .gct_s = gc.gct_s,
        };
    } else {
        runtime.prev_gc = null;
    }

    if (readCpuTotalPct(allocator, target.pid)) |cpu| {
        snapshot.cpu_total_pct = cpu;
    }

    snapshot.finding_count = computeFindingCount(snapshot);
    return snapshot;
}

fn findTargetProcess(allocator: std.mem.Allocator, app_pattern: []const u8) ?TargetProcess {
    const argv = [_][]const u8{ "jcmd", "-l" };
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv[0..],
        .max_output_bytes = 512 * 1024,
    }) catch return null;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (!isExit0(result.term)) return null;
    return parseTargetProcess(result.stdout, app_pattern);
}

fn parseTargetProcess(output: []const u8, app_pattern: []const u8) ?TargetProcess {
    var lines = std.mem.tokenizeScalar(u8, output, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r");
        if (line.len == 0) continue;
        if (app_pattern.len != 0 and std.ascii.indexOfIgnoreCase(line, app_pattern) == null) continue;

        var parts = std.mem.tokenizeAny(u8, line, " \t");
        const pid_str = parts.next() orelse continue;
        const pid = std.fmt.parseInt(u32, pid_str, 10) catch continue;
        var target = TargetProcess{ .pid = pid };
        const app_name = extractAppName(line);
        const n = @min(app_name.len, target.app_name_buf.len);
        if (n != 0) {
            std.mem.copyForwards(u8, target.app_name_buf[0..n], app_name[0..n]);
            target.app_name_len = n;
        }
        return target;
    }
    return null;
}

fn extractAppName(line: []const u8) []const u8 {
    const first_ws = std.mem.indexOfAny(u8, line, " \t") orelse return "";
    var i = first_ws;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
    if (i >= line.len) return "";
    return line[i..];
}

fn setAttachedApp(runtime: *types.RuntimeState, app_name: []const u8) ?[]const u8 {
    if (app_name.len == 0) {
        runtime.attached_app_len = 0;
        return null;
    }
    const n = @min(app_name.len, runtime.attached_app_buf.len);
    std.mem.copyForwards(u8, runtime.attached_app_buf[0..n], app_name[0..n]);
    runtime.attached_app_len = n;
    return runtime.attached_app_buf[0..runtime.attached_app_len];
}

fn readCpuTotalPct(allocator: std.mem.Allocator, pid: u32) ?u8 {
    var pid_buf: [20]u8 = undefined;
    const pid_str = std.fmt.bufPrint(&pid_buf, "{d}", .{pid}) catch return null;
    const argv = [_][]const u8{ "ps", "-p", pid_str, "-o", "%cpu=" };
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv[0..],
        .max_output_bytes = 32 * 1024,
    }) catch return null;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (!isExit0(result.term)) return null;

    const cpu_str = std.mem.trim(u8, result.stdout, " \t\r\n");
    if (cpu_str.len == 0) return null;
    const cpu = parseLocalizedFloat(cpu_str) orelse return null;
    return toPct(cpu);
}

fn readJstatGc(allocator: std.mem.Allocator, pid: u32) ?JstatGc {
    var pid_buf: [20]u8 = undefined;
    const pid_str = std.fmt.bufPrint(&pid_buf, "{d}", .{pid}) catch return null;
    const argv = [_][]const u8{ "jstat", "-gc", pid_str };
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv[0..],
        .max_output_bytes = 64 * 1024,
    }) catch return null;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (!isExit0(result.term)) return null;
    return parseJstatGc(result.stdout);
}

fn parseJstatGc(output: []const u8) ?JstatGc {
    var lines = std.mem.tokenizeScalar(u8, output, '\n');
    var header_line: ?[]const u8 = null;
    var values_line: ?[]const u8 = null;

    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r");
        if (line.len == 0) continue;
        if (header_line == null) {
            header_line = line;
            continue;
        }
        values_line = line;
        break;
    }

    const headers = header_line orelse return null;
    const values = values_line orelse return null;

    var header_tokens: [64][]const u8 = undefined;
    var value_tokens: [64][]const u8 = undefined;
    var hlen: usize = 0;
    var vlen: usize = 0;

    var h_it = std.mem.tokenizeAny(u8, headers, " \t");
    while (h_it.next()) |tok| {
        if (hlen >= header_tokens.len) return null;
        header_tokens[hlen] = tok;
        hlen += 1;
    }

    var v_it = std.mem.tokenizeAny(u8, values, " \t");
    while (v_it.next()) |tok| {
        if (vlen >= value_tokens.len) return null;
        value_tokens[vlen] = tok;
        vlen += 1;
    }

    const headers_slice = header_tokens[0..hlen];
    const values_slice = value_tokens[0..vlen];

    const i_s0c = findColumn(headers_slice, "S0C") orelse return null;
    const i_s1c = findColumn(headers_slice, "S1C") orelse return null;
    const i_ec = findColumn(headers_slice, "EC") orelse return null;
    const i_oc = findColumn(headers_slice, "OC") orelse return null;
    const i_s0u = findColumn(headers_slice, "S0U") orelse return null;
    const i_s1u = findColumn(headers_slice, "S1U") orelse return null;
    const i_eu = findColumn(headers_slice, "EU") orelse return null;
    const i_ou = findColumn(headers_slice, "OU") orelse return null;
    const i_ygc = findColumn(headers_slice, "YGC") orelse return null;
    const i_fgc = findColumn(headers_slice, "FGC") orelse return null;
    const i_gct = findColumn(headers_slice, "GCT") orelse return null;

    const s0c = parseFloatAt(values_slice, i_s0c) orelse return null;
    const s1c = parseFloatAt(values_slice, i_s1c) orelse return null;
    const ec = parseFloatAt(values_slice, i_ec) orelse return null;
    const oc = parseFloatAt(values_slice, i_oc) orelse return null;
    const s0u = parseFloatAt(values_slice, i_s0u) orelse return null;
    const s1u = parseFloatAt(values_slice, i_s1u) orelse return null;
    const eu = parseFloatAt(values_slice, i_eu) orelse return null;
    const ou = parseFloatAt(values_slice, i_ou) orelse return null;
    const ygc = parseFloatAt(values_slice, i_ygc) orelse return null;
    const fgc = parseFloatAt(values_slice, i_fgc) orelse return null;
    const gct = parseFloatAt(values_slice, i_gct) orelse return null;

    return .{
        .heap_used_bytes = kbToBytes(s0u + s1u + eu + ou),
        .heap_committed_bytes = kbToBytes(s0c + s1c + ec + oc),
        .ygc = toCount(ygc),
        .fgc = toCount(fgc),
        .gct_s = if (gct < 0) 0 else gct,
    };
}

fn isExit0(term: std.process.Child.Term) bool {
    return switch (term) {
        .Exited => |code| code == 0,
        else => false,
    };
}

fn findColumn(columns: []const []const u8, name: []const u8) ?usize {
    for (columns, 0..) |col, i| {
        if (std.mem.eql(u8, col, name)) return i;
    }
    return null;
}

fn parseFloatAt(tokens: []const []const u8, index: usize) ?f64 {
    if (index >= tokens.len) return null;
    return parseLocalizedFloat(tokens[index]);
}

fn parseLocalizedFloat(raw: []const u8) ?f64 {
    const s = std.mem.trim(u8, raw, " \t\r\n");
    if (s.len == 0) return null;
    if (std.fmt.parseFloat(f64, s)) |v| return v else |_| {}
    if (std.mem.indexOfScalar(u8, s, ',') == null) return null;

    var buf: [64]u8 = undefined;
    if (s.len > buf.len) return null;
    std.mem.copyForwards(u8, buf[0..s.len], s);
    for (buf[0..s.len]) |*c| {
        if (c.* == ',') c.* = '.';
    }
    return std.fmt.parseFloat(f64, buf[0..s.len]) catch null;
}

fn kbToBytes(kb: f64) u64 {
    if (kb <= 0) return 0;
    const bytes = kb * 1024.0;
    const max_u64_f = @as(f64, @floatFromInt(std.math.maxInt(u64)));
    if (bytes >= max_u64_f) return std.math.maxInt(u64);
    return @as(u64, @intFromFloat(bytes));
}

fn toCount(value: f64) u64 {
    if (value <= 0) return 0;
    return @as(u64, @intFromFloat(@floor(value)));
}

fn toPct(value: f64) u8 {
    const bounded = std.math.clamp(value, 0.0, 100.0);
    return @as(u8, @intFromFloat(@round(bounded)));
}

fn computeFindingCount(snapshot: types.Snapshot) u32 {
    var findings: u32 = 0;
    if (snapshot.cpu_total_pct >= 80) findings += 1;
    if (snapshot.gc_time_pct >= 15) findings += 1;
    if (snapshot.mem_committed_bytes > 0) {
        const mem_pct = (@as(u128, snapshot.mem_used_bytes) * 100) / @as(u128, snapshot.mem_committed_bytes);
        if (mem_pct >= 90) findings += 1;
    }
    return findings;
}
