// TUI state definitions and layout constants.
// Stores prompt state, visual peaks, and memory chart buffers used during rendering.

const std = @import("std");

pub const fallback_bar_width: usize = 96;
pub const min_bar_width: usize = 40;
pub const max_bar_width: usize = 220;
pub const graph_mark = "─";
pub const thin_fill = "■";
pub const thin_empty = "■";
pub const color_empty = "\x1b[38;5;250m";
pub const max_status_len: usize = 256;
pub const mem_graph_max_cols: usize = 512;
pub const graph_row_buf_len: usize = mem_graph_max_cols * 4;
pub const mem_graph_pending_max: usize = 64;
pub const graph_right_scale_width: usize = 10;
pub const graph_right_gap: usize = 1;
pub const mem_history_window_ms: i64 = 5 * 60 * 1000;
pub const mem_history_max_points: usize = 2048;
// Rows shifted down to reserve two lines for per-core CPU mini-bars, one GC details line,
// one spacer after GC, and one IO detail row.
pub const prompt_row: usize = 14;
pub const status_row: usize = 15;
pub const legend_row: usize = 16;
pub const graph_title_row: usize = 17;
pub const graph_top_row: usize = 18;
pub const graph_height: usize = 10;
pub const graph_axis_row: usize = graph_top_row + graph_height;
pub const graph_label_row: usize = graph_axis_row + 1;
pub const default_tui_sample_interval_ms: u64 = 500;

pub const MemHistoryPoint = struct {
    ts_ms: i64,
    pct: u8,
};

pub const EscapeSeqState = enum {
    none,
    esc,
    csi,
};

pub const UiState = struct {
    input_buf: [256]u8 = undefined,
    input_len: usize = 0,
    status_buf: [max_status_len]u8 = undefined,
    status_len: usize = 0,
    should_quit: bool = false,
    reset_requested: bool = false,
    prompt_dirty: bool = true,
    escape_seq_state: EscapeSeqState = .none,
    mem_history_pid: ?u32 = null,
    mem_history: [mem_history_max_points]MemHistoryPoint = undefined,
    mem_history_len: usize = 0,
    mem_graph_pid: ?u32 = null,
    mem_graph_cols: [mem_graph_max_cols]u8 = undefined,
    mem_graph_len: usize = 0,
    mem_graph_pending: [mem_graph_pending_max]u8 = undefined,
    mem_graph_pending_len: usize = 0,
    mem_graph_last_pct: u8 = 0,
    sample_interval_ms: u64 = default_tui_sample_interval_ms,
};

pub const Peaks = struct {
    mem_pct: u8 = 0,
    mem_used_bytes: u64 = 0,
    cpu_pct: u8 = 0,
    gc_pct: u8 = 0,
    io_pct: u8 = 0,
    disk_read_pct: u8 = 0,
    disk_write_pct: u8 = 0,
};

pub const TextRenderState = struct {
    peaks: Peaks = .{},
};
