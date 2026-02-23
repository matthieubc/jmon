// Interactive TUI runtime orchestrator.
// Runs the sampling loop, coordinates input/render modules, and manages chart state.

const std = @import("std");
const sampler = @import("../sampler.zig");
const gc_metrics = @import("../sampler/gc_metrics.zig");
const types = @import("../types.zig");
const compact = @import("../compact/mod.zig");
const tui_state = @import("state.zig");
const terminal = @import("terminal.zig");
const input = @import("input.zig");
const render = @import("render.zig");

const UiState = tui_state.UiState;
const Peaks = tui_state.Peaks;
const TerminalInputMode = terminal.TerminalInputMode;

pub const TextRenderState = compact.TextRenderState;

pub fn writeTextFrame(writer: anytype, snapshot: types.Snapshot, state: *TextRenderState) !void {
    try compact.writeTextFrame(writer, snapshot, state, terminal.terminalCols() orelse 0);
}

pub fn run(allocator: std.mem.Allocator, writer: anytype, opts: types.Options) !void {
    const stdout_file = std.fs.File.stdout();
    const is_tty = stdout_file.isTty();
    terminal.installSignalHandlers();

    if (is_tty) {
        try writer.writeAll("\x1b[?1049h\x1b[?25l\x1b[2J\x1b[H");
    }
    defer {
        if (is_tty) {
            writer.writeAll("\x1b[0m\x1b[?25h\x1b[?1049l") catch {};
        }
    }

    var input_mode = TerminalInputMode{};
    if (is_tty) input_mode.enable();
    defer input_mode.restore();

    var sample: u64 = 0;
    var last_render_ms: i64 = std.time.milliTimestamp() - @as(i64, @intCast(opts.interval_ms));
    var runtime = types.RuntimeState{};
    var peaks = Peaks{};
    var ui = UiState{};
    ui.sample_interval_ms = if (opts.sample_interval_ms > 0) opts.sample_interval_ms else tui_state.default_tui_sample_interval_ms;
    var charts = opts.charts;
    var prev_memory_chart = charts.memory;

    while (true) {
        if (terminal.consumeInterruptRequested()) {
            ui.should_quit = true;
        }

        sample += 1;
        const snapshot = sampler.collectSnapshot(allocator, opts.app_pattern, sample, &runtime);
        try input.pollAndHandleCommands(allocator, &ui, &runtime, &charts);
        if (ui.should_quit) break;

        if (ui.reset_requested) {
            peaks = .{};
            gc_metrics.resetGcRuntime(&runtime);
            sampler.resetDiskIoRuntime(&runtime);
            render.resetMemGraph(&ui);
            ui.reset_requested = false;
        }

        if (!charts.memory and prev_memory_chart) {
            render.resetMemGraph(&ui);
        }
        prev_memory_chart = charts.memory;

        if (charts.memory) {
            render.recordMemGraphSample(&ui, snapshot);
        }

        compact.updatePeaks(&peaks, snapshot);

        const now_ms = std.time.milliTimestamp();
        if (now_ms - last_render_ms >= @as(i64, @intCast(opts.interval_ms))) {
            if (charts.memory) {
                render.advanceMemGraphFrame(&ui, snapshot);
            }
            try render.renderVisualFrame(writer, snapshot, peaks, &ui, is_tty, terminal.terminalCols() orelse 0, charts.memory);
            last_render_ms = now_ms;
        }

        if (ui.prompt_dirty) {
            try render.renderPromptArea(writer, ui, is_tty);
            ui.prompt_dirty = false;
        }

        if (opts.once) break;
        std.Thread.sleep(ui.sample_interval_ms * std.time.ns_per_ms);
    }
}
