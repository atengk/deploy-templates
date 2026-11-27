package com.ateng.deploy;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.actuate.observability.AutoConfigureObservability;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.system.CapturedOutput;
import org.springframework.boot.test.system.OutputCaptureExtension;
import org.springframework.boot.test.web.client.TestRestTemplate;
import org.springframework.core.ParameterizedTypeReference;
import org.springframework.http.HttpMethod;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;

import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * 验证参考应用根路径、基础信息接口与单端口默认 Actuator 及 OTLP 默认关闭行为。
 *
 * @author Ateng
 * @since 2026-11-27
 */
@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT)
@AutoConfigureObservability
@ExtendWith(OutputCaptureExtension.class)
class InfoControllerIntegrationTest {

    private static final ParameterizedTypeReference<Map<String, Object>> MAP_TYPE =
            new ParameterizedTypeReference<>() {
            };

    @Autowired
    private TestRestTemplate restTemplate;

    @Test
    void shouldReturnFriendlyRootPayload() {
        ResponseEntity<Map<String, Object>> response = restTemplate.exchange(
                "/", HttpMethod.GET, null, MAP_TYPE);

        assertThat(response.getStatusCode()).isEqualTo(HttpStatus.OK);
        assertThat(response.getBody()).isNotNull();
        assertThat(response.getBody()).containsKeys("service", "version", "message", "endpoints");
    }

    @Test
    @SuppressWarnings("unchecked")
    void shouldReturnRuntimeAndSafeConfigSummaryOnApiInfo(CapturedOutput output) {
        ResponseEntity<Map<String, Object>> response = restTemplate.exchange(
                "/api/info", HttpMethod.GET, null, MAP_TYPE);

        assertThat(response.getStatusCode()).isEqualTo(HttpStatus.OK);
        assertThat(response.getBody()).isNotNull();

        Map<String, Object> body = response.getBody();
        assertThat(body.get("application")).isEqualTo("spring-boot-jar-app");
        assertThat(body.get("version")).isNotNull();
        assertThat(body.get("timestamp")).isNotNull();

        Map<String, Object> server = (Map<String, Object>) body.get("server");
        assertThat(server.get("shutdown")).isEqualTo("graceful");

        Map<String, Object> observability = (Map<String, Object>) body.get("observability");
        assertThat(observability.get("otlpEnabled")).isEqualTo(false);
        assertThat(observability.get("prometheusEnabled")).isEqualTo(true);

        assertThat(output.getOut() + output.getErr())
                .doesNotContain("Failed to export")
                .doesNotContain("4318");
    }

    @Test
    void shouldExposeHealthAndPrometheusEndpointsOnSinglePortByDefault() {
        ResponseEntity<Map<String, Object>> health = restTemplate.exchange(
                "/actuator/health", HttpMethod.GET, null, MAP_TYPE);
        assertThat(health.getStatusCode()).isEqualTo(HttpStatus.OK);
        assertThat(health.getBody()).containsEntry("status", "UP");

        ResponseEntity<Map<String, Object>> liveness = restTemplate.exchange(
                "/actuator/health/liveness", HttpMethod.GET, null, MAP_TYPE);
        assertThat(liveness.getStatusCode()).isEqualTo(HttpStatus.OK);
        assertThat(liveness.getBody()).containsEntry("status", "UP");

        ResponseEntity<Map<String, Object>> readiness = restTemplate.exchange(
                "/actuator/health/readiness", HttpMethod.GET, null, MAP_TYPE);
        assertThat(readiness.getStatusCode()).isEqualTo(HttpStatus.OK);
        assertThat(readiness.getBody()).containsEntry("status", "UP");

        ResponseEntity<String> prometheus = restTemplate.getForEntity("/actuator/prometheus", String.class);
        assertThat(prometheus.getStatusCode()).isEqualTo(HttpStatus.OK);
        assertThat(prometheus.getBody()).contains("jvm_memory_used_bytes");
    }
}
