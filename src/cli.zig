// Command-line parsing for jmon.
// Maps CLI flags to runtime options and validates user input values.

const clap = @import("clap");
const std = @import("std");
const types = @import("types.zig");
const chart_parse = @import("charts.zig");

const params = clap.parseParamsComptime(
    \\-h, --help              Display this help and exit.
    \\--text                  Emit compact text snapshot output for AI and shell tools.
    \\--once                  Emit one sample and exit.
    \\--interval <u64>        Sampling interval in milliseconds. Default: 1000.
    \\--sample <u64>          Internal TUI sampling interval in milliseconds. Default: 500.
    \\--app <str>             Pattern to match in jcmd output. Default: Application.
    \\--docker <str>          Attach to a JVM running inside the specified Docker container.
    \\--db-agent <str>        Path to the jmon Java DB agent JAR for dynamic attach.
    \\--chart <str>           Comma-separated charts to show (memory,cpu,io). Default: none.
    \\
);

pub const ParsedOptions = struct {
    options: types.Options,
    app_pattern_owned: []u8,
    docker_container_owned: ?[]u8,
    db_agent_jar_owned: ?[]u8,

    pub fn deinit(self: ParsedOptions, allocator: std.mem.Allocator) void {
        allocator.free(self.app_pattern_owned);
        if (self.docker_container_owned) |path| allocator.free(path);
        if (self.db_agent_jar_owned) |path| allocator.free(path);
    }
};

pub fn parseOptions(allocator: std.mem.Allocator, io: std.Io, args: std.process.Args) !?ParsedOptions {
    var stderr_buffer: [1024]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writerStreaming(io, &stderr_buffer);
    defer stderr_writer.flush() catch {};
    const stderr = &stderr_writer.interface;

    var diag = clap.Diagnostic{};
    var res = clap.parse(clap.Help, &params, clap.parsers.default, args, .{
        .diagnostic = &diag,
        .allocator = allocator,
    }) catch |err| {
        try diag.reportToFile(io, .stderr(), err);
        return err;
    };
    defer res.deinit();

    if (res.args.help != 0) {
        try printHelp(io);
        return null;
    }

    const interval_ms = res.args.interval orelse 1000;
    if (interval_ms == 0) {
        try stderr.writeAll("error: --interval must be > 0\n");
        return error.InvalidInterval;
    }
    const sample_interval_ms = res.args.sample orelse 500;
    if (sample_interval_ms == 0) {
        try stderr.writeAll("error: --sample must be > 0\n");
        return error.InvalidSampleInterval;
    }

    const charts = try parseCharts(stderr, res.args.chart orelse "");
    const app_pattern = res.args.app orelse "Application";
    const app_pattern_owned = try allocator.dupe(u8, app_pattern);
    const docker_container_owned = if (res.args.docker) |container|
        try allocator.dupe(u8, container)
    else
        null;
    const db_agent_jar_owned = if (res.args.@"db-agent") |path|
        try allocator.dupe(u8, path)
    else
        null;

    return .{
        .options = .{
            .output = if (res.args.text != 0) .text else .tui,
            .once = res.args.once != 0,
            .interval_ms = interval_ms,
            .sample_interval_ms = sample_interval_ms,
            .app_pattern = app_pattern_owned,
            .docker_container = docker_container_owned,
            .db_agent_jar = db_agent_jar_owned,
            .charts = charts,
        },
        .app_pattern_owned = app_pattern_owned,
        .docker_container_owned = docker_container_owned,
        .db_agent_jar_owned = db_agent_jar_owned,
    };
}

fn parseCharts(stderr: anytype, raw: []const u8) !types.ChartOptions {
    const parsed = chart_parse.parseList(raw);
    if (parsed.invalid) |part| {
        try stderr.print("error: unknown chart '{s}' (allowed: memory,cpu,io)\n", .{part});
        return error.InvalidChart;
    }
    return parsed.charts;
}

fn printHelp(io: std.Io) !void {
    const stdout_file = std.Io.File.stdout();
    var buf: [2048]u8 = undefined;
    var writer = stdout_file.writerStreaming(io, &buf);
    const stdout = &writer.interface;

    if (try stdout_file.isTty(io)) {
        try stdout.writeAll("\x1b[1mjmon\x1b[0m - Minimal JVM monitor with auto attach and anomaly detection\n\n");
    } else {
        try stdout.writeAll("jmon - Minimal JVM monitor with auto attach and anomaly detection\n\n");
    }
    try stdout.writeAll("Usage: jmon [OPTIONS]\n\n");
    try stdout.writeAll("Options:\n");

    try clap.help(stdout, clap.Help, &params, .{
        .description_on_new_line = false,
        .description_indent = 2,
        .indent = 2,
        .spacing_between_parameters = 0,
    });
    try stdout.flush();
}
