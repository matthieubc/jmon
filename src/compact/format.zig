// Formatting helpers for compact output.
// Formats quoted strings, byte sizes, and MB labels used by section renderers.

const std = @import("std");

pub fn decimalDigits(value: anytype) usize {
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

pub fn writeHumanBytes(writer: anytype, bytes: u64) !void {
    const units = [_][]const u8{ "B", "KB", "MB", "GB", "TB" };
    var value = @as(f64, @floatFromInt(bytes));
    var idx: usize = 0;
    while (value >= 1024.0 and idx + 1 < units.len) : (idx += 1) value /= 1024.0;
    try writer.print("{d:.1}{s}", .{ value, units[idx] });
}

pub fn writeMb(writer: anytype, bytes: u64) !void {
    const mb = (@as(u128, bytes) + (1024 * 1024 / 2)) / (1024 * 1024);
    try writer.print("{d}MB", .{mb});
}

pub fn mbVisibleLen(bytes: u64) usize {
    const mb = (@as(u128, bytes) + (1024 * 1024 / 2)) / (1024 * 1024);
    return decimalDigits(mb) + "MB".len;
}

pub fn writeQuoted(writer: anytype, value: []const u8) !void {
    try writer.writeAll("\"");
    try writer.writeAll(value);
    try writer.writeAll("\"");
}
