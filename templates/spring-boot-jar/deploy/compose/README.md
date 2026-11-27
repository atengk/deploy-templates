# Spring Boot 3 Docker Compose 部署载体说明

本目录提供 **JDK 21 + Maven + Spring Boot 3** **技术栈**在 Docker Compose **部署载体**下的三级**独立等级副本**（`quickstart`、`production`、`hardened`）。各等级目录相互独立、互不继承，均严格遵循**单应用交付**边界（不捆绑数据库、缓存或消息队列等有状态中间件），并同时声明本地构建入口（复用同等级 [`../docker/`](../docker/README.md) 中的 `Dockerfile` 与 [`../../app/`](../../app/pom.xml) 构建上下文）与 GHCR 容器镜像坐标。

## 目录拓扑

```text
deploy/compose/
├── README.md                     # 本说明文档
├── quickstart/                   # 快速级：极简单端口 8080 启动配置
│   ├── .env.example
│   └── compose.yaml
├── production/                   # 生产级：非 root（10001）、8081 管理端口隔离、健康检查、资源限额与日志滚动
│   ├── .env.example
│   └── compose.yaml
└── hardened/                     # 企业加固级：Distroless 非 root（65532）、只读根文件系统、/tmp 临时盘、全量移除 Capabilities 与内置 JDK 探针
    ├── .env.example
    └── compose.yaml
```

## 三级加固差异对比

| 能力维度 | [`quickstart`](./quickstart/compose.yaml)（快速级） | [`production`](./production/compose.yaml)（生产级） | [`hardened`](./hardened/compose.yaml)（企业加固级） |
| :--- | :--- | :--- | :--- |
| **镜像坐标与构建复用** | `ghcr.io/atengk/deploy-templates/spring-boot-jar:quickstart`<br>上下文 `../../../app`，复用 `../docker/quickstart/Dockerfile` | `ghcr.io/atengk/deploy-templates/spring-boot-jar:production`<br>上下文 `../../../app`，复用 `../docker/production/Dockerfile` | `ghcr.io/atengk/deploy-templates/spring-boot-jar:hardened`<br>上下文 `../../../app`，复用 `../docker/hardened/Dockerfile`（支持 `GCR_REGISTRY`） |
| **运行用户权限** | 镜像默认用户 | 显式声明 `user: "10001:10001"`（低权限专用用户） | 显式声明 `user: "65532:65532"`（Distroless 无 shell `nonroot` 用户） |
| **端口映射与管理隔离** | 单端口映射 `${APP_PORT:-8080}:${SERVER_PORT:-8080}`，业务与 Actuator 共用 `8080` | 仅对外映射业务端口 `8080`，管理端口 `8081` 隔离在容器内部不暴露至宿主机公网 | 仅对外映射业务端口 `8080`，管理端口 `8081` 隔离在容器内部不暴露至宿主机公网 |
| **容器健康检查** | 继承镜像内置 `curl` 探测 `8080/actuator/health` | 显式配置 `curl` 探测 `8081/actuator/health/readiness` | 显式配置内置零依赖 JDK 探针 `com.ateng.deploy.HealthCheck`（`-Xms8m -Xmx32m`） |
| **重启与优雅停机** | 不配置自动重启与额外停机宽限 | `restart: unless-stopped`、`stop_grace_period: 30s`（覆盖应用 20 秒优雅关闭期） | `restart: unless-stopped`、`stop_grace_period: 30s`（覆盖应用 20 秒优雅关闭期） |
| **资源限额与日志滚动** | 不限制资源与日志体积 | `mem_limit: 512m`、`cpus: 1.0`、`pids_limit: 256`；`json-file` 日志 `10m × 5` | `mem_limit: 512m`、`cpus: 1.0`、`pids_limit: 256`；`json-file` 日志 `10m × 5` |
| **只读与内核权限加固** | 默认可写根文件系统与默认权限集 | 延续非 root 与环境变量 `TOMCAT_BASEDIR=/tmp/tomcat` 基线 | `read_only: true`、`/tmp` 挂载 `tmpfs`（`rw,noexec,nosuid,nodev,size=128m`）、`cap_drop: ["ALL"]`、`security_opt: ["no-new-privileges:true"]` |

## 本地构建与拉取 GHCR 命令

进入目标交付等级目录（`quickstart`、`production` 或 `hardened`）后，既可直接复用同等级 `Dockerfile` 基于本地源码构建启动，也可直接拉取 GHCR 已发布镜像运行。

### 1. 配置语法校验与本地构建启动

```bash
cd templates/spring-boot-jar/deploy/compose/production

# 校验 Compose 编排语法与环境变量插值结果
docker compose --env-file .env.example config

# 使用官方上游源本地构建并后台启动（含等待健康检查变绿）
docker compose --env-file .env.example up -d --build --wait

# 国内网络环境下通过构建参数切换基础镜像仓库与 Maven 镜像加速源
BASE_IMAGE_REGISTRY=docker.m.daocloud.io \
MAVEN_MIRROR_URL=https://maven.aliyun.com/repository/public \
APP_VERSION=v0.1.0 \
  docker compose --env-file .env.example up -d --build --wait
```

若构建 `hardened` 交付等级且需替换 Distroless 基础镜像仓库，可额外传入 `GCR_REGISTRY`：

```bash
cd templates/spring-boot-jar/deploy/compose/hardened

BASE_IMAGE_REGISTRY=docker.m.daocloud.io \
GCR_REGISTRY=gcr.m.daocloud.io \
MAVEN_MIRROR_URL=https://maven.aliyun.com/repository/public \
APP_VERSION=v0.1.0 \
  docker compose --env-file .env.example up -d --build --wait
```

### 2. 直接拉取 GHCR 镜像启动与停止

```bash
cd templates/spring-boot-jar/deploy/compose/production

# 拉取对应交付等级已发布镜像（不触发本地构建）
docker compose pull
docker compose --env-file .env.example up -d --no-build --wait

# 触发 SIGTERM 优雅停机（最长等待 stop_grace_period: 30s）并清理容器
docker compose down
```

### 3. 三级快速启停参考

```bash
# 快速级（单端口 8080；可通过 APP_PORT 避免宿主机端口冲突）
cd templates/spring-boot-jar/deploy/compose/quickstart
APP_PORT=18080 docker compose --env-file .env.example up -d --build --wait
curl -fsS http://127.0.0.1:18080/api/info
curl -fsS http://127.0.0.1:18080/actuator/health
docker compose down

# 企业加固级（Distroless + read_only + cap_drop: ALL + 内置 JDK 探针）
cd ../hardened
docker compose --env-file .env.example up -d --build --wait
docker compose ps
docker compose down
```

## 端口隔离与安全加固验证说明

以下验证步骤适用于 `production` 与 `hardened`（以 `hardened` 为例），用于确认业务端口可达、管理端口 `8081` 未暴露至宿主机公网、非 root 与只读根文件系统协同正常，以及内置 JDK 探针 `com.ateng.deploy.HealthCheck` 正常工作：

```bash
cd templates/spring-boot-jar/deploy/compose/hardened

# 1. 启动服务并等待健康检查就绪
docker compose --env-file .env.example up -d --build --wait

# 2. 验证业务端口 8080 正常响应，且 OTLP 默认关闭（otlpEnabled=false，无连接报错日志）
curl -fsS http://127.0.0.1:8080/
curl -fsS http://127.0.0.1:8080/api/info
docker compose logs --tail=50 app

# 3. 验证端口隔离：业务端口访问 Actuator 返回 404，且宿主机 8081 未对外开放监听
curl -sS -o /dev/null -w "%{http_code}\n" http://127.0.0.1:8080/actuator/health
curl -sS -o /dev/null -w "%{http_code}\n" http://127.0.0.1:8080/actuator/prometheus
# 预期上述两次请求均输出 404；宿主机访问 http://127.0.0.1:8081 将提示连接拒绝

# 4. 验证容器运行用户、健康状态与只读挂载配置（hardened 无 shell，通过 inspect 与探针验证）
docker compose ps
CONTAINER_ID="$(docker compose ps -q app)"
docker inspect --format 'status={{.State.Health.Status}} user={{.Config.User}} readOnly={{.HostConfig.ReadonlyRootfs}}' "${CONTAINER_ID}"

# 5. 验证在只读根文件系统模式下手动调用内置 JDK 探针探测管理端口 8081
docker compose exec app java -Xms8m -Xmx32m -cp /app/app.jar com.ateng.deploy.HealthCheck

# 6. 验证优雅停机与清理
docker compose stop
docker compose logs --tail=20 app
docker compose down
```

> [!NOTE]
> `production` 与 `hardened` 的 `compose.yaml` 默认仅发布 `${APP_PORT:-8080}` 业务端口。如需在受控内网采集 Prometheus 指标，建议将管理服务与 Prometheus 部署于同一隔离 Compose 网络并直接访问服务名 `http://app:8081/actuator/prometheus`，切勿在公网宿主机映射 `8081:8081`。

## 迁移自有项目改造清单

将本模板引入自有 Spring Boot 3 项目时，请按以下清单逐项核对改造：

1. **拷贝目标交付等级目录及构建文件**：选定目标**交付等级**（如 `production` 或 `hardened`），将该等级的 `compose.yaml`、`.env.example` 与同等级 [`../docker/`](../docker/README.md) 目录下的 `Dockerfile`、`.dockerignore` 一并拷贝至自有项目。
2. **调整 `build.context` 与 `build.dockerfile` 路径**：本仓库中 `compose.yaml` 的 `build.context` 指向 `../../../app`，`build.dockerfile` 按 Compose 规范相对于 `build.context` 指向 `../deploy/docker/<tier>/Dockerfile`。迁移至自有独立项目根目录后，通常将 `compose.yaml` 置于项目根目录并调整为 `context: .` 与 `dockerfile: Dockerfile`，同时确保自有 `pom.xml` 配置 `<finalName>app</finalName>`（或同步调整 `Dockerfile` 中产物文件名）。
3. **接入内置探针与管理端口契约（`hardened` 必做）**：将 `com.ateng.deploy.HealthCheck` 类纳入自有项目源码（或调整 `Dockerfile` 与 `compose.yaml` 中 `healthcheck.test` 类路径），并确保 `application.yml` 启用了 `management.endpoint.health.probes.enabled=true`、`server.shutdown=graceful` 且未写死 `management.server.port`。
4. **替换私有镜像仓库与锁定不可变标识**：将 `compose.yaml` 中的 `image:` 替换为企业私有镜像仓库地址；在 `hardened` 正式上线前，务必将浮动标签 `:hardened` 替换为不可变版本号标签（如 `:1.0.0-hardened`）或镜像 Digest（`@sha256:...`）。
5. **检查只读根文件系统与外部有状态依赖**：遵循**单应用交付**原则，根据 `.env.example` 复制生成本地 `.env`（并确认已被 `.gitignore` 与 `.dockerignore` 忽略）注入外部数据库、缓存与 `OTEL_EXPORTER_OTLP_ENDPOINT` 等配置；启用 `read_only: true` 前确认应用无写死本地磁盘日志或缓存路径，统一收敛至 `/tmp` 或外部存储。
6. **按负载调优资源限额与停机宽限**：结合压测结果与 JVM 堆外内存占用调整 `mem_limit`、`cpus`、`pids_limit` 及 `JAVA_OPTS`（`production`），并确保 `stop_grace_period` 大于 Spring Boot `spring.lifecycle.timeout-per-shutdown-phase`。
