// BH-6799: dead box cursors leave wake_cursors on the daily prune, and
// GET /api/wakes/cursor?all=1 marks a box stale when it is far behind and idle.
//
// Live on 2026-10-14: probe-operator-mac's cursor sat 327,178 rows behind MAX(id)
// on a 209,595-row table, and nothing said so. Every case runs the real route
// through `worker.fetch` (D2) over node:sqlite with the composed schema.
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';

const SECRET = 'test-secret';
const T0 = Date.parse('2026-10-15T08:00:00Z');
const iso = (ms) => new Date(ms).toISOString().replace(/\.\d{3}Z$/, 'Z');

async function fixture(t) {
  const o = await openDb();
  if (!o) { t.skip('node:sqlite unavailable'); return null; }
  t.mock.timers.enable({ apis: ['Date'], now: T0 });
  // The schema's own seed rows are kept, except the cursors: each case writes its own.
  o.db.exec('DELETE FROM wake_cursors');
  return o;
}
const call = (o, method, path, body) => {
  const init = { method, headers: { authorization: `Bearer ${SECRET}`, 'content-type': 'application/json' } };
  if (body !== undefined) init.body = JSON.stringify(body);
  return worker.fetch(new Request(`https://jobs.test${path}`, init), { DB: o.DB, HARNESS_SECRET: SECRET })
    .then(async (res) => ({ status: res.status, body: await res.json().catch(() => null) }));
};
// Wakes with ids lo..hi exactly (explicit ids, so MIN and MAX are the test's numbers).
function wakes(db, lo, hi, at = iso(T0)) {
  const ins = db.prepare('INSERT INTO wakes (id, repo, kind, key, event, minute, at) VALUES (?,?,?,?,?,?,?)');
  db.exec('BEGIN');
  for (let id = lo; id <= hi; id++) ins.run(id, 'o/a', 'push', `k${id}`, 'push', `m${id}`, at);
  db.exec('COMMIT');
}
const cursor = (db, box, c, updatedAt) =>
  db.prepare('INSERT INTO wake_cursors (box, cursor, updated_at) VALUES (?,?,?)').run(box, c, updatedAt);
const boxes = (db) => db.prepare('SELECT box FROM wake_cursors ORDER BY box').all().map((r) => r.box);

test('H1: the prune deletes a cursor below MIN(id), keeps one at MIN and above, and answers cursors_deleted', async (t) => {
  const o = await fixture(t);
  if (!o) return;
  wakes(o.db, 100, 120);
  cursor(o.db, 'dead', 50, iso(T0 - 40 * 86400e3));
  cursor(o.db, 'just-below', 99, iso(T0));
  cursor(o.db, 'at-min', 100, iso(T0));
  cursor(o.db, 'live', 120, iso(T0));
  const r = await call(o, 'POST', '/api/wakes/prune', { days: 30 });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.cursors_deleted, 2);
  assert.equal(r.body.deleted, 0, 'no wake is older than 30 days');
  assert.deepEqual(boxes(o.db), ['at-min', 'live']);
  const again = await call(o, 'POST', '/api/wakes/prune', { days: 30 });
  assert.equal(again.body.cursors_deleted, 0, 'nothing left to delete reads 0');
  o.db.close();
});

test('H2: the prune deletes no cursor when wakes is empty', async (t) => {
  const o = await fixture(t);
  if (!o) return;
  cursor(o.db, 'a', 0, iso(T0));
  cursor(o.db, 'b', 5000, iso(T0 - 90 * 86400e3));
  const r = await call(o, 'POST', '/api/wakes/prune', { days: 30 });
  assert.equal(r.status, 200);
  assert.equal(r.body.cursors_deleted, 0);
  assert.deepEqual(boxes(o.db), ['a', 'b']);
  o.db.close();
});

test('H3: the prune runs the age sweep first, so a cursor left below the new MIN goes in the same call', async (t) => {
  const o = await fixture(t);
  if (!o) return;
  wakes(o.db, 1, 10, iso(T0 - 40 * 86400e3));
  wakes(o.db, 11, 20, iso(T0));
  cursor(o.db, 'old', 5, iso(T0 - 40 * 86400e3));
  cursor(o.db, 'live', 20, iso(T0));
  const r = await call(o, 'POST', '/api/wakes/prune', { days: 30 });
  assert.equal(r.body.deleted, 10);
  assert.equal(r.body.cursors_deleted, 1);
  assert.deepEqual(boxes(o.db), ['live']);
  o.db.close();
});

test('H4: ?all=1 marks stale only when lag > rows AND the cursor is older than lag_s', async (t) => {
  const o = await fixture(t);
  if (!o) return;
  wakes(o.db, 1, 1);
  o.db.prepare('INSERT INTO wakes (id, repo, kind, key, event, minute, at) VALUES (?,?,?,?,?,?,?)')
    .run(60001, 'o/a', 'push', 'top', 'push', 'mtop', iso(T0));
  cursor(o.db, 'at-threshold', 50001, iso(T0 - 2 * 3600e3));     // lag 10,000: not stale
  cursor(o.db, 'over-and-idle', 50000, iso(T0 - 2 * 3600e3));    // lag 10,001, 2 h idle: stale
  cursor(o.db, 'far-but-moving', 10001, iso(T0 - 5 * 60e3));     // lag 50,000, 5 min ago: not stale
  cursor(o.db, 'idle-but-close', 59990, iso(T0 - 9 * 3600e3));   // lag 11, 9 h idle: not stale
  cursor(o.db, 'idle-at-1h', 1, iso(T0 - 3600e3));               // lag 60,000, exactly 1 h: not stale
  const r = await call(o, 'GET', '/api/wakes/cursor?all=1');
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.max_id, 60001);
  assert.equal(r.body.lag_rows, 10000);
  assert.equal(r.body.lag_s, 3600);
  const by = Object.fromEntries(r.body.cursors.map((c) => [c.box, c]));
  assert.deepEqual(Object.keys(by), ['at-threshold', 'far-but-moving', 'idle-at-1h', 'idle-but-close', 'over-and-idle']);
  assert.deepEqual(by['over-and-idle'], {
    box: 'over-and-idle', cursor: 50000, updated_at: iso(T0 - 2 * 3600e3), lag: 10001, stale: true,
  });
  assert.equal(by['at-threshold'].lag, 10000);
  assert.equal(by['at-threshold'].stale, false);
  assert.equal(by['far-but-moving'].stale, false);
  assert.equal(by['idle-but-close'].stale, false);
  assert.equal(by['idle-at-1h'].stale, false);
  o.db.close();
});

test('H5: the settings rows move the thresholds; a junk value uses the default', async (t) => {
  const o = await fixture(t);
  if (!o) return;
  wakes(o.db, 1, 101);
  cursor(o.db, 'b50', 51, iso(T0 - 2 * 3600e3));   // lag 50
  cursor(o.db, 'b51', 50, iso(T0 - 2 * 3600e3));   // lag 51
  const set = (key, value) => o.db.prepare('UPDATE settings SET value=? WHERE key=?').run(value, key);
  set('wakes.cursor_lag_alert_rows', '50');
  let r = await call(o, 'GET', '/api/wakes/cursor?all=1');
  assert.equal(r.body.lag_rows, 50);
  assert.deepEqual(r.body.cursors.map((c) => [c.box, c.stale]), [['b50', false], ['b51', true]]);
  set('wakes.cursor_lag_alert_rows', 'lots');
  r = await call(o, 'GET', '/api/wakes/cursor?all=1');
  assert.equal(r.body.lag_rows, 10000, 'a junk value uses the default');
  assert.ok(r.body.cursors.every((c) => !c.stale));
  set('wakes.cursor_lag_alert_rows', '50');
  set('wakes.cursor_lag_alert_s', '86400');
  r = await call(o, 'GET', '/api/wakes/cursor?all=1');
  assert.equal(r.body.lag_s, 86400);
  assert.ok(r.body.cursors.every((c) => !c.stale), '2 h idle is inside a 24 h window');
  o.db.close();
});

test('H6: ?box= keeps its answer; neither param is still a 400', async (t) => {
  const o = await fixture(t);
  if (!o) return;
  cursor(o.db, 'a', 7, iso(T0));
  const one = await call(o, 'GET', '/api/wakes/cursor?box=a');
  assert.deepEqual(one.body, { box: 'a', cursor: 7, as_of: iso(T0) });
  assert.equal((await call(o, 'GET', '/api/wakes/cursor')).status, 400);
  assert.equal((await call(o, 'GET', '/api/wakes/cursor?all=yes')).status, 400);
  const empty = await call(o, 'GET', '/api/wakes/cursor?all=1');
  assert.equal(empty.status, 200);
  assert.equal(empty.body.max_id, 0);
  assert.deepEqual(empty.body.cursors, [{ box: 'a', cursor: 7, updated_at: iso(T0), lag: 0, stale: false }]);
  o.db.close();
});

test('H7: the two settings rows are seeded with the ticket numbers', async (t) => {
  const o = await fixture(t);
  if (!o) return;
  const rows = o.db.prepare("SELECT key, value FROM settings WHERE key LIKE 'wakes.cursor_lag_alert_%' ORDER BY key").all()
    .map((r) => [r.key, r.value]);
  assert.deepEqual(rows, [['wakes.cursor_lag_alert_rows', '10000'], ['wakes.cursor_lag_alert_s', '3600']]);
  o.db.close();
});
