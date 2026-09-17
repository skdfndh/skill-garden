# 开源仓库的文件规范

第 6 步（开源改造）的执行细节。核心判断标准只有一条：**陌生人打开这个仓库，能不能在五分钟内搞懂它是什么、怎么跑起来、能不能用。**

## 核心四件套

### README.md

按这个顺序组织，每条都是访问者真实会问的问题：

```markdown
# 项目名

一句话说明这是什么、解决什么问题。（不要写"本项目是一个基于 XXX 的 YYY 系统"这类同义反复）

![screenshot](docs/screenshot.png)   <!-- 有界面才放；没有就删掉这一行，别留假链接 -->

## 功能
- 3-5 条，说能力不说技术

## 快速开始
（安装、最小可运行示例，命令必须是从本仓库真实跑通的）

## 使用
（主要用法，含一个完整可复制的例子）

## 配置
（环境变量表格：变量名 / 是否必填 / 说明 / 示例值。示例值必须是假值）

## 开发
（怎么跑测试、怎么提 PR）

## 许可证
MIT © 2026 <版权人>
```

三个常见错误：把 README 写成技术栈罗列；放一张不存在的截图链接；快速开始的命令抄自别处、在新克隆的仓库里跑不通。

### LICENSE

默认 MIT，`./assets/LICENSE-MIT.txt` 可直接取用，替换年份与版权人即可。

选择依据：

| 许可证 | 适用场景 | 注意 |
| --- | --- | --- |
| MIT | 工具、示例、教学项目；希望被最广泛使用 | 最宽松，不承担任何责任 |
| Apache-2.0 | 可能被企业采用的库 | 比 MIT 多一条明确的专利授权 |
| GPL-3.0 | 希望衍生作品也必须开源 | 商业使用会受限，谨慎选择 |
| 不设许可证 | —— | **等于保留全部权利**，别人无权使用。想让人用就必须选一个 |

许可证一旦发布就难以更改（已获得的授权不可撤回），所以生成前必须问用户，不要默认替他决定。

### .gitignore

从 `./assets/gitignore-templates/` 按语言取，但**任何模板都必须包含这几条**，它们的缺失才是真正的风险：

```gitignore
# 凭据与密钥
.env
.env.*
!.env.example
*.pem
*.key
*.p12
*.pfx
credentials.json
id_rsa
id_ed25519

# 依赖与构建产物
node_modules/
dist/
build/
__pycache__/
*.py[cod]

# IDE 与系统
.idea/
.vscode/
.DS_Store
Thumbs.db

# 扫描报告产物（本技能生成的报告不要入库）
report.json
report.md
```

`.env.example` 要**显式用 `!.env.example` 放行**，否则补了示例文件反而被忽略，别人不知道该配什么。

### .gitattributes

Windows 与 Linux 混用时没有这个文件，会导致整个仓库显示为"所有行都被修改"。最小可用版本：

```gitattributes
* text=auto eol=lf
*.ps1 text eol=crlf
*.bat text eol=crlf
*.cmd text eol=crlf

*.png binary
*.jpg binary
*.pdf binary
*.xlsx binary
*.docx binary
*.db binary
```

`eol=lf` 统一仓库内的换行符；PowerShell 与批处理脚本保留 CRLF，因为部分 Windows 环境对 LF 的 `.ps1` 处理异常。

## 协作文件

### CONTRIBUTING.md

贡献者实际需要知道的三件事：怎么把环境跑起来、怎么验证改动、提交规范。不要写"请遵守开源礼仪"这类正确的废话。

```markdown
## 开发环境
（克隆、安装依赖的具体命令）

## 提交前检查
（跑哪些测试、有没有 lint）

## 提交信息规范
（如 Conventional Commits：feat/fix/docs/refactor/test/chore）

## Pull Request
（说明改了什么、为什么、怎么验证；关联的 issue 编号）
```

### CODE_OF_CONDUCT.md

直接采用 [Contributor Covenant](https://www.contributor-covenant.org/) 2.1 版，它已是事实标准。**唯一需要改的是联系方式**——先确认用户愿意公开哪个邮箱，不要顺手填上他的私人邮箱。个人项目填 `GitHub Issues` 也是可接受的弱化方案。

### Issue 与 PR 模板

放在 `.github/` 下，YAML 格式的 issue 表单比 Markdown 模板更好用（能强制填写关键信息）：

```
.github/
├── ISSUE_TEMPLATE/
│   ├── bug_report.yml
│   └── feature_request.yml
└── PULL_REQUEST_TEMPLATE.md
```

bug 报告模板里最有价值的一个字段是**复现步骤**，其次是**环境信息**（版本、系统）。缺了这两项，issue 基本无法处理。

## CI

按语言从下表选模板，目标只有一个：**让陌生人相信这个仓库的代码是能跑的。**

| 语言 | 工作流 | 关键动作 |
| --- | --- | --- |
| Python | `setup-python` + pip | 多版本矩阵（3.10/3.11/3.12）、`ruff` 或 `flake8`、`pytest` |
| Node | `setup-node` + npm | `npm ci`、`npm run lint`、`npm test` |
| Java | `setup-java` + Maven/Gradle | `mvn -B verify` 或 `./gradlew build` |
| Go | `setup-go` | `go vet ./...`、`go test ./...` |
| Rust | `dtolnay/rust-toolchain` | `cargo clippy -- -D warnings`、`cargo test` |

两条硬性要求：

- **不要写死版本号**，用 `node-version: '20'` 或矩阵，避免半年后 CI 因版本下线而变红
- **绝不把任何密钥写进 workflow**，一律走 `${{ secrets.NAME }}`，并在 README 里说明需要配置哪些 secret

## CHANGELOG.md

采用 [Keep a Changelog](https://keepachangelog.com/) 结构，首条为 `Unreleased`：

```markdown
# Changelog

本项目遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

## [Unreleased]

## [1.0.0] - 2026-09-17
### Added
- 初始版本
```

## 仓库元信息

创建远端时一并设置，这些是别人在搜索结果里唯一能看到的信息：

```bash
gh repo create <name> --public --source . --remote origin --push \
  --description "一句话说明这个项目做什么"

gh repo edit \
  --add-topic python \
  --add-topic cli \
  --add-topic automation
```

- **description**：和 README 第一句一致即可，不要堆关键词
- **topics**：3-6 个，用社区通用词而非自造词，否则起不到被发现的作用
- **社交预览图**：Settings → Social preview 上传一张 1280×640 的图，分享到聊天工具时才会好看

## 一些考虑仓库用途时的判断

- 仓库名用 kebab-case，全小写，不要有空格与下划线
- 内部代号、客户名不要出现在仓库名与 description 里
- 如果项目只是自己用的脚本，公开的价值有限；这种时候更该确认用户的真实目的（备份？作品集？给别人用？），因为目的不同，要补的文件完全不同
