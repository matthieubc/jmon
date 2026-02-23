// Shared compact snapshot renderer used by TUI and text mode.
// Composes header and section components and exposes common rendering helpers.

const types = @import("../types.zig");
const tui_state = @import("../tui/state.zig");
const header = @import("header.zig");
const memory = @import("memory.zig");
const gc = @import("gc.zig");
const cpu = @import("cpu.zig");
const io = @import("io.zig");
const metrics = @import("metrics.zig");
const fmtu = @import("format.zig");
const std = @import("std");

pub const TextRenderState = tui_state.TextRenderState;
pub const Peaks = tui_state.Peaks;
pub const header_component = header;
pub const memory_component = memory;
pub const gc_component = gc;
pub const cpu_component = cpu;
pub const io_component = io;
pub const computeMainBarWidth = metrics.computeMainBarWidth;
pub const updatePeaks = metrics.updatePeaks;
pub const ioToPct = metrics.ioToPct;
pub const usagePct = metrics.usagePct;
pub const gcSummaryLen = gc.gcSummaryLen;

pub fn writeTextFrame(writer: anytype, snapshot: types.Snapshot, state: *TextRenderState, term_cols: usize) !void {
    _ = term_cols;
    metrics.updatePeaks(&state.peaks, snapshot);
    try writeTextHeader(writer, snapshot);
    try writer.writeAll("\n");
    try writeTextMemoryLine(writer, snapshot, state.peaks.mem_used_bytes);
    try writer.writeAll("\n");
    try writeTextGcLine(writer, snapshot);
    try writer.writeAll("\n");
    try writeTextCpuLine(writer, snapshot);
    try writer.writeAll("\n");
    try writeTextCpuCoresLine(writer, snapshot);
    try writer.writeAll("\n");
    try writeTextIoLine(writer, snapshot);
}

pub fn renderTopLines(
    writer: anytype,
    snapshot: types.Snapshot,
    peaks: Peaks,
    term_cols: usize,
    is_tty: bool,
) !void {
    const main_bar_width = metrics.computeMainBarWidth(term_cols);
    try header.renderHeaderLine(writer, snapshot, is_tty);
    try writer.writeAll("\n\n");
    try memory.renderMemoryBar(writer, snapshot, peaks.mem_pct, peaks.mem_used_bytes, main_bar_width, term_cols, is_tty);
    try gc.renderGcSection(writer, snapshot, peaks.gc_pct, main_bar_width, is_tty);
    try writer.writeAll("\n");
    try cpu.renderCpuSection(writer, snapshot, main_bar_width, is_tty);
    try io.renderIoLine(writer, snapshot, peaks.disk_read_pct, peaks.disk_write_pct, main_bar_width, is_tty);
}

fn writeTextHeader(writer: anytype, snapshot: types.Snapshot) !void {
    try writer.writeAll("jmon");
    try writer.print(" state={s}", .{@tagName(snapshot.state)});
    try writer.writeAll(" pid=");
    if (snapshot.pid) |pid| {
        try writer.print("{d}", .{pid});
    } else {
        try writer.writeAll("-");
    }
    try writer.writeAll(" attached=");
    if (snapshot.attached_app) |app_name| {
        try fmtu.writeQuoted(writer, app_name);
    } else {
        try writer.writeAll("-");
    }
}

fn writeTextMemoryLine(writer: anytype, snapshot: types.Snapshot, peak_used_bytes: u64) !void {
    const mem_total = if (snapshot.mem_max_bytes > 0) snapshot.mem_max_bytes else snapshot.mem_committed_bytes;
    const peak_used = if (snapshot.state == .ATTACHED) peak_used_bytes else 0;

    try writer.writeAll("mem");
    try writer.print(" heap_used_mb={d}", .{bytesToMb(snapshot.mem_used_bytes)});
    try writer.print(" heap_peak_mb={d}", .{bytesToMb(peak_used)});
    try writer.print(" heap_committed_mb={d}", .{bytesToMb(snapshot.mem_committed_bytes)});
    try writer.print(" heap_max_mb={d}", .{bytesToMb(mem_total)});
    try writer.print(" phys_mb={d}", .{bytesToMb(snapshot.mem_physical_footprint_bytes)});
}

fn writeTextGcLine(writer: anytype, snapshot: types.Snapshot) !void {
    try writer.writeAll("gc");
    if (snapshot.state != .ATTACHED) {
        try writer.writeAll(" attached=false");
        return;
    }

    try writer.print(" pressure_pct={d}", .{snapshot.gc_pressure_pct});
    try writer.print(" short_time_pct={d}.{d}", .{
        snapshot.gc_short_time_pct_x10 / 10,
        snapshot.gc_short_time_pct_x10 % 10,
    });
    try writer.print(" old_occ_pct={d}", .{snapshot.gc_old_occ_pct});
    try writer.print(" ygc={d}", .{snapshot.gc_ygc_count});
    try writer.print(" fgc={d}", .{snapshot.gc_fgc_count});
    try writer.print(" short_rate_per_s={d}.{d}", .{
        snapshot.gc_short_rate_per_s_x10 / 10,
        snapshot.gc_short_rate_per_s_x10 % 10,
    });
    try writer.print(" full_seen={s}", .{if (snapshot.gc_full_seen) "true" else "false"});
}

fn writeTextCpuLine(writer: anytype, snapshot: types.Snapshot) !void {
    try writer.writeAll("cpu");
    if (snapshot.state != .ATTACHED) {
        try writer.writeAll(" attached=false");
        return;
    }

    const raw_whole = snapshot.cpu_process_pct_x10 / 10;
    const raw_tenth = snapshot.cpu_process_pct_x10 % 10;
    const cores_x10 = @as(u16, @intCast((@as(u32, snapshot.cpu_process_pct_x10) + 50) / 100));
    try writer.print(" jvm_pct={d}.{d}", .{ raw_whole, raw_tenth });
    try writer.print(" jvm_cores={d}.{d}", .{ cores_x10 / 10, cores_x10 % 10 });
    try writer.print(" normalized_bar_pct={d}", .{snapshot.cpu_total_pct});
    try writer.print(" host_core_count={d}", .{snapshot.cpu_host_core_count});
}

fn writeTextCpuCoresLine(writer: anytype, snapshot: types.Snapshot) !void {
    try writer.writeAll("cpu_cores");
    if (snapshot.state != .ATTACHED or snapshot.cpu_host_core_count == 0) {
        try writer.writeAll(" attached=false");
        return;
    }
    var i: usize = 0;
    const count = @as(usize, snapshot.cpu_host_core_count);
    while (i < count) : (i += 1) {
        try writer.print(" c{d}={d}", .{ i + 1, snapshot.cpu_host_core_pcts[i] });
    }
}

fn writeTextIoLine(writer: anytype, snapshot: types.Snapshot) !void {
    try writer.writeAll("io");
    try writer.print(" disk_read_bps={d}", .{snapshot.io_disk_read_bps});
    try writer.print(" disk_write_bps={d}", .{snapshot.io_disk_write_bps});
    try writer.print(" disk_read_total_bytes={d}", .{snapshot.io_disk_read_total_bytes});
    try writer.print(" disk_write_total_bytes={d}", .{snapshot.io_disk_write_total_bytes});
    try writer.print(" disk_bps={d}", .{snapshot.io_disk_bps});
    try writer.print(" net_bps={d}", .{snapshot.io_net_bps});
    try writer.print(" finding_count={d}", .{snapshot.finding_count});
}

fn bytesToMb(bytes: u64) u64 {
    const mb = (@as(u128, bytes) + (1024 * 1024 / 2)) / (1024 * 1024);
    return @as(u64, @intCast(mb));
}
