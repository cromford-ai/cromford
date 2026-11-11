import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { DatabaseSync } from 'node:sqlite';
import { onRequest as dash } from '../functions/api/[[path]].js';
import { BOARD_FALLBACK_TYPES, ISSUE_TITLE_MAX, COMMENT_BODY_MAX } from '../functions/_lib/board-commands.js';
import { tools as mcpActions } from '../../mcp/tools/actions.mjs';
import { commandRows, commandTarget } from '../src/lib/commands.js';

// BH-9014. The MCP `file_issue` tool sends POST /api/dash/action
// {type:'file_issue', project, title, body?}. The console worker refuses it
// with 400 'unknown action', so the Pages proxy queues the command row itself,
// as it does for the BH-5820 types. The hub runs the row through
// bin/lib/tracker/issue-file-cmd.sh (tests/issue-file-cmd.bh-9014-test.sh).
//
// Every case runs the REAL Pages onRequest against a fake console worker and a
// real SQLite `commands` table in D1's prepare/bind/run/first shape (the
// BH-5820 world).

const NOW = Date.parse('2026-10-09T12:34:56Z');
const GOOD = 'dash=good';
const GOOD_AUTH = 'Bearer tok-fixture-bh9014';
// The payload I1 of tests/issue-file-cmd.bh-9014-test.sh runs ifcmd_run on.
const I1_PAYLOAD = '{"title":"t1","body":"b1","actor":"console"}';

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

function worker(t, answer = [400, { error: 'unknown action' }]) {
  const seen = [];
  seen.probes = [];
  t.mock.method(globalThis, 'fetch', async (url, init) => {
    if (new URL(String(url)).pathname === '/api/dash/fleet') {
      const h = new Headers(init && init.headers);
      const cookie = h.get('cookie');
      const authorization = h.get('authorization');
      seen.probes.push({ cookie, authorization });
      return new Response('{}', { status: cookie === GOOD || authorization === GOOD_AUTH ? 200 : 403 });
    }
    seen.push({ url: String(url), body: init.body ? JSON.parse(init.body) : null });
    return new Response(JSON.stringify(answer[1]),
      { status: answer[0], headers: { 'content-type': 'application/json' } });
  });
  return seen;
}

async function post(env, body, { cookie = GOOD, authorization = null } = {}) {
  const headers = { 'content-type': 'application/json' };
  if (cookie) headers.cookie = cookie;
  if (authorization) headers.authorization = authorization;
  const res = await dash({
    request: new Request('https://console.example/api/dash/action', {
      method: 'POST', headers, body: typeof body === 'string' ? body : JSON.stringify(body)
    }),
    env
  });
  const text = await res.text();
  let json = null;
  try { json = JSON.parse(text); } catch { /* not json */ }
  return { status: res.status, json, text };
}

const pinClock = (t) => t.mock.timers.enable({ apis: ['Date'], now: NOW });
const hash16 = (s) => createHash('sha256').update(s).digest('hex').slice(0, 16);

// The body the real MCP tool sends for these arguments.
async function mcpBody(args) {
  const tool = mcpActions.find((x) => x.name === 'file_issue');
  assert.ok(tool, 'the MCP has a file_issue tool');
  assert.ok(!(await tool.precheck(args)), 'the MCP precheck accepts the arguments');
  let sent = null;
  const ctx = {
    cfg: {},
    consoleFetch: async (_cfg, method, path, body) => {
      sent = { method, path, body };
      return { ok: true, data: {} };
    }
  };
  await tool.handler(args, ctx);
  assert.equal(sent.method, 'POST');
  assert.equal(sent.path, '/api/dash/action');
  return sent.body;
}

test('F1 the MCP file_issue body, posted to Pages, queues one file_issue row', async (t) => {
  pinClock(t);
  const seen = worker(t);
  const w = world();
  const body = await mcpBody({ project: 'cromford', title: 't1', body: 'b1' });
  assert.deepEqual(body, { type: 'file_issue', project: 'cromford', title: 't1', body: 'b1' });
  const r = await post({ CONSOLE_DB: w.db }, body);
  assert.equal(seen.length, 1, 'the worker is asked first');
  assert.equal(seen.probes.length, 1, 'the authed probe runs before the write');
  assert.equal(r.status, 200, r.text);
  assert.equal(r.json.ok, true);
  assert.equal(r.json.type, 'file_issue');
  assert.ok(Number.isInteger(r.json.command_id) && r.json.command_id > 0, r.text);
  const rows = w.rows();
  assert.equal(rows.length, 1);
  assert.equal(rows[0].id, r.json.command_id);
  assert.equal(rows[0].type, 'file_issue');
  assert.equal(rows[0].project, 'cromford');
  assert.equal(rows[0].status, 'pending');
  assert.equal(rows[0].ckey, r.json.ckey);
  assert.equal(rows[0].payload, I1_PAYLOAD, 'the payload the hub suite runs on, byte for byte');
});

test('F2 file_issue joins the fallback set; the three board types stay', () => {
  assert.ok(BOARD_FALLBACK_TYPES.has('file_issue'));
  for (const ty of ['comment_issue', 'hold_ticket', 'unhold_ticket']) assert.ok(BOARD_FALLBACK_TYPES.has(ty), ty);
  assert.equal(ISSUE_TITLE_MAX, 256);
});

test('F3 the ckey is project:file_issue:<UTC minute>:<sha256(title\\nbody)[0:16]>', async (t) => {
  pinClock(t);
  worker(t);
  const w = world();
  const a = await post({ CONSOLE_DB: w.db }, { type: 'file_issue', project: 'cromford', title: 't1', body: 'b1' });
  assert.equal(a.status, 200, a.text);
  assert.equal(a.json.ckey, `cromford:file_issue:2026-10-09T12:34:${hash16('t1\nb1')}`);
  const b = await post({ CONSOLE_DB: w.db }, { type: 'file_issue', project: 'cromford', title: 't1', body: 'b1' });
  assert.equal(b.json.command_id, a.json.command_id, 'the same post in the same minute is the same command');
  assert.equal(w.rows().length, 1);
  const c = await post({ CONSOLE_DB: w.db }, { type: 'file_issue', project: 'cromford', title: 't1', body: 'b2' });
  assert.notEqual(c.json.command_id, a.json.command_id, 'another body is another command');
  assert.equal(w.rows().length, 2);
});

test('F4 no body is an empty body', async (t) => {
  pinClock(t);
  worker(t);
  const w = world();
  const body = await mcpBody({ project: 'cromford', title: 't1' });
  const r = await post({ CONSOLE_DB: w.db }, body);
  assert.equal(r.status, 200, r.text);
  assert.equal(r.json.ckey, `cromford:file_issue:2026-10-09T12:34:${hash16('t1\n')}`);
  assert.deepEqual(JSON.parse(w.rows()[0].payload), { title: 't1', body: '', actor: 'console' });
});

test('F5 a bad title or body is a 400 that names the field, and queues nothing', async (t) => {
  pinClock(t);
  worker(t);
  const w = world();
  const base = { type: 'file_issue', project: 'cromford' };
  const cases = [
    [{ body: 'b' }, /title/],
    [{ title: '   ' }, /title/],
    [{ title: 7 }, /title/],
    [{ title: 'x'.repeat(ISSUE_TITLE_MAX + 1) }, /title/],
    [{ title: 't', body: 9 }, /body/],
    [{ title: 't', body: 'x'.repeat(COMMENT_BODY_MAX + 1) }, /body/]
  ];
  for (const [extra, field] of cases) {
    const r = await post({ CONSOLE_DB: w.db }, { ...base, ...extra });
    assert.equal(r.status, 400, JSON.stringify(extra).slice(0, 80));
    assert.match(r.json.error, field);
  }
  assert.equal(w.rows().length, 0);
  const ok = await post({ CONSOLE_DB: w.db },
    { ...base, title: 'x'.repeat(ISSUE_TITLE_MAX), body: 'y'.repeat(COMMENT_BODY_MAX) });
  assert.equal(ok.status, 200, ok.text.slice(0, 200));
  assert.equal(w.rows().length, 1);
  // The title is stored trimmed.
  await post({ CONSOLE_DB: w.db }, { ...base, title: '  spaced  ' });
  assert.equal(JSON.parse(w.rows()[1].payload).title, 'spaced');
});

test('F6 no credentials is a 403 before validation, with no probe and no row', async (t) => {
  const seen = worker(t);
  const w = world();
  const r = await post({ CONSOLE_DB: w.db }, { type: 'file_issue', project: 'cromford', title: 't1' }, { cookie: null });
  assert.equal(r.status, 403);
  assert.deepEqual(r.json, { error: 'unauthorized' });
  assert.equal(seen.probes.length, 0);
  assert.equal(w.rows().length, 0);
  // Unauthorised beats invalid: a bad title without credentials is still 403.
  const b = await post({ CONSOLE_DB: w.db }, { type: 'file_issue', project: 'cromford', title: 7 }, { cookie: null });
  assert.equal(b.status, 403);
});

test('F7 a cookie the probe refuses is a 403; a token client queues', async (t) => {
  pinClock(t);
  worker(t);
  const w = world();
  const r = await post({ CONSOLE_DB: w.db }, { type: 'file_issue', project: 'cromford', title: 't1' }, { cookie: 'dash=bad' });
  assert.equal(r.status, 403);
  assert.equal(w.rows().length, 0);
  const m = await post({ CONSOLE_DB: w.db }, { type: 'file_issue', project: 'cromford', title: 't1' },
    { cookie: null, authorization: GOOD_AUTH });
  assert.equal(m.status, 200, m.text);
  assert.equal(w.rows().length, 1);
});

test('F8 a worker that accepts file_issue is passed through, and Pages writes nothing', async (t) => {
  const seen = worker(t, [200, { ok: true, type: 'file_issue', ckey: 'k', command_id: 901 }]);
  const w = world();
  const r = await post({ CONSOLE_DB: w.db }, { type: 'file_issue', project: 'cromford', title: 't1' });
  assert.equal(seen.length, 1);
  assert.equal(r.status, 200);
  assert.deepEqual(r.json, { ok: true, type: 'file_issue', ckey: 'k', command_id: 901 });
  assert.equal(w.rows().length, 0);
});

test('F9 a file_issue row on /history/commands links to its board', () => {
  // The row the worker hands back for the F1 command (payload as a JSON string).
  const { rows, malformed } = commandRows({ commands: [
    { id: 12, type: 'file_issue', project: 'cromford', status: 'done', payload: I1_PAYLOAD,
      result: 'filed #500 https://github.com/example-org/cromford/issues/500 as the App (command 12, actor console)' }
  ] });
  assert.equal(malformed, false);
  assert.equal(rows.length, 1);
  assert.deepEqual(commandTarget(rows[0]), { to: '/p/cromford', label: 'cromford board' });
  assert.match(rows[0].outcome, /^filed #500 https:\/\/github\.com\/example-org\/cromford\/issues\/500 /);
});
