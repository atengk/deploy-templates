# Spring Boot 3（可执行 Jar）技术栈

本目录提供基于 **JDK 21 + Maven + Spring Boot `3.5.16`** 的**参考应用**与多**部署载体**参考配置，严格遵循[仓库领域词汇表](../../CONTEXT.md)与**单应用交付**边界（不捆绑数据库、缓存或消息队列等有状态中间件）。

## 目录结构

```text
templates/spring-boot-jar/
├── README.md                  # 技术栈总览、参考应用契约与部署载体导航
├── app/                       # 唯一共享参考应用源码（供全部四类载体共用）
│   ├── pom.xml
│   ├── .dockerignore
│   └── src/
└── deploy/
    ├── docker/                # Docker 部署载体（quickstart / production / hardened）
    ├── compose/               # Docker Compose 部署载体（quickstart / production / hardened）
    ├── systemd/               # 宿主机直跑 systemd 部署载体（quickstart / production / hardened）
    └── kubernetes/            # Kubernetes 部署载体（quickstart / production / hardened）
```

## 参考应用契约（`app/`）

### 1. HTTP 端点与端口隔离

| 端点路径 | 监听端口 | 适用等级 | 响应说明 |
| :--- | :--- | :--- | :--- |
| `GET /` | `${SERVER_PORT:8080}` | 全部等级 | 返回服务标识、当前版本号与可用端点列表（HTTP 200 JSON） |
| `GET /api/info` | `${SERVER_PORT:8080}` | 全部等级 | 返回应用名、版本、JVM 运行时、端口治理、可观测开关及非敏感配置摘要 |
| `GET /actuator/health` | `quickstart`: `8080`<br>`production` / `hardened`: `8081` | 全部等级 | 返回整体健康状态及 `livenessState` / `readinessState` 详情 |
| `GET /actuator/health/liveness` | `quickstart`: `8080`<br>`production` / `hardened`: `8081` | 全部等级 | Kubernetes / 容器存活探针端点 |
| `GET /actuator/health/readiness` | `quickstart`: `8080`<br>`production` / `hardened`: `8081` | 全部等级 | Kubernetes / 容器就绪探针端点 |
| `GET /actuator/prometheus` | `quickstart`: `8080`<br>`production` / `hardened`: `8081` | 全部等级 | 暴露 Micrometer + Prometheus 文本格式采集指标 |

> [!NOTE]
> 当设置环境变量 `MANAGEMENT_SERVER_PORT=8081` 时，Spring Boot 会自动将 Actuator 拆分至独立管理端口 `8081`，业务端口 `8080` 上访问 `/actuator/*` 将返回 `404`，从而天然防止运维与指标端点暴露至公网入口。

### 2. 环境变量契约

| 环境变量 | 默认值 | 说明 |
| :--- | :--- | :--- |
| `SERVER_PORT` | `8080` | 对外业务 HTTP 监听端口 |
| `MANAGEMENT_SERVER_PORT` | 未设置（共用业务端口） | 独立管理端口；`production` 与 `hardened` 默认设为 `8081` |
| `TZ` | 容器默认 `Asia/Shanghai` | 运行时默认时区，支持外部环境变量按需覆盖 |
| `APP_NAME` | `spring-boot-jar-app` | 应用标识名 |
| `APP_VERSION` | `@app.version@`（构建注入） | 运行时版本号；优先读取环境变量 `APP_VERSION`，否则回退 Maven 构建参数 `-Dapp.version` 注入值 |
| `APP_ENV` | `default` | 当前运行阶段标识（如 `quickstart`、`production`、`hardened`） |
| `APP_MESSAGE` | `Spring Boot 3 参考应用运行正常` | `/api/info` 中展示的非敏感提示文本 |
| `TOMCAT_BASEDIR` | `${java.io.tmpdir}/tomcat` | 内嵌 Tomcat 临时工作目录，只读根文件系统下可挂载 `/tmp` 配合使用 |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | 空（默认关闭） | 标准 OpenTelemetry Collector HTTP 端点（如 `http://otel-collector:4318`）；未配置或为空白时不激活 OTLP 导出，无 Collector 时零报错日志 |
| `EXTERNAL_API_URL` | 空 | 单应用交付边界外部依赖地址占位示例，`/api/info` 仅展示布尔配置状态而不泄露 URL 明文 |

### 3. 优雅停机与日志输出

- **优雅停机**：默认配置 `server.shutdown=graceful` 与 `spring.lifecycle.timeout-per-shutdown-phase=20s`，收到 `SIGTERM` 时停止接收新流量并在 20 秒宽限期内排空在途请求。
- **日志输出**：所有应用日志默认输出至标准输出（`stdout`）与标准错误（`stderr`），交由容器日志引擎或宿主机 `systemd-journald` 统一采集，不写本地磁盘日志文件。

### 4. 内置零依赖 JDK 健康检查探针（`com.ateng.deploy.HealthCheck`）

为支持无 `shell`、无 `curl` 的 Distroless `hardened` 镜像执行原生容器 `HEALTHCHECK`，参考应用内置零第三方依赖的轻量 JDK 探针类 `com.ateng.deploy.HealthCheck`（仅依赖标准库 `java.net.http.HttpClient`）。

探针目标 URL 解析优先级如下：
1. 命令行首个参数（如 `java -cp /app/app.jar com.ateng.deploy.HealthCheck http://127.0.0.1:8081/actuator/health/readiness`）
2. 环境变量 `HEALTHCHECK_URL`
3. 环境变量 `MANAGEMENT_SERVER_PORT` 或回退 `SERVER_PORT`（默认 `8080`）+ `HEALTHCHECK_PATH`（默认 `/actuator/health/readiness`）组装 `http://127.0.0.1:<port><path>`

探测响应 HTTP 状态码为 `200` 时退出码为 `0`，其余状态码、连接失败或超时统一返回退出码 `1`。

## 本地构建与验证

在仓库根目录下执行以下 Maven 命令完成测试与打包：

```bash
# 1. 运行单元测试与集成测试（覆盖 HealthCheck 探针、端口隔离与 OTLP 默认关闭）
mvn -f templates/spring-boot-jar/app/pom.xml test

# 2. 注入指定版本号打包可执行 Jar（输出至 templates/spring-boot-jar/app/target/app.jar）
mvn -f templates/spring-boot-jar/app/pom.xml -DskipTests package -Dapp.version=v0.1.0

# 3. 本地以独立管理端口方式启动并验证
SERVER_PORT=8080 MANAGEMENT_SERVER_PORT=8081 java -jar templates/spring-boot-jar/app/target/app.jar
```

## 四类部署载体入口

每个**部署载体**均按**独立等级副本**原则提供 `quickstart`、`production`、`hardened` 三级配置：

| 部署载体 | 载体目录 | 说明文档 | 交付状态 |
| :--- | :--- | :--- | :--- |
| **Docker** | `deploy/docker/` | [Docker 部署载体说明](./deploy/docker/README.md) | 已就绪（含 `quickstart` / `production` / `hardened`） |
| **Docker Compose** | `deploy/compose/` | [Docker Compose 部署载体说明](./deploy/compose/README.md) | 已就绪（含 `quickstart` / `production` / `hardened`） |
| **宿主机直跑（`systemd`）** | `deploy/systemd/` | [宿主机直跑部署载体说明](./deploy/systemd/README.md) | 已就绪（含 `quickstart` / `production` / `hardened`） |
| **Kubernetes** | `deploy/kubernetes/` | [Kubernetes 部署载体说明](./deploy/kubernetes/README.md) | 已就绪（含 `quickstart` / `production` / `hardened`） |
