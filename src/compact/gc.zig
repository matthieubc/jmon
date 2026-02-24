// Compact GC section renderer.
// Draws GC pressure, GC counters, and short GC summary text for the top panel.
// `pr.=x%` is a normalized GC pressure score from the sampler, not raw GC time.
// The score is computed in `src/sampler/gc_metrics.zig` from short-window GC time ratio
// and old-gen occupancy, then smoothed with an EWMA before display.

const types = @import("../types.zig");
const tui_state = @import("../tui/state.zig");
const bars = @import("bars.zig");
const fmtu = @import("format.zig");
const std = @import("std");

const color_empty = tui_state.color_empty;
const gc_fill = "▬";
const gc_empty = "▬";
const gc_count_fill = "━";
const gc_count_empty = "━";
const pressure_fill_start = [3]u8{ 0xFF, 0xC4, 0x7A }; // light orange
const pressure_fill_mid = [3]u8{ 0xFF, 0x8A, 0x3D }; // orange
const pressure_fill_end = [3]u8{ 0xE5, 0x39, 0x35 }; // bright red
const pressure_trail_start = [3]u8{ 0xFF, 0xE2, 0xBD };
const pressure_trail_mid = [3]u8{ 0xFF, 0xC9, 0xA3 };
const pressure_trail_end = [3]u8{ 0xFF, 0xB3, 0xB0 };

pub fn renderGcSection(
    writer: anytype,
    snapshot: types.Snapshot,
    peak_pressure_pct: u8,
    global_bar_width: usize,
    is_tty: bool,
) !void {
    const left_half = @max(@as(usize, 1), global_bar_width / 2);
    const right_half = global_bar_width - left_half;
    const pressure_pct = if (snapshot.state == .ATTACHED) snapshot.gc_pressure_pct else 0;

    try fmtu.writeBold(writer, "GC  ", is_tty);
    try writePressureField(writer, pressure_pct, left_half, is_tty);
    try writeGcPressureBar(writer, snapshot, peak_pressure_pct, left_half, is_tty);
    try writeGcCountsArea(writer, snapshot, right_half, is_tty);
    try writer.writeAll("\n");

    if (is_tty) try writer.writeAll("\x1b[2K");
    try writer.writeAll("    ");
    var pad: usize = 0;
    while (pad < fmtu.bar_side_field_width) : (pad += 1) try writer.writeAll(" ");
    try writeGcSummary(writer, snapshot);
    try writer.writeAll("\n");
}

fn writeGcPressureBar(
    writer: anytype,
    snapshot: types.Snapshot,
    peak_pressure_pct: u8,
    width: usize,
    is_tty: bool,
) !void {
    // The bar visualizes the normalized GC pressure score.
    // Fill = current pressure, watermark = peak pressure since attach/reset.
    const pct: u8 = if (snapshot.state == .ATTACHED) snapshot.gc_pressure_pct else 0;
    const peak: u8 = if (snapshot.state == .ATTACHED) peak_pressure_pct else 0;
    try bars.writeGradientWatermarkBarWithGlyphs(
        writer,
        width,
        pct,
        peak,
        is_tty,
        pressure_fill_start,
        pressure_fill_mid,
        pressure_fill_end,
        pressure_trail_start,
        pressure_trail_mid,
        pressure_trail_end,
        gc_fill,
        gc_empty,
    );
}

fn writePressureField(
    writer: anytype,
    pressure_pct: u8,
    pressure_bar_width: usize,
    is_tty: bool,
) !void {
    _ = pressure_bar_width;
    var buf: [32]u8 = undefined;
    const label = std.fmt.bufPrint(&buf, "pr.={d}%", .{pressure_pct}) catch "pr.=?%";
    const field_width = fmtu.bar_side_field_width;
    if (!is_tty) {
        try writer.print("{s: <" ++ std.fmt.comptimePrint("{}", .{field_width}) ++ "}", .{label});
        return;
    }

    try writer.writeAll(fmtu.prebar_gc_color);
    try writer.writeAll(label);
    try writer.writeAll("\x1b[0m");
    if (label.len < field_width) {
        var pad = field_width - label.len;
        while (pad > 0) : (pad -= 1) try writer.writeAll(" ");
    }
}

fn writeGcSummary(writer: anytype, snapshot: types.Snapshot) !void {
    if (snapshot.state != .ATTACHED) {
        try writer.writeAll("gc -: no jvm attached");
        return;
    }
    try writer.print("gc {d}.{d}% old {d}%", .{
        snapshot.gc_short_time_pct_x10 / 10,
        snapshot.gc_short_time_pct_x10 % 10,
        snapshot.gc_old_occ_pct,
    });
    try writer.print(" ygc={d}.{d}/s", .{
        snapshot.gc_short_rate_per_s_x10 / 10,
        snapshot.gc_short_rate_per_s_x10 % 10,
    });
}

pub fn gcSummaryLen(snapshot: types.Snapshot) usize {
    if (snapshot.state != .ATTACHED) return "gc -: no jvm attached".len;

    var len: usize = 0;
    len += "gc ".len;
    len += fmtu.decimalDigits(snapshot.gc_short_time_pct_x10 / 10);
    len += 1;
    len += 1;
    len += "% old ".len;
    len += fmtu.decimalDigits(snapshot.gc_old_occ_pct);
    len += " ygc=".len;
    len += fmtu.decimalDigits(snapshot.gc_short_rate_per_s_x10 / 10);
    len += 1;
    len += 1;
    len += "/s".len;
    return len;
}

fn writeGcCountsArea(writer: anytype, snapshot: types.Snapshot, width: usize, is_tty: bool) !void {
    if (width == 0) return;

    const count_digits_width: usize = 3;
    const ygc_label_prefix = " ygc=";
    const fgc_label_prefix = " fgc=";
    const count_trailing_space: usize = 1;
    const ygc_label_width = ygc_label_prefix.len + count_digits_width + count_trailing_space;
    const fgc_label_width = fgc_label_prefix.len + count_digits_width + count_trailing_space;
    const labels_total = ygc_label_width + fgc_label_width;

    if (width <= labels_total) {
        var i: usize = 0;
        if (is_tty) try writer.writeAll(color_empty);
        while (i < width) : (i += 1) try writer.writeAll(gc_count_empty);
        if (is_tty) try writer.writeAll("\x1b[0m");
        return;
    }

    const bars_total = width - labels_total;
    const ygc_bar_width = bars_total / 2;
    const fgc_bar_width = bars_total - ygc_bar_width;

    const ygc_count = if (snapshot.state == .ATTACHED) snapshot.gc_ygc_count else 0;
    const fgc_count = if (snapshot.state == .ATTACHED) snapshot.gc_fgc_count else 0;

    try writeGcCountBar(writer, ygc_count, ygc_bar_width, "\x1b[38;5;214m", is_tty);
    try writeGcTaggedCount(writer, ygc_label_prefix, ygc_count, "\x1b[38;5;214m", is_tty);
    try writeGcCountBar(writer, fgc_count, fgc_bar_width, "\x1b[38;5;203m", is_tty);
    try writeGcTaggedCount(writer, fgc_label_prefix, fgc_count, "\x1b[38;5;203m", is_tty);
}

fn writeGcCountBar(writer: anytype, count: u16, width: usize, fill_color: []const u8, is_tty: bool) !void {
    if (width == 0) return;
    const filled = @min(width, @as(usize, count));
    var i: usize = 0;
    while (i < width) : (i += 1) {
        if (is_tty) {
            if (i < filled) try writer.writeAll(fill_color) else try writer.writeAll(color_empty);
        }
        try writer.writeAll(if (i < filled) gc_count_fill else gc_count_empty);
    }
    if (is_tty) try writer.writeAll("\x1b[0m");
}

fn writeGcTaggedCount(writer: anytype, prefix: []const u8, count: u16, color: []const u8, is_tty: bool) !void {
    if (prefix.len > 0) {
        if (is_tty) try writer.writeAll("\x1b[2m");
        try writer.writeAll(prefix);
        if (is_tty) try writer.writeAll("\x1b[0m");
    }

    var buf: [3]u8 = [_]u8{ ' ', ' ', ' ' };
    if (count >= 100) {
        buf = [_]u8{ '9', '9', '+' };
    } else {
        const c = @as(u8, @intCast(count));
        if (c >= 10) {
            buf[0] = @as(u8, '0') + (c / 10);
            buf[1] = @as(u8, '0') + (c % 10);
        } else {
            buf[0] = @as(u8, '0') + c;
        }
    }

    if (is_tty) try writer.writeAll(color);
    try writer.writeAll(buf[0..]);
    if (is_tty) try writer.writeAll("\x1b[0m");
    try writer.writeAll(" ");
}
