package io.jmon.dbagent;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.AtomicMoveNotSupportedException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.nio.file.StandardOpenOption;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;

final class MetricsExporter {
    private static final int MAX_DATASOURCES = 4;

    private final MetricsRegistry registry;
    private final Path outputPath;
    private final long pid;
    private final int intervalMs;
    private final ScheduledExecutorService scheduler;
    private final AtomicBoolean started = new AtomicBoolean(false);

    MetricsExporter(MetricsRegistry registry, Path outputPath, long pid, int intervalMs) {
        this.registry = registry;
        this.outputPath = outputPath;
        this.pid = pid;
        this.intervalMs = intervalMs;
        this.scheduler = Executors.newSingleThreadScheduledExecutor(runnable -> {
            final Thread thread = new Thread(runnable, "jmon-db-agent-exporter");
            thread.setDaemon(true);
            return thread;
        });
    }

    void start() {
        if (!started.compareAndSet(false, true)) {
            return;
        }
        scheduler.scheduleAtFixedRate(this::safeFlush, intervalMs, intervalMs, TimeUnit.MILLISECONDS);
    }

    void stop() {
        if (!started.get()) {
            return;
        }
        safeFlush();
        scheduler.shutdownNow();
    }

    private void safeFlush() {
        try {
            flush();
        } catch (Throwable ignored) {
        }
    }

    private void flush() throws IOException {
        final MetricsRegistry.RegistryWindow window = registry.snapshotAndReset(intervalMs, MAX_DATASOURCES);
        final String payload = toPayload(window);
        writeAtomically(payload);
    }

    private String toPayload(MetricsRegistry.RegistryWindow window) {
        final StringBuilder sb = new StringBuilder(1024);
        sb.append("version=1\n");
        sb.append("pid=").append(pid).append('\n');
        sb.append("ts_unix_s=").append(window.tsUnixSec()).append('\n');
        sb.append("interval_ms=").append(intervalMs).append('\n');

        sb.append("sql_per_sec=").append(window.sqlPerSec()).append('\n');
        sb.append("errors_per_sec=").append(window.errorsPerSec()).append('\n');
        sb.append("in_flight=").append(window.inFlight()).append('\n');
        sb.append("lat_avg_ms_x10=").append(window.latAvgMsX10()).append('\n');
        sb.append("lat_p95_ms_x10=").append(window.latP95MsX10()).append('\n');
        sb.append("lat_max_ms_x10=").append(window.latMaxMsX10()).append('\n');
        sb.append("datasource_count=").append(window.datasourceCount()).append('\n');

        for (int i = 0; i < window.datasources().size(); i += 1) {
            final MetricsRegistry.DatasourceWindow ds = window.datasources().get(i);
            sb.append("datasource_").append(i).append("_name=").append(sanitize(ds.name())).append('\n');
            sb.append("datasource_").append(i).append("_sql_per_sec=").append(ds.sqlPerSec()).append('\n');
            sb.append("datasource_").append(i).append("_errors_per_sec=").append(ds.errorsPerSec()).append('\n');
            sb.append("datasource_").append(i).append("_in_flight=").append(ds.inFlight()).append('\n');
            sb.append("datasource_").append(i).append("_lat_avg_ms_x10=").append(ds.latAvgMsX10()).append('\n');
            sb.append("datasource_").append(i).append("_lat_p95_ms_x10=").append(ds.latP95MsX10()).append('\n');
            sb.append("datasource_").append(i).append("_lat_max_ms_x10=").append(ds.latMaxMsX10()).append('\n');
        }
        return sb.toString();
    }

    private static String sanitize(String value) {
        if (value == null || value.isBlank()) {
            return "unknown";
        }
        return value.replace('\n', ' ').replace('\r', ' ');
    }

    private void writeAtomically(String payload) throws IOException {
        final Path parent = outputPath.getParent();
        if (parent != null) {
            Files.createDirectories(parent);
        }

        final Path tmpPath = outputPath.resolveSibling(outputPath.getFileName() + ".tmp");
        Files.writeString(
            tmpPath,
            payload,
            StandardCharsets.UTF_8,
            StandardOpenOption.CREATE,
            StandardOpenOption.TRUNCATE_EXISTING,
            StandardOpenOption.WRITE
        );

        try {
            Files.move(tmpPath, outputPath, StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE);
        } catch (AtomicMoveNotSupportedException ignored) {
            Files.move(tmpPath, outputPath, StandardCopyOption.REPLACE_EXISTING);
        }
    }
}
