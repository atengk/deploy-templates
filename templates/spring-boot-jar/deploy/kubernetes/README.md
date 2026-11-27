# Spring Boot 3 Kubernetes 部署载体说明

本目录提供 **Spring Boot 3（JDK 21 可执行 Jar）** **技术栈**在 Kubernetes **部署载体**下的三级**独立等级副本**（`quickstart`、`production`、`hardened`）。各目录均维护完整可读的原生 Kubernetes YAML 清单与同目录 `kustomization.yaml` 聚合入口，不依赖 Helm 或跨等级隐式继承，坚持**单应用交付**边界，可直接拷贝任意单个目录部署至标准 Kubernetes 集群。

## 目录拓扑

```text
deploy/kubernetes/
├── README.md                     # 本说明文档
├── quickstart/                   # 快速级：单端口 8080、基础就绪探针、ClusterIP Service 与 Ingress
│   ├── kustomization.yaml
│   ├── deployment.yaml
│   ├── service.yaml
│   └── ingress.yaml
├── production/                   # 生产级：非 root（10001）、8080/8081 端口隔离、三探针、资源限额、HPA 与 PDB
│   ├── kustomization.yaml
│   ├── configmap.yaml
│   ├── deployment.yaml
│   ├── service.yaml
│   ├── ingress.yaml
│   ├── hpa.yaml
│   └── pdb.yaml
└── hardened/                     # 企业加固级：Distroless（65532）、只读根文件系统、/tmp 临时卷、NetworkPolicy 与监控注解
    ├── kustomization.yaml        # 默认不引入 servicemonitor.yaml，保障裸集群零 CRD 报错
    ├── configmap.yaml
    ├── deployment.yaml
    ├── service.yaml
    ├── ingress.yaml
    ├── hpa.yaml
    ├── pdb.yaml
    ├── networkpolicy.yaml
    └── servicemonitor.yaml       # 可选 Prometheus Operator ServiceMonitor 参考清单
```

## 三级演进对照

| 能力维度 | `quickstart`（快速级） | `production`（生产级） | `hardened`（企业加固级） |
| :--- | :--- | :--- | :--- |
| **默认镜像坐标** | `ghcr.io/atengk/deploy-templates/spring-boot-jar:quickstart` | `ghcr.io/atengk/deploy-templates/spring-boot-jar:production` | `ghcr.io/atengk/deploy-templates/spring-boot-jar:hardened`（上线前须锁定不可变标签或 Digest） |
| **运行用户与容器端口** | 镜像默认用户，单端口 `8080` | 非 root `10001:10001`，业务 `8080` + 管理 `8081` 隔离 | Distroless 非 root `65532:65532`（无 shell），业务 `8080` + 管理 `8081` 隔离 |
| **配置与 JVM 运行参数** | `Deployment` 内联基础 `env`（`TZ`、`SERVER_PORT`） | 通过 [`./production/configmap.yaml`](./production/configmap.yaml) + `envFrom` 注入 `JAVA_OPTS` 与运行时配置 | 通过 [`./hardened/configmap.yaml`](./hardened/configmap.yaml) + `envFrom` 注入端口与 `TOMCAT_BASEDIR`（沿用镜像内置 JVM 参数） |
| **只读根文件系统与挂载** | 可写容器层，无临时卷 | 可写容器层 `/tmp`，无显式卷限制 | `readOnlyRootFilesystem: true` + `emptyDir`（`sizeLimit: 64Mi`）挂载覆盖 `/tmp` |
| **特权与 API 访问治理** | 默认容器配置 | `runAsNonRoot: true`、`seccompProfile: RuntimeDefault`、`allowPrivilegeEscalation: false` | 额外叠加 `capabilities.drop: ["ALL"]`、`automountServiceAccountToken: false`、`enableServiceLinks: false` |
| **健康探针与优雅停机** | `readinessProbe` 探测 `8080` `/actuator/health` | `8081` 管理端口三探针（`startup`/`readiness`/`liveness`）+ `preStop` `sleep 5` + `terminationGracePeriodSeconds: 30` | `8081` 管理端口三探针 + PID 1 JVM 原生接收 `SIGTERM` 优雅停机（无 `/bin/sh` 依赖）+ `terminationGracePeriodSeconds: 30` |
| **资源与弹性治理** | 单副本（`replicas: 1`），无资源限额 | 2 副本起、CPU/内存 `requests`/`limits`、HPA（`autoscaling/v2`）与 PDB（`policy/v1`） | 2 副本起、资源 `requests`/`limits`、HPA（`autoscaling/v2`）与 PDB（`policy/v1`） |
| **流量入口与网络隔离** | `Service`（`8080`）+ `Ingress`（`networking.k8s.io/v1`，`ingressClassName: nginx`） | `Service`（仅 `8080`）+ `Ingress`（仅指向 `8080`，含 TLS 占位） | `Service`（仅 `8080`）+ `Ingress` + 默认拒绝加最小放行 `NetworkPolicy`（`8080` 供入口、`8081` 供监控、DNS 出站） |
| **监控指标采集接入** | Actuator `/actuator/prometheus` 随 `8080` 暴露 | 仅通过 `8081` 暴露 `/actuator/prometheus`（未纳入业务 `Service`） | Pod 模板内置标准 `prometheus.io/scrape` 注解采集 `8081`，另附可选 [`./hardened/servicemonitor.yaml`](./hardened/servicemonitor.yaml) |

> [!NOTE]
> 各交付等级复用的容器镜像构建定义与运行时约定，可对照参考 [Spring Boot 3 Docker 部署载体说明](../docker/README.md) 及 [Spring Boot 3 参考应用文档](../../README.md)。

## 渲染、部署与校验命令

### 1. 离线渲染与官方 Schema / 安全审计

在仓库根目录下使用 `kubectl kustomize` 渲染各交付等级完整清单，并在完整工具链环境中结合 `kubeconform` 与 `trivy config` 执行严格模式 Schema 校验与静态安全审计：

```bash
# 使用 Kustomize 渲染各交付等级完整 YAML 清单
kubectl kustomize templates/spring-boot-jar/deploy/kubernetes/quickstart
kubectl kustomize templates/spring-boot-jar/deploy/kubernetes/production
kubectl kustomize templates/spring-boot-jar/deploy/kubernetes/hardened

# 严格模式校验官方 Kubernetes Schema（默认不引入外部 CRD，可直接适配裸集群）
kubectl kustomize templates/spring-boot-jar/deploy/kubernetes/quickstart | kubeconform -strict -summary
kubectl kustomize templates/spring-boot-jar/deploy/kubernetes/production | kubeconform -strict -summary
kubectl kustomize templates/spring-boot-jar/deploy/kubernetes/hardened   | kubeconform -strict -summary

# 安全上下文与策略静态审计（建议对企业加固级执行 HIGH/CRITICAL 阻断）
trivy config --severity HIGH,CRITICAL --exit-code 1 templates/spring-boot-jar/deploy/kubernetes/hardened
```

### 2. 部署至集群与黑盒验收

```bash
# 按目标交付等级一键部署至当前默认命名空间（或通过 -n 指定命名空间）
kubectl apply -k templates/spring-boot-jar/deploy/kubernetes/production
kubectl apply -n spring-boot-demo -k templates/spring-boot-jar/deploy/kubernetes/production

# 观察 Pod 就绪状态
kubectl rollout status -n spring-boot-demo deployment/spring-boot-jar

# 验证业务端口 8080（业务 Service 仅暴露 8080，不暴露 /actuator/* 管理端）
kubectl port-forward -n spring-boot-demo svc/spring-boot-jar 18080:8080
curl -fsS http://127.0.0.1:18080/api/info

# 验证独立管理端口 8081（通过 Pod 端口转发验证健康探针与 Prometheus 指标）
kubectl port-forward -n spring-boot-demo deployment/spring-boot-jar 18081:8081
curl -fsS http://127.0.0.1:18081/actuator/health/readiness
curl -fsS http://127.0.0.1:18081/actuator/prometheus | head -n 5
```

> [!TIP]
> 在 `production` 与 `hardened` 中，`Deployment` 通过 `envFrom` 引用原生 `ConfigMap`。更新 `ConfigMap` 内的环境变量后，请执行 `kubectl rollout restart -n <namespace> deployment/spring-boot-jar` 触发 Pod 滚动重建使新配置生效。

## 镜像替换说明

每个交付等级的 `kustomization.yaml` 均已预留标准 `images:` 覆盖块，无需改动原生 `deployment.yaml` 即可一行切换私有镜像仓库与不可变版本标识：

```yaml
images:
  - name: ghcr.io/atengk/deploy-templates/spring-boot-jar
    newName: registry.example.com/your-org/spring-boot-jar
    newTag: "1.0.0-hardened"
    # 或移除 newTag 并直接锁定不可变镜像摘要：
    # digest: sha256:0000000000000000000000000000000000000000000000000000000000000000
```

> [!IMPORTANT]
> 使用 **`hardened`**（[`./hardened/kustomization.yaml`](./hardened/kustomization.yaml)）上线受控集群前，**必须**将浮动标签 `:hardened` 替换为不可变发布标签（如 `1.0.0-hardened`）或 `digest`（`sha256:...`），防止节点拉取策略或镜像更新导致运行时漂移。

## 可选 `ServiceMonitor` 启用说明

企业加固级默认已在 [`./hardened/deployment.yaml`](./hardened/deployment.yaml) 的 Pod 模板中配置标准 `prometheus.io/scrape: "true"`、`prometheus.io/port: "8081"` 与 `prometheus.io/path: "/actuator/prometheus"` 注解，标准 Prometheus 服务发现可开箱采集，无需依赖第三方 CRD。

为保证未安装 Prometheus Operator CRD 的裸集群可以零报错执行 `kubectl apply -k` 与 `kubeconform -strict`，[`./hardened/servicemonitor.yaml`](./hardened/servicemonitor.yaml) **默认未列入** [`./hardened/kustomization.yaml`](./hardened/kustomization.yaml) 的 `resources:` 列表中。若目标集群已安装 Prometheus Operator 并希望改用 `ServiceMonitor` 采集，请按以下步骤启用：

1. **在 `Service` 中暴露内部管理端口**：编辑 [`./hardened/service.yaml`](./hardened/service.yaml)，取消 `management`（`8081`）端口注释（或单独建立仅供集群内监控使用的管理 `Service`），**切勿**将 `8081` 端口加入 [`./hardened/ingress.yaml`](./hardened/ingress.yaml) 对外暴露。
2. **确认网络策略放行监控命名空间**：检查 [`./hardened/networkpolicy.yaml`](./hardened/networkpolicy.yaml) 中针对 `8081/TCP` 的 `namespaceSelector`（默认为 `kubernetes.io/metadata.name: monitoring`），确保其匹配集群内 Prometheus 实际所在命名空间。
3. **单独应用或纳管 `ServiceMonitor`**：执行 `kubectl apply -n <namespace> -f templates/spring-boot-jar/deploy/kubernetes/hardened/servicemonitor.yaml`（或在自有部署仓库的 `hardened/kustomization.yaml` 中手动将 `servicemonitor.yaml` 加入 `resources:`）。

## 自有集群迁移清单

将本目录模板迁移至自有 Kubernetes 集群或业务 Spring Boot 3 项目时，请逐项核对以下清单：

1. **单目录拷贝**：根据目标安全基线，完整拷贝 `quickstart/`、`production/` 或 `hardened/` 目录至自有部署仓库（若仅需原生 `kubectl apply -f`，可移除 `kustomization.yaml` 并直接在 `deployment.yaml` 中替换镜像坐标）。
2. **锁定镜像坐标**：在 `kustomization.yaml` 的 `images:` 块中将 `newName` 替换为自有镜像仓库地址；`hardened` 上线前必须锁定不可变版本标签或 `digest`。
3. **分离注入敏感外部依赖**：遵循**单应用交付**边界，切勿将数据库密码、缓存口令或 API Token 写入 `configmap.yaml`；请通过独立 Kubernetes `Secret` 配合 `envFrom` 或 `secretKeyRef` 注入，并在接入外部数据库或 OpenTelemetry Collector（如 `4318/TCP`）时同步在 [`./hardened/networkpolicy.yaml`](./hardened/networkpolicy.yaml) 中追加对应 `egress` 规则。
4. **核对 JVM 参数与内存限额**：`production` 通过 `configmap.yaml` 的 `JAVA_OPTS` 传递内存百分比参数；`hardened` 基于 Distroless 无 shell 镜像，内存百分比参数已内建于镜像 `ENTRYPOINT`，如调整 Pod `resources.limits.memory`，请同步评估 `-XX:MaxRAMPercentage`（默认 `75.0`）。
5. **调整 `Ingress` 域名与 TLS 证书**：将 `ingress.yaml` 中的占位域名 `spring-boot.example.com` 替换为实际域名，核对集群 `ingressClassName`（默认 `nginx`），并取消 `tls:` 注释挂载受管 HTTPS 证书 Secret。
6. **排查只读根文件系统写入路径**：启用 `hardened` 的 `readOnlyRootFilesystem: true` 前，确认自有业务不存在向容器本地磁盘写入日志文件、上传临时文件或本地缓存的行为，统一写入已挂载 `emptyDir` 的 `/tmp` 目录或外部对象存储。
7. **适配 `NetworkPolicy` 选择器与插件前置条件**：若集群 Ingress Controller 不在 `ingress-nginx` 命名空间，或监控组件不在 `monitoring` 命名空间，请调整 `networkpolicy.yaml` 的 `namespaceSelector`；使用 `HPA` 需确保集群已安装 `metrics-server`，使用 `NetworkPolicy` 需确保 CNI 插件（如 Cilium、Calico）已启用网络策略执行。
