# Skill Garden

![License](https://img.shields.io/badge/license-MIT-blue.svg)

一个持续生长的 Agent Skill 合集：把可复用的工作流写成 `SKILL.md`，让 AI 在特定场景中稳定地完成一类工作，而不是每次重新摸索。

## 收录的 Skills

| Skill | 用途 |
| --- | --- |
| [`project-context-maintainer`](skills/project-context-maintainer/SKILL.md) | 创建并维护面向 AI 的 `AGENTS.md` 项目上下文与工作约定。 |
| [`repo-privacy-hardening`](skills/repo-privacy-hardening/SKILL.md) | 扫描项目中的密钥、个人信息与内网信息，清理后将项目改造为可公开的 GitHub 仓库。 |

## 怎么用

这些不是需要编译安装的软件包，而是**给 Agent 读的说明书**。把技能目录放进 Agent 的技能搜索路径即可：

```bash
git clone https://github.com/skdfndh/skill-garden.git
```

然后复制你需要的技能到对应目录（按你使用的 Agent 选一个）：

```bash
# Claude Code
cp -r skill-garden/skills/repo-privacy-hardening ~/.claude/skills/

# Codex 与 DSH 都读取这个目录
cp -r skill-garden/skills/repo-privacy-hardening ~/.agents/skills/
```

Windows PowerShell：

```powershell
Copy-Item -Recurse skill-garden\skills\repo-privacy-hardening "$HOME\.agents\skills\"
```

放好之后，Agent 会在下一次会话开始时自动发现它，你只要用自然语言描述任务即可，例如"帮我把这个项目脱敏后传到 GitHub"。

`repo-privacy-hardening` 自带安装脚本，也可以直接用它完成上述复制：

```powershell
.\skills\repo-privacy-hardening\scripts\install.ps1          # 干跑，先看会做什么
.\skills\repo-privacy-hardening\scripts\install.ps1 -Apply   # 真正执行
```

## 目录结构

```
skill-garden/
└── skills/
    └── <skill-name>/
        ├── SKILL.md          # 必需，入口：YAML frontmatter + 工作流说明
        ├── scripts/          # 可选，确定性任务的可执行代码
        ├── references/       # 可选，按需加载的详细资料
        └── assets/           # 可选，模板与素材
```

`SKILL.md` 的 frontmatter 至少要有 `name` 与 `description`，目录名需与 `name` 一致。`description` 决定技能何时被触发——写清"能做什么"和"什么时候该用"，不要写得太泛，否则会在不相关的任务上被误触发。

## 自己写一个

本仓库的约定见 [`AGENTS.md`](./AGENTS.md)。核心是两条：

1. **只写能改变 Agent 决策的具体规则**。重复通用编程常识或平台已有政策，只会占用上下文而不产生价值。
2. **渐进披露**。核心规则放 `SKILL.md`（保持在 500 行以内），细节拆到 `references/` 按需读取。

## 许可

[MIT](LICENSE) © 2026 kddsk
