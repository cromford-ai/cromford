import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import worker from '../src/index.js';
import { jobsSchemaSql } from './lib/jobs-schema.js';

// BH-1985: a BOX lane's `project_scoped: true` knob is read per project.
//
// lane-reaper is a box lane, and its LANE_REAP_DEADLINE_SECS is declared
// `project_scoped: true` (catalog/lanes.d/lane-reaper.json, BH-1770): the reaper
// reads `lane.lane-reaper.<project>.lane_reap_deadline_secs` through lane_knob
// for a build of that project. The status route built the project key only
// for `scope: "project"` lanes, so the console's project tab showed the FLEET
// value as the project's. These cases drive the real fetch handler over a real
// schema.sql database (the lanes-status-conductor.bh-1201 pattern, D2), with the
// rows written through the production writer, PUT /api/settings.

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

function freshD1() {
  const db = new DatabaseSync(':memory:');
  db.exec(SCHEMA);
  return { db, env: { DB: d1(db), HARNESS_SECRET: SECRET } };
}

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

async function put(env, key, value) {
  const r = await call(env, 'PUT', '/api/settings', { key, value, actor: 'test' });
  assert.equal(r.status, 200, `the settings writer refused ${key}: ${JSON.stringify(r.body)}`);
}

const lane = (r, id) => r.body.lanes.find((l) => l.id === id);
const PK = 'lane.lane-reaper.project-4.lane_reap_deadline_secs';
const GK = 'lane.lane-reaper.lane_reap_deadline_secs';

// ── W1 ──────────────────────────────────────────────────────────────────────
test('W1: a project tab reads the project row for a box lane\'s project_scoped knob', async (t) => {
  if (!DatabaseSync) { t.skip('node:sqlite unavailable on this runtime'); return; }
  const { db, env } = freshD1();
  await put(env, PK, '43200');
  await put(env, GK, '14400');

  const r = await call(env, 'GET', '/api/lanes/status?project=project-4');
  assert.equal(r.status, 200);
  const lr = lane(r, 'lane-reaper');
  assert.ok(lr, 'the status page has no lane-reaper lane at all');
  assert.equal(lr.scope, 'box', 'the fixture lane is not the box lane this case is about');
  const k = lr.knobs.LANE_REAP_DEADLINE_SECS;
  assert.ok(k, 'the deadline knob is missing although two rows set it');
  assert.equal(k.value, 43200, 'the project tab shows the fleet value, not project-4\'s own row');
  assert.equal(k.key, PK, 'the knob does not name the per-project key it was read from');
  assert.equal(k.source, 'settings');
  db.close();
});

// ── W2 ──────────────────────────────────────────────────────────────────────
test('W2: a project with no row of its own falls back to the lane-wide row', async (t) => {
  if (!DatabaseSync) { t.skip('node:sqlite unavailable on this runtime'); return; }
  const { db, env } = freshD1();
  await put(env, PK, '43200');
  await put(env, GK, '14400');

  const r = await call(env, 'GET', '/api/lanes/status?project=project-3');
  assert.equal(r.status, 200);
  const k = lane(r, 'lane-reaper').knobs.LANE_REAP_DEADLINE_SECS;
  assert.ok(k, 'the deadline knob is missing although the lane-wide row sets it');
  assert.equal(k.value, 14400, 'project-3 was handed project-4\'s row');
  assert.equal(k.key, GK);

  // And the hub view (no project) is the lane-wide row too.
  const hub = await call(env, 'GET', '/api/lanes/status');
  assert.equal(lane(hub, 'lane-reaper').knobs.LANE_REAP_DEADLINE_SECS.value, 14400);
  db.close();
});

// ── W3 ──────────────────────────────────────────────────────────────────────
test('W3: a knob that is not project_scoped ignores a project row, and the switch and spend stay fleet-wide', async (t) => {
  if (!DatabaseSync) { t.skip('node:sqlite unavailable on this runtime'); return; }
  const { db, env } = freshD1();
  await put(env, PK, '43200');
  await put(env, 'lane.lane-reaper.project-4.lane_reap_kill_wait_s', '99');
  await put(env, 'lane.lane-reaper.lane_reap_kill_wait_s', '45');

  const p = await call(env, 'GET', '/api/lanes/status?project=project-4');
  const hub = await call(env, 'GET', '/api/lanes/status');
  assert.equal(p.status, 200);
  assert.equal(hub.status, 200);
  const lp = lane(p, 'lane-reaper');
  const lh = lane(hub, 'lane-reaper');

  const kw = lp.knobs.LANE_REAP_KILL_WAIT_S;
  assert.ok(kw, 'the kill-wait knob is missing although the lane-wide row sets it');
  assert.equal(kw.value, 45, 'a knob with no project_scoped read a per-project row nothing on a box reads');
  assert.equal(kw.key, 'lane.lane-reaper.lane_reap_kill_wait_s');
  // The positive half, so this case cannot pass with per-project reads off.
  assert.equal(lp.knobs.LANE_REAP_DEADLINE_SECS.value, 43200);

  // The switch, the state and the spend are not per project for a box lane.
  assert.deepEqual(lp.switch, lh.switch, 'the box lane grew a per-project switch');
  assert.deepEqual(lp.held_by, lh.held_by);
  assert.equal(lp.off, lh.off);
  assert.equal(lp.project, null, 'a box lane was labelled with the project');
  assert.equal(lp.runs_today, lh.runs_today);
  assert.equal(lp.cost_today, lh.cost_today);
  assert.equal(lp.cost_7d, lh.cost_7d);
  db.close();
});
