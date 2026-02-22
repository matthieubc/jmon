pub const OutputFormat = enum {
    tui,
    text,
    json,
};

pub const State = enum {
    SEARCHING,
    ATTACHED,
    LOST,
};

pub const Options = struct {
    output: OutputFormat,
    once: bool,
    interval_ms: u64,
    app_pattern: []const u8,
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
    cpu_total_pct: u8,
    gc_time_pct: u8,
    gc_time_pct_x10: u16,
    gc_short_time_pct_x10: u16,
    gc_pressure_pct: u8,
    gc_level: u8,
    gc_old_occ_pct: u8,
    gc_rate_per_s_x10: u16,
    gc_short_rate_per_s_x10: u16,
    gc_full_seen: bool,
    gc_fgc_count: u16,
    io_disk_bps: u64,
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
    gc_fgc_baseline: ?u64 = null,
    heap_max_pid: ?u32 = null,
    heap_max_bytes: u64 = 0,
    attached_app_buf: [512]u8 = undefined,
    attached_app_len: usize = 0,
};
