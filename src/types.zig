// Shared data model for jmon.
// Defines snapshots, runtime state, options, and common enums used across modules.

pub const OutputFormat = enum {
    tui,
    text,
};

pub const State = enum {
    SEARCHING,
    ATTACHED,
    LOST,
};

pub const ChartOptions = struct {
    memory: bool = false,
    cpu: bool = false,
    io: bool = false,
};

pub const max_cpu_cores: usize = 128;

pub const HostCpuCoreTicksSample = struct {
    len: usize = 0,
    total_ticks: [max_cpu_cores]u64 = [_]u64{0} ** max_cpu_cores,
    idle_ticks: [max_cpu_cores]u64 = [_]u64{0} ** max_cpu_cores,
};

pub const ProcessDiskIoCounters = struct {
    read_bytes: u64 = 0,
    write_bytes: u64 = 0,
};

pub const Options = struct {
    output: OutputFormat,
    once: bool,
    interval_ms: u64,
    sample_interval_ms: u64,
    app_pattern: []const u8,
    charts: ChartOptions,
};

pub const Snapshot = struct {
    ts_unix_s: i64,
    sample: u64,
    state: State,
    app_pattern: []const u8,
    pid: ?u32,
    attached_app: ?[]const u8,
    mem_used_bytes: u64,
    mem_committed_bytes: u64,
    mem_max_bytes: u64,
    mem_physical_footprint_bytes: u64,
    // Normalized to total machine CPU capacity (0..100) for the top CPU bar fill.
    cpu_total_pct: u8,
    // Raw JVM process CPU percent from `ps`, in tenths (can exceed 100% on multicore).
    cpu_process_pct_x10: u16,
    cpu_host_core_count: u8,
    cpu_host_core_pcts: [max_cpu_cores]u8,
    gc_time_pct: u8,
    gc_time_pct_x10: u16,
    gc_short_time_pct_x10: u16,
    gc_pressure_pct: u8,
    gc_level: u8,
    gc_old_occ_pct: u8,
    gc_rate_per_s_x10: u16,
    gc_short_rate_per_s_x10: u16,
    gc_full_seen: bool,
    gc_ygc_count: u16,
    gc_fgc_count: u16,
    io_disk_bps: u64,
    io_disk_read_bps: u64,
    io_disk_write_bps: u64,
    io_disk_read_total_bytes: u64,
    io_disk_write_total_bytes: u64,
    io_net_bps: u64,
    finding_count: u32,
};

pub const GcPoint = struct {
    pid: u32,
    ts_ms: i64,
    ygc: u64,
    fgc: u64,
    gct_s: f64,
    old_used_bytes: u64,
    old_committed_bytes: u64,
};

pub const RuntimeState = struct {
    was_attached: bool = false,
    attached_pid: ?u32 = null,
    gc_points: [512]GcPoint = undefined,
    gc_points_len: usize = 0,
    gc_time_red_windows: u8 = 0,
    last_full_gc_seen_ts_ms: i64 = -1,
    gc_pressure_ewma: f64 = 0,
    gc_ygc_baseline: ?u64 = null,
    gc_fgc_baseline: ?u64 = null,
    heap_max_pid: ?u32 = null,
    heap_max_bytes: u64 = 0,
    host_cpu_prev_valid: bool = false,
    host_cpu_prev_count: usize = 0,
    host_cpu_prev_total_ticks: [max_cpu_cores]u64 = [_]u64{0} ** max_cpu_cores,
    host_cpu_prev_idle_ticks: [max_cpu_cores]u64 = [_]u64{0} ** max_cpu_cores,
    attached_app_buf: [512]u8 = undefined,
    attached_app_len: usize = 0,
    disk_io_prev_pid: ?u32 = null,
    disk_io_prev_ts_ms: i64 = 0,
    disk_io_prev_read_bytes: u64 = 0,
    disk_io_prev_write_bytes: u64 = 0,
    disk_io_prev_valid: bool = false,
    disk_io_total_baseline_pid: ?u32 = null,
    disk_io_total_baseline_read_bytes: u64 = 0,
    disk_io_total_baseline_write_bytes: u64 = 0,
    disk_io_total_baseline_valid: bool = false,
};
