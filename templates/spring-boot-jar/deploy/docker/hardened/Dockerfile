# 企业加固级（hardened）Dockerfile：无 shell Distroless Java 21、只读根文件系统友好与内置 JDK 探针健康检查
ARG BASE_IMAGE_REGISTRY=docker.io
ARG GCR_REGISTRY=gcr.io

FROM --platform=$BUILDPLATFORM ${BASE_IMAGE_REGISTRY}/library/maven:3.9.9-eclipse-temurin-21-noble AS builder

# 可选传入国内 Maven 镜像地址，例如 https://maven.aliyun.com/repository/public
ARG MAVEN_MIRROR_URL=""
ARG APP_VERSION=0.1.0-SNAPSHOT

WORKDIR /build

COPY pom.xml ./

# 预先离线缓存依赖（利用 BuildKit 挂载缓存加速重复构建）
RUN --mount=type=cache,target=/root/.m2/repository \
    set -eu; \
    if [ -n "${MAVEN_MIRROR_URL}" ]; then \
        printf '<settings><mirrors><mirror><id>custom-mirror</id><mirrorOf>*</mirrorOf><url>%s</url></mirror></mirrors></settings>\n' "${MAVEN_MIRROR_URL}" > /tmp/maven-settings.xml; \
        mvn -B -ntp -s /tmp/maven-settings.xml dependency:go-offline; \
    else \
        mvn -B -ntp dependency:go-offline; \
    fi

COPY src ./src

# 编译打包并分层解包，同时确保所有解压产物对 Distroless nonroot 用户只读可执行
RUN --mount=type=cache,target=/root/.m2/repository \
    set -eu; \
    if [ -n "${MAVEN_MIRROR_URL}" ]; then \
        printf '<settings><mirrors><mirror><id>custom-mirror</id><mirrorOf>*</mirrorOf><url>%s</url></mirror></mirrors></settings>\n' "${MAVEN_MIRROR_URL}" > /tmp/maven-settings.xml; \
        mvn -B -ntp -s /tmp/maven-settings.xml package -DskipTests "-Dapp.version=${APP_VERSION}"; \
    else \
        mvn -B -ntp package -DskipTests "-Dapp.version=${APP_VERSION}"; \
    fi; \
    java -Djarmode=tools -jar /build/target/app.jar extract --layers --destination /build/extracted; \
    chmod -R a+rX /build/extracted

FROM ${GCR_REGISTRY}/distroless/java21-debian12:nonroot

LABEL org.opencontainers.image.title="spring-boot-jar-hardened" \
      org.opencontainers.image.description="Spring Boot 3 企业加固级参考应用镜像（Distroless nonroot、只读根文件系统友好、内置 JDK 探针）" \
      org.opencontainers.image.licenses="MIT"

ENV TZ=Asia/Shanghai \
    SERVER_PORT=8080 \
    MANAGEMENT_SERVER_PORT=8081 \
    TOMCAT_BASEDIR=/tmp/tomcat

WORKDIR /app

# 复制只读分层应用产物（文件属主保留 root 只读，UID 65532 仅具备读与执行权限）
COPY --from=builder /build/extracted/dependencies/ ./
COPY --from=builder /build/extracted/spring-boot-loader/ ./
COPY --from=builder /build/extracted/snapshot-dependencies/ ./
COPY --from=builder /build/extracted/application/ ./

# Distroless nonroot 镜像标准 UID/GID 为 65532
USER 65532:65532

EXPOSE 8080 8081

# 无 shell 与 curl 环境下使用内置零依赖 JDK 探针类探测独立管理端口 readiness，并限制探针内存上限
HEALTHCHECK --interval=30s --timeout=5s --start-period=25s --retries=3 \
    CMD ["java", "-Xms8m", "-Xmx32m", "-cp", "/app/app.jar", "com.ateng.deploy.HealthCheck"]

# 直接以 exec 形式拉起 JVM 作为 PID 1，原生接收 SIGTERM 触发 Spring Boot 优雅停机；临时文件指向 /tmp 以兼容只读根文件系统
ENTRYPOINT ["java", "-XX:InitialRAMPercentage=25.0", "-XX:MaxRAMPercentage=75.0", "-XX:+UseG1GC", "-XX:+ExitOnOutOfMemoryError", "-Djava.io.tmpdir=/tmp", "-Djava.security.egd=file:/dev/./urandom", "-jar", "/app/app.jar"]
