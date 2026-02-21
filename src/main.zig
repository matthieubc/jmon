const std = @import("std");

const OutputFormat = enum {
    tui,
    text,
    json,
};

const Options = struct {
    output: ?OutputFormat = null,
    once: bool = false,
    interval_ms: u64 = 1000,
    app_pattern: []const u8 = "Application",
};

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const stderr = std.fs.File.stderr().deprecatedWriter();
    const stdout = std.fs.File.stdout().deprecatedWriter();

    const opts = parseArgs(args, stderr) catch |err| switch (err) {
        error.ShowHelp => return,
        else => return err,
    };

    const output = opts.output orelse if (std.fs.File.stdout().isTty()) OutputFormat.tui else OutputFormat.text;
    switch (output) {
        .tui => {
            try stdout.writeAll("jmon: tui mode is not implemented yet\n");
            try stdout.writeAll("use --output text or --output json for ai-friendly diagnostics\n");
        },
        .text => try runTextMode(stdout, opts),
        .json => try runJsonMode(stdout, opts),
    }
}

fn parseArgs(args: []const [:0]u8, stderr: anytype) !Options {
    var opts = Options{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try printUsage(stderr);
            return error.ShowHelp;
        }

        if (std.mem.eql(u8, arg, "--once")) {
            opts.once = true;
            continue;
        }

        if (std.mem.startsWith(u8, arg, "--output=")) {
            opts.output = try parseOutput(arg["--output=".len..]);
            continue;
        }
        if (std.mem.eql(u8, arg, "--output")) {
            i += 1;
            if (i >= args.len) return error.MissingOutputValue;
            opts.output = try parseOutput(args[i]);
            continue;
        }

        if (std.mem.startsWith(u8, arg, "--interval-ms=")) {
            opts.interval_ms = try parseInterval(arg["--interval-ms=".len..]);
            continue;
        }
        if (std.mem.eql(u8, arg, "--interval-ms")) {
            i += 1;
            if (i >= args.len) return error.MissingIntervalValue;
            opts.interval_ms = try parseInterval(args[i]);
            continue;
        }

        if (std.mem.startsWith(u8, arg, "--app=")) {
            opts.app_pattern = arg["--app=".len..];
            continue;
        }
        if (std.mem.eql(u8, arg, "--app")) {
            i += 1;
            if (i >= args.len) return error.MissingAppValue;
            opts.app_pattern = args[i];
            continue;
        }

        try stderr.print("error: unknown option '{s}'\n", .{arg});
        try printUsage(stderr);
        return error.InvalidOption;
    }
    return opts;
}

fn parseOutput(value: []const u8) !OutputFormat {
    if (std.mem.eql(u8, value, "tui")) return .tui;
    if (std.mem.eql(u8, value, "text")) return .text;
    if (std.mem.eql(u8, value, "json")) return .json;
    return error.InvalidOutputFormat;
}

fn parseInterval(value: []const u8) !u64 {
    const n = std.fmt.parseInt(u64, value, 10) catch return error.InvalidInterval;
    if (n == 0) return error.InvalidInterval;
    return n;
}

fn printUsage(writer: anytype) !void {
    try writer.writeAll(
        \\usage: jmon [options]
        \\  --output <tui|text|json>  output format (default: tui on tty, text otherwise)
        \\  --once                    emit one sample and exit
        \\  --interval-ms <n>         sampling interval in ms (default: 1000)
        \\  --app <pattern>           app pattern to match (default: Application)
        \\  --help                    show this help
        \\
    );
}

fn runTextMode(writer: anytype, opts: Options) !void {
    var sample: u64 = 0;
    while (true) {
        sample += 1;
        try writer.print(
            "ts_unix_s={d} sample={d} state=SEARCHING app_pattern={s} pid=- mem_used_bytes=0 mem_committed_bytes=0 mem_max_bytes=0 cpu_total_pct=0 gc_time_pct=0 io_disk_bps=0 io_net_bps=0 finding_count=0\n",
            .{ std.time.timestamp(), sample, opts.app_pattern },
        );
        if (opts.once) break;
        std.Thread.sleep(opts.interval_ms * std.time.ns_per_ms);
    }
}

fn runJsonMode(writer: anytype, opts: Options) !void {
    var sample: u64 = 0;
    while (true) {
        sample += 1;
        try writer.print("{{\"ts_unix_s\":{d},\"sample\":{d},\"state\":\"SEARCHING\",\"app_pattern\":", .{
            std.time.timestamp(),
            sample,
        });
        try writeJsonString(writer, opts.app_pattern);
        try writer.writeAll(",\"pid\":null,\"mem_used_bytes\":0,\"mem_committed_bytes\":0,\"mem_max_bytes\":0,\"cpu_total_pct\":0,\"gc_time_pct\":0,\"io_disk_bps\":0,\"io_net_bps\":0,\"finding_count\":0}\n");
        if (opts.once) break;
        std.Thread.sleep(opts.interval_ms * std.time.ns_per_ms);
    }
}

fn writeJsonString(writer: anytype, value: []const u8) !void {
    try writer.writeAll("\"");
    for (value) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => try writer.writeByte(c),
        }
    }
    try writer.writeAll("\"");
}
