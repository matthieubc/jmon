const sampler = @import("sampler.zig");
const std = @import("std");
const types = @import("types.zig");

const bar_width: usize = 48;

const Peaks = struct {
    mem_pct: u8 = 0,
    cpu_pct: u8 = 0,
    gc_pct: u8 = 0,
    io_pct: u8 = 0,
};

pub fn run(allocator: std.mem.Allocator, writer: anytype, opts: types.Options) !void {
    const stdout_file = std.fs.File.stdout();
    const is_tty = stdout_file.isTty();

    if (is_tty) {
        try writer.writeAll("\x1b[?1049h\x1b[?25l");
    }
    defer {
        if (is_tty) {
            writer.writeAll("\x1b[0m\x1b[?25h\x1b[?1049l") catch {};
        }
    }

    var sample: u64 = 0;
    var runtime = types.RuntimeState{};
    var peaks = Peaks{};

    while (true) {
        sample += 1;
        const snapshot = sampler.collectSnapshot(allocator, opts.app_pattern, sample, &runtime);
        updatePeaks(&peaks, snapshot);
        try renderFrame(writer, snapshot, peaks, is_tty);
        if (opts.once) break;
        std.Thread.sleep(opts.interval_ms * std.time.ns_per_ms);
    }
}

fn renderFrame(writer: anytype, snapshot: types.Snapshot, peaks: Peaks, is_tty: bool) !void {
    try writer.writeAll("\x1b[H\x1b[2J");

    if (is_tty) {
        try writer.writeAll("\x1b[1m");
    }
    try writer.writeAll("jmon");
    if (is_tty) {
        try writer.writeAll("\x1b[0m");
    }
    try writer.print("  state={s}  sample={d}\n", .{ @tagName(snapshot.state), snapshot.sample });

    try writer.writeAll("app_pattern=");
    try writeQuoted(writer, snapshot.app_pattern);
    try writer.writeAll("  pid=");
    if (snapshot.pid) |pid| {
        try writer.print("{d}", .{pid});
    } else {
        try writer.writeAll("-");
    }
    try writer.writeAll("  attached_app=");
    if (snapshot.attached_app) |app_name| {
        try writeQuoted(writer, app_name);
    } else {
        try writer.writeAll("-");
    }
    try writer.writeAll("\n\n");

    const mem_pct = usagePct(snapshot.mem_used_bytes, snapshot.mem_committed_bytes);
    try renderBar(writer, "MEM", mem_pct, peaks.mem_pct, "\x1b[38;5;45m", snapshot.mem_used_bytes, snapshot.mem_committed_bytes, "bytes", is_tty);

    try renderBar(writer, "CPU", snapshot.cpu_total_pct, peaks.cpu_pct, "\x1b[38;5;82m", snapshot.cpu_total_pct, peaks.cpu_pct, "pct", is_tty);

    try renderBar(writer, "GC ", snapshot.gc_time_pct, peaks.gc_pct, "\x1b[38;5;214m", snapshot.gc_time_pct, peaks.gc_pct, "pct", is_tty);

    const io_total = snapshot.io_disk_bps + snapshot.io_net_bps;
    try renderBar(writer, "IO ", ioToPct(io_total), peaks.io_pct, "\x1b[38;5;141m", snapshot.io_disk_bps, snapshot.io_net_bps, "io", is_tty);

    try writer.writeAll("\n");
    if (is_tty) {
        try writer.writeAll("\x1b[2m");
    }
    try writer.writeAll(": commands coming soon (q to quit will be added)\n");
    if (is_tty) {
        try writer.writeAll("\x1b[0m");
    }
}

fn renderBar(
    writer: anytype,
    label: []const u8,
    pct: u8,
    peak: u8,
    color: []const u8,
    a: u64,
    b: u64,
    mode: []const u8,
    is_tty: bool,
) !void {
    const filled = (@as(usize, pct) * bar_width) / 100;
    const peak_pos = (@as(usize, peak) * bar_width) / 100;

    try writer.print("{s} [", .{label});
    if (is_tty) try writer.writeAll(color);
    var i: usize = 0;
    while (i < bar_width) : (i += 1) {
        if (i < filled) {
            try writer.writeAll("█");
        } else if (i == peak_pos and peak > 0 and peak_pos < bar_width) {
            try writer.writeAll("│");
        } else {
            try writer.writeAll("░");
        }
    }
    if (is_tty) try writer.writeAll("\x1b[0m");

    if (std.mem.eql(u8, mode, "bytes")) {
        try writer.print("] {d}%  ", .{pct});
        try writeHumanBytes(writer, a);
        try writer.writeAll(" / ");
        try writeHumanBytes(writer, b);
        try writer.writeAll("\n");
        return;
    }
    if (std.mem.eql(u8, mode, "pct")) {
        try writer.print("] {d}%  peak={d}%\n", .{ pct, peak });
        return;
    }
    try writer.writeAll("] disk=");
    try writeHumanBytes(writer, a);
    try writer.writeAll("/s net=");
    try writeHumanBytes(writer, b);
    try writer.writeAll("/s\n");
}

fn updatePeaks(peaks: *Peaks, snapshot: types.Snapshot) void {
    const mem_pct = usagePct(snapshot.mem_used_bytes, snapshot.mem_committed_bytes);
    peaks.mem_pct = @max(peaks.mem_pct, mem_pct);
    peaks.cpu_pct = @max(peaks.cpu_pct, snapshot.cpu_total_pct);
    peaks.gc_pct = @max(peaks.gc_pct, snapshot.gc_time_pct);
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

fn writeHumanBytes(writer: anytype, bytes: u64) !void {
    const units = [_][]const u8{ "B", "KB", "MB", "GB", "TB" };
    var value = @as(f64, @floatFromInt(bytes));
    var idx: usize = 0;
    while (value >= 1024.0 and idx + 1 < units.len) : (idx += 1) value /= 1024.0;
    try writer.print("{d:.1}{s}", .{ value, units[idx] });
}

fn writeQuoted(writer: anytype, value: []const u8) !void {
    try writer.writeAll("\"");
    try writer.writeAll(value);
    try writer.writeAll("\"");
}
