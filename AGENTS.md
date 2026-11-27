# AGENTS.md

## Agent skills

### Issue 追踪器（Issue tracker）

本仓库的 Issue 与规格文档（Spec）统一托管在 GitHub Issues（`atengk/deploy-templates`），使用 `gh` CLI 进行操作。详见 `docs/agents/issue-tracker.md`。

### 分诊标签（Triage labels）

使用 5 个默认标准分诊标签（`needs-triage`、`needs-info`、`ready-for-agent`、`ready-for-human`、`wontfix`）。详见 `docs/agents/triage-labels.md`。

### 领域文档（Domain docs）

采用单上下文（single-context）布局：仓库根目录维护 `CONTEXT.md`，架构决策记录存放于 `docs/adr/`。详见 `docs/agents/domain.md`。
