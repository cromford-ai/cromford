import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import worker from '../src/index.js';
import { jobsSchemaSql } from './lib/jobs-schema.js';

// BH-1201 (BH-1383): GET /api/lanes/status carries the merge-conductor's
// published mode and held-page count, and carries them on that lane ONLY.
//
// WHY A REAL DATABASE. The two values are `settings` rows
// (`merge-conductor.mode`, `merge-conductor.held_pages`) that the conductor
// publishes and this route reads. A stub that answers `{results:[]}` to any
// SELECT cannot tell "the row is there" from "the row is not", which is the
// entire distinction here — `mode: null` means the conductor has published
// nothing and is exactly as load-bearing an answer as `mode: "kill-switch"`.
// So the fixture is a real schema.sql database, the rows are written through
// the production writer (`PUT /api/settings`), and the read is a real
// `GET /api/lanes/status` request through the worker's fetch handler (D2) —
// not a helper called directly.
//
// The route's settings read is a SECOND query: the one already in the handler
// is `WHERE key LIKE 'lane.%'` and could never see either of these keys.

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

// A database exactly as schema.sql declares it. `env` is rebuilt per test
// because ensureTable caches per DB object (a WeakMap keyed on env.DB).
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

const lane = (r, id) => r.body.lanes.find((l) => l.id === id);

// ── AT-4a ───────────────────────────────────────────────────────────────────
test('the merge-conductor lane carries the mode and held count the conductor published', async (t) => {
  if (!DatabaseSync) { t.skip('node:sqlite unavailable on this runtime'); return; }
  const { db, env } = freshD1();

  // Written through the route the conductor itself writes with, so the read
  // path under test is the production one end to end.
  const m = await call(env, 'PUT', '/api/settings',
    { key: 'merge-conductor.mode', value: 'kill-switch', actor: 'test' });
  assert.equal(m.status, 200, 'the mode row was refused by the settings writer');
  const h = await call(env, 'PUT', '/api/settings',
    { key: 'merge-conductor.held_pages', value: '3 STUCK=2 BUDGET=1', actor: 'test' });
  assert.equal(h.status, 200, 'the held_pages row was refused by the settings writer');

  const r = await call(env, 'GET', '/api/lanes/status');
  assert.equal(r.status, 200);
  const mc = lane(r, 'merge-conductor');
  assert.ok(mc, 'the status page has no merge-conductor lane at all');
  assert.equal(mc.mode, 'kill-switch',
    'the status page does not report the mode the conductor published');
  // RAW, unparsed: the conductor publishes a summary string and the breakdown
  // is the half an operator reads. A number here would drop STUCK=2 BUDGET=1.
  assert.equal(mc.held_pages, '3 STUCK=2 BUDGET=1',
    'the status page does not report the held count the conductor published');
  db.close();
});

// ── AT-4b ───────────────────────────────────────────────────────────────────
test('no lane other than merge-conductor grows either key', async (t) => {
  if (!DatabaseSync) { t.skip('node:sqlite unavailable on this runtime'); return; }
  const { db, env } = freshD1();

  assert.equal((await call(env, 'PUT', '/api/settings',
    { key: 'merge-conductor.mode', value: 'observe', actor: 'test' })).status, 200);
  assert.equal((await call(env, 'PUT', '/api/settings',
    { key: 'merge-conductor.held_pages', value: '0', actor: 'test' })).status, 200);

  const r = await call(env, 'GET', '/api/lanes/status');
  assert.equal(r.status, 200);
  const others = r.body.lanes.filter((l) => l.id !== 'merge-conductor');
  assert.ok(others.length > 1, 'the registry produced no other lanes to check');
  for (const l of others) {
    assert.ok(!('mode' in l) && !('held_pages' in l),
      `lane ${l.id} grew a conductor-only key`);
  }
  // And the conductor's own values are the published ones, so this test cannot
  // pass by the fields being absent everywhere.
  assert.equal(lane(r, 'merge-conductor').mode, 'observe');
  assert.equal(lane(r, 'merge-conductor').held_pages, '0');
  db.close();
});

// ── AT-4c ───────────────────────────────────────────────────────────────────
test('with no rows published both fields are present and null, and the page is 200', async (t) => {
  if (!DatabaseSync) { t.skip('node:sqlite unavailable on this runtime'); return; }
  const { db, env } = freshD1();
  assert.equal(
    db.prepare("SELECT COUNT(*) AS n FROM settings WHERE key LIKE 'merge-conductor.%'").get().n, 0,
    'the fixture did not start from a database with no conductor rows');

  const r = await call(env, 'GET', '/api/lanes/status');
  assert.equal(r.status, 200, 'an unpublished mode took the whole settings page down');
  const mc = lane(r, 'merge-conductor');
  assert.ok(mc, 'the status page has no merge-conductor lane at all');
  // PRESENT AND NULL, never absent and never 0 (D11): "the conductor has not
  // published" and "the conductor is holding nothing" are different answers.
  assert.ok('mode' in mc && 'held_pages' in mc,
    'the fields vanish when the conductor has published nothing');
  assert.equal(mc.mode, null);
  assert.equal(mc.held_pages, null);
  db.close();
});
