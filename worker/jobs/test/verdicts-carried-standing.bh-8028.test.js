import test from 'node:test';
import assert from 'node:assert/strict';
import { DatabaseSync } from 'node:sqlite';
import worker from '../src/index.js';
import { jobsSchemaSql } from './lib/jobs-schema.js';

// BH-8028 — the conductor's patch-id REBOUND carries the lead word onto the
// rebased head B: bin/lib/lead-carry.sh posts a source=lead row on B whose
// note names the source verdict (`carried_from:#<id> reason:patch-id:<id>`).
// GET /api/verdicts&head=B must answer that row as the standing verdict, like
// any lead row (vd_standing, AUTOENQUEUE G3 and Mergify's lead-verdict all
// read it). A changed patch carries nothing, so nothing stands on B.
const SECRET = 'test-secret';
const LEAD = 'lead-test-token';
const SCHEMA = jobsSchemaSql();

function sqliteDB(db) {
  const bindAndRun = (sql, binds) => ({
    first: async (col) => {
      const row = db.prepare(sql).get(...binds) ?? null;
      return col ? (row ? row[col] : null) : row;
    },
    all: async () => ({ results: db.prepare(sql).all(...binds) }),
    run: async () => {
      const r = db.prepare(sql).run(...binds);
      return { meta: { changes: Number(r.changes) || 0, last_row_id: Number(r.lastInsertRowid) || 0 } };
    },
  });
  return {
    prepare: (sql) => ({ ...bindAndRun(sql, []), bind: (...b) => bindAndRun(sql, b.map((v) => (v === undefined ? null : v))) }),
    batch: async (stmts) => { const out = []; for (const s of stmts) out.push(await s.run()); return out; },
  };
}

const openDb = () => { const db = new DatabaseSync(':memory:'); db.exec(SCHEMA); return db; };
const A = 'a'.repeat(40);
const B = 'b'.repeat(40);
const REPO = 'example-org/cromford';
const PR = 8028;

const send = (db, path, method, body) => worker.fetch(new Request(`https://jobs.test${path}`, {
  method,
  headers: { authorization: `Bearer ${SECRET}`, 'content-type': 'application/json', 'x-lead-verdict-token': LEAD },
  body: body === undefined ? undefined : JSON.stringify(body),
}), { DB: sqliteDB(db), HARNESS_SECRET: SECRET, LEAD_VERDICT_TOKEN: LEAD })
  .then(async (res) => ({ status: res.status, body: await res.json().catch(() => null) }));
const postLead = (db, head, note) => send(db, '/api/verdicts', 'POST', { repo: REPO, pr: PR, head_sha: head, verdict: 'MERGE', source: 'lead', note });
const standing = (db, head) => send(db, `/api/verdicts?repo=${REPO}&pr=${PR}&head=${head}`, 'GET');

test('a carried lead MERGE on the rebased head stands like the original and names its source', async () => {
  const db = openDb();
  const a = await postLead(db, A, 'two nits');
  assert.equal(a.status, 201);
  const idA = a.body.verdict.id;
  const note = `lead-replay:${A.slice(0, 12)} how:patch-id ref:#${idA} by:merge-conductor carried_from:#${idA} reason:patch-id:${'c'.repeat(40)}`;
  assert.equal((await postLead(db, B, note)).status, 201);
  const got = await standing(db, B);
  assert.equal(got.status, 200);
  assert.equal(got.body.standing.verdict, 'MERGE');
  assert.equal(got.body.standing.source, 'lead');
  assert.equal(got.body.standing.head_sha, B);
  assert.ok(got.body.standing.note.includes(`carried_from:#${idA}`), got.body.standing.note);
});

test('a changed patch carries nothing: no row on B, nothing stands on B', async () => {
  const db = openDb();
  assert.equal((await postLead(db, A, 'ok')).status, 201);
  const got = await standing(db, B);
  assert.equal(got.status, 200);
  assert.equal(got.body.standing, null);
});
