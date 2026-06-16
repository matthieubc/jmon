package io.jmon.dbagent;

import net.bytebuddy.agent.builder.AgentBuilder;

import java.lang.instrument.Instrumentation;
import java.nio.file.Path;
import java.util.Locale;
import java.util.concurrent.atomic.AtomicBoolean;

import static net.bytebuddy.matcher.ElementMatchers.hasSuperType;
import static net.bytebuddy.matcher.ElementMatchers.isAbstract;
import static net.bytebuddy.matcher.ElementMatchers.isMethod;
import static net.bytebuddy.matcher.ElementMatchers.isNative;
import static net.bytebuddy.matcher.ElementMatchers.nameStartsWith;
import static net.bytebuddy.matcher.ElementMatchers.named;
import static net.bytebuddy.matcher.ElementMatchers.not;

public final class Agent {
    private static final AtomicBoolean STARTED = new AtomicBoolean(false);
    private static final String DEFAULT_OUTPUT_DIR = "/tmp";
    private static final int DEFAULT_INTERVAL_MS = 1000;

    private static volatile MetricsExporter exporter;

    private Agent() {
    }

    public static void premain(String agentArgs, Instrumentation instrumentation) {
        start(agentArgs, instrumentation);
    }

    public static void agentmain(String agentArgs, Instrumentation instrumentation) {
        start(agentArgs, instrumentation);
    }

    private static void start(String agentArgs, Instrumentation instrumentation) {
        if (!STARTED.compareAndSet(false, true)) {
            return;
        }

        final Config config = parseConfig(agentArgs);
        final long pid = ProcessHandle.current().pid();
        final Path outputPath = Path.of(config.outputDir(), "jmon-db-agent-" + pid + ".metrics");

        exporter = new MetricsExporter(MetricsRegistry.get(), outputPath, pid, config.intervalMs());
        exporter.start();

        Runtime.getRuntime().addShutdownHook(new Thread(() -> {
            final MetricsExporter local = exporter;
            if (local != null) {
                local.stop();
            }
        }, "jmon-db-agent-shutdown"));

        installJdbcInstrumentation(instrumentation);
    }

    private static void installJdbcInstrumentation(Instrumentation instrumentation) {
        new AgentBuilder.Default()
            .ignore(nameStartsWith("net.bytebuddy.")
                .or(nameStartsWith("io.jmon.dbagent."))
                .or(nameStartsWith("jdk.internal.")))
            .with(AgentBuilder.RedefinitionStrategy.RETRANSFORMATION)
            .type(hasSuperType(named("java.sql.Statement")))
            .transform(new AgentBuilder.Transformer.ForAdvice()
                .include(JdbcExecuteAdvice.class.getClassLoader())
                .advice(
                    isMethod()
                        .and(nameStartsWith("execute"))
                        .and(not(isAbstract()))
                        .and(not(isNative())),
                    JdbcExecuteAdvice.class.getName()
                ))
            .installOn(instrumentation);
    }

    private static Config parseConfig(String rawArgs) {
        if (rawArgs == null || rawArgs.isBlank()) {
            return new Config(DEFAULT_OUTPUT_DIR, DEFAULT_INTERVAL_MS);
        }

        String outputDir = DEFAULT_OUTPUT_DIR;
        int intervalMs = DEFAULT_INTERVAL_MS;

        final String[] parts = rawArgs.split(",");
        for (String part : parts) {
            final String trimmed = part.trim();
            if (trimmed.isEmpty()) {
                continue;
            }

            final int idx = trimmed.indexOf('=');
            if (idx <= 0 || idx >= trimmed.length() - 1) {
                continue;
            }

            final String key = trimmed.substring(0, idx).trim().toLowerCase(Locale.ROOT);
            final String value = trimmed.substring(idx + 1).trim();
            if (value.isEmpty()) {
                continue;
            }

            if (key.equals("output") || key.equals("output_dir") || key.equals("dir")) {
                outputDir = value;
            } else if (key.equals("interval") || key.equals("interval_ms")) {
                try {
                    final int parsed = Integer.parseInt(value);
                    if (parsed > 0) {
                        intervalMs = parsed;
                    }
                } catch (NumberFormatException ignored) {
                }
            }
        }

        return new Config(outputDir, intervalMs);
    }

    private record Config(String outputDir, int intervalMs) {
    }
}
