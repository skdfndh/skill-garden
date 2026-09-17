# 凭据类型、误报规避与历史处置

配套 `./Scanner.ps1` 的规则说明。第 5 步（历史处置）必读。

## 目录

- [扫描器的判定逻辑](#扫描器的判定逻辑)
- [已知的误报与漏报](#已知的误报与漏报)
- [掩码规则](#掩码规则)
- [git 历史处置](#git-历史处置)
- [验证是否真的清干净了](#验证是否真的清干净了)

## 扫描器的判定逻辑

三层，从确定到模糊：

**第一层：固定形态匹配。** 各大平台的密钥有可识别前缀，例如 `AKIA`（AWS）、`ghp_`/`github_pat_`（GitHub）、`sk-ant-`（Anthropic）、`xox[baprs]-`（Slack）、`AIza`（Google）、`glpat-`（GitLab）、`LTAI`（阿里云）、`AKID`（腾讯云）、`npm_`、`hf_`、`SG.`（SendGrid）。这类匹配几乎不会误报。

**第二层：上下文匹配。** 密钥本身没有固定形态时，靠赋值语句识别：`password = "..."`、`api_key: "..."`、`postgres://user:pass@host`。这一层的误报率明显更高，所以规则要求前缀带分隔符——`api_token` 会命中，裸的 `token` 不会（否则一个正常变量名就能触发一整页 P0）。

**第三层：香农熵兜底。** 长度 32 以上、字符分布足够随机（熵 ≥ 4.0）的字符串被标为疑似密钥。这一层专门用来抓自建系统的密钥，代价是误报最多，所以结果里一律标注"需人工确认"，并且已经剥掉整行注释、URL、十六进制哈希、UUID、纯数字和纯单词。

三层之外还有**文件名规则**：`.env`、`id_rsa`、`*.pem`、`credentials.json` 这类文件的存在本身就是风险信号，哪怕内容为空也要报——因为它意味着"这个项目里有凭据流转"，而凭据常常同时存在于别处。

## 已知的误报与漏报

判断扫描结果时心里要有这两张清单。

### 会误报的

| 现象 | 说明 | 处置 |
| --- | --- | --- |
| 测试夹具里的假密钥 | 单元测试常写 `api_key = "test_key_1234567890abcdef"` | 改名为明显的假值（含 `EXAMPLE`/`FAKE`），或移入 fixture 并在 `.gitignore` 中排除 |
| 文档中的示例 | README 里的 `sk-xxxx` 占位符 | 确认是占位符即可放行 |
| 低熵长的标识符 | 版本号拼接、base64 图片前缀 | 熵阈值已过滤大部分，剩余靠人工判断 |
| 哈希值 | commit hash、校验和 | 已排除纯十六进制串 |
| 官方示例凭据 | `AKIAIOSFODNN7EXAMPLE` 这类被文档用烂的值 | 降级为 P2 提示，见下 |

### 占位符过滤与"官方示例"的降级

扫描器有一套占位符过滤规则，避免报告被教程和测试里的假密钥淹没。**这套规则要求标记词落在片段边界上**，不做裸子串匹配——早期版本用 `example`、`abcdef`、`123456` 做子串匹配时，静默漏掉了 `AKIAIOSFODNN7EXAMPLE` 和 `npm_abc...0123456789` 这类真实凭据。漏报比误报危险得多，所以宁可让规则复杂一点。

排除的标记包括：`example`、`placeholder`、`fake`、`dummy`、`sample`、`changeme`、`redacted`、`todo`、`your_api_key` 形式的引导语、`test_key`/`test_token`、`<尖括号>` 占位。

`test_` 前缀**本身不算占位符**——测试环境凭据同样能访问真实数据，必须照报。

对于 `AKIAIOSFODNN7EXAMPLE` 这种官方文档用烂、但复制进代码就真实可用的值，扫描器做了折中：**报出来，但降级为 P2，不阻塞发布**。理由是这类值歧义太大——它可能只是教程引用，也可能是有人真把示例密钥写进了生产代码——只能由人确认来源。降级而不是静默忽略，是因为静默忽略正好漏掉了后一种情况。
| `localhost` 与 `127.0.0.1` | 不是内网信息 | 未纳入 private-ip 规则 |

### 会漏报的（这才是要警惕的）

- **被拆分或拼接的密钥**：`part1 = "sk-"; part2 = "..."` 这类写法任何正则都拼不出来
- **二进制与压缩文件**：`.xlsx`、`.docx`、`.db`、`.zip`、图片，扫描器直接跳过
- **非 UTF-8 编码的文本文件**：读不出内容就跳过，不会报警
- **超大文件**：超过 2MB 的文件被跳过
- **私有格式的密钥**：自研系统的 session、内部签发的长期令牌，没有可识别特征，熵值也不一定够高
- **业务数据**：价格表、客户名单、订单导出——这类"敏感"没有任何格式特征

**因此"扫描无 P0"绝不等于"可以公开"。** 必须回到 `./privacy-checklist.md` 逐项人工确认。

## 掩码规则

```powershell
长度 ≤ 8   →  "abc***"
长度 ≤ 16  →  "abcd***ef"
更长      →  "sk-abc…7f9c"
```

保留少量字符是为了让用户能对照自己的密钥管理系统认出"这是哪一个"，同时不足以复原。判定标准很简单：**看到掩码的人，不应该能比看到之前多知道任何有用的信息。**

同一条规则要应用到给用户的摘要里。说"3 个 AWS 密钥、1 个 Stripe 生产密钥"，不要把值贴出来。

## git 历史处置

### 先判断，别急着重写

```bash
# 这个值进过历史吗？
git log -S "<值>" --oneline

# 推过远端吗？
git remote -v
git log origin/$(git branch --show-current) --oneline 2>/dev/null | head -3
```

三种结论对应三种做法：

| 情况 | 做法 |
| --- | --- |
| 从未提交过（还在工作区） | 最简单，删掉文件、加 `.gitignore` 即可，无历史包袱 |
| 提交过但从未推送 | 可以放心重写历史，没有协作者受影响 |
| 已推送到远端 | 先轮换密钥；重写历史需用户明确同意，并告知协作者影响 |

### 顺序不能反

**轮换密钥优先于一切清理动作。** 一个已推送的密钥，在你重写历史的同时就已经被 git 抓取服务收录了。清理历史只是减少继续暴露的面积，轮换才是真正让旧密钥失效的手段。反过来做（先清理再轮换）会有一段"历史看着很干净、但密钥仍然有效"的危险窗口。

### 重写历史：git filter-repo

`git filter-repo` 不是 git 自带命令，需要单独安装：

```bash
pip install git-filter-repo          # 需要 Python
brew install git-filter-repo         # macOS
scoop install git-filter-repo        # Windows
```

用之前**先备份**，它会直接改写仓库：

```bash
git clone --mirror <repo-url> repo-backup.git    # 或者直接复制整个目录
```

删除某个文件的所有历史：

```bash
git filter-repo --invert-paths --path config/.env --path src/keys.json
```

替换历史中的具体文本（把 `replacements.txt` 写成 `旧值==>新值` 形式，`regex:` 前缀可启用正则）：

```bash
git filter-repo --replace-text replacements.txt
```

完成后需要重新关联远端（filter-repo 会移除 origin 以防误推）并强制推送：

```bash
git remote add origin <repo-url>
git push origin --force --all
git push origin --force --tags
```

### 重写历史的真实代价

必须提前告诉用户，不能只报喜：

- 所有协作者必须重新克隆；他们本地的旧历史再推送会把敏感内容带回来
- 已有的 fork、PR 会指向失效的提交，GitHub 上会显示为异常状态
- 已创建的 release 与 tag 需要重新处理
- GitHub 端可能仍缓存旧提交对象一段时间；对真正敏感的密钥，唯一可靠的做法是**当作已泄露并轮换**

### 更轻的替代方案

如果只是为了"公开历史好看"而不是"清除泄露"，别用重写：

- 用 `git commit --amend` 修掉最近一条的作者信息或误提交（仅限未推送）
- 面对已推送的仓库，接受历史现状，把清理动作放在当前提交
- 需要重建干净历史时，`git checkout --orphan` 开一条全新分支，把干净的工作树作为首个提交——旧历史保留在本地，公开的是新分支

## 验证是否真的清干净了

清理之后按顺序验证，缺一步都可能留下残留：

```bash
# 1. 工作区还有没有
pwsh -File ./Scanner.ps1 -Path . -Mode secrets

# 2. 暂存区与索引里还有没有（git rm --cached 之后尤其要查）
git grep -n -I -E "(AKIA|ghp_|sk-ant-|BEGIN .*PRIVATE KEY)" -- .

# 3. 整个历史里还有没有
git log -S "<被清理的值>" --oneline
git rev-list --all --objects | git cat-file --batch-check | head

# 4. 已被跟踪的文件清单里还有没有敏感载体
git ls-files | grep -E "\.(env|pem|key|p12)$|id_rsa|credentials"
```

第 2 步最容易被忽略：文件从工作区删掉了，但索引里还在，下一次提交就把它带回来了。
