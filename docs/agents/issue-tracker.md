# Issue 追踪器：GitHub

本仓库的 Issue 与规格文档（Spec）均以 GitHub Issues 形式托管，所有操作统一使用 `gh` CLI。

## 操作约定

- **创建 Issue**：`gh issue create --title "..." --body "..."`。多行正文请使用 heredoc 或通过 `--body-file` 传入。
- **查看 Issue**：`gh issue view <number> --json number,title,body,labels,comments`。
- **列出 Issue**：`gh issue list --state open --json number,title,body,labels,comments --jq '[.[] | {number, title, body, labels: [.labels[].name], comments: [.comments[].body]}]'`，按需配合 `--label` 与 `--state` 过滤条件。
- **将 Issue 设为父 Issue 的子 Issue（Sub-issue）**：使用 `gh issue create --parent <parent> ...`，或事后执行 `gh issue edit <parent> --add-sub-issue <child>`（需 `gh` 2.94+）。旧版本 `gh` 可使用 `gh api --method POST repos/<owner>/<repo>/issues/<parent>/sub_issues -F sub_issue_id=<child-db-id>`（数据库 ID，获取方式同下方**阻塞关系**）。若不支持 Sub-issue，则在子 Issue 正文顶部标注 `Part of #<parent>`。
- **阻塞关系（Blocking）**：使用 GitHub **原生 Issue 依赖（native issue dependencies）**作为唯一权威且在 UI 中可见的表示方式。通过 `gh issue create --blocked-by <n>,<n> ...` 或 `gh issue edit <child> --add-blocked-by <blocker>` 添加依赖（需 `gh` 2.94+）。旧版本 `gh` 可使用 `gh api --method POST repos/<owner>/<repo>/issues/<child>/dependencies/blocked_by -F issue_id=<blocker-db-id>`，其中 `<blocker-db-id>` 是阻塞方的数字**数据库 ID**（通过 `gh api repos/<owner>/<repo>/issues/<n> --jq .id` 获取，*不要*使用 `#number` 或 `node_id`）。若原生依赖不可用，则退回到在子 Issue 正文顶部添加 `Blocked by: #<n>, #<n>` 行。当所有阻塞方均关闭后，该工单即解除阻塞。
- **统计未关闭的阻塞项**：`gh api repos/<owner>/<repo>/issues/<n> --jq .issue_dependencies_summary.blocked_by`（仅统计 open 状态的阻塞项；返回 `0` 表示可以开始执行）。`gh issue view <n> --json blockedBy` 会同时列出已关闭的阻塞项，因此需配合过滤：`--jq '[.blockedBy.nodes[] | select(.state == "OPEN")] | length'`。
- **评论 Issue**：`gh issue comment <number> --body "..."`。
- **添加 / 移除标签**：`gh issue edit <number> --add-label "..."` / `--remove-label "..."`。
- **关闭 Issue**：先使用 `gh issue comment <number> --body "..."` 发表关闭说明，再执行 `gh issue close <number>`。注意：对已关闭的 Issue 直接运行 `gh issue close --comment` 会静默丢弃评论且仍返回退出码 `0`。

目标仓库自动从 `git remote -v` 推断；在本地克隆仓库目录中执行 `gh` 时会自动识别。

仅允许向用户自己的仓库提交 Issue，严禁提交到 `mattpocock/skills`（技能源仓库），除非用户本人拥有该仓库。在 Fork 仓库中，`gh` 可能默认指向上游父仓库，因此在每次会话首次执行 `gh issue create` 之前，务必先运行 `gh repo view --json nameWithOwner` 校验目标仓库；若不是用户自己的仓库，必须先向用户确认。

## 将 Pull Request 作为分诊入口

**PRs as a request surface: no.** _（若本仓库将外部 PR 视为功能需求纳入分诊队列，请改为 `yes`；`/triage` 技能会读取此标记。）_

当设置为 `yes` 时，PR 使用与 Issue 相同的标签与状态机，对应改用 `gh pr` 子命令：

- **查看 PR**：先执行 `gh pr view <number>`，再执行 `gh pr view <number> --comments`（非 TTY 环境下 `--comments` 仅输出评论而不输出正文），并通过 `gh pr diff <number>` 查看代码变更。
- **列出待分诊的外部 PR**：`gh api --paginate 'repos/{owner}/{repo}/pulls?state=open' --jq '.[] | select(.author_association | IN("OWNER","MEMBER","COLLABORATOR") | not) | {number, title, author: .user.login, author_association, labels: [.labels[].name]}'`。
- **评论 / 打标 / 关闭**：`gh pr comment`、`gh pr edit --add-label`/`--remove-label`、`gh pr close`。

GitHub 的 Issue 与 PR 共用同一套编号空间，因此裸编号 `#42` 可能是 Issue 也可能是 PR：解析时先尝试 `gh pr view 42`，失败后再回退到 `gh issue view 42`。

## 当技能要求“发布到 Issue 追踪器”时

创建一个 GitHub Issue。

## 当技能要求“拉取相关工单”时

按上文**查看 Issue**的约定读取该 Issue。

## Wayfinding 探路操作

供 `/wayfinder` 技能使用。**地图（map）**是一个单独的 Issue，各**子工单（child）**作为其子 Issue 挂载。

- **地图（Map）**：带有 `wayfinder:map` 标签的单个 Issue，正文包含 Notes / Decisions-so-far / Fog 三部分。创建命令：`gh issue create --label wayfinder:map`。
- **子工单（Child ticket）**：作为 GitHub Sub-issue 关联到地图 Issue（参见上文**将 Issue 设为父 Issue 的子 Issue**）。若未启用 Sub-issue，则在地图正文中加入任务列表项，并在子工单正文顶部添加 `Part of #<map>`。标签格式为 `wayfinder:<type>`（取值为 `research` / `prototype` / `grilling` / `task`）。被认领后，该工单会指派给负责推进的开发者。
- **阻塞关系（Blocking）**：遵循上文“操作约定”中的**阻塞关系**规则。
- **前沿可推进工单查询（Frontier query）**：列出地图下所有 open 状态的子工单（`gh issue list --state open`，限定在地图的 sub-issues 或任务列表范围内），剔除存在未关闭阻塞项（参见**统计未关闭的阻塞项**，或检查 `Blocked by` 行中是否仍有 open Issue）或已被指派的工单；按地图排列顺序取第一个。
- **认领（Claim）**：`gh issue edit <n> --add-assignee @me`，作为本次会话的首个写操作。
- **解决（Resolve）**：先执行 `gh issue comment <n> --body "<answer>"`，再执行 `gh issue close <n>`，最后将上下文指针（要点摘要 + 链接）追加到地图的 Decisions-so-far 区域。
