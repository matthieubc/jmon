const std = @import("std");
const types = @import("types.zig");

pub fn writeTextSample(writer: anytype, snapshot: types.Snapshot) !void {
    try writer.print("ts_unix_s={d} sample={d} state={s} app_pattern=", .{
        snapshot.ts_unix_s,
        snapshot.sample,
        @tagName(snapshot.state),
    });
    try writeJsonString(writer, snapshot.app_pattern);
    if (snapshot.pid) |pid| {
        try writer.print(" pid={d}", .{pid});
    } else {
        try writer.writeAll(" pid=-");
    }
    try writer.writeAll(" attached_app=");
    if (snapshot.attached_app) |app_name| {
        try writeJsonString(writer, app_name);
    } else {
        try writer.writeAll("-");
    }
    try writer.print(
        " mem_used_bytes={d} mem_committed_bytes={d} mem_max_bytes={d} cpu_total_pct={d} gc_time_pct={d} io_disk_bps={d} io_net_bps={d} finding_count={d}\n",
        .{
            snapshot.mem_used_bytes,
            snapshot.mem_committed_bytes,
            snapshot.mem_max_bytes,
            snapshot.cpu_total_pct,
            snapshot.gc_time_pct,
            snapshot.io_disk_bps,
            snapshot.io_net_bps,
            snapshot.finding_count,
        },
    );
}

pub fn writeJsonSample(writer: anytype, snapshot: types.Snapshot) !void {
    try writer.print("{{\"ts_unix_s\":{d},\"sample\":{d},\"state\":\"{s}\",\"app_pattern\":", .{
        snapshot.ts_unix_s,
        snapshot.sample,
        @tagName(snapshot.state),
    });
    try writeJsonString(writer, snapshot.app_pattern);

    if (snapshot.pid) |pid| {
        try writer.print(",\"pid\":{d}", .{pid});
    } else {
        try writer.writeAll(",\"pid\":null");
    }
    try writer.writeAll(",\"attached_app\":");
    if (snapshot.attached_app) |app_name| {
        try writeJsonString(writer, app_name);
    } else {
        try writer.writeAll("null");
    }

    try writer.print(",\"mem_used_bytes\":{d},\"mem_committed_bytes\":{d},\"mem_max_bytes\":{d},\"cpu_total_pct\":{d},\"gc_time_pct\":{d},\"io_disk_bps\":{d},\"io_net_bps\":{d},\"finding_count\":{d}}}\n", .{
        snapshot.mem_used_bytes,
        snapshot.mem_committed_bytes,
        snapshot.mem_max_bytes,
        snapshot.cpu_total_pct,
        snapshot.gc_time_pct,
        snapshot.io_disk_bps,
        snapshot.io_net_bps,
        snapshot.finding_count,
    });
}

fn writeJsonString(writer: anytype, value: []const u8) !void {
    try writer.writeAll("\"");
    for (value) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => try writer.writeByte(c),
        }
    }
    try writer.writeAll("\"");
}
