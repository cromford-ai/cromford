// project_status adds a spend_ceiling block: the project's daily ceiling row
// (conf.cost-caps.<project>.daily_usd) and its spend for the current UTC day,
// read in parallel with the dash read. A real `node mcp/server.mjs` child
// against the stub console.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { createInterface } from 'node:readline';
import { fileURLToPath } from 'node:url';
import { startStub } from './lib/stub-console.mjs';

const SERVER = fileURLToPath(new URL('../server.mjs', import.meta.url));
const TOKEN = 'tok-fixture-ceiling';
const SETTING = (p) => `/api/coord/settings/conf.cost-caps.${p}.daily_usd`;
const SPEND = (p) => `/api/coord/metrics/llm-spend?project=${p}`;
const WARN = '/api/coord/settings/conf.cost-caps.daily_warn_pct';

function spawnServer(env) {
  const child = spawn(process.execPath, [SERVER], { env: { PATH: process.env.PATH, ...env }, stdio: ['pipe', 'pipe', 'pipe'] });
  const pending = new Map();
  createInterface({ input: child.stdout }).on('line', (line) => {
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
  return { child, rpc, notify: (method) => child.stdin.write(JSON.stringify({ jsonrpc: '2.0', method }) + '\n') };
}

let stub, srv;
// The stub reads this object per request, so a case can add a route to it.
const ROUTES = {
      '/api/dash/p/acme-os': { json: { project: 'acme-os', board: { open: 3 } } },
      [SETTING('acme-os')]: { json: { key: 'conf.cost-caps.acme-os.daily_usd', setting: { value: '5000' }, source: 'db' } },
      [SPEND('acme-os')]: { json: { usd: 4100.5, calls: 9, refused: 0, settled: 0, as_of: '2026-10-21T19:00:00Z' } },
      [SETTING('nocap')]: { json: { key: 'conf.cost-caps.nocap.daily_usd', setting: null } },
      [SETTING('down')]: { json: { key: 'conf.cost-caps.down.daily_usd', setting: { value: '50' } } },
};
test.before(async () => {
  stub = await startStub({ fail: { '/api/dash/p/gone': 404, [SPEND('down')]: 500 }, routes: ROUTES });
  srv = spawnServer({ HARNESS_CONSOLE_URL: stub.url, HARNESS_CONSOLE_TOKEN: TOKEN });
  await srv.rpc('initialize', { protocolVersion: '2025-11-25' });
  srv.notify('notifications/initialized');
});
test.after(async () => { srv.child.kill(); await stub.close(); });

async function call(project) {
  const before = stub.requests.length;
  const r = await srv.rpc('tools/call', { name: 'project_status', arguments: { project } });
  assert.equal(r.error, undefined, JSON.stringify(r));
  return { result: r.result, sent: stub.requests.slice(before) };
}

test('M1 four GETs with the bearer; the dash answer plus spend_ceiling', async () => {
  const { result, sent } = await call('acme-os');
  assert.deepEqual(sent.map((s) => s.path).sort(), ['/api/dash/p/acme-os', SETTING('acme-os'), SPEND('acme-os'), WARN].sort());
  for (const s of sent) {
    assert.equal(s.method, 'GET');
    assert.equal(s.authorization, `Bearer ${TOKEN}`);
    assert.equal(s.body, null);
  }
  assert.equal(result.isError, undefined);
  const sc = result.structuredContent;
  assert.equal(sc.project, 'acme-os');
  assert.deepEqual(sc.board, { open: 3 });
  assert.equal(sc.spend_ceiling.project, 'acme-os');
  assert.equal(sc.spend_ceiling.ceiling_usd, 5000);
  assert.equal(sc.spend_ceiling.spent_usd_today, 4100.5);
  assert.equal(sc.spend_ceiling.pct, 82);
  assert.equal(sc.spend_ceiling.state, 'warn');
  assert.equal(sc.spend_ceiling.as_of, '2026-10-21T19:00:00Z');
  assert.equal(JSON.parse(result.content[0].text).spend_ceiling.ceiling_usd, 5000);
  assert.ok(!result.content[0].text.includes(TOKEN));
});

test('M2 no ceiling row: state none, still the dash answer', async () => {
  const { result } = await call('nocap');
  assert.equal(result.isError, undefined);
  assert.equal(result.structuredContent.spend_ceiling.ceiling_usd, null);
  assert.equal(result.structuredContent.spend_ceiling.state, 'none');
});

test('M2b a failed spend read is unknown, never 0', async () => {
  const { result } = await call('down');
  assert.equal(result.isError, undefined);
  const sc = result.structuredContent.spend_ceiling;
  assert.equal(sc.ceiling_usd, 50);
  assert.equal(sc.spent_usd_today, null);
  assert.equal(sc.state, 'unknown');
  assert.ok(sc.error);
});

test('M4 the project is encoded in every path', async () => {
  const { sent } = await call('a/b c');
  assert.deepEqual(sent.map((s) => s.path).sort(), ['/api/dash/p/a%2Fb%20c',
    '/api/coord/settings/conf.cost-caps.a%2Fb%20c.daily_usd', '/api/coord/metrics/llm-spend?project=a%2Fb+c', WARN].sort());
});

test('M5 the warn row moves the warn point', async () => {
  ROUTES[WARN] = { json: { key: 'conf.cost-caps.daily_warn_pct', setting: { value: '90' } } };
  try {
    const { result } = await call('acme-os');
    assert.equal(result.structuredContent.spend_ceiling.pct, 82);
    assert.equal(result.structuredContent.spend_ceiling.state, 'under');
  } finally { delete ROUTES[WARN]; }
});

test('M3 a dash 404 is the same error as before', async () => {
  const { result } = await call('gone');
  assert.equal(result.isError, true);
  assert.equal(result.content[0].text, 'console route not available: /api/dash/p/gone');
});
