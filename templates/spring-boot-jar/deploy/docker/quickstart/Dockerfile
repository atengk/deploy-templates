# 快速级（quickstart）Dockerfile：极简构建与单端口 8080 运行，适用于本地体验与快速验证
ARG BASE_IMAGE_REGISTRY=docker.io

FROM --platform=$BUILDPLATFORM ${BASE_IMAGE_REGISTRY}/library/maven:3.9.9-eclipse-temurin-21-noble AS builder

# 可选传入国内 Maven 镜像地址，例如 https://maven.aliyun.com/repository/public
ARG MAVEN_MIRROR_URL=""
ARG APP_VERSION=0.1.0-SNAPSHOT

WORKDIR /build

COPY pom.xml ./
COPY src ./src

RUN set -eu; \
    if [ -n "${MAVEN_MIRROR_URL}" ]; then \
        printf '<settings><mirrors><mirror><id>custom-mirror</id><mirrorOf>*</mirrorOf><url>%s</url></mirror></mirrors></settings>\n' "${MAVEN_MIRROR_URL}" > /tmp/maven-settings.xml; \
        mvn -B -ntp -s /tmp/maven-settings.xml clean package -DskipTests "-Dapp.version=${APP_VERSION}"; \
    else \
        mvn -B -ntp clean package -DskipTests "-Dapp.version=${APP_VERSION}"; \
    fi

FROM ${BASE_IMAGE_REGISTRY}/library/eclipse-temurin:21-jre-noble

LABEL org.opencontainers.image.title="spring-boot-jar-quickstart" \
      org.opencontainers.image.description="Spring Boot 3 快速级参考应用镜像（单端口 8080）" \
      org.opencontainers.image.licenses="MIT"

ENV TZ=Asia/Shanghai \
    SERVER_PORT=8080

WORKDIR /app

COPY --from=builder /build/target/app.jar /app/app.jar

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
    CMD curl -fsS "http://127.0.0.1:${SERVER_PORT:-8080}/actuator/health" || exit 1

ENTRYPOINT ["java", "-jar", "/app/app.jar"]
