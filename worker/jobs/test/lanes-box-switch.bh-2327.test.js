import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import worker from '../src/index.js';
import { jobsSchemaSql } from './lib/jobs-schema.js';

// BH-2327: a box-scope lane can be switched off on ONE box by the row
// `lane-off-<id>.box.<box>`, and GET /api/lanes/status reports that per box.
// These drive the real fetch handler over a real schema.sql database (the
// lanes-project-scoped.bh-1985 pattern, D2), with every row written through
// its production writer: PUT /api/flags, POST /api/lanes/liveness and
// POST /api/lanes/flag-seen.

const SECRET = 'test-secret';
const SCHEMA = jobsSchemaSql();

let DatabaseSync = null;
try { ({ DatabaseSync } = await import('node:sqlite')); } catch { DatabaseSync = null; }

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
    batch: async (stmts) => stmts.map((s) => exec(s._sql, s._binds)),
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

async function ok(env, method, path, body) {
  const r = await call(env, method, path, body);
  assert.equal(r.status, 200, `${method} ${path} refused: ${JSON.stringify(r.body)}`);
  return r.body;
}
const tick = (env, lane, box) => ok(env, 'POST', '/api/lanes/liveness', { lane, box, outcome: 'ran' });
const flag = (env, name, active) => ok(env, 'PUT', '/api/flags', { name, active, actor: 'console', reason: 'test' });
const status = async (env) => (await ok(env, 'GET', '/api/lanes/status')).lanes;
const lane = (lanes, id) => lanes.find((l) => l.id === id);

// The switch name every layer agrees on — the same literal is pinned in
// tests/lane-gate-box-switch.bh-2327-test.sh and
// console-ui/tests/settings-box-switch.bh-2327.test.js.
const SW = 'lane-off-disk-clean.box.b';

test('W1: per-box state for a box lane; one box off does not turn the lane off', async (t) => {
  if (!DatabaseSync) { t.skip('node:sqlite unavailable on this runtime'); return; }
  const { env } = freshD1();
  await tick(env, 'disk-clean', 'a');
  await tick(env, 'disk-clean', 'b');
  await flag(env, SW, 1);
  const l = lane(await status(env), 'disk-clean');
  assert.deepEqual(l.boxes.map((b) => [b.box, b.switch_name, b.off, b.off_source]), [
    ['a', 'lane-off-disk-clean.box.a', false, null],
    ['b', SW, true, 'db'],
  ]);
  assert.equal(l.boxes_off, 1);
  assert.equal(l.boxes_complete, true);
  assert.equal(l.off, false);
  const b = l.boxes[1];
  assert.equal(b.paused_by, 'console');
  assert.equal(b.paused_reason, 'test');
  assert.ok(b.paused_since, 'paused_since carries the row time');
  assert.ok(l.boxes[0].last_tick_at, 'box a carries its own last tick');
  assert.equal(l.boxes[0].last_outcome, 'ran');

  // flipped back on -> the box reads on, the row still lists it
  await flag(env, SW, 0);
  const l2 = lane(await status(env), 'disk-clean');
  assert.equal(l2.boxes_off, 0);
  assert.equal(l2.boxes.find((x) => x.box === 'b').off, false);
});

test('W2: a box that never ticked but holds a row still shows', async (t) => {
  if (!DatabaseSync) { t.skip('node:sqlite unavailable on this runtime'); return; }
  const { env } = freshD1();
  await tick(env, 'disk-clean', 'a');
  await flag(env, 'lane-off-disk-clean.box.c', 1);
  const l = lane(await status(env), 'disk-clean');
  assert.deepEqual(l.boxes.map((b) => [b.box, b.off]), [['a', false], ['c', true]]);
  assert.equal(l.boxes.find((b) => b.box === 'c').last_tick_at, null);
  // a row for ANOTHER lane's box switch does not leak in
  assert.ok(!l.boxes.some((b) => b.box === 'x'));
});

test('W3: hub and project lanes carry no boxes key', async (t) => {
  if (!DatabaseSync) { t.skip('node:sqlite unavailable on this runtime'); return; }
  const { env } = freshD1();
  await tick(env, 'merge-conductor', 'hub');
  await flag(env, 'lane-off-merge-conductor.box.hub', 1);
  const lanes = await status(env);
  for (const id of ['merge-conductor', 'review-prs']) {
    const l = lane(lanes, id);
    assert.ok(l, `${id} missing from status`);
    assert.equal('boxes' in l, false, `${id} carries boxes`);
    assert.equal('boxes_off' in l, false, `${id} carries boxes_off`);
    assert.equal('boxes_complete' in l, false, `${id} carries boxes_complete`);
  }
  // and the box-form row does not turn the hub lane off either
  assert.equal(lane(lanes, 'merge-conductor').off, false);
});

test('W4: a per-box file sighting is that box only, never lane-wide off', async (t) => {
  if (!DatabaseSync) { t.skip('node:sqlite unavailable on this runtime'); return; }
  const { env } = freshD1();
  await tick(env, 'disk-clean', 'a');
  await tick(env, 'disk-clean', 'b');
  await ok(env, 'POST', '/api/lanes/flag-seen',
    { name: 'lane-off-disk-clean.box.a', lane: 'disk-clean', box: 'a', active: 1 });
  const l = lane(await status(env), 'disk-clean');
  assert.equal(l.off, false, 'one box\'s file turned the lane off fleet-wide');
  assert.deepEqual(l.flag_boxes, []);
  assert.deepEqual(l.held_by, []);
  const a = l.boxes.find((b) => b.box === 'a');
  assert.equal(a.off, true);
  assert.equal(a.off_source, 'flag');
  assert.equal(a.paused_by, 'a');
  assert.equal(l.boxes_off, 1);
  // a lane-wide sighting still turns the lane off, as before
  await ok(env, 'POST', '/api/lanes/flag-seen',
    { name: 'lane-off-disk-clean', lane: 'disk-clean', box: 'b', active: 1 });
  const l2 = lane(await status(env), 'disk-clean');
  assert.equal(l2.off, true);
  assert.deepEqual(l2.flag_boxes, ['b']);
});

test('W5: a capped lane_ticks read says the box list may be incomplete', async (t) => {
  if (!DatabaseSync) { t.skip('node:sqlite unavailable on this runtime'); return; }
  const { db, env } = freshD1();
  await tick(env, 'disk-clean', 'seed');   // creates lane_ticks through its writer
  const ins = db.prepare(`INSERT INTO lane_ticks (lane, project, box, last_outcome, last_tick_at, why, updated_at)
                          VALUES ('watchdog-ping','-',?,'ran','2026-09-01T00:00:00Z',NULL,'2026-09-01T00:00:00Z')`);
  for (let i = 0; i < 2000; i++) ins.run('box-' + i);
  const lanes = await status(env);
  assert.equal(lane(lanes, 'disk-clean').boxes_complete, false);
  assert.equal(lane(lanes, 'watchdog-ping').boxes_complete, false);
});
