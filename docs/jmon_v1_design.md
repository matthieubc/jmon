# JVM monitor (jmon) - v1 design

## Goal

Create a small and beautiful CLI monitor for one JVM app, with a compact default view and an extended fullscreen mode.

Main use case: local development anomaly detection with very low overhead for both humans and AI coding tools.

## Primary requirements

- Launch as a CLI command (like `btop`).
- Search and attach to a configurable JVM app.
- If app disappears, keep running and auto-attach when it comes back.
- Compact default output with 4 bars:
  - Memory
  - CPU (split by cores)
  - GC activity
  - IO activity
- Prompt line below bars for commands and toggles.
- Support machine-friendly output for AI tooling:
  - Text line mode (`--text`)
  - JSON line mode (`--json`)
- Optional deeper memory view for overrepresented classes.
- Native support for macOS and Linux.

## Non-goals for v1

- Cluster-wide monitoring.
- Long-term storage/backend service.
- Complex dashboard layout.
- Per-process network accounting on all platforms (best effort only in v1).

## UX

### Modes

- `compact` (default):
  - Header + 4 bars + prompt.
- `wide`:
  - Same header/bars.
  - Additional panes: findings, top classes, threads, profiler summary.

### Output formats

- `tui`:
  - Interactive terminal UI with bars and prompt.
  - Default output mode.
- `text`:
  - One stable key/value line per sample.
  - Enabled by `--text`.
- `json`:
  - One JSON object per line.
  - Enabled by `--json`.

### States

- `SEARCHING`: target app not found.
- `ATTACHED`: PID found and sampled.
- `LOST`: PID disappeared, waiting for a replacement.

State transitions:

- `SEARCHING -> ATTACHED`: target process found.
- `ATTACHED -> LOST`: target process gone or sampling failed repeatedly.
- `LOST -> ATTACHED`: matching process appears again.

## Data pipeline

The monitor has four loops:

1. Discovery loop (`1s`):
   - Resolve target JVM by app pattern and PID.
2. Sample loop (`1s`):
   - Collect JVM + OS metrics.
3. Render loop (`250ms`):
   - Draw latest snapshot.
4. Input loop (event-driven):
   - Handle prompt commands.

For `text` and `json` output modes, only discovery and sampling loops are active.

If attached PID changes, watermarks and sliding windows reset.

## JVM interaction model

### Always-on lightweight sources

- `jcmd -l` or `jps -l` for discovery.
- JMX or `jcmd`/`jstat` snapshots for:
  - Heap (`used`, `committed`, `max`).
  - GC counters/time.
  - Process CPU.

### On-demand heavy sources

Only executed via prompt or anomaly trigger:

- `jcmd <pid> GC.class_histogram` for top memory classes.
- `async-profiler` for CPU/alloc/lock/live diagnostics.

## Bar definitions

All bars use:

- Current fill.
- Watermark marker `|` for max seen since attach.
- Right-side textual summary.

### 1) Memory bar

Purpose: show heap pressure quickly.

Inputs:

- `heap_used_bytes`
- `heap_committed_bytes`
- `heap_max_bytes` (0 means unknown)

Render:

- Bar width normalized to `heap_max_bytes` when known.
- Segment A (bright): `used`.
- Segment B (dim): `committed - used`.
- Segment C (empty): `max - committed`.

Watermark rule:

- Use JVM `max` as the reference ceiling.
- Do not keep extra synthetic peak in default mode.

Text:

- `<used> / <committed> (max <max>, <used_pct_of_max>%)`

### 2) CPU bar

Purpose: show both total CPU and core imbalance.

Inputs:

- `core_usage_pct[]` (0..100 for each logical core)
- `process_cpu_pct_total`

Render:

- Bar split into `N` contiguous equal sections (`N = core count`).
- Each section fill corresponds to one core usage.
- Global watermark tracks highest `process_cpu_pct_total`.
- Optional per-core watermark in wide mode.

Text:

- `total <process_cpu_pct_total>%`

### 3) GC bar

Purpose: show GC pressure, not raw counters.

Inputs:

- `delta_gc_time_ms`
- `delta_window_ms`
- `delta_young_gc_count`
- `delta_full_gc_count`

Formula:

- `gc_time_pct = clamp(100 * delta_gc_time_ms / delta_window_ms, 0, 100)`

Scale:

- 0-5% normal.
- 5-15% elevated.
- >15% warning.

Watermark:

- Peak `gc_time_pct` since attach.

Text:

- `<gc_time_pct>% gc-time / <window> ygc+<n> fgc+<n>`

### 4) IO bar

Purpose: show activity spikes and stalls.

Inputs:

- `proc_disk_read_bps`
- `proc_disk_write_bps`
- `host_net_rx_bps`
- `host_net_tx_bps`

Render:

- Combined line with two sub-bars:
  - Disk throughput (process-level where available).
  - Network throughput (host-level in v1 unless process-level backend is available).

Scale:

- Dynamic log-like scale based on rolling p95 to avoid flat bars.

Watermark:

- Peak total disk throughput and peak total network throughput since attach.

Text:

- `D <read+write>/s | N <rx+tx>/s`

## Watermark behavior

- Watermarks reset on:
  - `:reset-peaks`
  - PID change/reattach
- Watermarks persist across `compact`/`wide` mode toggles.
- Memory uses JVM max semantics; other bars track runtime peaks.

## Prompt command contract (v1, tui mode)

- `:help`
- `:q`
- `:mode compact`
- `:mode wide`
- `:reset-peaks`
- `:pause`
- `:resume`
- `:topmem [n]`
- `:threads [n]`
- `:gc`
- `:prof cpu <duration>`
- `:prof alloc <duration>`
- `:prof live <duration>`
- `:prof lock <duration>`
- `:prof status`
- `:prof stop`
- `:auto on`
- `:auto off`
- `:auto rules`
- `:findings`

Durations accept `5s`, `10s`, `30s`, `1m`.

## AI tool integration contract (v1)

### CLI options

- `--text`
- `--json`
- `--once`
- `--interval <n>`
- `--app <pattern>`

### Text line schema

Each sample is one line with stable keys:

- `ts_unix_s`
- `sample`
- `state`
- `app_pattern`
- `pid`
- `mem_used_bytes`
- `mem_committed_bytes`
- `mem_max_bytes`
- `cpu_total_pct`
- `gc_time_pct`
- `io_disk_bps`
- `io_net_bps`
- `finding_count`

### JSON line schema

Same fields as text mode, serialized as one JSON object per line.

### Behavior rules

- Never render ANSI colors in `text` or `json` modes.
- Never require prompt interaction in `text` or `json` modes.
- `--once` emits exactly one sample and exits with code `0`.
- On recoverable sampling errors, emit a sample with `state=LOST` and continue.

## Async-profiler integration

### Usage model

- Manual commands through prompt.
- Automatic short captures only when rule engine triggers sustained anomalies.

### Auto-trigger rules (initial)

- `CPU_HOT`:
  - Condition: process CPU > 80% for 20s.
  - Action: profile `cpu` for 10s.
- `GC_PRESSURE`:
  - Condition: GC time > 15% for 30s or repeated full GCs.
  - Action: profile `alloc` for 10s.
- `LEAK_TREND`:
  - Condition: post-GC heap floor increasing over last 5 full windows.
  - Action: profile `live` for 15s plus class histogram.
- `LOCK_CONTENTION`:
  - Condition: blocked threads above threshold for 20s.
  - Action: profile `lock` for 10s.

### Guardrails

- One profiler session at a time.
- Cooldown per rule: default `180s`.
- Global profile budget: default `30s` per `10m`.
- Minimum attach stability before auto-profile: `60s`.

## Cross-platform backend design

### Shared interfaces

- `DiscoveryBackend`
- `JvmMetricsBackend`
- `PlatformMetricsBackend`
- `ProfilerBackend`

### Linux backend

- CPU/core/process: `/proc/stat`, `/proc/<pid>/task/*/stat`
- Process disk IO: `/proc/<pid>/io`
- Host network: `/proc/net/dev`

### macOS backend

- CPU/core: `host_processor_info`
- Process/thread CPU: `task_threads` + `thread_info`
- Process disk IO: `proc_pid_rusage`
- Host network: `ifdata`/sysctl APIs

## Configuration (v1)

`~/.config/jmon/config.toml`:

```toml
app_pattern = "Application"
mode = "compact"
output = "auto"
sample_interval_ms = 1000
render_interval_ms = 250

[auto]
enabled = true
cooldown_seconds = 180
budget_seconds = 30
budget_window_seconds = 600
min_attach_stable_seconds = 60

[thresholds]
cpu_hot_pct = 80
cpu_hot_sustain_seconds = 20
gc_pressure_pct = 15
gc_pressure_sustain_seconds = 30
```

## Language options for this design

### C++

- Pros: closest to `btop` style/perf profile, mature terminal stacks.
- Cons: highest implementation complexity and safety cost.

### Rust

- Pros: native performance with memory safety, very good TUI velocity.
- Cons: more compiler/lifetime overhead while coding.

### Zig

- Pros: lightweight native binaries, strong low-level control.
- Cons: less TUI ecosystem maturity, more custom plumbing.

Decision guideline:

- Pick C++ when visual/perf parity with `btop` is the top priority.
- Pick Rust when delivery speed + reliability are primary.
- Pick Zig when low-level control and small binary footprint dominate.

## Suggested v1 milestones

1. Skeleton:
   - State machine + discovery + compact UI frame + prompt.
2. Metrics:
   - All 4 bars with watermarks and cross-platform backends.
3. Commands:
   - `:mode`, `:reset-peaks`, `:topmem`, `:gc`, `:threads`.
4. Profiler:
   - Manual async-profiler commands.
5. Auto-detect:
   - Rule engine + guarded auto-trigger + findings pane.

## Acceptance criteria (v1)

- Starts as `jmon`.
- Finds target JVM by pattern and auto-reattaches after restart.
- Renders compact 4-bar view with watermarks.
- Supports command prompt interactions without UI flicker.
- Runs on both macOS and Linux.
- Supports `--text --once` with stable parseable fields.
- Supports `--json --once` with one JSON object and exit code `0`.
- Can trigger async-profiler manually.
- Can auto-detect at least `CPU_HOT` and `GC_PRESSURE` with cooldown/budget limits.
