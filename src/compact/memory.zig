// Compact memory section renderer.
// Draws the layered heap bar, physical extension, and memory summary labels.

const std = @import("std");
const types = @import("../types.zig");
const tui_state = @import("../tui/state.zig");
const bars = @import("bars.zig");
const fmtu = @import("format.zig");
const metrics = @import("metrics.zig");

pub fn renderMemoryBar(
    writer: anytype,
    snapshot: types.Snapshot,
    peak_pct: u8,
    peak_used_bytes: u64,
    width: usize,
    term_cols: usize,
    is_tty: bool,
) !void {
    const total = if (snapshot.mem_max_bytes > 0) snapshot.mem_max_bytes else snapshot.mem_committed_bytes;
    const pct = metrics.usagePct(snapshot.mem_used_bytes, total);
    const fill_color = "\x1b[38;5;51m";
    const trail_color = "\x1b[38;5;195m";
    const committed_color = "\x1b[38;5;231m";
    const footprint_color = "\x1b[38;5;20m";
    const effective_pct: u8 = if (snapshot.state == .ATTACHED) pct else 0;
    const effective_peak: u8 = if (snapshot.state == .ATTACHED) peak_pct else 0;
    const committed_pct: u8 = if (snapshot.state == .ATTACHED)
        metrics.usagePct(snapshot.mem_committed_bytes, total)
    else
        0;
    const memory_line_capacity = computeMemoryBarLineCapacity(term_cols, width);
    const base_width = @min(width, memory_line_capacity);
    const extra_capacity = memory_line_capacity - base_width;
    const footprint_extension_cells = computeMemoryFootprintExtensionCells(snapshot, total, base_width, extra_capacity);

    try writer.writeAll("MEM ");
    try bars.writeMemoryLayeredBar(writer, base_width, effective_pct, effective_peak, committed_pct, fill_color, trail_color, committed_color, is_tty);
    try writeFootprintExtensionBar(writer, footprint_extension_cells, footprint_color, is_tty);
    try writer.writeAll("\n");

    if (is_tty) try writer.writeAll("\x1b[2K");
    try writer.writeAll("    ");
    var left_visible_cols: usize = 0;
    try writer.writeAll("heap: used");
    left_visible_cols += "heap: used".len;
    try writeLegendSquare(writer, fill_color, is_tty);
    left_visible_cols += 1;
    try writer.writeAll("=");
    left_visible_cols += 1;
    try fmtu.writeMb(writer, snapshot.mem_used_bytes);
    left_visible_cols += fmtu.mbVisibleLen(snapshot.mem_used_bytes);
    try writer.writeAll(" peak");
    left_visible_cols += " peak".len;
    try writeLegendSquare(writer, trail_color, is_tty);
    left_visible_cols += 1;
    try writer.writeAll("=");
    left_visible_cols += 1;
    try fmtu.writeMb(writer, if (snapshot.state == .ATTACHED) peak_used_bytes else 0);
    left_visible_cols += fmtu.mbVisibleLen(if (snapshot.state == .ATTACHED) peak_used_bytes else 0);
    try writer.writeAll(" committed");
    left_visible_cols += " committed".len;
    try writeLegendSquare(writer, committed_color, is_tty);
    left_visible_cols += 1;
    try writer.writeAll("=");
    left_visible_cols += 1;
    try fmtu.writeMb(writer, snapshot.mem_committed_bytes);
    left_visible_cols += fmtu.mbVisibleLen(snapshot.mem_committed_bytes);

    const max_anchor_col = base_width;
    const max_label_visible_len = "max=".len + fmtu.mbVisibleLen(total);
    if (left_visible_cols + max_label_visible_len < max_anchor_col) {
        var pad = max_anchor_col - (left_visible_cols + max_label_visible_len);
        while (pad > 0) : (pad -= 1) try writer.writeAll(" ");
    } else {
        try writer.writeAll("  ");
    }
    try writer.writeAll("max=");
    try fmtu.writeMb(writer, total);
    try writer.writeAll(" phys");
    try writeLegendSquare(writer, footprint_color, is_tty);
    try writer.writeAll("=");
    try fmtu.writeMb(writer, snapshot.mem_physical_footprint_bytes);
    try writer.writeAll("\n");
}

fn writeLegendSquare(writer: anytype, color: []const u8, is_tty: bool) !void {
    if (is_tty) try writer.writeAll(color);
    try writer.writeAll("■");
    if (is_tty) try writer.writeAll("\x1b[0m");
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
        try writer.writeAll(tui_state.thin_fill);
    }
    if (is_tty) try writer.writeAll("\x1b[0m");
}
