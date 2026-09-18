<!-- Agent 的执行指令在 SKILL.md；本文件面向人类读者 -->

# repo-privacy-hardening

> 把一个"只有你自己知道里面有什么"的项目，检查一遍再公开到 GitHub——扫描密钥、个人信息与内网信息，清理后补齐开源工程文件。

## 它解决什么问题

把内部项目开源，风险不在技术难度，而在**不可逆**：

- 一次 `git push` 之后，即使立刻删文件、立刻重写历史，密钥也已经交给了所有抓取 GitHub 新仓库的爬虫
- 真实数据一旦公开就收不回来
- 而"删除引用"不等于"删除数据"——未被任何 ref 指向的提交，GitHub 仍会按 SHA 提供服务

所以这个技能的重心是**动手之前想清楚**，而不是删得快。

## 流程

| 步骤 | 做什么 |
| --- | --- |
| 1. 侦察 | 语言、依赖、是否 git 仓库、提交规模、有无现成工程文件 |
| 2. 扫描 | 跑扫描器 + 人眼确认正则抓不到的部分（截图、数据集、二进制） |
| 3. 分级报告 | P0/P1/P2 分档，每档给**具体处置动作**而不只是问题位置 |
| 4. 逐项清理 | 一次一项，拿到确认再改；改完复扫 |
| 5. 历史处置 | 先轮换密钥，再决定要不要重写历史（顺序不能反） |
| 6. 开源改造 | README、LICENSE、.gitignore、.gitattributes、CI、协作文件 |
| 7. 交付终检 | 零克隆验证、复扫、作者身份确认 |

## 三条不可动摇的规则

**报告不是可信文件，它本身就是隐私。** 报告会列出所有问题位置，写进仓库目录等于用一份新文件重演了你要修的问题。所以报告一律写到仓库之外。

**不要把明文敏感值显示给任何人。** 报告会被读进 AI 上下文、被贴进聊天窗口、被转发归档。所有值一律掩码（`sk-abc1…7f9c`）。

**只提案，不擅自改。** 删除文件、重写历史、推送远端都必须单独确认。"你看着办"只授权低风险项。

## 扫描器

自带 PowerShell 7 扫描器，只读，不依赖外部工具（`gitleaks` / `trufflehog` 未安装时也能用）：

```powershell
# 全量扫描，报告写到仓库之外
pwsh -File ./scripts/Scanner.ps1 -Path . -OutDir $env:TEMP/repo-privacy-scan

# 只查某一类
pwsh -File ./scripts/Scanner.ps1 -Path . -Mode secrets
```

| 模式 | 检查内容 |
| --- | --- |
| `secrets` | 20 条固定形态规则（AWS / GitHub / OpenAI / Slack / Stripe / 各家云厂商 / 私钥块 / JWT / 内嵌凭据的连接串）+ 香农熵兜底 |
| `pii` | 手机号、身份证号、邮箱、本机绝对路径 |
| `infra` | 内网 IP、内部域名、SSH 形式的 Git 远端 |
| `hygiene` | .gitignore 覆盖度、已被跟踪的敏感文件、大文件、提交作者身份 |
| `readme` | README **正确性**审计：死链、未替换占位符、许可证一致性、0-10 健康分 |
| `all` | 全部 |

退出码 `1` 表示存在 P0，可直接用于 CI 卡发布。

## 它是在真实仓库上磨出来的

这个技能不是写完就交付的。拿四个真实公开仓库跑过之后，修掉了 **15 个缺陷**，其中几个值得单独说：

**一条从未生效的死规则。** 跳过列表按完整路径匹配，但这八条规则没有前导 `*`：

```powershell
'package-lock.json'   # ← 永远匹配不到任何文件
'*.lock'              # ← 因为有 * 而正常，掩盖了缺陷
```

后果是 lock 文件里的 npm 完整性哈希被当作高熵密钥上报，**单个项目 84 条**，把真正的发现淹没。修完后某个仓库的 P1 从 88 条降到 4 条。

**把正确的工程实践报成事故。** 早期版本会把已被 `.gitignore` 正确挡住的 Android 签名密钥库报成 P0，把内容全是占位符的 `.env.example` 报成 P0。现在的判定分三态：

| 情况 | 判定 |
| --- | --- |
| 未被 git 跟踪 | P2——只是隐患，`.gitignore` 覆盖了就没事 |
| 被跟踪，但内容是占位符 | P2——模板文件本来就该提交 |
| 被跟踪且内容含真实值 | P0——这才是真泄露 |

**把正确做法报成错误。** 配置文件里写 `${MYSQL_PASSWORD}` 是从环境变量取值，是**正确**做法，早期版本却把它当明文口令报出来。同理还有 bcrypt 哈希、base64 内嵌图片、Java 包名 `com.foo.local`、移动端资源名 `Icon-App@2x.png`（`@2x` 被当成邮箱域名）。

**静默漏报比误报危险。** 修误报时踩过三次同一个坑：用 `example`、`abcdef`、`123456` 做**裸子串**匹配，结果静默漏掉了 `AKIAIOSFODNN7EXAMPLE` 和 `npm_abc...0123456789` 这类真实凭据。现在标记词一律要求落在片段边界上，而官方示例凭据**降级为 P2 提示而非静默忽略**——它可能只是教程引用，也可能是真把示例复制进了生产代码。

## 它抓不到什么

**这一点必须说清楚，因为"扫描无 P0"不等于"可以安全公开"：**

- 二进制文件内容（`.xlsx`、`.docx`、`.db`、图片）——扫描器只登记存在，不读内容
- 超过 2MB 的文件被跳过
- 非 UTF-8 编码的文本静默跳过
- 拆分拼接的密钥（`part1 + part2`）任何正则都抓不到
- **业务数据**：价格表、客户名单、订单导出——这类"敏感"没有任何格式特征

前几项可以靠人补，最后一项只能靠人判断。技能里附了一份 `references/privacy-checklist.md` 专门列出这些必须人工确认的项目。

## 使用示例

```text
帮我把 D:\work\my-project 脱敏后传到 GitHub。
```

```text
这个仓库准备开源，先做一次发布前安全检查。
```

```text
扫描一下这个项目有没有硬编码的密钥，顺便看看 README 有没有问题。
```

## 附带产出

| 文件 | 内容 |
| --- | --- |
| `references/secret-patterns.md` | 凭据类型、误报清单、`git filter-repo` 历史重写方案 |
| `references/privacy-checklist.md` | 正则抓不到的非文本隐私：截图 EXIF、数据集、二进制元数据 |
| `references/github-layout.md` | LICENSE 选择、README 结构、CI 模板对应关系 |
| `references/readme-design.md` | README 的说服力与视觉优化：首屏、一句话公式、徽章、常见错误清单 |
| `assets/gitignore-templates/` | common / python / node / java 四套模板 |
| `assets/README-template.md` | 带设计注释的 README 骨架 |

## 安装

```bash
cp -r skills/repo-privacy-hardening ~/.claude/skills/     # Claude Code
cp -r skills/repo-privacy-hardening ~/.agents/skills/     # Codex 与 DSH
```

或用它自带的安装脚本（默认干跑，`-Apply` 才真正执行）：

```powershell
.\scripts\install.ps1
.\scripts\install.ps1 -Apply
```

## 目录结构

```
repo-privacy-hardening/
├── SKILL.md                      # Agent 执行指令
├── scripts/
│   ├── Scanner.ps1               # 脱敏扫描器（约 54 KB）
│   └── install.ps1               # 安装脚本
├── references/
│   ├── secret-patterns.md
│   ├── privacy-checklist.md
│   ├── github-layout.md
│   └── readme-design.md
└── assets/
    ├── LICENSE-MIT.txt
    ├── README-template.md
    └── gitignore-templates/
```

## 环境要求

- PowerShell 7+（扫描器依赖 `pwsh`）
- git（历史检查用；未安装时降级为只扫工作区）
- 可选：`gh` CLI（建远端仓库用）、`git filter-repo`（历史重写用）

## 许可

[MIT](../../LICENSE) © 2026 kddsk。本仓库所有技能采用同一许可。
