// Time helpers for jmon runtime sampling.
// Centralizes Zig 0.16 POSIX clock access for wall-clock timestamps and intervals.

const std = @import("std");

pub fn unixSeconds() i64 {
    const ts = readClock(.REALTIME);
    return @as(i64, @intCast(ts.sec));
}

pub fn monotonicMillis() i64 {
    const ts = readClock(.MONOTONIC);
    return @as(i64, @intCast(ts.sec)) * std.time.ms_per_s +
        @as(i64, @intCast(@divTrunc(ts.nsec, std.time.ns_per_ms)));
}

fn readClock(clock_id: std.c.clockid_t) std.c.timespec {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(clock_id, &ts) != 0) @panic("clock_gettime failed");
    return ts;
}
