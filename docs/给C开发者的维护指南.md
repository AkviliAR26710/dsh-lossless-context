# 给 C 开发者的维护指南

> 你是写 C 的。这套东西是 JS + PowerShell + YAML。**好消息：你 95% 的维护不需要写代码，只需要改数字。**
> 这份文档就是「改哪个数字 = 会发生什么」+「坏了怎么查」的对照表。

---

## 0. 先接受三个事实

1. **你不必读懂 JS 也能维护它。** 因为真正要动的都是 YAML 配置（数字和开关），脚本只是"把配置跑起来"。
2. **你不需要改 `openseek-lcm` 本身。** 那是别人写的 3000 行插件，你只在配置里指定参数。
3. **你的调试直觉完全通用。** `printf` → `Write-Host`；分段验证 → 一个环节一个环节测；看日志 → 看 `auto-snapshot.log`。

---

## 1. 概念对照表

| C 里的东西 | 这套东西里的对应物 | 说明 |
|---|---|---|
| `#define MAX_TOKENS 1048576` | `cordis.patch.yml` 里的 `thresholdRatio: 0.6` | **配置项 = 宏定义**，改它比改代码安全 |
| `main()` 里的顺序语句 | `.mjs` / `.ps1` 脚本 | 全是线性的，从上往下读就行 |
| `struct` + 字段 | JSON 对象 `{ "key": "value" }` | 无指针，无内存管理 |
| 回调函数 `register_handler(fn)` | `ctx.on('session/event', fn)` | 这就是事件驱动，跟你写 signal handler 一样 |
| `.o` 文件 + 链接 | `import` / 模块 | 类似 `#include`，但运行时解析 |
| `printf` 调试 | `Write-Host` / `console.log` | 完全一样 |
| `errno` + 返回码 | `[OK]/[WARN]/[FAIL]` + exit code | 自检脚本 exit code = 失败项数 |
| Makefile | 计划任务（schtasks） | 定时触发，不是依赖图 |
| 静态库 `.a` | `lcm.db`（SQLite） | 一个文件，有索引，能 `SELECT` |

**唯一真正陌生的两个概念：**

1. **异步（Promise / async/await）** —— 只在 3 个地方出现，而且是 `await call()` 这种"等它做完再继续"的写法，**读起来像同步代码**。
2. **YAML 缩进** —— 用空格，**绝对不能有 Tab**（跟 Python 一样）。这是最容易出错的地方。

---

## 2. 维护地图：想改什么，动哪里

### 2.1 调参数（90% 的维护是这个）

全部在 **`C:\Users\Mu\.dsh\profiles\desktop\cordis.patch.yml`**，改完重启 DSH 生效。

| 你想改 | 改哪个键 | 现在的值 | 改了会怎样 |
|---|---|---|---|
| 压缩更早 / 更晚 | `compaction-basic.thresholdRatio` | `0.6` | 调高=省 token 但容易撞窗口；调低=更频繁压缩、更贵 |
| 最近多少原文不压缩 | `compaction-basic.retainRatio` | `0.35` | 调高=更"记得刚才"但每轮更贵 |
| 压缩用哪个模型 | `compaction-basic.summarizationModel` | `deepseek-flash` | 换成 `deepseek-v4-pro` 更贵更好 |
| 工具输出截断长度 | `tool-result-pruner.thresholdChars` | `32000` | 调小=省 token 但可能丢中段信息 |
| 归档哪些内容 | `openseek-lcm.capture.includeToolResults` | `true` | 改 `false` 库会小很多，但查不到命令输出 |
| 暴露几个 lcm 工具 | `openseek-lcm.tools.expose` | 5 个 | 删掉 `expose` 整段 = 全部 18 个（更费 token） |
| 归档留多久 | `openseek-lcm.retention.deletedSessionDays` | `365` | — |

**算法**（这两个数字怎么配合，记这个就够）：

```
触发阈值 = min( 1048576 × thresholdRatio , (1048576 - 256000) - 24576 )
逐字保留 = (1048576 - 256000) × retainRatio
```

手算验证：

```powershell
$W=1048576; $O=256000; $r=0.6; $ret=0.35
$thr  = [Math]::Floor([Math]::Min($W*$r, ($W-$O)-24576))
$keep = [Math]::Floor(($W-$O)*$ret)
"阈值 $thr  /  逐字保留 $keep"
```

### 2.2 调存档频率

**`scripts\install-snapshot-task.ps1`** 里的 `-IntervalMinutes`（默认 10），以及 `auto-snapshot.mjs` 的 `--min-new`（默认 4 条 = 2 轮）。

改默认值：在 `auto-snapshot.ps1` 的 `param()` 块里改数字。

### 2.3 调备份策略

**`scripts\dsh-backup.ps1`** 的 `param()`：

```powershell
[int]$KeepDays = 14          # 保留几天
[int]$WaitIdleMinutes = 10   # 要求空闲多久
```

**`scripts\dsh-backup-idle.ps1`** 的四个判定（空闲/忙锁/会话安静/间隔），每个都是一行 `if`。

### 2.4 改角色的性格 / 记忆

**`C:\Users\Mu\Desktop\流萤\AGENTS.md`** —— 纯 Markdown，改完开新会话生效。

- 语气不对 → 只改 §0
- 忘事 → 改 §2
- 不像人 → 改 §4（口癖/动作/反应模式）
- 想出戏限制 → §5

### 2.5 你**永远不用碰**的东西

| 目录/文件 | 为什么不用碰 |
|---|---|
| `openseek-lcm\` 整个目录 | 第三方插件，配置够用 |
| `dsh-runtimes\` | DSH 自带的 node/python，别动 |
| `sessions\` | 会话原文，只读 |
| `app.asar` | DSH 本体 |

---

## 3. 三个 JS 脚本是干什么的（伪代码）

全部在 `C:\D\DeepSeek\` 和 `dsh-lossless-context\tools\`，**都是 100–200 行的线性脚本，没有一个类**。

### `resume-pack.mjs` —— 生成"接着聊"的恢复包

```
main:
    db = open(lcm.db, READONLY)
    sessions = SELECT session_id, count(*) FROM sessions JOIN messages
    target = sessions[0]              # 或者 --session 指定的
    rows = SELECT 最近 20 条 user/assistant 消息
    for each row:
        text = 从 info_json 里只取 type=="text" 的块   # 丢掉 reasoning 和 tool-call
        if 看起来像英文推理: skip
        print "【他】" 或 "【她】" + text
    print 包在 ```text 代码块里
```

**改它**：想多取几轮 → 改 `--turns`。想改输出格式 → 改最后那个 `lines.push()` 数组。

### `auto-snapshot.mjs` —— 定时存档 + 抽风检测

```
main:
    state = 读 JSON 状态文件（记录每个会话上次存到第几条）
    for each session:
        delta = 当前条数 - 上次记录
        if delta < MIN_NEW: continue          # 没新增，跳过
        取最近 N 轮纯文本（同 resume-pack）
        检查最近 4 条有没有"助手腔"正则        # 有就写警告到日志
        写到 snapshots/<工作目录>/<session>-<时间>.md
        滚动删除，只留 KEEP 份
    写回状态文件
```

**改它**：抽风检测的规则是 `ASSISTANT_SMELL` 那个正则数组，加一条正则就行。

### `lcm-inspect.mjs` —— 只读体检

```
main:
    db = open(READONLY)
    PRAGMA integrity_check
    统计各表行数
    对比 messages 与 message_fts 数量（不一致 = 索引坏了）
    打印表格
```

**改它**：想加个查询 → 学 `--sql` 参数，直接 `node lcm-inspect.mjs --sql "SELECT ..."`。

---

## 4. PowerShell 脚本是什么水平

**本质是批处理**，不是编程。看一个典型片段：

```powershell
$db = Join-Path $DshHome 'storages\dsh-plugin-lcm\lcm.db'
if (Test-Path $db) {
    $info = Get-Item $db
    $age = ((Get-Date) - $info.LastWriteTime).TotalHours
    if ($age -gt 48) { Warn "48 小时没写入" }
}
```

对应的 C：

```c
char *db = join(dsh_home, "storages/.../lcm.db");
if (access(db, F_OK) == 0) {
    time_t age_h = hours_since(stat_mtime(db));
    if (age_h > 48) warn("48 小时没写入");
}
```

**一一对应。** 唯一要注意：

- 变量以 `$` 开头
- 字符串用 `"双引号"`（会插值）或 `'单引号'`（不插值）
- 判断用 `-eq` `-gt` `-lt`，不是 `==` `>` `<`
- **脚本必须存成 UTF-8 with BOM**，否则中文注释会让 PowerShell 5.1 解析出错（这个坑我踩过）

---

## 5. 坏了怎么查（你的调试思路直接用）

### 第一步：跑自检

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File C:\D\DeepSeek\dsh-lossless-context\scripts\doctor.ps1
```

或者双击桌面 `DSH-恢复工具\自检.cmd`。

它按 **8 个环节**顺序检查，每个环节打印 `[OK]` / `[WARN]` / `[FAIL]` + 一句话建议。**先看第一个 FAIL**，后面的往往是它的连锁反应。

### 第二步：定位到"哪一层"

```
第 3 层  AGENTS.md（角色）      ← 语气/记忆不对
第 2 层  压缩（compaction）     ← 上下文爆、钱花太快
第 1 层  归档（lcm.db）         ← 搜不到原文
```

| 现象 | 最可能坏在哪 | 怎么验证 |
|---|---|---|
| 语气变助手腔 | preset 没选中 / 系统提示 | 设置→通用→默认 preset |
| 忘事 | AGENTS.md / 归档 | `node lcm-inspect.mjs --show "关键词"` |
| 上下文爆 | 压缩参数 | 手算阈值，对比面板占用 |
| 搜不到原文 | FTS 索引 | `/lcm doctor apply` |
| 存档不动 | 计划任务 | `schtasks /Query /TN "DSH-Auto-Snapshot" /FO LIST` |
| DSH 起不来 | YAML 语法 | 看 `.bak` 备份，复制回去 |

### 第三步：看日志（相当于看 stderr）

```powershell
# 存档日志（含抽风警告）
Get-Content "$env:USERPROFILE\Documents\dsh-backup\snapshots\auto-snapshot.log" -Encoding UTF8 -Tail 30

# 备份调度日志
Get-Content "$env:USERPROFILE\Documents\dsh-backup\idle-scheduler.log" -Encoding UTF8 -Tail 30
```

### 第四步：直接查数据库（相当于 gdb）

```powershell
$node = "$env:USERPROFILE\.dsh\dsh-runtimes\dsh-primary-runtime\dependencies\node\bin\node.exe"

# 表结构
& $node C:\D\DeepSeek\dsh-lossless-context\tools\lcm-inspect.mjs --sql "SELECT name FROM sqlite_master WHERE type='table'"

# 某会话最近 10 条
& $node C:\D\DeepSeek\dsh-lossless-context\tools\lcm-inspect.mjs --sql "SELECT seq, role, substr(text,1,80) FROM messages WHERE session_id LIKE 'session-c4a%' ORDER BY seq DESC LIMIT 10"

# 绕过 FTS 直接搜原文（判断"没归档"还是"索引坏了"）
& $node C:\D\DeepSeek\dsh-lossless-context\tools\lcm-inspect.mjs --show "关键词"
```

**⚠ 只读**：`lcm-inspect.mjs` 用 `readOnly: true` 打开，写操作会被拒绝。改库要用 DSH 里的 `/lcm` 命令。

---

## 6. 出问题先备份，再动手

**改任何配置之前**：

```powershell
Copy-Item "$env:USERPROFILE\.dsh\profiles\desktop\cordis.patch.yml" `
          "$env:USERPROFILE\.dsh\profiles\desktop\cordis.patch.yml.bak-$(Get-Date -f yyyyMMdd-HHmmss)"
```

**改回来**：

```powershell
Copy-Item (Get-ChildItem "$env:USERPROFILE\.dsh\profiles\desktop\cordis.patch.yml.bak-*" | Sort-Object Name -Descending | Select-Object -First 1).FullName `
          "$env:USERPROFILE\.dsh\profiles\desktop\cordis.patch.yml"
```

**记住：DSH 的会话原文在 `sessions\` 里，改配置改不坏它。最坏情况就是恢复配置 + 重启。**

---

## 7. 想真改代码时的学习路径（按需）

| 想改什么 | 要学 | 需要多久 |
|---|---|---|
| 改存档/恢复包的输出格式 | 只看 `lines.push()` 那几行 | 10 分钟 |
| 加一条抽风检测规则 | 正则表达式 + 数组加一项 | 10 分钟 |
| 写个新脚本（比如导出成 JSON） | 抄 `lcm-inspect.mjs` 的结构改 | 1 小时 |
| 改 `openseek-lcm` 插件本身 | Node.js + Cordis 插件 API | **不建议**，3000 行，没必要 |
| 给 DSH 写新插件 | Cordis + TypeScript | 几天，但你已经不需要 |

**JS 对 C 开发者最反直觉的三点**：

1. **没有类型**，`1 + "1"` = `"11"`（字符串拼接）。
2. **`const` 只是不能重新赋值**，对象内容还能改（像 `const int *p` 但能改指向的内容）。
3. **`==` 会做类型转换**，永远用 `===`。

---

## 8. 一句话

> **你维护的不是代码，是一组数字和一份 Markdown。**
> 数字在 `cordis.patch.yml`，人格在 `AGENTS.md`，出问题跑 `doctor.ps1`。
> 真正的代码（JS/PS）只有在"想加新功能"时才需要动，而那时候可以照抄现有的。

---

## 附：全部文件的作用

```
C:\D\DeepSeek\
├── 恢复指南.md                    # 挂了怎么恢复（人读）
├── 恢复包.mjs / resume-pack.mjs   # 生成恢复包（工具）
├── auto-snapshot.mjs              # 自动存档（工具）
├── clean-agents.ps1               # 清 AGENTS.md 里的 base64 垃圾
├── install-role-preset.ps1        # 装/卸角色扮演 preset
├── install-role-mode.ps1          # 装/卸系统提示补丁
├── 角色扮演preset.yml             # preset 定义（可读可改）
├── 工具\*.cmd                     # 双击工具
└── dsh-lossless-context\          # 开源仓库（同内容的整理版）
    ├── patches\                   # 配置模板
    ├── scripts\                   # 安装/备份/自检脚本
    ├── tools\                     # 3 个 node 工具
    ├── tests\                     # 验收 + 成本模型
    └── docs\                      # 深入原理 / 维护手册 / 恢复指南

C:\Users\Mu\.dsh\                   # DSH 自己的目录
├── profiles\desktop\
│   ├── cordis.patch.yml           # ★ 所有参数在这里
│   └── node_modules\openseek-lcm\ # 插件（别动）
├── storages\dsh-plugin-lcm\lcm.db # ★ 归档数据库
└── sessions\                      # ★ 会话原文（唯一不可再生）

C:\Users\Mu\Desktop\流萤\AGENTS.md  # ★ 她的人格与记忆
```
