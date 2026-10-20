// BH-7708: pause_project and resume_project. Each one sends three console
// commands in one call (board, automerge, pool) and reports one result per
// part plus the project state after. Without confirm: true they send nothing.
// Every case runs a REAL `node mcp/server.mjs` child against a console stub on
// 127.0.0.1 that answers each POST by its body type. No other network.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { spawn } from 'node:child_process';
import { createInterface } from 'node:readline';
import { cpSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

const MCP_DIR = fileURLToPath(new URL('..', import.meta.url));
const SERVER = join(MCP_DIR, 'server.mjs');
const TOKEN = 'tok-fixture-bh7708';
const SECRET = 'sec-fixture-bh7708/+&';

// The console stub. `answers[type]` is [status, json] for a POST of that body
// type (default 200 with a command id); `state` is [status, json] for the GET
// of the project page. On a 500 the stub echoes the request headers back.
function startConsole({ answers = {}, state = [200, { board: { paused: true, automerge: false } }] } = {}) {
  const requests = [];
  let next = 100;
  const send = (res, status, json, headers = {}) => {
    res.writeHead(status, { 'content-type': 'application/json', ...headers });
    res.end(JSON.stringify(json));
  };
  const server = http.createServer((req, res) => {
    let raw = '';
    req.on('data', (c) => { raw += c; });
    req.on('end', () => {
      const body = raw ? JSON.parse(raw) : null;
      requests.push({ method: req.method, path: req.url, body, headers: req.headers });
      const login = /^\/login\/([^/?]+)$/.exec(req.url);
      if (req.method === 'GET' && login) {
        res.writeHead(302, { 'set-cookie': `dash=ck-${login[1]}; Path=/; HttpOnly`, location: '/' });
        return res.end();
      }
      if (req.method === 'POST' && req.url === '/api/dash/action') {
        const [status, json] = answers[body?.type] ?? [200, { ok: true, command_id: ++next }];
        return send(res, status, status === 500 ? { ...json, headers: req.headers } : json);
      }
      if (req.method === 'GET' && req.url.startsWith('/api/dash/p/')) {
        const [status, json] = state;
        return send(res, status, status === 500 ? { ...json, headers: req.headers } : json);
      }
      send(res, 404, { error: 'not_found' });
    });
  });
  return new Promise((resolve) => {
    server.listen(0, '127.0.0.1', () => resolve({
      url: `http://127.0.0.1:${server.address().port}`,
      requests,
      api: () => requests.filter((r) => !r.path.startsWith('/login/')),
      close: () => new Promise((r) => { server.closeAllConnections?.(); server.close(() => r()); }),
    }));
  });
}

async function serve(t, { stub: stubOpts, env = { HARNESS_CONSOLE_TOKEN: TOKEN }, server = SERVER } = {}) {
  const stub = await startConsole(stubOpts);
  const child = spawn(process.execPath, [server], {
    env: { PATH: process.env.PATH, HARNESS_CONSOLE_URL: stub.url, ...env },
    stdio: ['pipe', 'pipe', 'pipe'],
  });
  let stderr = '';
  child.stderr.on('data', (d) => { stderr += d; });
  const lines = [];
  const pending = new Map();
  createInterface({ input: child.stdout }).on('line', (line) => {
    lines.push(line);
    const m = JSON.parse(line);
    pending.get(m.id)?.(m);
    pending.delete(m.id);
  });
  let id = 0;
  const rpc = (method, params) => new Promise((resolve) => {
    const mid = ++id;
    pending.set(mid, resolve);
    child.stdin.write(JSON.stringify({ jsonrpc: '2.0', id: mid, method, params }) + '\n');
  });
  t.after(async () => { child.kill(); await stub.close(); });
  await rpc('initialize', { protocolVersion: '2025-11-25' });
  const call = async (name, args) => {
    const before = stub.api().length;
    const r = await rpc('tools/call', { name, arguments: args });
    assert.equal(r.error, undefined, JSON.stringify(r));
    return { result: r.result, sent: stub.api().slice(before) };
  };
  return { stub, rpc, call, lines, stderr: () => stderr };
}

const posts = (sent) => sent.filter((r) => r.method === 'POST' && r.path === '/api/dash/action');
const byType = (sent) => new Map(posts(sent).map((r) => [r.body.type, r.body]));

test('M1 tools/list has both tools, with closed schemas that need confirm', async (t) => {
  const { rpc } = await serve(t);
  const r = await rpc('tools/list', {});
  const byName = new Map(r.result.tools.map((x) => [x.name, x]));
  for (const n of ['pause_project', 'resume_project']) {
    assert.ok(byName.has(n), `missing ${n}`);
    const s = byName.get(n).inputSchema;
    assert.equal(s.additionalProperties, false, n);
    assert.ok(s.required.includes('confirm'), n);
    assert.ok(s.required.includes('project'), n);
    assert.equal('tenant' in s.properties, false, n);
  }
  assert.ok(byName.get('resume_project').inputSchema.required.includes('automerge'));
  assert.equal('automerge' in byName.get('pause_project').inputSchema.properties, false);
});

test('M2 without confirm: true, confirm_required and 0 requests', async (t) => {
  const { call, stub } = await serve(t);
  for (const name of ['pause_project', 'resume_project']) {
    for (const confirm of [undefined, false, 'true', 'yes', 1, {}]) {
      const args = { project: 'pa', automerge: true, ...(confirm === undefined ? {} : { confirm }) };
      if (name === 'pause_project') delete args.automerge;
      const { result, sent } = await call(name, args);
      assert.equal(result.isError, true, `${name} ${JSON.stringify(confirm)}`);
      assert.equal(result.content[0].text, 'confirm_required');
      assert.equal(sent.length, 0, `${name} confirm=${JSON.stringify(confirm)} sent a request`);
    }
  }
  assert.equal(stub.requests.length, 0, 'not even a login');
});

test('M3 pause_project: three commands, then the state after', async (t) => {
  const { call } = await serve(t);
  const { result, sent } = await call('pause_project', { project: 'pa', confirm: true });
  assert.equal(result.isError, undefined, JSON.stringify(result));
  assert.equal(posts(sent).length, 3);
  const b = byType(sent);
  assert.deepEqual([...b.keys()].sort(), ['automerge_off', 'pause_board', 'pool_hold']);
  assert.equal(b.get('pause_board').project, 'pa');
  assert.ok(b.get('pause_board').reason.length > 0, 'the proxy refuses a pause with no reason');
  assert.deepEqual(b.get('automerge_off'), { type: 'automerge_off', project: 'pa' });
  assert.equal(b.get('pool_hold').hold, true);
  assert.equal(b.get('pool_hold').project, 'pa');
  assert.equal('confirm' in b.get('pool_hold'), false, 'confirm is not sent to the console');
  // The state read goes last, once.
  assert.equal(sent.length, 4);
  assert.deepEqual([sent[3].method, sent[3].path], ['GET', '/api/dash/p/pa']);
  const s = result.structuredContent;
  assert.equal(s.project, 'pa');
  assert.equal(s.ok, true);
  assert.deepEqual(s.parts.map((p) => [p.part, p.type, p.ok, p.error]),
    [['board', 'pause_board', true, null], ['automerge', 'automerge_off', true, null], ['pool', 'pool_hold', true, null]]);
  for (const p of s.parts) assert.ok(Number.isInteger(p.command_id) && p.command_id > 100, JSON.stringify(p));
  assert.deepEqual(s.state_after, { paused: true, automerge: false });
  assert.deepEqual(s.partial, []);
  assert.match(s.note, /queued/);
  for (const p of ['pause_board', 'automerge_off', 'pool_hold']) assert.ok(result.content[0].text.includes(p), p);
  const reason = await call('pause_project', { project: 'pa', confirm: true, reason: 'drain for the operator' });
  const rb = byType(reason.sent);
  assert.equal(rb.get('pause_board').reason, 'drain for the operator');
  assert.equal(rb.get('pool_hold').reason, 'drain for the operator');
});

test('M4 resume_project: resume, release, and automerge as given', async (t) => {
  const { call } = await serve(t, { stub: { state: [200, { board: { paused: false, automerge: true } }] } });
  const on = await call('resume_project', { project: 'pa', confirm: true, automerge: true });
  const b = byType(on.sent);
  assert.equal(posts(on.sent).length, 3);
  assert.deepEqual([...b.keys()].sort(), ['automerge_on', 'pool_hold', 'resume_board']);
  assert.equal(b.get('pool_hold').hold, false);
  assert.ok(b.get('resume_board').reason.length > 0);
  assert.deepEqual(on.result.structuredContent.parts.map((p) => [p.part, p.type]),
    [['board', 'resume_board'], ['automerge', 'automerge_on'], ['pool', 'pool_hold']]);
  assert.deepEqual(on.result.structuredContent.state_after, { paused: false, automerge: true });
  const off = await call('resume_project', { project: 'pa', confirm: true, automerge: false });
  assert.deepEqual([...byType(off.sent).keys()].sort(), ['automerge_off', 'pool_hold', 'resume_board']);
  for (const automerge of [undefined, 'true', 1]) {
    const args = { project: 'pa', confirm: true, ...(automerge === undefined ? {} : { automerge }) };
    const bad = await call('resume_project', args);
    assert.equal(bad.result.isError, true);
    assert.equal(bad.result.content[0].text, 'invalid_arguments: automerge');
    assert.equal(bad.sent.length, 0);
  }
  const extra = await call('pause_project', { project: 'pa', confirm: true, type: 'merge_pr' });
  assert.equal(extra.result.content[0].text, 'invalid_arguments: type');
  assert.equal(extra.sent.length, 0);
});

test('M5 a failed part is reported, and the other parts still go', async (t) => {
  const { call } = await serve(t, { stub: { answers: { pool_hold: [400, { error: 'unknown action' }] } } });
  const { result, sent } = await call('pause_project', { project: 'pa', confirm: true });
  assert.equal(posts(sent).length, 3, 'all three are sent');
  assert.equal(result.isError, true);
  const s = result.structuredContent;
  assert.equal(s.ok, false);
  const pool = s.parts.find((p) => p.part === 'pool');
  assert.deepEqual([pool.ok, pool.command_id, pool.error], [false, null, 'http_400: unknown action']);
  for (const p of s.parts.filter((x) => x.part !== 'pool')) assert.equal(p.ok, true, p.part);
  assert.ok(result.content[0].text.includes('http_400: unknown action'));
});

test('M6 a failed state read is named as partial; the parts still show', async (t) => {
  const { call } = await serve(t, { stub: { state: [503, { error: 'down' }] } });
  const { result } = await call('pause_project', { project: 'pa', confirm: true });
  const s = result.structuredContent;
  assert.equal(s.state_after, null);
  assert.deepEqual(s.partial, ['/api/dash/p/pa']);
  assert.equal(s.parts.length, 3);
  assert.equal(s.ok, true, 'the three commands were queued');
  // A state answer with no booleans is unknown, never false.
  const t2 = await serve(t, { stub: { state: [200, { board: {} }] } });
  const r2 = await t2.call('pause_project', { project: 'pa', confirm: true });
  assert.deepEqual(r2.result.structuredContent.state_after, { paused: null, automerge: null });
});

test('M7 secret mode: no secret, encoded secret or cookie reaches the client or stderr', async (t) => {
  const { call, lines, stderr, stub } = await serve(t, {
    env: { HARNESS_CONSOLE_SECRET: SECRET },
    stub: { answers: { pause_board: [500, { error: 'boom' }], pool_hold: [400, { error: `bad ${SECRET}` }] }, state: [500, { error: 'boom' }] },
  });
  const { result, sent } = await call('pause_project', { project: 'pa', confirm: true });
  assert.equal(posts(sent).length, 3);
  assert.ok(sent.every((r) => r.headers.cookie === `dash=ck-${encodeURIComponent(SECRET)}`), 'the dash cookie was sent');
  assert.equal(result.isError, true);
  const seen = [...lines, stderr()].join('\n');
  for (const v of [SECRET, encodeURIComponent(SECRET), `ck-${encodeURIComponent(SECRET)}`]) {
    assert.equal(seen.includes(v), false, `leaked ${v}`);
  }
  assert.equal(stub.requests.filter((r) => r.path.startsWith('/login/')).length, 1);
});

test('M8 a project with a slash is encoded in the state path', async (t) => {
  const { call } = await serve(t);
  const { sent } = await call('pause_project', { project: 'a/b', confirm: true });
  assert.equal(sent.at(-1).path, '/api/dash/p/a%2Fb');
});

test('M9 mutation pin: with the confirm check removed, a call without confirm sends', async (t) => {
  const dir = mkdtempSync(join(tmpdir(), 'mcp-mut-'));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  cpSync(MCP_DIR, dir, { recursive: true });
  const file = join(dir, 'tools', 'project-pause.mjs');
  const src = readFileSync(file, 'utf8');
  const anchor = "if (args.confirm !== true) return 'confirm_required';";
  assert.equal(src.split(anchor).length, 2, 'mutation anchor not found exactly once');
  writeFileSync(file, src.replace(anchor, ''));
  const { call } = await serve(t, { server: join(dir, 'server.mjs') });
  const { sent } = await call('pause_project', { project: 'pa', confirm: false });
  assert.ok(sent.length > 0, 'the mutant sends, so M2 is what holds the guard');
});
