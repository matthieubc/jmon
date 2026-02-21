# jmon

A minimal, beautiful JVM monitor with auto attach and anomaly detection.

## Status

Scaffold in progress.

## Output modes

- TUI is default output mode.
- `--text` for AI/shell diagnostics.
- `--json` for automation and robust parsing.

## Quick examples

```bash
zig build run -- --text --once
zig build run -- --json --once
```
