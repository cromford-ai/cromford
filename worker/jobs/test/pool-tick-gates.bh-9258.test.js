// BH-9258 (#9061 Fix 4): POST /api/pool/tick-summary stores each row's
// gates_today (today's selection-gate counts, bin/lib/sg-day-counts.sh) and
// GET /api/pool/status returns it. Driven through the REAL worker.fetch on
// node:sqlite with the composed jobs schema.
//   W1 the body the real lane posted (tests/fixtures/pool-tick-gate-counts.bh-9258/post.json,
//      pinned by tests/pool-tick-gate-counts.bh-9258-test.sh P1) round-trips
//   W2 a row with no gates_today (or null) stores null
//   W3 a bad gates_today rejects that row only; the other row is written
//   W4 the GET is still two PRIMARY KEY reads with 200 rows (no full scan)
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import { plan, fullScans } from './lib/d1-volume.bh-6727.js';
import * as SQL from '../src/routes/pool-tick.js';

const SECRET = 'tok-fixture-bh9258';
const FIX = fileURLToPath(new URL('../../../tests/fixtures/pool-tick-gate-counts.bh-9258/post.json', import.meta.url));
const posted = () => JSON.parse(readFileSync(FIX, 'utf8'));

async function fresh(t) {
  const o = await openDb();
  if (!o) { t.skip('node:sqlite unavailable'); return null; }
  return o;
}
function call(DB, method, path, body) {
  const init = { method, headers: { 'content-type': 'application/json', authorization: `Bearer ${SECRET}` } };
  if (method !== 'GET') init.body = JSON.stringify(body ?? {});
  return worker.fetch(new Request(`https://jobs.test${path}`, init), { DB, HARNESS_SECRET: SECRET })
    .then(async (res) => ({ status: res.status, body: await res.json().catch(() => null) }));
}
const post = (DB, b) => call(DB, 'POST', '/api/pool/tick-summary', b);
const get = (DB, p) => call(DB, 'GET', `/api/pool/status?project=${encodeURIComponent(p)}`);
const stored = (db, p) => JSON.parse(db.prepare('SELECT summary_json FROM pool_tick_summary WHERE project = ?').get(p).summary_json);

test('W1 the lane body round-trips: POST then GET returns gates_today equal', async (t) => {
  const o = await fresh(t); if (!o) return;
  const body = posted();
  const r = await post(o.DB, body);
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.deepEqual([r.body.written, r.body.rejected], [2, 0]);
  for (const row of body.rows) {
    const g = (await get(o.DB, row.project)).body;
    assert.deepEqual(g.gates_today, row.gates_today, row.project);
  }
  assert.deepEqual(stored(o.db, 'p').gates_today,
    { day: '2026-11-08', gates: 4, rc0: 1, rc1_attributed: 1, rc1_unattributed: 1, could_not_run: 1 });
  // Stored after respawns_truncated, in the fixed field order.
  assert.deepEqual(Object.keys(stored(o.db, 'p')).slice(-2), ['respawns_truncated', 'gates_today']);
});

test('W2 a row without gates_today, or with null, stores null and GET returns null', async (t) => {
  const o = await fresh(t); if (!o) return;
  const [a] = posted().rows;
  const { gates_today: _drop, ...without } = a;
  const r = await post(o.DB, { rows: [{ ...without, project: 'p-none' }, { ...a, project: 'p-null', gates_today: null }] });
  assert.deepEqual([r.body.written, r.body.rejected], [2, 0]);
  for (const p of ['p-none', 'p-null']) {
    assert.equal(stored(o.db, p).gates_today, null, p);
    const g = (await get(o.DB, p)).body;
    assert.ok(Object.hasOwn(g, 'gates_today'), p);
    assert.equal(g.gates_today, null, p);
  }
});

test('W3 a bad gates_today rejects that row only; the other row is written', async (t) => {
  const o = await fresh(t); if (!o) return;
  const [a] = posted().rows;
  const gt = a.gates_today;
  const bads = [
    { ...gt, rc0: -1 }, { ...gt, day: '2026-11-8' }, { ...gt, gates: 1.5 }, { ...gt, could_not_run: '1' },
    (({ rc1_unattributed: _x, ...rest }) => rest)(gt), [gt], 'today', 4,
  ];
  for (const bad of bads) {
    const r = await post(o.DB, { rows: [{ ...a, project: 'p-bad', gates_today: bad }, { ...a, project: 'p-good' }] });
    assert.deepEqual([r.body.written, r.body.rejected], [1, 1], JSON.stringify(bad));
    assert.equal(o.db.prepare("SELECT COUNT(*) AS n FROM pool_tick_summary WHERE project = 'p-bad'").get().n, 0, JSON.stringify(bad));
  }
  assert.deepEqual(stored(o.db, 'p-good').gates_today, gt);
  // A stray key inside gates_today is not stored.
  await post(o.DB, { rows: [{ ...a, project: 'p-extra', gates_today: { ...gt, why: 'tok-fixture-planted' } }] });
  assert.deepEqual(stored(o.db, 'p-extra').gates_today, gt);
});

test('W4 the GET is two PRIMARY KEY reads with 200 rows: no full scan', async (t) => {
  const o = await fresh(t); if (!o) return;
  const [a] = posted().rows;
  const rows = Array.from({ length: 200 }, (_, i) => ({ ...a, project: `p-${i}` }));
  assert.equal((await post(o.DB, { rows })).body.written, 200);
  const r = plan(o.db, SQL.READ_SQL, 'p-7');
  assert.deepEqual(fullScans(r, ['pool_tick_summary']), [], r.join(' | '));
  const s = plan(o.db, SQL.SETTINGS_SQL, 'a', 'b', 'c');
  assert.deepEqual(fullScans(s, ['settings']), [], s.join(' | '));
  // The statement count of the GET: count the prepares one GET makes.
  let n = 0;
  const DB = { ...o.DB, prepare: (q) => { n++; return o.DB.prepare(q); } };
  const g = await get(DB, 'p-7');
  assert.equal(g.status, 200);
  assert.equal(n, 2);
  assert.deepEqual(g.body.gates_today, a.gates_today);
});
