// The read and action tools end to end: a real `node mcp/server.mjs` child
// against the stub console, plus a direct import for the module shape.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { createInterface } from 'node:readline';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { startStub } from './lib/stub-console.mjs';

const SERVER = fileURLToPath(new URL('../server.mjs', import.meta.url));
const TOKEN = 'tok-fixture-y';
const READ = ['project_status', 'builds', 'pipeline', 'prs', 'alerts', 'costs', 'machines', 'logs', 'chat'];
const WRITE = ['file_issue', 'comment_issue', 'hold_issue', 'run_triage', 'pause_board', 'resume_board', 'fetch_artifact'];

function spawnServer(env) {
  const child = spawn(process.execPath, [SERVER], {
    env: { PATH: process.env.PATH, ...env },
    stdio: ['pipe', 'pipe', 'pipe'],
  });
  let stderr = '';
  child.stderr.on('data', (c) => { stderr += c; });
  const pending = new Map();
  createInterface({ input: child.stdout }).on('line', (line) => {
    const m = JSON.parse(line);
    pending.get(m.id)?.(m);
    pending.delete(m.id);
  });
  const exited = new Promise((r) => child.on('exit', (code) => r(code)));
  let id = 0;
  const rpc = (method, params) => new Promise((resolve) => {
    const mid = ++id;
    pending.set(mid, resolve);
    child.stdin.write(JSON.stringify({ jsonrpc: '2.0', id: mid, method, params }) + '\n');
  });
  return {
    child, rpc,
    stderr: () => stderr,
    notify: (method) => child.stdin.write(JSON.stringify({ jsonrpc: '2.0', method }) + '\n'),
    end: () => { child.stdin.end(); return exited; },
  };
}

// One server and one stub for the whole file; every case reads the request
// log delta it caused.
let stub, srv;
const texts = [];

test.before(async () => {
  stub = await startStub({ fail: { '/api/dash/alerts': 404 } });
  srv = spawnServer({ HARNESS_CONSOLE_URL: stub.url, HARNESS_CONSOLE_TOKEN: TOKEN });
  const init = await srv.rpc('initialize', { protocolVersion: '2025-11-25' });
  assert.equal(init.result.serverInfo.name, 'cromford');
  srv.notify('notifications/initialized');
});

test.after(async () => {
  srv.child.kill();
  await stub.close();
});

async function call(name, args) {
  const before = stub.requests.length;
  const r = await srv.rpc('tools/call', { name, arguments: args });
  assert.equal(r.error, undefined, JSON.stringify(r));
  for (const c of r.result.content ?? []) texts.push(c.text);
  return { result: r.result, sent: stub.requests.slice(before) };
}

test('1 tools/list has fleet_status and all 16 tools', async () => {
  const r = await srv.rpc('tools/list', {});
  const names = new Set(r.result.tools.map((t) => t.name));
  for (const n of ['fleet_status', ...READ, ...WRITE]) assert.ok(names.has(n), `missing ${n}`);
});

test('2 module shape: kinds, closed schemas, no tenant', async () => {
  const read = (await import('../tools/read.mjs')).tools;
  const actions = (await import('../tools/actions.mjs')).tools;
  assert.deepEqual(read.map((t) => t.name), READ);
  assert.deepEqual(actions.map((t) => t.name), WRITE);
  assert.ok(read.every((t) => t.kind === 'read'));
  assert.ok(actions.every((t) => t.kind === 'write'));
  const closed = (s) => s.type !== 'object' ||
    (s.additionalProperties === false && Object.values(s.properties ?? {}).every(closed));
  for (const t of [...read, ...actions]) {
    assert.equal(t.inputSchema.type, 'object', t.name);
    assert.ok(closed(t.inputSchema), `${t.name} has an open object level`);
    assert.ok(!JSON.stringify(t.inputSchema).includes('"tenant"'), t.name);
  }
});

// project_status is not here since BH-7876: it reads its daily ceiling beside
// the dash route, four GETs, pinned in project-status-ceiling.bh-7876.test.mjs
// (M1 path, bearer and no body; M4 the same 'a/b c' encoding).
const READ_CASES = [
  ['builds', { limit: 5 }, 'GET', '/api/dash/builds?limit=5'],
  ['builds', {}, 'GET', '/api/dash/builds'],
  ['pipeline', { limit: 10, filter: { project: 'p' } }, 'GET', '/api/dash/kanban/pipeline?project=p&shipped_limit=10'],
  ['pipeline', {}, 'GET', '/api/dash/kanban/pipeline'],
  ['prs', { filter: { project: 'p' }, limit: 3, state: 'open' }, 'GET', '/api/dash/prs/p?limit=3&state=open'],
  ['prs', { filter: { project: 'x/y' } }, 'GET', '/api/dash/prs/x%2Fy'],
  ['alerts', { filter: { severity: 'page' } }, 'GET', '/api/dash/alerts?severity=page'],
  ['costs', {}, 'GET', '/api/dash/costs'],
  ['costs', { limit: 2, filter: { project: 'p', since: '2026-10-01' } }, 'GET', '/api/dash/costs?limit=2&project=p&since=2026-10-01'],
  ['machines', {}, 'GET', '/api/dash/machines'],
  ['logs', { project: 'p', lines: 50 }, 'GET', '/api/dash/logs/p?lines=50'],
  ['logs', { project: 'p' }, 'GET', '/api/dash/logs/p'],
];

test('3 read tools forward once to their route with the bearer', async () => {
  for (const [name, args, method, path] of READ_CASES) {
    const { sent } = await call(name, args);
    assert.equal(sent.length, 1, `${name} ${JSON.stringify(args)} sent ${sent.length}`);
    assert.equal(sent[0].method, method, name);
    assert.equal(sent[0].path, path, name);
    assert.equal(sent[0].authorization, `Bearer ${TOKEN}`, name);
    assert.equal(sent[0].body, null, name);
  }
});

test('3b chat posts {text} and adds target only when a project is given', async () => {
  const a = await call('chat', { message: 'hi', project: 'p' });
  assert.equal(a.sent.length, 1);
  assert.equal(a.sent[0].method, 'POST');
  assert.equal(a.sent[0].path, '/api/dash/chat');
  assert.deepEqual(a.sent[0].body, { text: 'hi', target: 'p' });
  assert.equal(a.result.isError, undefined);

  const b = await call('chat', { message: 'hi' });
  assert.equal(b.sent.length, 1);
  assert.deepEqual(b.sent[0].body, { text: 'hi' });
});

const ACTION_CASES = [
  ['file_issue', { project: 'p', title: 't', body: 'b' }],
  ['comment_issue', { project: 'p', issue: 1, body: 'hi' }],
  // BH-5820: hold_issue is sent as the hub's own type, hold_ticket.
  ['hold_issue', { project: 'p', issue: 2, reason: 'r' }, 'hold_ticket'],
  ['run_triage', { project: 'p', issue: 3 }],
  ['pause_board', { project: 'p' }],
  ['resume_board', { project: 'p' }],
  ['fetch_artifact', { project: 'p', build_id: 'b1', name: 'plan.md' }],
];

test('4 action tools post {type, ...args} to /api/dash/action exactly once', async () => {
  for (const [name, args, type = name] of ACTION_CASES) {
    const { result, sent } = await call(name, args);
    assert.equal(sent.length, 1, `${name} sent ${sent.length}`);
    assert.equal(sent[0].method, 'POST', name);
    assert.equal(sent[0].path, '/api/dash/action', name);
    assert.equal(sent[0].authorization, `Bearer ${TOKEN}`, name);
    assert.deepEqual(sent[0].body, { type, ...args }, name);
    assert.equal(result.isError, undefined, name);
  }
});

test('4b comment_issue body is byte-for-byte the ticket case', async () => {
  const { result } = await call('comment_issue', { project: 'p', issue: 1, body: 'hi' });
  // The stub echoes the parsed body; re-serialize to pin key order.
  assert.equal(JSON.stringify(result.structuredContent.body), '{"type":"comment_issue","project":"p","issue":1,"body":"hi"}');
});

test('5 refusals send nothing', async () => {
  const cases = [
    ['builds', { limit: 1, tenant: 'x' }, 'invalid_arguments: tenant'],
    ['comment_issue', { project: 'p', issue: 1, body: 'hi', type: 'merge_pr' }, 'invalid_arguments: type'],
    ['prs', {}, 'project_required'],
    ['prs', { filter: {} }, 'project_required'],
    ['prs', { filter: { project: '' } }, 'project_required'],
    ['pipeline', { filter: { project: 'p', tenant: 'x' } }, 'invalid_arguments: filter.tenant'],
    // The rest of the schema: required, type, length, range, enum, nested.
    ['project_status', {}, 'invalid_arguments: project'],
    ['project_status', { project: '' }, 'invalid_arguments: project'],
    ['logs', {}, 'invalid_arguments: project'],
    ['logs', { project: 'p', lines: 501 }, 'invalid_arguments: lines'],
    ['pause_board', {}, 'invalid_arguments: project'],
    ['comment_issue', { project: 'p' }, 'invalid_arguments: issue'],
    ['comment_issue', { project: 'p', issue: 1 }, 'invalid_arguments: body'],
    ['comment_issue', { project: 'p', issue: '1 or 1', body: 'hi' }, 'invalid_arguments: issue'],
    ['comment_issue', { project: 'p', issue: 1, body: '' }, 'invalid_arguments: body'],
    ['comment_issue', { project: 'p', issue: 1.5, body: 'hi' }, 'invalid_arguments: issue'],
    ['fetch_artifact', { project: 'p', build_id: 'b1' }, 'invalid_arguments: name'],
    ['chat', {}, 'invalid_arguments: message'],
    ['chat', { message: 'x'.repeat(4001) }, 'invalid_arguments: message'],
    ['builds', { limit: -5 }, 'invalid_arguments: limit'],
    ['builds', { limit: '5' }, 'invalid_arguments: limit'],
    ['prs', { filter: { project: 'p' }, state: 'draft' }, 'invalid_arguments: state'],
    ['prs', { filter: 'p' }, 'project_required'],
    ['prs', { filter: { project: 'p' }, limit: 0 }, 'invalid_arguments: limit'],
    ['alerts', { filter: { severity: 'loud' } }, 'invalid_arguments: filter.severity'],
    ['pipeline', { filter: { project: 7 } }, 'invalid_arguments: filter.project'],
  ];
  for (const [name, args, msg] of cases) {
    const { result, sent } = await call(name, args);
    assert.equal(result.isError, true, `${name} ${JSON.stringify(args)}`);
    assert.equal(result.content[0].text, msg);
    assert.equal(sent.length, 0, `${name} ${JSON.stringify(args)} sent a request`);
  }
});

test('6 a console 404 on an unconfirmed route is an honest isError', async () => {
  const { result, sent } = await call('alerts', {});
  assert.equal(sent.length, 1);
  assert.equal(result.isError, true);
  assert.equal(result.content[0].text, 'console route not available: /api/dash/alerts');
});

test('7 the token never leaks into results or stderr', async () => {
  assert.ok(texts.length > 0);
  await srv.end();
  assert.ok(!texts.join('\n').includes(TOKEN));
  assert.ok(!srv.stderr().includes(TOKEN));
});

test('8 public-tree files carry no private names', () => {
  const words = [['li', 'orwn'], ['fortu', 'nian'], ['board-', 'watcher'], ['or', 'go']].map((w) => w.join(''));
  const re = new RegExp(words.join('|'), 'i');
  const files = ['../tools/read.mjs', '../tools/actions.mjs', '../tools/lib/schema.mjs',
    './read-action-tools.test.mjs',
    '../../docs/MCP.md', '../../docs/notes/2026-10-07-BH-5218-mcp-server.md'];
  for (const f of files) {
    const text = readFileSync(new URL(f, import.meta.url), 'utf8');
    assert.equal(re.exec(text), null, f);
  }
});
