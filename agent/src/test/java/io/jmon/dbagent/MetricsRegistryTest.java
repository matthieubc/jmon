package io.jmon.dbagent;

import org.junit.jupiter.api.Assertions;
import org.junit.jupiter.api.Test;

final class MetricsRegistryTest {
    @Test
    void normalizeJdbcUrlStripsCredentialsAndQuery() {
        final String normalized = MetricsRegistry.normalizeJdbcUrl("jdbc:postgresql://user:secret@db.prod.local:5432/appdb?ssl=true");
        Assertions.assertEquals("postgresql://db.prod.local:5432/appdb", normalized);
    }

    @Test
    void normalizeJdbcUrlFallsBackToUnknownForBlank() {
        final String normalized = MetricsRegistry.normalizeJdbcUrl("   ");
        Assertions.assertEquals("unknown", normalized);
    }
}
