// macOS process memory probes.
// Reads process physical footprint using libproc APIs for live memory visualization.

const builtin = @import("builtin");
const std = @import("std");
const types = @import("../types.zig");

const c_platform = if (builtin.os.tag == .macos) @cImport({
    @cInclude("libproc.h");
    @cInclude("mach/mach.h");
    @cInclude("sys/resource.h");
}) else struct {};

pub fn readPhysicalFootprintBytes(pid: u32) ?u64 {
    const info = readRusageInfoV4(pid) orelse return null;
    return @as(u64, @intCast(info.ri_phys_footprint));
}

pub fn readProcessDiskIoCounters(pid: u32) ?types.ProcessDiskIoCounters {
    const info = readRusageInfoV4(pid) orelse return null;
    return .{
        .read_bytes = @as(u64, @intCast(info.ri_diskio_bytesread)),
        .write_bytes = @as(u64, @intCast(info.ri_diskio_byteswritten)),
    };
}

pub fn readHostCpuCoreTicks() ?types.HostCpuCoreTicksSample {
    if (builtin.os.tag != .macos) return null;

    var cpu_info: c_platform.processor_info_array_t = undefined;
    var cpu_count: c_platform.natural_t = 0;
    var info_count: c_platform.mach_msg_type_number_t = 0;

    const kr = c_platform.host_processor_info(
        c_platform.mach_host_self(),
        c_platform.PROCESSOR_CPU_LOAD_INFO,
        &cpu_count,
        &cpu_info,
        &info_count,
    );
    if (kr != c_platform.KERN_SUCCESS) return null;
    defer {
        _ = c_platform.vm_deallocate(
            c_platform.mach_task_self(),
            @as(c_platform.vm_address_t, @intCast(@intFromPtr(cpu_info))),
            @as(c_platform.vm_size_t, @intCast(@as(usize, info_count) * @sizeOf(c_platform.integer_t))),
        );
    }

    var sample = types.HostCpuCoreTicksSample{};
    const count = @min(@as(usize, @intCast(cpu_count)), types.max_cpu_cores);
    const ints: [*]c_platform.integer_t = cpu_info;
    const stride: usize = c_platform.CPU_STATE_MAX;

    var i: usize = 0;
    while (i < count) : (i += 1) {
        const base = i * stride;
        const user = @as(u64, @intCast(ints[base + c_platform.CPU_STATE_USER]));
        const system = @as(u64, @intCast(ints[base + c_platform.CPU_STATE_SYSTEM]));
        const idle = @as(u64, @intCast(ints[base + c_platform.CPU_STATE_IDLE]));
        const nice = @as(u64, @intCast(ints[base + c_platform.CPU_STATE_NICE]));
        sample.total_ticks[i] = user + system + idle + nice;
        sample.idle_ticks[i] = idle;
    }
    sample.len = count;
    return sample;
}

fn readRusageInfoV4(pid: u32) ?c_platform.struct_rusage_info_v4 {
    if (builtin.os.tag != .macos) return null;

    var info = std.mem.zeroes(c_platform.struct_rusage_info_v4);
    const rc = c_platform.proc_pid_rusage(
        @as(c_int, @intCast(pid)),
        c_platform.RUSAGE_INFO_V4,
        @ptrCast(&info),
    );
    if (rc != 0) return null;
    return info;
}
