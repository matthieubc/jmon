// Chart selection parser shared by CLI and TUI commands.
// Parses comma-separated chart names and reports invalid values.

const std = @import("std");
const types = @import("types.zig");

pub const ParseOutcome = struct {
    charts: types.ChartOptions = .{},
    invalid: ?[]const u8 = null,
};

pub fn parseList(raw: []const u8) ParseOutcome {
    var outcome = ParseOutcome{};
    const trimmed = std.mem.trim(u8, raw, " \t");
    if (trimmed.len == 0) return outcome;

    var it = std.mem.tokenizeScalar(u8, trimmed, ',');
    while (it.next()) |part_raw| {
        const part = std.mem.trim(u8, part_raw, " \t");
        if (part.len == 0) continue;
        if (std.ascii.eqlIgnoreCase(part, "memory")) {
            outcome.charts.memory = true;
            continue;
        }
        if (std.ascii.eqlIgnoreCase(part, "cpu")) {
            outcome.charts.cpu = true;
            continue;
        }
        if (std.ascii.eqlIgnoreCase(part, "io")) {
            outcome.charts.io = true;
            continue;
        }
        outcome.invalid = part;
        return outcome;
    }
    return outcome;
}
