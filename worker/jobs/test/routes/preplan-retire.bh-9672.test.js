import test from 'node:test';
import assert from 'node:assert/strict';
import { DatabaseSync } from 'node:sqlite';
import { call, sqlOf } from '../lib/harness.js';
import worker from '../../src/index.js';
import { jobsSchemaSql } from '../lib/jobs-schema.js';

// BH-9672 — POST /api/preplans/retire. The plan thread gate refused a pre-plan
// and the coordination DB row stayed, so the next build adopted the same row
// and ended PLAN_STALE again (BH-8841 four times). The route deletes the row,
// guarded by the refused plan's stamp: a pre-plan published after the refused
// one (a newer thread_at) survives.

const body = (over) => ({ project: 'cromford', ticket_key: 'BH-9672', thread_at_max: '2026-11-10T21:00:00Z', ...over });
const deletes = (db) => sqlOf(db, /DELETE FROM preplans WHERE project=\?1 AND ticket_key=\?2/);

test('W1: no bearer is 401 and nothing is deleted', async () => {
  const r = await call('/api/preplans/retire', { method: 'POST', secret: null, body: body() });
  assert.equal(r.status, 401);
});

test('W2: a bad project, key or thread_at_max is 400 and no DELETE is issued', async () => {
  for (const over of [
    { project: 'bad project/..' }, { ticket_key: '' }, { ticket_key: 'BH 1;drop' },
    { thread_at_max: undefined }, { thread_at_max: '' }, { thread_at_max: '2026-11-10 21:00:00' },
    { thread_at_max: '2026-11-10T21:00:00.123Z' }, { thread_at_max: 'yesterday' },
  ]) {
    const r = await call('/api/preplans/retire', { method: 'POST', body: body(over) });
    assert.equal(r.status, 400, `expected 400 for ${JSON.stringify(over)}`);
    assert.equal(deletes(r.db).length, 0, `a DELETE ran for ${JSON.stringify(over)}`);
  }
});

test('W3: the guarded DELETE binds [project, key, thread_at_max] and answers {retired}', async () => {
  const r = await call('/api/preplans/retire', { method: 'POST', body: body() });
  assert.equal(r.status, 200);
  const d = deletes(r.db);
  assert.equal(d.length, 1);
  assert.match(d[0].sql, /\(thread_at IS NULL OR thread_at <= \?3\)/);
  assert.deepEqual(d[0].binds, ['cromford', 'BH-9672', '2026-11-10T21:00:00Z']);
  assert.equal(typeof r.body.retired, 'number');
});

// A D1-shaped facade over node:sqlite (the boxes-self-report pattern).
function sqliteDB(db) {
  const prepare = (sql) => {
    const bindAndRun = (binds) => ({
      first: async () => db.prepare(sql).get(...binds) ?? null,
      all: async () => ({ results: db.prepare(sql).all(...binds) }),
      run: async () => {
        const r = db.prepare(sql).run(...binds);
        return { meta: { changes: Number(r.changes) || 0, last_row_id: Number(r.lastInsertRowid) || 0 } };
      },
    });
    return { ...bindAndRun([]), bind: (...binds) => bindAndRun(binds) };
  };
  const batch = async (stmts) => { const out = []; for (const s of stmts) out.push(await s.run()); return out; };
  return { prepare, batch };
}
const SECRET = 'test-secret';
async function retire(d1, b) {
  const req = new Request('https://jobs.test/api/preplans/retire', {
    method: 'POST', headers: { 'content-type': 'application/json', authorization: `Bearer ${SECRET}` },
    body: JSON.stringify(b),
  });
  const res = await worker.fetch(req, { DB: d1, HARNESS_SECRET: SECRET });
  return { status: res.status, body: await res.json().catch(() => null) };
}
function freshDB() {
  const db = new DatabaseSync(':memory:');
  db.exec(jobsSchemaSql());
  db.exec('ALTER TABLE preplans ADD COLUMN thread_at TEXT');
  return { db, d1: sqliteDB(db) };
}
const seed = (db, project, key, threadAt) => db.prepare(
  `INSERT INTO preplans (project, ticket_key, base_sha, plan_md, created_at, updated_at, thread_at)
   VALUES (?,?,?,?,?,?,?)`).run(project, key, 'abc1234', '# plan', '2026-11-10T20:00:00Z', '2026-11-10T20:00:00Z', threadAt);
const has = (db, project, key) => !!db.prepare('SELECT 1 FROM preplans WHERE project=? AND ticket_key=?').get(project, key);

test('W4: real rows — older and NULL thread_at go, newer and other tickets stay', async () => {
  const { db, d1 } = freshDB();
  seed(db, 'cromford', 'BH-1', '2026-11-10T20:59:59Z');
  seed(db, 'cromford', 'BH-2', null);
  seed(db, 'cromford', 'BH-3', '2026-11-10T21:00:01Z');
  seed(db, 'cromford', 'BH-4', '2026-11-10T20:00:00Z');
  seed(db, 'project-3', 'BH-1', '2026-11-10T20:00:00Z');
  const a = await retire(d1, body({ ticket_key: 'BH-1' }));
  assert.equal(a.status, 200); assert.equal(a.body.retired, 1);
  assert.equal(has(db, 'cromford', 'BH-1'), false);
  assert.equal(has(db, 'project-3', 'BH-1'), true, 'another project row was deleted');
  const b = await retire(d1, body({ ticket_key: 'BH-2' }));
  assert.equal(b.body.retired, 1);
  assert.equal(has(db, 'cromford', 'BH-2'), false, 'a NULL thread_at row survived');
  const c = await retire(d1, body({ ticket_key: 'BH-3' }));
  assert.equal(c.body.retired, 0);
  assert.equal(has(db, 'cromford', 'BH-3'), true, 'a newer pre-plan was deleted');
  assert.equal(has(db, 'cromford', 'BH-4'), true, 'another ticket row was deleted');
  const again = await retire(d1, body({ ticket_key: 'BH-1' }));
  assert.equal(again.body.retired, 0);
});

test('W5: EXPLAIN QUERY PLAN of the DELETE uses the primary key at 5,000 rows', async () => {
  const { PREPLAN_RETIRE_SQL } = await import('../../src/routes/preplan-retire.js');
  const { db } = freshDB();
  const ins = db.prepare(`INSERT INTO preplans (project, ticket_key, base_sha, plan_md, created_at, updated_at, thread_at)
    VALUES (?,?,?,?,?,?,?)`);
  db.exec('BEGIN');
  for (let i = 0; i < 5000; i++) ins.run(`p${i % 20}`, `BH-${i}`, 'abc1234', '# plan', '2026-11-10T20:00:00Z', '2026-11-10T20:00:00Z', '2026-11-10T20:00:00Z');
  db.exec('COMMIT');
  db.exec('ANALYZE');
  const plan = db.prepare(`EXPLAIN QUERY PLAN ${PREPLAN_RETIRE_SQL}`).all('p1', 'BH-21', '2026-11-10T21:00:00Z')
    .map((r) => r.detail).join('\n');
  assert.match(plan, /sqlite_autoindex_preplans_1/);
  assert.doesNotMatch(plan, /SCAN preplans/);
});
