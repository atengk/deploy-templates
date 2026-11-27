# Vue 3 宿主机直跑（`systemd`）部署载体说明

本目录提供 **Vue 3 + pnpm + Vite** **技术栈**面向 Linux 宿主机的三级**独立等级副本**（`quickstart`、`production`、`hardened`）。各交付等级均包含完整的站点 Nginx 配置、示例环境配置与标准化 Bash 运维脚本，相互独立、互不继承，可直接拷贝单目录迁移落地。

## 为什么不提供 Node.js 常驻 `systemd` 服务单元

参考应用经 Vite 打包后产出为纯静态 SPA（位于 `dist/`），运行时不依赖 Node.js 进程提供页面服务。在 Linux 宿主机生产实践中，强行使用 Node.js 常驻进程托管静态文件不仅引入无谓的内存占用与进程保活风险，还会丢失 Nginx 原生的高并发静态文件传输、协商压缩、缓存控制与安全响应头能力。

因此，本载体**严格不编造 Node.js 常驻 `.service` 单元**，而是通过以下标准化组合实现宿主机零停机发布与回滚：

- **系统 `nginx.service`**：负责稳定监听端口、处理 SPA History 路由回退、分级缓存与安全响应头治理；
- **不可变版本目录与软链接原子切换**：所有发布写入 `${DEPLOY_ROOT}/releases/<版本号>`，通过原子切换 `${DEPLOY_ROOT}/current` 软链接并平滑重载 `nginx.service` 完成零中断发布与秒级回滚。

## 目录拓扑

```text
deploy/systemd/
├── README.md                     # 本说明文档
├── quickstart/                   # 快速级：基础 Nginx 站点配置、软链发布与健康探测
│   ├── app.env.example
│   ├── deploy.sh
│   ├── healthcheck.sh
│   └── nginx.conf
├── production/                   # 生产级：运行时配置注入、分级缓存、基础安全头与一键回滚
│   ├── app.env.example
│   ├── deploy.sh
│   ├── healthcheck.sh
│   ├── nginx.conf
│   └── rollback.sh
└── hardened/                     # 企业加固级：权限收敛、不可变保护、严格 CSP、失败自动回滚与审计日志
    ├── app.env.example
    ├── deploy.sh
    ├── healthcheck.sh
    ├── nginx.conf
    └── rollback.sh
```

## 三级能力演进对比

| 能力维度 | `quickstart`（快速级） | `production`（生产级） | `hardened`（企业加固级） |
| :--- | :--- | :--- | :--- |
| **默认目录与配置路径** | `/opt/vue3-pnpm`、`/etc/vue3-pnpm/app.env` | `/opt/vue3-pnpm`、`/etc/vue3-pnpm/app.env` | `/opt/vue3-pnpm`、`/etc/vue3-pnpm/app.env`（校验配置权限非全局可写） |
| **Nginx 基础与超时** | 监听 `80` 端口 | `server_tokens off` + Gzip 压缩 + TLS 占位注释 | 额外限制 `client_max_body_size 1m` 与读写/保持连接超时 |
| **一次构建，运行时注入** | 回退构建期变量或占位脚本 | `deploy.sh` 安全解析环境配置并转义生成 `releases/<版本号>/config.js` | 与生产级同一转义契约生成 `config.js`，随版本目录原子切换 |
| **路由与缓存治理** | SPA History 回退 + `/healthz` | `assets/` 一年不可变缓存、`index.html` 与 `/config.js` 严格 `no-store` | 继承分级缓存，并屏蔽 `.git`/`.env` 等隐藏文件（放行 `/.well-known/`） |
| **安全响应头与方法约束** | 默认基础响应头 | `X-Content-Type-Options`、`X-Frame-Options`、`Referrer-Policy` | 叠加严格 CSP、`Permissions-Policy`、COOP/CORP 与只读 HTTP 方法限制（非 GET/HEAD/OPTIONS 返回 405） |
| **发布与回滚治理** | 暂存落盘 + `current` 软链接原子切换 | 增加 `.previous_version`/`previous` 指针、`rollback.sh` 支持指定或回退上一可用版本 | 增加不可变目录防覆写、只读权限收敛、保留策略清理（`KEEP_RELEASES`）、`deploy-history.log` 审计与 `AUTO_HEALTHCHECK` 失败自动回滚 |
| **健康探测** | `/healthz` 重试探测 | `/healthz` 探测 + 可选 `CHECK_CONFIG_URL` 校验 | `/healthz` 探测 + 可选 `CHECK_CONFIG_URL` 正文及 `Cache-Control: no-store` 校验 |

## 宿主机安装与运维指南

### 1. 构建纯静态产物

在参考应用目录 [../../app/](../../app/) 执行构建，也可直接使用正式发版生成的静态归档包：

```bash
cd templates/vue3-pnpm/app
pnpm install --frozen-lockfile
pnpm test
pnpm build
```

### 2. 初始化宿主机目录与系统 `nginx.service`

以 `production` 或 `hardened` 为例（默认兼容 Ubuntu / Debian / Rocky Linux）：

```bash
# 1. 创建部署根目录与权限受控的配置目录
sudo mkdir -p /opt/vue3-pnpm/releases /etc/vue3-pnpm

# 2. 拷贝并按需编辑环境配置（建议仅对 root 与 nginx 组可读）
sudo cp deploy/systemd/hardened/app.env.example /etc/vue3-pnpm/app.env
sudo chmod 0640 /etc/vue3-pnpm/app.env
# 若系统 Nginx 运行用户为 nginx 或 www-data，按需设置属组：
# sudo chown root:nginx /etc/vue3-pnpm/app.env

# 3. 拷贝站点配置并验证语法后启用 nginx.service
sudo cp deploy/systemd/hardened/nginx.conf /etc/nginx/conf.d/vue3-pnpm.conf
sudo nginx -t
sudo systemctl enable --now nginx
```

### 3. 常用发布、回滚与运维命令

```bash
# 首次发布 v1.0.0（生产级或企业加固级自动生成 config.js）
sudo bash deploy/systemd/hardened/deploy.sh v1.0.0 ./app/dist

# 验证健康检查端点与运行时配置脚本禁缓存头
bash deploy/systemd/hardened/healthcheck.sh
CHECK_CONFIG_URL=http://127.0.0.1/config.js bash deploy/systemd/hardened/healthcheck.sh

# 二次升级 v1.1.0（可先更新 /etc/vue3-pnpm/app.env）
sudo bash deploy/systemd/hardened/deploy.sh v1.1.0 ./app/dist

# 一键回滚至上一可用版本（无需传入版本号）
sudo bash deploy/systemd/hardened/rollback.sh

# 或回滚至指定的历史版本
sudo bash deploy/systemd/hardened/rollback.sh v1.0.0

# 系统 nginx.service 日常运维与日志排查
sudo nginx -t
sudo systemctl reload nginx
sudo systemctl status nginx --no-pager
sudo journalctl -u nginx -n 100 --no-pager
```

### 4. `hardened` 配套 `systemd` Drop-in 沙箱加固参考

针对宿主机自带的 `nginx.service`，可通过 `sudo systemctl edit nginx` 叠加 drop-in 限制（既不破坏发行版原生包升级，又限制 Nginx 进程对静态发布目录的写权限）：

```ini
[Service]
PrivateTmp=true
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ReadOnlyPaths=/opt/vue3-pnpm
ReadWritePaths=/var/log/nginx /var/cache/nginx /run
```

> 说明：如使用非标准路径存放缓存或 PID，请对应补充到 `ReadWritePaths` 后执行 `sudo systemctl daemon-reload && sudo systemctl restart nginx`。

## 无 root 隔离目录演练与静态检查

所有脚本均预留环境变量接缝（`DEPLOY_ROOT`、`ENV_FILE`、`NGINX_TEST_CMD`、`NGINX_RELOAD_CMD`、`SKIP_NGINX_RELOAD`、`HEALTHCHECK_URL`、`CURL_CMD`），无需 `root` 权限或安装 `nginx` 即可在临时目录完整演练“首次发布 → 运行时配置校验 → 二次升级 → 一键回滚”全链路：

```bash
WORK_TMP="$(mktemp -d)"
mkdir -p "${WORK_TMP}/dist-v1" "${WORK_TMP}/dist-v2"
echo '<!doctype html><html><script src="/config.js"></script><body>v1</body></html>' > "${WORK_TMP}/dist-v1/index.html"
echo '<!doctype html><html><script src="/config.js"></script><body>v2</body></html>' > "${WORK_TMP}/dist-v2/index.html"

cat > "${WORK_TMP}/app.env" <<'EOF'
APP_TITLE=隔离演练站点
APP_ENV=staging
APP_API_BASE_URL=https://api-v1.example.com
EOF

# 1. 首次发布 v1.0.0 并检查生成的运行时配置
DEPLOY_ROOT="${WORK_TMP}/root" ENV_FILE="${WORK_TMP}/app.env" SKIP_NGINX_RELOAD=true \
  bash deploy/systemd/hardened/deploy.sh v1.0.0 "${WORK_TMP}/dist-v1"
readlink -f "${WORK_TMP}/root/current"
cat "${WORK_TMP}/root/current/config.js"

# 2. 更新配置并二次升级 v1.1.0
sed -i 's|api-v1.example.com|api-v2.example.com|' "${WORK_TMP}/app.env"
DEPLOY_ROOT="${WORK_TMP}/root" ENV_FILE="${WORK_TMP}/app.env" SKIP_NGINX_RELOAD=true \
  bash deploy/systemd/hardened/deploy.sh v1.1.0 "${WORK_TMP}/dist-v2"
cat "${WORK_TMP}/root/current/config.js"

# 3. 一键回滚至 v1.0.0，验证软链接与 config.js 同步回归
DEPLOY_ROOT="${WORK_TMP}/root" ENV_FILE="${WORK_TMP}/app.env" SKIP_NGINX_RELOAD=true \
  bash deploy/systemd/hardened/rollback.sh
readlink -f "${WORK_TMP}/root/current"
cat "${WORK_TMP}/root/current/config.js"

rm -rf "${WORK_TMP}"
```

静态检查与规范验证命令（需宿主机或 CI 安装对应工具）：

```bash
bash -n templates/vue3-pnpm/deploy/systemd/*/*.sh
shellcheck templates/vue3-pnpm/deploy/systemd/*/*.sh
sudo nginx -t -c /etc/nginx/nginx.conf
```

## 迁移自有项目改造清单

将本载体配置应用至自有前端项目时，请按以下清单逐项核对：

1. **按交付等级独立拷贝**：从 `quickstart/`、`production/` 或 `hardened/` 中选择单个等级目录完整拷贝到自有项目运维仓库或部署包目录，并同步调整 [../../README.md](../../README.md) 中声明的构建与运行时契约。
2. **定制站点域名、路径与端口**：在目标 `nginx.conf` 中将 `server_name _;` 替换为实际域名，按需修改 `root /opt/vue3-pnpm/current;` 为自有应用基目录（并与 `app.env` 的 `DEPLOY_ROOT` 保持一致）。
3. **配置 HTTPS / TLS**：`production` 与 `hardened` 的 `nginx.conf` 默认监听 `80` 并附带 TLS 占位注释，以免在无证书机器上阻塞 `nginx -t`；若由本机 Nginx 直接终结 TLS，请解除 HTTPS 注释并配置真实证书及 HSTS 响应头。
4. **接入运行时配置契约**：确保自有前端在 `index.html` 中早于主模块引入 `<script src="/config.js"></script>` 并从 `window.__APP_CONFIG__` 读取配置；若新增了其他 `APP_*` 键名，需同步补充至 `deploy.sh` 内 `generate_runtime_config` 的 `keys` 列表（保持与 [../docker/README.md](../docker/README.md) 一致）。
5. **按需调整 `hardened` CSP 与限流**：若浏览器需直连独立域名的后端接口，请在 `hardened/nginx.conf` 各个 `Content-Security-Policy` 头的 `connect-src` 中显式追加目标 API 域名；若需启用请求限流，请在系统主配置 `/etc/nginx/nginx.conf` 的 `http {}` 块声明 `limit_req_zone` 并在站点 `server {}` 块引用。
6. **核对宿主机软链权限与自动清理**：使用 `hardened` 时如开启了 `DEPLOY_OWNER=root:nginx`，请确保执行 `deploy.sh`/`rollback.sh` 的运维账号（或 `sudo`）对 `DEPLOY_ROOT` 具备写入与调整权限；注意不要在 Nginx 主配置中启用 `disable_symlinks on`，否则将阻止 `current` 软链接解析。
