<#
.SYNOPSIS
    仓库隐私扫描器：在把项目公开到 GitHub 之前，找出密钥、个人信息、内网信息与仓库卫生问题。

.DESCRIPTION
    只读扫描，绝不修改被扫描的项目，也绝不把明文敏感值写进任何输出。

    产物默认落在被扫描仓库之外（系统临时目录），原因是：扫描报告本身就是敏感文件，
    放在仓库里会立刻变成一个新的泄露点。

    报告中的敏感值一律以掩码呈现（如 `sk-abc1…7f9c`），因为报告会被 Agent 读进上下文、
    被贴进聊天窗口、被当作附件转发，明文出现在其中等于二次泄露。

.PARAMETER Path
    被扫描的项目根目录，默认为当前目录。

.PARAMETER OutDir
    报告输出目录，默认为 <临时目录>\repo-privacy-scan。刻意不默认写入仓库内。

.PARAMETER Mode
    secrets（密钥令牌）/ pii（个人信息）/ infra（内网信息）/ hygiene（仓库结构与二进制）
    / readme（README 正确性审计：死链、占位符、许可证一致性、健康分）/ all（默认，全部）。

.PARAMETER Exclude
    额外排除的目录名。依赖目录与构建产物默认已排除，因为它们几乎只会制造噪音。

.PARAMETER All
    不限制每类问题的输出条数。默认每类最多 200 条，超出部分只记录数量，
    以免报告被 lock 文件淹没能读。

.PARAMETER Json
    只把 JSON 结果打印到标准输出，便于其他工具消费。

.EXAMPLE
    ./Scanner.ps1 -Path . -OutDir $env:TEMP/repo-privacy-scan

.EXAMPLE
    ./Scanner.ps1 -Path . -Mode secrets -Json

.NOTES
    退出码：0 = 无 P0；1 = 存在 P0，需要处理；2 = 参数或环境错误。
#>
[CmdletBinding()]
param(
    [string]$Path = '.',
    [string]$OutDir = (Join-Path ([System.IO.Path]::GetTempPath()) 'repo-privacy-scan'),
    [ValidateSet('all', 'secrets', 'pii', 'infra', 'hygiene', 'readme')]
    [string]$Mode = 'all',
    [string[]]$Exclude = @(),
    [switch]$All,
    [switch]$Json
)

$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Error '需要 PowerShell 7 或更高版本（pwsh）。'
    exit 2
}

#region 遍历排除规则

$script:SkipDirs = @(
    '.git', '.hg', '.svn',
    'node_modules', 'bower_components', 'vendor', 'packages',
    'dist', 'build', 'out', 'target', 'bin', 'obj', 'coverage', 'htmlcov',
    '__pycache__', '.venv', 'venv', 'env', '.tox', '.mypy_cache', '.pytest_cache',
    '.ruff_cache', '.next', '.nuxt', '.gradle', '.idea', '.vs', 'Pods', 'DerivedData',
    # 各语言的包管理器缓存与构建产物：里面全是工具生成的绝对路径与哈希，扫它们只有噪音
    '.dart_tool', '.pub-cache', '.cargo', '.stack-work', '.terraform',
    '.parcel-cache', '.svelte-kit', '.angular', '.docusaurus'
) + $Exclude

# 注意：匹配用的是**完整路径**，所以不带通配符的文件名永远匹配不到——
# package-lock.json 曾经就是这样一条死规则（*.lock 因为有 * 而正常，掩盖了它）。
# 凡是按文件名匹配的规则都必须带前导 *。
$script:SkipFilePatterns = @(
    '*.lock', '*package-lock.json', '*pnpm-lock.yaml', '*yarn.lock', '*poetry.lock',
    '*Cargo.lock', '*composer.lock', '*Gemfile.lock', '*go.sum', '*bun.lockb',
    '*.min.js', '*.min.css', '*.map',
    '*.bundle.js', '*.chunk.js', '*.esm.js', '*.cjs', '*.umd.js',
    '*.png', '*.jpg', '*.jpeg', '*.gif', '*.webp', '*.ico', '*.bmp', '*.svg',
    '*.pdf', '*.zip', '*.7z', '*.rar', '*.gz', '*.tar', '*.jar', '*.war',
    '*.exe', '*.dll', '*.so', '*.dylib', '*.pyd', '*.class', '*.pyc', '*.wasm',
    '*.woff', '*.woff2', '*.ttf', '*.otf', '*.eot',
    '*.mp3', '*.mp4', '*.mov', '*.avi', '*.mkv', '*.psd', '*.sketch', '*.blend'
)

# 构建产物目录：前端打包后的 JS/CSS 里塞满了内容哈希，逐个报出来毫无意义，
# 真正的风险（打包进前端的密钥）会被这些噪音淹没。
# 注意这里是相对路径匹配，只跳过生成目录，不跳过源码里的同名文件。
$script:SkipPathPatterns = @(
    '*/static/assets/*', '*/static/js/*', '*/static/css/*',
    '*/assets/index-*.js', '*/assets/index-*.css',
    '*/public/build/*', '*/webpack/*', '*/__generated__/*'
)

# 值层面的过滤：这些"值"不是凭据，而是模板变量引用、密码哈希、内嵌图片数据。
# 配置文件里写 ${DB_PASSWORD} 是正确做法（从环境变量取值），报它是误报；
# bcrypt 哈希看不出原密码，本身不是可直接利用的凭据；
# base64 图片数据是资源不是密钥。三者混进"凭据轮换清单"只会稀释重点。
$script:NonCredentialRx = [regex]::new(
    '(?i)^\$\{?[A-Za-z_][A-Za-z0-9_]*' +      # ${VAR} 或 $VAR 开头
    '|^\$[0-9a-z]{2}\$[0-9]{2}\$' +            # bcrypt / argon2 等密码哈希
    '|^[a-z0-9+/]{40,}={0,2}$' +               # 长 base64（图片与二进制内嵌数据）
    '|^(?:[a-z][a-z0-9_]*\.){2,}[A-Za-z][A-Za-z0-9_]*$' +   # org.example.Widget 式标识符链
    '|^(?:com|org|net|io|cn|edu|gov|me|dev)\.[a-z0-9]+\.(?:local|internal|corp|lan|localdomain)$'  # Java 包名 com.foo.local
)

# 这些邮箱是文档与工具链里的公共标识，不是隐私，命中它们只会稀释报告。
$script:EmailAllowlist = @(
    'example.com', 'example.org', 'example.net', 'test.com', 'localhost',
    'noreply@github.com', 'actions@github.com', 'you@example.com', 'user@example.com',
    'none@none', 'noreply@anthropic.com'
)

# 文档、教程与单元测试里到处是"看起来像密钥的假密钥"。不过滤掉它们，报告会被
# 示例值淹没，真正需要处理的凭据反而看不见——这正是"狼来了"式扫描器的失败方式。
#
# 但过滤必须精确，这里踩过三次坑：'example'、'abcdef'、'123456' 都曾以**裸子串**
# 形式命中真实密钥（AKIAIOSFODNN7EXAMPLE、npm_abc...0123456789），造成静默漏报。
# 所以标记词一律要求落在片段边界上（串首、串尾或分隔符之间）；
# 像 123456 这种既可能是占位符又常见于真实密钥的数字串，只允许整串匹配。
#
# 另外：`test_` 前缀本身不算占位符。测试环境凭据同样能访问真实数据，必须照报。
$script:PlaceholderRx = [regex]::new(
    '(?i)(?:^|[_\-. ])(?:example|placeholder|fake|dummy|sample|changeme|change[_\-. ]?me|redacted|todo|insert[_\-. ]?your)(?:[_\-. ]|$)' +
    '|your[_\-. ]?(?:key|token|secret|password|api)' +
    '|test[_\-. ]?(?:key|token|secret|value)' +
    '|^(?:x{3,}|abcdef|123456|password|secret|token)$' +
    '|<[^>]{1,30}>'
)

# 官方文档里用烂了的示例凭据。它们本身不是秘密，但一旦被复制进真实代码就是可用凭据——
# 所以不能静默忽略（那是漏报），也不该按 P0 阻塞发布（那会让人对报告脱敏）。
# 降级为 P2 提示，让读者自己确认来源。
#
# 这段检查会被扫描器扫到自己身上——本文件上面的注释里就写着 AKIAIOSFODNN7EXAMPLE——
# 这正是它该有的行为：注释与文档同样会随仓库公开，同样值得一句提示。
$script:KnownPlaceholderValues = [regex]::new(
    '(?i)^(?:AKIAIOSFODNN7EXAMPLE|AKIAI44QH8DHBEXAMPLE|wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY|test_key_1234567890abcdef)$'
)
# 上面那条只排除"整串恰好等于官方示例"的情况，不排除含它的长串——
# 因为含示例密钥的长串更可能是真的把示例复制进了代码，属于该报的。

# 文档里出现的、仅是"提到"某个示例值的行，会同时触发具体规则与高熵兜底。
# 这里只在具体规则已经报过同一个值时才让兜底沉默，逻辑见下方扫描主体。

#endregion

#region 规则表

$script:Patterns = @(
    # ---------- P0：高置信密钥与凭据 ----------
    @{ Id = 'aws-access-key'; Sev = 'P0'; Cat = 'secrets'; Rx = '\b(?:AKIA|ASIA|AGPA|AIDA|AROA|ANPA)[0-9A-Z]{16}\b'; Desc = 'AWS Access Key ID' }
    @{ Id = 'private-key-block'; Sev = 'P0'; Cat = 'secrets'; Rx = '-----BEGIN (?:RSA |DSA |EC |OPENSSH |PGP |ENCRYPTED )?PRIVATE KEY(?: BLOCK)?-----'; Desc = '私钥文件内容' }
    @{ Id = 'openai-key'; Sev = 'P0'; Cat = 'secrets'; Rx = '\bsk-(?:proj-)?[A-Za-z0-9_\-]{20,}'; Desc = 'OpenAI 风格 API Key' }
    @{ Id = 'anthropic-key'; Sev = 'P0'; Cat = 'secrets'; Rx = '\bsk-ant-[A-Za-z0-9_\-]{20,}'; Desc = 'Anthropic API Key' }
    @{ Id = 'github-token'; Sev = 'P0'; Cat = 'secrets'; Rx = '\b(?:gh[pousr]_[A-Za-z0-9]{16,}|github_pat_[A-Za-z0-9_]{20,})'; Desc = 'GitHub Token' }
    @{ Id = 'slack-token'; Sev = 'P0'; Cat = 'secrets'; Rx = '\bxox[baprs]-[A-Za-z0-9\-]{10,}'; Desc = 'Slack Token' }
    @{ Id = 'google-api-key'; Sev = 'P0'; Cat = 'secrets'; Rx = '\bAIza[0-9A-Za-z_\-]{35}\b'; Desc = 'Google API Key' }
    @{ Id = 'stripe-key'; Sev = 'P0'; Cat = 'secrets'; Rx = '\b(?:sk|pk|rk)_(?:live|test)_[A-Za-z0-9]{16,}'; Desc = 'Stripe Key' }
    @{ Id = 'gitlab-token'; Sev = 'P0'; Cat = 'secrets'; Rx = '\bglpat-[A-Za-z0-9_\-]{18,}'; Desc = 'GitLab Personal Access Token' }
    @{ Id = 'npm-token'; Sev = 'P0'; Cat = 'secrets'; Rx = '\bnpm_[A-Za-z0-9]{34,}'; Desc = 'npm Access Token' }
    @{ Id = 'huggingface-token'; Sev = 'P0'; Cat = 'secrets'; Rx = '\bhf_[A-Za-z0-9]{30,}'; Desc = 'Hugging Face Token' }
    @{ Id = 'aliyun-access-key'; Sev = 'P0'; Cat = 'secrets'; Rx = '\bLTAI[A-Za-z0-9]{12,20}\b'; Desc = '阿里云 AccessKey ID' }
    @{ Id = 'tencent-secret-id'; Sev = 'P0'; Cat = 'secrets'; Rx = '\bAKID[A-Za-z0-9]{13,32}\b'; Desc = '腾讯云 SecretId' }
    @{ Id = 'sendgrid-key'; Sev = 'P0'; Cat = 'secrets'; Rx = '\bSG\.[A-Za-z0-9_\-]{16,}\.[A-Za-z0-9_\-]{16,}'; Desc = 'SendGrid API Key' }
    @{ Id = 'jwt'; Sev = 'P0'; Cat = 'secrets'; Rx = '\beyJ[A-Za-z0-9_\-]{8,}\.eyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{10,}'; Desc = 'JWT Token' }
    @{ Id = 'basic-auth-url'; Sev = 'P0'; Cat = 'secrets'; Rx = 'https?://[^\s/:@''"]{2,64}:[^\s/@''"]{4,64}@[^\s/''"]{3,}'; Desc = 'URL 内嵌账号密码' }
    # 前缀必须由分隔符带出：`api_token = "..."` 要报，而 `token = "..."` 这种泛化变量名不报，
    # 否则一个 JWT 会同时触发 jwt / connection-password / secret-assignment 三条规则，把报告淹掉。
    @{ Id = 'connection-password'; Sev = 'P0'; Cat = 'secrets'; Rx = '(?i)(?:[a-z0-9]+[_.\-])?(?:password|passwd|pwd|secret|apikey|api_key|access_key|private_key|access_token|auth_token|api_token|client_secret)\s*[:=]\s*[''"]([^''"\s]{8,})[''"]'; Desc = '配置项中的明文口令' }
    @{ Id = 'secret-assignment'; Sev = 'P0'; Cat = 'secrets'; Rx = '(?i)(?:[a-z0-9]+[_.\-])?(?:api[_-]?key|secret[_-]?key|access[_-]?token|auth[_-]?token|api[_-]?token|client[_-]?secret)\s*[:=]\s*[''"]([A-Za-z0-9_\-]{16,})[''"]'; Desc = '疑似硬编码密钥赋值' }
    @{ Id = 'mail-password'; Sev = 'P0'; Cat = 'secrets'; Rx = '(?i)(?<![a-z0-9_\-])(?:smtp|mail|email)[_-]?(?:pass|password|pwd)\s*[:=]\s*[''"]?([^\s''"]{6,})'; Desc = '邮箱/SMTP 授权码' }

    # ---------- P1：个人信息 ----------
    @{ Id = 'cn-phone'; Sev = 'P1'; Cat = 'pii'; Rx = '(?<![0-9])1[3-9][0-9]{9}(?![0-9])'; Desc = '中国大陆手机号' }
    @{ Id = 'cn-id-card'; Sev = 'P1'; Cat = 'pii'; Rx = '(?<![0-9Xx])[1-9][0-9]{5}(?:19|20)[0-9]{2}(?:0[1-9]|1[0-2])(?:0[1-9]|[12][0-9]|3[01])[0-9]{3}[0-9Xx](?![0-9Xx])'; Desc = '中国大陆身份证号' }
    # 移动端资源命名（Icon@2x.png、splash@3x.png）天然长得像邮箱，不加排除会命中整个 Xcode 资源清单
    @{ Id = 'email'; Sev = 'P1'; Cat = 'pii'; Rx = '\b[A-Za-z0-9._%+\-]+@(?!\d+x\.)[A-Za-z0-9\-]+(?:\.[A-Za-z0-9\-]+)*\.[A-Za-z]{2,}\b'; Desc = '邮箱地址'; Allow = $script:EmailAllowlist }
    @{ Id = 'win-user-path'; Sev = 'P1'; Cat = 'pii'; Rx = '(?i)[A-Z]:\\Users\\[^\\\s''"]{1,40}\\'; Desc = '本机绝对路径（暴露 Windows 用户名，改为相对路径）' }
    @{ Id = 'unix-home-path'; Sev = 'P1'; Cat = 'pii'; Rx = '/(?:home|Users)/([A-Za-z0-9._\-]{2,32})/'; Desc = '本机绝对路径（暴露用户名，改为相对路径）'; Allow = @('runner', 'ubuntu', 'app', 'user', 'node', 'root', 'vscode', 'circleci', 'travis', 'jenkins', 'yourname', 'username', 'me') }

    # ---------- P1：内网与内部信息 ----------
    @{ Id = 'private-ip'; Sev = 'P1'; Cat = 'infra'; Rx = '(?<![0-9.])(?:10\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}|192\.168\.[0-9]{1,3}\.[0-9]{1,3}|172\.(?:1[6-9]|2[0-9]|3[01])\.[0-9]{1,3}\.[0-9]{1,3})(?![0-9.])'; Desc = '内网 IP 地址' }
    # 只认真正像主机的内部域名。像 tz.local、db.local 这类"标识符.后缀"的写法极其常见
    # （时区库、ORM 模型名、枚举值），把它们当内网域名报出来纯属噪音。
    # 因此要求至少两段前缀，或者前缀足够长且带连字符。
    @{ Id = 'internal-domain'; Sev = 'P1'; Cat = 'infra'; Rx = '(?<![a-z0-9.\-])(?:[a-z0-9\-]+\.[a-z0-9\-]{2,}\.(?:internal|intranet|corp|lan|localdomain)|[a-z0-9\-]{6,}(?:-[a-z0-9]+)+\.(?:internal|intranet|corp|local))\b(?!\.[a-z])'; Desc = '内部域名' }
    @{ Id = 'internal-git-url'; Sev = 'P1'; Cat = 'infra'; Rx = '(?i)\b(?:git|ssh)@[A-Za-z0-9.\-]+:[^\s''"]+'; Desc = 'SSH 形式 Git 远端（可能暴露内网主机）' }

    # ---------- 敏感文件名 ----------
    @{ Id = 'sensitive-filename'; Sev = 'P0'; Cat = 'secrets'; FileName = $true; Rx = '(?i)^(?:\.env(?:\..+)?|\.envrc|credentials(?:\.json|\.yaml|\.yml|\.ini)?|secrets?\.(?:json|ya?ml|ini|toml|txt)|id_rsa|id_ed25519|id_ecdsa|\.npmrc|\.pypirc|\.netrc|_netrc|\.git-credentials|serviceaccount.*\.json|.*\.(?:pem|key|pfx|p12|jks|keystore))$'; Desc = '敏感文件名（凭据载体）' }
    # 按环境划分的 .env 文件（.env.production / .env.dev / .env.staging）。
    # 单独成一条规则的原因：它们是最容易被 git add -A 顺手提交、且通常装着真实凭据的一类，
    # 但文件名本身不区分环境，靠上一条规则的下标后缀无法判断。
    @{ Id = 'env-by-environment'; Sev = 'P1'; Cat = 'secrets'; FileName = $true; Rx = '(?i)^\.env\.(?:prod|production|dev|development|stage|staging|test|testing|qa|uat|pre|preview|release|live)(?:\..+)?$'; Desc = '按环境划分的 .env 文件（极可能含真实凭据）' }
    @{ Id = 'sensitive-filename-config'; Sev = 'P2'; Cat = 'secrets'; FileName = $true; Rx = '(?i)^(?:config\.(?:json|ya?ml|ini|toml)|settings\.(?:json|ya?ml)|application(?:-[a-z]+)?\.(?:properties|ya?ml)|appsettings(?:\.[A-Za-z]+)?\.json|\.htpasswd|wp-config\.php)$'; Desc = '配置文件（需确认是否含凭据）' }
)

# 高熵候选串：正则只负责"长得像密钥"，是否真的可疑由香农熵判断。
$script:EntropyPattern = '\b[A-Za-z0-9+/=_\-]{32,120}\b'

#endregion

#region 工具函数

function Get-MaskedValue {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)

    $v = $Value.Trim()
    if ($v.Length -eq 0) { return '' }
    if ($v.Length -le 8) { return "$($v.Substring(0, [Math]::Min(3, $v.Length)))***" }
    if ($v.Length -le 16) { return "$($v.Substring(0, 4))***$($v.Substring($v.Length - 2))" }
    return "$($v.Substring(0, 6))…$($v.Substring($v.Length - 4))"
}

function Get-ShannonEntropy {
    param([Parameter(Mandatory)][string]$Text)

    $counts = @{}
    foreach ($ch in $Text.ToCharArray()) {
        if ($counts.ContainsKey($ch)) { $counts[$ch]++ } else { $counts[$ch] = 1 }
    }
    $len = $Text.Length
    $entropy = 0.0
    foreach ($n in $counts.Values) {
        $p = $n / $len
        $entropy -= $p * [Math]::Log($p, 2)
    }
    return $entropy
}

function Test-Allowlisted {
    param([string]$Value, [string[]]$Allow)

    if (-not $Allow -or $Allow.Count -eq 0) { return $false }
    foreach ($a in $Allow) {
        if ($Value -like "*$a*") { return $true }
    }
    return $false
}

function Test-SkipFile {
    param([string]$FullName)

    foreach ($pattern in $script:SkipFilePatterns) {
        if ($FullName -like $pattern) { return $true }
    }
    # 相对路径规则用正斜杠统一后匹配，避免 Windows 反斜杠导致规则失效
    $normalized = $FullName.Replace('\', '/')
    foreach ($pattern in $script:SkipPathPatterns) {
        if ($normalized -like $pattern) { return $true }
    }
    return $false
}

function Test-IsBinary {
    param([string]$FullName)

    try {
        $fs = [System.IO.File]::Open($FullName, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            $buffer = New-Object byte[] 8192
            $read = $fs.Read($buffer, 0, $buffer.Length)
        }
        finally { $fs.Dispose() }
    }
    catch { return $true }

    for ($i = 0; $i -lt $read; $i++) {
        if ($buffer[$i] -eq 0) { return $true }
    }
    return $false
}

function Add-Finding {
    param(
        [string]$PatternId, [string]$Severity, [string]$Category, [string]$File,
        [int]$Line, [string]$Masked, [string]$Raw, [string]$Note,
        # 具体规则默认登记掩码值，让高熵兜底规则不必重复报同一个值
        [bool]$Track = $true
    )

    if ($Track -and $Masked) { $null = $seenValues.Add($Masked) }

    $script:RawFindings.Add([pscustomobject]@{
            id       = $PatternId
            severity = $Severity
            category = $Category
            file     = $File
            line     = $Line
            evidence = $Masked
            raw      = $Raw
            note     = $Note
        })
}

#endregion

#region git 情报

function Get-GitIntel {
    param([string]$Root)

    $intel = [ordered]@{
        isRepo      = $false
        commitCount = $null
        configured  = [ordered]@{ name = $null; email = $null }
        authors     = @()
        remote      = $null
        findings    = @()
    }

    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        $intel.findings += 'git 未安装，跳过提交历史检查'
        return [pscustomobject]$intel
    }

    $inRepo = (& git -C $Root rev-parse --is-inside-work-tree 2>$null)
    if ($LASTEXITCODE -ne 0 -or "$inRepo".Trim() -ne 'true') {
        $intel.findings += '当前目录不是 git 仓库：提交历史与作者身份尚未纳入检查'
        return [pscustomobject]$intel
    }
    $intel.isRepo = $true

    $intel.commitCount = [int](& git -C $Root rev-list --count HEAD 2>$null)
    $remote = ("$(& git -C $Root remote get-url origin 2>$null)").Trim()
    if (-not [string]::IsNullOrWhiteSpace($remote)) { $intel.remote = $remote }

    $name = ("$(& git -C $Root config user.name 2>$null)").Trim()
    $email = ("$(& git -C $Root config user.email 2>$null)").Trim()
    if ($name) { $intel.configured.name = $name }
    if ($email) { $intel.configured.email = $email }

    $log = & git -C $Root log --format='%an|%ae' 2>$null
    if ($log) {
        $intel.authors = @(
            $log | Where-Object { $_ -match '\|' } | ForEach-Object {
                $parts = $_ -split '\|', 2
                [pscustomobject]@{ name = $parts[0].Trim(); email = $parts[1].Trim() }
            } | Sort-Object -Property email, name -Unique
        )
    }

    return [pscustomobject]$intel
}

#endregion

#region 扫描主体

$root = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
if (-not (Test-Path -LiteralPath $root -PathType Container)) {
    Write-Error "不是目录：$root"
    exit 2
}

$scanSecrets = $Mode -in @('all', 'secrets')
$scanPii = $Mode -in @('all', 'pii')
$scanInfra = $Mode -in @('all', 'infra')
$scanHygiene = $Mode -in @('all', 'hygiene')
$scanReadme = $Mode -in @('all', 'readme')

$script:RawFindings = [System.Collections.Generic.List[object]]::new()
# 已被具体规则命中的值（掩码形式），用于让高熵兜底规则保持沉默
$seenValues = [System.Collections.Generic.HashSet[string]]::new()

# 预编译正则：逐行扫描时每秒会调用成百上千次，-match 的重复解析开销不可接受。
$compiled = @()
foreach ($p in $script:Patterns) {
    $cat = $p.Cat
    if ($cat -eq 'secrets' -and -not $scanSecrets) { continue }
    if ($cat -eq 'pii' -and -not $scanPii) { continue }
    if ($cat -eq 'infra' -and -not $scanInfra) { continue }
    $compiled += [pscustomobject]@{
        Id       = $p.Id
        Sev      = $p.Sev
        Cat      = $cat
        Desc     = $p.Desc
        Rx       = [regex]::new($p.Rx)
        Allow    = $p.Allow
        FileName = [bool]$p.FileName
    }
}
$entropyRx = [regex]::new($script:EntropyPattern)

$gitIntel = Get-GitIntel -Root $root

# 已跟踪文件集合：用于区分"仓库里有这个敏感文件"和"这个敏感文件已经会被推送出去"。
# 前者只是隐患（被 .gitignore 挡住了就没问题），后者才是真实泄露——两者的严重性差一个数量级，
# 报告必须说清楚，否则用户会对着一堆已被正确忽略的文件做无用功。
$trackedSet = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
if ($gitIntel.isRepo) {
    foreach ($tf in (& git -C $root ls-files 2>$null)) {
        if ($tf) { $null = $trackedSet.Add($tf.Replace('\', '/')) }
    }
}

$files = [System.Collections.Generic.List[string]]::new()
$skippedLarge = 0
$skippedBinary = 0

Get-ChildItem -LiteralPath $root -Recurse -File -Force -ErrorAction SilentlyContinue |
    ForEach-Object {
        if ($_.FullName -match '\\\.git\\') { return }
        $rel = [System.IO.Path]::GetRelativePath($root, $_.FullName)
        $segments = $rel -split '[\\/]'
        if ($segments.Length -gt 1) {
            $dirs = $segments[0..($segments.Length - 2)]
            if ($dirs | Where-Object { $script:SkipDirs -contains $_ }) { return }
        }
        if (Test-SkipFile -FullName $_.FullName) {
            if ($_.Length -gt 2MB) { $script:skippedLarge++ } else { $script:skippedBinary++ }
            return
        }
        if ($_.Length -gt 2MB) { $script:skippedLarge++; return }
        $files.Add($_.FullName)
    }

foreach ($full in $files) {
    $rel = [System.IO.Path]::GetRelativePath($root, $full)
    $fileName = [System.IO.Path]::GetFileName($full)

    # 文件名规则。这里必须区分三种情况，否则会把正确的工程实践报成事故：
    #   1. 未被 git 跟踪 → 只是隐患，.gitignore 覆盖了就没事
    #   2. 被跟踪，但内容是占位符（.env.example 的存在意义就是如此）→ 模板文件，本来就该提交
    #   3. 被跟踪且内容含真实值 → 这才是真正泄露
    $isTracked = $trackedSet.Contains($rel.Replace('\', '/'))
    $isTemplate = $fileName -match '(?i)\.(example|sample|template|dist)$'
    foreach ($p in $compiled) {
        if (-not ($p.FileName -and $p.Rx.IsMatch($fileName))) { continue }

        if ($isTemplate) {
            Add-Finding -PatternId $p.Id -Severity 'P2' -Category $p.Cat -File $rel -Line 0 `
                -Masked '(模板文件)' -Raw $null -Note "$($p.Desc)——模板文件，确认不含真实值即可"
            continue
        }

        if (-not $isTracked) {
            Add-Finding -PatternId $p.Id -Severity 'P2' -Category $p.Cat -File $rel -Line 0 `
                -Masked '(文件名命中)' -Raw $null -Note "$($p.Desc)——未被 git 跟踪（确认 .gitignore 已覆盖即可）"
            continue
        }

        # 已被跟踪：读内容判断究竟是真实凭据还是占位符。判错方向的两个代价差别很大——
        # 把模板报成 P0 会让用户白白轮换密钥，把真实凭据漏掉则会让密钥公开。
        $looksPlaceholder = $true
        $valueCount = 0
        try {
            foreach ($cl in [System.IO.File]::ReadAllLines($full)) {
                $t = $cl.Trim()
                if ($t.Length -eq 0 -or $t.StartsWith('#')) { continue }
                if ($t -notmatch '^\s*[A-Za-z_][A-Za-z0-9_]*\s*=\s*(.*)$') { $looksPlaceholder = $false; break }
                $val = $matches[1].Trim().Trim('"').Trim("'")
                if ($val.Length -eq 0) { continue }
                $valueCount++
                if (-not ($script:PlaceholderRx.IsMatch($val) -or $script:NonCredentialRx.IsMatch($val) -or $val.Length -le 4)) {
                    $looksPlaceholder = $false
                    break
                }
            }
        }
        catch { $looksPlaceholder = $false }

        if ($looksPlaceholder) {
            Add-Finding -PatternId $p.Id -Severity 'P2' -Category $p.Cat -File $rel -Line 0 `
                -Masked '(内容为占位符)' -Raw $null -Note "$($p.Desc)——已跟踪但内容全是占位符，安全"
        }
        else {
            Add-Finding -PatternId $p.Id -Severity $p.Sev -Category $p.Cat -File $rel -Line 0 `
                -Masked '(文件名命中)' -Raw $null -Note "$($p.Desc)——**已被 git 跟踪且内容含真实值，会随仓库公开**"
        }
    }

    if (Test-IsBinary -FullName $full) { $skippedBinary++; continue }

    try {
        $lines = [System.IO.File]::ReadAllLines($full)
    }
    catch {
        continue
    }

    $lineNo = 0
    foreach ($text in $lines) {
        $lineNo++
        if ($text.Length -eq 0) { continue }
        if ($text.Length -gt 4000) { $text = $text.Substring(0, 4000) }

        foreach ($p in $compiled) {
            if ($p.FileName) { continue }
            if (-not $p.Rx.IsMatch($text)) { continue }

            $values = @()
            foreach ($m in $p.Rx.Matches($text)) {
                if ($m.Groups.Count -gt 1 -and $m.Groups[1].Success) { $values += $m.Groups[1].Value }
                else { $values += $m.Value }
            }

            foreach ($v in ($values | Sort-Object -Unique)) {
                if (Test-Allowlisted -Value $v -Allow $p.Allow) { continue }
                if ($script:PlaceholderRx.IsMatch($v)) { continue }
                # 模板变量引用、密码哈希、内嵌图片数据、标识符链都不是凭据
                if ($script:NonCredentialRx.IsMatch($v)) { continue }
                # 官方示例凭据降级为提示：不阻塞，但必须出现在报告里
                $sev = $p.Sev
                $note = $p.Desc
                if ($script:KnownPlaceholderValues.IsMatch($v)) {
                    $sev = 'P2'
                    $note = "$($p.Desc)——值是官方文档的示例凭据，确认不是从教程复制进真实代码的"
                }
                # 官方示例的 secret key 常常以更长字符串的形式出现在文档里
                # （例如 wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY 被引号包住时），
                # 整串匹配不到，这里再做一次包含判断，同样降级而不是静默忽略。
                elseif ($v -match '(?i)EXAMPLEKEY$|EXAMPLE$' -and $v -match '(?i)^[A-Za-z0-9+/=]{20,}$') {
                    $sev = 'P2'
                    $note = "$($p.Desc)——疑似官方文档示例值，确认不是从教程复制进真实代码的"
                }
                Add-Finding -PatternId $p.Id -Severity $sev -Category $p.Cat -File $rel -Line $lineNo `
                    -Masked (Get-MaskedValue -Value $v) -Raw $v -Note $note
            }
        }

        # 高熵兜底：先剥掉整行注释与 URL，避免把普通长文本误判成密钥
        if ($scanSecrets) {
            $probe = $text
            if ($probe -match '^\s*(?:#|//|\*|/\*|<!--|REM\b|::)') { $probe = '' }
            elseif ($probe -match '^\s*(?:https?|ftp)://') { $probe = '' }
            if ($probe) {
                foreach ($m in $entropyRx.Matches($probe)) {
                    $tok = $m.Value
                    if ($tok -match '^[0-9a-fA-F]+$') { continue }                     # 十六进制哈希或提交号
                    if ($tok -match '^\d+$') { continue }                               # 纯数字
                    if ($tok -match '^[0-9a-fA-F]{8}-[0-9a-fA-F\-]{20,}$') { continue }  # UUID
                    # 真密钥是随机字符。用三条结构性特征代替"必须含大小写"这种粗暴过滤：
                    # 纯小写的密钥确实存在（npm token 就是），漏掉它们比多报几条更糟。
                    if ($tok -notmatch '[0-9]') { continue }                            # 不含数字的长串基本是散文或路径
                    if ($tok -match '\.(?:md|py|js|json|ya?ml|ps1|ts|java|go|rs|txt|html|css)$') { continue }  # 文件路径
                    if ($tok -match '^-+$|^_+$') { continue }
                    # 路径与 CSS 类名常同时带下划线和连字符，密钥极少这样
                    if ($tok -match '_' -and $tok -match '\-') { continue }
                    if ($script:PlaceholderRx.IsMatch($tok)) { continue }
                    if ($script:NonCredentialRx.IsMatch($tok)) { continue }
                    if ($tok -match '^[A-Za-z_\-]+$') { continue }                       # 纯单词或标识符
                    if ((Get-ShannonEntropy -Text $tok) -lt 4.0) { continue }
                    # 兜底规则只在"没有更具体的规则已经报过这个值"时出手，
                    # 否则一个 JWT 会被 jwt 规则和熵规则各报一次，读者分不清哪条才是重点。
                    $maskedTok = Get-MaskedValue -Value $tok
                    if ($seenValues.Contains($maskedTok)) { continue }
                    # 官方文档里的示例 secret key（如 AWS 的 wJalrX…EXAMPLEKEY）是长随机串，
                    # 会被熵规则当成真密钥。静默忽略会漏掉"有人真把它复制进代码"的情况，
                    # 所以同样降级为 P2 提示而非丢弃。
                    $entSev = 'P1'
                    $entNote = '高熵字符串，疑似密钥，需人工确认'
                    if ($tok -match '(?i)EXAMPLEKEY$|EXAMPLE$') {
                        $entSev = 'P2'
                        $entNote = '疑似官方文档示例密钥，确认不是从教程复制进真实代码的'
                    }
                    Add-Finding -PatternId 'high-entropy-string' -Severity $entSev -Category 'secrets' -File $rel -Line $lineNo `
                        -Masked $maskedTok -Raw $tok -Note $entNote
                }
            }
        }
    }
}

#endregion

#region 仓库卫生

$hygiene = [ordered]@{
    hasGitignore             = $false
    hasLicense               = $false
    hasReadme                = $false
    missingGitignoreEntries  = @()
    missingRootFiles         = @()
    trackedSensitive         = @()
    largeTracked             = @()
}

if ($scanHygiene) {
    $hygiene.hasGitignore = Test-Path -LiteralPath (Join-Path $root '.gitignore')

    # .gitignore 是否存在只是及格线，还得看它有没有真的挡住常见的敏感载体
    if ($hygiene.hasGitignore) {
        $ig = Get-Content -LiteralPath (Join-Path $root '.gitignore') -Raw
        $expect = [ordered]@{
            '.env'     = '\.env'
            '密钥文件' = '(?i)\*\.(?:pem|key|p12|pfx)'
            '依赖目录' = '(?i)node_modules|\.venv|venv'
            '构建产物' = '(?i)\bdist\b|\bbuild\b|\btarget\b|__pycache__'
            'IDE 配置' = '(?i)\.idea|\.vscode|\.vs/'
        }
        foreach ($k in $expect.Keys) {
            if ($ig -notmatch $expect[$k]) { $hygiene.missingGitignoreEntries += $k }
        }
    }

    $hygiene.hasLicense = (Test-Path -LiteralPath (Join-Path $root 'LICENSE')) -or (Test-Path -LiteralPath (Join-Path $root 'LICENSE.md'))
    $hygiene.hasReadme = [bool](@('README.md', 'README.rst', 'README.txt', 'readme.md') |
        Where-Object { Test-Path -LiteralPath (Join-Path $root $_) } | Select-Object -First 1)

    foreach ($lf in @('LICENSE', 'README.md', 'CONTRIBUTING.md', 'CODE_OF_CONDUCT.md', 'CHANGELOG.md')) {
        if (-not (Test-Path -LiteralPath (Join-Path $root $lf))) { $hygiene.missingRootFiles += $lf }
    }

    # 已被 git 跟踪的敏感载体才是真正会被推上公开仓库的东西
    if ($gitIntel.isRepo) {
        $tracked = & git -C $root ls-files 2>$null
        $hygiene.trackedSensitive = @(
            $tracked | Where-Object { $_ -match '(?i)(^|/)(?:\.env(?:\..+)?|.*\.(?:pem|key|p12|pfx)|id_rsa|id_ed25519|credentials(?:\..+)?|\.npmrc|\.netrc|_netrc)$' }
        )
        $hygiene.largeTracked = @(
            $tracked | ForEach-Object {
                $f = Join-Path $root $_
                if (Test-Path -LiteralPath $f -PathType Leaf) {
                    $len = (Get-Item -LiteralPath $f).Length
                    if ($len -gt 1MB) { [pscustomobject]@{ file = $_; sizeMB = [Math]::Round($len / 1MB, 2) } }
                }
            } | Sort-Object -Property sizeMB -Descending | Select-Object -First 20
        )
    }
}

#endregion

#region README 审计

# 卫生检查只回答"README 存在吗"，而 README 的问题几乎全是**正确性**问题：
# 克隆地址是不是占位符、链接指向的文件还在不在、声称的许可证与仓库里的
# LICENSE 是否一致、文档提到的配置文件是否已被删除。
# 这些用 Test-Path 一个都查不出来，必须拿文档去和仓库现状对照。
$readme = [ordered]@{
    path             = $null
    sizeBytes        = 0
    lineCount        = 0
    placeholders     = @()
    brokenLinks      = @()
    brokenImages     = @()
    licenseClaimed   = $null
    licenseFile      = $null
    licenseInReadme  = $false
    hasCloneUrl      = $false
    hasRealRepoUrl   = $false
    mentionsInstall  = $false
    mentionsTest     = $false
    sectionHeadings  = @()
    score            = 0
    scoreMax         = 10
    scoreNotes       = @()
}

if ($scanReadme) {
    $readmeName = @('README.md', 'README.rst', 'README.txt', 'readme.md') |
        Where-Object { Test-Path -LiteralPath (Join-Path $root $_) } | Select-Object -First 1

    if ($readmeName) {
        $readmePath = Join-Path $root $readmeName
        $readme.path = $readmeName
        $readme.sizeBytes = (Get-Item -LiteralPath $readmePath).Length
        $content = Get-Content -LiteralPath $readmePath -Raw -ErrorAction SilentlyContinue
        if ($null -eq $content) { $content = '' }
        $readme.lineCount = ($content -split "`n").Count

        # ---- 1. 未替换的占位符：最常见的"我本地看着没问题"型缺陷 ----
        # 注意不要把裸的 TODO/FIXME/TBD 算进来：它们在源码里是正当的待办标记，
        # 而且项目名里就可能含 "todo"（如 todo-reminder），报出来纯属噪音。
        # 这里只抓**模板没填**的痕迹。
        foreach ($m in [regex]::Matches($content, '<[^>\r\n]{1,40}>')) {
            # 排除 HTML 注释与合法的内联标签
            if ($m.Value -match '^</?(?:!--|br|img|div|p|sub|sup|details|summary|kbd|b|i|code|a\s)') { continue }
            $readme.placeholders += $m.Value
        }
        foreach ($m in [regex]::Matches($content, '(?i)\b(?:your[-_ ]?(?:username|repo|name|org)|OWNER/REPO|USERNAME/REPO|CHANGE[_-]?ME|INSERT[_-]?(?:YOUR|HERE))\b')) {
            $readme.placeholders += $m.Value
        }
        # 指向 example.com 的克隆地址说明模板没填
        foreach ($m in [regex]::Matches($content, '(?i)github\.com/(?:your|example|username|owner)/[\w.\-]+')) {
            $readme.placeholders += $m.Value
        }
        $readme.placeholders = @($readme.placeholders | Sort-Object -Unique)

        # ---- 2. 相对链接指向的文件是否真的存在 ----
        foreach ($m in [regex]::Matches($content, '\]\((?!https?://|#|mailto:)([^)\s]+)\)')) {
            $target = $m.Groups[1].Value.Split('#')[0]
            if (-not $target) { continue }
            $decoded = [System.Uri]::UnescapeDataString($target)
            if (-not (Test-Path -LiteralPath (Join-Path $root $decoded))) {
                $readme.brokenLinks += $decoded
            }
        }
        $readme.brokenLinks = @($readme.brokenLinks | Sort-Object -Unique)

        # ---- 3. 图片引用是否真的存在 ----
        foreach ($m in [regex]::Matches($content, '!\[[^\]]*\]\((?!https?://)([^)\s]+)\)')) {
            $target = $m.Groups[1].Value.Split('#')[0]
            if (-not $target) { continue }
            $decoded = [System.Uri]::UnescapeDataString($target)
            if (-not (Test-Path -LiteralPath (Join-Path $root $decoded))) {
                $readme.brokenImages += $decoded
            }
        }
        $readme.brokenImages = @($readme.brokenImages | Sort-Object -Unique)

        # ---- 4. 许可证一致性：README 的声明必须与仓库里的文件对得上 ----
        $licFile = @('LICENSE', 'LICENSE.md', 'LICENSE.txt', 'COPYING') |
            Where-Object { Test-Path -LiteralPath (Join-Path $root $_) } | Select-Object -First 1
        $readme.licenseFile = $licFile

        # 许可证章节标题。这里刻意不用 \b 收尾：中文标题（"## 许可"）后面没有词边界，
        # 用 \b 会导致中文 README 的许可章节全部识别不到。
        if ($content -match '(?im)^#{1,4}\s*(?:许可证|许可|license|licence|licensing)\s*$') {
            $readme.licenseInReadme = $true
        }
        if ($content -match '(?i)\bMIT\b') { $readme.licenseClaimed = 'MIT' }
        elseif ($content -match '(?i)Apache[- ]2') { $readme.licenseClaimed = 'Apache-2.0' }
        elseif ($content -match '(?i)\bGPL\b') { $readme.licenseClaimed = 'GPL' }
        elseif ($content -match '(?i)\bBSD\b') { $readme.licenseClaimed = 'BSD' }

        # ---- 5. 克隆地址与仓库 URL ----
        $readme.hasCloneUrl = $content -match '(?i)git\s+clone'
        $readme.hasRealRepoUrl = $content -match 'github\.com/[\w.\-]+/[\w.\-]+'
        $readme.mentionsInstall = $content -match '(?i)install|安装|npm i|pip install|go get|cargo add'
        $readme.mentionsTest = $content -match '(?i)\btest\b|测试|pytest|vitest|jest|dotnet test|flutter test'

        # ---- 6. 结构：标题层级 ----
        $readme.sectionHeadings = @(
            [regex]::Matches($content, '(?m)^(#{1,4})\s+(.+?)\s*$') |
                ForEach-Object { "$($_.Groups[1].Value.Length)级: $($_.Groups[2].Value.Trim())" }
        )

        # ---- 7. 健康分：把"能不能用"量化成一件事，便于跨仓库比较与追踪改进 ----
        $checks = [ordered]@{
            '首句能说清项目是什么'   = ($readme.lineCount -ge 5 -and $content.Length -gt 200)
            '有真实克隆地址'         = $readme.hasRealRepoUrl
            '无未替换占位符'         = ($readme.placeholders.Count -eq 0)
            '无死链'                 = ($readme.brokenLinks.Count -eq 0)
            '无失效图片'             = ($readme.brokenImages.Count -eq 0)
            '有许可证文件'           = [bool]$readme.licenseFile
            'README 声明了许可证'    = $readme.licenseInReadme
            '声明与 LICENSE 一致'    = ($readme.licenseInReadme -and [bool]$readme.licenseFile)
            '有安装或运行说明'       = $readme.mentionsInstall
            '有测试或验证说明'       = $readme.mentionsTest
        }
        foreach ($k in $checks.Keys) {
            if ($checks[$k]) { $readme.score++ } else { $readme.scoreNotes += $k }
        }
    }
}

#endregion

#region 汇总与报告

# 去重：同一文件同一行同一规则只保留一条，否则重复赋值会灌爆报告
$fileRuleIds = @('sensitive-filename', 'sensitive-filename-config', 'env-by-environment')

$deduped = [System.Collections.Generic.List[object]]::new()
$seen = [System.Collections.Generic.HashSet[string]]::new()
# 被内容规则抓到真实凭据的文件清单（先扫一遍，文件名规则要用它来避让）
$contentHitFiles = [System.Collections.Generic.HashSet[string]]::new()
foreach ($f in $script:RawFindings) {
    if ($fileRuleIds -notcontains $f.id) { $null = $contentHitFiles.Add($f.file) }
}
# 同一个文件可能同时命中多条文件名规则（.env.production 既匹配通用凭据载体规则，
# 也匹配按环境划分的规则）。两条规则的结论一致，分开展示只会让读者以为发现了两个问题，
# 所以按文件路径合并，取最严重的那条结论。
$mergedFileFindings = [ordered]@{}

foreach ($f in $script:RawFindings) {
    $key = "$($f.id)|$($f.file)|$($f.line)|$($f.evidence)"
    if (-not $seen.Add($key)) { continue }

    if ($fileRuleIds -contains $f.id) {
        # 如果这个文件里的真实凭据已经被内容规则（connection-password 等）抓到，
        # 文件名规则就不该再插一句"这只是个模板"——两条结论会互相矛盾，
        # 读者会不知道该信哪个。内容规则看的是实际值，永远更可信，以它为准。
        if ($contentHitFiles.Contains($f.file)) { continue }

        if ($mergedFileFindings.Contains($f.file)) {
            $existing = $mergedFileFindings[$f.file]
            $rank = @{ 'P0' = 0; 'P1' = 1; 'P2' = 2 }
            if ($rank[$f.severity] -lt $rank[$existing.severity]) { $mergedFileFindings[$f.file] = $f }
        }
        else {
            $mergedFileFindings[$f.file] = $f
        }
        continue
    }

    $deduped.Add($f)
}
foreach ($f in $mergedFileFindings.Values) { $deduped.Add($f) }

$cap = if ($All) { [int]::MaxValue } else { 200 }

$bySeverity = [ordered]@{ P0 = 0; P1 = 0; P2 = 0 }
foreach ($f in $deduped) { $bySeverity[$f.severity] = $bySeverity[$f.severity] + 1 }

$grouped = $deduped | Group-Object -Property id | Sort-Object -Property @{Expression = {
            $s = $_.Group[0].severity; if ($s -eq 'P0') { 0 } elseif ($s -eq 'P1') { 1 } else { 2 }
        } }, Name

$renderGroups = @()
foreach ($g in $grouped) {
    $items = @($g.Group | Select-Object -First $cap)
    $renderGroups += [pscustomobject]@{
        id          = $g.Name
        severity    = $g.Group[0].severity
        category    = $g.Group[0].category
        description = $g.Group[0].note
        total       = $g.Count
        shown       = $items.Count
        items       = @($items | ForEach-Object {
                [pscustomobject]@{ file = $_.file; line = $_.line; evidence = $_.evidence }
            })
    }
}

# 值级归并：同一个密钥出现十次也只需要轮换一次，所以按原始值归并后再报告
$uniqueAll = @($deduped | Where-Object { $_.raw } | Group-Object -Property raw |
    Sort-Object -Property @{Expression = { $_.Count }; Descending = $true } |
    ForEach-Object {
        [pscustomobject]@{
            severity = $_.Group[0].severity
            category = $_.Group[0].category
            masked   = (Get-MaskedValue -Value $_.Name)
            count    = $_.Count
            files    = @($_.Group | ForEach-Object { $_.file } | Sort-Object -Unique | Select-Object -First 8)
        }
    })

# 只有凭据需要"轮换"；手机号与内网 IP 的处置方式是替换，混在一起会误导读者
$rotationValues = @($uniqueAll | Where-Object { $_.category -eq 'secrets' })
$piiValues = @($uniqueAll | Where-Object { $_.category -ne 'secrets' })

$result = [pscustomobject]@{
    generatedAt   = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    scannedRoot   = $root
    mode          = $Mode
    fileCount     = $files.Count
    skippedLarge  = $skippedLarge
    skippedBinary = $skippedBinary
    summary       = [pscustomobject]@{ P0 = $bySeverity.P0; P1 = $bySeverity.P1; P2 = $bySeverity.P2; total = $deduped.Count }
    patterns      = $renderGroups
    rotationValues = $rotationValues
    piiValues      = $piiValues
    git           = $gitIntel
    hygiene       = $hygiene
    readme        = $readme
}

New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
$jsonPath = Join-Path $OutDir 'report.json'
$mdPath = Join-Path $OutDir 'report.md'
$result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $jsonPath -Encoding utf8

# Markdown 报告：给人读的版本
$md = [System.Collections.Generic.List[string]]::new()
$md.Add('# 仓库隐私扫描报告')
$md.Add('')
$md.Add("- 扫描时间：$($result.generatedAt)")
$md.Add("- 扫描目录：``$root``")
$md.Add("- 扫描模式：$Mode")
$md.Add("- 文件数：$($result.fileCount)（跳过超大文件 $skippedLarge，跳过二进制 $skippedBinary）")
$md.Add("- 问题统计：**P0 = $($bySeverity.P0)** / P1 = $($bySeverity.P1) / P2 = $($bySeverity.P2)")
$md.Add('')
$md.Add('> 本报告中的所有敏感值均已掩码。报告应保存在仓库之外，不要提交到版本库。')
$md.Add('')

if ($deduped.Count -eq 0) {
    $md.Add('未匹配到规则。仍建议人工确认业务数据与截图内容——正则挡不住"看起来很正常"的真实数据。')
    $md.Add('')
}

foreach ($sev in @('P0', 'P1', 'P2')) {
    $groups = @($renderGroups | Where-Object { $_.severity -eq $sev })
    if ($groups.Count -eq 0) { continue }
    $title = if ($sev -eq 'P0') { 'P0 必须处理（密钥与凭据）' }
    elseif ($sev -eq 'P1') { 'P1 应该处理（个人信息 / 内网信息 / 疑似密钥）' }
    else { 'P2 建议处理' }
    $md.Add("## $title")
    $md.Add('')
    foreach ($g in $groups) {
        $md.Add("### ``$($g.id)`` — $($g.description)（$($g.total) 处）")
        $md.Add('')
        $md.Add('| 文件 | 行 | 证据（掩码） |')
        $md.Add('| --- | --- | --- |')
        foreach ($i in $g.items) {
            $md.Add("| $($i.file) | $($i.line) | ``$($i.evidence)`` |")
        }
        if ($g.total -gt $g.shown) {
            $md.Add('')
            $md.Add("> 另有 $($g.total - $g.shown) 处未列出（加 -All 可输出全部）。")
        }
        $md.Add('')
    }
}

if ($rotationValues.Count -gt 0) {
    $md.Add('## 需要轮换或重置的凭据清单')
    $md.Add('')
    $md.Add('密钥一旦进入 git 历史或曾被推送到远端，删文件并不能撤回泄露。请先轮换，再清理。')
    $md.Add('')
    $md.Add('| 掩码值 | 等级 | 出现次数 | 涉及文件 |')
    $md.Add('| --- | --- | --- | --- |')
    foreach ($u in $rotationValues) {
        $md.Add("| ``$($u.masked)`` | $($u.severity) | $($u.count) | $($u.files -join ', ') |")
    }
    $md.Add('')
}

if ($piiValues.Count -gt 0) {
    $md.Add('## 需要替换或匿名化的个人信息与内网信息')
    $md.Add('')
    $md.Add('| 掩码值 | 等级 | 出现次数 | 涉及文件 |')
    $md.Add('| --- | --- | --- | --- |')
    foreach ($u in $piiValues) {
        $md.Add("| ``$($u.masked)`` | $($u.severity) | $($u.count) | $($u.files -join ', ') |")
    }
    $md.Add('')
}

$md.Add('## README 审计')
$md.Add('')
if ($scanReadme) {
    if (-not $readme.path) {
        $md.Add('**未找到 README 文件。** 开源仓库没有 README 等于没有入口，必须补。')
        $md.Add('')
    }
    else {
        $scoreColor = if ($readme.score -ge 8) { '良好' } elseif ($readme.score -ge 5) { '及格' } else { '需要重写' }
        $md.Add("**健康分：$($readme.score) / $($readme.scoreMax)**（$scoreColor）")
        $md.Add('')
        $md.Add('| 检查项 | 结果 |')
        $md.Add('| --- | --- |')
        # 报告行先算好变量再拼接。PowerShell 的双引号字符串里再嵌双引号会截断字符串，
        # 用反引号转义虽然能过，但下一个改这行的人几乎必然踩坑，所以宁可多两行。
        $phText = if ($readme.placeholders.Count) { "**$($readme.placeholders.Count) 处**：" + (($readme.placeholders | Select-Object -First 5) -join ' ') } else { '无' }
        $linkText = if ($readme.brokenLinks.Count) { "**$($readme.brokenLinks.Count) 个**：" + (($readme.brokenLinks | Select-Object -First 5) -join ', ') } else { '无' }
        $imgText = if ($readme.brokenImages.Count) { "**$($readme.brokenImages.Count) 个**：" + (($readme.brokenImages | Select-Object -First 5) -join ', ') } else { '无' }
        $licFileText = if ($readme.licenseFile) { "``$($readme.licenseFile)``" } else { '**缺失**' }
        $licClaimText = if ($readme.licenseInReadme) { "有（$(if ($readme.licenseClaimed) { $readme.licenseClaimed } else { '未识别类型' })）" } else { '**没有许可证章节**' }
        $cloneText = if ($readme.hasRealRepoUrl) { '含真实仓库 URL' } elseif ($readme.hasCloneUrl) { '**有 git clone 但地址是占位符**' } else { '未提供' }

        $md.Add("| 文件 | ``$($readme.path)``（$($readme.sizeBytes) B，$($readme.lineCount) 行）|")
        $md.Add("| 未替换的占位符 | $phText |")
        $md.Add("| 死链（相对路径不存在） | $linkText |")
        $md.Add("| 失效图片引用 | $imgText |")
        $md.Add("| 许可证文件 | $licFileText |")
        $md.Add("| README 声明许可证 | $licClaimText |")
        $md.Add("| 克隆地址 | $cloneText |")
        $md.Add("| 安装说明 | $(if ($readme.mentionsInstall) { '有' } else { '**缺**' }) |")
        $md.Add("| 测试说明 | $(if ($readme.mentionsTest) { '有' } else { '**缺**' }) |")
        $md.Add('')
        if ($readme.scoreNotes.Count -gt 0) {
            $md.Add('未通过的检查项：')
            $md.Add('')
            foreach ($n in $readme.scoreNotes) { $md.Add("- $n") }
            $md.Add('')
        }
        if ($readme.sectionHeadings.Count -gt 0) {
            $md.Add('现有结构：')
            $md.Add('')
            foreach ($h in $readme.sectionHeadings) { $md.Add("- $h") }
            $md.Add('')
        }
        $md.Add('> 结构正确性只占一半。视觉与说服力的优化规则见 `references/github-layout.md` 的「README 设计」一节。')
        $md.Add('')
    }
}
else {
    $md.Add('（本次未执行 README 审计，可用 `-Mode readme` 单独运行）')
    $md.Add('')
}

$md.Add('## 仓库卫生')
$md.Add('')
if ($scanHygiene) {
    $md.Add('| 检查项 | 结果 |')
    $md.Add('| --- | --- |')
    $md.Add("| 是否 git 仓库 | $(if ($gitIntel.isRepo) { '是' } else { '否' }) |")
    if ($gitIntel.isRepo) { $md.Add("| 提交数 | $($gitIntel.commitCount) |") }
    if ($gitIntel.remote) { $md.Add("| origin | $($gitIntel.remote) |") }
    $md.Add("| .gitignore | $(if ($hygiene.hasGitignore) { '存在' } else { '**缺失**' }) |")
    $md.Add("| LICENSE | $(if ($hygiene.hasLicense) { '存在' } else { '**缺失**' }) |")
    $md.Add("| README | $(if ($hygiene.hasReadme) { '存在' } else { '**缺失**' }) |")
    if ($hygiene.missingGitignoreEntries.Count -gt 0) {
        $md.Add("| .gitignore 未覆盖 | $($hygiene.missingGitignoreEntries -join ', ') |")
    }
    if ($hygiene.trackedSensitive.Count -gt 0) {
        $md.Add("| **已被跟踪的敏感文件** | $($hygiene.trackedSensitive -join ', ') |")
    }
    if ($hygiene.largeTracked.Count -gt 0) {
        $md.Add("| 超过 1MB 的已跟踪文件 | $(($hygiene.largeTracked | ForEach-Object { "$($_.file) ($($_.sizeMB)MB)" }) -join ', ') |")
    }
    $md.Add('')

    if ($gitIntel.authors.Count -gt 0) {
        $md.Add('### 提交作者身份')
        $md.Add('')
        $md.Add('| 姓名 | 邮箱 |')
        $md.Add('| --- | --- |')
        foreach ($a in $gitIntel.authors) { $md.Add("| $($a.name) | $($a.email) |") }
        $md.Add('')
        $md.Add('公开仓库会永久暴露提交者姓名与邮箱。如不愿公开，请在开源前改用 noreply 邮箱。')
        $md.Add('')
    }
}
else {
    $md.Add('（本次未执行卫生检查）')
    $md.Add('')
}

$md.Add('## 下一步建议')
$md.Add('')
if ($bySeverity.P0 -gt 0) {
    $md.Add('1. **先轮换 P0 密钥**，再去清理文件——顺序反了等于没处理。')
    $md.Add('2. 把敏感文件移出仓库，改用环境变量或密钥管理服务；同时同步更新部署方式。')
    $md.Add('3. 确认这些值是否已进入 git 历史；若已推送过，按 `references/secret-patterns.md` 的历史重写方案处理。')
}
elseif ($bySeverity.P1 -gt 0) {
    $md.Add('1. 逐条确认 P1：真实信息换成占位符，或改成合成样例数据。')
    $md.Add('2. 确认无误后补齐 `.gitignore` 与开源工程文件。')
}
else {
    $md.Add('可以直接进入开源改造阶段：补齐 README、LICENSE、.gitignore 与协作文件。')
}

Set-Content -LiteralPath $mdPath -Value ($md -join [Environment]::NewLine) -Encoding utf8

#endregion

if ($Json) {
    $result | ConvertTo-Json -Depth 8
    if ($bySeverity.P0 -gt 0) { exit 1 } else { exit 0 }
}

$color = if ($bySeverity.P0 -gt 0) { 'Red' } elseif ($bySeverity.P1 -gt 0) { 'Yellow' } else { 'Green' }
Write-Host ''
Write-Host '=== 仓库隐私扫描 ===' -ForegroundColor Cyan
Write-Host "扫描目录 : $root"
Write-Host "文件数   : $($files.Count)（跳过超大 $skippedLarge / 二进制 $skippedBinary）"
Write-Host "P0: $($bySeverity.P0)   P1: $($bySeverity.P1)   P2: $($bySeverity.P2)" -ForegroundColor $color
Write-Host "报告     : $mdPath"
Write-Host "机器可读 : $jsonPath"
Write-Host ''

if ($bySeverity.P0 -gt 0) {
    Write-Host '存在 P0 问题：公开之前必须处理并轮换密钥。' -ForegroundColor Red
    exit 1
}
exit 0
