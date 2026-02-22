#!/bin/sh
set -eu

usage() {
  cat <<'EOF'
Usage: jvm-mem-snapshot.sh <pid>

Prints:
  - OS process memory (RSS, VSZ, etc.)
  - JVM heap views (jstat/jcmd)
  - JVM native/off-heap view (NMT if enabled)

Examples:
  ./scripts/jvm-mem-snapshot.sh 99109
EOF
}

if [ "${1-}" = "" ] || [ "${1-}" = "-h" ] || [ "${1-}" = "--help" ]; then
  usage
  exit 0
fi

PID="$1"

case "$PID" in
  *[!0-9]*|'') echo "error: pid must be numeric" >&2; exit 1 ;;
esac

if ! kill -0 "$PID" 2>/dev/null; then
  echo "error: pid $PID not found or not accessible" >&2
  exit 1
fi

have() { command -v "$1" >/dev/null 2>&1; }

section() {
  printf '\n== %s ==\n' "$1"
}

run_cmd() {
  printf '$ %s\n' "$*"
  "$@" 2>&1 || true
}

OS="$(uname -s 2>/dev/null || echo unknown)"

section "Process Summary"
if [ "$OS" = "Darwin" ]; then
  run_cmd ps -p "$PID" -o pid,ppid,%cpu,%mem,rss,vsz,etime,command
else
  run_cmd ps -p "$PID" -o pid,ppid,%cpu,%mem,rss,vsz,etime,cmd
fi

if [ "$OS" = "Darwin" ]; then
  section "macOS Process Memory (vmmap summary)"
  if have vmmap; then
    run_cmd vmmap -summary "$PID"
  else
    echo "vmmap not found"
  fi
elif [ "$OS" = "Linux" ]; then
  section "Linux /proc Status Memory"
  if [ -r "/proc/$PID/status" ]; then
    printf '$ %s\n' "grep Vm*/Rss* from /proc/$PID/status"
    grep -E 'VmRSS|VmHWM|VmSize|RssAnon|RssFile|RssShmem' "/proc/$PID/status" || true
  else
    echo "/proc/$PID/status not readable"
  fi

  section "Linux pmap Summary"
  if have pmap; then
    printf '$ %s\n' "pmap -x $PID | tail -1"
    pmap -x "$PID" 2>&1 | tail -1 || true
  else
    echo "pmap not found"
  fi
fi

section "JVM Heap (jstat/jcmd)"
if have jstat; then
  run_cmd jstat -gc "$PID"
else
  echo "jstat not found"
fi

if have jcmd; then
  run_cmd jcmd "$PID" GC.heap_info
else
  echo "jcmd not found"
fi

section "JVM Native Memory / Off-Heap (NMT)"
if have jcmd; then
  run_cmd jcmd "$PID" VM.native_memory summary
  echo
  echo "If this says NMT is not enabled, restart the JVM with:"
  echo "  -XX:NativeMemoryTracking=summary"
  echo "or:"
  echo "  -XX:NativeMemoryTracking=detail"
else
  echo "jcmd not found"
fi

section "JVM Perf Counters (direct/mapped buffer hints)"
if have jcmd; then
  printf '$ %s\n' "jcmd $PID PerfCounter.print | egrep 'DirectBuffer|MappedByteBuffer|sun.nio'"
  jcmd "$PID" PerfCounter.print 2>&1 | egrep 'DirectBuffer|MappedByteBuffer|sun.nio' || true
else
  echo "jcmd not found"
fi

