// Compact CPU section renderer.
// Renders the JVM CPU bar plus host per-core mini-bars for quick contention visibility.

const std = @import("std");
const types = @import("../types.zig");
const tui_state = @import("../tui/state.zig");
const bars = @import("bars.zig");

const thin_fill = tui_state.thin_fill;
const thin_empty = tui_state.thin_empty;
const color_empty = tui_state.color_empty;
const reserved_core_rows: usize = 2;
const min_core_bar_width: usize = 3;
const core_scope_prefix = "(h) ";
const core_fill = "▬";
const core_empty = "▬";
// btop built-in default CPU gradient from src/btop_theme.cpp.
const btop_cpu_start = [3]u8{ 0x77, 0xCA, 0x9B };
const btop_cpu_mid = [3]u8{ 0xCB, 0xC0, 0x6C };
const btop_cpu_end = [3]u8{ 0xDC, 0x4C, 0x4C };

pub fn renderCpuSection(writer: anytype, snapshot: types.Snapshot, width: usize, is_tty: bool) !void {
    const fill_pct = if (snapshot.state == .ATTACHED) snapshot.cpu_total_pct else 0;
    try writer.writeAll("CPU ");
    try bars.writeGradientBar(writer, width, fill_pct, is_tty, btop_cpu_start, btop_cpu_mid, btop_cpu_end);
    if (snapshot.state == .ATTACHED) {
        const raw_whole = snapshot.cpu_process_pct_x10 / 10;
        const raw_tenth = snapshot.cpu_process_pct_x10 % 10;
        const cores_x10 = @as(u16, @intCast((@as(u32, snapshot.cpu_process_pct_x10) + 50) / 100));
        const cores_whole = cores_x10 / 10;
        const cores_tenth = cores_x10 % 10;
        try writer.print("  {d}.{d}% (~{d}.{d}c)\n", .{ raw_whole, raw_tenth, cores_whole, cores_tenth });
    } else {
        try writer.writeAll("  0.0% (~0.0c)\n");
    }

    try renderCoreBars(writer, snapshot, width, is_tty);
}

fn renderCoreBars(writer: anytype, snapshot: types.Snapshot, width: usize, is_tty: bool) !void {
    const host_core_count = if (snapshot.state == .ATTACHED)
        @as(usize, snapshot.cpu_host_core_count)
    else
        0;

    const rows_used: usize = computeRowsUsed(width, host_core_count);

    const rows_to_emit = if (is_tty) reserved_core_rows else rows_used;
    const scope_prefix_len: usize = if (host_core_count > 0) core_scope_prefix.len else 0;
    const content_width = if (width > scope_prefix_len) width - scope_prefix_len else width;
    var row: usize = 0;
    while (row < rows_to_emit) : (row += 1) {
        if (is_tty) try writer.writeAll("\x1b[2K");
        try writer.writeAll("    ");

        if (row >= rows_used or host_core_count == 0) {
            try writer.writeAll("\n");
            continue;
        }

        const row_core_count = coresInBalancedRow(host_core_count, rows_used, row);
        const start = rowStartIndex(host_core_count, rows_used, row);
        const layout = computeRowLayout(content_width, start, row_core_count);
        var written_cells: usize = 0;

        if (scope_prefix_len > 0) {
            if (row == 0) {
                if (is_tty) try writer.writeAll("\x1b[2m");
                try writer.writeAll(core_scope_prefix);
                if (is_tty) try writer.writeAll("\x1b[0m");
            } else {
                var s: usize = 0;
                while (s < scope_prefix_len) : (s += 1) try writer.writeAll(" ");
            }
            written_cells += scope_prefix_len;
        }

        var i: usize = 0;
        while (i < row_core_count) : (i += 1) {
            if (i > 0) {
                try writer.writeAll(" ");
                written_cells += 1;
            }
            try writeCoreLabel(writer, start + i + 1, is_tty);
            written_cells += coreLabelLen(start + i + 1);
            const core_pct = snapshot.cpu_host_core_pcts[start + i];
            const bar_width = layout.bar_width_base + @as(usize, @intFromBool(i < layout.bar_width_extra));
            try writeCoreMiniBar(writer, bar_width, core_pct, is_tty);
            written_cells += bar_width;
        }

        while (written_cells < width) : (written_cells += 1) {
            try writer.writeAll(" ");
        }
        try writer.writeAll("\n");
    }
}

fn computeRowsUsed(width: usize, host_core_count: usize) usize {
    if (host_core_count == 0) return 0;
    var rows: usize = 1;
    while (rows <= reserved_core_rows) : (rows += 1) {
        if (coreRowsFit(width, host_core_count, rows)) return rows;
    }
    return reserved_core_rows;
}

fn coreRowsFit(width: usize, host_core_count: usize, rows: usize) bool {
    var row: usize = 0;
    var start: usize = 0;
    while (row < rows) : (row += 1) {
        const row_core_count = coresInBalancedRow(host_core_count, rows, row);
        if (row_core_count == 0) continue;
        var labels_total: usize = 0;
        var i: usize = 0;
        while (i < row_core_count) : (i += 1) {
            labels_total += coreLabelLen(start + i + 1);
        }
        const separators = row_core_count - 1;
        const min_total = labels_total + separators + (row_core_count * min_core_bar_width);
        if (min_total > width) return false;
        start += row_core_count;
    }
    return true;
}

const RowLayout = struct {
    bar_width_base: usize,
    bar_width_extra: usize,
};

fn computeRowLayout(width: usize, start_index: usize, row_core_count: usize) RowLayout {
    if (row_core_count == 0) return .{ .bar_width_base = 0, .bar_width_extra = 0 };
    var labels_total: usize = 0;
    var i: usize = 0;
    while (i < row_core_count) : (i += 1) {
        labels_total += coreLabelLen(start_index + i + 1);
    }
    const separators = row_core_count - 1;
    const reserved = labels_total + separators;
    const available = if (width > reserved) width - reserved else row_core_count;
    return .{
        .bar_width_base = @max(@as(usize, 1), available / row_core_count),
        .bar_width_extra = available % row_core_count,
    };
}

fn coresInBalancedRow(total: usize, rows: usize, row: usize) usize {
    if (rows == 0) return 0;
    const base = total / rows;
    const extra = total % rows;
    return base + @intFromBool(row < extra);
}

fn rowStartIndex(total: usize, rows: usize, row: usize) usize {
    var start: usize = 0;
    var r: usize = 0;
    while (r < row) : (r += 1) {
        start += coresInBalancedRow(total, rows, r);
    }
    return start;
}

fn writeCoreMiniBar(writer: anytype, width: usize, pct: u8, is_tty: bool) !void {
    if (width == 0) return;
    try bars.writeGradientBarWithGlyphs(
        writer,
        width,
        pct,
        is_tty,
        btop_cpu_start,
        btop_cpu_mid,
        btop_cpu_end,
        core_fill,
        core_empty,
    );
}

fn coreLabelLen(core_index_1based: usize) usize {
    return 1 + decimalDigits(core_index_1based);
}

fn writeCoreLabel(writer: anytype, core_index_1based: usize, is_tty: bool) !void {
    if (is_tty) try writer.writeAll("\x1b[2m");
    try writer.print("c{d}", .{core_index_1based});
    if (is_tty) try writer.writeAll("\x1b[0m");
}

fn decimalDigits(value: usize) usize {
    var v = value;
    var d: usize = 1;
    while (v >= 10) : (v /= 10) d += 1;
    return d;
}
