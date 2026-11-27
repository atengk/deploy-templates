# 语法声明与全局基础镜像源参数
ARG BASE_IMAGE_REGISTRY=docker.io
ARG PNPM_REGISTRY=https://registry.npmjs.org
ARG APP_VERSION=0.0.0-dev

# 阶段 1：在构建主机原生架构下利用 BuildKit 缓存与严格锁文件完成构建
FROM --platform=$BUILDPLATFORM ${BASE_IMAGE_REGISTRY}/library/node:22.19-alpine AS builder

ARG PNPM_REGISTRY
ARG APP_VERSION
ARG VITE_APP_VERSION=${APP_VERSION}

ENV PNPM_HOME="/pnpm"
ENV PNPM_STORE_DIR="/pnpm/store"
ENV PATH="${PNPM_HOME}:${PATH}"
ENV VITE_APP_VERSION=${VITE_APP_VERSION}

WORKDIR /workspace

# 安装固定版本 pnpm 并配置包仓库源
RUN npm --registry="${PNPM_REGISTRY}" install -g pnpm@11.21.0 \
    && pnpm config set registry "${PNPM_REGISTRY}"

COPY app/package.json app/pnpm-lock.yaml app/pnpm-workspace.yaml ./
RUN --mount=type=cache,id=pnpm,target=/pnpm/store \
    pnpm install --frozen-lockfile

COPY app/ ./
RUN pnpm build

# 阶段 2：使用非特权 Nginx 镜像（UID 101，监听 8080）并支持运行时配置注入
FROM ${BASE_IMAGE_REGISTRY}/nginx/nginx-unprivileged:1.28-alpine

USER root

ENV TZ=Asia/Shanghai

# 安装时区数据包并默认链接 Asia/Shanghai（允许外部通过 TZ 环境变量覆盖）
# hadolint ignore=DL3018
RUN apk add --no-cache tzdata \
    && ln -snf "/usr/share/zoneinfo/${TZ}" /etc/localtime \
    && echo "${TZ}" > /etc/timezone

COPY deploy/docker/production/nginx.conf /etc/nginx/conf.d/default.conf
COPY deploy/docker/production/docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN mkdir -p /tmp/app-runtime /tmp/nginx \
    && chown 101:101 /tmp/app-runtime /tmp/nginx \
    && chmod 0755 /usr/local/bin/docker-entrypoint.sh

COPY --from=builder --chown=101:101 /workspace/dist /usr/share/nginx/html

USER 101

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD ["wget", "-q", "-O", "/dev/null", "http://127.0.0.1:8080/healthz"]

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["nginx", "-g", "daemon off;"]
