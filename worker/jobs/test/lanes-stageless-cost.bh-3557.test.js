import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import worker from '../src/index.js';
import { jobsSchemaSql } from './lib/jobs-schema.js';

// BH-3557: a lane with no `stats.cost_stage` and no `stats.cost_project_filter`
// declares no model spend of its own, so GET /api/lanes/status reports its
// runs/cost counts as null, its cost_rows as [] and cost_attribution "none".
// Before this, `owns(r)` was true for every row on such a lane, so 91 lanes
// each showed the whole fleet's (or project's) spend in the $ TODAY column.
//
// These cases drive the real fetch handler over a real schema.sql database
// with the clock pinned, against the real LANES_REGISTRY. The d1() adapter is
// copied from lanes-stage-array.bh-2304.test.js on purpose (no shared helper).

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
  return { prepare: (sql) => make(sql, []), batch: async (s) => s.map((x) => exec(x._sql, x._binds)) };
}

const NOW_MS = Date.parse('2026-09-25T12:00:00Z');
const NOW = new Date(NOW_MS).toISOString();
const THREE_DAYS_AGO = new Date(NOW_MS - 3 * 86400000).toISOString();

// [stage, project, usd, ts]
const ROWS = [
  ['triage', 'project-4', 348, NOW],
  ['execute', 'cromford', 257, NOW],
  ['review', 'project-5', 161, NOW],
  ['plan', 'project-4', 10, THREE_DAYS_AGO],
  ['triage', 'alert-triage', 5, NOW],
];
const FLEET_TODAY = 348 + 257 + 161 + 5;

function freshD1(t) {
  t.mock.timers.enable({ apis: ['Date'], now: NOW_MS });
  const db = new DatabaseSync(':memory:');
  db.exec(SCHEMA);
  const ins = db.prepare(
    'INSERT INTO cost_rows (box, row_hash, line_no, ts, project, stage, cost_usd, inserted_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)');
  ROWS.forEach(([stage, project, usd, ts], i) => ins.run('hub', `h${i}`, i + 1, ts, project, stage, usd, NOW));
  return { db, env: { DB: d1(db), HARNESS_SECRET: SECRET } };
}

async function status(env, qs = '') {
  const res = await worker.fetch(new Request('https://jobs.test/api/lanes/status' + qs,
    { headers: { authorization: 'Bearer ' + SECRET } }), env);
  assert.equal(res.status, 200);
  return res.json();
}
const lane = (body, id) => body.lanes.find((l) => l.id === id);
const stageless = (l) => {
  const cs = l.stats.cost_stage;
  return !(Array.isArray(cs) ? cs.length : cs) && !l.stats.cost_project_filter;
};
function assertNoCost(l, where) {
  assert.ok(l, `lane missing ${where}`);
  assert.equal(l.cost_attribution, 'none', `${l.id} ${where}: attribution`);
  assert.equal(l.cost_today, null, `${l.id} ${where}: cost_today carried a sum it does not own`);
  assert.equal(l.cost_7d, null, `${l.id} ${where}: cost_7d`);
  assert.equal(l.runs_today, null, `${l.id} ${where}: runs_today`);
  assert.deepEqual(l.cost_rows, [], `${l.id} ${where}: cost_rows listed someone else's rows`);
}

test('A1: on the fleet tab no stage-less lane carries the fleet total', async (t) => {
  if (!DatabaseSync) { t.skip('node:sqlite unavailable on this runtime'); return; }
  const { db, env } = freshD1(t);
  const body = await status(env);
  assertNoCost(lane(body, 'cost-rollup'), 'fleet tab');
  const none = body.lanes.filter(stageless);
  assert.ok(none.length > 10, `expected many stage-less lanes, got ${none.length}`);
  for (const l of none) assertNoCost(l, 'fleet tab');
  assert.ok(body.lanes.every((l) => l.cost_today !== FLEET_TODAY),
    'some lane still reports the fleet total');
  db.close();
});

test('A2: on a project tab a stage-less project lane is not the project total', async (t) => {
  if (!DatabaseSync) { t.skip('node:sqlite unavailable on this runtime'); return; }
  const { db, env } = freshD1(t);
  const body = await status(env, '?project=project-4');
  for (const id of ['merge-queue', 'deploy-train']) {
    const l = lane(body, id);
    assert.equal(l.scope, 'project');
    assertNoCost(l, '?project=project-4');
    assert.notEqual(l.cost_today, 348);
    assert.notEqual(l.cost_7d, 358);
  }
  db.close();
});

test('A3: a staged lane still sums only its own stage and filter rows', async (t) => {
  if (!DatabaseSync) { t.skip('node:sqlite unavailable on this runtime'); return; }
  const { db, env } = freshD1(t);
  const at = lane(await status(env), 'alert-triage');
  const { cost_stage, cost_project_filter } = at.stats;
  assert.ok(cost_stage && cost_project_filter, 'alert-triage lost its stage/filter in the registry');
  const want = ROWS.filter(([s, p, , ts]) => s === cost_stage && p === cost_project_filter && ts === NOW)
    .reduce((a, r) => a + r[2], 0);
  assert.ok(want > 0);
  assert.equal(at.cost_attribution, 'lane');
  assert.equal(at.cost_today, want);
  assert.equal(at.runs_today, 1);
  assert.equal(at.cost_rows.length, 1);
  db.close();
});

test('A4: a shared-signature lane stays "shared" and null', async (t) => {
  if (!DatabaseSync) { t.skip('node:sqlite unavailable on this runtime'); return; }
  const { db, env } = freshD1(t);
  const br = lane(await status(env), 'blocked-resolver');
  assert.equal(br.cost_attribution, 'shared');
  assert.equal(br.cost_today, null);
  assert.deepEqual(br.cost_rows, []);
  db.close();
});

test('A5: a stage-less box lane is null on the fleet tab and on a project tab', async (t) => {
  if (!DatabaseSync) { t.skip('node:sqlite unavailable on this runtime'); return; }
  const { db, env } = freshD1(t);
  assertNoCost(lane(await status(env), 'lane-reaper'), 'fleet tab');
  assertNoCost(lane(await status(env, '?project=project-4'), 'lane-reaper'), '?project=project-4');
  db.close();
});
