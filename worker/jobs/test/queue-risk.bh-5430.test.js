import test from 'node:test';
import assert from 'node:assert/strict';
import { DatabaseSync } from 'node:sqlite';
import worker, { CREATED_TABLES } from '../src/index.js';
import { jobsSchemaSql } from './lib/jobs-schema.js';

// BH-5430 — the record of the merge-queue break-risk score, one row per scored
// PR head (schema.sql's queue_risk_scores block and its CREATED_TABLES copy).
// The writer is bin/lib/queue-risk.sh (qr_enqueue_step) on every enqueue in a
// mode other than off; the reader is Mission Control's MERGE QUEUE badge.
//
// Unlike risk_tiers (first classification kept), a re-enqueue of the same head
// under changed settings rows must show the NEW routing, so the same key is an
// update: 201 on the first write, 200 on every later one.
//
// Driven through worker.fetch against THE SQL THAT SHIPS (worker/jobs/schema.sql),
// the risk-tiers.bh-5022 idiom.
const SECRET = 'test-secret';
// The composition of worker/jobs/schema.d/ (BH-6005): schema.sql is a render.
const SCHEMA = jobsSchemaSql();

function sqliteDB(db) {
  const bindAndRun = (sql, binds) => ({
    first: async () => db.prepare(sql).get(...binds) ?? null,
    all: async () => ({ results: db.prepare(sql).all(...binds) }),
    run: async () => {
      const r = db.prepare(sql).run(...binds);
      return { meta: { changes: Number(r.changes) || 0, last_row_id: Number(r.lastInsertRowid) || 0 } };
    },
  });
  return {
    prepare: (sql) => ({ ...bindAndRun(sql, []), bind: (...b) => bindAndRun(sql, b.map((v) => (v === undefined ? null : v))) }),
  };
}

const fresh = () => { const db = new DatabaseSync(':memory:'); db.exec(SCHEMA); return { db, DB: sqliteDB(db) }; };

const call = (DB, path, { method = 'GET', body, bearer = true } = {}) => {
  const req = new Request(`https://jobs.test${path}`, {
    method,
    headers: { ...(bearer ? { authorization: `Bearer ${SECRET}` } : {}), 'content-type': 'application/json' },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
  });
  return worker.fetch(req, { DB, HARNESS_SECRET: SECRET })
    .then(async (res) => ({ status: res.status, body: await res.json().catch(() => null) }));
};

const REPO = 'example-org/cromford';
const H1 = 'a'.repeat(40);
const H2 = 'b'.repeat(40);
const H3 = 'c'.repeat(40);
// The exact body bin/lib/queue-risk.sh sends.
const SCORE = {
  repo: REPO, pr: 5430, head_sha: H1, project: 'cromford', score: 55, threshold: 50,
  route: 'solo', mode: 'enforce', reasons: 'shared_lib:+30(bin/lib/x.sh),registry:+25(catalog/y.tsv)',
};
const post = (DB, body) => call(DB, '/api/queue-risk', { method: 'POST', body });
// The worker stamps whole seconds (nowIso), so the clock is driven, not slept on:
// tick() moves every no-argument `new Date()` one second on.
const RealDate = Date;
let clock = RealDate.parse('2026-10-08T10:00:00Z');
globalThis.Date = class extends RealDate {
  constructor(...a) { if (a.length) super(...a); else super(clock); }
  static now() { return clock; }
};
const tick = () => { clock += 1000; };

test('W1. POST → 201; the same (repo, pr, head_sha) with a new score/route → 200 and the row holds the NEW values (upsert, not first-wins)', async () => {
  const { db, DB } = fresh();
  const a = await post(DB, SCORE);
  assert.equal(a.status, 201, JSON.stringify(a.body));
  assert.equal(a.body.ok, true);
  assert.ok(Number.isInteger(a.body.id) && a.body.id > 0);
  const before = db.prepare('SELECT * FROM queue_risk_scores').get();
  tick();
  const b = await post(DB, { ...SCORE, score: 30, threshold: 90, route: 'batch', mode: 'shadow', reasons: 'shared_lib:+30(bin/lib/x.sh)' });
  assert.equal(b.status, 200, JSON.stringify(b.body));
  assert.equal(b.body.ok, true);
  assert.equal(b.body.updated, true);
  const rows = db.prepare('SELECT * FROM queue_risk_scores').all();
  assert.equal(rows.length, 1, 'one row per (repo, pr, head_sha)');
  assert.equal(rows[0].score, 30);
  assert.equal(rows[0].threshold, 90);
  assert.equal(rows[0].route, 'batch');
  assert.equal(rows[0].mode, 'shadow');
  assert.equal(rows[0].reasons, 'shared_lib:+30(bin/lib/x.sh)');
  assert.equal(rows[0].created_at, before.created_at, 'created_at is the first write');
  assert.ok(rows[0].updated_at > before.updated_at, 'updated_at moves on the update');
  // The GET answers the new values.
  const g = await call(DB, `/api/queue-risk?repo=${REPO}&pr=5430`);
  assert.equal(g.status, 200, JSON.stringify(g.body));
  assert.equal(g.body.rows.length, 1);
  assert.equal(g.body.rows[0].route, 'batch');
  assert.equal(g.body.rows[0].score, 30);
  // A null score (files-unavailable) is accepted and stored as NULL.
  const n = await post(DB, { ...SCORE, head_sha: H2, score: null, route: 'batch', reasons: 'files-unavailable' });
  assert.equal(n.status, 201, JSON.stringify(n.body));
  assert.equal(db.prepare('SELECT score FROM queue_risk_scores WHERE head_sha=?').get(H2).score, null);
  // project and reasons are optional.
  const bare = await post(DB, { ...SCORE, head_sha: H3, project: undefined, reasons: undefined });
  assert.equal(bare.status, 201, JSON.stringify(bare.body));
});

test('W2. bad repo, pr, head_sha, route, mode, score, threshold, reasons, project → 400 naming the field, and nothing written', async () => {
  const { db, DB } = fresh();
  const cases = [
    ['repo', 'nope'], ['repo', undefined],
    ['pr', 0], ['pr', -3], ['pr', 'x'],
    ['head_sha', 'abc'], ['head_sha', undefined],
    ['route', 'fast'], ['route', undefined],
    ['mode', 'loud'], ['mode', undefined],
    ['score', -1], ['score', 10001], ['score', 5.5], ['score', '55'],
    ['threshold', undefined], ['threshold', 'x'], ['threshold', -1],
    ['reasons', 'r'.repeat(1001)], ['reasons', 7],
    ['project', 'bad project!'],
  ];
  for (const [k, v] of cases) {
    const res = await post(DB, { ...SCORE, [k]: v });
    assert.equal(res.status, 400, `${k}=${JSON.stringify(v)}: ${JSON.stringify(res.body)}`);
    assert.match(res.body.error, new RegExp(`^${k} `), `${k}=${JSON.stringify(v)}: the error names the field: ${res.body.error}`);
  }
  assert.equal(db.prepare('SELECT count(*) AS n FROM queue_risk_scores').get().n, 0, 'a refused POST lands nothing');
  // The edges are accepted.
  assert.equal((await post(DB, { ...SCORE, score: 0 })).status, 201);
  assert.equal((await post(DB, { ...SCORE, head_sha: H2, score: 10000 })).status, 201);
});

test('W3. GET: limit 0/201/junk → 400 (refused, not clamped); limit=1 over two rows → truncated; ?route= filters; newest updated_at first', async () => {
  const { DB } = fresh();
  assert.equal((await post(DB, { ...SCORE, pr: 1, head_sha: H1, route: 'solo' })).status, 201);
  tick();
  assert.equal((await post(DB, { ...SCORE, pr: 2, head_sha: H2, route: 'batch', score: 0 })).status, 201);
  tick();
  assert.equal((await post(DB, { ...SCORE, pr: 3, head_sha: H3, route: 'solo' })).status, 201);
  tick();
  // pr 1 is re-scored last, so it is now the newest by updated_at though its id is the oldest.
  assert.equal((await post(DB, { ...SCORE, pr: 1, head_sha: H1, route: 'solo', score: 70 })).status, 200);
  await post(DB, { ...SCORE, repo: 'example-org/other', pr: 9, head_sha: H1 });

  for (const l of ['0', '201', 'x', '-1', '1.5']) {
    const r = await call(DB, `/api/queue-risk?limit=${l}`);
    assert.equal(r.status, 400, `limit=${l}: ${JSON.stringify(r.body)}`);
    assert.match(r.body.error, /^limit /);
  }
  const all = await call(DB, `/api/queue-risk?repo=${REPO}`);
  assert.equal(all.status, 200, JSON.stringify(all.body));
  assert.deepEqual(all.body.rows.map((r) => r.pr), [1, 3, 2], 'newest updated_at first, not id order');
  assert.equal(all.body.truncated, false);
  const one = await call(DB, `/api/queue-risk?repo=${REPO}&limit=1`);
  assert.deepEqual(one.body.rows.map((r) => r.pr), [1]);
  assert.equal(one.body.truncated, true);
  const two = await call(DB, `/api/queue-risk?repo=${REPO}&limit=3`);
  assert.equal(two.body.truncated, false, 'exactly limit rows is not truncated');
  const solo = await call(DB, `/api/queue-risk?repo=${REPO}&route=solo`);
  assert.deepEqual(solo.body.rows.map((r) => r.pr), [1, 3]);
  const batch = await call(DB, '/api/queue-risk?route=batch');
  assert.deepEqual(batch.body.rows.map((r) => r.pr), [2]);
  const byPr = await call(DB, `/api/queue-risk?repo=${REPO}&pr=3`);
  assert.deepEqual(byPr.body.rows.map((r) => r.pr), [3]);
  assert.equal((await call(DB, '/api/queue-risk')).body.rows.length, 4, 'no filter: every repo');
  assert.equal((await call(DB, '/api/queue-risk?route=fast')).status, 400);
  assert.equal((await call(DB, '/api/queue-risk?repo=nope')).status, 400);
  assert.equal((await call(DB, '/api/queue-risk?pr=0')).status, 400);
  // Same updated_at: id DESC breaks the tie.
  const { DB: DB2, db: db2 } = fresh();
  const T = '2026-10-08T00:00:00.000Z';
  for (const [pr, h] of [[11, H1], [12, H2]]) {
    db2.prepare(`INSERT INTO queue_risk_scores (repo, pr, head_sha, score, threshold, route, mode, created_at, updated_at)
                 VALUES (?, ?, ?, 1, 50, 'batch', 'enforce', ?, ?)`).run(REPO, pr, h, T, T);
  }
  assert.deepEqual((await call(DB2, '/api/queue-risk')).body.rows.map((r) => r.pr), [12, 11]);
});

test('W4. no bearer → 401 on both POST and GET, and nothing written', async () => {
  const { db, DB } = fresh();
  const p = await call(DB, '/api/queue-risk', { method: 'POST', body: SCORE, bearer: false });
  assert.equal(p.status, 401, JSON.stringify(p.body));
  const g = await call(DB, '/api/queue-risk', { bearer: false });
  assert.equal(g.status, 401, JSON.stringify(g.body));
  assert.equal(db.prepare('SELECT count(*) AS n FROM queue_risk_scores').get().n, 0);
});

test('W5. on an EMPTY database the route self-creates queue_risk_scores (ensureTable), and CREATED_TABLES matches schema.sql column for column', async () => {
  const db = new DatabaseSync(':memory:');
  const DB = sqliteDB(db);
  const a = await post(DB, SCORE);
  assert.equal(a.status, 201, JSON.stringify(a.body));
  assert.equal(db.prepare('SELECT count(*) AS n FROM queue_risk_scores').get().n, 1);

  const block = SCHEMA.match(/CREATE TABLE IF NOT EXISTS queue_risk_scores[\s\S]*?\);(\s*CREATE INDEX IF NOT EXISTS idx_queue_risk_scores[^;]*;)+/);
  assert.ok(block, 'schema.sql has no queue_risk_scores block');
  assert.ok(Array.isArray(CREATED_TABLES.queue_risk_scores), 'CREATED_TABLES has no queue_risk_scores key');
  const s = new DatabaseSync(':memory:');
  s.exec(block[0]);
  const c = new DatabaseSync(':memory:');
  for (const stmt of CREATED_TABLES.queue_risk_scores) c.exec(stmt);
  const cols = (d) => d.prepare('PRAGMA table_info(queue_risk_scores)').all()
    .map(({ name, type, notnull, dflt_value, pk }) => ({ name, type, notnull, dflt_value, pk }));
  assert.deepEqual(cols(c), cols(s));
  assert.deepEqual(cols(s).map((x) => x.name),
    ['id', 'repo', 'pr', 'head_sha', 'project', 'score', 'threshold', 'route', 'mode', 'reasons', 'created_at', 'updated_at']);
  const idx = (d) => d.prepare("SELECT name, sql FROM sqlite_master WHERE type='index' AND tbl_name='queue_risk_scores' ORDER BY name").all()
    .map((r) => `${r.name}:${r.sql || 'auto'}`);
  assert.deepEqual(idx(c), idx(s));
  assert.equal(idx(s).filter((n) => !n.startsWith('sqlite_')).length, 2, 'the (repo, pr) and (route, id) indexes');
  assert.ok(idx(s).some((n) => n.startsWith('sqlite_autoindex')), 'UNIQUE(repo, pr, head_sha)');
});
