# Deploy Templates

`deploy-templates` 是面向多**技术栈**与多**部署载体**的可验证中文参考部署模板库，提供清晰的成熟度分级与开箱可参考的工程交付基线。

## 核心设计原则

- **自包含可验证**：每个**技术栈**维护唯一一份极简可运行的**参考应用**（详见 [ADR-0001](./docs/adr/0001-self-contained-verifiable-templates.md)），保障全部部署配置均可真实构建、启动并通过健康检查验证，同时保持配置与应用源码解耦。
- **单应用交付**：所有模板严格遵守**单应用交付**边界（详见 [ADR-0002](./docs/adr/0002-app-only-delivery-boundary.md)），仅负责应用自身的构建、运行与治理，不捆绑数据库、缓存或消息队列等有状态中间件容器，外部依赖统一通过环境变量注入。
- **独立等级副本**：同一**部署载体**下的三个**交付等级**各自维护完整、独立可读的配置集合（详见 [ADR-0003](./docs/adr/0003-topology-and-independent-tiers.md)），不依赖跨等级隐式继承拼装，便于按需直接单目录拷贝复用。
- **一次构建，运行时注入**：前端纯静态**参考应用**在构建阶段不固化环境差异配置，而在启动或部署阶段通过外部环境变量动态生成运行时配置脚本。
- **国内网络与时区友好**：容器构建默认走官方上游源以保证通用性，同时暴露镜像仓库前缀、Maven 镜像与 pnpm 仓库覆盖参数；运行镜像默认配置 `Asia/Shanghai` 时区并支持 `TZ` 环境变量覆盖。
- **双流水线严格隔离**：[日常验证流水线](./.github/workflows/ci.yml) 仅负责按路径过滤的四载体质量与安全门禁（绝不推送镜像或发布附件）；[发版流水线](./.github/workflows/release.yml) 严格仅由语义化发布标签（`v*.*.*`）触发（详见 [ADR-0004](./docs/adr/0004-tag-gated-release-and-artifact-split.md)）。

## 交付等级划分

| 交付等级 | 中文名称 | 核心定位与适用场景 |
| :--- | :--- | :--- |
| `quickstart` | 快速级 | 极简配置与最短上手路径，面向本地体验、快速验证或临时演练场景 |
| `production` | 生产级 | 面向线上真实流量的最小安全与稳定性基线（非 root 运行、优雅停机、管理端口或静态缓存治理、健康探针、资源限额与弹性治理） |
| `hardened` | 企业加固级 | 在生产级基线之上强化安全合规、可观测性与发布治理（最小运行镜像、只读根文件系统、移除全部 Capabilities、网络隔离、CSP 与审计阻断） |

## 技术栈与部署载体导航矩阵

首期覆盖 **Spring Boot 3（JDK 21 + Maven 可执行 Jar）** 与 **Vue 3（Node.js 22 + pnpm + Vite 纯静态 SPA）** 两大**技术栈**，以及 **Docker**、**Docker Compose**、**宿主机直跑（`systemd`）** 与 **Kubernetes** 四类**部署载体**，全部直达入口均已就绪：

| 技术栈 | 参考应用入口 | Docker | Docker Compose | 宿主机直跑（`systemd`） | Kubernetes |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Spring Boot 3** | [技术栈总览](./templates/spring-boot-jar/README.md)<br>[Maven 工程](./templates/spring-boot-jar/app/pom.xml) | [说明](./templates/spring-boot-jar/deploy/docker/README.md)<br>[`quickstart`](./templates/spring-boot-jar/deploy/docker/quickstart/Dockerfile) / [`production`](./templates/spring-boot-jar/deploy/docker/production/Dockerfile) / [`hardened`](./templates/spring-boot-jar/deploy/docker/hardened/Dockerfile) | [说明](./templates/spring-boot-jar/deploy/compose/README.md)<br>[`quickstart`](./templates/spring-boot-jar/deploy/compose/quickstart/compose.yaml) / [`production`](./templates/spring-boot-jar/deploy/compose/production/compose.yaml) / [`hardened`](./templates/spring-boot-jar/deploy/compose/hardened/compose.yaml) | [说明](./templates/spring-boot-jar/deploy/systemd/README.md)<br>[`quickstart`](./templates/spring-boot-jar/deploy/systemd/quickstart/spring-boot-jar.service) / [`production`](./templates/spring-boot-jar/deploy/systemd/production/spring-boot-jar.service) / [`hardened`](./templates/spring-boot-jar/deploy/systemd/hardened/spring-boot-jar.service) | [说明](./templates/spring-boot-jar/deploy/kubernetes/README.md)<br>[`quickstart`](./templates/spring-boot-jar/deploy/kubernetes/quickstart/kustomization.yaml) / [`production`](./templates/spring-boot-jar/deploy/kubernetes/production/kustomization.yaml) / [`hardened`](./templates/spring-boot-jar/deploy/kubernetes/hardened/kustomization.yaml) |
| **Vue 3** | [技术栈总览](./templates/vue3-pnpm/README.md)<br>[前端工程](./templates/vue3-pnpm/app/package.json) | [说明](./templates/vue3-pnpm/deploy/docker/README.md)<br>[`quickstart`](./templates/vue3-pnpm/deploy/docker/quickstart/Dockerfile) / [`production`](./templates/vue3-pnpm/deploy/docker/production/Dockerfile) / [`hardened`](./templates/vue3-pnpm/deploy/docker/hardened/Dockerfile) | [说明](./templates/vue3-pnpm/deploy/compose/README.md)<br>[`quickstart`](./templates/vue3-pnpm/deploy/compose/quickstart/compose.yaml) / [`production`](./templates/vue3-pnpm/deploy/compose/production/compose.yaml) / [`hardened`](./templates/vue3-pnpm/deploy/compose/hardened/compose.yaml) | [说明](./templates/vue3-pnpm/deploy/systemd/README.md)<br>[`quickstart`](./templates/vue3-pnpm/deploy/systemd/quickstart/nginx.conf) / [`production`](./templates/vue3-pnpm/deploy/systemd/production/nginx.conf) / [`hardened`](./templates/vue3-pnpm/deploy/systemd/hardened/nginx.conf) | [说明](./templates/vue3-pnpm/deploy/kubernetes/README.md)<br>[`quickstart`](./templates/vue3-pnpm/deploy/kubernetes/quickstart/kustomization.yaml) / [`production`](./templates/vue3-pnpm/deploy/kubernetes/production/kustomization.yaml) / [`hardened`](./templates/vue3-pnpm/deploy/kubernetes/hardened/kustomization.yaml) |

## 全维度能力对比矩阵

### 1. 三级交付等级演进对照

| 能力维度 | `quickstart`（快速级） | `production`（生产级） | `hardened`（企业加固级） |
| :--- | :--- | :--- | :--- |
| **基础镜像与构建优化** | 标准构建与基础运行时镜像（Temurin 21 JRE / 官方 Nginx 1.28） | BuildKit 缓存挂载、Spring Boot 分层解包 / pnpm `--frozen-lockfile` 严格锁定 | 后端无 shell `distroless/java21-debian12:nonroot`；前端 `nginx/nginx-unprivileged:1.28-alpine` 静态产物只读 |
| **运行权限与系统沙箱** | 默认运行用户与可写文件系统 | 专用低权非 root UID（后端 `10001`，前端 `101`）；`systemd` 低权系统用户与 `MemoryMax` | 容器 `read_only` + `/tmp` `tmpfs`、`cap_drop: ALL`、`no-new-privileges`；`systemd` 全套 `ProtectSystem=strict` 与能力清零 |
| **端口隔离与流量策略** | 单端口暴露（后端 `8080`、前端 Nginx `80`） | 后端管理端口拆至 `8081` 且反代屏蔽 `/actuator`；前端监听 `8080`、`assets/` 一年不可变缓存 | 后端宿主机绑定 `127.0.0.1`、K8s 默认拒绝加最小放行 `NetworkPolicy`；前端严格 CSP 与非只读 HTTP 方法 `405` 拦截 |
| **健康探针与生命周期** | 基础存活/就绪检查或单脚本探测 | `startup`/`readiness`/`liveness` 三探针、`SIGTERM` 优雅停机（20s 宽限 + 30s 缓冲区）、HPA 与 PDB | 无 shell 内置零依赖 JDK 探针 `com.ateng.deploy.HealthCheck`、宿主机失败自动回滚与历史版本治理 |
| **运行时配置注入** | 使用应用默认或构建期环境变量 | Docker/K8s/宿主机安全转义生成 `/config.js`，响应头强制 `Cache-Control: no-store` | 绕开 `/docker-entrypoint.d/` 只读目录写入限制，全部临时文件与配置统一隔离至 `/tmp` 挂载 |
| **可观测性与审计记录** | 标准流 `stdout`/`stderr` 与 `journald` 基础日志 | 独立管理端口暴露 `/actuator/prometheus` 指标、容器日志滚动限额（`10m × 5`） | Pod 标准 Prometheus 采集注解、可选 `ServiceMonitor` 参考、可选 OTLP 开关、宿主机部署审计日志 |

### 2. 四类部署载体核心设计要点

| 部署载体 | Spring Boot 3（可执行 Jar） | Vue 3（纯静态 SPA） |
| :--- | :--- | :--- |
| **Docker** | 构建上下文 `templates/spring-boot-jar/app`；支持 `BASE_IMAGE_REGISTRY`、`GCR_REGISTRY`、`MAVEN_MIRROR_URL`、`APP_VERSION` | 构建上下文 `templates/vue3-pnpm`；支持 `BASE_IMAGE_REGISTRY`、`PNPM_REGISTRY`、`APP_VERSION`；`production`/`hardened` 使用自定义入口生成只读兼容 `/tmp/app-runtime/config.js` |
| **Docker Compose** | 独立 `compose.yaml` + `.env.example`；`production`/`hardened` 仅向宿主机映射业务端口 `8080`，`8081` 管理端口仅限容器内探针与内网隔离网络访问 | 独立 `compose.yaml` + `.env.example`；支持不重建镜像直接通过环境变量动态刷新 `/config.js` 并立即生效 |
| **宿主机直跑（`systemd`）** | 原生 `spring-boot-jar.service` 托管 JVM、`releases/<version>` + `current` 软链原子发布、一键回滚与前置 Nginx 站点配置 | 严格由系统 `nginx.service` 托管静态产物与 SPA History 回退（不编造 Node.js 常驻服务），原子目录切换并随版本同步生成 `config.js` |
| **Kubernetes** | 原生清单 + 同目录 `kustomization.yaml`（一行 `images:` 覆盖）；`hardened` 附带 `NetworkPolicy` 与可选 `ServiceMonitor`（默认不引入 CRD 保障裸集群零报错） | 原生清单 + `ConfigMap` 注入 `APP_*` 变量、`Ingress`（v1）、HPA、PDB 与精确放行 `ingress-nginx` 的 `NetworkPolicy` |

## 本地构建与自动化验证

### 1. 运行参考应用单测与打包

```bash
# Spring Boot 3 参考应用测试与可执行 Jar 打包
mvn -B -ntp -f templates/spring-boot-jar/app/pom.xml test
mvn -B -ntp -f templates/spring-boot-jar/app/pom.xml -DskipTests package -Dapp.version=0.1.0

# Vue 3 参考应用严格锁文件安装、Vitest 单测与 Vite 构建
pnpm --dir templates/vue3-pnpm/app install --frozen-lockfile
pnpm --dir templates/vue3-pnpm/app test
pnpm --dir templates/vue3-pnpm/app build
```

### 2. 使用统一验证与打包脚本本地自检

仓库在 [`scripts/`](./scripts/) 下提供统一验证与发版打包脚本（公共日志、Python 探测与明文凭据扫描函数统一收口在 [`scripts/lib/common.sh`](./scripts/lib/common.sh)），覆盖仓库基线、全部四类部署载体与离线发版打包：

| 脚本入口 | 核心覆盖范围 | 常用运行命令 |
| :--- | :--- | :--- |
| [`scripts/verify-repo.sh`](./scripts/verify-repo.sh) | LF 行尾、`.sh` 权限、Markdown 无本地绝对路径或 `file` 协议路径与断链检查、明文凭据与禁用词扫描 | `bash scripts/verify-repo.sh` |
| [`scripts/verify-containers.sh`](./scripts/verify-containers.sh) | 构建并拉起两栈全部 6 个 Docker 容器与 6 个 Compose 编排，黑盒实测 HTTP 契约、端口隔离、`SIGTERM` 退出、运行时 `/config.js` 注入与只读运行 | `bash scripts/verify-containers.sh --stack all` |
| [`scripts/verify-host.sh`](./scripts/verify-host.sh) | 在隔离临时目录中演练两栈三级宿主机首次发布、升级、不可变防重、回滚与健康检查（兼容 Git Bash 与 Linux） | `bash scripts/verify-host.sh --stack all` |
| [`scripts/verify-k8s.sh`](./scripts/verify-k8s.sh) | 使用 `kubectl kustomize` 渲染全部 6 套清单，按工具链可用性执行 `kubeconform -strict` 与 `trivy config` 审计 | `bash scripts/verify-k8s.sh --stack all` |
| [`scripts/package-release.sh`](./scripts/package-release.sh) | 以传入版本号为唯一真相源构建双技术栈离线交付件、宿主机部署归档及 `SHA256SUMS.txt` 校验清单 | `bash scripts/package-release.sh --version v0.0.1-dryrun` |

> [!TIP]
> 在具备完整容器与 Kubernetes 安全工具链的节点上，可通过 `REQUIRE_ALL_TOOLS=true bash scripts/verify-k8s.sh --stack all` 强制开启 `kubeconform -strict` 与 `trivy config` 检查；国内网络构建镜像时可通过环境变量覆盖 `BASE_IMAGE_REGISTRY`、`GCR_REGISTRY`、`MAVEN_MIRROR_URL` 与 `PNPM_REGISTRY`。

## 日常验证流水线（CI 门禁）

[`.github/workflows/ci.yml`](./.github/workflows/ci.yml) 在 `pull_request`、推送 `main` 与手动 `workflow_dispatch` 时运行，声明最小只读权限 `permissions: contents: read` 并通过可复用校验工作流 [`.github/workflows/verify.yml`](./.github/workflows/verify.yml) 执行以下分层门禁：

- **智能路径分流**：纯文档改动仅运行 `verify-repo.sh` 与 `shellcheck`；单技术栈变更仅执行对应栈门禁；公共脚本或工作流变更及 `workflow_dispatch` 触发全量验证。
- **应用与容器门禁**：执行参考应用测试与构建、`hadolint` 静态扫描全部 6 个 `Dockerfile`、`verify-containers.sh` 真实拉起实测，以及 `trivy image`（输出 `HIGH,CRITICAL` 完整报告并对存在修复版本的 `CRITICAL` 严格阻断）。
- **宿主机与 Kubernetes 门禁**：在 Ubuntu Runner 上运行 `shellcheck`、`systemd-analyze verify`、`nginx -t`（按各配置真实语法层级构造外层包裹校验）、`verify-host.sh` 与开启 `REQUIRE_ALL_TOOLS=true` 的 `verify-k8s.sh`。
- **发版干跑与边界校验**：运行 `package-release.sh` 离线验证产物完整性，并通过 PyYAML 与 `bash -n` 静态校验全部工作流边界与内嵌脚本语法。

## 容器镜像与发版产物使用说明

正式发版严格仅由语义化发布标签（`v*.*.*`）触发 [`.github/workflows/release.yml`](./.github/workflows/release.yml)，先调用 [`.github/workflows/verify.yml`](./.github/workflows/verify.yml) 完成全量前置质量与安全门禁，再同步发布双架构 GHCR 容器镜像并借助 [`scripts/package-release.sh`](./scripts/package-release.sh) 构建上传 GitHub Release **发版产物**：

### 1. GHCR 容器镜像坐标

- **命名规则**：`ghcr.io/atengk/deploy-templates/<stack>:<tier>`（同时推送不可变版本标签 `:<version>-<tier>`，其中 `:latest` 指向 `production`）。
- **架构支持**：`linux/amd64` 与 `linux/arm64` 双架构清单。
- **使用建议**：生产与企业加固场景部署前，务必在 `compose.yaml` 或 `kustomization.yaml` 中锁定不可变版本标签（如 `1.0.0-hardened`）或镜像 Digest（`@sha256:...`）。

```bash
# 拉取并快速验证 Spring Boot 3 生产级镜像
docker pull ghcr.io/atengk/deploy-templates/spring-boot-jar:production
docker run --rm -p 8080:8080 -e MANAGEMENT_SERVER_PORT=8081 \
  ghcr.io/atengk/deploy-templates/spring-boot-jar:production

# 拉取并验证 Vue 3 企业加固级镜像（支持只读根文件系统与运行时配置注入）
docker pull ghcr.io/atengk/deploy-templates/vue3-pnpm:hardened
docker run --rm -p 8080:8080 --read-only --cap-drop=ALL --tmpfs /tmp:rw,noexec,nosuid,nodev \
  -e APP_TITLE="生产门户" -e APP_API_BASE_URL="https://api.example.com" \
  ghcr.io/atengk/deploy-templates/vue3-pnpm:hardened
```

### 2. GitHub Release 离线交付件清单

每次正式发布在 GitHub Release 页面提供以下离线**发版产物**及校验清单（不附加臃肿的容器镜像 `.tar` 导出包）：

| 文件名格式 | 适用载体 | 内容说明 |
| :--- | :--- | :--- |
| `spring-boot-jar-<version>.jar` | 通用 Java / 宿主机 | 已注入发布版本号的 Spring Boot 3 可执行 Jar |
| `vue3-pnpm-dist-<version>.tar.gz` | 通用静态托管 / CDN | Vue 3 参考应用编译输出纯静态资源包（`dist/`） |
| `spring-boot-jar-systemd-<version>.tar.gz` | Linux 宿主机 | 包含可执行 Jar 与三级 `deploy/systemd/` 脚本、单元与示例配置 |
| `vue3-pnpm-systemd-<version>.tar.gz` | Linux 宿主机 | 包含 `dist/` 静态产物与三级 `deploy/systemd/` 脚本及 Nginx 站点配置 |
| `<stack>-<version>-hardened.spdx.json` | 安全合规审计 | 对应技术栈 `hardened` 容器镜像的 SPDX JSON 软件物料清单（SBOM） |
| `SHA256SUMS.txt` | 完整性校验 | 覆盖以上全部发布附件的 SHA-256 校验和文件 |

下载后可执行以下命令校验交付件完整性：

```bash
sha256sum -c SHA256SUMS.txt --ignore-missing
```

## 仓库目录拓扑与领域文档索引

```text
.
├── AGENTS.md                        # 仓库工程代理基础配置
├── CONTEXT.md                       # 领域词汇表与禁用术语约束
├── LICENSE                          # MIT 开源协议
├── README.md                        # 仓库中文总览与导航入口
├── .editorconfig                    # 跨操作系统编辑器缩进与 UTF-8 基线
├── .gitattributes                   # 跨操作系统 LF 行尾强制约束
├── .gitignore                       # 构建产物、本地 .env* 与临时文件忽略规则
├── .github/
│   └── workflows/
│       ├── ci.yml                   # 四载体分层日常验证入口流水线
│       ├── verify.yml               # 可复用多载体质量与安全门禁工作流
│       └── release.yml              # 仅由 v*.*.* 标签触发的发版流水线
├── docs/
│   ├── adr/                         # 架构决策记录（ADR-0001 至 ADR-0004）
│   └── agents/                      # 领域建模与 Issue 分诊协作规范
├── scripts/
│   ├── lib/
│   │   └── common.sh                # 公共日志、Python 探测与明文凭据扫描函数库
│   ├── verify-repo.sh               # 仓库基线静态检查脚本
│   ├── verify-containers.sh         # Docker 与 Compose 容器契约黑盒验证脚本
│   ├── verify-host.sh               # 宿主机全链路隔离演练脚本
│   ├── verify-k8s.sh                # Kubernetes Kustomize 与安全审计脚本
│   └── package-release.sh           # 发版产物统一构建打包与校验清单生成脚本
└── templates/
    ├── spring-boot-jar/             # Spring Boot 3 技术栈参考应用与四载体三级副本
    └── vue3-pnpm/                   # Vue 3 技术栈参考应用与四载体三级副本
```

- **领域与工程规范索引**：
  - 领域词汇表：[`CONTEXT.md`](./CONTEXT.md)
  - 架构决策记录：
    - [ADR-0001：自包含可验证模板形态](./docs/adr/0001-self-contained-verifiable-templates.md)
    - [ADR-0002：单应用交付边界](./docs/adr/0002-app-only-delivery-boundary.md)
    - [ADR-0003：按载体分组与独立等级副本拓扑](./docs/adr/0003-topology-and-independent-tiers.md)
    - [ADR-0004：标签触发发版与产物分离规范](./docs/adr/0004-tag-gated-release-and-artifact-split.md)
  - 代理协作指南：[`AGENTS.md`](./AGENTS.md)、[`domain.md`](./docs/agents/domain.md)、[`issue-tracker.md`](./docs/agents/issue-tracker.md)、[`triage-labels.md`](./docs/agents/triage-labels.md)
  - 工程基线文件：[`.gitattributes`](./.gitattributes)、[`.editorconfig`](./.editorconfig)、[`.gitignore`](./.gitignore)

## 开源协议

本项目基于 [MIT License](./LICENSE) 开源。
