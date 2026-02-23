// Shared bar drawing primitives for compact sections.
// Provides watermark bars, layered memory bars, and reusable color helpers.

const std = @import("std");
const tui_state = @import("../tui/state.zig");
const fmtu = @import("format.zig");

const thin_fill = tui_state.thin_fill;
const thin_empty = tui_state.thin_empty;
const color_empty = tui_state.color_empty;

pub fn renderBar(
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
        try fmtu.writeHumanBytes(writer, a);
        try writer.writeAll(" / ");
        try fmtu.writeHumanBytes(writer, b);
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
    try fmtu.writeHumanBytes(writer, a);
    try writer.writeAll("/s net=");
    try fmtu.writeHumanBytes(writer, b);
    try writer.writeAll("/s\n");
}

pub fn writeWatermarkBar(
    writer: anytype,
    width: usize,
    pct: u8,
    peak: u8,
    fill_color: []const u8,
    trail_color: []const u8,
    is_tty: bool,
) !void {
    try writeWatermarkBarWithGlyphs(writer, width, pct, peak, fill_color, trail_color, is_tty, thin_fill, thin_empty);
}

pub fn writeWatermarkBarWithGlyphs(
    writer: anytype,
    width: usize,
    pct: u8,
    peak: u8,
    fill_color: []const u8,
    trail_color: []const u8,
    is_tty: bool,
    fill_glyph: []const u8,
    empty_glyph: []const u8,
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
        try writer.writeAll(if (i < peak_cells) fill_glyph else empty_glyph);
    }
    if (is_tty) try writer.writeAll("\x1b[0m");
}

pub fn writeGradientWatermarkBarWithGlyphs(
    writer: anytype,
    width: usize,
    pct: u8,
    peak: u8,
    is_tty: bool,
    fill_start_rgb: [3]u8,
    fill_mid_rgb: [3]u8,
    fill_end_rgb: [3]u8,
    trail_start_rgb: [3]u8,
    trail_mid_rgb: [3]u8,
    trail_end_rgb: [3]u8,
    fill_glyph: []const u8,
    empty_glyph: []const u8,
) !void {
    const filled = (@as(usize, pct) * width) / 100;
    const peak_cells_raw = (@as(usize, peak) * width) / 100;
    const peak_cells = @max(filled, @min(peak_cells_raw, width));

    var i: usize = 0;
    while (i < width) : (i += 1) {
        if (is_tty) {
            if (i < filled) {
                const rgb = gradientRgbAt(i, width, fill_start_rgb, fill_mid_rgb, fill_end_rgb);
                try writer.print("\x1b[38;2;{d};{d};{d}m", .{ rgb[0], rgb[1], rgb[2] });
            } else if (i < peak_cells) {
                const rgb = gradientRgbAt(i, width, trail_start_rgb, trail_mid_rgb, trail_end_rgb);
                try writer.print("\x1b[38;2;{d};{d};{d}m", .{ rgb[0], rgb[1], rgb[2] });
            } else {
                try writer.writeAll(color_empty);
            }
        }
        try writer.writeAll(if (i < peak_cells) fill_glyph else empty_glyph);
    }
    if (is_tty) try writer.writeAll("\x1b[0m");
}

pub fn gradientLastFilledRgb(
    width: usize,
    pct: u8,
    start_rgb: [3]u8,
    mid_rgb: [3]u8,
    end_rgb: [3]u8,
) ?[3]u8 {
    if (width == 0 or pct == 0) return null;
    const filled = (@as(usize, pct) * width) / 100;
    if (filled == 0) return null;
    return gradientRgbAt(filled - 1, width, start_rgb, mid_rgb, end_rgb);
}

pub fn writeMirroredGradientWatermarkBarWithGlyphs(
    writer: anytype,
    width: usize,
    left_pct: u8,
    left_peak_pct: u8,
    right_pct: u8,
    right_peak_pct: u8,
    is_tty: bool,
    fill_start_rgb: [3]u8,
    fill_mid_rgb: [3]u8,
    fill_end_rgb: [3]u8,
    trail_start_rgb: [3]u8,
    trail_mid_rgb: [3]u8,
    trail_end_rgb: [3]u8,
    fill_glyph: []const u8,
    empty_glyph: []const u8,
    center_glyph: []const u8,
    center_color: []const u8,
) !void {
    if (width == 0) return;
    const center_width = center_glyph.len;
    if (width <= center_width) {
        if (is_tty) try writer.writeAll(center_color);
        try writer.writeAll(center_glyph[0..width]);
        if (is_tty) try writer.writeAll("\x1b[0m");
        return;
    }

    const side_total = width - center_width;
    const left_width = side_total / 2;
    const right_width = side_total - left_width;

    try writeMirroredHalf(
        writer,
        left_width,
        left_pct,
        left_peak_pct,
        is_tty,
        true,
        fill_start_rgb,
        fill_mid_rgb,
        fill_end_rgb,
        trail_start_rgb,
        trail_mid_rgb,
        trail_end_rgb,
        fill_glyph,
        empty_glyph,
    );

    if (is_tty) try writer.writeAll(center_color);
    try writer.writeAll(center_glyph);

    try writeMirroredHalf(
        writer,
        right_width,
        right_pct,
        right_peak_pct,
        is_tty,
        false,
        fill_start_rgb,
        fill_mid_rgb,
        fill_end_rgb,
        trail_start_rgb,
        trail_mid_rgb,
        trail_end_rgb,
        fill_glyph,
        empty_glyph,
    );

    if (is_tty) try writer.writeAll("\x1b[0m");
}

pub fn writeGradientBar(
    writer: anytype,
    width: usize,
    pct: u8,
    is_tty: bool,
    start_rgb: [3]u8,
    mid_rgb: [3]u8,
    end_rgb: [3]u8,
) !void {
    try writeGradientBarWithGlyphs(writer, width, pct, is_tty, start_rgb, mid_rgb, end_rgb, thin_fill, thin_empty);
}

fn writeMirroredHalf(
    writer: anytype,
    width: usize,
    pct: u8,
    peak_pct: u8,
    is_tty: bool,
    reverse_gradient: bool,
    fill_start_rgb: [3]u8,
    fill_mid_rgb: [3]u8,
    fill_end_rgb: [3]u8,
    trail_start_rgb: [3]u8,
    trail_mid_rgb: [3]u8,
    trail_end_rgb: [3]u8,
    fill_glyph: []const u8,
    empty_glyph: []const u8,
) !void {
    if (width == 0) return;
    const filled = (@as(usize, pct) * width) / 100;
    const peak_raw = (@as(usize, peak_pct) * width) / 100;
    const peak = @max(filled, @min(peak_raw, width));

    var i: usize = 0;
    while (i < width) : (i += 1) {
        const fill_start_idx = width - filled;
        const peak_start_idx = width - peak;
        const in_fill = i >= fill_start_idx;
        const in_peak = i >= peak_start_idx;

        if (is_tty) {
            if (in_fill) {
                const grad_idx = if (reverse_gradient) (width - 1 - i) else i;
                const rgb = gradientRgbAt(grad_idx, width, fill_start_rgb, fill_mid_rgb, fill_end_rgb);
                try writer.print("\x1b[38;2;{d};{d};{d}m", .{ rgb[0], rgb[1], rgb[2] });
            } else if (in_peak) {
                const grad_idx = if (reverse_gradient) (width - 1 - i) else i;
                const rgb = gradientRgbAt(grad_idx, width, trail_start_rgb, trail_mid_rgb, trail_end_rgb);
                try writer.print("\x1b[38;2;{d};{d};{d}m", .{ rgb[0], rgb[1], rgb[2] });
            } else {
                try writer.writeAll(color_empty);
            }
        }
        try writer.writeAll(if (in_peak) fill_glyph else empty_glyph);
    }
}

pub fn writeGradientBarWithGlyphs(
    writer: anytype,
    width: usize,
    pct: u8,
    is_tty: bool,
    start_rgb: [3]u8,
    mid_rgb: [3]u8,
    end_rgb: [3]u8,
    fill_glyph: []const u8,
    empty_glyph: []const u8,
) !void {
    const filled = (@as(usize, pct) * width) / 100;
    var i: usize = 0;
    while (i < width) : (i += 1) {
        if (is_tty) {
            if (i < filled) {
                const rgb = gradientRgbAt(i, width, start_rgb, mid_rgb, end_rgb);
                try writer.print("\x1b[38;2;{d};{d};{d}m", .{ rgb[0], rgb[1], rgb[2] });
            } else {
                try writer.writeAll(color_empty);
            }
        }
        try writer.writeAll(if (i < filled) fill_glyph else empty_glyph);
    }
    if (is_tty) try writer.writeAll("\x1b[0m");
}

pub fn writeMemoryLayeredBar(
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

pub fn lighterColor(fill_color: []const u8) []const u8 {
    if (std.mem.eql(u8, fill_color, "\x1b[38;5;82m")) return "\x1b[38;5;157m";
    if (std.mem.eql(u8, fill_color, "\x1b[38;5;141m")) return "\x1b[38;5;183m";
    if (std.mem.eql(u8, fill_color, "\x1b[38;5;45m")) return "\x1b[38;5;159m";
    return fill_color;
}

fn gradientRgbAt(
    index: usize,
    width: usize,
    start_rgb: [3]u8,
    mid_rgb: [3]u8,
    end_rgb: [3]u8,
) [3]u8 {
    if (width <= 1) return start_rgb;
    const denom = width - 1;
    const idx = @min(index, denom);
    // Two linear segments: [start -> mid] on first half, [mid -> end] on second half.
    if (idx * 2 <= denom) {
        return lerpRgb(start_rgb, mid_rgb, idx * 2, denom);
    }
    return lerpRgb(mid_rgb, end_rgb, (idx * 2) - denom, denom);
}

fn lerpRgb(a: [3]u8, b: [3]u8, num: usize, den: usize) [3]u8 {
    if (den == 0) return a;
    var out: [3]u8 = undefined;
    inline for (0..3) |c| {
        const av = @as(i32, a[c]);
        const bv = @as(i32, b[c]);
        const delta = bv - av;
        const v = av + @divTrunc(delta * @as(i32, @intCast(num)), @as(i32, @intCast(den)));
        out[c] = @as(u8, @intCast(std.math.clamp(v, 0, 255)));
    }
    return out;
}
