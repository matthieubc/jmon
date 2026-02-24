// Compact CPU section renderer.
// Renders the JVM CPU bar plus host per-core mini-bars for quick contention visibility.

const std = @import("std");
const types = @import("../types.zig");
const tui_state = @import("../tui/state.zig");
const bars = @import("bars.zig");
const fmtu = @import("format.zig");

const thin_fill = tui_state.thin_fill;
const thin_empty = tui_state.thin_empty;
const color_empty = tui_state.color_empty;
const reserved_core_rows: usize = 2;
const min_core_bar_width: usize = 3;
const core_scope_suffix = " (h)";
const core_fill = "▬";
const core_empty = "▬";
// btop built-in default CPU gradient from src/btop_theme.cpp.
const btop_cpu_start = [3]u8{ 0x77, 0xCA, 0x9B };
const btop_cpu_mid = [3]u8{ 0xCB, 0xC0, 0x6C };
const btop_cpu_end = [3]u8{ 0xDC, 0x4C, 0x4C };

pub fn renderCpuSection(writer: anytype, snapshot: types.Snapshot, width: usize, is_tty: bool) !void {
    const fill_pct = if (snapshot.state == .ATTACHED) snapshot.cpu_total_pct else 0;
    var pct_buf: [16]u8 = undefined;
    const pct_text = formatCpuPctField(&pct_buf, snapshot);
    try fmtu.writeBold(writer, "CPU ", is_tty);
    try writeCpuPctField(writer, pct_text, width, snapshot.state == .ATTACHED, is_tty);
    try bars.writeGradientBar(writer, width, fill_pct, is_tty, btop_cpu_start, btop_cpu_mid, btop_cpu_end);
    try writer.writeAll("\n");

    try renderCoreBars(writer, snapshot, width, is_tty);
}

fn renderCoreBars(writer: anytype, snapshot: types.Snapshot, width: usize, is_tty: bool) !void {
    const host_core_count = if (snapshot.state == .ATTACHED)
        @as(usize, snapshot.cpu_host_core_count)
    else
        0;

    const rows_used: usize = computeRowsUsed(width, host_core_count);

    const rows_to_emit = if (is_tty) reserved_core_rows else rows_used;
    var row: usize = 0;
    while (row < rows_to_emit) : (row += 1) {
        if (is_tty) try writer.writeAll("\x1b[2K");
        try writer.writeAll("    ");
        try writeCpuCoreSideField(writer, snapshot, row, is_tty);

        if (row >= rows_used or host_core_count == 0) {
            try writer.writeAll("\n");
            continue;
        }

        const row_core_count = coresInBalancedRow(host_core_count, rows_used, row);
        const start = rowStartIndex(host_core_count, rows_used, row);
        const scope_suffix_len = coreScopeSuffixLen(host_core_count, row);
        const content_width = if (width > scope_suffix_len) width - scope_suffix_len else width;
        const layout = computeRowLayout(content_width, start, row_core_count);
        var written_cells: usize = 0;

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

        while (written_cells < content_width) : (written_cells += 1) {
            try writer.writeAll(" ");
        }
        try writeCoreScopeSuffix(writer, host_core_count, row, is_tty);
        written_cells += scope_suffix_len;
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
        const suffix_len = coreScopeSuffixLen(host_core_count, row);
        const row_width = if (width > suffix_len) width - suffix_len else 0;
        const min_total = labels_total + separators + (row_core_count * min_core_bar_width);
        if (min_total > row_width) return false;
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

fn coreScopeSuffixLen(host_core_count: usize, row: usize) usize {
    if (host_core_count == 0 or row != 0) return 0;
    return core_scope_suffix.len;
}

fn writeCoreScopeSuffix(writer: anytype, host_core_count: usize, row: usize, is_tty: bool) !void {
    if (coreScopeSuffixLen(host_core_count, row) == 0) return;
    if (is_tty) try writer.writeAll("\x1b[2m");
    try writer.writeAll(core_scope_suffix);
    if (is_tty) try writer.writeAll("\x1b[0m");
}

fn formatCpuPctField(buf: []u8, snapshot: types.Snapshot) []const u8 {
    if (snapshot.state != .ATTACHED) return "0.0%";
    return std.fmt.bufPrint(buf, "{d}.{d}%", .{
        snapshot.cpu_process_pct_x10 / 10,
        snapshot.cpu_process_pct_x10 % 10,
    }) catch "0.0%";
}

fn writeCpuPctField(
    writer: anytype,
    text: []const u8,
    bar_width: usize,
    attached: bool,
    is_tty: bool,
) !void {
    const field_width = fmtu.bar_side_field_width;
    if (!is_tty) {
        try writer.print("{s: <" ++ std.fmt.comptimePrint("{}", .{field_width}) ++ "}", .{text});
        return;
    }

    _ = bar_width;
    if (attached) {
        try writer.writeAll(fmtu.prebar_cpu_color);
        try writer.writeAll(text);
        try writer.writeAll("\x1b[0m");
    } else {
        try writer.writeAll(color_empty);
        try writer.writeAll(text);
        try writer.writeAll("\x1b[0m");
    }
    if (text.len < field_width) {
        var pad = field_width - text.len;
        while (pad > 0) : (pad -= 1) try writer.writeAll(" ");
    }
}

fn writeCpuCoreSideField(writer: anytype, snapshot: types.Snapshot, row: usize, is_tty: bool) !void {
    if (row != 0) {
        var i: usize = 0;
        while (i < fmtu.bar_side_field_width) : (i += 1) try writer.writeAll(" ");
        return;
    }

    var buf: [16]u8 = undefined;
    const text = if (snapshot.state == .ATTACHED) blk: {
        const cores_x10 = @as(u16, @intCast((@as(u32, snapshot.cpu_process_pct_x10) + 50) / 100));
        break :blk (std.fmt.bufPrint(&buf, "~{d}.{d}c", .{ cores_x10 / 10, cores_x10 % 10 }) catch "~0.0c");
    } else "~0.0c";

    if (is_tty) {
        try writer.writeAll(if (snapshot.state == .ATTACHED) fmtu.prebar_cpu_color else color_empty);
        try writer.print("{s: <" ++ std.fmt.comptimePrint("{}", .{fmtu.bar_side_field_width}) ++ "}", .{text});
        try writer.writeAll("\x1b[0m");
    } else {
        try writer.print("{s: <" ++ std.fmt.comptimePrint("{}", .{fmtu.bar_side_field_width}) ++ "}", .{text});
    }
}
