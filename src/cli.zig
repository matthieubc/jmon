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
    \\--chart <str>           Comma-separated charts to show (memory,cpu,io). Default: none.
    \\
);

pub const ParsedOptions = struct {
    options: types.Options,
    app_pattern_owned: []u8,

    pub fn deinit(self: ParsedOptions, allocator: std.mem.Allocator) void {
        allocator.free(self.app_pattern_owned);
    }
};

pub fn parseOptions(allocator: std.mem.Allocator) !?ParsedOptions {
    const stderr = std.fs.File.stderr().deprecatedWriter();

    var diag = clap.Diagnostic{};
    var res = clap.parse(clap.Help, &params, clap.parsers.default, .{
        .diagnostic = &diag,
        .allocator = allocator,
    }) catch |err| {
        try diag.reportToFile(.stderr(), err);
        return err;
    };
    defer res.deinit();

    if (res.args.help != 0) {
        try printHelp();
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

    return .{
        .options = .{
            .output = if (res.args.text != 0) .text else .tui,
            .once = res.args.once != 0,
            .interval_ms = interval_ms,
            .sample_interval_ms = sample_interval_ms,
            .app_pattern = app_pattern_owned,
            .charts = charts,
        },
        .app_pattern_owned = app_pattern_owned,
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

fn printHelp() !void {
    const stdout_file = std.fs.File.stdout();
    var buf: [2048]u8 = undefined;
    var writer = stdout_file.writer(&buf);

    if (stdout_file.isTty()) {
        try writer.interface.writeAll("\x1b[1mjmon\x1b[0m - Minimal JVM monitor with auto attach and anomaly detection\n\n");
    } else {
        try writer.interface.writeAll("jmon - Minimal JVM monitor with auto attach and anomaly detection\n\n");
    }
    try writer.interface.writeAll("Usage: jmon [OPTIONS]\n\n");
    try writer.interface.writeAll("Options:\n");

    try clap.help(&writer.interface, clap.Help, &params, .{
        .description_on_new_line = false,
        .description_indent = 2,
        .indent = 2,
        .spacing_between_parameters = 0,
    });
    try writer.interface.flush();
}
