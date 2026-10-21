import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';

// BH-7802 (BH-4157.2): the alerts row is what the alert-state READERS decide
// from when flags/alerts-db is on. Two route changes carry what they used to
// take from state/alerts/<id>.json:
//   POST /api/alerts/resolve answers the rows it MOVED (count, severity,
//     first_seen), so a cross-box resolve pages at the severity the condition
//     opened at, from the same statement that closed it;
//   GET /api/alerts?id=<id> answers that one row, in any state, so
//     alert_state_open / alert_state_age read one primary-key row.
// tests/fixtures/bh-7802/resolve-rows.json is the resolve body W1 produces; the
// shell suite tests/alert-state-rows.bh-7802-test.sh parses the same file, so
// the writer and the reader are pinned to one shape.

const SECRET = 'test-secret';
const NOW_MS = Date.parse('2026-09-19T12:00:00Z');
const iso = (sAgo) => new Date(NOW_MS - sAgo * 1000).toISOString().replace(/\.\d{3}Z$/, 'Z');
const FIXTURE = JSON.parse(readFileSync(
  new URL('../../../tests/fixtures/bh-7802/resolve-rows.json', import.meta.url), 'utf8'));

async function open(t) {
  t.mock.timers.enable({ apis: ['Date'], now: NOW_MS });
  const env = await openDb();
  if (!env) t.skip('node:sqlite unavailable on this runtime');
  return env;
}

async function call(DB, method, path, body) {
  const init = { method, headers: { authorization: `Bearer ${SECRET}` } };
  if (body !== undefined) {
    init.body = JSON.stringify(body);
    init.headers['content-type'] = 'application/json';
  }
  const res = await worker.fetch(new Request(`https://jobs.test${path}`, init), { DB, HARNESS_SECRET: SECRET });
  return { status: res.status, body: await res.json() };
}

const COLS = 'id,family,box,project,line,severity,first_seen,last_seen,count,state';
function seed(db, row) {
  const r = {
    family: null, box: 'hub', project: 'cromford', line: 'disk 91% on /', severity: 'warn',
    first_seen: iso(120), last_seen: iso(120), count: 1, state: 'new', ...row,
  };
  db.prepare(`INSERT INTO alerts (${COLS}) VALUES (?,?,?,?,?,?,?,?,?,?)`).run(
    r.id, r.family, r.box, r.project, r.line, r.severity, r.first_seen, r.last_seen, r.count, r.state,
  );
}
// The table is self-created by the routes; one GET makes it.
async function ready(t) {
  const env = await open(t); if (!env) return null;
  await call(env.DB, 'GET', '/api/alerts');
  return env;
}

test('W1: resolve answers the rows it moved, with count, severity and first_seen', async (t) => {
  const env = await ready(t); if (!env) return;
  seed(env.db, { id: 'r1', severity: 'warn', count: 4, first_seen: iso(1800) });
  seed(env.db, { id: 'r2', severity: 'critical', count: 1, first_seen: iso(600) });
  const res = await call(env.DB, 'POST', '/api/alerts/resolve', { ids: ['r2', 'r1', 'r9'] });
  assert.equal(res.status, 200);
  assert.equal(res.body.resolved, 2, 'r9 is unknown and counts zero');
  assert.deepEqual(res.body.rows, FIXTURE.rows, 'the rows the shell suite parses, sorted by id');
  assert.equal(res.body.resolved, FIXTURE.resolved);
  assert.equal(res.body.as_of, FIXTURE.as_of);
  assert.equal(env.db.prepare("SELECT state FROM alerts WHERE id='r1'").get().state, 'resolved');
});

test('W2: an already resolved id moves nothing and answers rows: []', async (t) => {
  const env = await ready(t); if (!env) return;
  seed(env.db, { id: 'r1', state: 'resolved', count: 3 });
  const res = await call(env.DB, 'POST', '/api/alerts/resolve', { ids: ['r1'] });
  assert.equal(res.status, 200);
  assert.equal(res.body.resolved, 0);
  assert.deepEqual(res.body.rows, []);
  // The second resolve of a row the first one closed is silent too.
  seed(env.db, { id: 'r3', count: 2 });
  assert.equal((await call(env.DB, 'POST', '/api/alerts/resolve', { ids: ['r3'] })).body.rows.length, 1);
  const again = await call(env.DB, 'POST', '/api/alerts/resolve', { ids: ['r3'] });
  assert.equal(again.body.resolved, 0);
  assert.deepEqual(again.body.rows, []);
});

test('W3: GET /api/alerts?id= answers exactly that row, in any state', async (t) => {
  const env = await ready(t); if (!env) return;
  seed(env.db, { id: 'a1', state: 'resolved', count: 7, last_seen: iso(30) });
  seed(env.db, { id: 'a10', last_seen: iso(10) });
  seed(env.db, { id: 'a1x', last_seen: iso(5) });
  const res = await call(env.DB, 'GET', '/api/alerts?id=a1&limit=1');
  assert.equal(res.status, 200);
  assert.equal(res.body.alerts.length, 1);
  assert.equal(res.body.alerts[0].id, 'a1');
  assert.equal(res.body.alerts[0].state, 'resolved');
  assert.equal(res.body.alerts[0].count, 7);
  assert.equal(res.body.truncated, false);
  const none = await call(env.DB, 'GET', '/api/alerts?id=a2');
  assert.equal(none.status, 200);
  assert.deepEqual(none.body.alerts, []);
});

test('W4: a bad id is a 400; an empty id is no filter', async (t) => {
  const env = await ready(t); if (!env) return;
  seed(env.db, { id: 'a1' });
  seed(env.db, { id: 'a2' });
  for (const bad of ['bad%2Fid', 'a%201', 'x'.repeat(121)]) {
    const res = await call(env.DB, 'GET', `/api/alerts?id=${bad}`);
    assert.equal(res.status, 400, bad);
    assert.match(res.body.error, /^id must match/);
  }
  const empty = await call(env.DB, 'GET', '/api/alerts?id=');
  assert.equal(empty.status, 200);
  assert.equal(empty.body.alerts.length, 2);
});

test('W5: with no id the list is unchanged: every row, last_seen desc', async (t) => {
  const env = await ready(t); if (!env) return;
  seed(env.db, { id: 'a1', last_seen: iso(300) });
  seed(env.db, { id: 'a2', last_seen: iso(100), state: 'resolved' });
  seed(env.db, { id: 'a3', last_seen: iso(200) });
  const res = await call(env.DB, 'GET', '/api/alerts');
  assert.deepEqual(res.body.alerts.map((r) => r.id), ['a2', 'a3', 'a1']);
  // The families path never takes id: it keeps answering the family count.
  const fam = await call(env.DB, 'GET', '/api/alerts/families?lane=triage&id=bad%2Fid');
  assert.equal(fam.status, 200);
});

test('W6: EXPLAIN QUERY PLAN on 5,000 rows: the id read is a primary-key search', async (t) => {
  const env = await ready(t); if (!env) return;
  const { db } = env;
  db.exec('BEGIN');
  const ins = db.prepare(`INSERT INTO alerts (id, family, box, project, line, severity, first_seen, last_seen, state)
    VALUES (?, 'abcdef012345', 'hub', '', 'x', 'warn', '2026-10-01T00:00:00Z', ?, ?)`);
  for (let i = 0; i < 5000; i++) {
    ins.run(`a${i}`, new Date(Date.UTC(2026, 9, 1) + i * 60000).toISOString(), i % 7 ? 'new' : 'resolved');
  }
  db.exec('COMMIT');
  db.exec('ANALYZE');
  const plan = (sql, ...b) => db.prepare('EXPLAIN QUERY PLAN ' + sql).all(...b).map((r) => r.detail).join(' | ');
  // The statement GET /api/alerts?id= builds (alertWhere ids + the list query),
  // and the resolve UPDATE ... RETURNING.
  const p1 = plan('SELECT * FROM alerts WHERE id IN (?1) ORDER BY last_seen DESC, id ASC LIMIT ?2', 'a42', 2);
  const p2 = plan("UPDATE alerts SET state='resolved' WHERE state<>'resolved' AND id IN (?1) RETURNING id, count, severity, first_seen", 'a42');
  for (const p of [p1, p2]) {
    assert.match(p, /SEARCH alerts USING INDEX sqlite_autoindex_alerts_1 \(id=\?\)/, p);
    assert.doesNotMatch(p, /SCAN alerts/, p);
  }
  const res = await call(env.DB, 'GET', '/api/alerts?id=a42');
  assert.deepEqual(res.body.alerts.map((r) => r.id), ['a42']);
});
