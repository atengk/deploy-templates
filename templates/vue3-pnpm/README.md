# Vue 3 + pnpm + Vite 参考应用与部署模板

本目录提供 **Vue 3（Node.js 22 + pnpm + Vite + TypeScript）** **技术栈**的唯一共享**参考应用**及配套多载体分级部署配置，严格遵循**单应用交付**原则与**一次构建，运行时注入**前端交付契约。

## 技术栈定位

- **构建体系**：Node.js 22 + `pnpm`（附带真实可复现的 `pnpm-lock.yaml`）+ Vite 6 + Vue 3 + TypeScript + Vitest。
- **产物形态**：纯静态 SPA（打包产物位于 `dist/`），运行阶段不依赖 Node.js 常驻进程，由 Nginx 直接托管静态资源并处理 SPA History 路由回退。
- **单应用交付边界**：不捆绑后端服务、数据库或缓存中间件容器；外部接口地址与环境标识通过构建期回退变量或运行期动态脚本注入。

## 参考应用目录与使用说明

唯一共享**参考应用**源码位于 [`./app/`](./app/)：

```text
app/
├── .env.example                  # 本地开发环境变量示例
├── index.html                    # 入口页（先于应用脚本加载 /config.js）
├── package.json                  # 依赖声明与 pnpm 脚本入口
├── pnpm-lock.yaml                # 精确锁定依赖树的可复现锁文件
├── pnpm-workspace.yaml           # pnpm v11 构建脚本白名单配置（allowBuilds）
├── public/
│   └── config.js                 # 本地开发与快速级静态托管占位脚本
├── vite.config.ts                # Vite 构建与 Vitest（happy-dom）配置
└── src/
    ├── App.vue                   # 参考应用根组件（展示标题、版本、配置状态与导航）
    ├── config/runtimeConfig.ts   # 运行时配置与构建期环境变量合并解析模块
    ├── router/index.ts           # SPA History 路由表（含深层路由回退视图）
    └── __tests__/                # Vitest 单元测试用例
```

### 本地开发与校验命令

```bash
cd templates/vue3-pnpm/app
pnpm install --frozen-lockfile
pnpm test
pnpm build
pnpm dev
```

## 运行时配置注入契约（`window.__APP_CONFIG__`）

为落实现代前端**一次构建，运行时注入**原则，参考应用在构建阶段不写死环境差异配置：

1. [`./app/index.html`](./app/index.html) 在应用入口 `<script type="module">` 之前同步加载 `<script src="/config.js"></script>`。
2. `production` 与 `hardened` 等级容器启动时，由入口脚本将容器环境变量安全转义并写入可写目录 `/tmp/app-runtime/config.js`，再由 Nginx 映射至 `/config.js` 并附加 `Cache-Control: no-store` 响应头，禁止浏览器缓存配置脚本。
3. [`./app/src/config/runtimeConfig.ts`](./app/src/config/runtimeConfig.ts) 严格按照 `window.__APP_CONFIG__` > `import.meta.env.VITE_*` > 内置默认值的优先级解析配置；本地 `pnpm dev` 与 `quickstart` 等级下默认回退构建期变量或默认值，且不阻塞页面渲染。

| 运行时字段（`window.__APP_CONFIG__`） | 构建期回退字段（`import.meta.env`） | 内置默认值 | 用途说明 |
| :--- | :--- | :--- | :--- |
| `APP_TITLE` | `VITE_APP_TITLE` | `Vue 3 部署参考应用` | 页面主标题与浏览器标签标题 |
| `APP_VERSION` | `VITE_APP_VERSION` | `0.0.0-dev` | 构建或发布注入的应用版本号 |
| `APP_ENV` | `VITE_APP_ENV` | `development` | 当前业务环境标识 |
| `APP_API_BASE_URL` | `VITE_API_BASE_URL` | `/api` | 前端调用后端服务的基础路径 |

## 四类部署载体入口

同一份 [`./app/`](./app/) 源码可供以下四类**部署载体**构建与托管，且每个载体下均按**独立等级副本**提供 `quickstart`、`production` 与 `hardened` 三级配置：

| 部署载体 | 仓库路径 | 当前状态 | 核心说明 |
| :--- | :--- | :--- | :--- |
| **Docker** | [`./deploy/docker/README.md`](./deploy/docker/README.md) | 已就绪 | 三级 `Dockerfile`、Nginx 配置与运行时配置注入入口脚本 |
| **Docker Compose** | `deploy/compose/` | 规划中 | 单机复用同等级 Docker 构建定义并叠加只读/资源限额编排 |
| **宿主机直跑（`systemd`）** | `deploy/systemd/` | 规划中 | 基于系统 `nginx.service` 的三级站点配置与原子软链发布回滚 |
| **Kubernetes** | `deploy/kubernetes/` | 规划中 | 原生清单、ConfigMap 注入、`Ingress`（v1）与 Kustomize 聚合入口 |
