<#
.SYNOPSIS
    把这个技能安装到本机的技能目录，让 Claude Code / Codex / DSH 等 Agent 能自动发现它。

.DESCRIPTION
    默认只做干跑（dry-run），打印将要执行的每个动作但不落盘；确认无误后加 -Apply 才真正安装。

    采用「复制」而不是「符号链接」作为默认方式，原因是 Windows 上创建符号链接需要开发者模式
    或管理员权限，而且很多工具在解析链接指向仓库外的路径时会出问题。代价是安装后本地副本与
    仓库不再同步——改完仓库要重新运行本脚本。

    目标目录中若已存在同名技能，默认不覆盖。要覆盖需显式加 -Force，避免悄悄抹掉用户自己改过的版本。

.PARAMETER Destination
    安装目标。默认安装到 ~/.claude/skills 与 ~/.agents/skills 两处，
    前者服务 Claude Code，后者被 Codex 与 DSH 同时读取。

.PARAMETER Apply
    真正执行。不加此参数时只打印计划。

.PARAMETER Force
    覆盖已存在的同名技能。

.PARAMETER Uninstall
    从目标目录移除已安装的副本，不影响仓库中的源文件。

.EXAMPLE
    ./install.ps1
    查看将要执行的动作。

.EXAMPLE
    ./install.ps1 -Apply

.EXAMPLE
    ./install.ps1 -Uninstall -Apply
#>
[CmdletBinding()]
param(
    [string[]]$Destination = @(),
    [switch]$Apply,
    [switch]$Force,
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'

$skillName = 'repo-privacy-hardening'
# 本脚本位于 <skill>/scripts/ 下，技能根目录在上一层
$source = Split-Path -Parent $PSScriptRoot

if ($Destination.Count -eq 0) {
    $Destination = @(
        (Join-Path $HOME '.claude/skills'),
        (Join-Path $HOME '.agents/skills')
    )
}

function Write-Step {
    param([string]$Text, [string]$Kind = 'plan')
    $prefix = switch ($Kind) {
        'plan' { '[计划] ' }
        'done' { '[完成] ' }
        'skip' { '[跳过] ' }
        'warn' { '[注意] ' }
        default { '       ' }
    }
    $color = switch ($Kind) { 'done' { 'Green' } 'skip' { 'DarkGray' } 'warn' { 'Yellow' } default { 'Cyan' } }
    Write-Host "$prefix$Text" -ForegroundColor $color
}

if (-not (Test-Path -LiteralPath (Join-Path $source 'SKILL.md'))) {
    Write-Error "源目录中找不到 SKILL.md：$source"
    exit 2
}

if (-not $Apply) {
    Write-Host ''
    Write-Host '=== 干跑模式：不会修改任何文件 ===' -ForegroundColor Yellow
    Write-Host '确认下面的动作无误后，加 -Apply 参数真正执行。'
    Write-Host ''
}

$exitCode = 0

foreach ($root in $Destination) {
    $target = Join-Path $root $skillName

    if ($Uninstall) {
        if (Test-Path -LiteralPath $target) {
            Write-Step "移除 $target" 'plan'
            if ($Apply) {
                Remove-Item -LiteralPath $target -Recurse -Force
                Write-Step "已移除 $target" 'done'
            }
        }
        else {
            Write-Step "不存在，无需移除：$target" 'skip'
        }
        continue
    }

    if (Test-Path -LiteralPath $target) {
        if (-not $Force) {
            Write-Step "已存在同名技能，未覆盖（需要覆盖请加 -Force）：$target" 'skip'
            continue
        }
        Write-Step "覆盖已存在的 $target" 'warn'
        if ($Apply) {
            Remove-Item -LiteralPath $target -Recurse -Force
        }
    }

    if (-not (Test-Path -LiteralPath $root)) {
        Write-Step "创建目录 $root" 'plan'
        if ($Apply) { New-Item -ItemType Directory -Path $root -Force | Out-Null }
    }

    Write-Step "复制 $skillName → $target" 'plan'
    if ($Apply) {
        Copy-Item -LiteralPath $source -Destination $target -Recurse -Force
        Write-Step "已安装到 $target" 'done'
    }
}

Write-Host ''
if (-not $Apply) {
    Write-Host '干跑结束，未做任何修改。' -ForegroundColor Yellow
}
else {
    Write-Host '安装完成。技能会在下一次会话开始时被自动发现。' -ForegroundColor Green
    Write-Host '注意：安装的是副本；修改仓库后需要重新运行本脚本同步。' -ForegroundColor DarkGray
}

exit $exitCode
