package com.ateng.deploy;

import com.sun.net.httpserver.HttpServer;
import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * 验证内置轻量 JDK 健康检查探针的 URL 解析与 HTTP 状态探测行为。
 *
 * @author Ateng
 * @since 2026-11-27
 */
class HealthCheckTest {

    @Test
    void shouldResolveDefaultUrlWhenNoArgsOrEnvProvided() {
        String url = HealthCheck.resolveTargetUrl(new String[0], Map.of());
        assertThat(url).isEqualTo("http://127.0.0.1:8080/actuator/health/readiness");
    }

    @Test
    void shouldResolveUrlWithPriorityFromArgsAndEnvironment() {
        assertThat(HealthCheck.resolveTargetUrl(
                new String[0],
                Map.of("SERVER_PORT", "9090")))
                .isEqualTo("http://127.0.0.1:9090/actuator/health/readiness");

        assertThat(HealthCheck.resolveTargetUrl(
                new String[0],
                Map.of("SERVER_PORT", "9090", "MANAGEMENT_SERVER_PORT", "8081")))
                .isEqualTo("http://127.0.0.1:8081/actuator/health/readiness");

        assertThat(HealthCheck.resolveTargetUrl(
                new String[0],
                Map.of("MANAGEMENT_SERVER_PORT", "8081", "HEALTHCHECK_URL", "http://127.0.0.1:8080/actuator/health")))
                .isEqualTo("http://127.0.0.1:8080/actuator/health");

        assertThat(HealthCheck.resolveTargetUrl(
                new String[]{"http://127.0.0.1:18081/healthz"},
                Map.of("HEALTHCHECK_URL", "http://127.0.0.1:8080/actuator/health")))
                .isEqualTo("http://127.0.0.1:18081/healthz");
    }

    @Test
    void shouldReturnZeroWhenEndpointResponds200() throws IOException {
        HttpServer server = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        server.createContext("/actuator/health/readiness", exchange -> {
            byte[] body = "{\"status\":\"UP\"}".getBytes(StandardCharsets.UTF_8);
            exchange.sendResponseHeaders(200, body.length);
            exchange.getResponseBody().write(body);
            exchange.close();
        });
        server.start();
        try {
            String url = "http://127.0.0.1:" + server.getAddress().getPort() + "/actuator/health/readiness";
            int exitCode = HealthCheck.check(url, Duration.ofSeconds(2));
            assertThat(exitCode).isEqualTo(0);
        } finally {
            server.stop(0);
        }
    }

    @Test
    void shouldReturnOneWhenEndpointRespondsNon200() throws IOException {
        HttpServer server = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        server.createContext("/actuator/health/readiness", exchange -> {
            byte[] body = "{\"status\":\"OUT_OF_SERVICE\"}".getBytes(StandardCharsets.UTF_8);
            exchange.sendResponseHeaders(503, body.length);
            exchange.getResponseBody().write(body);
            exchange.close();
        });
        server.start();
        try {
            String url = "http://127.0.0.1:" + server.getAddress().getPort() + "/actuator/health/readiness";
            int exitCode = HealthCheck.check(url, Duration.ofSeconds(2));
            assertThat(exitCode).isEqualTo(1);
        } finally {
            server.stop(0);
        }
    }

    @Test
    void shouldReturnOneWhenConnectionRefusedOrInvalidUrl() throws IOException {
        int unusedPort;
        try (java.net.ServerSocket socket = new java.net.ServerSocket(0)) {
            unusedPort = socket.getLocalPort();
        }
        String url = "http://127.0.0.1:" + unusedPort + "/actuator/health/readiness";
        assertThat(HealthCheck.check(url, Duration.ofSeconds(1))).isEqualTo(1);
        assertThat(HealthCheck.check("not-a-valid-url", Duration.ofSeconds(1))).isEqualTo(1);
    }
}
