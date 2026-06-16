// Top-level application runner for jmon modes.
// Dispatches TUI or text output loops and coordinates snapshot collection cadence.

const std = @import("std");
const sampler = @import("sampler.zig");
const tui = @import("tui.zig");
const types = @import("types.zig");

pub fn run(allocator: std.mem.Allocator, io: std.Io, writer: anytype, opts: types.Options) !void {
    switch (opts.output) {
        .tui => try tui.run(allocator, io, writer, opts),
        .text => try runSampling(allocator, io, writer, opts),
    }
}

fn runSampling(allocator: std.mem.Allocator, io: std.Io, writer: anytype, opts: types.Options) !void {
    var sample: u64 = 0;
    var runtime = types.RuntimeState{};
    var text_state = tui.TextRenderState{};
    var emitted_non_attached_since_last_attach = false;
    while (true) {
        sample += 1;
        const snapshot = sampler.collectSnapshot(allocator, io, opts.app_pattern, opts.docker_container, opts.db_agent_jar, sample, &runtime);
        const is_attached = snapshot.state == .ATTACHED;
        const should_emit = if (opts.once)
            true
        else if (is_attached)
            true
        else
            !emitted_non_attached_since_last_attach;

        if (should_emit) {
            switch (opts.output) {
                .text => try tui.writeTextFrame(writer, snapshot, &text_state),
                .tui => unreachable,
            }
        }
        if (is_attached) emitted_non_attached_since_last_attach = false else if (should_emit) emitted_non_attached_since_last_attach = true;
        if (opts.once) break;
        if (should_emit) try writer.writeAll("\n");
        try std.Io.sleep(io, .fromNanoseconds(opts.interval_ms * std.time.ns_per_ms), .awake);
    }
}
