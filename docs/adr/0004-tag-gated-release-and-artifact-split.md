---
status: accepted
---

# 双流水线严格隔离，仅版本标签触发发版并分离镜像与 Release 产物

普通提交与 PR 若直接推送镜像或创建 Release，容易污染公开镜像标签并引入未审核产物；同时将数百 MB 的 `docker save` 镜像包直接塞进 GitHub Release 也会导致附件臃肿、难以维护。我们决定将 GitHub Actions 拆分为严格隔离的两条流水线：`ci.yml` 仅在 PR、推送 `main` 或手动触发时执行按路径过滤的四载体门禁验证（绝不发布外部产物）；`release.yml` 严格仅在推送语义化版本标签（`v*.*.*`）时触发，以 Git Tag 为唯一版本真相源，跨编译推送 `linux/amd64` 与 `linux/arm64` 容器镜像至 GHCR，而 GitHub Release 仅托管应用构建产物、宿主机即用部署归档、SBOM 与 `SHA256SUMS.txt`，并在 Release Notes 中列出镜像地址与 Digest。

## 备选方案（Considered Options）

- **合并到 `main` 即自动构建推送 `:latest` 镜像**：反馈快，但违背“仅发版时构建发布最终产物”的治理边界，且易产生未版本化的不稳定镜像。
- **同步推送 Docker Hub 或将镜像 `.tar` 放入 Release**：增加外部凭据管理成本或导致单次 Release 附件膨胀至 GB 级。

## 影响（Consequences）

- 每次正式发版只需推送一个 `v*.*.*` 标签即可完成全量验证、双架构镜像发布与 Release 归档；若未来确需 Docker Hub 同步或离线镜像导出，可在不破坏既有标签契约的前提下独立扩展。
