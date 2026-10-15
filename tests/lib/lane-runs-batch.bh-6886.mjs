// tests/lib/lane-runs-batch.bh-6886.mjs — the contract of
// POST /api/lane-runs/batch (worker/jobs/src/routes/lane-runs-batch.js),
// driven through the REAL router (worker.fetch) over the composed jobs schema
// on the node:sqlite D1 shim. Run by tests/hub-load-budget.bh-6886-test.sh.
//
//   node tests/lib/lane-runs-batch.bh-6886.mjs
//
// Exit 0 = every case passed, 1 = a case failed, 3 = node:sqlite is missing
// (the suite prints a visible SKIP).
//
//   R1 one live row in a batch: it answers already_live, the rest enqueued
//   R2 501 rows -> 400 and nothing written; 500 rows -> 200, enqueued=500
//   R3 bad input (duplicate, bad name, absolute or '..' cmd, 0 rows, not an
//      array, no lane) -> 400 and nothing written
//   R4 a done row does not block a new row for the same (lane, project)
//   R5 the same batch twice: the second answers every row already_live
//   R6 EXPLAIN QUERY PLAN of BATCH_SQL on 20,500 seeded rows scans no lane_runs
//   R7 the claim route hands back the batch's args byte for byte
//   R8 no bearer -> 401
import assert from 'node:assert/strict';
import { fileURLToPath } from 'node:url';

const ROOT = fileURLToPath(new URL('../../', import.meta.url));
let DatabaseSync;
try { ({ DatabaseSync } = await import('node:sqlite')); } catch { process.exit(3); }
const worker = (await import(`${ROOT}worker/jobs/src/index.js`)).default;
const { d1 } = await import(`${ROOT}worker/jobs/test/lib/d1-sqlite.bh-1030.js`);
const { jobsSchemaSql } = await import(`${ROOT}worker/jobs/test/lib/jobs-schema.js`);
const batchMod = await import(`${ROOT}worker/jobs/src/routes/lane-runs-batch.js`);

const SECRET = 'fixture-harness-secret';
const SCHEMA = jobsSchemaSql();
const fresh = () => {
  const db = new DatabaseSync(':memory:');
  db.exec(SCHEMA);
  return { db, DB: d1(db) };
};
const call = async (DB, method, path, body, auth = true) => {
  const headers = { 'content-type': 'application/json' };
  if (auth) headers.authorization = `Bearer ${SECRET}`;
  const req = new Request(`https://jobs.fixture.invalid${path}`, {
    method, headers, body: body === undefined ? undefined : JSON.stringify(body),
  });
  const res = await worker.fetch(req, { DB, HARNESS_SECRET: SECRET });
  return { status: res.status, body: await res.json().catch(() => null) };
};
const ARGS = ['bin/fake-lane.sh', '--x', 'a b'];
const batch = (DB, lane, projects, args = ARGS) =>
  call(DB, 'POST', '/api/lane-runs/batch', { lane, box: 'fixture-box', rows: projects.map((project) => ({ project, args })) });
const count = (db) => db.prepare('SELECT COUNT(*) AS n FROM lane_runs').get().n;
const live = (db, lane, project) =>
  db.prepare("SELECT id FROM lane_runs WHERE lane=? AND project=? AND status IN ('queued','claimed')").all(lane, project);

let pass = 0; let fail = 0;
const tcase = async (name, fn) => {
  try { await fn(); pass += 1; console.log(`  ok   ${name}`); } catch (e) {
    fail += 1; console.log(`  FAIL ${name}: ${e && e.message}`);
  }
};

await tcase('R1 a batch with one live row: that row already_live, the rest enqueued', async () => {
  const { db, DB } = fresh();
  const one = await call(DB, 'POST', '/api/lane-runs', { lane: 'demo', project: 'p2', args: ARGS });
  assert.equal(one.status, 201);
  const r = await batch(DB, 'demo', ['p1', 'p2', 'p3']);
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.enqueued, 2);
  assert.equal(r.body.already_live, 1);
  assert.deepEqual(r.body.rows.map((x) => [x.project, x.status]),
    [['p1', 'enqueued'], ['p2', 'already_live'], ['p3', 'enqueued']]);
  assert.ok(Number.isInteger(r.body.rows[0].id) && Number.isInteger(r.body.rows[2].id), 'enqueued rows carry an id');
  assert.ok(r.body.rows[0].id < r.body.rows[2].id, 'ids ascend in input order');
  const p2 = live(db, 'demo', 'p2');
  assert.equal(p2.length, 1);
  assert.equal(Number(p2[0].id), one.body.id, 'the live p2 row is the old one');
  assert.equal(count(db), 3);
  const p1 = db.prepare('SELECT * FROM lane_runs WHERE id=?').get(r.body.rows[0].id);
  assert.equal(p1.project, 'p1');
  assert.equal(p1.enqueued_by, 'fixture-box');
  assert.equal(p1.status, 'queued');
});

await tcase('R2 501 rows -> 400 and nothing written; 500 rows -> 200 enqueued=500', async () => {
  const { db, DB } = fresh();
  const names = (n) => Array.from({ length: n }, (_, i) => `p${String(i + 1).padStart(4, '0')}`);
  const big = await batch(DB, 'demo', names(501));
  assert.equal(big.status, 400);
  assert.match(big.body.error, /1\.\.500/);
  assert.equal(count(db), 0);
  const ok = await batch(DB, 'demo', names(500));
  assert.equal(ok.status, 200, JSON.stringify(ok.body).slice(0, 200));
  assert.equal(ok.body.enqueued, 500);
  assert.equal(ok.body.already_live, 0);
  assert.equal(count(db), 500);
  assert.equal(batchMod.BATCH_MAX, 500);
});

await tcase('R3 bad input -> 400, 0 rows written', async () => {
  const { db, DB } = fresh();
  const post = (body) => call(DB, 'POST', '/api/lane-runs/batch', body);
  const row = (project, args = ARGS) => ({ project, args });
  const cases = [
    ['duplicate project', { lane: 'demo', rows: [row('p1'), row('p2'), row('p1')] }, /duplicate project p1/],
    ['bad project name', { lane: 'demo', rows: [row('p1'), row('bad name')] }, /rows\[1\]/],
    ['absolute args[0]', { lane: 'demo', rows: [row('p1', ['/abs/x.sh'])] }, /rows\[0\].*args\[0\]/],
    ["'..' in args[0]", { lane: 'demo', rows: [row('p1', ['bin/../x'])] }, /args\[0\]/],
    ['args not strings', { lane: 'demo', rows: [row('p1', ['bin/x.sh', 3])] }, /rows\[0\]/],
    ['0 rows', { lane: 'demo', rows: [] }, /1\.\.500/],
    ['rows not an array', { lane: 'demo', rows: { project: 'p1' } }, /1\.\.500/],
    ['missing lane', { rows: [row('p1')] }, /lane/],
    ['a row that is not an object', { lane: 'demo', rows: [row('p1'), 'p2'] }, /rows\[1\]/],
  ];
  for (const [name, body, re] of cases) {
    const r = await post(body);
    assert.equal(r.status, 400, `${name}: ${r.status} ${JSON.stringify(r.body)}`);
    assert.match(r.body.error, re, `${name}: ${r.body.error}`);
  }
  assert.equal(count(db), 0);
});

await tcase('R4 a done row does not block a new row; a claimed row does', async () => {
  const { db, DB } = fresh();
  await batch(DB, 'demo', ['p1', 'p2']);
  db.exec("UPDATE lane_runs SET status='done', rc=0 WHERE project='p1'");
  db.exec("UPDATE lane_runs SET status='claimed', claimed_by='m1' WHERE project='p2'");
  const r = await batch(DB, 'demo', ['p1', 'p2']);
  assert.equal(r.status, 200);
  assert.deepEqual(r.body.rows.map((x) => [x.project, x.status]), [['p1', 'enqueued'], ['p2', 'already_live']]);
  assert.equal(live(db, 'demo', 'p1').length, 1);
  assert.equal(count(db), 3);
  const other = await batch(DB, 'other', ['p2']);
  assert.equal(other.body.rows[0].status, 'enqueued', 'a live row of another lane does not conflict');
});

await tcase('R5 the same batch twice: the second answers every row already_live', async () => {
  const { db, DB } = fresh();
  const a = await batch(DB, 'demo', ['p1', 'p2', 'p3']);
  assert.equal(a.body.enqueued, 3);
  const b = await batch(DB, 'demo', ['p1', 'p2', 'p3']);
  assert.equal(b.status, 200);
  assert.equal(b.body.enqueued, 0);
  assert.equal(b.body.already_live, 3);
  assert.ok(b.body.rows.every((x) => x.status === 'already_live' && x.id === undefined));
  assert.equal(count(db), 3);
});

await tcase('R6 EXPLAIN QUERY PLAN on 20,500 seeded rows scans no lane_runs', async () => {
  const { db } = fresh();
  assert.equal(typeof batchMod.BATCH_SQL, 'string');
  db.exec(`WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM n WHERE i < 20000)
    INSERT INTO lane_runs (lane, project, args_json, enqueued_at, status, rc)
    SELECT 'demo', 'p' || (i % 1000), '["bin/x.sh"]', '2026-10-01T00:00:00Z', 'done', 0 FROM n`);
  db.exec(`WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM n WHERE i < 500)
    INSERT INTO lane_runs (lane, project, args_json, enqueued_at, status)
    SELECT 'demo', 'p' || i, '["bin/x.sh"]', '2026-10-01T00:00:00Z', 'queued' FROM n`);
  db.exec('ANALYZE');
  assert.equal(count(db), 20500);
  const rowsJson = JSON.stringify(Array.from({ length: 500 }, (_, i) => ({ p: `p${i + 250}`, a: '["bin/x.sh"]' })));
  const plan = db.prepare(`EXPLAIN QUERY PLAN ${batchMod.BATCH_SQL}`)
    .all('demo', '2026-10-15T00:00:00Z', 'fixture-box', rowsJson);
  const details = plan.map((s) => s.detail);
  assert.ok(details.length > 0, 'a plan came back');
  assert.ok(!details.some((d) => /SCAN lane_runs/.test(d)), `plan: ${details.join(' | ')}`);
  console.log(`  plan R6: ${details.join(' | ')}`);
});

await tcase('R7 the claim route hands back the batch args byte for byte', async () => {
  const { DB } = fresh();
  const args = ['bin/fake-lane.sh', '--x', 'a b', 'line1\nline2', 'ünï', ''];
  const r = await batch(DB, 'demo', ['p1'], args);
  assert.equal(r.body.enqueued, 1);
  const c = await call(DB, 'POST', '/api/lane-runs/claim', { machine: 'm1' });
  assert.equal(c.status, 200);
  assert.equal(c.body.id, r.body.rows[0].id);
  assert.equal(c.body.project, 'p1');
  assert.deepEqual(c.body.args, args);
});

await tcase('R8 no bearer -> 401', async () => {
  const { db, DB } = fresh();
  const r = await call(DB, 'POST', '/api/lane-runs/batch', { lane: 'demo', rows: [{ project: 'p1', args: ARGS }] }, false);
  assert.equal(r.status, 401);
  assert.equal(count(db), 0);
});

console.log(`lane-runs-batch: ${pass} passed, ${fail} failed`);
process.exit(fail === 0 ? 0 : 1);
