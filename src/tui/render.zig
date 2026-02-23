// TUI rendering and memory chart drawing.
// Renders the top panel, prompt area, and optional memory history chart.

const std = @import("std");
const types = @import("../types.zig");
const compact = @import("../compact/mod.zig");
const tui_state = @import("state.zig");

const UiState = tui_state.UiState;
const Peaks = tui_state.Peaks;
const color_empty = tui_state.color_empty;
const fallback_bar_width = tui_state.fallback_bar_width;
const mem_graph_max_cols = tui_state.mem_graph_max_cols;
const graph_row_buf_len = tui_state.graph_row_buf_len;
const graph_right_scale_width = tui_state.graph_right_scale_width;
const graph_right_gap = tui_state.graph_right_gap;
const graph_title_row = tui_state.graph_title_row;
const graph_top_row = tui_state.graph_top_row;
const graph_height = tui_state.graph_height;
const graph_axis_row = tui_state.graph_axis_row;
const graph_label_row = tui_state.graph_label_row;
const prompt_row = tui_state.prompt_row;
const status_row = tui_state.status_row;
const legend_row = tui_state.legend_row;
const graph_mark = tui_state.graph_mark;

pub fn renderVisualFrame(
    writer: anytype,
    snapshot: types.Snapshot,
    peaks: Peaks,
    ui: *const UiState,
    is_tty: bool,
    term_cols: usize,
    show_memory_chart: bool,
) !void {
    if (is_tty) try writer.writeAll("\x1b7");
    try writer.writeAll("\x1b[H");
    const main_bar_width = compact.computeMainBarWidth(term_cols);

    try clearLine(writer);
    try compact.header_component.renderHeaderLine(writer, snapshot, is_tty);
    try writer.writeAll("\n\n");

    try clearLine(writer);
    try compact.memory_component.renderMemoryBar(writer, snapshot, peaks.mem_pct, peaks.mem_used_bytes, main_bar_width, term_cols, is_tty);

    try clearLine(writer);
    try compact.gc_component.renderGcSection(writer, snapshot, peaks.gc_pct, main_bar_width, is_tty);

    // Keep a visual gap between GC and CPU sections.
    try clearLine(writer);
    try writer.writeAll("\n");
    try clearLine(writer);
    _ = peaks.cpu_pct; // CPU watermark is disabled; per-core bars + normalized JVM bar are shown instead.
    try compact.cpu_component.renderCpuSection(writer, snapshot, main_bar_width, is_tty);

    try clearLine(writer);
    try compact.io_component.renderIoLine(writer, snapshot, peaks.disk_read_pct, peaks.disk_write_pct, main_bar_width, is_tty);

    try renderScopeLegend(writer, is_tty);

    if (show_memory_chart) {
        try renderMemoryHistorySection(writer, ui, snapshot, term_cols, is_tty);
    } else {
        try clearMemoryHistorySection(writer);
    }
    if (is_tty) try writer.writeAll("\x1b8");
}

pub fn renderPromptArea(writer: anytype, ui: UiState, is_tty: bool) !void {
    try writer.print("\x1b[{d};1H", .{prompt_row});
    try clearLine(writer);
    try writer.writeAll(">> ");
    if (ui.input_len > 0) try writer.writeAll(ui.input_buf[0..ui.input_len]);

    try writer.print("\x1b[{d};1H", .{status_row});
    try clearLine(writer);
    if (ui.status_len > 0) {
        if (is_tty) try writer.writeAll("\x1b[2m");
        try writer.writeAll(ui.status_buf[0..ui.status_len]);
        if (is_tty) try writer.writeAll("\x1b[0m");
    }

    try writer.print("\x1b[{d};{d}H", .{ prompt_row, 4 + ui.input_len });
}

pub fn recordMemGraphSample(ui: *UiState, snapshot: types.Snapshot) void {
    if (snapshot.state != .ATTACHED or snapshot.pid == null) {
        resetMemGraph(ui);
        return;
    }

    const pid = snapshot.pid.?;
    if (ui.mem_graph_pid == null or ui.mem_graph_pid.? != pid) {
        resetMemGraph(ui);
        ui.mem_graph_pid = pid;
    }

    const total = if (snapshot.mem_max_bytes > 0) snapshot.mem_max_bytes else snapshot.mem_committed_bytes;
    const pct = compact.usagePct(snapshot.mem_used_bytes, total);
    ui.mem_graph_last_pct = pct;
    appendPendingMemGraphSample(ui, pct);
}

pub fn advanceMemGraphFrame(ui: *UiState, snapshot: types.Snapshot) void {
    if (snapshot.state != .ATTACHED or snapshot.pid == null) {
        resetMemGraph(ui);
        return;
    }

    const pid = snapshot.pid.?;
    if (ui.mem_graph_pid == null or ui.mem_graph_pid.? != pid) {
        resetMemGraph(ui);
        ui.mem_graph_pid = pid;
    }

    if (ui.mem_graph_pending_len == 0) {
        appendMemGraphPoint(ui, ui.mem_graph_last_pct);
        return;
    }

    var i: usize = 0;
    while (i < ui.mem_graph_pending_len) : (i += 1) {
        appendMemGraphPoint(ui, ui.mem_graph_pending[i]);
    }
    ui.mem_graph_pending_len = 0;
}

pub fn resetMemGraph(ui: *UiState) void {
    ui.mem_graph_pid = null;
    ui.mem_graph_len = 0;
    ui.mem_graph_pending_len = 0;
    ui.mem_graph_last_pct = 0;
}

fn appendMemGraphPoint(ui: *UiState, pct: u8) void {
    if (ui.mem_graph_len >= ui.mem_graph_cols.len) {
        std.mem.copyForwards(u8, ui.mem_graph_cols[0 .. ui.mem_graph_cols.len - 1], ui.mem_graph_cols[1..]);
        ui.mem_graph_len = ui.mem_graph_cols.len - 1;
    }
    ui.mem_graph_cols[ui.mem_graph_len] = pct;
    ui.mem_graph_len += 1;
}

fn appendPendingMemGraphSample(ui: *UiState, pct: u8) void {
    if (ui.mem_graph_pending_len >= ui.mem_graph_pending.len) {
        std.mem.copyForwards(u8, ui.mem_graph_pending[0 .. ui.mem_graph_pending.len - 1], ui.mem_graph_pending[1..]);
        ui.mem_graph_pending_len = ui.mem_graph_pending.len - 1;
    }
    ui.mem_graph_pending[ui.mem_graph_pending_len] = pct;
    ui.mem_graph_pending_len += 1;
}

fn renderMemoryHistorySection(
    writer: anytype,
    ui: *const UiState,
    snapshot: types.Snapshot,
    term_cols: usize,
    is_tty: bool,
) !void {
    const plot_width = computeGraphPlotWidth(term_cols);
    const plot_left_col: usize = 1;
    const right_scale_col: usize = plot_left_col + plot_width + graph_right_gap;
    const graph_color = "\x1b[38;5;39m";
    const graph_total_bytes = if (snapshot.mem_max_bytes > 0) snapshot.mem_max_bytes else snapshot.mem_committed_bytes;
    const visible_cols = @min(plot_width, ui.mem_graph_len);

    try writer.print("\x1b[{d};1H", .{graph_title_row});
    try clearLine(writer);
    var r: usize = 0;
    while (r < graph_height) : (r += 1) {
        try writer.print("\x1b[{d};1H", .{graph_top_row + r});
        try clearLine(writer);
    }
    try writer.print("\x1b[{d};1H", .{graph_axis_row});
    try clearLine(writer);
    try writer.print("\x1b[{d};1H", .{graph_label_row});
    try clearLine(writer);
    if (snapshot.state != .ATTACHED or ui.mem_graph_len == 0) return;

    var span_tmp: [16]u8 = undefined;
    const span = formatGraphSpanLabel(&span_tmp, visible_cols, ui.sample_interval_ms);
    var title_buf: [64]u8 = undefined;
    const title = std.fmt.bufPrint(&title_buf, "MEM history (last {s})", .{span}) catch "MEM history";
    try writer.print("\x1b[{d};1H", .{graph_title_row});
    try writeSectionTitleSeparator(writer, title, term_cols, is_tty);

    var rows: [graph_height][graph_row_buf_len]u8 = undefined;
    var row_lens: [graph_height]usize = [_]usize{0} ** graph_height;

    var marks: [mem_graph_max_cols]u8 = undefined;
    if (plot_width > marks.len) return;
    @memset(marks[0..plot_width], 0);
    const visible = visible_cols;
    const dst_start = plot_width - visible;
    const src_start = ui.mem_graph_len - visible;

    var col: usize = 0;
    while (col < visible) : (col += 1) {
        const pct = ui.mem_graph_cols[src_start + col];
        const row_from_bottom = (@as(usize, pct) * (graph_height - 1)) / 100;
        const target_row = (graph_height - 1) - row_from_bottom;
        marks[dst_start + col] = @as(u8, @intCast(target_row + 1));
    }

    r = 0;
    while (r < graph_height) : (r += 1) {
        row_lens[r] = 0;
        col = 0;
        while (col < plot_width) : (col += 1) {
            const is_mark = marks[col] == @as(u8, @intCast(r + 1));
            appendCell(&rows[r], &row_lens[r], if (is_mark) graph_mark else " ");
        }
    }

    r = 0;
    while (r < graph_height) : (r += 1) {
        try writer.print("\x1b[{d};{d}H", .{ graph_top_row + r, plot_left_col });
        try clearLine(writer);
        if (is_tty) try writer.writeAll(graphColorForRow(r, graph_height, graph_color));
        try writer.writeAll(rows[r][0..row_lens[r]]);
        if (is_tty) try writer.writeAll("\x1b[0m");
        try writer.print("\x1b[{d};{d}H", .{ graph_top_row + r, right_scale_col });
        if (is_tty) try writer.writeAll("\x1b[2m");
        try writeGraphRightScaleLabel(writer, r, graph_total_bytes);
        if (is_tty) try writer.writeAll("\x1b[0m");
    }
}

fn clearMemoryHistorySection(writer: anytype) !void {
    try writer.print("\x1b[{d};1H", .{graph_title_row});
    try clearLine(writer);
    var r: usize = 0;
    while (r < graph_height) : (r += 1) {
        try writer.print("\x1b[{d};1H", .{graph_top_row + r});
        try clearLine(writer);
    }
    try writer.print("\x1b[{d};1H", .{graph_axis_row});
    try clearLine(writer);
    try writer.print("\x1b[{d};1H", .{graph_label_row});
    try clearLine(writer);
}

fn renderScopeLegend(writer: anytype, is_tty: bool) !void {
    try writer.print("\x1b[{d};1H", .{legend_row});
    try clearLine(writer);
    if (is_tty) try writer.writeAll("\x1b[2m");
    try writer.writeAll("(h) host-level metrics");
    if (is_tty) try writer.writeAll("\x1b[0m");
}

fn fillLine(buf: []u8, len: *usize, count: usize, cell: []const u8) void {
    len.* = 0;
    var i: usize = 0;
    while (i < count) : (i += 1) appendCell(buf, len, cell);
}

fn appendCell(buf: []u8, len: *usize, cell: []const u8) void {
    if (len.* + cell.len > buf.len) return;
    std.mem.copyForwards(u8, buf[len.* .. len.* + cell.len], cell);
    len.* += cell.len;
}

pub fn writeSectionTitleSeparator(writer: anytype, title: []const u8, term_cols: usize, is_tty: bool) !void {
    try writer.writeAll(title);

    const total_cols = if (term_cols == 0) fallback_bar_width else term_cols;
    const used_cols = title.len;
    if (used_cols + 2 >= total_cols) return;

    try writer.writeAll(" ");
    if (is_tty) try writer.writeAll(color_empty);
    var i: usize = 0;
    const fill = total_cols - used_cols - 1;
    while (i < fill) : (i += 1) try writer.writeAll("─");
    if (is_tty) try writer.writeAll("\x1b[0m");
}

fn graphColorForRow(row: usize, height: usize, base_color: []const u8) []const u8 {
    if (row == 0 or row == height - 1) return "\x1b[2m";
    return base_color;
}

fn formatGraphSpanLabel(tmp: []u8, visible_cols: usize, sample_interval_ms: u64) []const u8 {
    if (visible_cols <= 1) return "0s";
    const span_ms = @as(u64, visible_cols - 1) * sample_interval_ms;
    const age = formatAgeLabel(tmp, span_ms);
    if (age.len > 0 and age[0] == '-') return age[1..];
    return age;
}

fn writeGraphRightScaleLabel(writer: anytype, row: usize, total_bytes: u64) !void {
    var tmp: [16]u8 = undefined;
    const label = graphRightScaleLabel(&tmp, row, total_bytes);
    if (label.len == 0) return;
    try writer.print("{s: >10}", .{label});
}

fn graphRightScaleLabel(tmp: []u8, row: usize, total_bytes: u64) []const u8 {
    if (row == graphRowForPct(100)) return formatMbLabel(tmp, graphBytesForPct(total_bytes, 100));
    if (row == graphRowForPct(75)) return formatMbLabel(tmp, graphBytesForPct(total_bytes, 75));
    if (row == graphRowForPct(50)) return formatMbLabel(tmp, graphBytesForPct(total_bytes, 50));
    if (row == graphRowForPct(25)) return formatMbLabel(tmp, graphBytesForPct(total_bytes, 25));
    if (row == graphRowForPct(0)) return formatMbLabel(tmp, 0);
    return "";
}

fn graphRowForPct(pct: u8) usize {
    const row_from_bottom = ((@as(usize, pct) * (graph_height - 1)) + 50) / 100;
    return (graph_height - 1) - @min(row_from_bottom, graph_height - 1);
}

fn graphBytesForPct(total_bytes: u64, pct: u8) u64 {
    return @as(u64, @intCast((@as(u128, total_bytes) * pct) / 100));
}

fn formatMbLabel(tmp: []u8, bytes: u64) []const u8 {
    const mb = (@as(u128, bytes) + (1024 * 1024 / 2)) / (1024 * 1024);
    return std.fmt.bufPrint(tmp, "{d}MB", .{mb}) catch "";
}

fn formatAgeLabel(tmp: []u8, age_ms: u64) []const u8 {
    if (age_ms == 0) return "0s";
    const age_s = age_ms / 1000;
    if (age_s < 60) {
        return std.fmt.bufPrint(tmp, "-{d}s", .{age_s}) catch "-s";
    }
    const mins = age_s / 60;
    const secs = age_s % 60;
    if (secs == 0) {
        return std.fmt.bufPrint(tmp, "-{d}m", .{mins}) catch "-m";
    }
    return std.fmt.bufPrint(tmp, "-{d}m{d:0>2}s", .{ mins, secs }) catch "-m";
}

fn computeGraphPlotWidth(term_cols: usize) usize {
    const total_cols = if (term_cols == 0)
        fallback_bar_width
    else
        @min(term_cols, mem_graph_max_cols + graph_right_gap + graph_right_scale_width);

    const reserve = graph_right_gap + graph_right_scale_width;
    if (total_cols <= reserve + 16) return 16;
    return @min(mem_graph_max_cols, total_cols - reserve);
}

fn clearLine(writer: anytype) !void {
    try writer.writeAll("\x1b[2K");
}
