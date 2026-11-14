#!/usr/bin/env pwsh
#Requires -Version 5.1
<#
.SYNOPSIS
    一键自检：DSH 更新后 / 出问题时，跑这个判断哪一环坏了。
.DESCRIPTION
    检查 10 个环节，逐项打印 [OK] / [WARN] / [FAIL] 和一句话建议。
    只读，不修改任何东西。

    给非 JS 开发者看的：这份脚本就是"顺序执行的检查清单"，
    每个 Check-xxx 函数只做一件事，失败时返回建议字符串。
#>
[CmdletBinding()]
param(
    [string]$DshHome = $env:DSH_HOME,
    [string]$Profile = 'desktop',
    [switch]$NoPause
)

$ErrorActionPreference = 'Continue'
if ([string]::IsNullOrWhiteSpace($DshHome)) { $DshHome = Join-Path $env:USERPROFILE '.dsh' }

$script:fails = 0
$script:warns = 0

function Ok([string]$msg)   { Write-Host ("  [OK]   " + $msg) -ForegroundColor Green }
function Warn([string]$msg, [string]$fix) {
    $script:warns++
    Write-Host ("  [WARN] " + $msg) -ForegroundColor Yellow
    if ($fix) { Write-Host ("         → " + $fix) -ForegroundColor DarkYellow }
}
function Fail([string]$msg, [string]$fix) {
    $script:fails++
    Write-Host ("  [FAIL] " + $msg) -ForegroundColor Red
    if ($fix) { Write-Host ("         → " + $fix) -ForegroundColor DarkYellow }
}
function Section([string]$t) { Write-Host ""; Write-Host "── $t" -ForegroundColor Cyan }

Write-Host ""
Write-Host "dsh-lossless-context 自检" -ForegroundColor White
Write-Host "  DSH_HOME : $DshHome"
Write-Host "  profile  : $Profile"
Write-Host "  时间     : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"

# ── 1. DSH 安装 ────────────────────────────────────────────────────────────
Section "1. DeepSeek Harness 安装"
$dshExe = $null
foreach ($p in @(
    "$env:LOCALAPPDATA\Programs\DeepSeek Harness",
    "$env:ProgramFiles\DeepSeek Harness"
)) {
    if (Test-Path (Join-Path $p 'DeepSeek Harness.exe')) { $dshExe = $p; break }
}
if ($dshExe) {
    $ver = (Get-Content (Join-Path $dshExe 'version') -ErrorAction SilentlyContinue) -join ''
    $asar = Get-Item (Join-Path $dshExe 'resources\app.asar') -ErrorAction SilentlyContinue
    Ok "装在 $dshExe"
    Write-Host "         版本文件: $ver"
    if ($asar) { Write-Host "         app.asar: $([Math]::Round($asar.Length/1MB,1)) MB, 编译于 $($asar.LastWriteTime)" }
} else {
    Fail "找不到 DeepSeek Harness.exe" "确认安装路径"
}

# ── 2. 归档插件 ────────────────────────────────────────────────────────────
Section "2. 归档插件 openseek-lcm"
$pluginDir = Join-Path (Join-Path (Join-Path $DshHome 'profiles') $Profile) 'node_modules\openseek-lcm'
if (Test-Path $pluginDir) {
    $pkg = Get-Content (Join-Path $pluginDir 'package.json') -Raw | ConvertFrom-Json
    Ok "版本 $($pkg.version)"
    if (-not (Test-Path (Join-Path $pluginDir 'index.js'))) {
        Fail "package.json 在但 index.js 不见了" "重装：dsh plugin --profile $Profile add openseek-lcm"
    }
} else {
    Fail "插件没装" "关掉 DSH 后执行：dsh plugin --profile $Profile add openseek-lcm"
}

# ── 3. 归档数据库 ──────────────────────────────────────────────────────────
Section "3. 归档数据库 lcm.db"
$db = Join-Path $DshHome 'storages\dsh-plugin-lcm\lcm.db'
if (Test-Path $db) {
    $info = Get-Item $db
    $age = ((Get-Date) - $info.LastWriteTime).TotalHours
    Ok ("{0:N1} MB, 最后写入 {1:N1} 小时前" -f ($info.Length/1MB), $age)
    if ($age -gt 48) {
        Warn "超过 48 小时没写入 → 插件可能没在跑" "重启 DSH；仍不涨就重装插件"
    }
    # WAL 异常大
    $wal = Get-Item "$db-wal" -ErrorAction SilentlyContinue
    if ($wal -and $wal.Length -gt 200MB) {
        Warn "WAL 文件超过 200 MB" "在 DSH 里跑 /lcm compact apply"
    }
} else {
    Fail "没有 lcm.db" "插件没初始化：重启 DSH，然后随便发一句消息"
}

# ── 4. 配置覆盖层 ──────────────────────────────────────────────────────────
Section "4. profile 配置（cordis.patch.yml）"
$patch = Join-Path (Join-Path (Join-Path $DshHome 'profiles') $Profile) 'cordis.patch.yml'
if (Test-Path $patch) {
    $txt = Get-Content $patch -Raw -Encoding UTF8
    $need = @{
        'openseek-lcm'       = '归档层'
        'compaction-basic'   = '压缩层'
        'tool-result-pruner' = '工具输出修剪'
        'preset-roleplay'    = '角色扮演 preset'
    }
    foreach ($k in $need.Keys) {
        if ($txt -match [regex]::Escape($k)) { Ok "$k（$($need[$k])）" }
        else { Warn "$k 不在配置里（$($need[$k])）" "重跑对应的 install 脚本" }
    }
    # YAML 粗检：制表符、明显缩进错误
    if ($txt -match "`t") { Fail "配置里有 Tab 字符（YAML 不允许）" "把 Tab 换成空格" }
} else {
    Fail "找不到 profile 覆盖层" "确认 profile 名是不是 $Profile"
}

# ── 5. 计划任务 ────────────────────────────────────────────────────────────
Section "5. 计划任务"
$tasks = @{
    'DSH-Auto-Snapshot'  = '恢复包存档（每 10 分钟）'
    'DSH-LCM-Snapshot'   = '归档快照（每 30 分钟）'
    'DSH-Daily-Backup'   = '全量备份（每天 00:00）'
}
foreach ($n in $tasks.Keys) {
    $q = & schtasks.exe /Query /TN $n /FO LIST 2>&1 | Out-String
    if ($q -match 'Ready|Running|就绪|正在运行') {
        $next = ([regex]::Match($q, '(?:Next Run Time|下次运行时间):\s*(.+)')).Groups[1].Value.Trim()
        Ok ("{0}（{1}）下次 {2}" -f $n, $tasks[$n], $next)
    } else {
        Warn "$n 不存在（$($tasks[$n])）" "在 dsh-lossless-context\scripts 里跑对应的 install-*.ps1"
    }
}

# ── 6. 备份与存档产物 ──────────────────────────────────────────────────────
Section "6. 备份与存档产物"
$snapRoot = Join-Path (Join-Path $env:USERPROFILE 'Documents') 'dsh-backup\snapshots'
if (Test-Path $snapRoot) {
    $md = Get-ChildItem $snapRoot -Recurse -File -Filter *.md -ErrorAction SilentlyContinue |
          Sort-Object LastWriteTime -Descending
    if ($md) {
        Ok ("存档 {0} 份，最新 {1:N1} 小时前" -f $md.Count, ((Get-Date) - $md[0].LastWriteTime).TotalHours)
    } else {
        Warn "存档目录是空的" "双击桌面的「存档一次.cmd」"
    }
} else {
    Warn "还没有存档目录" "双击桌面的「存档一次.cmd」"
}

$bakRoot = Join-Path (Join-Path $env:USERPROFILE 'Documents') 'dsh-backup'
$baks = Get-ChildItem $bakRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^\d{8}-\d{6}$' } | Sort-Object Name -Descending
if ($baks) { Ok ("全量备份 {0} 份，最新 {1}" -f $baks.Count, $baks[0].Name) }
else { Warn "还没有全量备份" "手动跑：scripts\dsh-backup.ps1 -WaitIdleMinutes 0" }

# ── 7. node 与 SQLite 能力 ─────────────────────────────────────────────────
Section "7. 运行时（node / SQLite）"
$node = Join-Path $DshHome 'dsh-runtimes\dsh-primary-runtime\dependencies\node\bin\node.exe'
if (-not (Test-Path $node)) {
    $cmd = Get-Command node -ErrorAction SilentlyContinue
    if ($cmd) { $node = $cmd.Source }
}
if ($node -and (Test-Path $node)) {
    $v = & $node --version 2>&1
    Ok "node $v（$node）"
    $probe = & $node -e "try{const{DatabaseSync}=require('node:sqlite');new DatabaseSync(':memory:');console.log('ok')}catch(e){console.log('no:'+e.message)}" 2>&1
    if ("$probe" -match 'ok') { Ok "node:sqlite 可用（FTS5 依赖它）" }
    else { Fail "node:sqlite 不可用" "升级 DSH（自带运行时会带）" }
} else {
    Fail "找不到 node" "检查 DSH 是否完整安装"
}

# ── 8. 归档一致性（借用 lcm-inspect）────────────────────────────────────────
Section "8. 归档一致性"
$repo = Split-Path -Parent $PSScriptRoot
$inspect = Join-Path $repo 'tools\lcm-inspect.mjs'
if (-not (Test-Path $inspect)) { $inspect = Join-Path $repo '..\tools\lcm-inspect.mjs' }
if ((Test-Path $inspect) -and $node -and (Test-Path $db)) {
    $out = & $node $inspect --json 2>&1 | Out-String
    try {
        $j = $out | ConvertFrom-Json
        if ($j.integrity -eq 'ok') { Ok "SQLite 完整性 ok" } else { Fail "完整性检查失败：$($j.integrity)" "备份后重建归档" }
        if ($j.counts.messages -eq $j.counts.message_fts) {
            Ok "消息数 = FTS 索引数（$($j.counts.messages)）"
        } else {
            Warn "消息数($($j.counts.messages)) ≠ FTS($($j.counts.message_fts))" "在 DSH 里跑 /lcm doctor apply"
        }
        if ($j.warnings -and $j.warnings.Count -gt 0) {
            foreach ($w in $j.warnings) { Warn $w "" }
        }
    } catch {
        Warn "体检输出解析失败（不影响使用）" ""
    }
} else {
    Warn "跳过（缺 tools/lcm-inspect.mjs 或 lcm.db）" ""
}

# ── 汇总 ───────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host ("═" * 60)
if ($script:fails -eq 0 -and $script:warns -eq 0) {
    Write-Host "  全部正常。" -ForegroundColor Green
} elseif ($script:fails -eq 0) {
    Write-Host "  可用，有 $($script:warns) 个提醒（不影响使用）。" -ForegroundColor Yellow
} else {
    Write-Host "  有 $($script:fails) 项失败、$($script:warns) 项提醒。" -ForegroundColor Red
    Write-Host "  先按上面 [FAIL] 的 → 提示处理，处理完再跑一次。" -ForegroundColor Red
}
Write-Host ("═" * 60)
Write-Host ""

if (-not $NoPause) { Read-Host "按回车关闭" | Out-Null }
exit $script:fails
