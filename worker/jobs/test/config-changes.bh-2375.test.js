// BH-2375 (BH-2330.0): two new config_changes kinds (SETTING, FLAG) and the
// one shared read over the table, listConfigChanges, behind
// GET /api/config-changes. There is one audit store (the operator's RESUME of
// 2026-09-27): no settings_changes or flag_changes table is created.
//
// WHAT IS PINNED, on a REAL schema.sql database behind the node:sqlite shim:
//   L1  CONFIG_KINDS carries SETTING='setting' and FLAG='flag', stays frozen, all distinct;
//   L2  a kind filter returns only that kind, newest first; kind+name only that name;
//   L3  limit+1 measures `truncated`; a bad limit falls back like the other audit GETs;
//       an unknown kind or a bad name is {error}, never an unfiltered read;
//   L4  the existing configChangeStmts writes a FLAG row the reader returns;
//   R1-R3 the same through the real worker.fetch (bearer, router, handler);
//   N2  schema.sql creates no settings_changes or flag_changes table.
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { CONFIG_KINDS, configChangeStmts, listConfigChanges } from '../src/lib/config-changes.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';

const SECRET = 'test-secret';
const T = '2026-09-27T20:00:00Z';

async function withDb(t, fn) {
  const opened = await openDb();
  if (opened === null) {
    t.skip('node:sqlite unavailable in this runtime');
    return;
  }
  await fn(opened);
}

const insert = (db, kind, name, n = 1) => {
  for (let i = 0; i < n; i++) {
    db.prepare(
      "INSERT INTO config_changes (kind, name, before_json, after_json, actor, reason, at) VALUES (?,?,NULL,'{}','api',NULL,?)",
    ).run(kind, name, T);
  }
};

const get = (DB, path) => worker.fetch(
  new Request(`https://jobs.test${path}`, { headers: { authorization: `Bearer ${SECRET}` } }),
  { DB, HARNESS_SECRET: SECRET },
).then(async (res) => ({ status: res.status, body: await res.json().catch(() => null) }));

test('L1 CONFIG_KINDS gains SETTING and FLAG, stays frozen, every value distinct', () => {
  assert.equal(CONFIG_KINDS.SETTING, 'setting');
  assert.equal(CONFIG_KINDS.FLAG, 'flag');
  assert.ok(Object.isFrozen(CONFIG_KINDS));
  const values = Object.values(CONFIG_KINDS);
  // BH-3155 (BH-2325.0) added MERGE_QUEUE and HELD_PAGE: nine became eleven;
  // BH-4082 added PROJECT: twelve. BH-8317 added PROJECT_SECRET: thirteen.
  assert.equal(values.length, 13);
  assert.equal(new Set(values).size, values.length);
});

test('L2 listConfigChanges filters by kind (newest first) and by kind+name', (t) => withDb(t, async ({ db, DB }) => {
  insert(db, 'setting', 'a.b');
  insert(db, 'cost_cap', 'conf.cost-caps.default');
  insert(db, 'setting', 'c.d');
  insert(db, 'flag', 'x');
  const byKind = await listConfigChanges({ DB }, { kind: 'setting' }, T);
  assert.equal(byKind.error, undefined);
  assert.deepEqual(byKind.changes.map((r) => r.name), ['c.d', 'a.b']);
  assert.ok(byKind.changes[0].id > byKind.changes[1].id);
  assert.equal(byKind.truncated, false);
  assert.equal(byKind.as_of, T);
  const byName = await listConfigChanges({ DB }, { kind: 'setting', name: 'a.b' }, T);
  assert.deepEqual(byName.changes.map((r) => [r.kind, r.name]), [['setting', 'a.b']]);
  const every = await listConfigChanges({ DB }, {}, T);
  assert.equal(every.changes.length, 4);
}));

test('L3 limit+1 measures truncated; bad limits fall back; bad kind/name is {error}', (t) => withDb(t, async ({ db, DB }) => {
  insert(db, 'setting', 'a', 3);
  const two = await listConfigChanges({ DB }, { kind: 'setting', limit: 2 }, T);
  assert.equal(two.changes.length, 2);
  assert.equal(two.truncated, true);
  const three = await listConfigChanges({ DB }, { kind: 'setting', limit: 3 }, T);
  assert.equal(three.truncated, false);

  // The binds are observed, not inferred: 'abc' reads 100+1, 99999 reads 500+1, -5 reads 1+1.
  const seen = [];
  const spy = {
    prepare: (sql) => {
      const s = DB.prepare(sql);
      return { run: () => s.run(), bind: (...b) => { seen.push(b[0]); return s.bind(...b); } };
    },
  };
  for (const limit of ['abc', 99999, -5]) await listConfigChanges({ DB: spy }, { limit }, T);
  assert.deepEqual(seen.filter((b) => typeof b === 'number'), [101, 501, 2]);

  for (const kind of ['settings_changes', "'; DROP TABLE config_changes; --", '']) {
    const r = await listConfigChanges({ DB }, { kind }, T);
    assert.ok(r.error, `kind ${JSON.stringify(kind)} is refused`);
    assert.equal(r.changes, undefined);
  }
  for (const name of ['', 'n'.repeat(257)]) {
    const r = await listConfigChanges({ DB }, { name }, T);
    assert.ok(r.error, `name of length ${name.length} is refused`);
  }
  assert.equal(db.prepare('SELECT count(*) AS n FROM config_changes').get().n, 3, 'nothing was dropped');
}));

test('L4 the existing configChangeStmts writes a FLAG row the reader returns', (t) => withDb(t, async ({ DB }) => {
  const stmts = configChangeStmts({ DB }, CONFIG_KINDS.FLAG, 'x', { active: 0 }, { active: 1 }, ['active'], 'console', 'why', T);
  assert.equal(stmts.length, 1);
  await DB.batch(stmts);
  const r = await listConfigChanges({ DB }, { kind: 'flag', name: 'x' }, T);
  assert.equal(r.changes.length, 1);
  const row = r.changes[0];
  assert.deepEqual(JSON.parse(row.before_json), { active: 0 });
  assert.deepEqual(JSON.parse(row.after_json), { active: 1 });
  assert.equal(row.actor, 'console');
  assert.equal(row.reason, 'why');
}));

test('R1 GET /api/config-changes?kind=setting answers 200 with only setting rows', (t) => withDb(t, async ({ db, DB }) => {
  insert(db, 'setting', 'a.b');
  insert(db, 'flag', 'x');
  const r = await get(DB, '/api/config-changes?kind=setting');
  assert.equal(r.status, 200);
  assert.deepEqual(Object.keys(r.body).sort(), ['as_of', 'changes', 'truncated']);
  assert.deepEqual(r.body.changes.map((c) => c.kind), ['setting']);
  assert.equal(r.body.truncated, false);
  const named = await get(DB, `/api/config-changes?kind=flag&name=x&limit=1`);
  assert.equal(named.status, 200);
  assert.deepEqual(named.body.changes.map((c) => c.name), ['x']);
}));

test('R2 an unknown kind or an empty name is a 400, never an unfiltered read', (t) => withDb(t, async ({ db, DB }) => {
  insert(db, 'setting', 'a.b');
  const badKind = await get(DB, '/api/config-changes?kind=settings_changes');
  assert.equal(badKind.status, 400);
  assert.match(badKind.body.error, /kind/);
  assert.equal(badKind.body.changes, undefined);
  const emptyName = await get(DB, '/api/config-changes?name=');
  assert.equal(emptyName.status, 400);
  assert.match(emptyName.body.error, /name/);
  const unauth = await worker.fetch(new Request('https://jobs.test/api/config-changes'), { DB, HARNESS_SECRET: SECRET });
  assert.equal(unauth.status, 401);
}));

test('R3 a D1 without config_changes answers 200 {changes: []} (ensureTable belt)', (t) => withDb(t, async ({ db, DB }) => {
  db.exec('DROP TABLE config_changes');
  const r = await get(DB, '/api/config-changes');
  assert.equal(r.status, 200);
  assert.deepEqual(r.body.changes, []);
  assert.equal(r.body.truncated, false);
}));

test('N2 schema.sql creates no settings_changes or flag_changes table', (t) => withDb(t, async ({ db }) => {
  const names = db.prepare("SELECT name FROM sqlite_master WHERE type='table'").all().map((r) => r.name);
  assert.ok(names.includes('config_changes'));
  for (const bad of ['settings_changes', 'flag_changes', 'change_log']) assert.ok(!names.includes(bad), bad);
}));
