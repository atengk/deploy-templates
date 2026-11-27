package com.ateng.deploy.controller;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.core.env.Environment;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;

import java.time.OffsetDateTime;
import java.time.ZoneId;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * 提供参考应用根路径欢迎信息与运行态信息接口，仅暴露非敏感配置摘要。
 *
 * @author Ateng
 * @since 2026-11-27
 */
@RestController
public class InfoController {

    private final Environment environment;
    private final String applicationName;
    private final String appVersion;
    private final String appEnv;
    private final String appMessage;
    private final String externalApiUrl;

    /**
     * 构造基础信息控制器。
     *
     * @param environment     Spring 运行环境上下文
     * @param applicationName 应用名称
     * @param appVersion      应用版本号
     * @param appEnv          当前运行环境标签
     * @param appMessage      自定义展示消息
     * @param externalApiUrl  外部依赖地址配置（仅用于判断配置状态）
     */
    public InfoController(
            Environment environment,
            @Value("${spring.application.name:spring-boot-jar-app}") String applicationName,
            @Value("${app.version:0.1.0-SNAPSHOT}") String appVersion,
            @Value("${app.env:default}") String appEnv,
            @Value("${app.message:Spring Boot 3 参考应用运行正常}") String appMessage,
            @Value("${app.external-api-url:}") String externalApiUrl) {
        this.environment = environment;
        this.applicationName = applicationName;
        this.appVersion = appVersion;
        this.appEnv = appEnv;
        this.appMessage = appMessage;
        this.externalApiUrl = externalApiUrl;
    }

    /**
     * 返回根路径基础导航信息。
     *
     * @return 服务标识与可用接口说明
     */
    @GetMapping("/")
    public Map<String, Object> root() {
        Map<String, Object> payload = new LinkedHashMap<>();
        payload.put("service", applicationName);
        payload.put("version", appVersion);
        payload.put("environment", appEnv);
        payload.put("message", appMessage);
        payload.put("endpoints", List.of(
                "/api/info",
                "/actuator/health",
                "/actuator/health/liveness",
                "/actuator/health/readiness",
                "/actuator/prometheus"
        ));
        return payload;
    }

    /**
     * 返回参考应用运行态、端口治理与非敏感环境变量摘要。
     *
     * @return 结构化应用与运行环境摘要
     */
    @GetMapping("/api/info")
    public Map<String, Object> info() {
        Runtime runtime = Runtime.getRuntime();

        Map<String, Object> runtimeInfo = new LinkedHashMap<>();
        runtimeInfo.put("javaVersion", System.getProperty("java.version", "unknown"));
        runtimeInfo.put("javaVendor", System.getProperty("java.vendor", "unknown"));
        runtimeInfo.put("osName", System.getProperty("os.name", "unknown"));
        runtimeInfo.put("osArch", System.getProperty("os.arch", "unknown"));
        runtimeInfo.put("timezone", ZoneId.systemDefault().getId());
        runtimeInfo.put("availableProcessors", runtime.availableProcessors());
        runtimeInfo.put("maxMemoryBytes", runtime.maxMemory());

        String serverPort = environment.getProperty("local.server.port",
                environment.getProperty("server.port", "8080"));
        String managementPort = environment.getProperty("local.management.port",
                environment.getProperty("management.server.port", serverPort));

        Map<String, Object> serverInfo = new LinkedHashMap<>();
        serverInfo.put("port", parsePortOrRaw(serverPort));
        serverInfo.put("managementPort", parsePortOrRaw(managementPort));
        serverInfo.put("shutdown", environment.getProperty("server.shutdown", "graceful"));
        serverInfo.put("shutdownTimeout", environment.getProperty("spring.lifecycle.timeout-per-shutdown-phase", "20s"));

        boolean otlpEnabled = Boolean.TRUE.equals(
                environment.getProperty("management.otlp.tracing.export.enabled", Boolean.class, false));
        boolean prometheusEnabled = Boolean.TRUE.equals(
                environment.getProperty("management.prometheus.metrics.export.enabled", Boolean.class, true));

        Map<String, Object> observabilityInfo = new LinkedHashMap<>();
        observabilityInfo.put("prometheusEnabled", prometheusEnabled);
        observabilityInfo.put("otlpEnabled", otlpEnabled);

        Map<String, Object> configSummary = new LinkedHashMap<>();
        configSummary.put("appMessage", appMessage);
        configSummary.put("externalDependencyConfigured", externalApiUrl != null && !externalApiUrl.isBlank());
        configSummary.put("timezoneEnv", environment.getProperty("TZ", ZoneId.systemDefault().getId()));

        Map<String, Object> payload = new LinkedHashMap<>();
        payload.put("application", applicationName);
        payload.put("version", appVersion);
        payload.put("environment", appEnv);
        payload.put("runtime", runtimeInfo);
        payload.put("server", serverInfo);
        payload.put("observability", observabilityInfo);
        payload.put("configSummary", configSummary);
        payload.put("timestamp", OffsetDateTime.now().toString());
        return payload;
    }

    private Object parsePortOrRaw(String value) {
        try {
            return Integer.parseInt(value);
        } catch (NumberFormatException ex) {
            return value;
        }
    }
}
