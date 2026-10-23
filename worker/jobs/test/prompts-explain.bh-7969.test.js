// BH-7969 (BH-7940.0): every hot prompt statement uses an index at volume.
// 20 projects x 7 kinds x 200 versions = 28,000 prompt_versions rows, plus one
// fleet head and one project head per kind and project (147 heads, the bound).
// The statements are the ones src/lib/prompt-store.js runs (exported as
// PROMPT_SQL), so the plan checked is the plan the worker gets.
import test from 'node:test';
import assert from 'node:assert/strict';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import { plan, fullScans } from './lib/d1-volume.bh-6727.js';
import { PROMPT_KINDS, PROMPT_SQL } from '../src/lib/prompt-store.js';

const AT = '2026-10-22T12:00:00Z';

test('BH-7969 prompt statements use an index at 28,000 rows', async (t) => {
  const opened = await openDb();
  if (opened === null) { t.skip('node:sqlite unavailable in this runtime'); return; }
  const { db } = opened;
  db.exec('BEGIN');
  for (let p = 0; p < 20; p++) {
    for (const kind of PROMPT_KINDS) {
      const vals = [];
      const binds = [];
      for (let v = 1; v <= 200; v++) {
        vals.push("('project',?,?,?,'b','a','',?)");
        binds.push(`p${p}-os`, kind, v, AT);
      }
      db.prepare(`INSERT INTO prompt_versions (scope,project,kind,version,body,author,note,created_at) VALUES ${vals.join(',')}`).run(...binds);
    }
  }
  for (const kind of PROMPT_KINDS) {
    db.prepare("INSERT INTO prompt_versions (scope,project,kind,version,body,author,note,created_at) VALUES ('fleet','',?,1,'b','a','',?)").run(kind, AT);
    db.prepare("INSERT INTO prompt_heads (scope,project,kind,version_id,set_by,set_at) SELECT 'fleet','',?,max(id),'a',? FROM prompt_versions WHERE scope='fleet' AND kind=?").run(kind, AT, kind);
    for (let p = 0; p < 20; p++) {
      db.prepare("INSERT INTO prompt_heads (scope,project,kind,version_id,set_by,set_at) SELECT 'project',?,?,max(id),'a',? FROM prompt_versions WHERE scope='project' AND project=? AND kind=?").run(`p${p}-os`, kind, AT, `p${p}-os`, kind);
    }
  }
  db.exec('COMMIT');
  db.exec('ANALYZE');
  assert.equal(db.prepare('SELECT count(*) AS n FROM prompt_versions').get().n, 28007);
  assert.equal(db.prepare('SELECT count(*) AS n FROM prompt_heads').get().n, 147);

  const cases = [
    ['listHeads', PROMPT_SQL.listHeads, ['p3-os']],
    ['readVersion', PROMPT_SQL.readVersion, ['project', 'p3-os', 'plan', 7]],
    ['insertNext', PROMPT_SQL.insertNext, ['project', 'p3-os', 'plan', 'b', 'a', '', AT]],
    ['insertOnBase', PROMPT_SQL.insertOnBase, ['project', 'p3-os', 'plan', 'b', 'a', '', AT, 200]],
    ['headUpsert', PROMPT_SQL.headUpsert, ['project', 'p3-os', 'plan']],
    ['versionById', PROMPT_SQL.versionById, [5]],
  ];
  for (const [name, sql, binds] of cases) {
    assert.equal(typeof sql, 'string', `${name} is exported`);
    const lines = plan(db, sql, ...binds);
    assert.ok(lines.length > 0, `${name}: no plan`);
    assert.deepEqual(fullScans(lines, ['prompt_versions', 'prompt_heads', 'h', 'v']), [], `${name} scans:\n${lines.join('\n')}`);
    const used = lines.some((l) => /USING (?:COVERING )?INDEX prompt_(versions|heads)_key|USING INTEGER PRIMARY KEY/.test(l));
    assert.ok(used, `${name} uses no prompt index:\n${lines.join('\n')}`);
  }
});
