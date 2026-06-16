package io.jmon.dbagent;

import net.bytebuddy.asm.Advice;

public final class JdbcExecuteAdvice {
    private JdbcExecuteAdvice() {
    }

    @Advice.OnMethodEnter(suppress = Throwable.class)
    public static MetricsRegistry.QueryScope onEnter(@Advice.This Object statement) {
        return MetricsRegistry.get().onQueryStart(statement);
    }

    @Advice.OnMethodExit(onThrowable = Throwable.class, suppress = Throwable.class)
    public static void onExit(
        @Advice.Enter MetricsRegistry.QueryScope scope,
        @Advice.Thrown Throwable thrown
    ) {
        if (scope == null) {
            return;
        }
        MetricsRegistry.get().onQueryEnd(scope, thrown);
    }
}
