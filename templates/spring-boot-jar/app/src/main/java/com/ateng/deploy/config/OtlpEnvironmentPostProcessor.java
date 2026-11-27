package com.ateng.deploy.config;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.env.EnvironmentPostProcessor;
import org.springframework.core.Ordered;
import org.springframework.core.env.ConfigurableEnvironment;
import org.springframework.core.env.MapPropertySource;

import java.util.LinkedHashMap;
import java.util.Map;

/**
 * 依据标准 OTEL_EXPORTER_OTLP_ENDPOINT 环境变量按需启用 OpenTelemetry OTLP 导出，未配置时保持默认关闭。
 *
 * @author Ateng
 * @since 2026-11-27
 */
public class OtlpEnvironmentPostProcessor implements EnvironmentPostProcessor, Ordered {

    private static final String PROPERTY_SOURCE_NAME = "otlpEndpointAutoToggle";
    private static final String OTLP_TRACES_SUFFIX = "/v1/traces";

    @Override
    public void postProcessEnvironment(ConfigurableEnvironment environment, SpringApplication application) {
        String endpoint = resolveEndpoint(environment);
        if (endpoint == null || endpoint.isBlank()) {
            return;
        }

        Map<String, Object> overrides = new LinkedHashMap<>();
        overrides.put("management.tracing.enabled", true);
        overrides.put("management.otlp.tracing.export.enabled", true);
        overrides.put("management.otlp.tracing.endpoint", normalizeTracesEndpoint(endpoint));
        environment.getPropertySources().addFirst(new MapPropertySource(PROPERTY_SOURCE_NAME, overrides));
    }

    @Override
    public int getOrder() {
        return Ordered.LOWEST_PRECEDENCE;
    }

    private String resolveEndpoint(ConfigurableEnvironment environment) {
        String direct = environment.getProperty("OTEL_EXPORTER_OTLP_ENDPOINT");
        if (direct != null && !direct.isBlank()) {
            return direct.trim();
        }
        String tracesSpecific = environment.getProperty("OTEL_EXPORTER_OTLP_TRACES_ENDPOINT");
        if (tracesSpecific != null && !tracesSpecific.isBlank()) {
            return tracesSpecific.trim();
        }
        return null;
    }

    static String normalizeTracesEndpoint(String rawEndpoint) {
        String trimmed = rawEndpoint.trim();
        if (trimmed.endsWith(OTLP_TRACES_SUFFIX)) {
            return trimmed;
        }
        if (trimmed.endsWith("/")) {
            return trimmed.substring(0, trimmed.length() - 1) + OTLP_TRACES_SUFFIX;
        }
        return trimmed + OTLP_TRACES_SUFFIX;
    }
}
