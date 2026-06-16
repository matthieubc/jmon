> [!IMPORTANT] 
> WORK IN PROGRESS

# jmon

A minimal, beautiful JVM monitor with auto attach and anomaly detection.

## Status

Scaffold in progress.

## Output modes

- TUI is default output mode.
- `--text` for compact AI/shell diagnostics (same top panel content as TUI, no graph/prompt).
- `--db-agent <jar>` to auto-attach the optional Java DB metrics agent.
- `--chart memory` to enable the memory history chart in TUI (future: `cpu,io`).

## Quick examples

```bash
./agent/gradlew -p agent jar
zig build run -- --text --once
zig build run -- --chart memory
zig build run -- --text --db-agent agent/build/libs/jmon-db-agent-0.1.0.jar
```

## DB agent

- Optional: jmon still works when no DB agent is configured.
- The agent instruments JDBC `execute*` calls and writes metrics to `/tmp/jmon-db-agent-<pid>.metrics`.
- You can load the agent at JVM startup (`-javaagent`) or let jmon attach it at runtime with `--db-agent`.

```bash
java -javaagent:/absolute/path/jmon-db-agent-0.1.0.jar -jar app.jar
```
