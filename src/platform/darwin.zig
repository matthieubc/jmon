// macOS process memory probes.
// Reads process physical footprint using libproc APIs for live memory visualization.

const builtin = @import("builtin");
const std = @import("std");
const types = @import("../types.zig");

const rusage_info_v4_flavor: c_int = 4;
const kern_success: c_int = 0;
const processor_cpu_load_info: c_int = 2;
const cpu_state_max: usize = 4;
const cpu_state_user: usize = 0;
const cpu_state_system: usize = 1;
const cpu_state_idle: usize = 2;
const cpu_state_nice: usize = 3;

const MachPort = c_uint;

const RusageInfoV4 = extern struct {
    ri_uuid: [16]u8,
    ri_user_time: u64,
    ri_system_time: u64,
    ri_pkg_idle_wkups: u64,
    ri_interrupt_wkups: u64,
    ri_pageins: u64,
    ri_wired_size: u64,
    ri_resident_size: u64,
    ri_phys_footprint: u64,
    ri_proc_start_abstime: u64,
    ri_proc_exit_abstime: u64,
    ri_child_user_time: u64,
    ri_child_system_time: u64,
    ri_child_pkg_idle_wkups: u64,
    ri_child_interrupt_wkups: u64,
    ri_child_pageins: u64,
    ri_child_elapsed_abstime: u64,
    ri_diskio_bytesread: u64,
    ri_diskio_byteswritten: u64,
    ri_cpu_time_qos_default: u64,
    ri_cpu_time_qos_maintenance: u64,
    ri_cpu_time_qos_background: u64,
    ri_cpu_time_qos_utility: u64,
    ri_cpu_time_qos_legacy: u64,
    ri_cpu_time_qos_user_initiated: u64,
    ri_cpu_time_qos_user_interactive: u64,
    ri_billed_system_time: u64,
    ri_serviced_system_time: u64,
    ri_logical_writes: u64,
    ri_lifetime_max_phys_footprint: u64,
    ri_instructions: u64,
    ri_cycles: u64,
    ri_billed_energy: u64,
    ri_serviced_energy: u64,
    ri_interval_max_phys_footprint: u64,
    ri_runnable_time: u64,
};

extern "c" fn proc_pid_rusage(pid: c_int, flavor: c_int, buffer: *anyopaque) c_int;
extern "c" fn mach_host_self() MachPort;
extern "c" var mach_task_self_: MachPort;
extern "c" fn host_processor_info(
    host: MachPort,
    flavor: c_int,
    out_processor_count: *c_uint,
    out_processor_info: *[*]c_int,
    out_processor_info_count: *c_uint,
) c_int;
extern "c" fn vm_deallocate(target_task: MachPort, address: usize, size: usize) c_int;

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

    var cpu_info: [*]c_int = undefined;
    var cpu_count: c_uint = 0;
    var info_count: c_uint = 0;

    const kr = host_processor_info(
        mach_host_self(),
        processor_cpu_load_info,
        &cpu_count,
        &cpu_info,
        &info_count,
    );
    if (kr != kern_success) return null;
    defer {
        _ = vm_deallocate(
            mach_task_self_,
            @intFromPtr(cpu_info),
            @as(usize, @intCast(info_count)) * @sizeOf(c_int),
        );
    }

    var sample = types.HostCpuCoreTicksSample{};
    const count = @min(@as(usize, @intCast(cpu_count)), types.max_cpu_cores);

    var i: usize = 0;
    while (i < count) : (i += 1) {
        const base = i * cpu_state_max;
        const user = @as(u64, @intCast(cpu_info[base + cpu_state_user]));
        const system = @as(u64, @intCast(cpu_info[base + cpu_state_system]));
        const idle = @as(u64, @intCast(cpu_info[base + cpu_state_idle]));
        const nice = @as(u64, @intCast(cpu_info[base + cpu_state_nice]));
        sample.total_ticks[i] = user + system + idle + nice;
        sample.idle_ticks[i] = idle;
    }
    sample.len = count;
    return sample;
}

fn readRusageInfoV4(pid: u32) ?RusageInfoV4 {
    if (builtin.os.tag != .macos) return null;

    var info = std.mem.zeroes(RusageInfoV4);
    const rc = proc_pid_rusage(
        @as(c_int, @intCast(pid)),
        rusage_info_v4_flavor,
        @ptrCast(&info),
    );
    if (rc != 0) return null;
    return info;
}
