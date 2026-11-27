# Spring Boot 3 Docker 部署载体

本目录提供 Spring Boot 3 可执行 Jar 在 Docker **部署载体**下的三级**独立等级副本**：`quickstart`、`production`、`hardened`。各等级均直接复用 [唯一参考应用](../../app/) 源码进行构建，严格坚持**单应用交付**边界，同时保证单等级目录可直接完整拷贝至自有项目使用。

## 目录结构

```text
templates/spring-boot-jar/deploy/docker/
├── README.md                  # 三级对比、构建验证指令与迁移清单
├── quickstart/                # 快速级独立副本
│   ├── Dockerfile
│   ├── .dockerignore
│   └── .env.example
├── production/                # 生产级独立副本
│   ├── Dockerfile
│   ├── .dockerignore
│   └── .env.example
└── hardened/                  # 企业加固级独立副本
    ├── Dockerfile
    ├── .dockerignore
    └── .env.example
```

## 三级交付等级对比

| 能力维度 | `quickstart`（快速级） | `production`（生产级） | `hardened`（企业加固级） |
| :--- | :--- | :--- | :--- |
| **适用场景** | 本地快速体验、功能原型验证 | 线上常规流量标准交付基线 | 严格安全合规、零非必要攻击面场景 |
| **构建阶段** | `maven:3.9.9-eclipse-temurin-21-noble`（`--platform=$BUILDPLATFORM` 原生编译） | 叠加 `dependency:go-offline` 与 BuildKit `.m2` 缓存及 `jarmode=tools` 分层解包 | 叠加 `dependency:go-offline` 与 BuildKit `.m2` 缓存及 `jarmode=tools` 分层解包 |
| **运行基础镜像** | `eclipse-temurin:21-jre-noble` | `eclipse-temurin:21-jre-noble` | `gcr.io/distroless/java21-debian12:nonroot`（无 `shell` / 无包管理器） |
| **运行用户权限** | 镜像默认用户 | 专用低权限用户（`appuser`，UID/GID `10001`） | Distroless 内置 `nonroot` 用户（UID/GID `65532`），应用产物只读 |
| **JVM 内存参数** | 默认 JVM 行为 | `-XX:InitialRAMPercentage=25.0 -XX:MaxRAMPercentage=75.0` 等容器内存感知参数 | 内置容器内存感知参数与 `/tmp` 临时目录指向 |
| **端口与管理隔离** | 单端口 `8080` 同时提供业务与 Actuator | 业务 `8080` 与管理端口 `8081` 拆分隔离 | 业务 `8080` 与管理端口 `8081` 拆分隔离 |
| **容器健康检查** | `curl` 探测 `8080/actuator/health` | `curl` 探测 `8081/actuator/health/readiness` | 内置零依赖 JDK 探针 `com.ateng.deploy.HealthCheck`（`-Xmx32m`） |
| **只读根文件系统** | 未针对性配置 | 支持配合挂载 `/tmp` 启用 | 原生兼容 `--read-only` + `--tmpfs /tmp` + `--cap-drop=ALL` |
| **信号与优雅停机** | `ENTRYPOINT ["java", ...]` 原生接收 `SIGTERM` | `exec java ...` 替换 `sh` 成为 PID 1，透传 `SIGTERM` | `ENTRYPOINT ["java", ...]` 原生作为 PID 1 接收 `SIGTERM` |
| **主要解决的线上风险** | 消除手工配置环境差异 | 解决缓存慢构建、root 提权风险、堆超限 OOMKilled 与管理端点暴露公网风险 | 消除容器内 `shell` / `curl` 逃逸与篡改隐患，满足最小攻击面合规审计 |

## 加速源、时区与多架构构建参数

三个等级的 `Dockerfile` 均默认使用官方上游源，同时暴露以下构建参数便于受限网络环境切换及版本注入：

| 构建参数 (`--build-arg`) | 默认值 | 用途说明 |
| :--- | :--- | :--- |
| `BASE_IMAGE_REGISTRY` | `docker.io` | 替换 Docker Hub 上游镜像仓库前缀（例如内部镜像代理地址） |
| `GCR_REGISTRY` | `gcr.io` | 仅 `hardened` 使用，用于替换 Distroless 基础镜像仓库前缀 |
| `MAVEN_MIRROR_URL` | `""`（官方中央仓库） | 可选注入国内 Maven 镜像加速地址（如 `https://maven.aliyun.com/repository/public`） |
| `APP_VERSION` | `0.1.0-SNAPSHOT` | 注入至应用构建产物的版本号，在 `/api/info` 中可观测 |

所有镜像默认设置 `ENV TZ=Asia/Shanghai`，并在运行时支持通过 `-e TZ=UTC` 等标准环境变量按需覆盖。

## 构建与黑盒验证

以下命令均在**仓库根目录**下执行，构建上下文统一指向 `templates/spring-boot-jar/app`：

### 1. 构建三级镜像

```bash
# 快速级（quickstart）
docker build \
  -f templates/spring-boot-jar/deploy/docker/quickstart/Dockerfile \
  --build-arg APP_VERSION=v0.1.0 \
  -t ghcr.io/atengk/deploy-templates/spring-boot-jar:quickstart \
  templates/spring-boot-jar/app

# 生产级（production）
docker build \
  -f templates/spring-boot-jar/deploy/docker/production/Dockerfile \
  --build-arg APP_VERSION=v0.1.0 \
  -t ghcr.io/atengk/deploy-templates/spring-boot-jar:production \
  templates/spring-boot-jar/app

# 企业加固级（hardened）
docker build \
  -f templates/spring-boot-jar/deploy/docker/hardened/Dockerfile \
  --build-arg APP_VERSION=v0.1.0 \
  -t ghcr.io/atengk/deploy-templates/spring-boot-jar:hardened \
  templates/spring-boot-jar/app
```

如需在国内网络环境下启用加速源，可附加构建参数（例如）：

```bash
docker build \
  -f templates/spring-boot-jar/deploy/docker/production/Dockerfile \
  --build-arg BASE_IMAGE_REGISTRY=docker.m.daocloud.io \
  --build-arg MAVEN_MIRROR_URL=https://maven.aliyun.com/repository/public \
  --build-arg APP_VERSION=v0.1.0 \
  -t spring-boot-jar:production \
  templates/spring-boot-jar/app
```

### 2. 启动运行与黑盒验证

```bash
# 验证 quickstart（单端口 8080）
docker run -d --name sb-quickstart -p 8080:8080 \
  --env-file templates/spring-boot-jar/deploy/docker/quickstart/.env.example \
  ghcr.io/atengk/deploy-templates/spring-boot-jar:quickstart
curl -fsS http://127.0.0.1:8080/api/info
curl -fsS http://127.0.0.1:8080/actuator/health
docker rm -f sb-quickstart

# 验证 production（独立管理端口 8081、非 root、容器内存限额）
docker run -d --name sb-production -p 8080:8080 -p 127.0.0.1:8081:8081 \
  --memory=512m \
  --env-file templates/spring-boot-jar/deploy/docker/production/.env.example \
  ghcr.io/atengk/deploy-templates/spring-boot-jar:production
curl -fsS http://127.0.0.1:8080/api/info
curl -fsS http://127.0.0.1:8081/actuator/health/readiness
curl -fsS http://127.0.0.1:8081/actuator/prometheus | head -n 5
docker inspect --format '{{.State.Health.Status}} uid={{.Config.User}}' sb-production
docker stop -t 25 sb-production && docker rm sb-production

# 验证 hardened（只读根文件系统 + 临时挂载 + 移除全部 Capabilities + 禁止提权）
docker run -d --name sb-hardened -p 8080:8080 -p 127.0.0.1:8081:8081 \
  --memory=512m \
  --read-only \
  --tmpfs /tmp:rw,noexec,nosuid,size=64m \
  --cap-drop=ALL \
  --security-opt=no-new-privileges:true \
  --env-file templates/spring-boot-jar/deploy/docker/hardened/.env.example \
  ghcr.io/atengk/deploy-templates/spring-boot-jar:hardened
curl -fsS http://127.0.0.1:8080/api/info
curl -fsS http://127.0.0.1:8081/actuator/health/readiness
curl -fsS http://127.0.0.1:8081/actuator/prometheus | head -n 5
docker inspect --format '{{.State.Health.Status}} uid={{.Config.User}}' sb-hardened
docker stop -t 25 sb-hardened && docker rm sb-hardened
```

### 3. 静态检查与镜像安全扫描

```bash
# Dockerfile 最佳实践检查
hadolint templates/spring-boot-jar/deploy/docker/quickstart/Dockerfile
hadolint templates/spring-boot-jar/deploy/docker/production/Dockerfile
hadolint templates/spring-boot-jar/deploy/docker/hardened/Dockerfile

# 容器漏洞扫描（存在已修复版本的高危与严重漏洞报告，CRITICAL 级阻断）
trivy image --ignore-unfixed --severity CRITICAL --exit-code 1 ghcr.io/atengk/deploy-templates/spring-boot-jar:hardened
trivy image --severity HIGH,CRITICAL ghcr.io/atengk/deploy-templates/spring-boot-jar:hardened
```

## 迁移到自有项目改造清单

将任意一个**交付等级**目录（例如 `production/` 或 `hardened/`）内的 `Dockerfile`、`.dockerignore` 与 `.env.example` 直接拷贝至自有 Spring Boot 3 Maven 项目根目录后，按以下清单逐项核对改造：

1. **对齐构建产物文件名**：若自有项目 `pom.xml` 未配置 `<finalName>app</finalName>`，可将 `Dockerfile` 中的 `/build/target/app.jar` 调整为 `/build/target/*.jar`（注意仅匹配可执行 Jar，排除 `*-plain.jar` 或 `*.jar.original`），或在自有 `pom.xml` 中显式设置 `<finalName>app</finalName>`。
2. **确认 Spring Boot 分层工具版本**：`java -Djarmode=tools ... extract --layers` 要求 Spring Boot `3.3+`；若自有项目仍停留在 Spring Boot `3.0`–`3.2`，请先升级或改用 `jarmode=layertools` 及 `JarLauncher` 启动方式。
3. **接入健康探针（`hardened` 必做）**：将 `com.ateng.deploy.HealthCheck` 复制到自有源码包下（或调整 `Dockerfile` 中 `HEALTHCHECK` 类路径），并确保自有应用已引入 `spring-boot-starter-actuator` 且开启 `management.endpoint.health.probes.enabled=true`。
4. **保持管理端口与优雅停机配置**：确保自有项目 `application.yml` 已启用 `server.shutdown=graceful`、未写死 `management.server.port`，以便通过环境变量 `MANAGEMENT_SERVER_PORT=8081` 拆分管理端口。
5. **排查只读根文件系统写入路径**：启用 `--read-only` 前检查自有代码是否存在本地日志落盘、文件上传临时存储或本地缓存目录写入，统一改写至 `/tmp` 或外部对象存储/数据库。
6. **注入外部有状态依赖**：遵循**单应用交付**原则，切勿在镜像内固化数据库密码或中间件地址；复制 `.env.example` 为 `.env`（已被 `.dockerignore` 排除）或通过编排系统注入生产环境变量。
7. **更新 OCI 标签与镜像坐标**：将 `LABEL` 元数据替换为自有仓库信息，上线生产环境时锁定不可变镜像版本标签或 Digest。
