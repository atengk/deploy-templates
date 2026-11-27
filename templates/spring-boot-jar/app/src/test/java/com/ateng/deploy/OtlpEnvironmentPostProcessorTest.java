package com.ateng.deploy;

import com.ateng.deploy.config.OtlpEnvironmentPostProcessor;
import org.junit.jupiter.api.Test;
import org.springframework.boot.SpringApplication;
import org.springframework.core.env.MapPropertySource;
import org.springframework.mock.env.MockEnvironment;

import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * 验证 OTLP 环境变量开关后处理器的默认关闭与按需激活契约。
 *
 * @author Ateng
 * @since 2026-11-27
 */
class OtlpEnvironmentPostProcessorTest {

    private final OtlpEnvironmentPostProcessor processor = new OtlpEnvironmentPostProcessor();

    @Test
    void shouldKeepOtlpDisabledWhenEndpointMissingOrBlank() {
        MockEnvironment missingEnv = new MockEnvironment();
        processor.postProcessEnvironment(missingEnv, new SpringApplication(DeployTemplateApplication.class));
        assertThat(missingEnv.getProperty("management.otlp.tracing.export.enabled")).isNull();

        MockEnvironment blankEnv = new MockEnvironment();
        blankEnv.getPropertySources().addFirst(new MapPropertySource("env", Map.of("OTEL_EXPORTER_OTLP_ENDPOINT", "   ")));
        processor.postProcessEnvironment(blankEnv, new SpringApplication(DeployTemplateApplication.class));
        assertThat(blankEnv.getProperty("management.otlp.tracing.export.enabled")).isNull();
    }

    @Test
    void shouldEnableOtlpAndNormalizeEndpointWhenConfigured() {
        MockEnvironment env = new MockEnvironment();
        env.getPropertySources().addFirst(
                new MapPropertySource("env", Map.of("OTEL_EXPORTER_OTLP_ENDPOINT", "http://otel-collector:4318")));

        processor.postProcessEnvironment(env, new SpringApplication(DeployTemplateApplication.class));

        assertThat(env.getProperty("management.tracing.enabled", Boolean.class)).isTrue();
        assertThat(env.getProperty("management.otlp.tracing.export.enabled", Boolean.class)).isTrue();
        assertThat(env.getProperty("management.otlp.tracing.endpoint"))
                .isEqualTo("http://otel-collector:4318/v1/traces");

        MockEnvironment envWithPath = new MockEnvironment();
        envWithPath.getPropertySources().addFirst(
                new MapPropertySource("env", Map.of("OTEL_EXPORTER_OTLP_ENDPOINT", "http://otel-collector:4318/v1/traces")));
        processor.postProcessEnvironment(envWithPath, new SpringApplication(DeployTemplateApplication.class));
        assertThat(envWithPath.getProperty("management.otlp.tracing.endpoint"))
                .isEqualTo("http://otel-collector:4318/v1/traces");
    }
}
