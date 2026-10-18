import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';

// BH-7191 (BH-7303): a registry box carries a role (build, review, gate,
// standby, hub, gate-only, retired). The import and the box write routes
// validate it, GET returns it, and a null role is a row with no `role` key, so
// old readers see the old shape. Driven through the worker's fetch handler
// against real SQLite. The schema from schema.d has no role column: readAll
// must add it (ensureColumns) before it names it.

const SECRET = 'fixture-secret';
const ADMIN = 'fixture-admin-token';
const NOW_MS = Date.parse('2026-10-18T10:00:00Z');

async function open(t) {
  t.mock.timers.enable({ apis: ['Date'], now: NOW_MS });
  const env = await openDb();
  if (!env) t.skip('node:sqlite unavailable on this runtime');
  return env;
}

async function call(env, method, path, { body, admin = ADMIN } = {}) {
  const headers = { authorization: `Bearer ${SECRET}` };
  if (admin !== undefined) headers['x-registry-admin-token'] = admin;
  const init = { method, headers };
  if (body !== undefined) {
    init.body = JSON.stringify(body);
    headers['content-type'] = 'application/json';
  }
  const res = await worker.fetch(new Request(`https://jobs.test${path}`, init), env);
  return { status: res.status, body: await res.json() };
}

const envOf = (DB) => ({ DB, HARNESS_SECRET: SECRET, REGISTRY_ADMIN_TOKEN: ADMIN });
const importIt = (env, body) => call(env, 'POST', '/api/registry/import', { body });
const count = (db, table) => db.prepare(`SELECT COUNT(*) AS n FROM ${table}`).get().n;
const version = (db) => db.prepare('SELECT version FROM registry_meta WHERE id=1').get().version;
const hasRoleCol = (db) => db.prepare('PRAGMA table_info(registry_boxes)').all().some((c) => c.name === 'role');
const boxOf = (g, name) => g.body.boxes.find((b) => b.box === name);

function fixture(role) {
  const review = { box: 'box-review-2', box_id: 'review2', tailnet_ip: null, cost_box: 'review2', standby_hub_name: null, standby_hub_id: null };
  if (role !== undefined) review.role = role;
  return {
    actor: 'registry-seed',
    projects: [
      { project: 'fixture-proj', repo: 'example-org/fixture-proj', prod: '-', board_prefix: '-', cron_offset: 1, box: 'box-small', position: 0, status: 'active' },
    ],
    boxes: [
      review,
      { box: 'box-small', box_id: 'small', tailnet_ip: null, cost_box: 'small', standby_hub_name: null, standby_hub_id: null },
    ],
    lane_boxes: [{ lane: 'watchdog-ping', box_id: 'review2' }],
    box_accounts: [],
  };
}

test('RR1: a box imported as gate-only comes back from GET with that role', async (t) => {
  const { DB } = await open(t);
  const env = envOf(DB);
  const r = await importIt(env, fixture('gate-only'));
  assert.equal(r.status, 200, JSON.stringify(r.body));
  const g = await call(env, 'GET', '/api/registry');
  assert.equal(g.status, 200);
  assert.equal(boxOf(g, 'box-review-2').role, 'gate-only');
});

test('RR2: the GET rows posted back as an import change nothing', async (t) => {
  const { db, DB } = await open(t);
  const env = envOf(DB);
  assert.equal((await importIt(env, fixture('gate-only'))).status, 200);
  const v1 = version(db);
  const g = await call(env, 'GET', '/api/registry');
  const back = { actor: 'registry-seed', projects: g.body.projects, boxes: g.body.boxes, lane_boxes: g.body.lane_boxes, box_accounts: g.body.box_accounts };
  const r = await importIt(env, back);
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.changed, 0);
  assert.equal(r.body.version, v1);
  assert.equal(version(db), v1);
});

test('RR3: a role outside the seven values is 400 and writes nothing', async (t) => {
  const { db, DB } = await open(t);
  const env = envOf(DB);
  const boss = await importIt(env, fixture('boss'));
  assert.equal(boss.status, 400);
  assert.match(boss.body.error, /boxes\[0\]\.role/);
  assert.match(boss.body.error, /build, review, gate, standby, hub, gate-only, retired/);
  for (const bad of ['', 'Gate-only', 1, 'gate only', 'GATE-ONLY', 'gate-only-x']) {
    const r = await importIt(env, fixture(bad));
    assert.equal(r.status, 400, `role ${JSON.stringify(bad)} must be refused`);
    assert.match(r.body.error, /boxes\[0\]\.role/, `role ${JSON.stringify(bad)}`);
  }
  assert.equal(count(db, 'registry_boxes'), 0);
  assert.equal(count(db, 'registry_audit'), 0);
  assert.equal(version(db), 0);
  for (const ok of ['build', 'review', 'gate', 'standby', 'hub', 'gate-only', 'retired', null]) {
    const r = await importIt(env, fixture(ok));
    assert.equal(r.status, 200, `role ${JSON.stringify(ok)}: ${JSON.stringify(r.body)}`);
  }
});

test('RR4: a box with no role has no role key in the GET row', async (t) => {
  const { DB } = await open(t);
  const env = envOf(DB);
  assert.equal((await importIt(env, fixture())).status, 200);
  const g = await call(env, 'GET', '/api/registry');
  const row = boxOf(g, 'box-review-2');
  assert.ok(row, 'the box row is there');
  assert.equal(Object.hasOwn(row, 'role'), false, JSON.stringify(row));
  assert.equal(Object.hasOwn(boxOf(g, 'box-small'), 'role'), false);
  // An explicit null is the same row.
  const again = await importIt(env, fixture(null));
  assert.equal(again.body.changed, 0);
});

test('RR5: PATCH a box role writes one audit row; a bad role is 400', async (t) => {
  const { db, DB } = await open(t);
  const env = envOf(DB);
  assert.equal((await importIt(env, fixture())).status, 200);
  const auditBefore = count(db, 'registry_audit');
  const r = await call(env, 'PATCH', '/api/registry/boxes/box-review-2', { body: { role: 'retired', actor: 'fixture-actor' } });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.changed, 1);
  const g = await call(env, 'GET', '/api/registry');
  assert.equal(boxOf(g, 'box-review-2').role, 'retired');
  assert.equal(count(db, 'registry_audit'), auditBefore + 1);
  const a = db.prepare("SELECT entity, key, new_value FROM registry_audit WHERE actor='fixture-actor'").all();
  assert.equal(a.length, 1);
  assert.equal(a[0].entity, 'box');
  assert.equal(a[0].key, 'box-review-2');
  assert.equal(JSON.parse(a[0].new_value).role, 'retired');

  const bad = await call(env, 'PATCH', '/api/registry/boxes/box-review-2', { body: { role: 'boss' } });
  assert.equal(bad.status, 400);
  assert.match(bad.body.error, /role/);
  assert.equal(count(db, 'registry_audit'), auditBefore + 1);

  // POST /api/registry/boxes takes a role too.
  const add = await call(env, 'POST', '/api/registry/boxes', { body: { box: 'bh-hub-2', box_id: 'hub2', role: 'hub' } });
  assert.equal(add.status, 200, JSON.stringify(add.body));
  assert.equal(boxOf(await call(env, 'GET', '/api/registry'), 'bh-hub-2').role, 'hub');
  const addBad = await call(env, 'POST', '/api/registry/boxes', { body: { box: 'bh-hub-3', box_id: 'hub3', role: 'boss' } });
  assert.equal(addBad.status, 400);
});

test('RR6: GET on a schema with no role column adds it and answers 200', async (t) => {
  const { db, DB } = await open(t);
  assert.equal(hasRoleCol(db), false, 'the schema.d table starts without the column');
  const g = await call(envOf(DB), 'GET', '/api/registry');
  assert.equal(g.status, 200, JSON.stringify(g.body));
  assert.equal(hasRoleCol(db), true, 'readAll added the column');
});
