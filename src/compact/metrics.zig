// Small metric helpers shared by compact rendering code.
// Updates visual peaks and computes normalized percentages for bars.

const types = @import("../types.zig");
const tui_state = @import("../tui/state.zig");

pub fn usagePct(value: u64, total: u64) u8 {
    if (total == 0) return 0;
    const raw = (@as(u128, value) * 100) / @as(u128, total);
    if (raw > 100) return 100;
    return @as(u8, @intCast(raw));
}

pub fn ioToPct(io_total_bps: u64) u8 {
    const full_scale: u64 = 100 * 1024 * 1024;
    return usagePct(io_total_bps, full_scale);
}

pub fn updatePeaks(peaks: *tui_state.Peaks, snapshot: types.Snapshot) void {
    if (snapshot.state != .ATTACHED) {
        peaks.* = .{};
        return;
    }
    const mem_total = if (snapshot.mem_max_bytes > 0) snapshot.mem_max_bytes else snapshot.mem_committed_bytes;
    const mem_pct = usagePct(snapshot.mem_used_bytes, mem_total);
    peaks.mem_pct = @max(peaks.mem_pct, mem_pct);
    peaks.mem_used_bytes = @max(peaks.mem_used_bytes, snapshot.mem_used_bytes);
    peaks.cpu_pct = @max(peaks.cpu_pct, snapshot.cpu_total_pct);
    peaks.gc_pct = @max(peaks.gc_pct, snapshot.gc_pressure_pct);
    const io_total = snapshot.io_disk_bps + snapshot.io_net_bps;
    peaks.io_pct = @max(peaks.io_pct, ioToPct(io_total));
    peaks.disk_read_pct = @max(peaks.disk_read_pct, ioToPct(snapshot.io_disk_read_bps));
    peaks.disk_write_pct = @max(peaks.disk_write_pct, ioToPct(snapshot.io_disk_write_bps));
}

pub fn computeMainBarWidth(term_cols: usize) usize {
    if (term_cols == 0) return (tui_state.fallback_bar_width * 3) / 4;
    const reserve: usize = 40;
    const raw = if (term_cols <= reserve + tui_state.min_bar_width)
        tui_state.min_bar_width
    else
        @import("std").math.clamp(term_cols - reserve, tui_state.min_bar_width, tui_state.max_bar_width);
    const scaled = @max(tui_state.min_bar_width, (raw * 3) / 4);
    return @import("std").math.clamp(scaled, tui_state.min_bar_width, tui_state.max_bar_width);
}
