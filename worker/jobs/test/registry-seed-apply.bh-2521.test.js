import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import worker from '../src/index.js';
import { SEED_REGISTRY_SQL, REGISTRY_SEED_ACTOR } from '../src/lib/core.js';
import { jobsSchemaSql } from './lib/jobs-schema.js';

// BH-2521.2 (BH-2676): the worker side of "plan preview, then apply, with
// actor". A console apply must pass the same fleet gate the CLI enforces, must
// apply only the plan the operator looked at (plan_fp), and leaves one durable
// registry_seed_runs row per attempt that got past those checks.
//
// Routes are driven through the real worker.fetch against real SQLite loaded
// with the shipped schema.sql, the seed-gate.bh-1511 pattern. The shim below is
// per-file on purpose (test/lib/harness.js is not ours to edit): it records the
// ORDER of executed writes, and it can be told to throw on one statement.

const SECRET = 'test-secret';
const SCHEMA = jobsSchemaSql();
let DatabaseSync = null;
try { ({ DatabaseSync } = await import('node:sqlite')); } catch { DatabaseSync = null; }
// Dynamic, so a missing module reads as failing cases, not a file that will not load.
let lib = {};
try { lib = await import('../src/lib/seed-apply.js'); } catch { lib = {}; }

const HEX64 = /^[0-9a-f]{64}$/;
const isRead = (sql) => /^\s*(SELECT|PRAGMA)\b/i.test(sql);

function d1(db, opts = {}) {
  const log = [];
  const exec = (sql, binds) => {
    if (opts.failOn && sql === opts.failOn) throw new Error('D1_ERROR: injected failure');
    const stmt = db.prepare(sql);
    if (isRead(sql)) return { results: stmt.all(...binds), meta: { changes: 0 } };
    log.push(sql);
    const r = stmt.run(...binds);
    return { results: [], meta: { changes: Number(r.changes), last_row_id: Number(r.lastInsertRowid) } };
  };
  const make = (sql, binds) => ({
    _sql: sql, _binds: binds,
    bind: (...b) => make(sql, b),
    run: async () => exec(sql, binds),
    first: async (col) => {
      const r = exec(sql, binds);
      if (!r.results.length) return null;
      return col ? r.results[0][col] : r.results[0];
    },
    all: async () => exec(sql, binds),
  });
  return {
    _log: log,
    prepare: (sql) => make(sql, []),
    batch: async (stmts) => stmts.map((s) => exec(s._sql, s._binds)),
  };
}

function freshDb(opts) {
  const db = new DatabaseSync(':memory:');
  db.exec(SCHEMA);
  const DB = d1(db, opts);
  return { db, DB, env: { DB, HARNESS_SECRET: SECRET } };
}

async function call(env, method, path, body) {
  const headers = { authorization: 'Bearer ' + SECRET };
  const init = { method, headers };
  if (body !== undefined) { headers['content-type'] = 'application/json'; init.body = JSON.stringify(body); }
  const res = await worker.fetch(new Request('https://jobs.test' + path, init), env);
  return { status: res.status, body: await res.json().catch(() => null) };
}

const ANCHOR = Date.now();  // determinism: ok the single anchor; every fixture below is ago(s) off it
const ago = (s) => new Date(ANCHOR - s * 1000).toISOString().replace(/\.\d{3}Z$/, 'Z');

function tick(db, box, at = ago(60)) {
  db.prepare(`INSERT INTO lane_ticks (lane, project, box, last_tick_at, last_outcome, updated_at)
              VALUES ('review-prs','-',?,?,'ran',?)`).run(box, at, at);
}
function report(db, box, commit, at) {
  db.prepare('INSERT INTO box_status (box, harness_commit, harness_reported_at, updated_at) VALUES (?,?,?,?)')
    .run(box, commit, at, ago(0));
}
function setting(db, key, value) {
  db.prepare("INSERT INTO settings (key, value, actor, updated_at) VALUES (?,?,'operator',?)").run(key, value, ago(0));
}
const count = (db, table) => Number(db.prepare(`SELECT COUNT(*) AS n FROM ${table}`).get().n);
function freshFleet(db) {
  tick(db, 'box-hub'); report(db, 'box-hub', 'abc123', ago(120));
  tick(db, 'box-project-4-1'); report(db, 'box-project-4-1', 'abc123', ago(300));
}
const APPLY = '/api/settings/seed-registry/apply';

// ── A1: the table ───────────────────────────────────────────────────────────
test('A1 schema.sql: registry_seed_runs is additive, and its CHECK holds', (t) => {
  assert.match(SCHEMA, /CREATE TABLE IF NOT EXISTS registry_seed_runs \(/);
  assert.match(SCHEMA, /CREATE INDEX IF NOT EXISTS idx_registry_seed_runs_started ON registry_seed_runs\(started_at\)/);
  const start = SCHEMA.indexOf('CREATE TABLE IF NOT EXISTS registry_seed_runs');
  assert.ok(start >= 0);
  const end = SCHEMA.indexOf('idx_registry_seed_runs_started', start);
  const block = SCHEMA.slice(start, SCHEMA.indexOf(';', end) + 1);
  assert.doesNotMatch(block, /\b(DROP|ALTER)\b/i);
  if (!DatabaseSync) { t.skip('node:sqlite unavailable on this runtime'); return; }
  const { db } = freshDb();
  const cols = db.prepare('PRAGMA table_info(registry_seed_runs)').all().map((c) => c.name);
  assert.deepEqual(cols, ['id', 'actor', 'plan_fp', 'status', 'rows', 'changed', 'pruned',
    'changed_keys', 'pruned_keys', 'error', 'started_at', 'finished_at']);
  assert.throws(() => db.prepare("INSERT INTO registry_seed_runs (actor, plan_fp, status, started_at) VALUES ('a','f','bogus','t')").run(),
    /CHECK/);
  db.close();
});

// ── A2: the fingerprint ─────────────────────────────────────────────────────
test('A2 planFingerprint: 64 hex, order-free over insert/update/prune, moves with a value, never mutates', async () => {
  assert.equal(typeof lib.planFingerprint, 'function', 'seed-apply.js must export planFingerprint');
  const a = { insert: ['x', 'a'], update: [{ key: 'k2', from: '1', to: '2' }, { key: 'k1', from: '3', to: '4' }],
    prune: ['b', 'a'], operator_owned: 3, unchanged: 9, rows: 12 };
  const snapshot = JSON.stringify(a);
  const b = { insert: ['a', 'x'], update: [{ to: '4', key: 'k1', from: '3' }, { key: 'k2', from: '1', to: '2' }],
    prune: ['a', 'b'], operator_owned: 0, unchanged: 0, rows: 1 };
  const fa = await lib.planFingerprint(a);
  assert.match(fa, HEX64);
  assert.equal(fa, await lib.planFingerprint(b), 'same sets in a different order must fingerprint the same');
  assert.equal(JSON.stringify(a), snapshot, 'input mutated');
  const moved = { ...b, update: [{ key: 'k1', from: '3', to: '5' }, { key: 'k2', from: '1', to: '2' }] };
  assert.notEqual(fa, await lib.planFingerprint(moved), 'a changed `to` must change the fingerprint');
  assert.notEqual(fa, await lib.planFingerprint({ ...b, prune: ['a'] }), 'a dropped prune must change it');
  assert.notEqual(fa, await lib.planFingerprint({ ...b, insert: ['a'] }), 'a dropped insert must change it');
});

// ── A3: GET plan answers plan_fp ───────────────────────────────────────────
test('A3 GET /api/settings/seed-registry/plan: plan_fp is the fingerprint of the body, other keys unchanged', async (t) => {
  if (!DatabaseSync) { t.skip('node:sqlite unavailable on this runtime'); return; }
  const { db, env } = freshDb();
  const r = await call(env, 'GET', '/api/settings/seed-registry/plan');
  assert.equal(r.status, 200, JSON.stringify(r.body));
  for (const k of ['rows', 'insert', 'update', 'prune', 'operator_owned', 'unchanged', 'actor', 'as_of']) {
    assert.ok(k in r.body, `missing ${k}`);
  }
  assert.equal(r.body.actor, REGISTRY_SEED_ACTOR);
  assert.match(String(r.body.plan_fp), HEX64);
  assert.equal(r.body.plan_fp, await lib.planFingerprint(r.body));
  db.close();
});

// ── A4: the gate, pure ─────────────────────────────────────────────────────
test('A4 fleetGateVerdict: every unproven box refused with a reason; a fresh fleet passes', () => {
  assert.equal(typeof lib.fleetGateVerdict, 'function', 'seed-apply.js must export fleetGateVerdict');
  const nowS = 1_800_000_000;
  const iso = (s) => new Date((nowS - s) * 1000).toISOString();
  const v = (ticks, boxes, maxAgeS = 7200) => lib.fleetGateVerdict({ ticks, boxes, nowS, maxAgeS });
  const fresh = (box) => ({ box, harness_commit: 'abc', harness_reported_at: iso(60) });

  const none = v([], [fresh('a')]);
  assert.equal(none.ok, false);
  assert.equal(none.bad.length, 1);
  assert.ok(none.bad[0].reason);

  const cases = [
    ['no row', []],
    ['blank commit', [{ box: 'a', harness_commit: '', harness_reported_at: iso(60) }]],
    ['null commit', [{ box: 'a', harness_commit: null, harness_reported_at: iso(60) }]],
    ['null time', [{ box: 'a', harness_commit: 'abc', harness_reported_at: null }]],
    ['stale', [{ box: 'a', harness_commit: 'abc', harness_reported_at: iso(7201) }]],
    ['junk', [{ box: 'a', harness_commit: 'abc', harness_reported_at: 'junk' }]],
  ];
  for (const [name, boxes] of cases) {
    const r = v(['a'], boxes);
    assert.equal(r.ok, false, name);
    assert.equal(r.bad.length, 1, name);
    assert.equal(r.bad[0].box, 'a', name);
    assert.ok(r.bad[0].reason.length > 0, name);
  }
  assert.match(v(['a'], cases[4][1]).bad[0].reason, /7201s ago.*7200s/);
  assert.match(v(['a'], cases[5][1]).bad[0].reason, /unreadable report time 'junk'/);
  // Exactly at the limit is still fresh.
  assert.equal(v(['a'], [{ box: 'a', harness_commit: 'abc', harness_reported_at: iso(7200) }]).ok, true);

  const partial = v(['a', 'b'], [fresh('a'), { box: 'b', harness_commit: 'abc', harness_reported_at: iso(9000) }]);
  assert.equal(partial.ok, false, 'one stale box refuses the fleet');
  assert.deepEqual(partial.bad.map((b) => b.box), ['b']);

  assert.deepEqual(v(['a', 'b', 'a'], [fresh('a'), fresh('b'), { box: 'alias' }]), { ok: true, bad: [] });
  // Fractional seconds parse.
  assert.equal(v(['a'], [{ box: 'a', harness_commit: 'c', harness_reported_at: iso(30) }]).ok, true);
  assert.equal(lib.SEED_GATE_TICK_WINDOW_S, 86400);
  assert.equal(lib.SEED_GATE_MAX_AGE_S, 7200);
});

// ── A5: knobs from settings rows ───────────────────────────────────────────
test('A5 apply: seed_gate_max_age_s row wins when a positive int, else the 7200 fallback', async (t) => {
  if (!DatabaseSync) { t.skip('node:sqlite unavailable on this runtime'); return; }
  {
    const { db, env } = freshDb();
    tick(db, 'bw'); report(db, 'bw', 'abc', ago(61));
    setting(db, 'seed_gate_max_age_s', '60');
    const plan = await call(env, 'GET', '/api/settings/seed-registry/plan');
    const r = await call(env, 'POST', APPLY, { plan_fp: plan.body.plan_fp, actor: 'operator@example.com' });
    assert.equal(r.status, 409, JSON.stringify(r.body));
    assert.equal(r.body.error, 'fleet_gate');
    assert.equal(r.body.boxes[0].box, 'bw');
    db.close();
  }
  for (const junk of ['0', 'abc', '-5', '60s']) {
    const { db, env } = freshDb();
    tick(db, 'bw'); report(db, 'bw', 'abc', ago(61));
    setting(db, 'seed_gate_max_age_s', junk);
    const plan = await call(env, 'GET', '/api/settings/seed-registry/plan');
    const r = await call(env, 'POST', APPLY, { plan_fp: plan.body.plan_fp, actor: 'operator@example.com' });
    assert.equal(r.status, 200, `${junk}: ${JSON.stringify(r.body)}`);
    db.close();
  }
  {
    // The tick window knob: a 2h-old tick falls outside a 3600s window, so no box ticked.
    const { db, env } = freshDb();
    tick(db, 'bw', ago(7000)); report(db, 'bw', 'abc', ago(60));
    setting(db, 'seed_gate_tick_window_s', '3600');
    const r = await call(env, 'POST', APPLY, { plan_fp: 'a'.repeat(64), actor: 'operator@example.com' });
    assert.equal(r.status, 409, JSON.stringify(r.body));
    assert.equal(r.body.error, 'fleet_gate');
    assert.equal(r.body.boxes[0].box, '-');
    db.close();
  }
});

// ── A6: 400s ────────────────────────────────────────────────────────────────
test('A6 apply: 400 on a blank actor or a malformed plan_fp, nothing written', async (t) => {
  if (!DatabaseSync) { t.skip('node:sqlite unavailable on this runtime'); return; }
  const { db, env } = freshDb();
  freshFleet(db);
  const fp = (await call(env, 'GET', '/api/settings/seed-registry/plan')).body.plan_fp;
  const s0 = count(db, 'settings');
  const bodies = [
    { plan_fp: fp }, { plan_fp: fp, actor: '' }, { plan_fp: fp, actor: '   ' }, { plan_fp: fp, actor: 42 },
    { actor: 'operator' }, { plan_fp: String(fp).toUpperCase(), actor: 'operator' }, { plan_fp: 'a'.repeat(63), actor: 'operator' },
    { plan_fp: 12345, actor: 'operator' },
  ];
  for (const b of bodies) {
    const r = await call(env, 'POST', APPLY, b);
    assert.equal(r.status, 400, `${JSON.stringify(b)} -> ${r.status} ${JSON.stringify(r.body)}`);
    assert.ok(r.body.error);
  }
  assert.equal(count(db, 'settings'), s0);
  assert.equal(count(db, 'registry_seed_runs'), 0);
  db.close();
});

// ── A7: fleet gate refusal ─────────────────────────────────────────────────
test('A7 apply: 409 fleet_gate names the boxes and writes nothing', async (t) => {
  if (!DatabaseSync) { t.skip('node:sqlite unavailable on this runtime'); return; }
  const { db, env } = freshDb();
  tick(db, 'fresh'); report(db, 'fresh', 'abc', ago(60));
  tick(db, 'stale'); report(db, 'stale', 'abc', ago(9000));
  tick(db, 'mute');                                           // ticks, never reported
  const fp = (await call(env, 'GET', '/api/settings/seed-registry/plan')).body.plan_fp;
  const s0 = count(db, 'settings');
  const r = await call(env, 'POST', APPLY, { plan_fp: fp, actor: 'operator@example.com' });
  assert.equal(r.status, 409, JSON.stringify(r.body));
  assert.equal(r.body.error, 'fleet_gate');
  assert.deepEqual(r.body.boxes.map((b) => b.box), ['mute', 'stale']);
  assert.ok(r.body.boxes.every((b) => typeof b.reason === 'string' && b.reason));
  assert.equal(count(db, 'settings'), s0, 'the gate refused but settings were written');
  assert.equal(count(db, 'registry_seed_runs'), 0, 'the gate refused but a run row was written');

  const empty = freshDb();
  const r2 = await call(empty.env, 'POST', APPLY, { plan_fp: fp, actor: 'operator@example.com' });
  assert.equal(r2.status, 409);
  assert.equal(r2.body.error, 'fleet_gate', 'zero ticking boxes must refuse');
  db.close(); empty.db.close();
});

// ── A8: plan moved ─────────────────────────────────────────────────────────
test('A8 apply: 409 plan_moved hands back the fresh plan with its fp and writes nothing', async (t) => {
  if (!DatabaseSync) { t.skip('node:sqlite unavailable on this runtime'); return; }
  const { db, env } = freshDb();
  freshFleet(db);
  const plan = (await call(env, 'GET', '/api/settings/seed-registry/plan')).body;
  const s0 = count(db, 'settings');
  const r = await call(env, 'POST', APPLY, { plan_fp: 'f'.repeat(64), actor: 'operator@example.com' });
  assert.equal(r.status, 409, JSON.stringify(r.body));
  assert.equal(r.body.error, 'plan_moved');
  assert.equal(r.body.plan.plan_fp, plan.plan_fp);
  assert.deepEqual(r.body.plan.insert, plan.insert);
  assert.equal(count(db, 'settings'), s0);
  assert.equal(count(db, 'registry_seed_runs'), 0);
  db.close();
});

// ── A9: the apply ──────────────────────────────────────────────────────────
test('A9 apply: 200 {id, actor, ...result}; run row started then applied, with the caller as actor', async (t) => {
  if (!DatabaseSync) { t.skip('node:sqlite unavailable on this runtime'); return; }
  const { db, DB, env } = freshDb();
  freshFleet(db);
  const plan = (await call(env, 'GET', '/api/settings/seed-registry/plan')).body;
  assert.ok(plan.insert.length > 0, 'fixture: the registry must have something to seed');
  const r = await call(env, 'POST', APPLY, { plan_fp: plan.plan_fp, actor: '  operator@example.com ' });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.deepEqual(Object.keys(r.body), ['id', 'actor', 'rows', 'changed', 'pruned', 'changed_keys', 'pruned_keys', 'as_of']);
  assert.equal(r.body.actor, 'operator@example.com');
  assert.ok(r.body.changed > 0);
  assert.equal(r.body.changed, plan.insert.length + plan.update.length);
  assert.deepEqual([...r.body.changed_keys].sort(), [...plan.insert].sort());

  const run = db.prepare('SELECT * FROM registry_seed_runs WHERE id=?').get(r.body.id);
  assert.equal(run.status, 'applied');
  assert.equal(run.actor, 'operator@example.com');
  assert.equal(run.plan_fp, plan.plan_fp);
  assert.equal(run.rows, r.body.rows);
  assert.equal(run.changed, r.body.changed);
  assert.equal(run.pruned, 0);
  assert.deepEqual(JSON.parse(run.changed_keys), r.body.changed_keys);
  assert.deepEqual(JSON.parse(run.pruned_keys), []);
  assert.ok(run.finished_at && run.started_at);
  const seeded = db.prepare('SELECT actor FROM settings WHERE key=?').get(plan.insert[0]);
  assert.equal(seeded.actor, REGISTRY_SEED_ACTOR, 'seeded rows keep the registry-seed actor');

  const iStart = DB._log.findIndex((s) => /INSERT INTO registry_seed_runs/.test(s));
  const iSeed = DB._log.indexOf(SEED_REGISTRY_SQL);
  const iDone = DB._log.findIndex((s) => /UPDATE registry_seed_runs/.test(s) && /'applied'/.test(s));
  assert.ok(iStart >= 0 && iSeed > iStart && iDone > iSeed, `order started=${iStart} seed=${iSeed} applied=${iDone}`);

  // A second apply of the now-current plan is honest: nothing changed.
  const plan2 = (await call(env, 'GET', '/api/settings/seed-registry/plan')).body;
  const r2 = await call(env, 'POST', APPLY, { plan_fp: plan2.plan_fp, actor: 'operator@example.com' });
  assert.equal(r2.status, 200);
  assert.equal(r2.body.changed, 0);
  assert.ok(r2.body.id > r.body.id);
  db.close();
});

// ── A10: a seed throw ──────────────────────────────────────────────────────
test('A10 apply: a seed that throws leaves the run failed, with the error, and answers 503', async (t) => {
  if (!DatabaseSync) { t.skip('node:sqlite unavailable on this runtime'); return; }
  const { db, env } = freshDb({ failOn: SEED_REGISTRY_SQL });
  freshFleet(db);
  const plan = (await call(env, 'GET', '/api/settings/seed-registry/plan')).body;
  const r = await call(env, 'POST', APPLY, { plan_fp: plan.plan_fp, actor: 'operator@example.com' });
  assert.equal(r.status, 503, JSON.stringify(r.body));
  const runs = db.prepare('SELECT * FROM registry_seed_runs').all();
  assert.equal(runs.length, 1);
  assert.equal(runs[0].status, 'failed');
  assert.match(runs[0].error, /injected failure/);
  assert.equal(runs[0].changed, null, 'a failed run must not claim changed=0');
  assert.ok(runs[0].finished_at);
  db.close();
});

// ── A11: the run history ───────────────────────────────────────────────────
test('A11 GET /api/settings/seed-registry/runs: newest first, 20 max, truncated, arrays parsed', async (t) => {
  if (!DatabaseSync) { t.skip('node:sqlite unavailable on this runtime'); return; }
  const { db, env } = freshDb();
  const none = await call(env, 'GET', '/api/settings/seed-registry/runs');
  assert.equal(none.status, 200, JSON.stringify(none.body));
  assert.deepEqual(none.body, { runs: [], truncated: false });

  const ins = db.prepare(`INSERT INTO registry_seed_runs (actor, plan_fp, status, rows, changed, pruned, changed_keys, pruned_keys, started_at, finished_at)
                          VALUES (?,?,'applied',10,1,0,?,?,?,?)`);
  for (let i = 1; i <= 21; i++) ins.run('operator', 'a'.repeat(64), JSON.stringify([`k${i}`]), '[]', ago(100 - i), ago(99 - i));
  db.prepare("INSERT INTO registry_seed_runs (actor, plan_fp, status, started_at) VALUES ('x','b','started',?)").run(ago(0));
  const r = await call(env, 'GET', '/api/settings/seed-registry/runs');
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.runs.length, 20);
  assert.equal(r.body.truncated, true);
  const ids = r.body.runs.map((x) => x.id);
  assert.deepEqual(ids, [...ids].sort((a, b) => b - a));
  assert.equal(ids[0], 22);
  assert.equal(r.body.runs[0].status, 'started');
  assert.deepEqual(r.body.runs[0].changed_keys, []);
  assert.deepEqual(r.body.runs[1].changed_keys, ['k21']);
  assert.deepEqual(r.body.runs[1].pruned_keys, []);
  assert.deepEqual(Object.keys(r.body.runs[1]), ['id', 'actor', 'plan_fp', 'status', 'rows', 'changed', 'pruned',
    'changed_keys', 'pruned_keys', 'error', 'started_at', 'finished_at']);
  db.close();
});

// ── A12: unapplied schema ──────────────────────────────────────────────────
test('A12 apply: registry_seed_runs not applied answers 503 schema not applied, no settings written', async (t) => {
  if (!DatabaseSync) { t.skip('node:sqlite unavailable on this runtime'); return; }
  const { db, env } = freshDb();
  freshFleet(db);
  db.exec('DROP TABLE registry_seed_runs');
  const plan = (await call(env, 'GET', '/api/settings/seed-registry/plan')).body;
  const s0 = count(db, 'settings');
  const r = await call(env, 'POST', APPLY, { plan_fp: plan.plan_fp, actor: 'operator@example.com' });
  assert.equal(r.status, 503);
  assert.equal(r.body.error, 'settings schema not applied');
  assert.equal(count(db, 'settings'), s0);
  const runs = await call(env, 'GET', '/api/settings/seed-registry/runs');
  assert.equal(runs.status, 503);
  db.close();
});

// ── A13: the CLI POST is unchanged ─────────────────────────────────────────
test('A13 POST /api/settings/seed-registry answers the CLI keys verbatim and writes no run row', async (t) => {
  if (!DatabaseSync) { t.skip('node:sqlite unavailable on this runtime'); return; }
  const { db, env } = freshDb();
  const r = await call(env, 'POST', '/api/settings/seed-registry');
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.deepEqual(Object.keys(r.body), ['rows', 'changed', 'pruned', 'changed_keys', 'pruned_keys', 'actor', 'as_of']);
  assert.equal(r.body.actor, REGISTRY_SEED_ACTOR);
  assert.ok(r.body.changed > 0);
  assert.equal(count(db, 'registry_seed_runs'), 0);
  db.close();
});
