package io.jmon.dbagent;

import java.sql.Connection;
import java.sql.DatabaseMetaData;
import java.sql.SQLException;
import java.sql.Statement;
import java.util.ArrayList;
import java.util.Collections;
import java.util.Comparator;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.WeakHashMap;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ConcurrentMap;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicLong;
import java.util.concurrent.atomic.LongAdder;

public final class MetricsRegistry {
    private static final int[] LATENCY_BUCKET_UPPER_MS = new int[]{1, 2, 5, 10, 20, 50, 100, 200, 500, 1_000, 2_000, 5_000, 10_000};
    private static final long[] LATENCY_BUCKET_UPPER_NS = buildLatencyUpperNs();

    private static final String UNKNOWN_DATASOURCE = "unknown";

    private static final MetricsRegistry INSTANCE = new MetricsRegistry();

    private final Meter globalMeter = new Meter();
    private final ConcurrentMap<String, Meter> datasourceMeters = new ConcurrentHashMap<>();
    private final Map<Connection, String> datasourceByConnection = Collections.synchronizedMap(new WeakHashMap<>());

    private MetricsRegistry() {
    }

    public static MetricsRegistry get() {
        return INSTANCE;
    }

    public QueryScope onQueryStart(Object statementObj) {
        final String datasource = resolveDatasourceKey(statementObj);
        final Meter meter = meterFor(datasource);
        globalMeter.inFlight.incrementAndGet();
        meter.inFlight.incrementAndGet();
        return new QueryScope(System.nanoTime(), datasource);
    }

    public void onQueryEnd(QueryScope scope, Throwable thrown) {
        final long endNs = System.nanoTime();
        final long durationNs = Math.max(0L, endNs - scope.startNs());
        final boolean isError = thrown != null;

        final Meter meter = meterFor(scope.datasource());
        meter.record(durationNs, isError);
        globalMeter.record(durationNs, isError);

        decrementInFlight(meter.inFlight);
        decrementInFlight(globalMeter.inFlight);
    }

    public RegistryWindow snapshotAndReset(int intervalMs, int topDatasources) {
        final MeterWindow global = globalMeter.snapshotAndReset(intervalMs);
        final int datasourceCount = datasourceMeters.size();

        final List<DatasourceWindow> windows = new ArrayList<>();
        for (Map.Entry<String, Meter> entry : datasourceMeters.entrySet()) {
            final MeterWindow window = entry.getValue().snapshotAndReset(intervalMs);
            if (window.sqlPerSec() == 0 && window.errorsPerSec() == 0 && window.inFlight() == 0) {
                continue;
            }
            windows.add(new DatasourceWindow(
                entry.getKey(),
                window.sqlPerSec(),
                window.errorsPerSec(),
                window.inFlight(),
                window.latAvgMsX10(),
                window.latP95MsX10(),
                window.latMaxMsX10()
            ));
        }

        windows.sort(
            Comparator.comparingInt(DatasourceWindow::sqlPerSec)
                .thenComparingInt(DatasourceWindow::errorsPerSec)
                .reversed()
        );

        final int limit = Math.max(0, topDatasources);
        final List<DatasourceWindow> top = windows.size() <= limit ? windows : new ArrayList<>(windows.subList(0, limit));

        return new RegistryWindow(
            System.currentTimeMillis() / 1000L,
            global.sqlPerSec(),
            global.errorsPerSec(),
            global.inFlight(),
            global.latAvgMsX10(),
            global.latP95MsX10(),
            global.latMaxMsX10(),
            datasourceCount,
            top
        );
    }

    private Meter meterFor(String datasource) {
        final String key = datasource == null || datasource.isBlank() ? UNKNOWN_DATASOURCE : datasource;
        return datasourceMeters.computeIfAbsent(key, ignored -> new Meter());
    }

    private String resolveDatasourceKey(Object statementObj) {
        if (!(statementObj instanceof Statement statement)) {
            return UNKNOWN_DATASOURCE;
        }

        final Connection connection;
        try {
            connection = statement.getConnection();
        } catch (SQLException ignored) {
            return UNKNOWN_DATASOURCE;
        }
        if (connection == null) {
            return UNKNOWN_DATASOURCE;
        }

        final String cached = datasourceByConnection.get(connection);
        if (cached != null) {
            return cached;
        }

        final String resolved = resolveConnectionKey(connection);
        datasourceByConnection.put(connection, resolved);
        return resolved;
    }

    private String resolveConnectionKey(Connection connection) {
        try {
            final DatabaseMetaData metadata = connection.getMetaData();
            if (metadata == null) {
                return UNKNOWN_DATASOURCE;
            }
            final String url = metadata.getURL();
            if (url == null || url.isBlank()) {
                return UNKNOWN_DATASOURCE;
            }
            return normalizeJdbcUrl(url);
        } catch (SQLException ignored) {
            return UNKNOWN_DATASOURCE;
        }
    }

    static String normalizeJdbcUrl(String rawUrl) {
        String value = rawUrl.trim();
        if (value.isEmpty()) {
            return UNKNOWN_DATASOURCE;
        }

        if (value.regionMatches(true, 0, "jdbc:", 0, 5)) {
            value = value.substring(5);
        }

        final int queryIndex = value.indexOf('?');
        if (queryIndex >= 0) {
            value = value.substring(0, queryIndex);
        }

        final int authStart = value.indexOf("://");
        if (authStart >= 0) {
            final int userInfoStart = authStart + 3;
            int authorityEnd = value.indexOf('/', userInfoStart);
            if (authorityEnd < 0) {
                authorityEnd = value.length();
            }
            final int at = value.indexOf('@', userInfoStart);
            if (at >= 0 && at < authorityEnd) {
                value = value.substring(0, userInfoStart) + value.substring(at + 1);
            }
        }

        if (value.length() > 200) {
            value = value.substring(0, 200);
        }

        return value.toLowerCase(Locale.ROOT);
    }

    private static void decrementInFlight(AtomicInteger counter) {
        counter.updateAndGet(current -> current > 0 ? current - 1 : 0);
    }

    private static int bucketIndexFor(long durationNs) {
        for (int i = 0; i < LATENCY_BUCKET_UPPER_NS.length; i += 1) {
            if (durationNs <= LATENCY_BUCKET_UPPER_NS[i]) {
                return i;
            }
        }
        return LATENCY_BUCKET_UPPER_NS.length;
    }

    private static long[] buildLatencyUpperNs() {
        final long[] values = new long[LATENCY_BUCKET_UPPER_MS.length];
        for (int i = 0; i < values.length; i += 1) {
            values[i] = LATENCY_BUCKET_UPPER_MS[i] * 1_000_000L;
        }
        return values;
    }

    private static int nsToMsX10(long ns) {
        if (ns <= 0L) {
            return 0;
        }
        final double msX10 = ns / 100_000.0;
        if (msX10 >= Integer.MAX_VALUE) {
            return Integer.MAX_VALUE;
        }
        return (int) Math.round(msX10);
    }

    private static int avgNsToMsX10(long durationTotalNs, long count) {
        if (durationTotalNs <= 0L || count <= 0L) {
            return 0;
        }
        final double avgNs = durationTotalNs / (double) count;
        final double msX10 = avgNs / 100_000.0;
        if (msX10 >= Integer.MAX_VALUE) {
            return Integer.MAX_VALUE;
        }
        return (int) Math.round(msX10);
    }

    private static int perSecond(long count, int intervalMs) {
        if (count <= 0L || intervalMs <= 0) {
            return 0;
        }
        final long scaled = (count * 1000L) / intervalMs;
        return scaled >= Integer.MAX_VALUE ? Integer.MAX_VALUE : (int) scaled;
    }

    private static int percentileMsX10(long[] buckets, long totalCount, int percentile) {
        if (totalCount <= 0L) {
            return 0;
        }

        final long target = (long) Math.ceil((totalCount * percentile) / 100.0);
        long cumulative = 0L;
        for (int i = 0; i < buckets.length; i += 1) {
            cumulative += buckets[i];
            if (cumulative < target) {
                continue;
            }

            if (i < LATENCY_BUCKET_UPPER_MS.length) {
                return LATENCY_BUCKET_UPPER_MS[i] * 10;
            }
            return LATENCY_BUCKET_UPPER_MS[LATENCY_BUCKET_UPPER_MS.length - 1] * 10;
        }

        return LATENCY_BUCKET_UPPER_MS[LATENCY_BUCKET_UPPER_MS.length - 1] * 10;
    }

    public record QueryScope(long startNs, String datasource) {
    }

    public record DatasourceWindow(
        String name,
        int sqlPerSec,
        int errorsPerSec,
        int inFlight,
        int latAvgMsX10,
        int latP95MsX10,
        int latMaxMsX10
    ) {
    }

    public record RegistryWindow(
        long tsUnixSec,
        int sqlPerSec,
        int errorsPerSec,
        int inFlight,
        int latAvgMsX10,
        int latP95MsX10,
        int latMaxMsX10,
        int datasourceCount,
        List<DatasourceWindow> datasources
    ) {
    }

    private static final class Meter {
        private final LongAdder callsWindow = new LongAdder();
        private final LongAdder errorsWindow = new LongAdder();
        private final LongAdder durationWindowNs = new LongAdder();
        private final AtomicLong maxWindowNs = new AtomicLong();
        private final LongAdder[] histogramWindow = createHistogram();
        private final AtomicInteger inFlight = new AtomicInteger();

        private void record(long durationNs, boolean error) {
            callsWindow.increment();
            if (error) {
                errorsWindow.increment();
            }
            durationWindowNs.add(durationNs);
            updateMax(maxWindowNs, durationNs);
            histogramWindow[bucketIndexFor(durationNs)].increment();
        }

        private MeterWindow snapshotAndReset(int intervalMs) {
            final long calls = callsWindow.sumThenReset();
            final long errors = errorsWindow.sumThenReset();
            final long durationTotal = durationWindowNs.sumThenReset();
            final long maxNs = maxWindowNs.getAndSet(0L);

            final long[] buckets = new long[histogramWindow.length];
            for (int i = 0; i < histogramWindow.length; i += 1) {
                buckets[i] = histogramWindow[i].sumThenReset();
            }

            return new MeterWindow(
                perSecond(calls, intervalMs),
                perSecond(errors, intervalMs),
                inFlight.get(),
                avgNsToMsX10(durationTotal, calls),
                percentileMsX10(buckets, calls, 95),
                nsToMsX10(maxNs)
            );
        }

        private static LongAdder[] createHistogram() {
            final LongAdder[] buckets = new LongAdder[LATENCY_BUCKET_UPPER_MS.length + 1];
            for (int i = 0; i < buckets.length; i += 1) {
                buckets[i] = new LongAdder();
            }
            return buckets;
        }
    }

    private record MeterWindow(
        int sqlPerSec,
        int errorsPerSec,
        int inFlight,
        int latAvgMsX10,
        int latP95MsX10,
        int latMaxMsX10
    ) {
    }

    private static void updateMax(AtomicLong target, long value) {
        long current = target.get();
        while (value > current) {
            if (target.compareAndSet(current, value)) {
                return;
            }
            current = target.get();
        }
    }
}
