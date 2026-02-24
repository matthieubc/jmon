> [!IMPORTANT] 
> WORK IN PROGRESS

# jmon

A minimal, beautiful JVM monitor with auto attach and anomaly detection.

## Status

Scaffold in progress.

## Output modes

- TUI is default output mode.
- `--text` for compact AI/shell diagnostics (same top panel content as TUI, no graph/prompt).
- `--chart memory` to enable the memory history chart in TUI (future: `cpu,io`).

## Quick examples

```bash
zig build run -- --text --once
zig build run -- --chart memory
```
