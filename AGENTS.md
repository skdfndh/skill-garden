# Skill Garden：项目上下文

## 项目目的

本仓库用于集中保存、版本管理和分享可复用的 Codex Skills。每个 Skill 应帮助 AI 在明确场景中稳定完成一类工作。

## 仓库结构

- `skills/<skill-name>/`：一个独立的 Skill 目录。
- 每个 Skill 必须包含 `SKILL.md`；可按实际需要包含 `agents/`、`scripts/`、`references/` 与 `assets/`。
- 根目录 `README.md`：面向人类的仓库介绍与 Skill 索引。
- 本文件 `AGENTS.md`：面向后续 AI 会话的仓库约定。

## Skill 编写约定

- Skill 目录名使用小写字母、数字和连字符，名称应简洁且反映用途。
- `SKILL.md` 必须有 `name` 与 `description` 的 YAML frontmatter。
- `description` 应明确说明能力和适用场景，并避免泛化到不相关任务。
- 只记录能改变 Agent 决策的具体规则；不重复通用编码常识或平台已执行的政策。
- 使用渐进披露：核心规则放在 `SKILL.md`，仅在确有必要时加入按需读取的 `references/` 或可复用的 `scripts/`。
- 不在 Skill、示例、日志或提交中写入密钥、令牌和个人敏感信息。

## 新增或修改 Skill 的流程

1. 先确认需求边界与触发场景。
2. 创建或更新最小必要文件，避免无关模板和占位文件。
3. 使用对应校验工具验证结构；涉及脚本时运行脚本验证行为。
4. 同步更新根目录 README 的 Skill 索引。
5. 提交信息应简短、准确描述改动。

## AGENTS.md 维护策略

本项目采用“确认后更新”：

- 当新增 Skill，或改动影响仓库结构、编写约定、发布方式或维护流程时，先展示拟更新的 `AGENTS.md` 内容或差异。
- 只有获得用户明确确认后，才写入本文件。
- 小型实现调整且不改变上述约定时，不更新本文件。

## 当前状态

- 首个已收录 Skill：`project-context-maintainer`。
