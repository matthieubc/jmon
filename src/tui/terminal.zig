// Terminal mode and signal handling for the TUI.
// Manages raw input mode, terminal size lookup, and interrupt flag handling.

const std = @import("std");
const c_tui = @cImport({
    @cInclude("termios.h");
    @cInclude("unistd.h");
    @cInclude("signal.h");
});

pub const TerminalInputMode = struct {
    enabled: bool = false,
    saved: c_tui.struct_termios = undefined,

    pub fn enable(self: *TerminalInputMode) void {
        if (c_tui.isatty(c_tui.STDIN_FILENO) != 1) return;
        if (c_tui.tcgetattr(c_tui.STDIN_FILENO, &self.saved) != 0) return;

        var raw = self.saved;
        raw.c_lflag &= ~(@as(@TypeOf(raw.c_lflag), c_tui.ECHO) |
            @as(@TypeOf(raw.c_lflag), c_tui.ICANON) |
            @as(@TypeOf(raw.c_lflag), c_tui.ISIG));
        raw.c_cc[c_tui.VMIN] = 0;
        raw.c_cc[c_tui.VTIME] = 0;

        if (c_tui.tcsetattr(c_tui.STDIN_FILENO, c_tui.TCSANOW, &raw) != 0) return;
        self.enabled = true;
    }

    pub fn restore(self: *TerminalInputMode) void {
        if (!self.enabled) return;
        _ = c_tui.tcsetattr(c_tui.STDIN_FILENO, c_tui.TCSANOW, &self.saved);
        self.enabled = false;
    }
};

var interrupt_requested = std.atomic.Value(u8).init(0);

fn onSignal(_: c_int) callconv(.c) void {
    interrupt_requested.store(1, .seq_cst);
}

pub fn installSignalHandlers() void {
    _ = c_tui.signal(c_tui.SIGINT, onSignal);
    _ = c_tui.signal(c_tui.SIGTERM, onSignal);
}

pub fn consumeInterruptRequested() bool {
    return interrupt_requested.swap(0, .seq_cst) != 0;
}

pub fn terminalCols() ?usize {
    const posix = std.posix;
    var wsz: posix.winsize = .{
        .row = 0,
        .col = 0,
        .xpixel = 0,
        .ypixel = 0,
    };

    const rc = posix.system.ioctl(posix.STDOUT_FILENO, posix.T.IOCGWINSZ, @intFromPtr(&wsz));
    if (posix.errno(rc) != .SUCCESS or wsz.col == 0) return null;
    return @as(usize, wsz.col);
}
