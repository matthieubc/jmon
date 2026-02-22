const builtin = @import("builtin");
const std = @import("std");
const types = @import("types.zig");
const darwin_c = if (builtin.os.tag == .macos) @cImport({
    @cInclude("libproc.h");
    @cInclude("sys/resource.h");
}) else struct {};

// Stable GC window used for anomaly scoring and machine-readable summary fields.
const gc_window_ms: i64 = 60 * 1000;
// Short GC window used for the live TUI "GC pressure" indicator.
const gc_ui_pressure_window_ms: i64 = 2 * 1000;
const full_gc_signal_hold_ms: i64 = 15 * 1000;
const gc_pressure_ewma_alpha: f64 = 0.25;

const JstatGc = struct {
    heap_used_bytes: u64,
    heap_committed_bytes: u64,
    old_used_bytes: u64,
    old_committed_bytes: u64,
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
        .mem_physical_footprint_bytes = 0,
        .cpu_total_pct = 0,
        .gc_time_pct = 0,
        .gc_time_pct_x10 = 0,
        .gc_short_time_pct_x10 = 0,
        .gc_pressure_pct = 0,
        .gc_level = 0,
        .gc_old_occ_pct = 0,
        .gc_rate_per_s_x10 = 0,
        .gc_short_rate_per_s_x10 = 0,
        .gc_full_seen = false,
        .gc_fgc_count = 0,
        .io_disk_bps = 0,
        .io_net_bps = 0,
        .finding_count = 0,
    };

    const target = findTargetProcess(allocator, app_pattern, runtime.attached_pid) orelse {
        snapshot.state = if (runtime.was_attached) .LOST else .SEARCHING;
        runtime.was_attached = false;
        runtime.attached_pid = null;
        runtime.gc_points_len = 0;
        runtime.gc_time_red_windows = 0;
        runtime.last_full_gc_seen_ts_ms = -1;
        runtime.gc_pressure_ewma = 0;
        runtime.gc_fgc_baseline = null;
        runtime.heap_max_pid = null;
        runtime.heap_max_bytes = 0;
        runtime.attached_app_len = 0;
        return snapshot;
    };

    snapshot.state = .ATTACHED;
    snapshot.pid = target.pid;
    runtime.attached_pid = target.pid;
    snapshot.attached_app = setAttachedApp(runtime, target.appName());
    snapshot.mem_max_bytes = readHeapMaxBytesCached(allocator, runtime, target.pid) orelse 0;
    runtime.was_attached = true;

    if (readProcessPhysicalFootprintBytes(allocator, target.pid)) |footprint| {
        snapshot.mem_physical_footprint_bytes = footprint;
    }

    if (readJstatGc(allocator, target.pid)) |gc| {
        snapshot.mem_used_bytes = gc.heap_used_bytes;
        snapshot.mem_committed_bytes = gc.heap_committed_bytes;
        applyGcWindowMetrics(&snapshot, runtime, target.pid, gc);
    } else {
        runtime.gc_points_len = 0;
        runtime.gc_time_red_windows = 0;
        runtime.last_full_gc_seen_ts_ms = -1;
        runtime.gc_pressure_ewma = 0;
        runtime.gc_fgc_baseline = null;
    }

    if (readCpuTotalPct(allocator, target.pid)) |cpu| {
        snapshot.cpu_total_pct = cpu;
    }

    snapshot.finding_count = computeFindingCount(snapshot);
    return snapshot;
}

fn findTargetProcess(
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

fn readHeapMaxBytesCached(
    allocator: std.mem.Allocator,
    runtime: *types.RuntimeState,
    pid: u32,
) ?u64 {
    if (runtime.heap_max_pid) |cached_pid| {
        if (cached_pid == pid and runtime.heap_max_bytes > 0) return runtime.heap_max_bytes;
    }

    runtime.heap_max_pid = pid;
    runtime.heap_max_bytes = 0;

    const max_bytes = readHeapMaxBytesFromPs(allocator, pid) orelse return null;
    runtime.heap_max_bytes = max_bytes;
    return max_bytes;
}

fn readHeapMaxBytesFromPs(allocator: std.mem.Allocator, pid: u32) ?u64 {
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

fn readProcessPhysicalFootprintBytes(allocator: std.mem.Allocator, pid: u32) ?u64 {
    return switch (builtin.os.tag) {
        .macos => readProcessPhysicalFootprintBytesMacos(pid),
        .linux => readProcessPhysicalFootprintBytesLinux(allocator, pid),
        else => null,
    };
}

fn readProcessPhysicalFootprintBytesMacos(pid: u32) ?u64 {
    if (builtin.os.tag != .macos) return null;

    var info = std.mem.zeroes(darwin_c.struct_rusage_info_v4);
    const rc = darwin_c.proc_pid_rusage(
        @as(c_int, @intCast(pid)),
        darwin_c.RUSAGE_INFO_V4,
        @ptrCast(&info),
    );
    if (rc != 0) return null;
    return @as(u64, @intCast(info.ri_phys_footprint));
}

fn readProcessPhysicalFootprintBytesLinux(allocator: std.mem.Allocator, pid: u32) ?u64 {
    var path_buf: [64]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/proc/{d}/status", .{pid}) catch return null;

    const file = std.fs.openFileAbsolute(path, .{}) catch return null;
    defer file.close();

    const contents = file.readToEndAlloc(allocator, 128 * 1024) catch return null;
    defer allocator.free(contents);

    return parseVmRssBytes(contents);
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
        .old_used_bytes = kbToBytes(ou),
        .old_committed_bytes = kbToBytes(oc),
        .ygc = toCount(ygc),
        .fgc = toCount(fgc),
        .gct_s = if (gct < 0) 0 else gct,
    };
}

fn applyGcWindowMetrics(
    snapshot: *types.Snapshot,
    runtime: *types.RuntimeState,
    pid: u32,
    gc: JstatGc,
) void {
    const now_ms = std.time.milliTimestamp();
    const point = types.GcPoint{
        .pid = pid,
        .ts_ms = now_ms,
        .ygc = gc.ygc,
        .fgc = gc.fgc,
        .gct_s = gc.gct_s,
        .old_used_bytes = gc.old_used_bytes,
        .old_committed_bytes = gc.old_committed_bytes,
    };

    appendGcPoint(runtime, point);
    trimGcWindow(runtime, pid, now_ms);

    snapshot.gc_old_occ_pct = if (gc.old_committed_bytes > 0)
        usagePctU64(gc.old_used_bytes, gc.old_committed_bytes)
    else
        usagePctU64(snapshot.mem_used_bytes, snapshot.mem_committed_bytes);

    // 60s rolling metrics remain the source for anomaly/finding logic and exported summary fields.
    var gc_time_ratio_pct: f64 = 0;
    var gc_rate_per_s: f64 = 0;
    if (runtime.gc_points_len >= 2) {
        const first = runtime.gc_points[0];
        const last = runtime.gc_points[runtime.gc_points_len - 1];
        if (first.pid == pid and last.pid == pid and last.ts_ms > first.ts_ms and last.gct_s >= first.gct_s) {
            const delta_ms_i = last.ts_ms - first.ts_ms;
            const delta_ms = @as(f64, @floatFromInt(delta_ms_i));
            const delta_gc_ms = (last.gct_s - first.gct_s) * 1000.0;
            gc_time_ratio_pct = @max(@as(f64, 0.0), delta_gc_ms * 100.0 / delta_ms);

            const delta_events = (last.ygc - first.ygc) + (last.fgc - first.fgc);
            const window_s = delta_ms / 1000.0;
            if (window_s > 0) {
                gc_rate_per_s = @as(f64, @floatFromInt(delta_events)) / window_s;
            }
        }
    }

    updateFullGcSignal(runtime, pid, now_ms);

    // Short-window metrics drive the reactive TUI GC pressure bar only.
    const short_metrics = computeGcMetricsForWindow(runtime, pid, now_ms - gc_ui_pressure_window_ms);
    if (runtime.gc_fgc_baseline == null) {
        runtime.gc_fgc_baseline = gc.fgc;
    }
    const fgc_count = countFullGcSinceBaseline(runtime, gc.fgc);

    const gc_pressure_raw = computeGcPressureRaw(short_metrics.gc_time_ratio_pct, snapshot.gc_old_occ_pct);
    if (runtime.gc_pressure_ewma <= 0) {
        runtime.gc_pressure_ewma = gc_pressure_raw;
    } else {
        runtime.gc_pressure_ewma = (gc_pressure_ewma_alpha * gc_pressure_raw) +
            ((1.0 - gc_pressure_ewma_alpha) * runtime.gc_pressure_ewma);
    }

    snapshot.gc_time_pct = toPct(gc_time_ratio_pct);
    snapshot.gc_time_pct_x10 = toPctX10(gc_time_ratio_pct);
    snapshot.gc_rate_per_s_x10 = toTenths(gc_rate_per_s);
    snapshot.gc_short_time_pct_x10 = toPctX10(short_metrics.gc_time_ratio_pct);
    snapshot.gc_short_rate_per_s_x10 = toTenths(short_metrics.gc_rate_per_s);
    snapshot.gc_pressure_pct = toPct(runtime.gc_pressure_ewma * 100.0);
    snapshot.gc_fgc_count = fgc_count;
    snapshot.gc_full_seen = runtime.last_full_gc_seen_ts_ms >= 0 and
        (now_ms - runtime.last_full_gc_seen_ts_ms) <= full_gc_signal_hold_ms;
    snapshot.gc_level = computeGcLevel(snapshot, runtime, gc_time_ratio_pct, gc_rate_per_s);
}

const GcMetrics = struct {
    gc_time_ratio_pct: f64 = 0,
    gc_rate_per_s: f64 = 0,
};

fn computeGcMetricsForWindow(runtime: *const types.RuntimeState, pid: u32, min_ts: i64) GcMetrics {
    if (runtime.gc_points_len < 2) return .{};

    const last = runtime.gc_points[runtime.gc_points_len - 1];
    if (last.pid != pid) return .{};

    var first_index: usize = runtime.gc_points_len - 1;
    while (first_index > 0) : (first_index -= 1) {
        const prev = runtime.gc_points[first_index - 1];
        if (prev.pid != pid or prev.ts_ms < min_ts) break;
    }

    const first = runtime.gc_points[first_index];
    if (first.pid != pid or last.ts_ms <= first.ts_ms or last.gct_s < first.gct_s) return .{};

    const delta_ms_i = last.ts_ms - first.ts_ms;
    const delta_ms = @as(f64, @floatFromInt(delta_ms_i));
    if (delta_ms <= 0) return .{};

    const delta_gc_ms = (last.gct_s - first.gct_s) * 1000.0;
    const gc_time_ratio_pct = @max(@as(f64, 0.0), delta_gc_ms * 100.0 / delta_ms);

    const delta_events = (last.ygc - first.ygc) + (last.fgc - first.fgc);
    const window_s = delta_ms / 1000.0;
    const gc_rate_per_s = if (window_s > 0)
        @as(f64, @floatFromInt(delta_events)) / window_s
    else
        0;

    return .{
        .gc_time_ratio_pct = gc_time_ratio_pct,
        .gc_rate_per_s = gc_rate_per_s,
    };
}

fn countFullGcSinceBaseline(runtime: *const types.RuntimeState, current_fgc: u64) u16 {
    const baseline = runtime.gc_fgc_baseline orelse return 0;
    if (current_fgc < baseline) return 0;
    const delta = current_fgc - baseline;
    return if (delta > std.math.maxInt(u16)) std.math.maxInt(u16) else @as(u16, @intCast(delta));
}

fn computeGcPressureRaw(gc_time_ratio_pct_short: f64, old_occ_pct: u8) f64 {
    const gc_norm = std.math.clamp(gc_time_ratio_pct_short / 10.0, 0.0, 1.0);
    const old_f = @as(f64, @floatFromInt(old_occ_pct));
    const old_norm = std.math.clamp((old_f - 70.0) / 25.0, 0.0, 1.0);
    return std.math.clamp((0.7 * gc_norm) + (0.3 * old_norm), 0.0, 1.0);
}

fn appendGcPoint(runtime: *types.RuntimeState, point: types.GcPoint) void {
    if (runtime.gc_points_len > 0) {
        const last = runtime.gc_points[runtime.gc_points_len - 1];
        if (last.pid != point.pid or point.ts_ms < last.ts_ms) {
            runtime.gc_points_len = 0;
            runtime.gc_time_red_windows = 0;
            runtime.last_full_gc_seen_ts_ms = -1;
            runtime.gc_pressure_ewma = 0;
            runtime.gc_fgc_baseline = null;
        }
    }

    if (runtime.gc_points_len >= runtime.gc_points.len) {
        std.mem.copyForwards(types.GcPoint, runtime.gc_points[0 .. runtime.gc_points.len - 1], runtime.gc_points[1..]);
        runtime.gc_points_len = runtime.gc_points.len - 1;
    }
    runtime.gc_points[runtime.gc_points_len] = point;
    runtime.gc_points_len += 1;
}

fn updateFullGcSignal(runtime: *types.RuntimeState, pid: u32, now_ms: i64) void {
    if (runtime.gc_points_len < 2) return;
    const prev = runtime.gc_points[runtime.gc_points_len - 2];
    const last = runtime.gc_points[runtime.gc_points_len - 1];
    if (prev.pid != pid or last.pid != pid) return;
    if (last.fgc > prev.fgc) {
        runtime.last_full_gc_seen_ts_ms = now_ms;
    }
}

fn trimGcWindow(runtime: *types.RuntimeState, pid: u32, now_ms: i64) void {
    if (runtime.gc_points_len == 0) return;
    const min_ts = now_ms - gc_window_ms;

    var start: usize = 0;
    while (start + 1 < runtime.gc_points_len) : (start += 1) {
        const p = runtime.gc_points[start];
        if (p.pid != pid or p.ts_ms >= min_ts) break;
    }

    if (start == 0) return;
    std.mem.copyForwards(types.GcPoint, runtime.gc_points[0 .. runtime.gc_points_len - start], runtime.gc_points[start..runtime.gc_points_len]);
    runtime.gc_points_len -= start;
}

fn computeGcLevel(
    snapshot: *const types.Snapshot,
    runtime: *types.RuntimeState,
    gc_time_ratio_pct: f64,
    gc_rate_per_s: f64,
) u8 {
    if (gc_time_ratio_pct >= 10.0) {
        runtime.gc_time_red_windows = if (runtime.gc_time_red_windows == std.math.maxInt(u8))
            runtime.gc_time_red_windows
        else
            runtime.gc_time_red_windows + 1;
    } else {
        runtime.gc_time_red_windows = 0;
    }

    const old_occ = snapshot.gc_old_occ_pct;
    const sustained_gc_time_red = runtime.gc_time_red_windows >= 2;

    if (snapshot.gc_full_seen or old_occ >= 92 or sustained_gc_time_red) return 3;
    if (gc_time_ratio_pct >= 2.0 or old_occ >= 85) return 2;
    if (gc_time_ratio_pct >= 0.5 or old_occ >= 70 or gc_rate_per_s > 5.0) return 1;
    return 0;
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

fn usagePctU64(value: u64, total: u64) u8 {
    if (total == 0) return 0;
    const raw = (@as(u128, value) * 100) / @as(u128, total);
    if (raw > 100) return 100;
    return @as(u8, @intCast(raw));
}

fn toPctX10(value: f64) u16 {
    const bounded = std.math.clamp(value, 0.0, 100.0);
    return @as(u16, @intFromFloat(@round(bounded * 10.0)));
}

fn toTenths(value: f64) u16 {
    if (!std.math.isFinite(value) or value <= 0) return 0;
    const max_u16_f = @as(f64, @floatFromInt(std.math.maxInt(u16)));
    const bounded = @min(value * 10.0, max_u16_f);
    return @as(u16, @intFromFloat(@round(bounded)));
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
