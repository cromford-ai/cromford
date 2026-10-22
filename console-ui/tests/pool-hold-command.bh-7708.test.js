import test from 'node:test';
import assert from 'node:assert/strict';
import { DatabaseSync } from 'node:sqlite';
import { onRequest as dash } from '../functions/api/[[path]].js';
import { BOARD_FALLBACK_TYPES } from '../functions/_lib/board-commands.js';
import { POOL_HOLD_TYPES, poolHoldCommand } from '../functions/_lib/pool-hold-command.js';

// BH-7708. The console worker has no pool_hold command kind, so it answers
// 400 'unknown action'. The Pages proxy forwards first and, ONLY on that exact
// refusal, validates the body and queues the pool_hold row in CONSOLE_DB
// itself, after the same authed probe the BH-5820 board fallback uses. The hub
// runs the row with bin/cmd-pool-hold.sh.
//
// Every route case runs the REAL Pages onRequest. globalThis.fetch is a fake
// console worker; CONSOLE_DB is a real SQLite `commands` table.

const NOW = Date.parse('2026-10-20T15:42:07Z');

function world() {
  const sqlite = new DatabaseSync(':memory:');
  sqlite.exec(`CREATE TABLE commands (
    id INTEGER PRIMARY KEY AUTOINCREMENT, ckey TEXT UNIQUE, type TEXT, project TEXT, payload TEXT,
    status TEXT DEFAULT 'pending', attempts INTEGER DEFAULT 0, lease_until TEXT, result TEXT,
    created_at TEXT, updated_at TEXT)`);
  const db = {
    prepare(sql) {
      const stmt = sqlite.prepare(sql);
      return {
        bind: (...args) => ({
          run: async () => ({ success: true, meta: { changes: Number(stmt.run(...args).changes) } }),
          first: async () => stmt.get(...args) || null,
          all: async () => ({ results: stmt.all(...args) })
        })
      };
    }
  };
  const rows = () => sqlite.prepare('SELECT * FROM commands ORDER BY id').all();
  return { db, rows };
}

const GOOD = 'dash=good';
const GOOD_AUTH = 'Bearer tok-fixture-bh7708';
function worker(t, answer = [400, { error: 'unknown action' }], { probe = 200 } = {}) {
  const seen = [];
  seen.probes = [];
  t.mock.method(globalThis, 'fetch', async (url, init) => {
    if (new URL(String(url)).pathname === '/api/dash/fleet') {
      const h = new Headers(init && init.headers);
      seen.probes.push({ cookie: h.get('cookie'), authorization: h.get('authorization') });
      const good = h.get('cookie') === GOOD || h.get('authorization') === GOOD_AUTH;
      return new Response('{}', { status: good ? probe : 403 });
    }
    seen.push({ url: String(url), body: init.body ? JSON.parse(init.body) : null });
    return new Response(JSON.stringify(answer[1]), { status: answer[0], headers: { 'content-type': 'application/json' } });
  });
  return seen;
}

async function post(env, body, { cookie = GOOD, authorization = null } = {}) {
  const headers = { 'content-type': 'application/json' };
  if (cookie) headers.cookie = cookie;
  if (authorization) headers.authorization = authorization;
  const res = await dash({
    request: new Request('https://console.example/api/dash/action', { method: 'POST', headers, body: JSON.stringify(body) }),
    env
  });
  const text = await res.text();
  let json = null;
  try { json = JSON.parse(text); } catch { /* not json */ }
  return { status: res.status, json, text };
}

const pinClock = (t) => t.mock.timers.enable({ apis: ['Date'], now: NOW });

test('C1 pool_hold refused by the worker is queued by Pages, signed in', async (t) => {
  pinClock(t);
  const seen = worker(t);
  const w = world();
  const r = await post({ CONSOLE_DB: w.db }, { type: 'pool_hold', project: 'pa', hold: true, reason: ' drain ' });
  assert.equal(seen.length, 1, 'the worker is always asked first');
  assert.equal(seen.probes.length, 1, 'the cookie passes the authed probe before the write');
  assert.equal(r.status, 200, r.text);
  assert.equal(r.json.ok, true);
  assert.equal(r.json.type, 'pool_hold');
  assert.equal(r.json.ckey, 'pa:pool_hold:on:2026-10-20T15:42');
  const rows = w.rows();
  assert.equal(rows.length, 1);
  assert.equal(rows[0].id, r.json.command_id);
  assert.equal(rows[0].type, 'pool_hold');
  assert.equal(rows[0].project, 'pa');
  assert.equal(rows[0].status, 'pending');
  const p0 = JSON.parse(rows[0].payload);
  assert.equal(p0.hold, true);
  assert.equal(p0.reason, 'drain', 'the reason is trimmed');
  assert.equal(p0.actor, 'console');
  const off = await post({ CONSOLE_DB: w.db }, { type: 'pool_hold', project: 'pa', hold: false });
  assert.equal(off.status, 200, off.text);
  assert.equal(off.json.ckey, 'pa:pool_hold:off:2026-10-20T15:42');
  assert.deepEqual(JSON.parse(w.rows()[1].payload), { hold: false, reason: '', actor: 'console' });
});

test('C2 the Bearer token (an MCP client) passes the probe the same way', async (t) => {
  pinClock(t);
  const seen = worker(t);
  const w = world();
  const r = await post({ CONSOLE_DB: w.db }, { type: 'pool_hold', project: 'pa', hold: true }, { cookie: null, authorization: GOOD_AUTH });
  assert.equal(r.status, 200, r.text);
  assert.equal(seen.probes[0].authorization, GOOD_AUTH);
  assert.equal(w.rows().length, 1);
});

test('C3 no credential or a refused probe is 403, and nothing is queued', async (t) => {
  worker(t);
  const w = world();
  const none = await post({ CONSOLE_DB: w.db }, { type: 'pool_hold', project: 'pa', hold: true }, { cookie: null });
  assert.equal(none.status, 403);
  const badCookie = await post({ CONSOLE_DB: w.db }, { type: 'pool_hold', project: 'pa', hold: true }, { cookie: 'dash=bad' });
  assert.equal(badCookie.status, 403);
  assert.deepEqual(badCookie.json, { error: 'unauthorized' });
  assert.equal(w.rows().length, 0);
});

test('C4 a hold that is not a boolean, or a bad project, is a 400 that names it', async (t) => {
  worker(t);
  const w = world();
  for (const hold of ['true', 1, null, undefined, {}]) {
    const r = await post({ CONSOLE_DB: w.db }, { type: 'pool_hold', project: 'pa', hold });
    assert.equal(r.status, 400, `hold ${JSON.stringify(hold)}`);
    assert.deepEqual(r.json, { error: 'hold must be true or false' });
  }
  for (const project of ['', 'a/b', '../x', 7, undefined]) {
    const r = await post({ CONSOLE_DB: w.db }, { type: 'pool_hold', project, hold: true });
    assert.equal(r.status, 400, `project ${JSON.stringify(project)}`);
    assert.deepEqual(r.json, { error: 'project required' });
  }
  assert.equal(w.rows().length, 0);
});

test('C5 a worker that accepts pool_hold, or another 400, is passed through', async (t) => {
  const w = world();
  worker(t, [200, { ok: true, type: 'pool_hold', command_id: 901 }]);
  const a = await post({ CONSOLE_DB: w.db }, { type: 'pool_hold', project: 'pa', hold: true });
  assert.equal(a.status, 200);
  assert.deepEqual(a.json, { ok: true, type: 'pool_hold', command_id: 901 });
  t.mock.restoreAll();
  worker(t, [400, { error: 'project not found' }]);
  const b = await post({ CONSOLE_DB: w.db }, { type: 'pool_hold', project: 'pa', hold: true });
  assert.equal(b.status, 400);
  assert.deepEqual(b.json, { error: 'project not found' });
  assert.equal(w.rows().length, 0);
});

test('C6 the same click in one minute is one command', async (t) => {
  pinClock(t);
  worker(t);
  const w = world();
  const a = await post({ CONSOLE_DB: w.db }, { type: 'pool_hold', project: 'pa', hold: true });
  const b = await post({ CONSOLE_DB: w.db }, { type: 'pool_hold', project: 'pa', hold: true });
  assert.equal(b.json.command_id, a.json.command_id);
  assert.equal(w.rows().length, 1);
});

test('C7 the BH-5820 fallback set is unchanged; pool_hold is its own set', () => {
  assert.deepEqual([...BOARD_FALLBACK_TYPES].sort(), ['comment_issue', 'hold_ticket', 'unhold_ticket']);
  assert.deepEqual([...POOL_HOLD_TYPES], ['pool_hold']);
});

test('C8 poolHoldCommand cuts the reason to 500 and refuses another type', () => {
  const c = poolHoldCommand({ type: 'pool_hold', project: ' pa ', hold: true, reason: 'x'.repeat(900), actor: 'a' });
  assert.equal(c.project, 'pa');
  assert.equal(c.payload.reason.length, 500);
  assert.equal(c.payload.actor, 'a');
  assert.deepEqual(poolHoldCommand({ type: 'pause_board', project: 'pa', hold: true }), { error: 'unknown action' });
});
