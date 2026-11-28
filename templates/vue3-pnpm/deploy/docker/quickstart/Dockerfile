# 语法声明与全局基础镜像源参数
ARG BASE_IMAGE_REGISTRY=docker.io
ARG PNPM_REGISTRY=https://registry.npmjs.org
ARG APP_VERSION=0.0.0-dev

# 阶段 1：在构建主机原生架构下完成静态打包，提升多架构构建效率
FROM --platform=$BUILDPLATFORM ${BASE_IMAGE_REGISTRY}/library/node:22.19-alpine AS builder

ARG PNPM_REGISTRY
ARG APP_VERSION
ARG VITE_APP_VERSION=${APP_VERSION}

ENV CI="true"
ENV PNPM_HOME="/pnpm"
ENV PATH="${PNPM_HOME}:${PATH}"
ENV VITE_APP_VERSION=${VITE_APP_VERSION}

WORKDIR /workspace

# 安装与锁文件版本一致的 pnpm，并按构建参数切换包仓库源
RUN npm --registry="${PNPM_REGISTRY}" install -g pnpm@11.21.0 \
    && pnpm config set registry "${PNPM_REGISTRY}"

COPY app/package.json app/pnpm-lock.yaml app/pnpm-workspace.yaml ./
RUN pnpm install

COPY app/ ./
RUN pnpm build

# 阶段 2：使用官方 Nginx 托管纯静态 SPA 构建产物
FROM ${BASE_IMAGE_REGISTRY}/library/nginx:1.28-alpine

ENV TZ=Asia/Shanghai

# 安装时区数据包并默认链接 Asia/Shanghai（允许外部通过 TZ 环境变量覆盖）
# hadolint ignore=DL3018
RUN apk add --no-cache tzdata \
    && ln -snf "/usr/share/zoneinfo/${TZ}" /etc/localtime \
    && echo "${TZ}" > /etc/timezone

COPY deploy/docker/quickstart/nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=builder /workspace/dist /usr/share/nginx/html

EXPOSE 80
