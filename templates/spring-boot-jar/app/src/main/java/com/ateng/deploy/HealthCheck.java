package com.ateng.deploy;

import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.time.Duration;
import java.util.Map;

/**
 * 面向无 shell 容器镜像的零外部依赖内置 JDK 健康检查探针。
 *
 * @author Ateng
 * @since 2026-11-27
 */
public final class HealthCheck {

    private static final String DEFAULT_HOST = "127.0.0.1";
    private static final String DEFAULT_PORT = "8080";
    private static final String DEFAULT_PATH = "/actuator/health/readiness";
    private static final Duration DEFAULT_TIMEOUT = Duration.ofSeconds(3);

    private HealthCheck() {
    }

    /**
     * 探针命令行入口，探测成功返回退出码 0，失败返回退出码 1。
     *
     * @param args 可选命令行参数，首个非空参数将作为探测目标 URL
     */
    public static void main(String[] args) {
        String targetUrl = resolveTargetUrl(args, System.getenv());
        int exitCode = check(targetUrl, DEFAULT_TIMEOUT);
        if (exitCode != 0) {
            System.err.println("健康检查失败: " + targetUrl);
        }
        System.exit(exitCode);
    }

    /**
     * 按优先级解析健康探测目标地址：命令行参数 &gt; HEALTHCHECK_URL &gt; MANAGEMENT_SERVER_PORT &gt; SERVER_PORT &gt; 默认 8080。
     *
     * @param args 命令行参数数组
     * @param env  环境变量映射表
     * @return 解析后的完整 HTTP 探测 URL
     */
    public static String resolveTargetUrl(String[] args, Map<String, String> env) {
        if (args != null && args.length > 0 && hasText(args[0])) {
            return args[0].trim();
        }
        if (env != null && hasText(env.get("HEALTHCHECK_URL"))) {
            return env.get("HEALTHCHECK_URL").trim();
        }

        String port = DEFAULT_PORT;
        if (env != null) {
            if (hasText(env.get("MANAGEMENT_SERVER_PORT"))) {
                port = env.get("MANAGEMENT_SERVER_PORT").trim();
            } else if (hasText(env.get("SERVER_PORT"))) {
                port = env.get("SERVER_PORT").trim();
            }
        }

        String path = DEFAULT_PATH;
        if (env != null && hasText(env.get("HEALTHCHECK_PATH"))) {
            String rawPath = env.get("HEALTHCHECK_PATH").trim();
            path = rawPath.startsWith("/") ? rawPath : "/" + rawPath;
        }

        return "http://" + DEFAULT_HOST + ":" + port + path;
    }

    /**
     * 向指定 URL 发起 HTTP GET 探测请求。
     *
     * @param targetUrl 目标探测 URL
     * @param timeout   连接与请求超时时间
     * @return HTTP 状态码为 200 时返回 0，其余状态或异常统一返回 1
     */
    public static int check(String targetUrl, Duration timeout) {
        if (!hasText(targetUrl)) {
            return 1;
        }

        Duration effectiveTimeout = (timeout == null || timeout.isNegative() || timeout.isZero())
                ? DEFAULT_TIMEOUT
                : timeout;

        try {
            URI uri = URI.create(targetUrl.trim());
            HttpClient client = HttpClient.newBuilder()
                    .connectTimeout(effectiveTimeout)
                    .build();
            HttpRequest request = HttpRequest.newBuilder(uri)
                    .timeout(effectiveTimeout)
                    .GET()
                    .build();
            HttpResponse<Void> response = client.send(request, HttpResponse.BodyHandlers.discarding());
            return response.statusCode() == 200 ? 0 : 1;
        } catch (InterruptedException ex) {
            Thread.currentThread().interrupt();
            return 1;
        } catch (Exception ex) {
            return 1;
        }
    }

    private static boolean hasText(String value) {
        return value != null && !value.isBlank();
    }
}
