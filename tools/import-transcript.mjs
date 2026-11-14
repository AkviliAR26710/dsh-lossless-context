#!/usr/bin/env node
/**
 * 把一份 Markdown 对话记录导入 lcm 归档，让新的会话能检索到它。
 *
 * 干什么：
 *   1. 备份 lcm.db
 *   2. 解析 md（**我说：** / **DeepSeek说：** 分隔）
 *   3. 新建一个 session（cwd 指向目标工作区）
 *   4. 逐条写入 messages + message_fts
 *
 * 不改任何现有数据，只追加。
 *
 * 用法：
 *   node tools/import-transcript.mjs --file "对话.md" --cwd "C:\path\to\workspace"
 *   node tools/import-transcript.mjs --file "x.md" --cwd "..." --title "标题" --dry-run
 */
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import crypto from 'node:crypto';
import { DatabaseSync } from 'node:sqlite';

const argv = process.argv.slice(2);
const argOf = (n, d) => { const i = argv.indexOf(`--${n}`); return i >= 0 && argv[i + 1] ? argv[i + 1] : d; };
const flag = (n) => argv.includes(`--${n}`);

const DSH_HOME = process.env.DSH_HOME ?? path.join(os.homedir(), '.dsh');
const DB = argOf('db', path.join(DSH_HOME, 'storages', 'dsh-plugin-lcm', 'lcm.db'));
const FILE = argOf('file', null);
const CWD = argOf('cwd', process.cwd());
const TITLE = argOf('title', '导入的对话');
const DRY = flag('dry-run');
const START = argOf('start', '2025-12-01T21:00:00+08:00');
const STEP_HOURS = Number(argOf('step-hours', 8));

if (!FILE || !fs.existsSync(FILE)) { console.error('缺 --file 或文件不存在'); process.exit(1); }
if (!fs.existsSync(DB)) { console.error('找不到 lcm.db: ' + DB); process.exit(1); }

// ── 解析 ───────────────────────────────────────────────────────────────────
const raw = fs.readFileSync(FILE, 'utf8');
const lines = raw.split('\n');
const items = [];
let cur = null, kind = null;
for (const line of lines) {
  const s = line.trim();
  if (s === '**我说：**') { cur = []; kind = 'user'; items.push({ k: kind, a: cur }); continue; }
  if (s === '**DeepSeek说：**') { cur = []; kind = 'assistant'; items.push({ k: kind, a: cur }); continue; }
  if (cur && s && s !== '---') cur.push(line);
}
const msgs = items
  .map((it) => ({ role: it.k, text: it.a.join('\n').trim() }))
  .filter((m) => m.text.length > 0);

console.log(`解析到 ${msgs.length} 条消息（user ${msgs.filter(m=>m.role==='user').length} / assistant ${msgs.filter(m=>m.role==='assistant').length}）`);
if (!msgs.length) process.exit(1);

// ── 时间线：从 START 开始，每 STEP_HOURS 小时一条 ──────────────────────────
const base = new Date(START).getTime();
const stamp = (i) => base + i * STEP_HOURS * 3600_000;

const sessionId = 'session-imported-' + crypto.randomBytes(6).toString('hex');
const worktreeKey = path.resolve(CWD).replace(/\\/g, '/').toLowerCase();

if (DRY) {
  console.log(`\n[DRY] session_id  = ${sessionId}`);
  console.log(`[DRY] cwd         = ${CWD}`);
  console.log(`[DRY] worktree    = ${worktreeKey}`);
  console.log(`[DRY] 首条时间    = ${new Date(stamp(0)).toLocaleString('zh-CN')}`);
  console.log(`[DRY] 末条时间    = ${new Date(stamp(msgs.length - 1)).toLocaleString('zh-CN')}`);
  console.log(`\n[DRY] 前 2 条：`);
  for (const m of msgs.slice(0, 2)) console.log(`  [${m.role}] ${m.text.slice(0, 100).replace(/\n/g, ' ')}`);
  process.exit(0);
}

// ── 备份 ───────────────────────────────────────────────────────────────────
const backup = `${DB}.bak-import-${new Date().toISOString().replace(/[-:T]/g, '').slice(0, 14)}`;
fs.copyFileSync(DB, backup);
console.log(`已备份归档：${backup}`);

// ── 写入 ───────────────────────────────────────────────────────────────────
const db = new DatabaseSync(DB);
db.exec('PRAGMA busy_timeout = 10000');

const now = Date.now();
db.prepare(`
  insert into sessions (session_id, title, cwd, worktree_key, parent_session_id, root_session_id,
                        lineage_depth, pinned, created_at, updated_at, deleted, event_count, watermark_seq)
  values (?, ?, ?, ?, null, ?, 0, 0, ?, ?, 0, ?, ?)
`).run(sessionId, TITLE, CWD, worktreeKey, sessionId, stamp(0), stamp(msgs.length - 1), msgs.length, msgs.length);

const insMsg = db.prepare(`
  insert into messages (message_id, session_id, seq, role, created_at, deleted_at, info_json, text)
  values (?, ?, ?, ?, ?, null, ?, ?)
`);
const insFts = db.prepare(`
  insert into message_fts (session_id, message_id, role, created_at, content)
  values (?, ?, ?, ?, ?)
`);

let n = 0;
db.exec('BEGIN');
try {
  for (let i = 0; i < msgs.length; i++) {
    const m = msgs[i];
    const id = crypto.randomUUID();
    const seq = i + 1;
    const ts = stamp(i);
    const info = JSON.stringify({
      id,
      role: m.role,
      seq,
      createdAt: ts,
      source: 'transcript-import',
      content: [{ type: 'text', text: m.text }],
    });
    insMsg.run(id, sessionId, seq, m.role, ts, info, m.text);
    insFts.run(sessionId, id, m.role, ts, m.text);
    n++;
  }
  db.exec('COMMIT');
} catch (e) {
  db.exec('ROLLBACK');
  console.error('导入失败，已回滚：', e.message);
  process.exit(1);
}

// 校验
const c1 = db.prepare('select count(*) n from messages where session_id = ?').get(sessionId).n;
const c2 = db.prepare('select count(*) n from message_fts where session_id = ?').get(sessionId).n;
db.close();

console.log(`\n导入完成：${n} 条`);
console.log(`  messages      ${c1}`);
console.log(`  message_fts   ${c2}`);
console.log(`  session_id    ${sessionId}`);
console.log(`  cwd           ${CWD}`);
if (c1 !== c2) console.log('  ⚠ messages 与 FTS 数量不一致');
