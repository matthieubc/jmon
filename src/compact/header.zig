// Compact header renderer.
// Formats the jmon status line with attach state, PID, and attached application name.

const types = @import("../types.zig");
const fmtu = @import("format.zig");

pub fn renderHeaderLine(writer: anytype, snapshot: types.Snapshot, is_tty: bool) !void {
    if (is_tty) try writer.writeAll("\x1b[1m");
    try writer.writeAll("🧞 jmon");
    if (is_tty) try writer.writeAll("\x1b[0m");
    try writer.print("  state={s}", .{@tagName(snapshot.state)});
    try writer.writeAll("  pid=");
    if (snapshot.pid) |pid| {
        try writer.print("{d}", .{pid});
    } else {
        try writer.writeAll("-");
    }
    try writer.writeAll("  attached=");
    if (snapshot.attached_app) |app_name| {
        try fmtu.writeQuoted(writer, app_name);
    } else {
        try writer.writeAll("-");
    }
}
