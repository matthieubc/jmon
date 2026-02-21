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
    cpu_total_pct: u8,
    gc_time_pct: u8,
    io_disk_bps: u64,
    io_net_bps: u64,
    finding_count: u32,
};

pub const GcTracker = struct {
    pid: u32,
    ts_ms: i64,
    ygc: u64,
    fgc: u64,
    gct_s: f64,
};

pub const RuntimeState = struct {
    was_attached: bool = false,
    prev_gc: ?GcTracker = null,
    attached_app_buf: [512]u8 = undefined,
    attached_app_len: usize = 0,
};
