// Compatibility shim for the split TUI module.
// Re-exports the TUI public API so existing imports keep working.

const mod = @import("tui/mod.zig");

pub const TextRenderState = mod.TextRenderState;
pub const run = mod.run;
pub const writeTextFrame = mod.writeTextFrame;
