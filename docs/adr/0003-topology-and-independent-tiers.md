---
status: accepted
---

# 按载体分组并维护独立等级副本，源码与 Dockerfile 按栈和等级复用

面对 `2 技术栈 × 4 部署载体 × 3 交付等级` 的组合，若每个目录都复制应用源码与 Dockerfile 会导致维护漂移，而若采用跨等级的 Compose Overlay、Kustomize Overlay 或 Helm 模板抽象，则会让参考读者无法在一个目录内直观读懂完整配置。我们决定采用 `templates/<stack>/{app, deploy/<target>/<tier>}` 拓扑：每个技术栈只保留唯一一份 `app/` 参考应用，同一载体下的三个交付等级各自维护完整独立的配置副本（Kubernetes 附带同目录 `kustomization.yaml`），而 Compose 与 Kubernetes 直接复用同等级 `docker/<tier>/Dockerfile` 构建出的容器镜像。

## 备选方案（Considered Options）

- **跨等级 Overlay / Helm 模板继承**：减少配置重复度，但引入模板黑盒与多文件跳转，违背开源参考模板“即看即懂、单目录拷贝”的首要目标。
- **按 `tier → target` 分组**：按成熟度优先导航，但实际使用者通常先确定部署载体（如 Compose 或 Kubernetes），再在载体内部横向对照三级演进。

## 影响（Consequences）

- 同一载体下三个等级的配置文件存在合理的结构重复，需要借助 CI 自动化门禁防止各等级配置漂移；换取了极高的可读性与零门槛拷贝体验。
