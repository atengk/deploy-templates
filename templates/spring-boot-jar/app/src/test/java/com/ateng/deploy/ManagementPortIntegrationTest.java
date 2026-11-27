package com.ateng.deploy;

import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.actuate.observability.AutoConfigureObservability;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.web.client.TestRestTemplate;
import org.springframework.boot.test.web.server.LocalManagementPort;
import org.springframework.boot.test.web.server.LocalServerPort;
import org.springframework.core.ParameterizedTypeReference;
import org.springframework.http.HttpMethod;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;

import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * 验证生产与加固模式下业务端口与独立管理端口隔离行为。
 *
 * @author Ateng
 * @since 2026-11-27
 */
@SpringBootTest(
        webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT,
        properties = {
                "management.server.port=0",
                "APP_ENV=production",
                "APP_MESSAGE=端口隔离校验"
        }
)
@AutoConfigureObservability
class ManagementPortIntegrationTest {

    private static final ParameterizedTypeReference<Map<String, Object>> MAP_TYPE =
            new ParameterizedTypeReference<>() {
            };

    @LocalServerPort
    private int serverPort;

    @LocalManagementPort
    private int managementPort;

    @Autowired
    private TestRestTemplate restTemplate;

    @Test
    @SuppressWarnings("unchecked")
    void shouldIsolateManagementEndpointsFromBusinessPort() {
        assertThat(managementPort).isNotEqualTo(serverPort);

        ResponseEntity<Map<String, Object>> infoResp = restTemplate.exchange(
                "http://127.0.0.1:" + serverPort + "/api/info",
                HttpMethod.GET,
                null,
                MAP_TYPE);
        assertThat(infoResp.getStatusCode()).isEqualTo(HttpStatus.OK);
        assertThat(infoResp.getBody()).isNotNull();
        assertThat(infoResp.getBody().get("environment")).isEqualTo("production");

        Map<String, Object> server = (Map<String, Object>) infoResp.getBody().get("server");
        assertThat(server.get("port")).isEqualTo(serverPort);
        assertThat(server.get("managementPort")).isEqualTo(managementPort);

        ResponseEntity<String> businessActuator = restTemplate.getForEntity(
                "http://127.0.0.1:" + serverPort + "/actuator/health", String.class);
        assertThat(businessActuator.getStatusCode()).isEqualTo(HttpStatus.NOT_FOUND);

        ResponseEntity<String> businessPrometheus = restTemplate.getForEntity(
                "http://127.0.0.1:" + serverPort + "/actuator/prometheus", String.class);
        assertThat(businessPrometheus.getStatusCode()).isEqualTo(HttpStatus.NOT_FOUND);
    }

    @Test
    void shouldExposeProbesAndPrometheusOnDedicatedManagementPort() {
        ResponseEntity<Map<String, Object>> liveness = restTemplate.exchange(
                "http://127.0.0.1:" + managementPort + "/actuator/health/liveness",
                HttpMethod.GET,
                null,
                MAP_TYPE);
        assertThat(liveness.getStatusCode()).isEqualTo(HttpStatus.OK);
        assertThat(liveness.getBody()).containsEntry("status", "UP");

        ResponseEntity<Map<String, Object>> readiness = restTemplate.exchange(
                "http://127.0.0.1:" + managementPort + "/actuator/health/readiness",
                HttpMethod.GET,
                null,
                MAP_TYPE);
        assertThat(readiness.getStatusCode()).isEqualTo(HttpStatus.OK);
        assertThat(readiness.getBody()).containsEntry("status", "UP");

        ResponseEntity<String> prometheus = restTemplate.getForEntity(
                "http://127.0.0.1:" + managementPort + "/actuator/prometheus", String.class);
        assertThat(prometheus.getStatusCode()).isEqualTo(HttpStatus.OK);
        assertThat(prometheus.getBody()).contains("http_server_requests_seconds");
    }
}
