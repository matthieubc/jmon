// jstat GC probe and parser.
// Reads jstat -gc output and converts localized numeric fields into typed GC metrics.

const std = @import("std");

pub const JstatGc = struct {
    heap_used_bytes: u64,
    heap_committed_bytes: u64,
    old_used_bytes: u64,
    old_committed_bytes: u64,
    ygc: u64,
    fgc: u64,
    gct_s: f64,
};

pub fn readJstatGc(allocator: std.mem.Allocator, pid: u32) ?JstatGc {
    var pid_buf: [20]u8 = undefined;
    const pid_str = std.fmt.bufPrint(&pid_buf, "{d}", .{pid}) catch return null;
    const argv = [_][]const u8{ "jstat", "-gc", pid_str };
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv[0..],
        .max_output_bytes = 64 * 1024,
    }) catch return null;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (!isExit0(result.term)) return null;
    return parseJstatGc(result.stdout);
}

pub fn parseLocalizedFloat(raw: []const u8) ?f64 {
    const s = std.mem.trim(u8, raw, " \t\r\n");
    if (s.len == 0) return null;
    if (std.fmt.parseFloat(f64, s)) |v| return v else |_| {}
    if (std.mem.indexOfScalar(u8, s, ',') == null) return null;

    var buf: [64]u8 = undefined;
    if (s.len > buf.len) return null;
    std.mem.copyForwards(u8, buf[0..s.len], s);
    for (buf[0..s.len]) |*c| {
        if (c.* == ',') c.* = '.';
    }
    return std.fmt.parseFloat(f64, buf[0..s.len]) catch null;
}

fn parseJstatGc(output: []const u8) ?JstatGc {
    var lines = std.mem.tokenizeScalar(u8, output, '\n');
    var header_line: ?[]const u8 = null;
    var values_line: ?[]const u8 = null;

    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r");
        if (line.len == 0) continue;
        if (header_line == null) {
            header_line = line;
            continue;
        }
        values_line = line;
        break;
    }

    const headers = header_line orelse return null;
    const values = values_line orelse return null;

    var header_tokens: [64][]const u8 = undefined;
    var value_tokens: [64][]const u8 = undefined;
    var hlen: usize = 0;
    var vlen: usize = 0;

    var h_it = std.mem.tokenizeAny(u8, headers, " \t");
    while (h_it.next()) |tok| {
        if (hlen >= header_tokens.len) return null;
        header_tokens[hlen] = tok;
        hlen += 1;
    }

    var v_it = std.mem.tokenizeAny(u8, values, " \t");
    while (v_it.next()) |tok| {
        if (vlen >= value_tokens.len) return null;
        value_tokens[vlen] = tok;
        vlen += 1;
    }

    const headers_slice = header_tokens[0..hlen];
    const values_slice = value_tokens[0..vlen];

    const i_s0c = findColumn(headers_slice, "S0C") orelse return null;
    const i_s1c = findColumn(headers_slice, "S1C") orelse return null;
    const i_ec = findColumn(headers_slice, "EC") orelse return null;
    const i_oc = findColumn(headers_slice, "OC") orelse return null;
    const i_s0u = findColumn(headers_slice, "S0U") orelse return null;
    const i_s1u = findColumn(headers_slice, "S1U") orelse return null;
    const i_eu = findColumn(headers_slice, "EU") orelse return null;
    const i_ou = findColumn(headers_slice, "OU") orelse return null;
    const i_ygc = findColumn(headers_slice, "YGC") orelse return null;
    const i_fgc = findColumn(headers_slice, "FGC") orelse return null;
    const i_gct = findColumn(headers_slice, "GCT") orelse return null;

    const s0c = parseFloatAt(values_slice, i_s0c) orelse return null;
    const s1c = parseFloatAt(values_slice, i_s1c) orelse return null;
    const ec = parseFloatAt(values_slice, i_ec) orelse return null;
    const oc = parseFloatAt(values_slice, i_oc) orelse return null;
    const s0u = parseFloatAt(values_slice, i_s0u) orelse return null;
    const s1u = parseFloatAt(values_slice, i_s1u) orelse return null;
    const eu = parseFloatAt(values_slice, i_eu) orelse return null;
    const ou = parseFloatAt(values_slice, i_ou) orelse return null;
    const ygc = parseFloatAt(values_slice, i_ygc) orelse return null;
    const fgc = parseFloatAt(values_slice, i_fgc) orelse return null;
    const gct = parseFloatAt(values_slice, i_gct) orelse return null;

    return .{
        .heap_used_bytes = kbToBytes(s0u + s1u + eu + ou),
        .heap_committed_bytes = kbToBytes(s0c + s1c + ec + oc),
        .old_used_bytes = kbToBytes(ou),
        .old_committed_bytes = kbToBytes(oc),
        .ygc = toCount(ygc),
        .fgc = toCount(fgc),
        .gct_s = if (gct < 0) 0 else gct,
    };
}

fn isExit0(term: std.process.Child.Term) bool {
    return switch (term) {
        .Exited => |code| code == 0,
        else => false,
    };
}

fn findColumn(columns: []const []const u8, name: []const u8) ?usize {
    for (columns, 0..) |col, i| {
        if (std.mem.eql(u8, col, name)) return i;
    }
    return null;
}

fn parseFloatAt(tokens: []const []const u8, index: usize) ?f64 {
    if (index >= tokens.len) return null;
    return parseLocalizedFloat(tokens[index]);
}

fn kbToBytes(kb: f64) u64 {
    if (kb <= 0) return 0;
    const bytes = kb * 1024.0;
    const max_u64_f = @as(f64, @floatFromInt(std.math.maxInt(u64)));
    if (bytes >= max_u64_f) return std.math.maxInt(u64);
    return @as(u64, @intFromFloat(bytes));
}

fn toCount(value: f64) u64 {
    if (value <= 0) return 0;
    return @as(u64, @intFromFloat(@floor(value)));
}
