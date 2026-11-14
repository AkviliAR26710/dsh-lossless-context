#!/usr/bin/env node
/**
 * 清理 lcm 归档里「磁盘上已经没有的会话」。
 *
 * 安全策略：
 *   1. 先把这些会话的原文导出成 Markdown（默认到 <repo>/导出/），确认写成功了才删
 *   2. 备份 lcm.db
 *   3. 级联删除 messages / message_fts / artifacts / artifact_fts /
 *      summary_nodes / summary_fts / summary_edges / events / resumes / sessions
 *   4. --dry-run 只看不动
 *
 * 默认**不动** session-imported-*（那是刻意导入的）。
 *
 * 用法：
 *   node tools/prune-orphans.mjs --dry-run
 *   node tools/prune-orphans.mjs --export-dir "D:\备份"
 */
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { DatabaseSync } from 'node:sqlite';

const argv = process.argv.slice(2);
const argOf = (n, d) => { const i = argv.indexOf(`--${n}`); return i >= 0 && argv[i + 1] ? argv[i + 1] : d; };
const DRY = argv.includes('--dry-run');

const HOME = os.homedir();
const DB = argOf('db', path.join(HOME, '.dsh', 'storages', 'dsh-plugin-lcm', 'lcm.db'));
const SESS = path.join(HOME, '.dsh', 'sessions');
const EXPORT_DIR = argOf('export-dir', path.join(process.cwd(), '导出'));

if (!fs.existsSync(DB)) { console.error('找不到 ' + DB); process.exit(1); }

// 磁盘上的会话
const onDisk = new Set();
for (const d of fs.readdirSync(SESS, { withFileTypes: true })) {
  if (!d.isDirectory()) continue;
  for (const s of fs.readdirSync(path.join(SESS, d.name), { withFileTypes: true })) {
    if (s.isDirectory()) onDisk.add(s.name);
  }
}

const db = new DatabaseSync(DB);
db.exec('PRAGMA busy_timeout = 10000');

const all = db.prepare('select session_id, title, cwd, created_at from sessions').all();
const orphans = all.filter((r) => !r.session_id.startsWith('session-imported-') && !onDisk.has(r.session_id));

if (!orphans.length) { console.log('没有孤儿会话，归档已经是干净的。'); db.close(); process.exit(0); }

// ── 1. 导出 ────────────────────────────────────────────────────────────────
const stamp = new Date().toISOString().replace(/[-:T]/g, '').slice(0, 12);
const outDir = path.join(EXPORT_DIR, `孤儿会话-${stamp}`);
if (!DRY) fs.mkdirSync(outDir, { recursive: true });

let exported = 0;
const summary = [];
for (const s of orphans) {
  const msgs = db.prepare(`
    select seq, role, created_at, text from messages
     where session_id = ? and deleted_at is null and length(text) > 0
     order by seq
  `).all(s.session_id);
  if (!msgs.length) { summary.push(`- ${s.session_id}  (0 条，跳过导出)`); continue; }

  const lines = [
    `# ${s.title || '(无标题)'}`,
    '',
    `- 会话：\`${s.session_id}\``,
    `- 目录：\`${s.cwd ?? '未知'}\``,
    `- 消息：${msgs.length} 条`,
    `- 导出于：${new Date().toLocaleString('zh-CN')}`,
    '',
    '---',
    '',
  ];
  for (const m of msgs) {
    lines.push(`**${m.role === 'user' ? '我' : '她'}**：`, '', m.text.trim(), '', '---', '');
  }
  const safe = `${(s.title || 'untitled').replace(/[\\/:*?"<>|]/g, '_').slice(0, 40)}-${s.session_id.slice(8, 20)}.md`;
  if (!DRY) fs.writeFileSync(path.join(outDir, safe), lines.join('\n'), 'utf8');
  exported++;
  summary.push(`- ${s.session_id}  ${String(msgs.length).padStart(4)} 条  → ${safe}`);
}

console.log(`孤儿会话：${orphans.length} 个`);
if (DRY) {
  console.log('[DRY] 将会导出到：' + outDir);
} else {
  console.log(`已导出 ${exported} 个到：${outDir}`);
}
for (const s of summary) console.log('  ' + s);

if (DRY) {
  const ids = orphans.map((o) => o.session_id);
  const ph = ids.map(() => '?').join(',');
  for (const t of ['messages', 'artifacts', 'summary_nodes', 'summary_edges', 'events', 'resumes']) {
    try {
      const n = db.prepare(`select count(*) n from ${t} where session_id in (${ph})`).get(...ids).n;
      console.log(`  [DRY] 将删除 ${t.padEnd(14)} ${n} 行`);
    } catch {}
  }
  db.close();
  process.exit(0);
}

// ── 2. 备份 ────────────────────────────────────────────────────────────────
const bak = `${DB}.bak-prune-${stamp}`;
fs.copyFileSync(DB, bak);
console.log(`\n已备份：${bak}`);

// ── 3. 级联删除 ────────────────────────────────────────────────────────────
const ids = orphans.map((o) => o.session_id);
const ph = ids.map(() => '?').join(',');
let removed = 0;
db.exec('BEGIN');
try {
  const del = (sql) => { const r = db.prepare(sql).run(...ids); removed += r.changes; return r.changes; };
  // FTS 在前，内容表在后
  try { del(`delete from message_fts   where session_id in (${ph})`); } catch {}
  try { del(`delete from artifact_fts  where session_id in (${ph})`); } catch {}
  try { del(`delete from summary_fts   where session_id in (${ph})`); } catch {}
  try { del(`delete from artifacts     where session_id in (${ph})`); } catch {}
  try { del(`delete from summary_edges where session_id in (${ph})`); } catch {}
  try { del(`delete from summary_nodes where session_id in (${ph})`); } catch {}
  try { del(`delete from summary_state where session_id in (${ph})`); } catch {}
  try { del(`delete from events        where session_id in (${ph})`); } catch {}
  try { del(`delete from resumes       where session_id in (${ph})`); } catch {}
  del(`delete from messages where session_id in (${ph})`);
  del(`delete from sessions where session_id in (${ph})`);
  db.exec('COMMIT');
} catch (e) {
  db.exec('ROLLBACK');
  console.error('删除失败，已回滚：', e.message);
  process.exit(1);
}

console.log(`\n已删除 ${orphans.length} 个会话，共 ${removed} 行。`);
const left = db.prepare('select count(*) n from sessions').get().n;
const leftMsg = db.prepare('select count(*) n from messages').get().n;
console.log(`剩余：${left} 个会话 / ${leftMsg} 条消息`);
db.exec('VACUUM');
console.log('已 VACUUM 回收空间。');
db.close();
