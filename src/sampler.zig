// Compatibility shim for the sampler module.
// Re-exports the sampler entrypoint from the split sampler directory.

const mod = @import("sampler/mod.zig");

pub const collectSnapshot = mod.collectSnapshot;
pub const resetDiskIoRuntime = mod.resetDiskIoRuntime;
