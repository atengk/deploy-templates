# Vue 3 Kubernetes 部署载体说明

本目录提供 **Vue 3 + pnpm + Vite** **技术栈**在 Kubernetes **部署载体**下的三级**独立等级副本**（`quickstart`、`production`、`hardened`）。各目录均维护完整可读的原生 Kubernetes YAML 清单与同目录 `kustomization.yaml` 聚合入口，不依赖 Helm 或跨等级隐式继承，坚持**单应用交付**边界，可直接拷贝任意单个目录部署至标准 Kubernetes 集群。

## 目录拓扑

```text
deploy/kubernetes/
├── README.md                     # 本说明文档
├── quickstart/                   # 快速级：80 端口静态托管、基础就绪探针、Service 与 Ingress
│   ├── kustomization.yaml
│   ├── deployment.yaml
│   ├── service.yaml
│   └── ingress.yaml
├── production/                   # 生产级：非 root 8080 端口、ConfigMap 运行时注入、三探针、资源限额、HPA 与 PDB
│   ├── kustomization.yaml
│   ├── configmap.yaml
│   ├── deployment.yaml
│   ├── service.yaml
│   ├── ingress.yaml
│   ├── hpa.yaml
│   └── pdb.yaml
└── hardened/                     # 企业加固级：只读根文件系统、/tmp 临时卷、Capabilities 全裁剪、Token 禁用与 NetworkPolicy
    ├── kustomization.yaml
    ├── configmap.yaml
    ├── deployment.yaml
    ├── service.yaml
    ├── ingress.yaml
    ├── hpa.yaml
    ├── pdb.yaml
    └── networkpolicy.yaml
```

## 三级演进对照

| 能力维度 | `quickstart`（快速级） | `production`（生产级） | `hardened`（企业加固级） |
| :--- | :--- | :--- | :--- |
| **默认镜像坐标** | `ghcr.io/atengk/deploy-templates/vue3-pnpm:quickstart` | `ghcr.io/atengk/deploy-templates/vue3-pnpm:production` | `ghcr.io/atengk/deploy-templates/vue3-pnpm:hardened`（上线前须锁定不可变标签或 Digest） |
| **运行用户与容器端口** | 容器默认用户，监听 `80` | 非 root `runAsUser: 101` / `runAsGroup: 101`，监听 `8080` | 非 root `101:101` + `fsGroupChangePolicy: OnRootMismatch`，监听 `8080` |
| **一次构建，运行时注入** | 回退镜像构建期变量或默认值 | 通过 [`./production/configmap.yaml`](./production/configmap.yaml) + `envFrom` 注入 `APP_*` 与 `TZ` | 通过 [`./hardened/configmap.yaml`](./hardened/configmap.yaml) + `envFrom` 注入，入口脚本写入 `/tmp/app-runtime/config.js` |
| **只读根文件系统与挂载** | 可写容器层，无临时卷 | 可写容器层 `/tmp`，无显式卷限制 | `readOnlyRootFilesystem: true` + `emptyDir`（`sizeLimit: 64Mi`）挂载覆盖 `/tmp` |
| **特权与 API 访问治理** | 默认容器配置 | `runAsNonRoot: true`、`seccompProfile: RuntimeDefault`、`allowPrivilegeEscalation: false` | 额外叠加 `capabilities.drop: ["ALL"]`、`automountServiceAccountToken: false`、`enableServiceLinks: false` |
| **健康探针与可用性** | 基础 `readinessProbe`（`/healthz`） | `startupProbe` + `readinessProbe` + `livenessProbe`、`preStop` 缓冲、零停机滚动更新 | 完整三探针 + `preStop` 缓冲 + 零停机滚动更新（兼容 Pod Security `restricted` 基线） |
| **资源与弹性治理** | 单副本（`replicas: 1`），无资源限额 | 2 副本起、CPU/内存 `requests` 与 `limits`、HPA（`autoscaling/v2`）与 PDB（`policy/v1`） | 2 副本起、资源 `requests`/`limits`、HPA（`autoscaling/v2`）与 PDB（`policy/v1`） |
| **流量入口与网络隔离** | `Service`（`80 -> 80`）+ `Ingress`（`networking.k8s.io/v1`，`ingressClassName: nginx`） | `Service`（`80 -> 8080`）+ `Ingress`（含 TLS 占位） | `Service`（`80 -> 8080`）+ `Ingress` + 默认拒绝加最小放行 `NetworkPolicy` |

> [!NOTE]
> 各交付等级复用的容器镜像构建定义与 Nginx 配置细节，可对照参考 [Vue 3 Docker 部署载体说明](../docker/README.md) 及 [Vue 3 参考应用文档](../../README.md)。

## 渲染、部署与校验命令

### 1. 离线渲染与官方 Schema / 安全审计

在仓库根目录下使用 `kubectl kustomize` 校验渲染输出，并在完整工具链环境中结合 `kubeconform` 与 `trivy config` 执行严格模式校验与安全审计：

```bash
# 使用 Kustomize 渲染各交付等级完整 YAML 清单
kubectl kustomize templates/vue3-pnpm/deploy/kubernetes/quickstart
kubectl kustomize templates/vue3-pnpm/deploy/kubernetes/production
kubectl kustomize templates/vue3-pnpm/deploy/kubernetes/hardened

# 严格模式校验官方 Kubernetes Schema（零外部 CRD 依赖，可直接适配裸集群）
kubectl kustomize templates/vue3-pnpm/deploy/kubernetes/quickstart | kubeconform -strict -summary
kubectl kustomize templates/vue3-pnpm/deploy/kubernetes/production | kubeconform -strict -summary
kubectl kustomize templates/vue3-pnpm/deploy/kubernetes/hardened   | kubeconform -strict -summary

# 安全上下文与策略静态审计（建议对企业加固级执行严格阻断）
trivy config --severity HIGH,CRITICAL --exit-code 1 templates/vue3-pnpm/deploy/kubernetes/hardened
```

### 2. 部署至集群与黑盒验收

```bash
# 按目标交付等级一键部署至当前默认命名空间（或通过 -n 指定命名空间）
kubectl apply -k templates/vue3-pnpm/deploy/kubernetes/production
kubectl apply -n vue3-demo -k templates/vue3-pnpm/deploy/kubernetes/production

# 观察 Pod 就绪状态
kubectl rollout status -n vue3-demo deployment/vue3-pnpm

# 端口转发验证健康端点与运行时注入脚本
kubectl port-forward -n vue3-demo svc/vue3-pnpm 18080:80
curl -fsS http://127.0.0.1:18080/healthz
curl -fsS -D - http://127.0.0.1:18080/config.js
```

> [!TIP]
> 在 `production` 与 `hardened` 中，`Deployment` 直接引用原生 [`configmap.yaml`](./production/configmap.yaml)。更新 `ConfigMap` 内的 `APP_*` 配置后，请执行 `kubectl rollout restart -n <namespace> deployment/vue3-pnpm` 触发 Pod 重建，以便容器入口脚本重新生成 `/tmp/app-runtime/config.js`。

## 镜像替换说明

每个交付等级的 `kustomization.yaml` 均已预留标准 `images:` 覆盖块，无需改动原生 `deployment.yaml` 即可一行切换镜像仓库与版本标识：

```yaml
images:
  - name: ghcr.io/atengk/deploy-templates/vue3-pnpm
    newName: registry.example.com/your-org/vue3-pnpm
    newTag: "1.0.0-hardened"
    # 或移除 newTag 并直接锁定不可变镜像摘要：
    # digest: sha256:0000000000000000000000000000000000000000000000000000000000000000
```

> [!IMPORTANT]
> 使用 **`hardened`**（[`./hardened/kustomization.yaml`](./hardened/kustomization.yaml)）上线前，**必须**将浮动标签 `:hardened` 替换为不可变发布标签（如 `1.0.0-hardened`）或 `digest`（`sha256:...`），避免节点拉取策略或镜像更新引发不可预期的版本漂移。

## 自有集群迁移清单

将本目录模板迁移至自有 Kubernetes 集群或业务前端项目时，请逐项核对以下清单：

1. **单目录拷贝**：根据目标安全基线，完整拷贝 `quickstart/`、`production/` 或 `hardened/` 目录至自有部署仓库（若仅需原生 `kubectl apply -f`，可保留清单中的标准标签并移除 `kustomization.yaml`）。
2. **锁定镜像坐标**：在 `kustomization.yaml` 的 `images:` 块中将 `newName` 替换为内部镜像仓库地址，`hardened` 必须固定版本标签或 `digest`。
3. **配置运行时环境变量**：在 `configmap.yaml` 中按实际目标业务更新 `APP_TITLE`、`APP_VERSION`、`APP_ENV`、`APP_API_BASE_URL` 与 `TZ`；若前端扩展了新的 `APP_*` 字段，需同步在对应容器镜像的 `docker-entrypoint.sh` 中放行。
4. **调整 `Ingress` 域名与 TLS 证书**：将 `ingress.yaml` 中的占位域名 `vue3.example.com` 替换为实际域名，核对集群 `ingressClassName`（默认 `nginx`），并取消 `tls:` 注释挂载有效 HTTPS 证书 Secret。
5. **核对 `hardened` 临时卷与权限**：若自有前端构建产物或自定义 Nginx 配置新增了写入路径，务必确保仅写入 `emptyDir` 挂载覆盖的 `/tmp` 子目录，切勿破坏 `readOnlyRootFilesystem: true` 与非 root `101:101` 权限边界。
6. **适配 `NetworkPolicy` 选择器**：[`./hardened/networkpolicy.yaml`](./hardened/networkpolicy.yaml) 默认仅放行 `kubernetes.io/metadata.name: ingress-nginx` 命名空间访问 `8080/TCP`，以及 `kube-system` 命名空间的 `53/UDP`、`53/TCP` DNS 出站。若集群 Ingress Controller 位于其他命名空间（例如 `kube-system` 或 `gateway`），请同步更新 `namespaceSelector`。
7. **确认集群插件前置条件**：使用 `HPA` 需确保集群已安装 `metrics-server`；使用 `NetworkPolicy` 需确保 CNI 插件（如 Cilium、Calico）支持并启用网络策略执行。
