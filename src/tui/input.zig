// Prompt input and command handling for the TUI.
// Parses typed commands, ignores escape-sequence noise, and updates runtime actions.

const std = @import("std");
const types = @import("../types.zig");
const charts_mod = @import("../charts.zig");
const tui_state = @import("state.zig");
const jvm_commands = @import("../jvm/commands.zig");

const UiState = tui_state.UiState;
const max_status_len = tui_state.max_status_len;

pub fn pollAndHandleCommands(
    allocator: std.mem.Allocator,
    ui: *UiState,
    runtime: *types.RuntimeState,
    charts: *types.ChartOptions,
) !void {
    const posix = std.posix;
    var fds = [_]posix.pollfd{.{
        .fd = posix.STDIN_FILENO,
        .events = posix.POLL.IN,
        .revents = 0,
    }};

    const ready = posix.poll(fds[0..], 0) catch return;
    if (ready == 0) return;
    if ((fds[0].revents & posix.POLL.IN) == 0) return;

    var buf: [256]u8 = undefined;
    const n = posix.read(posix.STDIN_FILENO, &buf) catch |err| switch (err) {
        error.WouldBlock => return,
        else => return,
    };
    if (n == 0) return;

    for (buf[0..n]) |c| {
        if (consumeEscapeSequenceByte(ui, c)) continue;
        switch (c) {
            0x03 => {
                ui.should_quit = true;
                ui.prompt_dirty = true;
            },
            '\r', '\n' => {
                try handleCommandLine(allocator, ui, runtime, charts);
                ui.input_len = 0;
                ui.prompt_dirty = true;
            },
            0x7f, 0x08 => {
                if (ui.input_len > 0) {
                    ui.input_len -= 1;
                    ui.prompt_dirty = true;
                }
            },
            else => {
                if (c < 0x20) continue;
                if (ui.input_len < ui.input_buf.len) {
                    ui.input_buf[ui.input_len] = c;
                    ui.input_len += 1;
                    ui.prompt_dirty = true;
                }
            },
        }
    }
}

fn consumeEscapeSequenceByte(ui: *UiState, c: u8) bool {
    switch (ui.escape_seq_state) {
        .none => {
            if (c == 0x1b) {
                ui.escape_seq_state = .esc;
                ui.prompt_dirty = true;
                return true;
            }
            return false;
        },
        .esc => {
            if (c == '[' or c == 'O') {
                ui.escape_seq_state = .csi;
            } else {
                ui.escape_seq_state = .none;
            }
            return true;
        },
        .csi => {
            if (c >= 0x40 and c <= 0x7e) {
                ui.escape_seq_state = .none;
            }
            return true;
        },
    }
}

fn handleCommandLine(
    allocator: std.mem.Allocator,
    ui: *UiState,
    runtime: *types.RuntimeState,
    charts: *types.ChartOptions,
) !void {
    const line = std.mem.trim(u8, ui.input_buf[0..ui.input_len], " \t");
    if (line.len == 0) return;

    if (std.ascii.eqlIgnoreCase(line, "q") or std.ascii.eqlIgnoreCase(line, "quit")) {
        ui.should_quit = true;
        setStatus(ui, "quit requested");
        return;
    }

    if (std.ascii.eqlIgnoreCase(line, "help")) {
        setStatus(ui, "commands: help | gc | reset | chart [off|memory,cpu,io] | q");
        return;
    }

    if (std.ascii.eqlIgnoreCase(line, "gc")) {
        const pid = runtime.attached_pid orelse {
            setStatus(ui, "gc failed: no attached jvm");
            return;
        };
        const ok = jvm_commands.runFullGc(allocator, pid);
        if (ok) {
            var msg: [max_status_len]u8 = undefined;
            const s = std.fmt.bufPrint(&msg, "gc requested on pid {d}", .{pid}) catch "gc requested";
            setStatusSlice(ui, s);
        } else {
            var msg: [max_status_len]u8 = undefined;
            const s = std.fmt.bufPrint(&msg, "gc failed on pid {d}", .{pid}) catch "gc failed";
            setStatusSlice(ui, s);
        }
        return;
    }

    if (std.ascii.eqlIgnoreCase(line, "reset")) {
        ui.reset_requested = true;
        setStatus(ui, "peaks and gc counters reset");
        return;
    }

    if (std.ascii.startsWithIgnoreCase(line, "chart")) {
        try handleChartCommand(ui, charts, line);
        return;
    }

    setStatus(ui, "unknown command (try: help)");
}

fn handleChartCommand(ui: *UiState, charts: *types.ChartOptions, line: []const u8) !void {
    const rest = if (line.len > "chart".len) std.mem.trim(u8, line["chart".len..], " \t") else "";
    if (rest.len == 0 or std.ascii.eqlIgnoreCase(rest, "show")) {
        var msg: [max_status_len]u8 = undefined;
        const active = formatChartList(&msg, charts.*);
        setStatusSlice(ui, active);
        return;
    }

    if (std.ascii.eqlIgnoreCase(rest, "off") or std.ascii.eqlIgnoreCase(rest, "none")) {
        charts.* = .{};
        setStatus(ui, "charts: none");
        return;
    }

    const parsed = charts_mod.parseList(rest);
    if (parsed.invalid) |bad| {
        var msg: [max_status_len]u8 = undefined;
        const s = std.fmt.bufPrint(&msg, "chart error: unknown '{s}' (allowed: memory,cpu,io)", .{bad}) catch "chart error";
        setStatusSlice(ui, s);
        return;
    }
    charts.* = parsed.charts;
    var msg: [max_status_len]u8 = undefined;
    const active = formatChartList(&msg, charts.*);
    setStatusSlice(ui, active);
}

fn formatChartList(buf: []u8, charts: types.ChartOptions) []const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    const w = fbs.writer();
    w.writeAll("charts: ") catch return "charts";
    var any = false;
    if (charts.memory) {
        w.writeAll("memory") catch {};
        any = true;
    }
    if (charts.cpu) {
        if (any) w.writeAll(",") catch {};
        w.writeAll("cpu") catch {};
        any = true;
    }
    if (charts.io) {
        if (any) w.writeAll(",") catch {};
        w.writeAll("io") catch {};
        any = true;
    }
    if (!any) w.writeAll("none") catch {};
    return fbs.getWritten();
}

fn setStatus(ui: *UiState, text: []const u8) void {
    setStatusSlice(ui, text);
}

fn setStatusSlice(ui: *UiState, text: []const u8) void {
    const n = @min(text.len, ui.status_buf.len);
    if (n > 0) std.mem.copyForwards(u8, ui.status_buf[0..n], text[0..n]);
    ui.status_len = n;
    ui.prompt_dirty = true;
}
