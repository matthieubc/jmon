const std = @import("std");
const output = @import("output.zig");
const sampler = @import("sampler.zig");
const tui = @import("tui.zig");
const types = @import("types.zig");

pub fn run(allocator: std.mem.Allocator, writer: anytype, opts: types.Options) !void {
    switch (opts.output) {
        .tui => try tui.run(allocator, writer, opts),
        .text, .json => try runSampling(allocator, writer, opts),
    }
}

fn runSampling(allocator: std.mem.Allocator, writer: anytype, opts: types.Options) !void {
    var sample: u64 = 0;
    var runtime = types.RuntimeState{};
    while (true) {
        sample += 1;
        const snapshot = sampler.collectSnapshot(allocator, opts.app_pattern, sample, &runtime);
        switch (opts.output) {
            .text => try output.writeTextSample(writer, snapshot),
            .json => try output.writeJsonSample(writer, snapshot),
            .tui => unreachable,
        }
        if (opts.once) break;
        std.Thread.sleep(opts.interval_ms * std.time.ns_per_ms);
    }
}
