# Vue 3 Docker 部署载体说明

本目录提供 **Vue 3 + pnpm + Vite** **技术栈**在 Docker **部署载体**下的三级**独立等级副本**（`quickstart`、`production`、`hardened`）。各等级目录均包含完整的 `Dockerfile`、`.dockerignore`、`.env.example`、`nginx.conf`（以及 `production` 与 `hardened` 配套的 `docker-entrypoint.sh`），相互独立、互不继承，可直接拷贝单目录迁移使用。

## 目录拓扑

```text
deploy/docker/
├── README.md                     # 本说明文档
├── quickstart/                   # 快速级：官方 Nginx 80 端口静态托管与 SPA 回退
│   ├── .dockerignore
│   ├── .env.example
│   ├── Dockerfile
│   └── nginx.conf
├── production/                   # 生产级：非 root UID 101、分级缓存、安全头与运行时注入
│   ├── .dockerignore
│   ├── .env.example
│   ├── Dockerfile
│   ├── docker-entrypoint.sh
│   └── nginx.conf
└── hardened/                     # 企业加固级：只读根文件系统兼容、/tmp 隔离、严格 CSP 与方法限制
    ├── .dockerignore
    ├── .env.example
    ├── Dockerfile
    ├── docker-entrypoint.sh
    └── nginx.conf
```

## 三级能力演进对比

| 能力维度 | `quickstart`（快速级） | `production`（生产级） | `hardened`（企业加固级） |
| :--- | :--- | :--- | :--- |
| **依赖安装与缓存** | `pnpm install` 基础安装 | `pnpm install --frozen-lockfile` + BuildKit Store 缓存挂载 | `pnpm install --frozen-lockfile` + BuildKit Store 缓存挂载 |
| **多架构构建加速** | 构建主机原生架构编译（`--platform=$BUILDPLATFORM`） | 构建主机原生架构编译（`--platform=$BUILDPLATFORM`） | 构建主机原生架构编译（`--platform=$BUILDPLATFORM`） |
| **运行时基础镜像** | `nginx:1.28-alpine` | `nginx/nginx-unprivileged:1.28-alpine` | `nginx/nginx-unprivileged:1.28-alpine` |
| **运行用户与端口** | 默认用户，监听 `80` | 非 root UID `101`，监听非特权端口 `8080` | 非 root UID `101`，监听非特权端口 `8080`，静态资源仅只读权限 |
| **一次构建，运行时注入** | 回退构建期环境变量 | 入口脚本安全转义环境变量写入 `/tmp/app-runtime/config.js` | 入口脚本安全转义写入 `/tmp/app-runtime/config.js`，并绕开 `/docker-entrypoint.d/` |
| **缓存治理与路由** | SPA History 回退 + `/healthz` | `assets/` 一年不可变缓存、`index.html` 与 `/config.js` 严格 `no-store` | `assets/` 一年不可变缓存、`index.html` 与 `/config.js` 严格 `no-store` |
| **安全响应头与方法约束** | 默认基础响应头 | 隐藏版本号、`X-Content-Type-Options`、`X-Frame-Options`、`Referrer-Policy` | 额外叠加严格 CSP、`Permissions-Policy`、COOP/CORP 与只读 HTTP 方法限制（非 GET/HEAD/OPTIONS 返回 405） |
| **只读根文件系统兼容** | 不适用 | 支持容器 `/tmp` 运行时配置隔离 | 全量 `*_temp_path` 与 `pid` 收口至 `/tmp/nginx/`，完全兼容 `--read-only` + `--cap-drop=ALL` |
| **容器健康检查** | 提供 `/healthz` 端点 | 内置 `HEALTHCHECK` 探测 `127.0.0.1:8080/healthz` | 内置 `HEALTHCHECK` 探测 `127.0.0.1:8080/healthz` |

## 国内镜像加速与时区参数

三套 `Dockerfile` 默认均使用官方上游源并显式配置 `ENV TZ=Asia/Shanghai`（已安装 Alpine `tzdata` 数据包）：

- **构建期切源参数**：
  - `BASE_IMAGE_REGISTRY`：容器基础镜像仓库前缀，默认 `docker.io`。
  - `PNPM_REGISTRY`：npm/pnpm 包仓库地址，默认 `https://registry.npmjs.org`（国内环境可替换为镜像源如 `https://registry.npmmirror.com`）。
  - `APP_VERSION` / `VITE_APP_VERSION`：构建期注入的版本号，默认 `0.0.0-dev`。
- **运行期时区覆盖**：容器启动时通过 `-e TZ=UTC` 即可动态切换容器内部时区。

## 本地构建与黑盒验证

请在 `templates/vue3-pnpm/` 目录（以同时包含 `app/` 与 `deploy/` 作为构建上下文）下执行以下操作。

### 1. 快速级（`quickstart`）

```bash
cd templates/vue3-pnpm
docker build -f deploy/docker/quickstart/Dockerfile --build-arg APP_VERSION=1.0.0 -t vue3-pnpm:quickstart .
docker run --rm -d --name vue3-qs -p 8080:80 vue3-pnpm:quickstart

# 验证健康检查与 SPA 深层路由回退
curl -fsS http://127.0.0.1:8080/healthz
curl -fsS -o /dev/null -w "%{http_code}\n" http://127.0.0.1:8080/orders/123
docker stop vue3-qs
```

### 2. 生产级（`production`）

```bash
cd templates/vue3-pnpm
docker build -f deploy/docker/production/Dockerfile --build-arg APP_VERSION=1.0.0 -t vue3-pnpm:production .
docker run --rm -d --name vue3-prod -p 8080:8080 \
  -e APP_TITLE="生产门户" \
  -e APP_ENV="production" \
  -e APP_API_BASE_URL="https://api.example.com" \
  vue3-pnpm:production

# 验证健康端点、运行时配置注入与禁缓存头
curl -fsS http://127.0.0.1:8080/healthz
curl -fsS -D - http://127.0.0.1:8080/config.js
curl -fsS -I http://127.0.0.1:8080/index.html
docker stop vue3-prod
```

### 3. 企业加固级（`hardened`）

```bash
cd templates/vue3-pnpm
docker build -f deploy/docker/hardened/Dockerfile --build-arg APP_VERSION=1.0.0 -t vue3-pnpm:hardened .

# 启用只读根文件系统、移除全部 Linux Capabilities、禁止提权并仅挂载 /tmp 为临时内存盘
docker run --rm -d --name vue3-hardened -p 8080:8080 \
  --read-only \
  --cap-drop=ALL \
  --security-opt=no-new-privileges:true \
  --tmpfs /tmp:rw,noexec,nosuid,nodev \
  -e APP_TITLE="企业加固门户" \
  -e APP_ENV="production" \
  -e APP_API_BASE_URL="https://api.example.com" \
  vue3-pnpm:hardened

# 验证健康端点、安全响应头、CSP、运行时配置与非法方法拦截（405）
curl -fsS http://127.0.0.1:8080/healthz
curl -fsS -D - http://127.0.0.1:8080/config.js
curl -sS -o /dev/null -w "%{http_code}\n" -X POST http://127.0.0.1:8080/
docker stop vue3-hardened
```

### 4. 国内源构建与安全审计参考命令

```bash
# 使用国内源构建示例（请按实际可用镜像代理地址替换）
docker build -f deploy/docker/production/Dockerfile \
  --build-arg BASE_IMAGE_REGISTRY=docker.m.daocloud.io \
  --build-arg PNPM_REGISTRY=https://registry.npmmirror.com \
  -t vue3-pnpm:production .

# Dockerfile 静态检查与容器镜像漏洞扫描
hadolint deploy/docker/quickstart/Dockerfile deploy/docker/production/Dockerfile deploy/docker/hardened/Dockerfile
trivy image --severity HIGH,CRITICAL --ignore-unfixed --exit-code 1 vue3-pnpm:hardened
```

## 迁移自有项目改造清单

将本模板应用至自有前端项目时，请按以下清单逐项核对：

1. **拷贝目标等级目录文件**：按目标安全基线，将 `quickstart/`、`production/` 或 `hardened/` 中的全部文件拷贝至自有项目根目录（或独立部署目录），并将 `.dockerignore` 置于 Docker 构建上下文根目录。
2. **调整 `Dockerfile` 中的构建路径**：仓库内 `Dockerfile` 默认从 `templates/vue3-pnpm/` 上下文读取 `app/` 与 `deploy/docker/<tier>/`；迁移至自有单项目仓库根目录后，请移除 `app/` 与 `deploy/docker/<tier>/` 路径前缀（直接 `COPY package.json pnpm-lock.yaml pnpm-workspace.yaml ./` 与 `COPY nginx.conf ...`）。
3. **对齐包管理器版本**：确认 `Dockerfile` 中安装的 `pnpm` 版本与自有项目 `package.json` 的 `packageManager` 及 `pnpm-lock.yaml` 版本一致。
4. **接入运行时配置契约**：在自有项目 `index.html` 中先于主入口脚本引入 `<script src="/config.js"></script>`，并在配置读取逻辑中优先读取 `window.__APP_CONFIG__`；若扩展了新的 `APP_*` 环境变量，同步补充进 `docker-entrypoint.sh` 的 `keys` 列表。
5. **按需调整 `hardened` CSP 策略**：若自有前端在浏览器中直接请求独立域名的后端接口，请在 `hardened/nginx.conf` 各 `Content-Security-Policy` 头的 `connect-src` 指令中显式追加对应 API 域名，切勿使用通配开放策略。
6. **核对只读静态资源与挂载要求**：使用 `hardened` 等级部署时，务必确保容器启动配置为容器提供可写的 `/tmp` 临时挂载，且应用本身不尝试向 `/usr/share/nginx/html` 或 `/etc/nginx` 写入运行期文件。
