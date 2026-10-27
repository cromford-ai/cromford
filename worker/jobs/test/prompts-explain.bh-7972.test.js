// BH-7972 (BH-7940.4): every prompt statement uses an index at volume.
// 20 projects x 7 kinds x 250 versions = 35,000 prompt_versions rows, plus one
// fleet version per kind, and 147 heads (the bound: (1 + projects) x 7).
// The statements are the exported texts the worker runs: PROMPT_SQL (the
// contract store), PROMPT_HISTORY_SQL (the history routes) and the
// prompt_versions.archive retention rule (ids, sel, del and the dry-run count).
import test from 'node:test';
import assert from 'node:assert/strict';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import { plan, fullScans } from './lib/d1-volume.bh-6727.js';
import { PROMPT_KINDS, PROMPT_SQL } from '../src/lib/prompt-store.js';
import { PROMPT_HISTORY_SQL } from '../src/routes/prompt-history.js';
import { RULES } from '../src/routes/retention.js';

const AT = '2026-09-01T12:00:00Z';
const CUT = '2026-09-27T12:00:00Z';
const INDEXED = /USING (?:COVERING )?INDEX prompt_(versions|heads)_key|USING INTEGER PRIMARY KEY/;

test('BH-7972 prompt statements use an index at 35,000 rows', async (t) => {
  const opened = await openDb();
  if (opened === null) { t.skip('node:sqlite unavailable in this runtime'); return; }
  const { db } = opened;
  db.exec('BEGIN');
  for (let p = 0; p < 20; p++) {
    for (const kind of PROMPT_KINDS) {
      const vals = [];
      const binds = [];
      for (let v = 1; v <= 250; v++) {
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
  assert.equal(db.prepare('SELECT count(*) AS n FROM prompt_versions').get().n, 35007);
  assert.equal(db.prepare('SELECT count(*) AS n FROM prompt_heads').get().n, 147);

  const rule = RULES.find((r) => r.rule === 'prompt_versions.archive');
  assert.ok(rule, 'the retention rule is registered');
  const ids = JSON.stringify([1, 2, 3]);

  // Route statements: a SEARCH on a prompt key or the rowid; never a SCAN.
  const routeCases = [
    ['listHeads', PROMPT_SQL.listHeads, ['p3-os']],
    ['readVersion', PROMPT_SQL.readVersion, ['project', 'p3-os', 'plan', 7]],
    ['insertNext', PROMPT_SQL.insertNext, ['project', 'p3-os', 'plan', 'b', 'a', '', AT]],
    ['insertOnBase', PROMPT_SQL.insertOnBase, ['project', 'p3-os', 'plan', 'b', 'a', '', AT, 250]],
    ['headUpsert', PROMPT_SQL.headUpsert, ['project', 'p3-os', 'plan']],
    ['versionById', PROMPT_SQL.versionById, [5]],
    ['listVersions', PROMPT_HISTORY_SQL.listVersions, ['project', 'p3-os', 'plan', 200]],
    ['maxVersion', PROMPT_HISTORY_SQL.maxVersion, ['project', 'p3-os', 'plan']],
    ['dropHead', PROMPT_HISTORY_SQL.dropHead, ['project', 'p3-os', 'plan']],
  ];
  assert.deepEqual(Object.keys(PROMPT_HISTORY_SQL).sort(), ['dropHead', 'listVersions', 'maxVersion'], 'every history statement is planned here');
  for (const [name, sql, binds] of routeCases) {
    assert.equal(typeof sql, 'string', `${name} is exported`);
    const lines = plan(db, sql, ...binds);
    assert.ok(lines.length > 0, `${name}: no plan`);
    assert.deepEqual(fullScans(lines, ['prompt_versions', 'prompt_heads', 'h', 'v']), [], `${name} scans:\n${lines.join('\n')}`);
    assert.ok(!lines.some((l) => /^SCAN (prompt_versions|v)\b/.test(l)), `${name} scans prompt_versions:\n${lines.join('\n')}`);
    assert.ok(lines.some((l) => INDEXED.test(l)), `${name} uses no prompt index:\n${lines.join('\n')}`);
  }

  // Retention: prompt_versions only through its key index (the per-run GROUP
  // BY may walk the covering index once) or the rowid. prompt_heads (147 rows,
  // bounded) may be scanned.
  const retentionCases = [
    ['rule.ids', rule.ids, [CUT, 500]],
    ['rule.dry-run-count', `SELECT COUNT(*) AS n FROM (${rule.ids})`, [CUT, 250001]],
    ['rule.sel', rule.sel, [ids]],
    ['rule.del', rule.del, [ids]],
  ];
  for (const [name, sql, binds] of retentionCases) {
    const lines = plan(db, sql, ...binds);
    assert.ok(lines.length > 0, `${name}: no plan`);
    const bare = lines.filter((l) => /^SCAN (prompt_versions|v|cut)\b/.test(l) && !/USING (COVERING )?INDEX prompt_versions_key/.test(l)
      && !/^SCAN cut$/.test(l));
    assert.deepEqual(bare, [], `${name} scans prompt_versions with no index:\n${lines.join('\n')}`);
    assert.ok(lines.some((l) => INDEXED.test(l)), `${name} uses no prompt index:\n${lines.join('\n')}`);
  }
  // The eligible rows at this volume: 50 per key (head on v250), so the ids
  // read is not vacuous.
  assert.equal(db.prepare(`SELECT COUNT(*) AS n FROM (${rule.ids})`).get(CUT, 250001).n, 20 * 7 * 50);
});
