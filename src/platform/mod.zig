// Platform probe dispatch layer.
// Selects the OS-specific implementation for process memory footprint sampling.

const builtin = @import("builtin");
const std = @import("std");
const types = @import("../types.zig");
const darwin = @import("darwin.zig");
const linux = @import("linux.zig");

pub fn readPhysicalFootprintBytes(allocator: std.mem.Allocator, pid: u32) ?u64 {
    return switch (builtin.os.tag) {
        .macos => darwin.readPhysicalFootprintBytes(pid),
        .linux => linux.readPhysicalFootprintBytes(allocator, pid),
        else => null,
    };
}

pub fn readHostCpuCoreTicks(allocator: std.mem.Allocator) ?types.HostCpuCoreTicksSample {
    return switch (builtin.os.tag) {
        .macos => darwin.readHostCpuCoreTicks(),
        .linux => linux.readHostCpuCoreTicks(allocator),
        else => null,
    };
}

pub fn readProcessDiskIoCounters(allocator: std.mem.Allocator, pid: u32) ?types.ProcessDiskIoCounters {
    return switch (builtin.os.tag) {
        .macos => darwin.readProcessDiskIoCounters(pid),
        .linux => linux.readProcessDiskIoCounters(allocator, pid),
        else => null,
    };
}
