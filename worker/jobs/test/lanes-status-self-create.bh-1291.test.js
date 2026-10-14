import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import worker from '../src/index.js';
import { jobsSchemaSql } from './lib/jobs-schema.js';

// BH-1291 (N1): GET /api/lanes/status self-creates the two BH-1165 tables.
//
// WHY A REAL DATABASE. The defect is that the route READS `lane_ticks` and
// `lane_flag_sightings` inside a try/catch and never calls `ensureTable`, so on
// a D1 where no lane has posted yet every read throws, every lane reports an
// unknown tick, and the worker log carries two `unreadable` lines on every
// single page load until some lane happens to POST. A pattern-matching stub
// answers `{rows:[]}` to anything and cannot tell "the table is there and
// empty" from "the table does not exist" — which is exactly the distinction
// this ticket is about. So the fixture is a real schema.sql database with the
// two tables DROPPED (the fresh-D1 state), and the assertions read
// `sqlite_master` back.
//
// The DROP lives in this fixture and nowhere else: product code never drops a
// table (D20), it is how a test reproduces a database that predates BH-1165.

const SECRET = 'test-secret';
const SCHEMA = jobsSchemaSql();

let DatabaseSync = null;
try { ({ DatabaseSync } = await import('node:sqlite')); } catch { DatabaseSync = null; }

// ── a D1-shaped adapter over node:sqlite (the machines.bh-1055 pattern) ─────
function d1(db) {
  const exec = (sql, binds) => {
    const stmt = db.prepare(sql);
    if (/^\s*(SELECT|PRAGMA)\b/i.test(sql)) {
      return { results: stmt.all(...binds), meta: { changes: 0 } };
    }
    const r = stmt.run(...binds);
    return { results: [], meta: { changes: Number(r.changes) } };
  };
  const make = (sql, binds) => ({
    _sql: sql,
    _binds: binds,
    bind: (...b) => make(sql, b),
    run: async () => exec(sql, binds),
    first: async () => { const r = exec(sql, binds); return r.results.length ? r.results[0] : null; },
    all: async () => exec(sql, binds),
  });
  return {
    prepare: (sql) => make(sql, []),
    batch: async (stmts) => {
      db.exec('BEGIN');
      try {
        const out = stmts.map((s) => exec(s._sql, s._binds));
        db.exec('COMMIT');
        return out;
      } catch (e) {
        db.exec('ROLLBACK');
        throw e;
      }
    },
  };
}

// A database that has EVERY table schema.sql declares except the two BH-1165
// ones — a worker deployed against a D1 where no lane has ever posted. `env` is
// rebuilt per test because ensureTable caches per DB object (a WeakMap keyed on
// env.DB), so a shared env would let one test's create satisfy the next.
function freshD1() {
  const db = new DatabaseSync(':memory:');
  db.exec(SCHEMA);
  db.exec('DROP TABLE lane_ticks');
  db.exec('DROP TABLE lane_flag_sightings');
  return { db, env: { DB: d1(db), HARNESS_SECRET: SECRET } };
}

const tables = (db) => db.prepare(
  "SELECT name FROM sqlite_master WHERE type='table' AND name IN ('lane_ticks','lane_flag_sightings') ORDER BY name"
).all().map((r) => r.name);

const indexes = (db) => db.prepare(
  "SELECT name FROM sqlite_master WHERE type='index' AND name IN ('idx_lane_ticks_lane','idx_lane_flag_sightings_lane') ORDER BY name"
).all().map((r) => r.name);

async function call(env, method, path, body) {
  const headers = { authorization: 'Bearer ' + SECRET };
  const init = { method, headers };
  if (body !== undefined) {
    headers['content-type'] = 'application/json';
    init.body = JSON.stringify(body);
  }
  const res = await worker.fetch(new Request('https://jobs.test' + path, init), env);
  return { status: res.status, body: await res.json().catch(() => null) };
}

// Captures what the route wrote to the worker log for the duration of one call.
async function withLog(fn) {
  const lines = [];
  const real = console.log;
  console.log = (...a) => { lines.push(a.map(String).join(' ')); };
  try { return { out: await fn(), lines }; } finally { console.log = real; }
}

const lane = (r, id) => r.body.lanes.find((l) => l.id === id);

// ── A ───────────────────────────────────────────────────────────────────────
test('a fresh D1 gets both BH-1165 tables from the status route itself', async (t) => {
  if (!DatabaseSync) { t.skip('node:sqlite unavailable on this runtime'); return; }
  const { db, env } = freshD1();
  assert.deepEqual(tables(db), [], 'the fixture did not start from a fresh D1');

  const r = await call(env, 'GET', '/api/lanes/status');
  assert.equal(r.status, 200);
  assert.deepEqual(tables(db), ['lane_flag_sightings', 'lane_ticks'],
    'the status route read the two BH-1165 tables without creating them');
  assert.deepEqual(indexes(db), ['idx_lane_flag_sightings_lane', 'idx_lane_ticks_lane'],
    'the tables were created without the indexes CREATED_TABLES declares');
  db.close();
});

// ── B ───────────────────────────────────────────────────────────────────────
test('a fresh D1 renders no "unreadable" degrade line', async (t) => {
  if (!DatabaseSync) { t.skip('node:sqlite unavailable on this runtime'); return; }
  const { db, env } = freshD1();

  const { out: r, lines } = await withLog(() => call(env, 'GET', '/api/lanes/status'));
  assert.equal(r.status, 200);
  const degrades = lines.filter((l) => l.includes('unreadable'));
  assert.deepEqual(degrades, [],
    'the route still degrades on a database it is supposed to set up itself');
  db.close();
});

// ── C ───────────────────────────────────────────────────────────────────────
test('a tick posted after the first status read is visible on the next read', async (t) => {
  if (!DatabaseSync) { t.skip('node:sqlite unavailable on this runtime'); return; }
  const { db, env } = freshD1();

  // Read first, so the table under the POST is the one the STATUS route made
  // and not one the liveness route had to create for it.
  assert.equal((await call(env, 'GET', '/api/lanes/status')).status, 200);
  assert.deepEqual(tables(db), ['lane_flag_sightings', 'lane_ticks'],
    'the POST below would be writing into a table the liveness route created');
  // The exact body bin/lib/lane-gate.sh posts (D4).
  const posted = await call(env, 'POST', '/api/lanes/liveness',
    { lane: 'merge-conductor', box: 'hub', outcome: 'ran' });
  assert.equal(posted.status, 200);
  const at = posted.body.tick.at;
  assert.match(at, /^\d{4}-\d{2}-\d{2}T/);

  const r = await call(env, 'GET', '/api/lanes/status');
  assert.equal(lane(r, 'merge-conductor').last_tick_at, at);
  assert.equal(lane(r, 'merge-conductor').last_outcome, 'ran');
  db.close();
});

// ── D ───────────────────────────────────────────────────────────────────────
test('a second status read reuses the tables it created', async (t) => {
  if (!DatabaseSync) { t.skip('node:sqlite unavailable on this runtime'); return; }
  const { db, env } = freshD1();

  assert.equal((await call(env, 'GET', '/api/lanes/status')).status, 200);
  const { out: second, lines } = await withLog(() => call(env, 'GET', '/api/lanes/status'));
  assert.equal(second.status, 200);
  assert.deepEqual(tables(db), ['lane_flag_sightings', 'lane_ticks']);
  assert.deepEqual(lines.filter((l) => l.includes('unreadable')), []);
  assert.equal(lane(second, 'merge-conductor').last_tick_at, null,
    'a read with no tick posted must report an unknown tick, not invent one');
  db.close();
});

// ── E (I1) ──────────────────────────────────────────────────────────────────
test('PUT /api/settings refuses a row that would re-aim testhost-tick at another Fly app', async (t) => {
  if (!DatabaseSync) { t.skip('node:sqlite unavailable on this runtime'); return; }
  const { db, env } = freshD1();

  // The exact write the ticket describes, through the route that holds the
  // bearer — the last of the four refusals (CLI, seed, console, here) and the
  // only one a caller cannot route around.
  const r = await call(env, 'PUT', '/api/settings',
    { key: 'lane.testhost-tick.testhost_app', value: 'someone-elses-app', actor: 'test' });
  assert.equal(r.status, 400, 'a settings row re-aimed the hub idle-stop at another app');
  assert.match(r.body.error, /not settable from the control plane/);
  assert.equal(
    db.prepare("SELECT COUNT(*) AS n FROM settings WHERE key='lane.testhost-tick.testhost_app'").get().n, 0,
    'the refused key was written anyway');

  // The lane's genuinely tunable knob still goes through: the rule reaches the
  // app name and nothing else.
  const ok = await call(env, 'PUT', '/api/settings',
    { key: 'lane.testhost-tick.testhost_idle_stop_min', value: 45, actor: 'test' });
  assert.equal(ok.status, 200, 'the APP rule froze an operator number it was never meant to touch');
  db.close();
});
