# Vue 3 Docker Compose 部署载体说明

本目录提供 **Vue 3 + pnpm + Vite** **技术栈**在 Docker Compose **部署载体**下的三级**独立等级副本**（`quickstart`、`production`、`hardened`）。各等级目录相互独立、互不继承，均严格遵循**单应用交付**边界（不捆绑后端服务、数据库或缓存中间件），并同时声明本地构建入口（复用同等级 [`../docker/`](../docker/README.md) 中的 `Dockerfile`）与 GHCR 容器镜像坐标。

## 目录拓扑

```text
deploy/compose/
├── README.md                     # 本说明文档
├── quickstart/                   # 快速级：极简静态站点启动配置（容器监听 80）
│   ├── .env.example
│   └── compose.yaml
├── production/                   # 生产级：非特权端口 8080、运行时配置注入、健康检查、资源限额与日志滚动
│   ├── .env.example
│   └── compose.yaml
└── hardened/                     # 企业加固级：只读根文件系统、/tmp 临时内存盘、全量裁剪 Capabilities 与禁止提权
    ├── .env.example
    └── compose.yaml
```

## 三级加固差异对比

| 能力维度 | [`quickstart`](./quickstart/compose.yaml)（快速级） | [`production`](./production/compose.yaml)（生产级） | [`hardened`](./hardened/compose.yaml)（企业加固级） |
| :--- | :--- | :--- | :--- |
| **镜像坐标与构建复用** | `ghcr.io/atengk/deploy-templates/vue3-pnpm:quickstart`<br>复用 `../docker/quickstart/Dockerfile` | `ghcr.io/atengk/deploy-templates/vue3-pnpm:production`<br>复用 `../docker/production/Dockerfile` | `ghcr.io/atengk/deploy-templates/vue3-pnpm:hardened`<br>复用 `../docker/hardened/Dockerfile` |
| **运行用户与端口映射** | 默认用户，`${APP_PORT:-8080}:80` | 非 root UID `101`，`${APP_PORT:-8080}:8080` | 显式声明 `user: "101:101"`，`${APP_PORT:-8080}:8080` |
| **一次构建，运行时注入** | 未启用运行期脚本注入，回退构建期变量 | 通过 `environment` 注入 `APP_TITLE`、`APP_VERSION`、`APP_ENV`、`APP_API_BASE_URL` | 在只读模式下将运行期配置安全转义写入 `/tmp/app-runtime/config.js` |
| **重启与健康检查** | 不配置自动重启与容器级 `healthcheck` | `restart: unless-stopped`、`stop_grace_period: 15s`，内置 `/healthz` 探针 | `restart: unless-stopped`、`stop_grace_period: 15s`，内置 `/healthz` 探针 |
| **资源限额与日志滚动** | 不限制资源与日志体积 | `mem_limit: 256m`、`cpus: 0.5`、`pids_limit: 128`；`json-file` 日志 `10m × 5` | `mem_limit: 256m`、`cpus: 0.5`、`pids_limit: 128`；`json-file` 日志 `10m × 5` |
| **只读与内核权限加固** | 默认可写根文件系统与默认权限集 | 延续标准非 root 运行基线 | `read_only: true`、`/tmp` 挂载 `tmpfs`（`rw,noexec,nosuid,nodev,size=32m,mode=1777`）、`cap_drop: ["ALL"]`、`no-new-privileges:true` |

## 本地构建与拉取镜像命令

进入目标交付等级目录（`quickstart`、`production` 或 `hardened`）后，既可直接基于本地源码构建启动，也可直接拉取 GHCR 官方发布镜像启动。

### 1. 配置语法校验与国内加速源构建

```bash
cd templates/vue3-pnpm/deploy/compose/production

# 校验 Compose 编排语法与插值结果
docker compose --env-file .env.example config

# 使用官方上游源本地构建并后台启动（含等待健康检查就绪）
docker compose --env-file .env.example up -d --build --wait

# 国内网络环境下通过构建参数切换基础镜像代理与 npm/pnpm 镜像源
BASE_IMAGE_REGISTRY=docker.m.daocloud.io \
PNPM_REGISTRY=https://registry.npmmirror.com \
APP_VERSION=1.0.0 \
  docker compose --env-file .env.example up -d --build --wait
```

### 2. 直接拉取 GHCR 发布镜像启动

```bash
cd templates/vue3-pnpm/deploy/compose/production

# 拉取对应交付等级已发布镜像（不触发本地构建）
docker compose pull
docker compose --env-file .env.example up -d --no-build --wait

# 停止并清理容器资源
docker compose down
```

### 3. 快速级与企业加固级启停参考

```bash
# 快速级（容器内监听 80，宿主机默认映射 8080；可通过 APP_PORT 避免端口冲突）
cd templates/vue3-pnpm/deploy/compose/quickstart
APP_PORT=18080 docker compose --env-file .env.example up -d --build
curl -fsS http://127.0.0.1:18080/healthz
docker compose down

# 企业加固级（启用只读根文件系统与全量 Capabilities 移除）
cd ../hardened
docker compose --env-file .env.example up -d --build --wait
docker compose ps
docker compose down
```

## 运行时配置注入测试示例

以下验证流程以 `hardened`（`production` 同样适用）为例，演示在不重新构建镜像的前提下动态覆盖前端配置，并验证只读文件系统与安全边界：

```bash
cd templates/vue3-pnpm/deploy/compose/hardened

# 1. 启动实例并验证健康检查与入口页禁缓存头
docker compose --env-file .env.example up -d --build --wait
curl -fsS http://127.0.0.1:8080/healthz
curl -fsS -I http://127.0.0.1:8080/index.html

# 2. 检查 /config.js 内容与 Cache-Control: no-store 响应头
curl -fsS -D - http://127.0.0.1:8080/config.js

# 3. 不重建镜像，直接通过环境变量注入新配置并验证生效
APP_TITLE="灰度验证门户" \
APP_ENV="staging" \
APP_API_BASE_URL="https://staging-api.example.com" \
  docker compose up -d --no-build --force-recreate --wait
curl -fsS http://127.0.0.1:8080/config.js

# 4. 验证加固级安全约束：非只读 HTTP 方法返回 405，且静态根路径不可写
curl -sS -o /dev/null -w "%{http_code}\n" -X POST http://127.0.0.1:8080/
docker compose exec app sh -c "touch /usr/share/nginx/html/ro-check 2>&1 || true"

# 5. 清理测试实例
docker compose down
```

## 迁移自有项目改造清单

将本模板引入自有前端项目时，请按以下清单逐项检查与改造：

1. **拷贝独立等级目录及对应构建定义**：选定目标**交付等级**（如 `production` 或 `hardened`），将该等级的 `compose.yaml`、`.env.example` 与同等级 [`../docker/`](../docker/README.md) 目录下的 `Dockerfile`、`nginx.conf`、`.dockerignore`（及 `docker-entrypoint.sh`）一并拷贝至自有项目部署目录。
2. **调整 `build.context` 与 `build.dockerfile` 路径**：本仓库中 `compose.yaml` 的 `build.context` 默认指向 `../../..`（`templates/vue3-pnpm/`）。迁移至自有独立仓库根目录后，通常修改为 `context: .` 与 `dockerfile: Dockerfile`（并同步移除 `Dockerfile` 中 `app/` 与 `deploy/docker/<tier>/` 路径前缀）。
3. **替换私有镜像仓库与不可变标识**：将 `compose.yaml` 中的 `image:` 替换为企业私有镜像仓库地址；在 `hardened` 正式上线前，务必将浮动标签替换为不可变版本号（如 `:1.0.0-hardened`）或镜像 Digest（`@sha256:...`）。
4. **管理运行时环境变量与凭据边界**：根据 `.env.example` 复制生成本地 `.env` 文件并确保 `.env` 已被 `.gitignore` 忽略；仅注入前端公开运行参数（如 `APP_TITLE`、`APP_API_BASE_URL`），严禁将后端密钥或私有令牌注入前端静态配置。
5. **按需放行 `hardened` CSP 与调优资源限额**：若自有站点在浏览器中直接请求独立域名的后端接口，请同步在 [`../docker/hardened/nginx.conf`](../docker/hardened/nginx.conf) 的 `Content-Security-Policy` `connect-src` 中显式补充目标 API 域名；并按实际并发流量调整 `mem_limit`、`cpus` 与 `pids_limit`。
