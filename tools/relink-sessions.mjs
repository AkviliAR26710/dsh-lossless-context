#!/usr/bin/env node
/**
 * 把同一个工作目录下的会话挂成一条树（同一个 root），
 * 这样 lcm_grep --scope root 也能一次查到全部，不用再切 worktree。
 *
 * 做什么：
 *   1. 按 worktree_key 分组
 *   2. 每组选「最早创建」的那个当主根
 *   3. 其它会话：parent_session_id = 主根, root_session_id = 主根, lineage_depth = 1
 *
 * 只改 lcm.db 里的这三个字段，不动消息、不动 DSH 的会话文件。
 * 不改的话 scope=worktree 也能查到，只是 scope=root 查不到。
 *
 * 用法：
 *   node tools/relink-sessions.mjs            # 预览
 *   node tools/relink-sessions.mjs --yes      # 执行
 */
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { DatabaseSync } from 'node:sqlite';

const YES = process.argv.includes('--yes');
const DB = path.join(os.homedir(), '.dsh', 'storages', 'dsh-plugin-lcm', 'lcm.db');
if (!fs.existsSync(DB)) { console.error('找不到 lcm.db'); process.exit(1); }

const db = new DatabaseSync(DB);
db.exec('PRAGMA busy_timeout = 10000');

const rows = db.prepare(`
  select session_id, title, worktree_key, parent_session_id, root_session_id, lineage_depth, created_at
    from sessions order by created_at
`).all();

const groups = new Map();
for (const r of rows) {
  const key = r.worktree_key ?? '(none)';
  if (!groups.has(key)) groups.set(key, []);
  groups.get(key).push(r);
}

const plan = [];
for (const [key, list] of groups) {
  if (list.length < 2) continue;
  const rootSession = list[0]; // 最早的
  for (const s of list.slice(1)) {
    if (s.root_session_id === rootSession.session_id && s.lineage_depth === 1) continue;
    plan.push({ id: s.session_id, title: s.title, root: rootSession.session_id, depth: 1 });
  }
}

console.log(`工作目录共 ${groups.size} 个，需要改父链的会话 ${plan.length} 个：\n`);
for (const [key, list] of groups) {
  console.log(`■ ${key}`);
  const root = list[0];
  console.log(`   主根 ${root.session_id.slice(0, 30)}  ${new Date(root.created_at).toLocaleDateString('zh-CN')}  《${root.title ?? ''}》`);
  for (const s of list.slice(1)) {
    const mark = plan.some((p) => p.id === s.session_id) ? '  ← 将挂到主根下' : '  (已挂好)';
    console.log(`     └ ${s.session_id.slice(0, 28)}  《${s.title ?? ''}》${mark}`);
  }
  console.log();
}

if (!plan.length) { console.log('所有会话已经挂好了。'); db.close(); process.exit(0); }

if (!YES) {
  console.log('这是预览，什么都没改。确认后加 --yes。');
  db.close();
  process.exit(0);
}

const bak = `${DB}.bak-relink-${new Date().toISOString().replace(/[-:T]/g, '').slice(0, 12)}`;
fs.copyFileSync(DB, bak);
db.close();

const db2 = new DatabaseSync(DB);
db2.exec('PRAGMA busy_timeout = 10000');
const upd = db2.prepare('update sessions set parent_session_id = ?, root_session_id = ?, lineage_depth = ? where session_id = ?');
db2.exec('BEGIN');
try {
  for (const p of plan) upd.run(p.root, p.root, p.depth, p.id);
  db2.exec('COMMIT');
} catch (e) {
  db2.exec('ROLLBACK');
  console.error('失败，已回滚：', e.message);
  process.exit(1);
}

// 校验
console.log('\n=== 改完之后 ===');
const after = db2.prepare(`
  select coalesce(root_session_id, session_id) root, count(*) cnt
    from sessions group by root order by cnt desc
`).all();
for (const r of after) console.log(`  root ${String(r.root).slice(0, 34)}  ${r.cnt} 个会话`);
db2.close();
console.log(`\n已改 ${plan.length} 个会话（备份 ${path.basename(bak)}）`);
