package com.ateng.deploy;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;

/**
 * Spring Boot 3 可执行 Jar 参考应用主启动类。
 *
 * @author Ateng
 * @since 2026-11-27
 */
@SpringBootApplication
public class DeployTemplateApplication {

    /**
     * 应用启动入口。
     *
     * @param args 启动命令行参数
     */
    public static void main(String[] args) {
        SpringApplication.run(DeployTemplateApplication.class, args);
    }
}
