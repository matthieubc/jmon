# jmon

A minimal, beautiful JVM monitor with auto attach and anomaly detection.

## Status

Scaffold in progress.

## Output modes

- `--output tui` for interactive mode (default on TTY)
- `--output text` for AI/shell diagnostics
- `--output json` for automation and robust parsing

## Quick examples

```bash
zig build run -- --output text --once
zig build run -- --output json --once
```
