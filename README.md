# Deploy Templates

`deploy-templates` 是面向多**技术栈**与多**部署载体**的可验证中文参考部署模板库，提供清晰的成熟度分级与开箱可参考的工程交付基线。

## 核心设计原则

- **自包含可验证**：每个技术栈维护唯一一份极简可运行的**参考应用**（详见 [ADR-0001](./docs/adr/0001-self-contained-verifiable-templates.md)），保障所有部署配置均可真实构建、启动与通过健康检查，同时保持配置与自有应用源码解耦。
- **单应用交付**：所有模板严格遵守**单应用交付**边界（详见 [ADR-0002](./docs/adr/0002-app-only-delivery-boundary.md)），仅负责应用自身的构建、运行与治理，不捆绑数据库、缓存或消息队列容器，外部有状态依赖统一通过环境变量注入。
- **独立等级副本**：同一**部署载体**下的三个**交付等级**各自维护完整、独立可读的配置集合（详见 [ADR-0003](./docs/adr/0003-topology-and-independent-tiers.md)），不依赖跨等级隐式继承拼装，便于按需直接拷贝复用。
- **一次构建，运行时注入**：前端纯静态**参考应用**在构建阶段不固化环境差异配置，而在启动或部署阶段通过外部环境变量动态生成运行时配置。
- **国内网络与时区友好**：容器构建默认走官方上游源以保证通用性，同时提供镜像仓库前缀、Maven 镜像与 pnpm 源覆盖参数；默认显式采用 `Asia/Shanghai` 时区并支持 `TZ` 环境变量覆盖。
- **双流水线严格隔离**：日常验证流水线仅执行按路径过滤的质量、运行态与安全门禁检查；**发版流水线**严格仅由语义化发布标签（`v*.*.*`）触发（详见 [ADR-0004](./docs/adr/0004-tag-gated-release-and-artifact-split.md)），统一构建发布容器镜像与**发版产物**。

## 交付等级划分

本仓库统一将**交付等级**划分为三级，覆盖从本地验证到严格合规交付的完整演进路径：

| 交付等级 | 中文名称 | 核心定位与适用场景 |
| :--- | :--- | :--- |
| `quickstart` | 快速级 | 极简配置与最短上手路径，面向本地体验、快速验证或临时演练场景 |
| `production` | 生产级 | 面向线上真实流量的最小安全与稳定性基线（非 root 运行、优雅停机、健康探针、资源限额、构建缓存） |
| `hardened` | 企业加固级 | 在生产级基线之上强化安全合规、可观测性与治理能力（最小运行镜像、只读根文件系统、移除全部 Linux Capabilities、网络隔离与指标采集） |

## 技术栈与部署载体导航矩阵

首期覆盖 **Spring Boot 3（JDK 21 + Maven 可执行 Jar）** 与 **Vue 3（Node.js 22 + pnpm + Vite 纯静态 SPA）** 两大**技术栈**，以及 **Docker**、**Docker Compose**、**宿主机直跑（`systemd`）** 与 **Kubernetes** 四类**部署载体**。

> [!NOTE]
> 当前处于仓库工程基线阶段，各技术栈**参考应用**与**部署载体**目录占位路径如下所示，后续模块随对应工单合入后将逐步激活导航链接。

| 技术栈 | 仓库路径与参考应用说明 | Docker | Docker Compose | 宿主机直跑（`systemd`） | Kubernetes |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Spring Boot 3** | `templates/spring-boot-jar/`<br>唯一 Jar 参考应用，支持端口隔离、优雅停机、内置零依赖 JDK 探针与可选 OTLP 开关 | `deploy/docker/`<br>(`quickstart` / `production` / `hardened`) | `deploy/compose/`<br>(`quickstart` / `production` / `hardened`) | `deploy/systemd/`<br>(`quickstart` / `production` / `hardened`，原生 `systemd` 服务单元 + 原子切换) | `deploy/kubernetes/`<br>(`quickstart` / `production` / `hardened`，含 `Ingress` 与 Kustomize 入口) |
| **Vue 3** | `templates/vue3-pnpm/`<br>唯一纯静态 SPA 参考应用，支持 History 回退与 `window.__APP_CONFIG__` 运行时配置注入 | `deploy/docker/`<br>(`quickstart` / `production` / `hardened`) | `deploy/compose/`<br>(`quickstart` / `production` / `hardened`) | `deploy/systemd/`<br>(`quickstart` / `production` / `hardened`，系统 `nginx.service` + 原子软链切换) | `deploy/kubernetes/`<br>(`quickstart` / `production` / `hardened`，含 `Ingress` 与 Kustomize 入口) |

## 三级能力演进对比

| 能力维度 | `quickstart`（快速级） | `production`（生产级） | `hardened`（企业加固级） |
| :--- | :--- | :--- | :--- |
| **基础镜像与构建** | 标准构建与基础运行时镜像 | 构建依赖缓存、分层 Jar 解包 / 锁文件严格安装、非 root 运行镜像 | 无 shell Distroless Java 21 / 非特权 Nginx，最小运行时攻击面 |
| **运行权限与容器安全** | 默认容器权限与可写文件系统 | 非 root UID 运行、资源请求与限额、容器内存感知参数 | 只读根文件系统 + 临时可写挂载、`cap_drop: ALL`、禁止提权、`NetworkPolicy` |
| **端口与流量隔离** | 单业务端口监听与静态托管 | 后端管理端口拆分至 `8081`、前端非特权端口 `8080` 与分级缓存/安全响应头 | 反代屏蔽管理端点、严格 CSP 响应头与最小放行策略 |
| **健康探针与生命周期** | 基础存活检查或脚本可运行校验 | `liveness` / `readiness` / `startup` 探针、优雅停机、滚动更新、HPA 与 PDB | 无 shell 内置 JDK 探针类健康检查、零报错只读配置注入（`Cache-Control: no-store`） |
| **可观测性与审计** | 标准输出 / `journald` 基础日志 | 暴露 `/actuator/prometheus` 指标端点、日志滚动限制 | 标准 Prometheus 采集注解、可选 `ServiceMonitor` 参考、可选 OTLP 开关与 SPDX SBOM |

## 仓库目录拓扑

```text
.
├── CONTEXT.md                 # 仓库领域词汇表与术语约束
├── LICENSE                    # MIT 开源协议
├── README.md                  # 仓库中文总览与导航入口
├── .editorconfig              # 跨操作系统编辑器缩进与编码基线
├── .gitattributes             # 跨操作系统文本行尾（LF）强制约束
├── .gitignore                 # 构建产物、本地凭据与临时文件忽略规则
├── docs/
│   ├── adr/                   # 架构决策记录（ADR-0001 至 ADR-0004）
│   └── agents/                # 工程代理协作规范
├── templates/                 # 技术栈参考应用与多载体独立等级副本（规划占位）
│   ├── spring-boot-jar/       # Spring Boot 3 Jar 技术栈模板
│   └── vue3-pnpm/             # Vue 3 + pnpm + Vite 静态站点技术栈模板
├── scripts/                   # 跨载体统一验证与发版打包脚本（规划占位）
└── .github/
    └── workflows/             # 日常验证流水线与标签触发发版流水线（规划占位）
```

## 容器镜像与发版产物规范

- **容器镜像坐标**：`ghcr.io/atengk/deploy-templates/<stack>:<tier>`（支持 `linux/amd64` 与 `linux/arm64` 双架构）；正式发版时同时推送不可变标签 `:<tag>-<tier>` 与浮动标签 `:<tier>`，其中 `:latest` 指向 `production`。
- **GitHub Release 发版产物**：随语义化发布标签统一生成的离线交付件，包括 Spring Boot 3 可执行 Jar、Vue 3 静态构建归档、两套技术栈的宿主机即用部署归档、`hardened` 镜像 SPDX SBOM 以及覆盖全部附件的 `SHA256SUMS.txt` 校验清单（不附加容器镜像导出文件）。

## 跨操作系统工程与安全基线

1. **行尾与编码约束**：仓库通过 [`.gitattributes`](./.gitattributes) 与 [`.editorconfig`](./.editorconfig) 强制所有文本与面向 Linux 的脚本（`*.sh`）、`systemd` 单元（`*.service`）、Nginx 配置（`*.conf`）、`Dockerfile` 及 YAML/JSON 清单统一使用 `UTF-8` 编码与 `LF` 行尾。
2. **忽略边界与零明文凭据**：通过 [`.gitignore`](./.gitignore) 排除构建产物、依赖目录与本地 `.env*` 文件，仅放行 `*.env.example` 与 `.env.example` 模板示例；所有文档、配置与脚本严禁出现明文凭据或本地绝对路径。
3. **术语与架构参考**：贡献或扩展模板前，请先阅读 [领域词汇表](./CONTEXT.md) 与 [架构决策记录](./docs/adr/)。

## 开源协议

本项目基于 [MIT License](./LICENSE) 开源。
