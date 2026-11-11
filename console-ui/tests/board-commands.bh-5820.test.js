import test from 'node:test';
import assert from 'node:assert/strict';
import { DatabaseSync } from 'node:sqlite';
import { onRequest as dash } from '../functions/api/[[path]].js';
import { BOARD_FALLBACK_TYPES } from '../functions/_lib/board-commands.js';
import { runTicketHold } from '../src/ui/TicketHold.js';
import { holdTarget } from '../src/lib/ticket-hold.js';
import { commandTarget } from '../src/lib/commands.js';

// BH-5820. The console worker refuses comment_issue, hold_ticket and
// unhold_ticket with 400 'unknown action' before it inserts a row, because its
// ACTION_TYPES (in the harness-console repo) does not list them. The Pages
// proxy forwards first and, ONLY on that exact refusal for those three types,
// validates the body and queues the command row in CONSOLE_DB itself.
//
// Every case runs the REAL Pages onRequest. globalThis.fetch is a fake console
// worker; CONSOLE_DB is a real SQLite `commands` table in D1's
// prepare/bind/run/first shape.

const NOW = Date.parse('2026-10-09T12:34:56Z');

function world({ throws = false } = {}) {
  const sqlite = new DatabaseSync(':memory:');
  sqlite.exec(`CREATE TABLE commands (
    id INTEGER PRIMARY KEY AUTOINCREMENT, ckey TEXT UNIQUE, type TEXT, project TEXT, payload TEXT,
    status TEXT DEFAULT 'pending', attempts INTEGER DEFAULT 0, lease_until TEXT, result TEXT,
    created_at TEXT, updated_at TEXT)`);
  const db = {
    prepare(sql) {
      if (throws) throw new Error('D1_ERROR: no such table: commands');
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

// A fake console worker. `answer` is [status, body] for the forwarded
// command; every forwarded command is recorded in the returned array. The
// authed probe (/api/dash/fleet) answers `probe` (a status, or 'throw') when
// the cookie is GOOD (or the Authorization header is GOOD_AUTH, the token the
// MCP client sends) and 403 otherwise; each probe is recorded in `.probes`.
const GOOD = 'dash=good';
const GOOD_AUTH = 'Bearer tok-fixture-bh5820';
function worker(t, answer = [400, { error: 'unknown action' }], { probe = 200 } = {}) {
  const seen = [];
  seen.probes = [];
  t.mock.method(globalThis, 'fetch', async (url, init) => {
    if (new URL(String(url)).pathname === '/api/dash/fleet') {
      const h = new Headers(init && init.headers);
      const cookie = h.get('cookie');
      const authorization = h.get('authorization');
      const rec = { url: String(url), cookie };
      if (authorization) rec.authorization = authorization;
      seen.probes.push(rec);
      if (probe === 'throw') throw new TypeError('fetch failed');
      return new Response('{}', { status: cookie === GOOD || authorization === GOOD_AUTH ? probe : 403 });
    }
    seen.push({ url: String(url), body: init.body ? JSON.parse(init.body) : null });
    return new Response(typeof answer[1] === 'string' ? answer[1] : JSON.stringify(answer[1]),
      { status: answer[0], headers: { 'content-type': 'application/json', 'x-worker': 'yes' } });
  });
  return seen;
}

async function post(env, body, { cookie = GOOD, authorization = null } = {}) {
  const headers = { 'content-type': 'application/json' };
  if (cookie) headers.cookie = cookie;
  if (authorization) headers.authorization = authorization;
  const res = await dash({
    request: new Request('https://console.example/api/dash/action', {
      method: 'POST', headers, body: JSON.stringify(body)
    }),
    env
  });
  const text = await res.text();
  let json = null;
  try { json = JSON.parse(text); } catch { /* not json */ }
  return { status: res.status, json, text, headers: res.headers };
}

const pinClock = (t) => t.mock.timers.enable({ apis: ['Date'], now: NOW });

// BH-9014 added file_issue (console-ui/tests/board-commands.bh-9014.test.js).
test('the fallback set is exactly the three board types and file_issue', () => {
  assert.deepEqual([...BOARD_FALLBACK_TYPES].sort(), ['comment_issue', 'file_issue', 'hold_ticket', 'unhold_ticket']);
});

test('P1 comment_issue refused by the worker is queued by Pages, once', async (t) => {
  pinClock(t);
  const seen = worker(t);
  const w = world();
  const r = await post({ CONSOLE_DB: w.db }, { type: 'comment_issue', project: 'cromford', issue: 7, body: 'hi' });
  assert.equal(seen.length, 1, 'the worker is always asked first');
  assert.deepEqual(seen.probes, [{ url: 'https://harness-console.operator.workers.dev/api/dash/fleet', cookie: GOOD }],
    'the cookie passes the worker authed probe before the write');
  assert.equal(r.status, 200, r.text);
  assert.equal(r.json.ok, true);
  assert.equal(r.json.type, 'comment_issue');
  assert.ok(Number.isInteger(r.json.command_id) && r.json.command_id > 0, r.text);
  assert.match(r.json.ckey, /^cromford:comment_issue:7:2026-10-09T12:34:[0-9a-f]{16}$/);
  const rows = w.rows();
  assert.equal(rows.length, 1);
  assert.equal(rows[0].id, r.json.command_id);
  assert.equal(rows[0].type, 'comment_issue');
  assert.equal(rows[0].project, 'cromford');
  assert.equal(rows[0].status, 'pending');
  assert.equal(rows[0].ckey, r.json.ckey);
  assert.deepEqual(JSON.parse(rows[0].payload), { issue: 7, body: 'hi', actor: 'console' });
});

test('P2 the same comment in the same minute is the same command', async (t) => {
  pinClock(t);
  worker(t);
  const w = world();
  const a = await post({ CONSOLE_DB: w.db }, { type: 'comment_issue', project: 'cromford', issue: 7, body: 'hi' });
  const b = await post({ CONSOLE_DB: w.db }, { type: 'comment_issue', project: 'cromford', issue: 7, body: 'hi' });
  assert.equal(b.status, 200);
  assert.equal(b.json.command_id, a.json.command_id);
  assert.equal(w.rows().length, 1);
});

test('P3 a different body is a new command', async (t) => {
  pinClock(t);
  worker(t);
  const w = world();
  const a = await post({ CONSOLE_DB: w.db }, { type: 'comment_issue', project: 'cromford', issue: 7, body: 'hi' });
  const b = await post({ CONSOLE_DB: w.db }, { type: 'comment_issue', project: 'cromford', issue: 7, body: 'hi again' });
  assert.notEqual(b.json.command_id, a.json.command_id);
  assert.equal(w.rows().length, 2);
});

test('P4 the TicketHold body for hold_ticket and unhold_ticket is queued', async (t) => {
  pinClock(t);
  worker(t);
  const w = world();
  const h = await post({ CONSOLE_DB: w.db }, { type: 'hold_ticket', project: 'cromford', ticket: 'BH-7', reason: '' });
  assert.equal(h.status, 200, h.text);
  assert.equal(h.json.ckey, 'cromford:hold_ticket:7:2026-10-09T12:34');
  const u = await post({ CONSOLE_DB: w.db }, { type: 'unhold_ticket', project: 'cromford', ticket: 'BH-7', reason: '  cleared  ' });
  assert.equal(u.status, 200, u.text);
  const rows = w.rows();
  assert.deepEqual(rows.map((r) => r.type), ['hold_ticket', 'unhold_ticket']);
  assert.deepEqual(JSON.parse(rows[0].payload), { ticket: 'BH-7', reason: '', actor: 'console' });
  assert.deepEqual(JSON.parse(rows[1].payload), { ticket: 'BH-7', reason: 'cleared', actor: 'console' });
  // The MCP shape: the issue number, no ticket key.
  const m = await post({ CONSOLE_DB: w.db }, { type: 'hold_ticket', project: 'cromford', issue: 9, reason: 'r' });
  assert.equal(m.status, 200, m.text);
  assert.deepEqual(JSON.parse(w.rows()[2].payload), { issue: 9, reason: 'r', actor: 'console' });
  // A body-sent actor never survives: the proxy stamps its own.
  const x = await post({ CONSOLE_DB: w.db }, { type: 'hold_ticket', project: 'cromford', ticket: 'BH-8', actor: 'mallory' });
  assert.equal(x.status, 200);
  assert.equal(JSON.parse(w.rows()[3].payload).actor, 'console');
});

test('P5 a worker that accepts the type is passed through, and Pages writes nothing', async (t) => {
  const seen = worker(t, [200, { ok: true, type: 'hold_ticket', ckey: 'k', command_id: 501 }]);
  const w = world();
  const r = await post({ CONSOLE_DB: w.db }, { type: 'hold_ticket', project: 'cromford', ticket: 'BH-7', reason: '' });
  assert.equal(seen.length, 1);
  assert.equal(r.status, 200);
  assert.deepEqual(r.json, { ok: true, type: 'hold_ticket', ckey: 'k', command_id: 501 });
  assert.equal(w.rows().length, 0);
});

test('P6 a type outside the fallback set keeps the worker refusal', async (t) => {
  worker(t);
  const w = world();
  const r = await post({ CONSOLE_DB: w.db }, { type: 'run_triage', project: 'cromford' });
  assert.equal(r.status, 400);
  assert.deepEqual(r.json, { error: 'unknown action' });
  assert.equal(w.rows().length, 0);
});

test('P7 no CONSOLE_DB is the worker refusal, never a fake success', async (t) => {
  worker(t);
  for (const env of [{}, undefined, { CONSOLE_DB: {} }]) {
    const r = await post(env, { type: 'comment_issue', project: 'cromford', issue: 7, body: 'hi' });
    assert.equal(r.status, 400);
    assert.deepEqual(r.json, { error: 'unknown action' });
  }
});

test('P8 a database that throws is a 503 that names the type', async (t) => {
  worker(t);
  t.mock.method(console, 'error', () => {});
  const w = world({ throws: true });
  const r = await post({ CONSOLE_DB: w.db }, { type: 'comment_issue', project: 'cromford', issue: 7, body: 'secret text' });
  assert.equal(r.status, 503);
  assert.deepEqual(r.json, { error: 'comment_issue not queued: console database write failed' });
  const logged = console.error.mock.calls.map((c) => c.arguments.join(' ')).join('\n');
  assert.ok(!logged.includes('secret text'), 'the comment body is never logged');
});

test('P9 a bad body is a visible 400 and writes nothing', async (t) => {
  worker(t);
  const w = world();
  const cases = [
    [{ type: 'comment_issue', project: 'cromford', issue: '7', body: 'hi' }, 'issue must be a positive integer'],
    [{ type: 'comment_issue', project: 'cromford', issue: 0, body: 'hi' }, 'issue must be a positive integer'],
    [{ type: 'comment_issue', project: 'cromford', issue: 1.5, body: 'hi' }, 'issue must be a positive integer'],
    [{ type: 'comment_issue', project: 'cromford', issue: 7, body: '   ' }, 'body required (1-20000 characters)'],
    [{ type: 'comment_issue', project: 'cromford', issue: 7 }, 'body required (1-20000 characters)'],
    [{ type: 'comment_issue', project: 'cromford', issue: 7, body: 'a'.repeat(20001) }, 'body required (1-20000 characters)'],
    [{ type: 'comment_issue', project: 'a b', issue: 7, body: 'hi' }, 'project required'],
    [{ type: 'comment_issue', issue: 7, body: 'hi' }, 'project required'],
    [{ type: 'hold_ticket', project: 'cromford', reason: 'r' }, 'ticket (PREFIX-<n>) or issue required'],
    [{ type: 'hold_ticket', project: 'cromford', ticket: 'BH-7a' }, 'ticket (PREFIX-<n>) or issue required'],
    [{ type: 'unhold_ticket', project: 'cromford', issue: -1 }, 'ticket (PREFIX-<n>) or issue required']
  ];
  for (const [body, want] of cases) {
    const r = await post({ CONSOLE_DB: w.db }, body);
    assert.equal(r.status, 400, JSON.stringify(body));
    assert.deepEqual(r.json, { error: want }, JSON.stringify(body));
  }
  assert.equal(w.rows().length, 0);
  // Exactly 20000 characters is allowed.
  const ok = await post({ CONSOLE_DB: w.db }, { type: 'comment_issue', project: 'cromford', issue: 7, body: 'a'.repeat(20000) });
  assert.equal(ok.status, 200);
});

test('P10 a worker 400 for another reason passes through verbatim', async (t) => {
  worker(t, [400, { error: 'bad project' }]);
  const w = world();
  const r = await post({ CONSOLE_DB: w.db }, { type: 'comment_issue', project: 'cromford', issue: 7, body: 'hi' });
  assert.equal(r.status, 400);
  assert.equal(r.text, '{"error":"bad project"}');
  assert.equal(r.headers.get('x-worker'), 'yes');
  assert.equal(w.rows().length, 0);
  // A 5xx is not a refusal either.
  t.mock.restoreAll();
  worker(t, [500, { error: 'unknown action' }]);
  const f = await post({ CONSOLE_DB: w.db }, { type: 'comment_issue', project: 'cromford', issue: 7, body: 'hi' });
  assert.equal(f.status, 500);
  assert.equal(w.rows().length, 0);
});

test('A1 no cookie is a 403 and writes nothing', async (t) => {
  pinClock(t);
  const seen = worker(t);
  const w = world();
  for (const type of BOARD_FALLBACK_TYPES) {
    const body = type === 'comment_issue'
      ? { type, project: 'cromford', issue: 7, body: 'hi' }
      : { type, project: 'cromford', ticket: 'BH-7', reason: '' };
    const r = await post({ CONSOLE_DB: w.db }, body, { cookie: null });
    assert.equal(r.status, 403, `${type}: ${r.text}`);
    assert.deepEqual(r.json, { error: 'unauthorized' });
  }
  assert.equal(seen.probes.length, 0, 'no cookie is refused without a probe');
  assert.equal(w.rows().length, 0);
});

test('A2 a cookie the worker probe refuses is a 403 and writes nothing', async (t) => {
  pinClock(t);
  const w = world();
  for (const status of [401, 403, 302, 500]) {
    t.mock.restoreAll();
    const seen = worker(t, undefined, { probe: status });
    const r = await post({ CONSOLE_DB: w.db }, { type: 'comment_issue', project: 'cromford', issue: 7, body: 'hi' });
    assert.equal(r.status, 403, `probe ${status}: ${r.text}`);
    assert.deepEqual(r.json, { error: 'unauthorized' });
    assert.equal(seen.probes.length, 1);
  }
  // A cookie that is not the dash session is refused by the probe too.
  t.mock.restoreAll();
  worker(t);
  const x = await post({ CONSOLE_DB: w.db }, { type: 'hold_ticket', project: 'cromford', ticket: 'BH-7' }, { cookie: 'dash=forged' });
  assert.equal(x.status, 403);
  assert.equal(w.rows().length, 0);
});

test('A3 an unreachable auth probe fails closed', async (t) => {
  pinClock(t);
  worker(t, undefined, { probe: 'throw' });
  const w = world();
  const r = await post({ CONSOLE_DB: w.db }, { type: 'unhold_ticket', project: 'cromford', ticket: 'BH-7' });
  assert.equal(r.status, 403);
  assert.deepEqual(r.json, { error: 'unauthorized' });
  assert.equal(w.rows().length, 0);
});

test('A4 an unauthenticated bad body is refused as unauthorized, not validated', async (t) => {
  worker(t);
  const w = world();
  const r = await post({ CONSOLE_DB: w.db }, { type: 'comment_issue', project: 'a b', issue: 0 }, { cookie: null });
  assert.equal(r.status, 403);
  assert.deepEqual(r.json, { error: 'unauthorized' });
});

// A5/A6 (lead review of 81b713ba): an MCP client with HARNESS_CONSOLE_TOKEN
// sends `authorization: Bearer …` and no cookie (mcp/lib/console.mjs: "a token
// wins"). The probe must see that header, or every token client is a 403.
test('A5 a token client with no cookie passes the probe and is queued', async (t) => {
  pinClock(t);
  const seen = worker(t);
  const w = world();
  const r = await post({ CONSOLE_DB: w.db }, { type: 'comment_issue', project: 'cromford', issue: 7, body: 'from mcp' },
    { cookie: null, authorization: GOOD_AUTH });
  assert.equal(r.status, 200, r.text);
  assert.equal(r.json.ok, true);
  assert.deepEqual(seen.probes, [{ url: 'https://harness-console.operator.workers.dev/api/dash/fleet', cookie: null, authorization: GOOD_AUTH }],
    'the token passes the worker authed probe before the write');
  assert.equal(w.rows().length, 1);
});

test('A6 a token the worker probe refuses is a 403 and writes nothing', async (t) => {
  pinClock(t);
  const seen = worker(t);
  const w = world();
  const r = await post({ CONSOLE_DB: w.db }, { type: 'hold_ticket', project: 'cromford', ticket: 'BH-7' },
    { cookie: null, authorization: 'Bearer forged' });
  assert.equal(r.status, 403);
  assert.deepEqual(r.json, { error: 'unauthorized' });
  assert.equal(seen.probes.length, 1);
  assert.equal(w.rows().length, 0);
});

test('P11 the HOLD button shows a refusal to the user', async () => {
  const apiObj = { action: async () => { throw new Error('unknown action'); } };
  const r = await runTicketHold({
    apiObj, confirm: async () => true, action: 'hold',
    target: holdTarget('cromford', 'BH-7'), reasonForm: () => null
  });
  assert.deepEqual(r, { tone: 'bad', text: 'HOLD failed: unknown action' });
});

test('P12 a comment_issue history row links to its board', () => {
  assert.deepEqual(commandTarget({ type: 'comment_issue', project: 'cromford', payload: {} }),
    { to: '/p/cromford', label: 'cromford board' });
});
