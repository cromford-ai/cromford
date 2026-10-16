import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { jobsSchemaSql } from './lib/jobs-schema.js';

// BH-6971 (BH-6546.1): every alert belongs to a component. alerts.component is
// an ADDED column (core.js ADDED_COLUMNS.alerts) with idx_alerts_component
// (ADDED_INDEXES.alerts), GET /api/alerts filters on it, and POST
// /api/alerts/component stamps it on rows that have none. All through
// worker.fetch over node:sqlite and the d1 shim of cost-rows-lane-index.bh-2489.
// The plans below are node:sqlite's; the live D1 plan is not probed here.

const SECRET = 'test-secret';
const SCHEMA = jobsSchemaSql();
let DatabaseSync = null;
try { ({ DatabaseSync } = await import('node:sqlite')); } catch { DatabaseSync = null; }
const skip = DatabaseSync ? false : 'node:sqlite unavailable on this runtime';

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
  return {
    prepare: (sql) => make(sql, []),
    batch: async (stmts) => {
      db.exec('BEGIN');
      try { const out = stmts.map((s) => exec(s._sql, s._binds)); db.exec('COMMIT'); return out; }
      catch (e) { db.exec('ROLLBACK'); throw e; }
    },
  };
}
// The live alerts table on deploy day: schema.d's CREATE, which has no component.
function fresh() {
  const db = new DatabaseSync(':memory:');
  db.exec(SCHEMA);
  return { db, env: { DB: d1(db), HARNESS_SECRET: SECRET } };
}
async function call(env, method, path, body, auth = true) {
  const headers = auth ? { authorization: 'Bearer ' + SECRET } : {};
  const init = { method, headers };
  if (body !== undefined) { headers['content-type'] = 'application/json'; init.body = JSON.stringify(body); }
  const res = await worker.fetch(new Request('https://jobs.test' + path, init), env);
  return { status: res.status, body: await res.json().catch(() => null) };
}
const cols = (db) => db.prepare('PRAGMA table_info(alerts)').all().map((r) => r.name);
const idx = (db) => db.prepare('PRAGMA index_list(alerts)').all().map((r) => r.name);
function seed(db, rows) {
  const ins = db.prepare(`INSERT INTO alerts (id, family, box, project, line, severity, first_seen, last_seen, count,
    state, claimed_by, claimed_at, notified_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)`);
  for (const r of rows) {
    ins.run(r.id, 'abcdef012345', 'hub', '', r.line || 'x', 'warn', '2026-10-15T10:00:00Z',
      r.last_seen || '2026-10-15T10:00:00Z', 1, r.state || 'new', r.claimed_by ?? null, r.claimed_at ?? null,
      r.notified_at ?? null);
    if (r.component !== undefined) db.prepare('UPDATE alerts SET component=? WHERE id=?').run(r.component, r.id);
  }
}
const ids = (b) => b.alerts.map((a) => a.id).sort();

test('A1: the first GET adds alerts.component and idx_alerts_component to the pre-change table', { skip }, async () => {
  const { db, env } = fresh();
  assert.ok(!cols(db).includes('component'), 'the schema.d CREATE must not carry component (ADDED column)');
  assert.ok(!idx(db).includes('idx_alerts_component'));
  const r = await call(env, 'GET', '/api/alerts');
  assert.equal(r.status, 200);
  assert.ok(cols(db).includes('component'));
  assert.ok(idx(db).includes('idx_alerts_component'));
  const c = db.prepare('PRAGMA table_info(alerts)').all().find((x) => x.name === 'component');
  assert.equal(c.notnull, 0, 'component is nullable');
});

test('A2: GET /api/alerts?component=a returns only the a rows', { skip }, async () => {
  const { db, env } = fresh();
  await call(env, 'GET', '/api/alerts');
  seed(db, [{ id: 'a1', component: 'a' }, { id: 'a2', component: 'a' }, { id: 'b1', component: 'b' }, { id: 'n1' }]);
  const r = await call(env, 'GET', '/api/alerts?component=a');
  assert.equal(r.status, 200);
  assert.deepEqual(ids(r.body), ['a1', 'a2']);
  assert.ok(r.body.alerts.every((a) => a.component === 'a'));
  // No filter: every row, as before.
  assert.deepEqual(ids((await call(env, 'GET', '/api/alerts')).body), ['a1', 'a2', 'b1', 'n1']);
  // group=family takes the same filter.
  const g = await call(env, 'GET', '/api/alerts?group=family&component=b');
  assert.deepEqual(g.body.families.map((f) => f.n), [1]);
});

test('A3: GET /api/alerts?unstamped=1&state=!resolved returns only NULL, open rows', { skip }, async () => {
  const { db, env } = fresh();
  await call(env, 'GET', '/api/alerts');
  seed(db, [{ id: 'n1' }, { id: 'n2', state: 'triaged' }, { id: 'nr', state: 'resolved' }, { id: 's1', component: 'cost' }]);
  const r = await call(env, 'GET', '/api/alerts?state=!resolved&unstamped=1&limit=200');
  assert.equal(r.status, 200);
  assert.deepEqual(ids(r.body), ['n1', 'n2']);
  assert.equal(r.body.truncated, false);
});

test('A4: a bad component or both filters is a 400', { skip }, async () => {
  const { env } = fresh();
  assert.equal((await call(env, 'GET', '/api/alerts?component=Bad_Name')).status, 400);
  assert.equal((await call(env, 'GET', '/api/alerts?component=a&unstamped=1')).status, 400);
  assert.equal((await call(env, 'GET', '/api/alerts?unstamped=yes')).status, 400);
});

test('A5: POST /api/alerts/component stamps NULL rows only and touches no other column', { skip }, async () => {
  const { db, env } = fresh();
  await call(env, 'GET', '/api/alerts');
  seed(db, [{ id: 'x1', state: 'triaged', claimed_by: 'medic@hub', claimed_at: '2026-10-15T10:01:00Z',
    notified_at: '2026-10-15T10:02:00Z' }, { id: 'x2' }]);
  const before = db.prepare("SELECT state, claimed_by, claimed_at, notified_at FROM alerts WHERE id='x1'").get();
  let r = await call(env, 'POST', '/api/alerts/component',
    { stamps: [{ id: 'x1', component: 'merge-conductor' }, { id: 'x2', component: 'unowned' }, { id: 'gone', component: 'cost' }] });
  assert.equal(r.status, 200);
  assert.equal(r.body.stamped, 2, 'stamped counts the rows that changed, not the stamps sent');
  // A second stamp with another value changes nothing.
  r = await call(env, 'POST', '/api/alerts/component', { stamps: [{ id: 'x1', component: 'cost' }] });
  assert.equal(r.status, 200);
  assert.equal(r.body.stamped, 0);
  assert.equal(db.prepare("SELECT component FROM alerts WHERE id='x1'").get().component, 'merge-conductor');
  assert.deepEqual({ ...db.prepare("SELECT state, claimed_by, claimed_at, notified_at FROM alerts WHERE id='x1'").get() }, { ...before });
  // The GET filter reads the stamp back.
  assert.deepEqual(ids((await call(env, 'GET', '/api/alerts?component=merge-conductor')).body), ['x1']);
  assert.deepEqual(ids((await call(env, 'GET', '/api/alerts?unstamped=1')).body), []);
  // Refusals write nothing.
  seed(db, [{ id: 'y1' }]);
  const many = Array.from({ length: 201 }, (_, i) => ({ id: i ? `z${i}` : 'y1', component: 'cost' }));
  assert.equal((await call(env, 'POST', '/api/alerts/component', { stamps: many })).status, 400);
  assert.equal((await call(env, 'POST', '/api/alerts/component', { stamps: [] })).status, 400);
  assert.equal((await call(env, 'POST', '/api/alerts/component',
    { stamps: [{ id: 'y1', component: 'cost' }, { id: 'y1', component: 'cost' }] })).status, 400);
  assert.equal((await call(env, 'POST', '/api/alerts/component', { stamps: [{ id: 'y1', component: 'Bad_Name' }] })).status, 400);
  assert.equal((await call(env, 'POST', '/api/alerts/component', { stamps: [{ id: 'y 1', component: 'cost' }] })).status, 400);
  assert.equal((await call(env, 'POST', '/api/alerts/component', { stamps: [{ id: 'y1', component: 'cost' }] }, false)).status, 401);
  assert.equal(db.prepare("SELECT component FROM alerts WHERE id='y1'").get().component, null);
  // 200 stamps is the bound, not a refusal.
  const ok = Array.from({ length: 200 }, (_, i) => ({ id: i ? `z${i}` : 'y1', component: 'cost' }));
  r = await call(env, 'POST', '/api/alerts/component', { stamps: ok });
  assert.equal(r.status, 200);
  assert.equal(r.body.stamped, 1);
});

test('A6: EXPLAIN QUERY PLAN on 5,000 rows: both hot reads use idx_alerts_component', { skip }, async () => {
  const { db, env } = fresh();
  await call(env, 'GET', '/api/alerts');
  db.exec('BEGIN');
  const ins = db.prepare(`INSERT INTO alerts (id, family, box, project, line, severity, first_seen, last_seen, state, component)
    VALUES (?, 'abcdef012345', 'hub', '', 'x', 'warn', '2026-10-01T00:00:00Z', ?, ?, ?)`);
  const comps = ['merge-conductor', 'cost', 'triage', 'unowned', null];
  for (let i = 0; i < 5000; i++) {
    const ts = new Date(Date.UTC(2026, 9, 1) + i * 60000).toISOString();
    ins.run(`a${i}`, ts, i % 7 === 0 ? 'resolved' : 'new', comps[i % comps.length]);
  }
  db.exec('COMMIT');
  db.exec('ANALYZE');
  const plan = (sql, ...b) => db.prepare('EXPLAIN QUERY PLAN ' + sql).all(...b).map((r) => r.detail).join(' | ');
  // The two statements GET /api/alerts builds for component= and unstamped=1 (alertWhere + the list query).
  const p1 = plan('SELECT * FROM alerts WHERE component=?1 ORDER BY last_seen DESC, id ASC LIMIT ?2', 'cost', 201);
  const p2 = plan("SELECT * FROM alerts WHERE state<>?1 AND component IS NULL ORDER BY last_seen DESC, id ASC LIMIT ?2", 'resolved', 201);
  for (const p of [p1, p2]) {
    assert.match(p, /SEARCH alerts USING (COVERING )?INDEX idx_alerts_component \(component/, p);
    assert.doesNotMatch(p, /SCAN alerts/, p);
  }
});
