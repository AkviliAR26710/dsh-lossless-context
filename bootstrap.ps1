#!/usr/bin/env pwsh
#Requires -Version 5.1
<#
.SYNOPSIS
    一键重建所有配置：读 settings.json → 探测当前 DSH 环境 → 重写配置块 → 修任务 → 自检。
.DESCRIPTION
    这是升级 DSH 之后唯一需要跑的东西。

    它做的事：
      1. 读 settings.json（所有参数都在这里，不用碰 JS）
      2. 探测当前环境：DSH 版本、profile 路径、node、插件版本、**每个插件实际支持哪些配置键**
      3. 只生成"当前版本真正认识的键"（避免键名漂移后静默失效）
      4. 用标记块整体替换 profile 里的配置（幂等，可以反复跑）
      5. 检查/修复计划任务
      6. 跑自检

    兼容性降级：
      · 有 dsh-persona + dsh-agent-preset → 生成完整 preset（系统提示整体替换）
      · 没有（大换血） → 降级成 system-prompt.personaSuffix，并在最后提示

.PARAMETER Settings
    settings.json 路径。默认仓库根的 settings.json。
.PARAMETER DryRun
    只打印将要写入的内容，不改文件。
.PARAMETER SkipTasks
    跳过计划任务检查。
.EXAMPLE
    ./bootstrap.ps1
    ./bootstrap.ps1 -DryRun
#>
[CmdletBinding()]
param(
    [string]$Settings = '',
    [string]$DshHome = $env:DSH_HOME,
    [switch]$DryRun,
    [switch]$SkipTasks
)

$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding($false)

$repo = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($Settings)) { $Settings = Join-Path $repo 'settings.json' }
if ([string]::IsNullOrWhiteSpace($DshHome)) { $DshHome = Join-Path $env:USERPROFILE '.dsh' }

$BEGIN = '# === dsh-lossless-context BEGIN（由 bootstrap.ps1 生成，勿手改；改 settings.json 后重跑）==='
$END   = '# === dsh-lossless-context END ==='

function Step([string]$t) { Write-Host ""; Write-Host "── $t" -ForegroundColor Cyan }
function Info([string]$m) { Write-Host "   $m" }
function Ok([string]$m)   { Write-Host "   [ok] $m" -ForegroundColor Green }
function Warn([string]$m) { Write-Host "   [!]  $m" -ForegroundColor Yellow }

# ── 1. 读 settings ─────────────────────────────────────────────────────────
Step "1. 读取 settings.json"
if (-not (Test-Path -LiteralPath $Settings)) {
    Write-Host "   找不到 $Settings" -ForegroundColor Red
    exit 1
}
$cfg = Get-Content -LiteralPath $Settings -Raw -Encoding UTF8 | ConvertFrom-Json
$profile = if ($cfg.profile) { $cfg.profile } else { 'desktop' }
Ok "profile = $profile"

# ── 2. 探测环境 ────────────────────────────────────────────────────────────
Step "2. 探测环境"
$profileDir = Join-Path (Join-Path (Join-Path $DshHome 'profiles') $profile) ''
$profileDir = $profileDir.TrimEnd('\', '/')
$patch = Join-Path $profileDir 'cordis.patch.yml'
$nm = Join-Path $profileDir 'node_modules'

if (-not (Test-Path -LiteralPath $patch)) {
    Write-Host "   找不到 $patch（profile 名对不对？）" -ForegroundColor Red
    exit 1
}
Ok "profile 目录：$profileDir"

# node
$node = Join-Path $DshHome 'dsh-runtimes\dsh-primary-runtime\dependencies\node\bin\node.exe'
if (-not (Test-Path $node)) {
    $c = Get-Command node -ErrorAction SilentlyContinue
    if ($c) { $node = $c.Source }
}
if ($node) { Ok "node：$node" } else { Warn "找不到 node（工具脚本会不可用）" }

# 插件探测
function Get-PkgVersion([string]$name) {
    $p = Join-Path $nm "$name\package.json"
    if (Test-Path $p) { try { return (Get-Content $p -Raw | ConvertFrom-Json).version } catch { return '?' } }
    return $null
}
$lcmVer = Get-PkgVersion 'openseek-lcm'
if ($lcmVer) { Ok "openseek-lcm $lcmVer" } else { Warn "openseek-lcm 没装（归档层会跳过）" }

# DSH 自带包：从 app.asar 目录判断是否存在（用 profile 里可解析性代替）
# 读 asar 的文件清单 JSON（存在文件头），缓存一次复用
$script:asarIndex = $null
function Get-AsarIndex {
    if ($script:asarIndex -ne $null) { return $script:asarIndex }
    $dshRoot = $null
    foreach ($p in @("$env:LOCALAPPDATA\Programs\DeepSeek Harness", "$env:ProgramFiles\DeepSeek Harness")) {
        if (Test-Path (Join-Path $p 'resources\app.asar')) { $dshRoot = $p; break }
    }
    if (-not $dshRoot) { $script:asarIndex = ''; return '' }
    $asar = Join-Path $dshRoot 'resources\app.asar'
    try {
        $fs = [System.IO.File]::OpenRead($asar)
        $hdr = New-Object byte[] 16
        [void]$fs.Read($hdr, 0, 16)
        # asar 头布局：4 字节 pickle 长度、4 字节 header size+4、4 字节 header size+4、4 字节 JSON 长度
        $jsonLen = [BitConverter]::ToUInt32($hdr, 4)
        if ($jsonLen -le 0 -or $jsonLen -gt 64MB) { $fs.Close(); $script:asarIndex = ''; return '' }
        $buf = New-Object byte[] $jsonLen
        $read = 0
        while ($read -lt $jsonLen) {
            $n = $fs.Read($buf, $read, $jsonLen - $read)
            if ($n -le 0) { break }
            $read += $n
        }
        $fs.Close()
        $script:asarIndex = [System.Text.Encoding]::UTF8.GetString($buf, 0, $read)
        return $script:asarIndex
    } catch {
        $script:asarIndex = ''
        return ''
    }
}

function Test-DshPkg([string]$name) {
    # name 传短名（如 dsh-persona），跨版本都能匹配：
    #   旧版 asar 路径：node_modules/@deepseek-ai/dsh-persona/...
    #   新版 asar 路径：直接 "dsh-persona":{...}
    $short = $name -replace '^@[^/]+/', ''
    # 1) profile 的 node_modules 里（用户自己装的插件）
    foreach ($cand in @($name, (Join-Path 'node_modules' $short))) {
        if (Test-Path (Join-Path $nm $cand)) { return $true }
    }
    if (Test-Path (Join-Path $nm $short)) { return $true }
    # 2) DSH 自带：查 asar 的文件清单，用 JSON key 形式匹配
    $idx = Get-AsarIndex
    if ([string]::IsNullOrEmpty($idx)) { return $false }
    if ($idx.Contains('"' + $short + '":')) { return $true }
    # 3) 兜底：旧版带前缀的路径
    return $idx.Contains($name)
}

$hasPersona = Test-DshPkg 'dsh-persona'
$hasPreset  = Test-DshPkg 'dsh-agent-preset'
$hasCompact = Test-DshPkg 'dsh-compaction-basic'
$hasPruner  = Test-DshPkg 'dsh-compaction-tool-result-pruner'

if ($hasPersona -and $hasPreset) { Ok "dsh-persona + dsh-agent-preset 都在 → 可生成完整 preset" }
else { Warn "缺 dsh-persona / dsh-agent-preset → 降级用 personaSuffix" }
if ($hasCompact) { Ok "dsh-compaction-basic 在" } else { Warn "dsh-compaction-basic 不在（压缩层会跳过）" }
if ($hasPruner) { Ok "dsh-compaction-tool-result-pruner 在" } else { Warn "pruner 不在（跳过）" }

# ── 3. 探测插件实际支持哪些配置键 ──────────────────────────────────────────
Step "3. 探测插件支持的配置键"
function Get-LcmKeys {
    $f = Join-Path $nm 'openseek-lcm\lib\config.js'
    if (-not (Test-Path $f)) { return $null }
    $src = Get-Content $f -Raw -Encoding UTF8
    $m = [regex]::Match($src, 'DEFAULT_CONFIG\s*=\s*\{')
    if (-not $m.Success) { return $null }
    # 从 { 开始做花括号配平，取出一层键
    $i = $src.IndexOf('{', $m.Index) + 1
    $depth = 1; $j = $i
    while ($j -lt $src.Length -and $depth -gt 0) {
        $ch = $src[$j]
        if ($ch -eq '{') { $depth++ }
        elseif ($ch -eq '}') { $depth-- }
        $j++
    }
    $body = $src.Substring($i, $j - $i - 1)
    # 只取顶层键（depth 0 的 name:）
    $keys = @(); $d = 0; $lineStart = 0
    $lines = $body -split "`n"
    foreach ($line in $lines) {
        $trim = $line.Trim()
        if ($d -eq 0 -and $trim -match '^([A-Za-z_][A-Za-z0-9_]*)\s*:') { $keys += $Matches[1] }
        $d += ([regex]::Matches($line, '\{')).Count
        $d -= ([regex]::Matches($line, '\}')).Count
        if ($d -lt 0) { $d = 0 }
    }
    return $keys
}
$lcmKeys = Get-LcmKeys
if ($lcmKeys) { Ok ("openseek-lcm 认识 {0} 个键：{1}" -f $lcmKeys.Count, ($lcmKeys -join ', ')) }
else { Warn "读不到 openseek-lcm 的配置键，将使用保守键集" }
if (-not $lcmKeys) { $lcmKeys = @('storeDir','capture','automaticRetrieval','freshTailMessages','summary','systemHint','tools','allowScopeAll','retention') }

function Has-Key([string]$k) { return ($lcmKeys -contains $k) }
function SkipNote([string]$k) { if (-not (Has-Key $k)) { Warn "  跳过 $k（当前插件版本不认识这个键）" } }

# ── 4. 生成配置块 ──────────────────────────────────────────────────────────
Step "4. 生成配置块"

$sb = New-Object System.Text.StringBuilder
function L([string]$s = '') { [void]$sb.AppendLine($s) }

L $BEGIN
L "#"
L "#  由 bootstrap.ps1 根据 settings.json 生成于 $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
L "#  改参数请改 settings.json，然后重跑 bootstrap；不要手改本段。"
L "#  卸载：删掉 BEGIN/END 之间的全部内容，重启 DSH。"
L "#"

$arch = $cfg.archive
$comp = $cfg.compaction
$prun = $cfg.pruner
$role = $cfg.roleplay

# 4.1 归档层
if ($arch -and $arch.enabled -and $lcmVer) {
    L ""
    L "# ── 归档层：逐字存进本地 SQLite，压缩不碰它 ──"
    L "- id: openseek-lcm"
    L "  config:"
    if (Has-Key 'capture') {
        L "    capture:"
        L "      enabled: true"
        L ("      includeToolResults: " + $(if ($arch.includeToolResults) { 'true' } else { 'false' }))
        L ("      maxTextCharsPerMessage: " + $arch.maxTextCharsPerMessage)
    }
    if (Has-Key 'automaticRetrieval') {
        L "    automaticRetrieval:"
        L "      enabled: false"
    }
    if (Has-Key 'scopeDefaults') {
        L "    scopeDefaults:"
        L ("      grep: " + $arch.scopeDefaults.grep)
        L ("      describe: " + $arch.scopeDefaults.describe)
    }
    if (Has-Key 'freshTailMessages') { L ("    freshTailMessages: " + $arch.freshTailMessages) }
    if (Has-Key 'summary') {
        L "    summary:"
        L ("      minMessagesForTransform: " + $arch.summary.minMessagesForTransform)
        L ("      levelSize: " + $arch.summary.levelSize)
        L ("      summaryCharBudget: " + $arch.summary.summaryCharBudget)
    }
    if (Has-Key 'systemHint') { L "    systemHint: true" }
    if (Has-Key 'tools') {
        L "    tools:"
        L "      enabled: true"
        if ($arch.tools -and @($arch.tools).Count -gt 0) {
            L "      expose:"
            foreach ($t in $arch.tools) { L ("        - " + $t) }
        }
    }
    if (Has-Key 'allowScopeAll') { L "    allowScopeAll: false" }
    if (Has-Key 'retention') {
        L "    retention:"
        L ("      deletedSessionDays: " + $arch.retention.deletedSessionDays)
        L ("      orphanBlobDays: " + $arch.retention.orphanBlobDays)
    }
} elseif ($arch -and $arch.enabled) {
    L ""
    L "# 归档层跳过：openseek-lcm 未安装"
}

# 4.2 压缩层
if ($comp -and $hasCompact) {
    L ""
    L "# ── 压缩层：到水位才折叠旧历史，摘要走便宜模型 ──"
    L "- id: compaction-basic"
    L "  config:"
    L ("    thresholdRatio: " + $comp.thresholdRatio)
    L ("    headroomTokens: " + $comp.headroomTokens)
    L ("    retainRatio: " + $comp.retainRatio)
    L "    summarizationProvider: deepseek-official"
    L ("    summarizationModel: " + $comp.summarizationModel)
    L ("    maxTokens: " + $comp.maxTokens)
    L ("    compactionRetries: " + $comp.compactionRetries)
    L ("    maxOverflowRetries: " + $comp.maxOverflowRetries)
    L "    auto: true"
}

# 4.3 修剪器
if ($prun -and $hasPruner) {
    L ""
    L "# ── 工具输出修剪：放宽头尾，别把中段细节砍掉 ──"
    L "- id: tool-result-pruner"
    L "  config:"
    L ("    thresholdChars: " + $prun.thresholdChars)
    L ("    headChars: " + $prun.headChars)
    L ("    tailChars: " + $prun.tailChars)
}

# 4.4 角色模式
$personaPath = Join-Path $repo ($role.personaFile -replace '/', '\')
$suffixPath  = Join-Path $repo ($role.fallbackSuffixFile -replace '/', '\')
$personaText = if (Test-Path $personaPath) { (Get-Content $personaPath -Raw -Encoding UTF8).TrimEnd() } else { $null }
$suffixText  = if (Test-Path $suffixPath)  { (Get-Content $suffixPath  -Raw -Encoding UTF8).TrimEnd() } else { $null }

$usePreset = ($role.enabled -and $hasPersona -and $hasPreset -and $personaText)

if ($usePreset) {
    L ""
    L "# ── 角色扮演 preset：用 dsh-persona complete:true 整体替换系统提示 ──"
    L "- insert:"
    L ("    - id: preset-" + $role.presetId)
    L "      name: '@deepseek-ai/dsh-agent-preset'"
    L "      config:"
    L ("        id: " + $role.presetId)
    L ("        name: " + $role.presetName)
    L "        description: 只有人设与上下文压缩，没有任何编码工具与助手引导"
    L "        order: 0"
    L "        plugins:"
    L "          - id: persona"
    L "            name: '@deepseek-ai/dsh-persona'"
    L "            config:"
    L "              complete: true"
    L "              includeRuntimeContext: false"
    L "              prefix: |"
    foreach ($line in ($personaText -split "`r?`n")) {
        if ($line.Trim() -eq '') { L "" } else { L ("                " + $line) }
    }
    # AGENTS.md 加载器。**必须挂**：preset 的 plugins 是本 agent 完整的子插件集，
    # 不列它，工作区里的 AGENTS.md 就完全不会被读进提示词（角色会"不知道自己是谁"）。
    L "          - id: agent-instructions"
    L "            name: '@deepseek-ai/dsh-agent-instructions'"
    L "            config:"
    L "              maxBytes: 65536"
    # 隔离 tools 服务：角色会话不该有任何工具（包括全局装的那些），
    # 否则她会去调 lcm_grep 之类，剧情里冒出"查数据库"的动作。
    L "          - id: no-tools"
    L "            name: cordis:group"
    L "            group: true"
    L "            isolate:"
    L "              tools: true"
    L "            config: []"
    if ($comp -and $hasCompact) {
        L "          - id: compaction"
        L "            name: cordis:group"
        L "            group: true"
        L "            isolate:"
        L "              compaction: true"
        L "            config:"
        L "              - id: compaction-basic"
        L "                name: '@deepseek-ai/dsh-compaction-basic'"
        L "              - id: command-compact"
        L "                name: '@deepseek-ai/dsh-command-compact'"
    }
} elseif ($role.enabled -and $suffixText) {
    Warn "降级：用 personaSuffix 而不是 preset"
    L "# ── 角色模式（降级版）：只注入系统提示末尾一段 ──"
    L "- id: system-prompt"
    L "  config:"
    L "    personaPrefix: ''"
    L "    personaSuffix: |"
    foreach ($line in ($suffixText -split "`r?`n")) {
        if ($line.Trim() -eq '') { L "" } else { L ("      " + $line) }
    }
}

# ── 4.5 陪伴聊天 preset（独立的一套，给"夜聊"场景用）──────────────────────
$comp2 = $cfg.companion
if ($comp2 -and $comp2.enabled -and $hasPersona -and $hasPreset) {
    $cpPath = Join-Path $repo ($comp2.personaFile -replace '/', '\')
    $cpText = if (Test-Path $cpPath) { (Get-Content $cpPath -Raw -Encoding UTF8).TrimEnd() } else { $null }
    if ($cpText) {
        L ""
        L "# ── 陪伴聊天 preset：第一人称对话，不是叙事 ──"
        L "- insert:"
        L ("    - id: preset-" + $comp2.presetId)
        L "      name: '@deepseek-ai/dsh-agent-preset'"
        L "      config:"
        L ("        id: " + $comp2.presetId)
        L ("        name: " + $comp2.presetName)
        L ("        description: " + $comp2.presetDesc)
        L ("        order: " + $comp2.order)
        L "        plugins:"
        L "          - id: persona"
        L "            name: '@deepseek-ai/dsh-persona'"
        L "            config:"
        L "              complete: true"
        L "              includeRuntimeContext: false"
        L "              prefix: |"
        foreach ($line in ($cpText -split "`r?`n")) {
            if ($line.Trim() -eq '') { L "" } else { L ("                " + $line) }
        }
        L "          - id: agent-instructions"
        L "            name: '@deepseek-ai/dsh-agent-instructions'"
        L "            config:"
        L "              maxBytes: 65536"
        # 陪伴模式**不隔离 tools**：它要靠 lcm_* 检索过去两千轮，
        # 而 openseek-lcm 依赖全局的 tools / systemPrompt / sessionQuery / agents 四个服务，
        # 隔离任何一个都会让它卡在 "lcm waiting for tools"。
        # 这个模式本来就是聊天，多几个工具无所谓。
        if ($comp -and $hasCompact) {
            L "          - id: compaction"
            L "            name: cordis:group"
            L "            group: true"
            L "            isolate:"
            L "              compaction: true"
            L "            config:"
            L "              - id: compaction-basic"
            L "                name: '@deepseek-ai/dsh-compaction-basic'"
            L "              - id: command-compact"
            L "                name: '@deepseek-ai/dsh-command-compact'"
        }
    }
}

L ""
L $END

$block = $sb.ToString()

# ── 5. 写回 profile ────────────────────────────────────────────────────────
Step "5. 写入 profile 配置"
$original = [System.IO.File]::ReadAllText($patch, $utf8)
$existing = $original

# 删掉旧标记块（可能有多个历史版本）
$existing = [regex]::Replace($existing, '(?ms)^# === dsh-lossless-context BEGIN.*?^# === dsh-lossless-context END ===\s*', '')
$existing = [regex]::Replace($existing, '(?ms)^# === dsh-role-mode BEGIN.*?^# === dsh-role-mode END ===\s*', '')
$existing = [regex]::Replace($existing, '(?ms)^# === dsh-role-preset BEGIN.*?^# === dsh-role-preset END ===\s*', '')

# 删掉历史上散落的段落（没有标记的）
$sections = @(
    '(?ms)^- id: openseek-lcm\s*\n(?:[ \t]+.*\n|\s*\n)*',
    '(?ms)^- id: compaction-basic\s*\n(?:[ \t]+.*\n|\s*\n)*',
    '(?ms)^- id: tool-result-pruner\s*\n(?:[ \t]+.*\n|\s*\n)*',
    '(?ms)^- id: system-prompt\s*\n(?:[ \t]+.*\n|\s*\n)*'
)
foreach ($re in $sections) {
    $existing = [regex]::Replace($existing, $re, '')
}
# 清理连续空行
$existing = [regex]::Replace($existing, '(\r?\n){3,}', "`r`n`r`n")
$existing = $existing.TrimEnd()

$new = $existing + "`r`n`r`n" + $block

if ($DryRun) {
    Write-Host ""
    Write-Host "===== DryRun：下面是会写进 $patch 的内容 =====" -ForegroundColor Yellow
    Write-Host $block
    Write-Host "===== DryRun 结束 =====" -ForegroundColor Yellow
} else {
    # 内容没变就不写 —— 避免触发 DSH 热重载（重载会中断正在跑的会话）
    $normalized = $new -replace "`r`n", "`n"
    $current    = $original -replace "`r`n", "`n"
    # 只比较"去掉生成时间注释后"的部分
    $strip = { param($s) ($s -replace '(?m)^#\s+由 bootstrap\.ps1 根据 settings\.json 生成于.*\r?\n', '') }
    if ((& $strip $normalized) -eq (& $strip $current)) {
        Ok "配置没有变化，跳过写入（避免中断你当前的会话）"
    } else {
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        Copy-Item -LiteralPath $patch -Destination "$patch.bak-$stamp" -Force
        [System.IO.File]::WriteAllText($patch, $new, $utf8)
        Ok "已写入（旧版备份：cordis.patch.yml.bak-$stamp）"
        Info ("配置块 {0} 行" -f ($block -split "`n").Count)
        Warn "配置文件改了 —— DSH 可能重载 profile，当前会话可能中断，这是正常的。"
    }
}

# ── 6. 计划任务 ────────────────────────────────────────────────────────────
if (-not $SkipTasks -and -not $DryRun) {
    Step "6. 计划任务"
    $t = $cfg.tasks
    $scripts = Join-Path $repo 'scripts'
    $needTasks = @()
    foreach ($n in @('DSH-Auto-Snapshot','DSH-LCM-Snapshot','DSH-Daily-Backup')) {
        $q = & schtasks.exe /Query /TN $n /FO LIST 2>&1 | Out-String
        if ($q -notmatch 'Ready|Running|就绪|正在运行') { $needTasks += $n }
    }
    if ($needTasks.Count -eq 0) { Ok "三个任务都在" }
    else {
        Warn ("缺任务：{0}" -f ($needTasks -join ', '))
        Info "正在重建..."
        $ins = Join-Path $scripts 'install-tasks.ps1'
        $insp = Join-Path $scripts 'install-snapshot-task.ps1'
        if (Test-Path $ins) {
            & powershell -NoProfile -ExecutionPolicy Bypass -File $ins -DailyTime $t.backupDailyTime 2>&1 | ForEach-Object { Info $_ }
        }
        if (Test-Path $insp) {
            & powershell -NoProfile -ExecutionPolicy Bypass -File $insp -IntervalMinutes $t.snapshotIntervalMinutes 2>&1 | ForEach-Object { Info $_ }
        }
    }
}

# ── 7. 自检 ────────────────────────────────────────────────────────────────
if (-not $DryRun) {
    Step "7. 自检"
    $doctor = Join-Path $repo 'scripts\doctor.ps1'
    if (Test-Path $doctor) {
        & powershell -NoProfile -ExecutionPolicy Bypass -File $doctor -NoPause -Profile $profile 2>&1 |
            ForEach-Object { Write-Host "   $_" }
    }
}

# ── 结尾 ───────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host ("═" * 64)
if ($usePreset) {
    Write-Host "  完成。用的是完整 preset（系统提示整体替换）。" -ForegroundColor Green
} else {
    Write-Host "  完成，但***降级了***：当前 DSH 没有 dsh-persona / dsh-agent-preset。" -ForegroundColor Yellow
    Write-Host "  角色模式退化成'系统提示末尾加一段'，助手味可能压不干净。" -ForegroundColor Yellow
    Write-Host "  如果新版本换了别的机制，把这里的探测结果发给我，我改探测逻辑。" -ForegroundColor Yellow
}
Write-Host ("═" * 64)
Write-Host ""
Write-Host "下一步：完全退出并重新打开 DeepSeek Harness。" -ForegroundColor Cyan
Write-Host ""
if (-not $DryRun) { Read-Host "按回车关闭" | Out-Null }
