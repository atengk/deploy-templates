# Spring Boot 3 宿主机直跑（`systemd`）部署载体

本目录提供 Spring Boot 3 可执行 Jar 在**宿主机直跑（Host / `systemd`）** **部署载体**下的三级**独立等级副本**：`quickstart`、`production`、`hardened`，面向 **Ubuntu 22.04/24.04**、**Debian 12** 与 **Rocky/RHEL 9** 等主流 `systemd` Linux 发行版。各等级均基于 [唯一参考应用](../../app/) 契约设计，严格遵循**单应用交付**边界，支持直接拷贝任意单一等级目录落地自有项目。

## 目录结构

```text
templates/spring-boot-jar/deploy/systemd/
├── README.md                  # 发行版安装指引、三级对比、journald 运维与迁移清单
├── quickstart/                # 快速级独立副本
│   ├── spring-boot-jar.service
│   ├── app.env.example
│   ├── deploy.sh
│   ├── rollback.sh
│   └── healthcheck.sh
├── production/                # 生产级独立副本
│   ├── spring-boot-jar.service
│   ├── app.env.example
│   ├── nginx.conf
│   ├── deploy.sh
│   ├── rollback.sh
│   └── healthcheck.sh
└── hardened/                  # 企业加固级独立副本
    ├── spring-boot-jar.service
    ├── app.env.example
    ├── nginx.conf
    ├── deploy.sh
    ├── rollback.sh
    └── healthcheck.sh
```

## 三级交付等级对比

| 能力维度 | `quickstart`（快速级） | `production`（生产级） | `hardened`（企业加固级） |
| :--- | :--- | :--- | :--- |
| **适用场景** | 测试宿主机快速验证、功能演示 | 线上常规流量的无容器标准交付基线 | 严格安全审计、最小权限与攻击面收敛场景 |
| **运行用户权限** | `systemd` 默认身份 | 专用低权系统用户 `springapp`（`nologin`） | 专用低权系统用户 `springapp`，且产物 `app.jar` 设为 `root:springapp` 只读 `0440` |
| **目录与原子发布** | `/opt/spring-boot-jar/releases/<version>` + `current` 软链 | 同左，目录权限 `0750`、`app.jar` 权限 `0640` | 同左，目录权限 `0750`、`app.jar` 权限 `0440` |
| **一键回滚能力** | 内置 `rollback.sh`（支持自动回退上一版本与指定版本） | 内置 `rollback.sh`（支持自动回退上一版本与指定版本） | 内置 `rollback.sh`（支持自动回退上一版本与指定版本） |
| **端口与访问隔离** | 单端口 `8080` 提供业务与 `/actuator/health` | 业务 `8080` 与管理端口 `8081` 拆分，配合 Nginx 屏蔽 `/actuator` | 默认绑定回环地址 `127.0.0.1:8080/8081`，强制经 Nginx 入口并屏蔽 `/actuator` |
| **内存与资源限额** | JVM 基础堆参数 `-Xms128m -Xmx512m` | `MemoryMax=768M` + `-XX:MaxRAMPercentage=75.0` + `LimitNOFILE=65536` | 增加 `TasksMax=256` 与 `UMask=0027` 收紧进程与文件权限 |
| **优雅停机治理** | 默认 `SIGTERM` + `SuccessExitStatus=143` | 显式 `KillSignal=SIGTERM` + `TimeoutStopSec=30`（覆盖 20s 宽限期） | 同 `production`，保障在途请求排空 |
| **`systemd` 安全沙箱** | 未启用沙箱隔离 | 聚焦低权用户与 cgroup 资源保护 | 启用 `ProtectSystem=strict`、`PrivateTmp=yes`、`NoNewPrivileges=yes`、能力清零与系统调用白名单 |
| **前置 Nginx 策略** | 无内置 Nginx 配置 | 反向代理至 `127.0.0.1:8080`、屏蔽 `/actuator`、标准代理头与 TLS 占位 | 叠加严格安全响应头（CSP、HSTS 占位、防点击劫持）与危险 HTTP 方法拦截 |
| **日志纳管方式** | 标准流直出 `systemd-journald` | 标准流直出 `systemd-journald` | 标准流直出 `systemd-journald` |

## 发行版前置准备

### 1. 安装 Java 21 运行时与 Nginx

**Ubuntu 22.04 / 24.04 与 Debian 12**：

```bash
sudo apt-get update
sudo apt-get install -y openjdk-21-jre-headless curl nginx
java -version
```

> [!NOTE]
> 若 Ubuntu 22.04 默认软件源未包含 `openjdk-21-jre-headless`，可采用 Eclipse Temurin APT 官方源安装 `temurin-21-jre`，并确认 `/usr/bin/java` 软链指向正确版本。

**Rocky Linux 9 / RHEL 9**：

```bash
sudo dnf install -y java-21-openjdk-headless curl nginx
java -version

# 若开启 SELinux，需允许 Nginx 反向代理本机回环端口 127.0.0.1:8080
sudo setsebool -P httpd_can_network_connect 1
```

### 2. 创建低权运行用户与标准目录（`production` / `hardened` 必做）

```bash
sudo useradd --system --no-create-home --shell /usr/sbin/nologin springapp
sudo mkdir -p /opt/spring-boot-jar/releases /etc/spring-boot-jar
sudo chown -R springapp:springapp /opt/spring-boot-jar
```

### 3. 安装环境变量配置（控制权限 `0640`）

以 `hardened` 等级为例（`quickstart` 与 `production` 拷贝各自目录下的对应文件）：

```bash
sudo cp templates/spring-boot-jar/deploy/systemd/hardened/app.env.example /etc/spring-boot-jar/app.env
sudo chown root:springapp /etc/spring-boot-jar/app.env
sudo chmod 0640 /etc/spring-boot-jar/app.env
sudoedit /etc/spring-boot-jar/app.env
```

> [!IMPORTANT]
> `/etc/spring-boot-jar/app.env` 将承载外部数据库密码与接口密钥等敏感配置，务必保持 `0640`（`root:springapp`）或更严格权限，切勿设为全局可读，也严禁将真实凭据提交至代码仓库。

## 服务单元安装、发布与回滚

### 1. 构建可执行 Jar 产物

在仓库根目录编译参考应用（完整契约参见 [Spring Boot 3 技术栈说明](../../README.md)）：

```bash
mvn -f templates/spring-boot-jar/app/pom.xml -DskipTests package -Dapp.version=v1.0.0
```

### 2. 安装 `systemd` 服务单元与 Nginx 配置

```bash
# 安装 systemd 服务单元（按目标交付等级三选一）
sudo cp templates/spring-boot-jar/deploy/systemd/hardened/spring-boot-jar.service /etc/systemd/system/spring-boot-jar.service
sudo systemctl daemon-reload
sudo systemctl enable spring-boot-jar.service

# 安装并校验前置 Nginx 配置（production / hardened）
sudo cp templates/spring-boot-jar/deploy/systemd/hardened/nginx.conf /etc/nginx/conf.d/spring-boot-jar.conf
sudo nginx -t
sudo systemctl enable --now nginx
sudo systemctl reload nginx
```

### 3. 首次发布、二次升级与一键回滚

```bash
# 首次发布 v1.0.0（原子切换 /opt/spring-boot-jar/current 并自动重启与健康探针）
sudo bash templates/spring-boot-jar/deploy/systemd/hardened/deploy.sh \
  templates/spring-boot-jar/app/target/app.jar v1.0.0

# 查看本地已发布版本与 current 指向
sudo bash templates/spring-boot-jar/deploy/systemd/hardened/rollback.sh --list

# 构建并二次升级 v1.1.0
mvn -f templates/spring-boot-jar/app/pom.xml -DskipTests package -Dapp.version=v1.1.0
sudo bash templates/spring-boot-jar/deploy/systemd/hardened/deploy.sh \
  templates/spring-boot-jar/app/target/app.jar v1.1.0

# 若新版本异常，一键回滚至上一版本（或显式指定 v1.0.0）
sudo bash templates/spring-boot-jar/deploy/systemd/hardened/rollback.sh
# sudo bash templates/spring-boot-jar/deploy/systemd/hardened/rollback.sh v1.0.0

# 手工执行健康探针
bash templates/spring-boot-jar/deploy/systemd/hardened/healthcheck.sh
```

## `systemd-journald` 日志查询与常用运维命令

所有应用标准输出（`stdout`）与标准错误（`stderr`）均已交由 `systemd-journald` 统一采集，无需额外配置本地文件滚动切割（`logrotate`）：

```bash
# 查看服务运行状态与最近日志
sudo systemctl status spring-boot-jar.service

# 实时追踪日志流
sudo journalctl -u spring-boot-jar.service -f

# 查看最近 200 行或最近 30 分钟日志
sudo journalctl -u spring-boot-jar.service -n 200 --no-pager
sudo journalctl -u spring-boot-jar.service --since "30 minutes ago" --no-pager

# 仅筛选错误优先级日志
sudo journalctl -u spring-boot-jar.service -p err --no-pager

# 查看服务安全沙箱评分（仅 Linux systemd 宿主机可执行）
systemd-analyze security spring-boot-jar.service
```

## 无 root / 无 `systemd` 隔离演练步骤

全部 Bash 运维脚本均内置可覆盖环境变量接缝，无需 `root` 权限或真实 `systemd` 守护进程即可在临时目录完成端到端黑盒演练：

| 环境变量接缝 | 默认值 | 用途说明 |
| :--- | :--- | :--- |
| `DEPLOY_ROOT` | `/opt/spring-boot-jar` | 覆盖版本库与 `current` 软链根目录 |
| `ENV_FILE` | `/etc/spring-boot-jar/app.env` | 覆盖环境配置文件读取路径 |
| `SERVICE_NAME` | `spring-boot-jar` | 覆盖目标 `systemd` 服务名称 |
| `SYSTEMCTL_CMD` | `systemctl` | 替换为测试桩脚本记录启停调用 |
| `SKIP_SYSTEMCTL` | `false` | 设为 `true` 跳过 `systemctl` 与默认健康检查 |
| `KEEP_RELEASES` | `5` | 历史版本保留个数（`0` 表示不自动清理） |
| `HEALTHCHECK_URL` | 按等级默认端口与路径拼接 | 显式覆盖探测目标 URL |
| `CURL_CMD` | `curl` | 替换探针使用的 `curl` 命令或测试桩 |

在当前用户临时目录演练完整生命周期：

```bash
WORK_DIR="$(mktemp -d)"
mkdir -p "${WORK_DIR}/etc" "${WORK_DIR}/artifacts"
printf 'MANAGEMENT_SERVER_PORT=18081\n' > "${WORK_DIR}/etc/app.env"
printf 'mock-jar-v1.0.0\n' > "${WORK_DIR}/artifacts/app-1.0.0.jar"
printf 'mock-jar-v1.1.0\n' > "${WORK_DIR}/artifacts/app-1.1.0.jar"

export DEPLOY_ROOT="${WORK_DIR}/opt/spring-boot-jar"
export ENV_FILE="${WORK_DIR}/etc/app.env"
export SKIP_SYSTEMCTL="true"

# 1. 首次发布 v1.0.0 并断言 current 软链
bash templates/spring-boot-jar/deploy/systemd/hardened/deploy.sh "${WORK_DIR}/artifacts/app-1.0.0.jar" v1.0.0
readlink "${DEPLOY_ROOT}/current"

# 2. 二次升级 v1.1.0 并断言 current 软链
bash templates/spring-boot-jar/deploy/systemd/hardened/deploy.sh "${WORK_DIR}/artifacts/app-1.1.0.jar" v1.1.0
readlink "${DEPLOY_ROOT}/current"

# 3. 一键回滚至 v1.0.0 并断言 current 软链复原
bash templates/spring-boot-jar/deploy/systemd/hardened/rollback.sh
readlink "${DEPLOY_ROOT}/current"

rm -rf "${WORK_DIR}"
```

## 静态校验命令（Linux CI 门禁）

在配备完整宿主机工具链的 Linux 节点上，可通过以下命令对脚本、服务单元与 Nginx 配置执行静态检查：

```bash
# 1. Shell 脚本静态检查
shellcheck \
  templates/spring-boot-jar/deploy/systemd/quickstart/*.sh \
  templates/spring-boot-jar/deploy/systemd/production/*.sh \
  templates/spring-boot-jar/deploy/systemd/hardened/*.sh

# 2. systemd 服务单元静态语法验证
systemd-analyze verify \
  templates/spring-boot-jar/deploy/systemd/quickstart/spring-boot-jar.service \
  templates/spring-boot-jar/deploy/systemd/production/spring-boot-jar.service \
  templates/spring-boot-jar/deploy/systemd/hardened/spring-boot-jar.service

# 3. Nginx 站点配置片段语法检查（包装临时 http 上下文）
for tier in production hardened; do
  TMP_NGINX_CONF="$(mktemp)"
  printf 'events {}\nhttp {\n  include %s/templates/spring-boot-jar/deploy/systemd/%s/nginx.conf;\n}\n' "$(pwd)" "${tier}" > "${TMP_NGINX_CONF}"
  nginx -t -c "${TMP_NGINX_CONF}"
  rm -f "${TMP_NGINX_CONF}"
done
```

## 迁移到自有项目改造清单

将任意一个**交付等级**目录（例如 `production/` 或 `hardened/`）内的全部文件复制到自有项目的运维部署目录后，按以下清单逐项核对调整：

1. **替换应用标识与标准路径**：按需将服务名 `spring-boot-jar`、安装基目录 `/opt/spring-boot-jar`、配置路径 `/etc/spring-boot-jar/app.env` 与低权用户名 `springapp` 统一替换为自有服务命名。
2. **核对 JDK 安装路径**：各 `.service` 默认使用 `/usr/bin/java`；若目标宿主机 JDK 安装在自定义目录（如 `/opt/jdk-21/bin/java`），请同步调整 `ExecStart=` 路径或创建系统级软链。
3. **检查本地文件写入需求（`hardened` 重点核对）**：`hardened` 服务单元启用了 `ProtectSystem=strict`，除 `/tmp`（私有挂载）外全盘只读；若自有应用确需向磁盘持久化上传文件或日志目录，请在 `[Service]` 段按最小路径放行 `ReadWritePaths=/var/lib/your-app`。
4. **配置 Actuator 与管理端口**：确保自有项目已引入 `spring-boot-starter-actuator` 且启用 `server.shutdown=graceful` 与探针开关（`management.endpoint.health.probes.enabled=true`），不在 `application.yml` 中硬编码固定端口，由 `app.env` 统一注入 `SERVER_PORT` 与 `MANAGEMENT_SERVER_PORT`。
5. **配置 Nginx 域名与 HTTPS 证书**：将 `nginx.conf` 中的 `server_name _;` 替换为实际公网域名，解除注释并配置有效 TLS 证书与 HTTP 跳转 HTTPS 规则；仅在全站启用 HTTPS 后取消注释 `Strict-Transport-Security` 响应头。
6. **注入外部有状态依赖**：遵循**单应用交付**原则，将数据库、缓存与对象存储的连接串及访问凭据写入宿主机受控的 `app.env`（保持 `0640` 权限），切勿硬编码进仓库或脚本中。
