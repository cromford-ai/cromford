import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import worker from '../src/index.js';
import { jobsSchemaSql } from './lib/jobs-schema.js';

// BH-2303: cost rows carry lane_id, and the pre-call spend gate's aggregate can
// be asked per LANE. Before this, review-prs, review-autopilot and
// merge-conductor all priced as stage=review, so a cap on one summed all three.
// Driven through the worker's REAL fetch handler over node:sqlite built from
// schema.sql, because the thing under test IS the SQL: which rows a lane owns.
//
//   ?lane=L  sums the rows stamped lane_id=L, PLUS the rows written before
//            lane_id existed (lane_id IS NULL) that match the old signature
//            (stage, and project when given) — so a day that straddles the
//            deploy still counts its earlier spend. A row stamped with ANOTHER
//            lane is never counted, whatever its stage.

const SECRET = 'test-secret';
const SCHEMA = jobsSchemaSql();
let DatabaseSync = null;
try { ({ DatabaseSync } = await import('node:sqlite')); } catch { DatabaseSync = null; }

function d1(db) {
  const exec = (sql, binds) => {
    const stmt = db.prepare(sql);
    if (/^\s*(SELECT|PRAGMA)\b/i.test(sql)) return { results: stmt.all(...binds), meta: { changes: 0 } };
    const r = stmt.run(...binds);
    return { results: [], meta: { changes: Number(r.changes) } };
  };
  const make = (sql, binds) => ({
    _sql: sql, _binds: binds,
    bind: (...b) => make(sql, b),
    run: async () => exec(sql, binds),
    first: async () => { const r = exec(sql, binds); return r.results.length ? r.results[0] : null; },
    all: async () => exec(sql, binds),
  });
  return {
    prepare: (sql) => make(sql, []),
    batch: async (stmts) => {
      db.exec('BEGIN');
      try { const out = stmts.map((s) => exec(s._sql, s._binds)); db.exec('COMMIT'); return out; }
      catch (e) { db.exec('ROLLBACK'); throw e; }
    },
  };
}
function fresh() {
  const db = new DatabaseSync(':memory:');
  db.exec(SCHEMA);
  return { db, env: { DB: d1(db), HARNESS_SECRET: SECRET } };
}
async function call(env, method, path, body) {
  const headers = { authorization: 'Bearer ' + SECRET };
  const init = { method, headers };
  if (body !== undefined) { headers['content-type'] = 'application/json'; init.body = JSON.stringify(body); }
  const res = await worker.fetch(new Request('https://jobs.test' + path, init), env);
  return { status: res.status, body: await res.json().catch(() => null) };
}
const DAY = '2026-09-25';
let n = 0;
const row = (o) => ({ row_hash: `h${++n}`, line_no: n, ts: `${DAY}T10:00:00Z`, host: 'h', project: 'p1',
  stage: 'review', runner: 'claude', model: 'm', rc: 0, cost_usd: 1, ...o });

test('schema.sql gives cost_rows a lane_id column', { skip: !DatabaseSync }, () => {
  const db = new DatabaseSync(':memory:');
  db.exec(SCHEMA); db.exec(SCHEMA);
  const cols = db.prepare('PRAGMA table_info(cost_rows)').all().map((c) => c.name);
  assert.ok(cols.includes('lane_id'), `cost_rows columns: ${cols.join(',')}`);
});

test('POST /api/metrics/cost-rows stores lane_id; a row without one stores NULL', { skip: !DatabaseSync }, async () => {
  const { db, env } = fresh();
  const r = await call(env, 'POST', '/api/metrics/cost-rows',
    { box: 'hub', rows: [row({ lane_id: 'review-prs' }), row({})] });
  assert.equal(r.status, 200);
  const got = db.prepare('SELECT lane_id FROM cost_rows ORDER BY line_no').all().map((x) => x.lane_id);
  assert.deepEqual(got, ['review-prs', null]);
});

test('llm-spend?lane= counts that lane only, plus legacy NULL-lane rows on the same stage', { skip: !DatabaseSync }, async () => {
  const { env } = fresh();
  await call(env, 'POST', '/api/metrics/cost-rows', { box: 'hub', rows: [
    row({ lane_id: 'review-prs', cost_usd: 3 }),
    row({ lane_id: 'review-autopilot', cost_usd: 50 }),     // same stage, another lane: never counted
    row({ lane_id: 'merge-conductor', cost_usd: 40 }),
    row({ cost_usd: 2 }),                                    // written before lane_id: counted by signature
    row({ cost_usd: 7, stage: 'triage' }),                   // legacy, other stage: not counted
    row({ lane_id: 'review-prs', cost_usd: 5, ts: '2026-09-24T10:00:00Z' }), // yesterday
  ] });
  const since = `${DAY}T00:00:00Z`;
  const prs = await call(env, 'GET', `/api/metrics/llm-spend?lane=review-prs&stage=review&since=${since}`);  // determinism: ok since= pins the window to the fixtures' fixed day
  assert.equal(prs.status, 200);
  assert.equal(prs.body.usd, 5, 'review-prs: its own 3 + the legacy 2');
  const auto = await call(env, 'GET', `/api/metrics/llm-spend?lane=review-autopilot&stage=review&since=${since}`);  // determinism: ok since= pins the window to the fixtures' fixed day
  assert.equal(auto.body.usd, 52);
  // No stage given: only rows stamped with the lane (legacy rows cannot be attributed).
  const bare = await call(env, 'GET', `/api/metrics/llm-spend?lane=review-prs&since=${since}`);  // determinism: ok since= pins the window to the fixtures' fixed day
  assert.equal(bare.body.usd, 3);
});

test('llm-spend?lane=&project= scopes both the lane rows and the legacy rows to the project', { skip: !DatabaseSync }, async () => {
  const { env } = fresh();
  await call(env, 'POST', '/api/metrics/cost-rows', { box: 'hub', rows: [
    row({ lane_id: 'alert-triage', stage: 'triage', project: 'alert-triage', cost_usd: 4 }),
    row({ lane_id: 'alert-triage', stage: 'triage', project: 'other', cost_usd: 9 }),
    row({ stage: 'triage', project: 'alert-triage', cost_usd: 1 }),
    row({ stage: 'triage', project: 'other', cost_usd: 8 }),
  ] });
  const r = await call(env, 'GET', `/api/metrics/llm-spend?lane=alert-triage&stage=triage&project=alert-triage&since=${DAY}T00:00:00Z`);  // determinism: ok since= pins the window to the fixtures' fixed day
  assert.equal(r.body.usd, 5);
});

test('llm-spend without lane= answers exactly as before (the stage signature)', { skip: !DatabaseSync }, async () => {
  const { env } = fresh();
  await call(env, 'POST', '/api/metrics/cost-rows', { box: 'hub', rows: [
    row({ lane_id: 'review-prs', cost_usd: 3 }), row({ lane_id: 'review-autopilot', cost_usd: 4 }), row({ cost_usd: 2 }),
  ] });
  const r = await call(env, 'GET', `/api/metrics/llm-spend?stage=review&since=${DAY}T00:00:00Z`);  // determinism: ok since= pins the window to the fixtures' fixed day
  assert.equal(r.body.usd, 9);
});

test('an unusable lane value is a 400, never a silent unfiltered sum', { skip: !DatabaseSync }, async () => {
  const { env } = fresh();
  const r = await call(env, 'GET', `/api/metrics/llm-spend?lane=${encodeURIComponent('a b;c')}&stage=review`);
  assert.equal(r.status, 400);
});

test('with a stage, a lane read is stage-scoped: summing the lane\'s stages counts each row once', { skip: !DatabaseSync }, async () => {
  const { env } = fresh();
  await call(env, 'POST', '/api/metrics/cost-rows', { box: 'hub', rows: [
    row({ lane_id: 'run-product', stage: 'map', cost_usd: 4 }),
    row({ lane_id: 'run-product', stage: 'synth', cost_usd: 7 }),
    row({ stage: 'map', cost_usd: 1 }),                       // legacy, on one of the lane's stages
    row({ lane_id: 'other-lane', stage: 'map', cost_usd: 30 }),
  ] });
  let sum = 0;
  for (const st of ['map', 'synth']) {
    const r = await call(env, 'GET', `/api/metrics/llm-spend?stage=${st}&since=${DAY}T00:00:00Z&lane=run-product`);  // determinism: ok since= pins the window to the fixtures' fixed day
    sum += r.body.usd;
  }
  assert.equal(sum, 12, 'map 4 + synth 7 + legacy map 1, never other-lane, never twice');
});

// THE LIVE D1 IS NOT A FRESH ONE (review of #2462, blocking 1). harness-sync's
// worker_schema_apply runs schema.sql against the live database BEFORE the new
// worker deploys, and there `CREATE TABLE IF NOT EXISTS cost_rows` is a no-op:
// lane_id, which only ensureColumns() adds (ADDED_COLUMNS), does not exist yet.
// Any statement in schema.sql that names it — the index this PR first shipped —
// fails "no such column", the deploy is skipped, and every later worker deploy
// is wedged behind it. So: build the table, take lane_id back OFF (the live
// table's shape on deploy day), then re-apply the whole file. (Older
// ensureColumns columns — ticket, pr, … — are already on the live table, which
// is why schema.sql may index those.)
test('schema.sql re-applies over a live cost_rows that has no lane_id yet', { skip: !DatabaseSync }, () => {
  const db = new DatabaseSync(':memory:');
  db.exec(SCHEMA);
  // An index on the column must go first or SQLite refuses the drop — and the
  // live table would not have such an index either.
  for (const ix of db.prepare("SELECT name, sql FROM sqlite_master WHERE type='index' AND tbl_name='cost_rows' AND sql IS NOT NULL").all()) {
    if (/\blane_id\b/.test(ix.sql)) db.exec(`DROP INDEX ${ix.name}`);
  }
  db.exec('ALTER TABLE cost_rows DROP COLUMN lane_id');
  assert.doesNotThrow(() => db.exec(SCHEMA), 'schema.sql must apply over a live cost_rows that ensureColumns has not reached yet');
});
