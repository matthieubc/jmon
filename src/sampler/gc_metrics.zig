// GC analytics and rolling-window state updates.
// Computes GC summary metrics, pressure signals, and baseline counters from jstat data.
// GC pressure is a 0..1 score (later rendered as 0..100%) used for the live TUI GC bar.
// It is intended to be a short-term "how much GC is hurting right now" indicator, not
// a direct raw GC metric. The score blends short-window GC time ratio and old-gen occupancy,
// then applies EWMA smoothing to reduce flicker.

const std = @import("std");
const types = @import("../types.zig");
const jvm_jstat = @import("../jvm/jstat_gc.zig");

// Stable GC window used for anomaly scoring and summary fields.
const gc_window_ms: i64 = 60 * 1000;
// Short GC window used for the live TUI GC pressure indicator.
const gc_ui_pressure_window_ms: i64 = 2 * 1000;
const full_gc_signal_hold_ms: i64 = 15 * 1000;
const gc_pressure_ewma_alpha: f64 = 0.25;

pub fn applyGcWindowMetrics(
    snapshot: *types.Snapshot,
    runtime: *types.RuntimeState,
    pid: u32,
    gc: jvm_jstat.JstatGc,
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

    const short_metrics = computeGcMetricsForWindow(runtime, pid, now_ms - gc_ui_pressure_window_ms);
    if (runtime.gc_ygc_baseline == null) runtime.gc_ygc_baseline = gc.ygc;
    if (runtime.gc_fgc_baseline == null) runtime.gc_fgc_baseline = gc.fgc;
    const ygc_count = countGcSinceBaseline(runtime.gc_ygc_baseline, gc.ygc);
    const fgc_count = countGcSinceBaseline(runtime.gc_fgc_baseline, gc.fgc);

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
    snapshot.gc_ygc_count = ygc_count;
    snapshot.gc_fgc_count = fgc_count;
    snapshot.gc_full_seen = runtime.last_full_gc_seen_ts_ms >= 0 and
        (now_ms - runtime.last_full_gc_seen_ts_ms) <= full_gc_signal_hold_ms;
    snapshot.gc_level = computeGcLevel(snapshot, runtime, gc_time_ratio_pct, gc_rate_per_s);
}

pub fn resetGcRuntime(runtime: *types.RuntimeState) void {
    runtime.gc_points_len = 0;
    runtime.gc_time_red_windows = 0;
    runtime.last_full_gc_seen_ts_ms = -1;
    runtime.gc_pressure_ewma = 0;
    runtime.gc_ygc_baseline = null;
    runtime.gc_fgc_baseline = null;
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

    return .{ .gc_time_ratio_pct = gc_time_ratio_pct, .gc_rate_per_s = gc_rate_per_s };
}

fn countGcSinceBaseline(baseline_opt: ?u64, current_count: u64) u16 {
    const baseline = baseline_opt orelse return 0;
    if (current_count < baseline) return 0;
    const delta = current_count - baseline;
    return if (delta > std.math.maxInt(u16)) std.math.maxInt(u16) else @as(u16, @intCast(delta));
}

fn computeGcPressureRaw(gc_time_ratio_pct_short: f64, old_occ_pct: u8) f64 {
    // Pressure formula (before EWMA smoothing):
    //   gc_norm  = clamp(short_gc_time_pct / 10, 0, 1)
    //   old_norm = clamp((old_occ_pct - 70) / 25, 0, 1)
    //   pressure = clamp(0.7 * gc_norm + 0.3 * old_norm, 0, 1)
    //
    // Interpretation:
    // - 70% weight on short-window GC time ratio (instant impact)
    // - 30% weight on old-gen occupancy (headroom/risk signal)
    // - short_gc_time_pct >= 10% saturates the GC-time component
    // - old_occ_pct <= 70% contributes 0, old_occ_pct >= 95% saturates the old-gen component
    const gc_norm = std.math.clamp(gc_time_ratio_pct_short / 10.0, 0.0, 1.0);
    const old_f = @as(f64, @floatFromInt(old_occ_pct));
    const old_norm = std.math.clamp((old_f - 70.0) / 25.0, 0.0, 1.0);
    return std.math.clamp((0.7 * gc_norm) + (0.3 * old_norm), 0.0, 1.0);
}

fn appendGcPoint(runtime: *types.RuntimeState, point: types.GcPoint) void {
    if (runtime.gc_points_len > 0) {
        const last = runtime.gc_points[runtime.gc_points_len - 1];
        if (last.pid != point.pid or point.ts_ms < last.ts_ms) {
            resetGcRuntime(runtime);
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
    if (last.fgc > prev.fgc) runtime.last_full_gc_seen_ts_ms = now_ms;
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

fn computeGcLevel(snapshot: *const types.Snapshot, runtime: *types.RuntimeState, gc_time_ratio_pct: f64, gc_rate_per_s: f64) u8 {
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
