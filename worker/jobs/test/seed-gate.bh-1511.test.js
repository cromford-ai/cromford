import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import worker from '../src/index.js';
import { REGISTRY_SEED_ACTOR, registrySeedRows, seedRegistryPlan, LANES_REGISTRY } from '../src/lib/core.js';
import { jobsSchemaSql } from './lib/jobs-schema.js';

// Review round 2 of #1565 (BH-1511.1b): what `harness-ctl seed-registry`
// needs from the worker to gate itself honestly.
//
// B1 — WHICH BOXES MUST PROVE THE CONTRACT. box_status is NOT that list: the
// CLI-version sweep names boxes by cron_box_id_for (box-hub -> hub),
// so half its rows are aliases that can never carry a harness_commit, and a
// box whose lanes tick but which never reported a backup or a CLI version has
// no row at all. The boxes that read settings rows are the boxes that run
// lane-gate, and every lane-gate — old or new — writes lane_ticks. So
// GET /api/lanes/tick-boxes answers the distinct lane_ticks.box that ticked
// inside a window, and nothing else.
//
// --dry-run — GET /api/settings/seed-registry/plan: what the seed WOULD
// insert, move and prune, computed from the same rows and the same guards,
// and writing nothing. A GET, not a flag on the POST: a worker that predates
// the flag would ignore it and seed for real.
//
// Proven on real SQLite (node:sqlite), because "which rows are inside the
// window" is a question about the SQL, and a pattern-matching stub answers it
// with whatever the fixture hands back.

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
  const writes = [];
  return {
    _writes: writes,
    prepare: (sql) => { if (!/^\s*(SELECT|PRAGMA)\b/i.test(sql)) writes.push(sql); return make(sql, []); },
    batch: async (stmts) => stmts.map((s) => { writes.push(s._sql); return exec(s._sql, s._binds); }),
  };
}

function freshDb() {
  const db = new DatabaseSync(':memory:');
  db.exec(SCHEMA);
  return { db, env: { DB: d1(db), HARNESS_SECRET: SECRET } };
}

// Registry keys schema.sql itself seeds (actor 'seed', so the plan counts them
// operator-owned and never touches them): BH-2644's
// lib.token-health.token_health_warn_h is the first. The two cases below
// subtract them instead of assuming a fresh schema holds no registry key.
function preseeded(db, want) {
  const has = db.prepare('SELECT 1 AS x FROM settings WHERE key=?');
  return want.filter((w) => has.get(w.key)).length;
}

async function call(env, method, path, body) {
  const headers = { authorization: 'Bearer ' + SECRET };
  const init = { method, headers };
  if (body !== undefined) { headers['content-type'] = 'application/json'; init.body = JSON.stringify(body); }
  const res = await worker.fetch(new Request('https://jobs.test' + path, init), env);
  return { status: res.status, body: await res.json().catch(() => null) };
}

// The route windows on the worker's own clock (`t`), so fixtures are placed
// relative to ONE anchor captured at load; every window below is minutes wider
// than any test run, so the anchor-vs-route skew cannot move a row across it.
const ANCHOR = Date.now();  // determinism: ok the single anchor; every fixture below is ago(s) off it
const ago = (s) => new Date(ANCHOR - s * 1000).toISOString().replace(/\.\d{3}Z$/, 'Z');

test('GET /api/lanes/tick-boxes: the distinct boxes that ticked a lane inside the window — not box_status', async (t) => {
  if (!DatabaseSync) { t.skip('node:sqlite unavailable on this runtime'); return; }
  const { db, env } = freshDb();
  const tick = db.prepare(`INSERT INTO lane_ticks (lane, project, box, last_tick_at, last_outcome, updated_at)
                           VALUES (?,?,?,?,'ran',?)`);
  tick.run('review-prs', 'project-4', 'box-project-4-1', ago(120), ago(120));
  const t60 = ago(60);
  tick.run('merge-conductor', '-', 'box-hub', t60, t60);
  tick.run('alert-triage', '-', 'box-hub', ago(7200), ago(7200));   // same box, older lane: one row, newest tick
  tick.run('review-prs', 'project-3', 'retired-box', ago(3 * 86400), ago(3 * 86400));
  // The CLI-sweep aliases: box_status rows with no lane tick. They must not appear.
  const bs = db.prepare('INSERT INTO box_status (box, updated_at) VALUES (?,?)');
  bs.run('hub', ago(60)); bs.run('project-4', ago(60));

  const r = await call(env, 'GET', '/api/lanes/tick-boxes?within_s=86400');
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.deepEqual(r.body.boxes.map((b) => b.box), ['box-hub', 'box-project-4-1']);
  assert.equal(r.body.boxes[0].last_tick_at, t60, 'a box is listed once, at its NEWEST tick');
  assert.equal(r.body.within_s, 86400);

  // A wider window brings the retired box back: the window decides, nothing else.
  const wide = await call(env, 'GET', '/api/lanes/tick-boxes?within_s=604800');
  assert.deepEqual(wide.body.boxes.map((b) => b.box), ['box-hub', 'box-project-4-1', 'retired-box']);
  db.close();
});

test('GET /api/lanes/tick-boxes refuses a window it cannot honour, rather than guessing one', async (t) => {
  if (!DatabaseSync) { t.skip('node:sqlite unavailable on this runtime'); return; }
  const { env } = freshDb();
  for (const w of ['', 'abc', '0', '-5', '59', '2592001', '1e5']) {
    const r = await call(env, 'GET', `/api/lanes/tick-boxes?within_s=${w}`);
    assert.equal(r.status, 400, `within_s=${w} answered ${r.status}`);
  }
  const none = await call(env, 'GET', '/api/lanes/tick-boxes');
  assert.equal(none.status, 400, 'no window must be a 400: the caller owns the knob');
});

test('seedRegistryPlan: insert / update / prune from the same guards as the SQL; operator rows untouched', () => {
  const rows = [
    { key: 'lane.a.new_knob', value: '5' },
    { key: 'lane.a.moved', value: '2' },
    { key: 'lane.a.same', value: '3' },
    { key: 'lane.a.operator', value: '7' },
  ];
  const existing = [
    { key: 'lane.a.moved', value: '1', actor: REGISTRY_SEED_ACTOR },
    { key: 'lane.a.same', value: '3', actor: REGISTRY_SEED_ACTOR },
    { key: 'lane.a.operator', value: '9', actor: 'operator' },
    { key: 'lane.a.orphan', value: '4', actor: REGISTRY_SEED_ACTOR },
    { key: 'lane.a.op_orphan', value: '4', actor: 'operator' },
  ];
  const p = seedRegistryPlan(rows, existing);
  assert.deepEqual(p.insert, ['lane.a.new_knob']);
  assert.deepEqual(p.update, [{ key: 'lane.a.moved', from: '1', to: '2' }]);
  assert.deepEqual(p.prune, ['lane.a.orphan']);
  assert.equal(p.operator_owned, 1);
  assert.equal(p.unchanged, 1);
  assert.equal(p.rows, 4);
});

test('GET /api/settings/seed-registry/plan answers the plan and WRITES NOTHING', async (t) => {
  if (!DatabaseSync) { t.skip('node:sqlite unavailable on this runtime'); return; }
  const { db, env } = freshDb();
  const want = registrySeedRows(LANES_REGISTRY);
  const pre = preseeded(db, want);
  const ins = db.prepare("INSERT INTO settings (key,value,note,actor,updated_at) VALUES (?,?,NULL,?,'t0')");
  ins.run(want[0].key, 'operator-value', 'operator');
  ins.run('lane.nope.gone_knob', '4', REGISTRY_SEED_ACTOR);
  const before = db.prepare('SELECT key, value, actor FROM settings ORDER BY key').all().map((r) => ({ ...r }));

  const r = await call(env, 'GET', '/api/settings/seed-registry/plan');
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.rows, want.length);
  assert.equal(r.body.insert.length, want.length - 1 - pre, 'every registered key but the operator-owned ones is new');
  assert.ok(!r.body.insert.includes(want[0].key), 'an operator-owned key must never be in the plan');
  assert.deepEqual(r.body.prune, ['lane.nope.gone_knob']);
  assert.equal(r.body.operator_owned, 1 + pre);
  assert.equal(r.body.actor, REGISTRY_SEED_ACTOR);

  const after = db.prepare('SELECT key, value, actor FROM settings ORDER BY key').all().map((x) => ({ ...x }));
  assert.deepEqual(after, before, 'the plan route changed the settings table');
  assert.deepEqual(env.DB._writes.filter((s) => /settings/i.test(s) && !/CREATE/i.test(s)), [], 'the plan route issued a write');
  db.close();
});

test('POST /api/settings/seed-registry reports the keys it changed and pruned, not only counts', async (t) => {
  if (!DatabaseSync) { t.skip('node:sqlite unavailable on this runtime'); return; }
  const { db, env } = freshDb();
  const want = registrySeedRows(LANES_REGISTRY);
  const pre = preseeded(db, want);
  const ins = db.prepare("INSERT INTO settings (key,value,note,actor,updated_at) VALUES (?,?,NULL,?,'t0')");
  ins.run(want[0].key, 'operator-value', 'operator');
  ins.run(want[1].key, want[1].value, REGISTRY_SEED_ACTOR);          // already current: not changed
  ins.run('lane.nope.gone_knob', '4', REGISTRY_SEED_ACTOR);

  const r = await call(env, 'POST', '/api/settings/seed-registry', {});
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.changed, want.length - 2 - pre);
  assert.equal(r.body.changed_keys.length, r.body.changed);
  assert.ok(!r.body.changed_keys.includes(want[0].key) && !r.body.changed_keys.includes(want[1].key));
  assert.deepEqual(r.body.pruned_keys, ['lane.nope.gone_knob']);
  assert.equal(db.prepare('SELECT value FROM settings WHERE key=?').get(want[0].key).value, 'operator-value');
  db.close();
});
