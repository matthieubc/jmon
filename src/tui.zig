const sampler = @import("sampler.zig");
const std = @import("std");
const types = @import("types.zig");

const fallback_bar_width: usize = 96;
const min_bar_width: usize = 40;
const max_bar_width: usize = 220;
const graph_mark = "─";
const thin_fill = "■";
const thin_empty = "■";
const color_empty = "\x1b[38;5;250m";
const max_status_len: usize = 256;
const mem_graph_max_cols: usize = 512;
const graph_row_buf_len: usize = mem_graph_max_cols * 4;
const mem_graph_pending_max: usize = 64;
const graph_right_scale_width: usize = 10;
const graph_right_gap: usize = 1;
const mem_history_window_ms: i64 = 5 * 60 * 1000;
const mem_history_max_points: usize = 2048;
const prompt_row: usize = 9;
const status_row: usize = 10;
const graph_title_row: usize = 12;
const graph_top_row: usize = 13;
const graph_height: usize = 10;
const graph_axis_row: usize = graph_top_row + graph_height;
const graph_label_row: usize = graph_axis_row + 1;
const tui_sample_interval_ms: u64 = 250;

const MemHistoryPoint = struct {
    ts_ms: i64,
    pct: u8,
};

const UiState = struct {
    input_buf: [256]u8 = undefined,
    input_len: usize = 0,
    status_buf: [max_status_len]u8 = undefined,
    status_len: usize = 0,
    should_quit: bool = false,
    reset_requested: bool = false,
    prompt_dirty: bool = true,
    mem_history_pid: ?u32 = null,
    mem_history: [mem_history_max_points]MemHistoryPoint = undefined,
    mem_history_len: usize = 0,
    mem_graph_pid: ?u32 = null,
    mem_graph_cols: [mem_graph_max_cols]u8 = undefined,
    mem_graph_len: usize = 0,
    mem_graph_pending: [mem_graph_pending_max]u8 = undefined,
    mem_graph_pending_len: usize = 0,
    mem_graph_last_pct: u8 = 0,
};

const Peaks = struct {
    mem_pct: u8 = 0,
    mem_used_bytes: u64 = 0,
    cpu_pct: u8 = 0,
    gc_pct: u8 = 0,
    io_pct: u8 = 0,
};

pub fn run(allocator: std.mem.Allocator, writer: anytype, opts: types.Options) !void {
    const stdout_file = std.fs.File.stdout();
    const is_tty = stdout_file.isTty();

    if (is_tty) {
        try writer.writeAll("\x1b[?1049h\x1b[?25l\x1b[2J\x1b[H");
    }
    defer {
        if (is_tty) {
            writer.writeAll("\x1b[0m\x1b[?25h\x1b[?1049l") catch {};
        }
    }

    var sample: u64 = 0;
    var last_render_ms: i64 = std.time.milliTimestamp() - @as(i64, @intCast(opts.interval_ms));
    var runtime = types.RuntimeState{};
    var peaks = Peaks{};
    var ui = UiState{};

    while (true) {
        sample += 1;
        const snapshot = sampler.collectSnapshot(allocator, opts.app_pattern, sample, &runtime);
        try pollAndHandleCommands(allocator, &ui, &runtime);
        if (ui.should_quit) break;
        if (ui.reset_requested) {
            peaks = .{};
            resetGcRuntime(&runtime);
            resetMemGraph(&ui);
            ui.reset_requested = false;
        }
        recordMemGraphSample(&ui, snapshot);
        updatePeaks(&peaks, snapshot);
        const now_ms = std.time.milliTimestamp();
        if (now_ms - last_render_ms >= @as(i64, @intCast(opts.interval_ms))) {
            advanceMemGraphFrame(&ui, snapshot);
            try renderVisualFrame(writer, snapshot, peaks, &ui, is_tty, terminalCols() orelse 0);
            if (ui.prompt_dirty) {
                try renderPromptArea(writer, ui, is_tty);
                ui.prompt_dirty = false;
            }
            last_render_ms = now_ms;
        }
        if (opts.once) break;
        std.Thread.sleep(tui_sample_interval_ms * std.time.ns_per_ms);
    }
}

fn renderVisualFrame(
    writer: anytype,
    snapshot: types.Snapshot,
    peaks: Peaks,
    ui: *const UiState,
    is_tty: bool,
    term_cols: usize,
) !void {
    if (is_tty) try writer.writeAll("\x1b7");
    try writer.writeAll("\x1b[H");
    const main_bar_width = computeMainBarWidth(term_cols);

    try clearLine(writer);
    if (is_tty) {
        try writer.writeAll("\x1b[1m");
    }
    try writer.writeAll("🧞 jmon");
    if (is_tty) {
        try writer.writeAll("\x1b[0m");
    }
    try writer.print("  state={s}", .{@tagName(snapshot.state)});
    try writer.writeAll("  pid=");
    if (snapshot.pid) |pid| {
        try writer.print("{d}", .{pid});
    } else {
        try writer.writeAll("-");
    }
    try writer.writeAll("  attached=");
    if (snapshot.attached_app) |app_name| {
        try writeQuoted(writer, app_name);
    } else {
        try writer.writeAll("-");
    }
    try writer.writeAll("\n\n");

    try clearLine(writer);
    try renderMemoryBar(writer, snapshot, peaks.mem_pct, peaks.mem_used_bytes, main_bar_width, term_cols, is_tty);

    try clearLine(writer);
    try renderGcSection(writer, snapshot, peaks.gc_pct, gcSectionBarWidth(main_bar_width), main_bar_width, is_tty);

    try clearLine(writer);
    try renderBar(writer, "CPU", snapshot.state == .ATTACHED, snapshot.cpu_total_pct, peaks.cpu_pct, main_bar_width, "\x1b[38;5;82m", snapshot.cpu_total_pct, peaks.cpu_pct, "pct", false, is_tty);

    const io_total = snapshot.io_disk_bps + snapshot.io_net_bps;
    try clearLine(writer);
    try renderBar(writer, "IO ", snapshot.state == .ATTACHED, ioToPct(io_total), peaks.io_pct, main_bar_width, "\x1b[38;5;141m", snapshot.io_disk_bps, snapshot.io_net_bps, "io", true, is_tty);

    try renderMemoryHistorySection(writer, ui, snapshot, term_cols, is_tty);
    if (is_tty) try writer.writeAll("\x1b8");
}

fn renderBar(
    writer: anytype,
    label: []const u8,
    attached: bool,
    pct: u8,
    peak: u8,
    width: usize,
    fill_color: []const u8,
    a: u64,
    b: u64,
    mode: []const u8,
    show_watermark: bool,
    is_tty: bool,
) !void {
    const trail_color = lighterColor(fill_color);
    const effective_pct: u8 = if (attached) pct else 0;
    const effective_peak: u8 = if (!attached)
        0
    else if (show_watermark)
        peak
    else
        pct;

    try writer.print("{s} ", .{label});
    try writeWatermarkBar(writer, width, effective_pct, effective_peak, fill_color, trail_color, is_tty);

    if (std.mem.eql(u8, mode, "bytes")) {
        try writer.print("  {d}%  ", .{pct});
        try writeHumanBytes(writer, a);
        try writer.writeAll(" / ");
        try writeHumanBytes(writer, b);
        try writer.writeAll("\n");
        return;
    }
    if (std.mem.eql(u8, mode, "pct")) {
        if (show_watermark) {
            try writer.print("  {d}%  peak={d}%\n", .{ pct, peak });
        } else {
            try writer.print("  {d}%\n", .{pct});
        }
        return;
    }
    try writer.writeAll("  disk=");
    try writeHumanBytes(writer, a);
    try writer.writeAll("/s net=");
    try writeHumanBytes(writer, b);
    try writer.writeAll("/s\n");
}

fn renderMemoryBar(
    writer: anytype,
    snapshot: types.Snapshot,
    peak: u8,
    peak_used_bytes: u64,
    width: usize,
    term_cols: usize,
    is_tty: bool,
) !void {
    const total = if (snapshot.mem_max_bytes > 0) snapshot.mem_max_bytes else snapshot.mem_committed_bytes;
    const pct = usagePct(snapshot.mem_used_bytes, total);
    const fill_color = "\x1b[38;5;45m";
    const trail_color = "\x1b[38;5;153m";
    const committed_color = "\x1b[38;5;195m";
    const footprint_color = "\x1b[38;5;27m";
    const effective_pct: u8 = if (snapshot.state == .ATTACHED) pct else 0;
    const effective_peak: u8 = if (snapshot.state == .ATTACHED) peak else 0;
    const committed_pct: u8 = if (snapshot.state == .ATTACHED)
        usagePct(snapshot.mem_committed_bytes, total)
    else
        0;
    const memory_line_capacity = computeMemoryBarLineCapacity(term_cols, width);
    const base_width = @min(width, memory_line_capacity);
    const extra_capacity = memory_line_capacity - base_width;
    const footprint_extension_cells = computeMemoryFootprintExtensionCells(
        snapshot,
        total,
        base_width,
        extra_capacity,
    );

    try writer.writeAll("MEM ");
    try writeMemoryLayeredBar(
        writer,
        base_width,
        effective_pct,
        effective_peak,
        committed_pct,
        fill_color,
        trail_color,
        committed_color,
        is_tty,
    );
    try writeFootprintExtensionBar(writer, footprint_extension_cells, footprint_color, is_tty);
    try writer.writeAll("\n");

    try writer.writeAll("    ");
    try writer.writeAll("used");
    try writeLegendSquare(writer, fill_color, is_tty);
    try writer.writeAll("=");
    try writeMb(writer, snapshot.mem_used_bytes);
    try writer.writeAll(" used peak");
    try writeLegendSquare(writer, trail_color, is_tty);
    try writer.writeAll("=");
    try writeMb(writer, if (snapshot.state == .ATTACHED) peak_used_bytes else 0);
    try writer.writeAll(" committed");
    try writeLegendSquare(writer, committed_color, is_tty);
    try writer.writeAll("=");
    try writeMb(writer, snapshot.mem_committed_bytes);
    try writer.writeAll(" max=");
    try writeMb(writer, total);
    try writer.writeAll(" phys");
    try writeLegendSquare(writer, footprint_color, is_tty);
    try writer.writeAll("=");
    try writeMb(writer, snapshot.mem_physical_footprint_bytes);
    try writer.writeAll("\n");
}

fn renderMemoryHistory(
    writer: anytype,
    ui: *const UiState,
    snapshot: types.Snapshot,
    width: usize,
    is_tty: bool,
) !void {
    const bar_color = "\x1b[38;5;39m";
    const spark_chars = [_][]const u8{ "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█" };
    try writer.writeAll("    ");

    if (ui.mem_history_len == 0 or snapshot.state != .ATTACHED) {
        if (is_tty) try writer.writeAll(color_empty);
        var i: usize = 0;
        while (i < width) : (i += 1) try writer.writeAll(thin_empty);
        if (is_tty) try writer.writeAll("\x1b[0m");
        try writer.writeAll("  mem 5m");
        try writer.writeAll("\n");
        return;
    }

    const now_ms = std.time.milliTimestamp();
    const window_start_ms = now_ms - mem_history_window_ms;
    const window_ms_u: u64 = @intCast(mem_history_window_ms);
    var idx: usize = 0;
    var have_value = false;
    var last_pct: u8 = 0;

    if (is_tty) try writer.writeAll(bar_color);
    var col: usize = 0;
    while (col < width) : (col += 1) {
        const bucket_end_ms = window_start_ms + @as(i64, @intCast(((col + 1) * window_ms_u) / width));
        while (idx < ui.mem_history_len and ui.mem_history[idx].ts_ms <= bucket_end_ms) : (idx += 1) {
            last_pct = ui.mem_history[idx].pct;
            have_value = true;
        }

        if (!have_value) {
            try writer.writeAll(thin_empty);
            continue;
        }

        const glyph_index = (@as(usize, last_pct) * (spark_chars.len - 1)) / 100;
        try writer.writeAll(spark_chars[glyph_index]);
    }
    if (is_tty) try writer.writeAll("\x1b[0m");
    try writer.writeAll("  mem 5m");
    try writer.writeAll("\n");
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
    const span = formatGraphSpanLabel(&span_tmp, visible_cols);
    var title_buf: [64]u8 = undefined;
    const title = std.fmt.bufPrint(&title_buf, "MEM history (last {s})", .{span}) catch "MEM history";
    try writer.print("\x1b[{d};1H", .{graph_title_row});
    try writeSectionTitleSeparator(writer, title, term_cols, is_tty);

    var rows: [graph_height][graph_row_buf_len]u8 = undefined;
    var row_lens: [graph_height]usize = [_]usize{0} ** graph_height;
    r = 0;
    while (r < graph_height) : (r += 1) {
        row_lens[r] = 0;
    }

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

fn writeLegendSquare(writer: anytype, color: []const u8, is_tty: bool) !void {
    if (is_tty) try writer.writeAll(color);
    try writer.writeAll("■");
    if (is_tty) try writer.writeAll("\x1b[0m");
}

fn writeSectionTitleSeparator(writer: anytype, title: []const u8, term_cols: usize, is_tty: bool) !void {
    try writer.writeAll(title);

    const total_cols = if (term_cols == 0) fallback_bar_width else term_cols;
    const used_cols = title.len;
    if (used_cols + 2 >= total_cols) return;

    try writer.writeAll(" ");
    if (is_tty) try writer.writeAll(color_empty);
    var i: usize = 0;
    const fill = total_cols - used_cols - 1;
    while (i < fill) : (i += 1) {
        try writer.writeAll("─");
    }
    if (is_tty) try writer.writeAll("\x1b[0m");
}

fn renderGcSection(
    writer: anytype,
    snapshot: types.Snapshot,
    peak_pressure_pct: u8,
    width: usize,
    global_bar_width: usize,
    is_tty: bool,
) !void {
    try writer.writeAll("GC  ");
    try writeGcPressureBar(writer, snapshot, peak_pressure_pct, width, is_tty);
    try writer.writeAll("  ");
    try writeGcSummary(writer, snapshot);
    const left_len = "GC  ".len + width + "  ".len + gcSummaryLen(snapshot);
    const fgc_anchor_end = "GC  ".len + global_bar_width; // align with end of MEM/CPU/IO bars
    const fgc_block_len = gcFgcBlockLen(snapshot, left_len, fgc_anchor_end);
    if (fgc_block_len > 0 and left_len + fgc_block_len <= fgc_anchor_end) {
        var pad = fgc_anchor_end - left_len - fgc_block_len;
        while (pad > 0) : (pad -= 1) try writer.writeAll(" ");
        try writeFullGcRight(writer, snapshot, left_len, fgc_anchor_end, is_tty);
    }
    try writer.writeAll("\n");
}

fn writeGcPressureBar(
    writer: anytype,
    snapshot: types.Snapshot,
    peak_pressure_pct: u8,
    width: usize,
    is_tty: bool,
) !void {
    const fill_color = "\x1b[38;5;208m";
    const trail_color = "\x1b[38;5;223m";
    const pct: u8 = if (snapshot.state == .ATTACHED) snapshot.gc_pressure_pct else 0;
    const peak: u8 = if (snapshot.state == .ATTACHED) peak_pressure_pct else 0;
    try writeWatermarkBar(writer, width, pct, peak, fill_color, trail_color, is_tty);
}

fn writeFullGcRight(
    writer: anytype,
    snapshot: types.Snapshot,
    left_len: usize,
    fgc_anchor_end: usize,
    is_tty: bool,
) !void {
    if (snapshot.state != .ATTACHED) return;
    const shown = gcFgcShownSquares(snapshot, left_len, fgc_anchor_end);
    var i: usize = 0;
    while (i < shown) : (i += 1) {
        if (i > 0) try writer.writeAll(" ");
        if (is_tty) try writer.writeAll("\x1b[38;5;203m");
        try writer.writeAll("■");
        if (is_tty) try writer.writeAll("\x1b[0m");
    }
    if (shown > 0) try writer.writeAll(" ");
    try writer.writeAll("fgc");
}

fn writeGcSummary(writer: anytype, snapshot: types.Snapshot) !void {
    if (snapshot.state != .ATTACHED) {
        try writer.writeAll("gc -: no jvm attached");
        return;
    }
    try writer.print("gc {d}.{d}% old {d}% p={d}%", .{
        snapshot.gc_short_time_pct_x10 / 10,
        snapshot.gc_short_time_pct_x10 % 10,
        snapshot.gc_old_occ_pct,
        snapshot.gc_pressure_pct,
    });
    if (snapshot.gc_short_rate_per_s_x10 > 0) {
        try writer.print(", {d}.{d}/s", .{
            snapshot.gc_short_rate_per_s_x10 / 10,
            snapshot.gc_short_rate_per_s_x10 % 10,
        });
    }
}

fn gcSummaryLen(snapshot: types.Snapshot) usize {
    if (snapshot.state != .ATTACHED) return "gc -: no jvm attached".len;

    var len: usize = 0;
    len += "gc ".len;
    len += decimalDigits(snapshot.gc_short_time_pct_x10 / 10);
    len += 1; // '.'
    len += 1; // tenths
    len += "% old ".len;
    len += decimalDigits(snapshot.gc_old_occ_pct);
    len += "% p=".len;
    len += decimalDigits(snapshot.gc_pressure_pct);
    len += 1; // '%'
    if (snapshot.gc_short_rate_per_s_x10 > 0) {
        len += ", ".len;
        len += decimalDigits(snapshot.gc_short_rate_per_s_x10 / 10);
        len += 1; // '.'
        len += 1; // tenths
        len += "/s".len;
    }
    return len;
}

fn gcFgcBlockLen(snapshot: types.Snapshot, left_len: usize, fgc_anchor_end: usize) usize {
    if (snapshot.state != .ATTACHED or left_len >= fgc_anchor_end) return 0;
    const shown = gcFgcShownSquares(snapshot, left_len, fgc_anchor_end);
    return if (shown > 0) (shown * 2) + 2 else 3; // "■ ■ ■ fgc" or "fgc"
}

fn gcFgcShownSquares(snapshot: types.Snapshot, left_len: usize, fgc_anchor_end: usize) usize {
    if (snapshot.state != .ATTACHED or left_len >= fgc_anchor_end) return 0;
    const avail = fgc_anchor_end - left_len;
    if (avail < 3) return 0;
    const max_squares = if (avail <= 3) 0 else (avail - 2) / 2;
    return @min(@as(usize, snapshot.gc_fgc_count), max_squares);
}

fn decimalDigits(value: anytype) usize {
    const T = @TypeOf(value);
    var v: u64 = switch (@typeInfo(T)) {
        .int => @as(u64, @intCast(value)),
        .comptime_int => @as(u64, @intCast(value)),
        else => 0,
    };
    var d: usize = 1;
    while (v >= 10) : (v /= 10) d += 1;
    return d;
}

fn updatePeaks(peaks: *Peaks, snapshot: types.Snapshot) void {
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
}

fn usagePct(value: u64, total: u64) u8 {
    if (total == 0) return 0;
    const raw = (@as(u128, value) * 100) / @as(u128, total);
    if (raw > 100) return 100;
    return @as(u8, @intCast(raw));
}

fn ioToPct(io_total_bps: u64) u8 {
    const full_scale: u64 = 100 * 1024 * 1024;
    return usagePct(io_total_bps, full_scale);
}

fn recordMemGraphSample(ui: *UiState, snapshot: types.Snapshot) void {
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
    const pct = usagePct(snapshot.mem_used_bytes, total);
    ui.mem_graph_last_pct = pct;
    appendPendingMemGraphSample(ui, pct);
}

fn advanceMemGraphFrame(ui: *UiState, snapshot: types.Snapshot) void {
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

fn appendMemGraphPoint(ui: *UiState, pct: u8) void {
    if (ui.mem_graph_len >= ui.mem_graph_cols.len) {
        std.mem.copyForwards(u8, ui.mem_graph_cols[0 .. ui.mem_graph_cols.len - 1], ui.mem_graph_cols[1..]);
        ui.mem_graph_len = ui.mem_graph_cols.len - 1;
    }
    ui.mem_graph_cols[ui.mem_graph_len] = pct;
    ui.mem_graph_len += 1;
}

fn resetMemGraph(ui: *UiState) void {
    ui.mem_graph_pid = null;
    ui.mem_graph_len = 0;
    ui.mem_graph_pending_len = 0;
    ui.mem_graph_last_pct = 0;
}

fn appendPendingMemGraphSample(ui: *UiState, pct: u8) void {
    if (ui.mem_graph_pending_len >= ui.mem_graph_pending.len) {
        std.mem.copyForwards(u8, ui.mem_graph_pending[0 .. ui.mem_graph_pending.len - 1], ui.mem_graph_pending[1..]);
        ui.mem_graph_pending_len = ui.mem_graph_pending.len - 1;
    }
    ui.mem_graph_pending[ui.mem_graph_pending_len] = pct;
    ui.mem_graph_pending_len += 1;
}

fn graphColorForRow(row: usize, height: usize, base_color: []const u8) []const u8 {
    if (row == 0 or row == height - 1) return "\x1b[2m";
    return base_color;
}

fn formatGraphSpanLabel(tmp: []u8, visible_cols: usize) []const u8 {
    if (visible_cols <= 1) return "0s";
    const span_ms = @as(u64, visible_cols - 1) * tui_sample_interval_ms;
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

fn buildGraphAxisLine(buf: []u8) void {
    @memset(buf, ' ');
    if (buf.len == 0) return;

    var i: usize = 0;
    while (i < buf.len) : (i += 1) {
        buf[i] = '-';
    }

    putAxisTick(buf, 0);
    if (buf.len > 1) {
        putAxisTick(buf, (buf.len - 1) / 4);
        putAxisTick(buf, (buf.len - 1) / 2);
        putAxisTick(buf, ((buf.len - 1) * 3) / 4);
        putAxisTick(buf, buf.len - 1);
    }
}

fn putAxisTick(buf: []u8, idx: usize) void {
    if (idx >= buf.len) return;
    buf[idx] = '|';
}

fn buildGraphTimeLabels(buf: []u8, plot_width: usize) void {
    @memset(buf, ' ');
    if (plot_width == 0) return;

    var tmp_left: [16]u8 = undefined;
    var tmp_mid: [16]u8 = undefined;
    const left = formatAgeLabel(&tmp_left, graphAgeMsForColumn(plot_width, 0));
    const mid_col = if (plot_width > 0) (plot_width - 1) / 2 else 0;
    const mid = formatAgeLabel(&tmp_mid, graphAgeMsForColumn(plot_width, mid_col));
    putLabelAt(buf, 0, left, .left);
    putLabelAt(buf, mid_col, mid, .center);
    putLabelAt(buf, plot_width - 1, "now", .right);
}

const LabelAlign = enum {
    left,
    center,
    right,
};

fn putLabelAt(buf: []u8, anchor_col: usize, label: []const u8, label_align: LabelAlign) void {
    if (buf.len == 0 or label.len == 0) return;

    const start: usize = switch (label_align) {
        .left => anchor_col,
        .center => if (anchor_col >= label.len / 2) anchor_col - (label.len / 2) else 0,
        .right => if (anchor_col + 1 >= label.len) (anchor_col + 1) - label.len else 0,
    };
    if (start >= buf.len) return;
    const n = @min(label.len, buf.len - start);
    std.mem.copyForwards(u8, buf[start .. start + n], label[0..n]);
}

fn graphAgeMsForColumn(plot_width: usize, col: usize) u64 {
    if (plot_width == 0) return 0;
    const clamped_col = @min(col, plot_width - 1);
    const cols_ago = (plot_width - 1) - clamped_col;
    return @as(u64, cols_ago) * tui_sample_interval_ms;
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

fn writeWatermarkBar(
    writer: anytype,
    width: usize,
    pct: u8,
    peak: u8,
    fill_color: []const u8,
    trail_color: []const u8,
    is_tty: bool,
) !void {
    const filled = (@as(usize, pct) * width) / 100;
    const peak_cells_raw = (@as(usize, peak) * width) / 100;
    const peak_cells = @max(filled, @min(peak_cells_raw, width));

    var i: usize = 0;
    while (i < width) : (i += 1) {
        if (is_tty) {
            if (i < filled) {
                try writer.writeAll(fill_color);
            } else if (i < peak_cells) {
                try writer.writeAll(trail_color);
            } else {
                try writer.writeAll(color_empty);
            }
        }
        try writer.writeAll(if (i < peak_cells) thin_fill else thin_empty);
    }
    if (is_tty) try writer.writeAll("\x1b[0m");
}

fn writeMemoryLayeredBar(
    writer: anytype,
    width: usize,
    used_pct: u8,
    peak_pct: u8,
    committed_pct: u8,
    used_color: []const u8,
    peak_color: []const u8,
    committed_color: []const u8,
    is_tty: bool,
) !void {
    const used_cells = (@as(usize, used_pct) * width) / 100;
    const peak_cells_raw = (@as(usize, peak_pct) * width) / 100;
    const peak_cells = @max(used_cells, @min(peak_cells_raw, width));
    const committed_cells_raw = (@as(usize, committed_pct) * width) / 100;
    const committed_cells = @min(committed_cells_raw, width);
    const committed_start = @max(used_cells, peak_cells);

    var i: usize = 0;
    while (i < width) : (i += 1) {
        if (is_tty) {
            if (i < used_cells) {
                try writer.writeAll(used_color);
            } else if (i < peak_cells) {
                try writer.writeAll(peak_color);
            } else if (i >= committed_start and i < committed_cells) {
                try writer.writeAll(committed_color);
            } else {
                try writer.writeAll(color_empty);
            }
        }
        if (i < used_cells or i < peak_cells or (i >= committed_start and i < committed_cells)) {
            try writer.writeAll(thin_fill);
        } else {
            try writer.writeAll(thin_empty);
        }
    }
    if (is_tty) try writer.writeAll("\x1b[0m");
}

fn lighterColor(fill_color: []const u8) []const u8 {
    if (std.mem.eql(u8, fill_color, "\x1b[38;5;82m")) return "\x1b[38;5;157m";
    if (std.mem.eql(u8, fill_color, "\x1b[38;5;141m")) return "\x1b[38;5;183m";
    if (std.mem.eql(u8, fill_color, "\x1b[38;5;45m")) return "\x1b[38;5;159m";
    return fill_color;
}

fn computeMainBarWidth(term_cols: usize) usize {
    if (term_cols == 0) return (fallback_bar_width * 3) / 4;
    const reserve: usize = 40;
    const raw = if (term_cols <= reserve + min_bar_width)
        min_bar_width
    else
        std.math.clamp(term_cols - reserve, min_bar_width, max_bar_width);
    const scaled = @max(min_bar_width, (raw * 3) / 4);
    return std.math.clamp(scaled, min_bar_width, max_bar_width);
}

fn computeMemoryBarLineCapacity(term_cols: usize, fallback_width: usize) usize {
    if (term_cols == 0) return fallback_width;
    if (term_cols <= 4) return @min(fallback_width, @as(usize, 1));
    return @max(@as(usize, 1), term_cols - 4);
}

fn computeMemoryFootprintExtensionCells(
    snapshot: types.Snapshot,
    total_bytes: u64,
    base_width: usize,
    extra_capacity: usize,
) usize {
    if (snapshot.state != .ATTACHED) return 0;
    if (total_bytes == 0 or base_width == 0 or extra_capacity == 0) return 0;
    const footprint = snapshot.mem_physical_footprint_bytes;
    if (footprint <= total_bytes) return 0;

    const over = footprint - total_bytes;
    const raw = (@as(u128, over) * @as(u128, base_width)) / @as(u128, total_bytes);
    if (raw == 0) return 1;
    const cells = if (raw > std.math.maxInt(usize)) std.math.maxInt(usize) else @as(usize, @intCast(raw));
    return @min(cells, extra_capacity);
}

fn writeFootprintExtensionBar(
    writer: anytype,
    cells: usize,
    color: []const u8,
    is_tty: bool,
) !void {
    if (cells == 0) return;
    var i: usize = 0;
    while (i < cells) : (i += 1) {
        if (is_tty) try writer.writeAll(color);
        try writer.writeAll(thin_fill);
    }
    if (is_tty) try writer.writeAll("\x1b[0m");
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

fn gcSectionBarWidth(main_bar_width: usize) usize {
    const raw = main_bar_width / 4;
    return @max(@as(usize, 6), raw);
}

fn renderPromptArea(writer: anytype, ui: UiState, is_tty: bool) !void {
    try writer.print("\x1b[{d};1H", .{prompt_row});
    try clearLine(writer);
    if (is_tty) try writer.writeAll("\x1b[2m");
    try writer.writeAll(": ");
    try writer.writeAll("gc | reset | q");
    if (is_tty) try writer.writeAll("\x1b[0m");

    try writer.print("\x1b[{d};1H", .{status_row});
    try clearLine(writer);
    if (ui.status_len > 0) {
        if (is_tty) try writer.writeAll("\x1b[2m");
        try writer.writeAll(ui.status_buf[0..ui.status_len]);
        if (is_tty) try writer.writeAll("\x1b[0m");
    }

    try writer.print("\x1b[{d};3H", .{prompt_row});
}

fn clearLine(writer: anytype) !void {
    try writer.writeAll("\x1b[2K");
}

fn pollAndHandleCommands(
    allocator: std.mem.Allocator,
    ui: *UiState,
    runtime: *types.RuntimeState,
) !void {
    const posix = std.posix;
    var fds = [_]posix.pollfd{.{
        .fd = posix.STDIN_FILENO,
        .events = posix.POLL.IN,
        .revents = 0,
    }};

    const ready = posix.poll(fds[0..], 0) catch return;
    if (ready == 0) return;
    if ((fds[0].revents & posix.POLL.IN) == 0) return;

    var buf: [256]u8 = undefined;
    const n = posix.read(posix.STDIN_FILENO, &buf) catch |err| switch (err) {
        error.WouldBlock => return,
        else => return,
    };
    if (n == 0) return;

    for (buf[0..n]) |c| {
        switch (c) {
            '\r', '\n' => {
                try handleCommandLine(allocator, ui, runtime);
                ui.input_len = 0;
                ui.prompt_dirty = true;
            },
            0x7f, 0x08 => {
                if (ui.input_len > 0) ui.input_len -= 1;
            },
            else => {
                if (c < 0x20) continue;
                if (ui.input_len < ui.input_buf.len) {
                    ui.input_buf[ui.input_len] = c;
                    ui.input_len += 1;
                }
            },
        }
    }
}

fn handleCommandLine(
    allocator: std.mem.Allocator,
    ui: *UiState,
    runtime: *types.RuntimeState,
) !void {
    const line = std.mem.trim(u8, ui.input_buf[0..ui.input_len], " \t");
    if (line.len == 0) return;

    if (std.ascii.eqlIgnoreCase(line, "q") or std.ascii.eqlIgnoreCase(line, "quit")) {
        ui.should_quit = true;
        setStatus(ui, "quit requested");
        return;
    }

    if (std.ascii.eqlIgnoreCase(line, "gc")) {
        const pid = runtime.attached_pid orelse {
            setStatus(ui, "gc failed: no attached jvm");
            return;
        };
        const ok = runFullGc(allocator, pid);
        if (ok) {
            var msg: [max_status_len]u8 = undefined;
            const s = std.fmt.bufPrint(&msg, "gc requested on pid {d}", .{pid}) catch "gc requested";
            setStatusSlice(ui, s);
        } else {
            var msg: [max_status_len]u8 = undefined;
            const s = std.fmt.bufPrint(&msg, "gc failed on pid {d}", .{pid}) catch "gc failed";
            setStatusSlice(ui, s);
        }
        return;
    }

    if (std.ascii.eqlIgnoreCase(line, "reset")) {
        ui.reset_requested = true;
        setStatus(ui, "peaks and gc counters reset");
        return;
    }

    setStatus(ui, "unknown command (try: gc, reset)");
}

fn runFullGc(allocator: std.mem.Allocator, pid: u32) bool {
    var pid_buf: [20]u8 = undefined;
    const pid_str = std.fmt.bufPrint(&pid_buf, "{d}", .{pid}) catch return false;
    const argv = [_][]const u8{ "jcmd", pid_str, "GC.run" };
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv[0..],
        .max_output_bytes = 32 * 1024,
    }) catch return false;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    return switch (result.term) {
        .Exited => |code| code == 0,
        else => false,
    };
}

fn resetGcRuntime(runtime: *types.RuntimeState) void {
    runtime.gc_points_len = 0;
    runtime.gc_time_red_windows = 0;
    runtime.last_full_gc_seen_ts_ms = -1;
    runtime.gc_pressure_ewma = 0;
    runtime.gc_fgc_baseline = null;
}

fn setStatus(ui: *UiState, text: []const u8) void {
    setStatusSlice(ui, text);
}

fn setStatusSlice(ui: *UiState, text: []const u8) void {
    const n = @min(text.len, ui.status_buf.len);
    if (n > 0) std.mem.copyForwards(u8, ui.status_buf[0..n], text[0..n]);
    ui.status_len = n;
    ui.prompt_dirty = true;
}

fn terminalCols() ?usize {
    const posix = std.posix;
    var wsz: posix.winsize = .{
        .row = 0,
        .col = 0,
        .xpixel = 0,
        .ypixel = 0,
    };

    const rc = posix.system.ioctl(posix.STDOUT_FILENO, posix.T.IOCGWINSZ, @intFromPtr(&wsz));
    if (posix.errno(rc) != .SUCCESS or wsz.col == 0) return null;
    return @as(usize, wsz.col);
}

fn writeHumanBytes(writer: anytype, bytes: u64) !void {
    const units = [_][]const u8{ "B", "KB", "MB", "GB", "TB" };
    var value = @as(f64, @floatFromInt(bytes));
    var idx: usize = 0;
    while (value >= 1024.0 and idx + 1 < units.len) : (idx += 1) value /= 1024.0;
    try writer.print("{d:.1}{s}", .{ value, units[idx] });
}

fn writeMb(writer: anytype, bytes: u64) !void {
    const mb = (@as(u128, bytes) + (1024 * 1024 / 2)) / (1024 * 1024);
    try writer.print("{d}MB", .{mb});
}

fn writeQuoted(writer: anytype, value: []const u8) !void {
    try writer.writeAll("\"");
    try writer.writeAll(value);
    try writer.writeAll("\"");
}
