# 生产级（production）Dockerfile：Maven 依赖缓存、Spring Boot 分层解包、非 root 运行、容器内存感知 JVM 与管理端口隔离
ARG BASE_IMAGE_REGISTRY=docker.io

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

# 编译打包并使用 Spring Boot 3 工具模式分层解包
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

FROM ${BASE_IMAGE_REGISTRY}/library/eclipse-temurin:21-jre-noble

LABEL org.opencontainers.image.title="spring-boot-jar-production" \
      org.opencontainers.image.description="Spring Boot 3 生产级参考应用镜像（非 root、分层优化、管理端口隔离 8081）" \
      org.opencontainers.image.licenses="MIT"

ENV TZ=Asia/Shanghai \
    SERVER_PORT=8080 \
    MANAGEMENT_SERVER_PORT=8081 \
    TOMCAT_BASEDIR=/tmp/tomcat \
    JAVA_OPTS="-XX:InitialRAMPercentage=25.0 -XX:MaxRAMPercentage=75.0 -XX:+UseG1GC -XX:+ExitOnOutOfMemoryError -Djava.security.egd=file:/dev/./urandom"

WORKDIR /app

# 创建低权限专用运行用户（UID/GID 10001），避免以 root 身份运行业务进程
RUN groupadd --gid 10001 appgroup \
    && useradd --uid 10001 --gid appgroup --shell /usr/sbin/nologin --create-home appuser \
    && chown 10001:10001 /app

# 按变更频率由低到高依次复制分层构建产物，最大化镜像层复用
COPY --from=builder /build/extracted/dependencies/ ./
COPY --from=builder /build/extracted/spring-boot-loader/ ./
COPY --from=builder /build/extracted/snapshot-dependencies/ ./
COPY --from=builder /build/extracted/application/ ./

USER 10001:10001

EXPOSE 8080 8081

HEALTHCHECK --interval=30s --timeout=5s --start-period=25s --retries=3 \
    CMD curl -fsS "http://127.0.0.1:${MANAGEMENT_SERVER_PORT:-8081}/actuator/health/readiness" || exit 1

# 使用 exec 替换 shell 进程，确保 java 作为 PID 1 直接接收 SIGTERM 实现优雅停机
ENTRYPOINT ["sh", "-c", "exec java ${JAVA_OPTS} -Djava.io.tmpdir=/tmp -jar /app/app.jar"]
