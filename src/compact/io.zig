// Compact IO section renderer.
// Renders an aligned IO bar plus a per-process disk details line (rates + session totals).

const std = @import("std");
const types = @import("../types.zig");
const bars = @import("bars.zig");
const metrics = @import("metrics.zig");
const fmtu = @import("format.zig");

const disk_fill = "■";
const disk_empty = "■";
const disk_total_fill = "━";
const disk_total_empty = "━";
const disk_center_color = "\x1b[38;5;242m";
const io_empty_text_color = "\x1b[38;5;250m";

const purple_fill_start = [3]u8{ 0x58, 0x1F, 0x87 }; // dark purple (center)
const purple_fill_mid = [3]u8{ 0xA1, 0x36, 0xC6 }; // vivid purple
const purple_fill_end = [3]u8{ 0xFF, 0x8F, 0xE7 }; // pink (edge)
const purple_trail_start = [3]u8{ 0x95, 0x6B, 0xBC };
const purple_trail_mid = [3]u8{ 0xC8, 0x90, 0xDD };
const purple_trail_end = [3]u8{ 0xFF, 0xC7, 0xE8 };
const center_label_slot_width: usize = 10; // minimum fixed slot that still fits `r net(h) w`.

pub fn renderIoLine(
    writer: anytype,
    snapshot: types.Snapshot,
    peak_read_pct: u8,
    peak_write_pct: u8,
    width: usize,
    is_tty: bool,
) !void {
    _ = peak_read_pct;
    _ = peak_write_pct;
    const attached = snapshot.state == .ATTACHED;
    const read_bps = if (attached) snapshot.io_disk_read_bps else 0;
    const write_bps = if (attached) snapshot.io_disk_write_bps else 0;
    const read_total = if (attached) snapshot.io_disk_read_total_bytes else 0;
    const write_total = if (attached) snapshot.io_disk_write_total_bytes else 0;
    const read_pct = metrics.ioToPct(read_bps);
    const write_pct = metrics.ioToPct(write_bps);
    const total_bar_scale_bytes = totalAutoScaleBytes(read_total, write_total);
    const read_total_pct = pctForScale(read_total, total_bar_scale_bytes);
    const write_total_pct = pctForScale(write_total, total_bar_scale_bytes);

    var left_rate_buf: [16]u8 = undefined;
    var right_rate_buf: [16]u8 = undefined;
    const left_rate = formatRateMbPerS(&left_rate_buf, read_bps);
    const right_rate = formatRateMbPerS(&right_rate_buf, write_bps);
    try fmtu.writeBold(writer, "IO  ", is_tty);
    try renderMirroredLabeledLine(
        writer,
        width,
        attached,
        left_rate,
        right_rate,
        "disk",
        read_pct,
        write_pct,
        read_pct, // no watermark
        write_pct, // no watermark
        disk_fill,
        disk_empty,
        is_tty,
    );
    try writer.writeAll("\n");

    if (is_tty) try writer.writeAll("\x1b[2K");
    try writer.writeAll("    ");
    var left_total_buf: [16]u8 = undefined;
    var right_total_buf: [16]u8 = undefined;
    const left_total = formatTotalMb(&left_total_buf, read_total);
    const right_total = formatTotalMb(&right_total_buf, write_total);
    try renderMirroredLabeledLine(
        writer,
        width,
        attached,
        left_total,
        right_total,
        "tot.",
        read_total_pct,
        write_total_pct,
        read_total_pct, // no watermark
        write_total_pct, // no watermark
        disk_total_fill,
        disk_total_empty,
        is_tty,
    );
    try writer.writeAll("\n");
}

fn renderMirroredLabeledLine(
    writer: anytype,
    width: usize,
    attached: bool,
    left_text: []const u8,
    right_text: []const u8,
    center_label: []const u8,
    left_pct: u8,
    right_pct: u8,
    left_peak_pct: u8,
    right_peak_pct: u8,
    fill_glyph: []const u8,
    empty_glyph: []const u8,
    is_tty: bool,
) !void {
    const field_width: usize = fmtu.bar_side_field_width;
    const bars_width = if (width > (field_width * 2)) width - (field_width * 2) else 1;
    var center_buf: [32]u8 = undefined;
    const center_text = formatCenterLabel(&center_buf, center_label);
    const side_total = if (bars_width > center_text.len) bars_width - center_text.len else 0;
    const left_width = side_total / 2;
    const right_width = side_total - left_width;

    try writeIoField(writer, left_text, field_width, left_width, attached, true, is_tty);
    try bars.writeMirroredGradientWatermarkBarWithGlyphs(
        writer,
        bars_width,
        left_pct,
        left_peak_pct,
        right_pct,
        right_peak_pct,
        is_tty,
        purple_fill_start,
        purple_fill_mid,
        purple_fill_end,
        purple_trail_start,
        purple_trail_mid,
        purple_trail_end,
        fill_glyph,
        empty_glyph,
        center_text,
        disk_center_color,
    );
    try writeIoField(writer, right_text, field_width, right_width, attached, false, is_tty);
}

fn formatRateMbPerS(buf: []u8, bps: u64) []const u8 {
    const mbps = @as(f64, @floatFromInt(bps)) / (1024.0 * 1024.0);
    return std.fmt.bufPrint(buf, "{d:.1}MB/s", .{mbps}) catch "0.0MB/s";
}

fn formatTotalMb(buf: []u8, bytes: u64) []const u8 {
    const mb = (@as(u128, bytes) + (1024 * 1024 / 2)) / (1024 * 1024);
    return std.fmt.bufPrint(buf, "{d}MB", .{mb}) catch "0MB";
}

fn pctForScale(value: u64, scale: u64) u8 {
    if (scale == 0) return 0;
    const raw = (@as(u128, value) * 100) / @as(u128, scale);
    return @as(u8, @intCast(@min(raw, 100)));
}

fn totalAutoScaleBytes(read_total: u64, write_total: u64) u64 {
    const one_gib: u64 = 1024 * 1024 * 1024;
    var scale = one_gib;
    const max_total = @max(read_total, write_total);
    while (max_total >= scale) {
        const next = std.math.mul(u64, scale, 10) catch break;
        scale = next;
    }
    return scale;
}

fn formatCenterLabel(buf: []u8, label: []const u8) []const u8 {
    // Fixed-width slot keeps the bar space identical across rows (`disk`, `tot.`, future `net(h)`).
    // `r` and `w` are always placed at the slot edges so they touch the bars directly.
    if (center_label_slot_width == 0) return "";
    if (center_label_slot_width == 1) return "r";
    if (center_label_slot_width == 2) return "rw";

    const inner_width = center_label_slot_width - 2;
    const trimmed = std.mem.trim(u8, label, " ");
    const inner_label = if (trimmed.len > inner_width) trimmed[0..inner_width] else trimmed;

    var pos: usize = 0;
    buf[pos] = 'r';
    pos += 1;

    const inner_left_pad = if (inner_width > inner_label.len) (inner_width - inner_label.len) / 2 else 0;
    const inner_right_pad = if (inner_width > inner_label.len) inner_width - inner_label.len - inner_left_pad else 0;

    var i: usize = 0;
    while (i < inner_left_pad) : (i += 1) {
        buf[pos] = ' ';
        pos += 1;
    }
    std.mem.copyForwards(u8, buf[pos .. pos + inner_label.len], inner_label);
    pos += inner_label.len;
    i = 0;
    while (i < inner_right_pad) : (i += 1) {
        buf[pos] = ' ';
        pos += 1;
    }
    buf[pos] = 'w';
    pos += 1;
    return buf[0..pos];
}

fn writeIoField(
    writer: anytype,
    text: []const u8,
    field_width: usize,
    side_width: usize,
    attached: bool,
    left_align: bool,
    is_tty: bool,
) !void {
    if (!is_tty) {
        if (left_align) {
            try writer.print("{s: <" ++ std.fmt.comptimePrint("{}", .{fmtu.bar_side_field_width}) ++ "}", .{text});
        } else {
            try writer.print("{s: >" ++ std.fmt.comptimePrint("{}", .{fmtu.bar_side_field_width}) ++ "}", .{text});
        }
        return;
    }

    const visible_len = text.len;
    if (left_align) {
        try writeIoFieldText(writer, text, side_width, attached, is_tty);
        if (visible_len < field_width) {
            var pad = field_width - visible_len;
            while (pad > 0) : (pad -= 1) try writer.writeAll(" ");
        }
    } else {
        if (visible_len < field_width) {
            var pad = field_width - visible_len;
            while (pad > 0) : (pad -= 1) try writer.writeAll(" ");
        }
        try writeIoFieldText(writer, text, side_width, attached, is_tty);
    }
}

fn writeIoFieldText(
    writer: anytype,
    text: []const u8,
    side_width: usize,
    attached: bool,
    is_tty: bool,
) !void {
    if (!is_tty) {
        try writer.writeAll(text);
        return;
    }
    _ = side_width;
    if (attached) {
        try writer.writeAll(fmtu.prebar_io_color);
        try writer.writeAll(text);
        try writer.writeAll("\x1b[0m");
    } else {
        try writer.writeAll(io_empty_text_color);
        try writer.writeAll(text);
        try writer.writeAll("\x1b[0m");
    }
}
