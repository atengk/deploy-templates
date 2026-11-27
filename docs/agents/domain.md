# 领域文档（Domain Docs）

规范各工程技能在探索代码库时如何消费本仓库的领域文档。

当前布局：**单上下文（single-context）**（仓库根目录维护 `CONTEXT.md`，架构决策记录存放于 `docs/adr/`）。

## 探索代码库前先阅读以下文档

- 仓库根目录的 **`CONTEXT.md`**，或
- 若仓库根目录存在 **`CONTEXT-MAP.md`**（多上下文场景）：它会指向各个上下文各自的 `CONTEXT.md`，请按需阅读与当前主题相关的文档。
- **`docs/adr/`**：阅读与你即将改动的领域相关的架构决策记录（ADR）。在多上下文仓库中，还需检查 `src/<context>/docs/adr/` 下的上下文级决策。

若上述文件尚不存在，请**静默继续**。不要主动提醒它们缺失，也不要提前建议创建。`/domain-modeling` 技能（通常经由 `/grill-with-docs` 与 `/improve-codebase-architecture` 触发）会在术语或架构决策真正落地时按需惰性创建它们。

## 目录结构

单上下文仓库（本仓库当前采用的布局）：

```text
/
├── CONTEXT.md
├── docs/adr/
│   ├── 0001-event-sourced-orders.md
│   └── 0002-postgres-for-write-model.md
└── src/
```

多上下文仓库（当根目录存在 `CONTEXT-MAP.md` 时）：

```text
/
├── CONTEXT-MAP.md
├── docs/adr/                          ← 系统级架构决策
└── src/
    ├── ordering/
    │   ├── CONTEXT.md
    │   └── docs/adr/                  ← 上下文专属架构决策
    └── billing/
        ├── CONTEXT.md
        └── docs/adr/
```

## 遵循词汇表中的领域术语

当你的产出提及领域概念时（如 Issue 标题、重构提案、排障假设、测试命名等），必须使用 `CONTEXT.md` 中定义的标准术语，切勿漂移到词汇表明确排除的近义词。

如果你需要的概念尚未收录在词汇表中，这通常意味着：要么你正在引入项目并未使用的生造词（请重新斟酌），要么确实存在领域模型缺口（请记录下来，留待 `/domain-modeling` 处理）。

## 显式标出 ADR 冲突

如果你的方案或产出与既有 ADR 相冲突，请明确指出，切勿静默覆盖：

> _与 ADR-0007（事件溯源订单模型）存在冲突，但值得重新讨论，原因是……_
