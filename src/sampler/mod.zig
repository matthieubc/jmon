// Snapshot collection orchestration for jmon.
// Attaches to a target JVM, gathers probe data, and assembles the public snapshot struct.

const std = @import("std");
const types = @import("../types.zig");
const gc_metrics = @import("gc_metrics.zig");
const platform = @import("../platform/mod.zig");
const jvm_discovery = @import("../jvm/discovery.zig");
const jvm_heap = @import("../jvm/heap_max.zig");
const jvm_jstat = @import("../jvm/jstat_gc.zig");

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
        .cpu_process_pct_x10 = 0,
        .cpu_host_core_count = 0,
        .cpu_host_core_pcts = [_]u8{0} ** types.max_cpu_cores,
        .gc_time_pct = 0,
        .gc_time_pct_x10 = 0,
        .gc_short_time_pct_x10 = 0,
        .gc_pressure_pct = 0,
        .gc_level = 0,
        .gc_old_occ_pct = 0,
        .gc_rate_per_s_x10 = 0,
        .gc_short_rate_per_s_x10 = 0,
        .gc_full_seen = false,
        .gc_ygc_count = 0,
        .gc_fgc_count = 0,
        .io_disk_bps = 0,
        .io_disk_read_bps = 0,
        .io_disk_write_bps = 0,
        .io_disk_read_total_bytes = 0,
        .io_disk_write_total_bytes = 0,
        .io_net_bps = 0,
        .finding_count = 0,
    };

    const target = jvm_discovery.findTargetProcess(allocator, app_pattern, runtime.attached_pid) orelse {
        snapshot.state = if (runtime.was_attached) .LOST else .SEARCHING;
        runtime.was_attached = false;
        runtime.attached_pid = null;
        gc_metrics.resetGcRuntime(runtime);
        runtime.heap_max_pid = null;
        runtime.heap_max_bytes = 0;
        runtime.attached_app_len = 0;
        resetDiskIoRuntime(runtime);
        return snapshot;
    };

    snapshot.state = .ATTACHED;
    snapshot.pid = target.pid;
    runtime.attached_pid = target.pid;
    snapshot.attached_app = setAttachedApp(runtime, target.appName());
    snapshot.mem_max_bytes = readHeapMaxBytesCached(allocator, runtime, target.pid) orelse 0;
    runtime.was_attached = true;

    if (platform.readPhysicalFootprintBytes(allocator, target.pid)) |footprint| {
        snapshot.mem_physical_footprint_bytes = footprint;
    }
    populateProcessDiskIoMetrics(allocator, &snapshot, runtime, target.pid);

    if (jvm_jstat.readJstatGc(allocator, target.pid)) |gc| {
        snapshot.mem_used_bytes = gc.heap_used_bytes;
        snapshot.mem_committed_bytes = gc.heap_committed_bytes;
        gc_metrics.applyGcWindowMetrics(&snapshot, runtime, target.pid, gc);
    } else {
        gc_metrics.resetGcRuntime(runtime);
    }

    populateHostCpuCoreMetrics(allocator, &snapshot, runtime);

    if (readCpuProcessPctX10(allocator, target.pid)) |cpu_x10| {
        snapshot.cpu_process_pct_x10 = cpu_x10;
        snapshot.cpu_total_pct = normalizeProcessCpuToMachinePct(cpu_x10, snapshot.cpu_host_core_count);
    }

    snapshot.finding_count = computeFindingCount(snapshot);
    return snapshot;
}

fn populateProcessDiskIoMetrics(
    allocator: std.mem.Allocator,
    snapshot: *types.Snapshot,
    runtime: *types.RuntimeState,
    pid: u32,
) void {
    const counters = platform.readProcessDiskIoCounters(allocator, pid) orelse {
        runtime.disk_io_prev_valid = false;
        runtime.disk_io_prev_pid = pid;
        runtime.disk_io_total_baseline_valid = false;
        runtime.disk_io_total_baseline_pid = pid;
        return;
    };

    const now_ms = std.time.milliTimestamp();
    if (!runtime.disk_io_total_baseline_valid or runtime.disk_io_total_baseline_pid == null or runtime.disk_io_total_baseline_pid.? != pid) {
        runtime.disk_io_total_baseline_pid = pid;
        runtime.disk_io_total_baseline_read_bytes = counters.read_bytes;
        runtime.disk_io_total_baseline_write_bytes = counters.write_bytes;
        runtime.disk_io_total_baseline_valid = true;
    }
    if (counters.read_bytes >= runtime.disk_io_total_baseline_read_bytes) {
        snapshot.io_disk_read_total_bytes = counters.read_bytes - runtime.disk_io_total_baseline_read_bytes;
    }
    if (counters.write_bytes >= runtime.disk_io_total_baseline_write_bytes) {
        snapshot.io_disk_write_total_bytes = counters.write_bytes - runtime.disk_io_total_baseline_write_bytes;
    }

    if (!runtime.disk_io_prev_valid or runtime.disk_io_prev_pid == null or runtime.disk_io_prev_pid.? != pid) {
        runtime.disk_io_prev_pid = pid;
        runtime.disk_io_prev_ts_ms = now_ms;
        runtime.disk_io_prev_read_bytes = counters.read_bytes;
        runtime.disk_io_prev_write_bytes = counters.write_bytes;
        runtime.disk_io_prev_valid = true;
        return;
    }

    const dt_ms = now_ms - runtime.disk_io_prev_ts_ms;
    if (dt_ms <= 0) return;

    if (counters.read_bytes >= runtime.disk_io_prev_read_bytes) {
        const delta_read = counters.read_bytes - runtime.disk_io_prev_read_bytes;
        snapshot.io_disk_read_bps = bytesPerSecond(delta_read, dt_ms);
    }
    if (counters.write_bytes >= runtime.disk_io_prev_write_bytes) {
        const delta_write = counters.write_bytes - runtime.disk_io_prev_write_bytes;
        snapshot.io_disk_write_bps = bytesPerSecond(delta_write, dt_ms);
    }
    snapshot.io_disk_bps = snapshot.io_disk_read_bps + snapshot.io_disk_write_bps;

    runtime.disk_io_prev_pid = pid;
    runtime.disk_io_prev_ts_ms = now_ms;
    runtime.disk_io_prev_read_bytes = counters.read_bytes;
    runtime.disk_io_prev_write_bytes = counters.write_bytes;
    runtime.disk_io_prev_valid = true;
}

pub fn resetDiskIoRuntime(runtime: *types.RuntimeState) void {
    runtime.disk_io_prev_valid = false;
    runtime.disk_io_prev_pid = null;
    runtime.disk_io_prev_ts_ms = 0;
    runtime.disk_io_prev_read_bytes = 0;
    runtime.disk_io_prev_write_bytes = 0;
    runtime.disk_io_total_baseline_valid = false;
    runtime.disk_io_total_baseline_pid = null;
    runtime.disk_io_total_baseline_read_bytes = 0;
    runtime.disk_io_total_baseline_write_bytes = 0;
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

fn readCpuProcessPctX10(allocator: std.mem.Allocator, pid: u32) ?u16 {
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
    const cpu = jvm_jstat.parseLocalizedFloat(cpu_str) orelse return null;
    return toPctX10(cpu);
}

fn readHeapMaxBytesCached(allocator: std.mem.Allocator, runtime: *types.RuntimeState, pid: u32) ?u64 {
    if (runtime.heap_max_pid) |cached_pid| {
        if (cached_pid == pid and runtime.heap_max_bytes > 0) return runtime.heap_max_bytes;
    }

    runtime.heap_max_pid = pid;
    runtime.heap_max_bytes = 0;

    const max_bytes = jvm_heap.readHeapMaxBytesFromPs(allocator, pid) orelse return null;
    runtime.heap_max_bytes = max_bytes;
    return max_bytes;
}

fn isExit0(term: std.process.Child.Term) bool {
    return switch (term) {
        .Exited => |code| code == 0,
        else => false,
    };
}

fn toPct(value: f64) u8 {
    const bounded = std.math.clamp(value, 0.0, 100.0);
    return @as(u8, @intFromFloat(@round(bounded)));
}

fn toPctX10(value: f64) u16 {
    const bounded = std.math.clamp(value, 0.0, @as(f64, @floatFromInt(std.math.maxInt(u16))) / 10.0);
    return @as(u16, @intFromFloat(@round(bounded * 10.0)));
}

fn normalizeProcessCpuToMachinePct(cpu_process_pct_x10: u16, host_core_count: u8) u8 {
    if (host_core_count == 0) {
        return toPct(@as(f64, @floatFromInt(cpu_process_pct_x10)) / 10.0);
    }
    const raw_pct = @as(f64, @floatFromInt(cpu_process_pct_x10)) / 10.0;
    const core_count = @as(f64, @floatFromInt(host_core_count));
    return toPct(raw_pct / core_count);
}

fn bytesPerSecond(delta_bytes: u64, dt_ms: i64) u64 {
    if (dt_ms <= 0) return 0;
    const dt_ms_u = @as(u64, @intCast(dt_ms));
    const scaled = std.math.mul(u128, @as(u128, delta_bytes), 1000) catch return 0;
    return @as(u64, @intCast(scaled / dt_ms_u));
}

fn populateHostCpuCoreMetrics(
    allocator: std.mem.Allocator,
    snapshot: *types.Snapshot,
    runtime: *types.RuntimeState,
) void {
    const sample = platform.readHostCpuCoreTicks(allocator) orelse return;
    if (sample.len == 0) {
        runtime.host_cpu_prev_valid = false;
        runtime.host_cpu_prev_count = 0;
        return;
    }

    snapshot.cpu_host_core_count = @as(u8, @intCast(@min(sample.len, @as(usize, std.math.maxInt(u8)))));

    if (runtime.host_cpu_prev_valid and runtime.host_cpu_prev_count == sample.len) {
        var i: usize = 0;
        while (i < sample.len) : (i += 1) {
            const prev_total = runtime.host_cpu_prev_total_ticks[i];
            const prev_idle = runtime.host_cpu_prev_idle_ticks[i];
            const cur_total = sample.total_ticks[i];
            const cur_idle = sample.idle_ticks[i];

            if (cur_total <= prev_total or cur_idle < prev_idle) {
                snapshot.cpu_host_core_pcts[i] = 0;
                continue;
            }

            const delta_total = cur_total - prev_total;
            const delta_idle = if (cur_idle > prev_idle) cur_idle - prev_idle else 0;
            if (delta_total == 0) {
                snapshot.cpu_host_core_pcts[i] = 0;
                continue;
            }
            const active = delta_total - @min(delta_idle, delta_total);
            const pct_raw = (@as(u128, active) * 100) / @as(u128, delta_total);
            snapshot.cpu_host_core_pcts[i] = @as(u8, @intCast(@min(pct_raw, 100)));
        }
    }

    runtime.host_cpu_prev_valid = true;
    runtime.host_cpu_prev_count = sample.len;
    std.mem.copyForwards(u64, runtime.host_cpu_prev_total_ticks[0..sample.len], sample.total_ticks[0..sample.len]);
    std.mem.copyForwards(u64, runtime.host_cpu_prev_idle_ticks[0..sample.len], sample.idle_ticks[0..sample.len]);
}

fn computeFindingCount(snapshot: types.Snapshot) u32 {
    var findings: u32 = 0;
    if (snapshot.cpu_process_pct_x10 >= 800) findings += 1;
    if (snapshot.gc_time_pct >= 15) findings += 1;
    if (snapshot.mem_committed_bytes > 0) {
        const mem_pct = (@as(u128, snapshot.mem_used_bytes) * 100) / @as(u128, snapshot.mem_committed_bytes);
        if (mem_pct >= 90) findings += 1;
    }
    return findings;
}
