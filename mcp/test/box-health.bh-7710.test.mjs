// The box_health and box_restart tools in mcp/tools/box-health.mjs. Every case
// goes through the REAL registry (loadTools + callTool) and the REAL
// consoleFetch against the stub console. globalThis.fetch and
// node:child_process are wrapped with recorders BEFORE the tools load, so
// "0 network calls off the stub" and "no ssh from here" are measured.
//   M1 the fixture: one reachable box, one hung box
//   M2 the decision rule, D1-D16     M3 the box filter, one GET per call
//   M4 and M10 nothing secret in an answer
//   M5-M9 box_restart refusals and the one POST     M11 mutation pins
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createRequire, syncBuiltinESMExports } from 'node:module';
import { cpSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

// ---- recorders, installed before any tool module is imported ----
const fetched = [];
const realFetch = globalThis.fetch;
let stubOrigin = null;
globalThis.fetch = (input, init) => {
  const url = String(input instanceof Request ? input.url : input);
  fetched.push(url);
  if (!stubOrigin || !url.startsWith(stubOrigin + '/')) return Promise.reject(new Error(`blocked off-stub fetch: ${url}`));
  return realFetch(input, init);
};
const spawned = [];
const cp = createRequire(import.meta.url)('node:child_process');
for (const fn of ['spawn', 'exec', 'execFile', 'execSync', 'execFileSync', 'spawnSync', 'fork']) {
  cp[fn] = (...a) => { spawned.push(`${fn} ${String(a[0])}`); throw new Error(`child_process.${fn} blocked`); };
}
syncBuiltinESMExports();

const { loadTools, callTool } = await import('../lib/tools.mjs');
const { startStub } = await import('./lib/stub-console.mjs');

const HERE = dirname(fileURLToPath(import.meta.url));
const MCP_DIR = join(HERE, '..');
const FIXTURE = JSON.parse(readFileSync(join(HERE, 'fixtures/box-health.bh-7710.json'), 'utf8'));
const clone = (v) => JSON.parse(JSON.stringify(v));
const TOKEN = 'tok-fixture-box-health';
const PLANTED = 'key-fixture-zz';
const HEALTH = '/api/coord/box-health';
const COMMANDS = '/api/coord/box-commands';
const AS_OF = Date.parse(FIXTURE.as_of);
const ago = (s) => new Date(AS_OF - s * 1000).toISOString().replace(/\.\d{3}Z$/, 'Z');
const QUEUED = { status: 201, json: { id: 77, status: 'requested', deduped: false, command: { id: 77 }, token: TOKEN } };

const registry = await loadTools(new URL('../tools/', import.meta.url));

// The fixture with watcher-bravo replaced by `bravo(entry)`, and the top level
// patched by `top`.
function answer(bravo = (b) => b, top = {}) {
  const a = clone(FIXTURE);
  a.boxes[1] = bravo(a.boxes[1]);
  return { ...a, ...top };
}

async function withStub(t, health = answer(), extra = {}, reg = registry) {
  const routes = { [HEALTH]: { json: health }, [COMMANDS]: QUEUED, ...extra };
  const stub = await startStub({ routes });
  stubOrigin = stub.url;
  t.after(() => stub.close());
  const ctx = { cfg: { url: stub.url, token: TOKEN, secret: null } };
  const call = (name, args) => callTool(reg, name, args, ctx);
  const posts = () => stub.requests.filter((q) => q.method === 'POST');
  return { stub, ctx, call, posts };
}
const out = (r) => {
  assert.notEqual(r.isError, true, r.content?.[0]?.text);
  assert.deepEqual(JSON.parse(r.content[0].text), r.structuredContent);
  return r.structuredContent;
};
const refused = (r, code) => {
  assert.equal(r.isError, true, JSON.stringify(r));
  assert.equal(r.content[0].text, code);
};
const stateOf = async (t, bravo, top) => {
  const { call } = await withStub(t, answer(bravo, top));
  return out(await call('box_health', { box: 'watcher-bravo' })).boxes[0];
};
const live = (status = 'running') => [{ id: 'vm-b1', status, seen_at: ago(180), account: 'acct-fixture' }];
const ssh = (rc, probedS, okS) => ({ rc, probed_at: ago(probedS), last_ok_at: okS === null ? null : ago(okS) });

test('M0 the registry lists box_health (read) and box_restart (guarded), closed schemas', () => {
  const h = registry.get('box_health');
  const r = registry.get('box_restart');
  assert.equal(h?.kind, 'read');
  assert.equal(r?.kind, 'guarded');
  for (const x of [h, r]) assert.equal(x.inputSchema.additionalProperties, false, x.name);
  assert.deepEqual(r.inputSchema.required, ['box', 'confirm']);
  assert.equal('confirm' in h.inputSchema.properties, false, 'box_health takes no confirm, so the leak sweep calls it');
});

test('M1 the fixture: the reachable box is ok, the hung box (ssh rc 255, VM running) is hung', async (t) => {
  const { call, stub } = await withStub(t);
  const o = out(await call('box_health', {}));
  assert.deepEqual(stub.requests.map((q) => `${q.method} ${q.path}`), [`GET ${HEALTH}`]);
  assert.deepEqual(o.hung, ['watcher-bravo']);
  const by = Object.fromEntries(o.boxes.map((b) => [b.box, b]));
  assert.equal(by['watcher-alpha'].state, 'ok');
  assert.equal(by['watcher-alpha'].ssh.reachable, true);
  const b = by['watcher-bravo'];
  assert.equal(b.state, 'hung');
  assert.equal(b.ssh.reachable, false);
  assert.equal(b.ssh.last_rc, 255);
  assert.equal(b.ssh.probe_stale, false);
  assert.equal(b.ssh.last_ok_at, '2026-10-20T04:21:00Z');
  assert.equal(b.lane_ssh_failures.count, 4);
  assert.equal(b.lane_ssh_failures.window_s, 900);
  assert.equal(b.vm.hosted, true);
  assert.equal(b.vm.status, 'running');
  assert.equal(b.heartbeat.last_beat_at, '2026-10-20T04:21:00Z');
  assert.equal(b.heartbeat.age_s, 9 * 3600 + 9 * 60);
  assert.equal(by['watcher-hub'].vm.hosted, false);
  assert.deepEqual(o.boxes.map((x) => x.box), ['watcher-alpha', 'watcher-bravo', 'watcher-hub']);
  assert.equal(o.as_of, FIXTURE.as_of);
  assert.equal(fetched.every((u) => u.startsWith(stubOrigin)), true);
  assert.deepEqual(spawned, []);
});

// [case, bravo patch, top patch, expected state]
const RULE = [
  ['D1 rc 0 fresh', (b) => ({ ...b, ssh: ssh(0, 60, 60) }), {}, 'ok'],
  ['D2 rc 255 fresh, last ok 9 h ago, running', (b) => ({ ...b, ssh: ssh(255, 60, 9 * 3600) }), {}, 'hung'],
  ['D3 rc 255 fresh, never ok, running', (b) => ({ ...b, ssh: ssh(255, 60, null) }), {}, 'hung'],
  ['D4 rc 124 (timeout) fresh, running', (b) => ({ ...b, ssh: ssh(124, 60, 3600) }), {}, 'hung'],
  ['D5 rc 255 fresh, ok 2 min ago', (b) => ({ ...b, ssh: ssh(255, 60, 120) }), {}, 'unreachable'],
  ['D6 rc 255 fresh, VM stopped', (b) => ({ ...b, ssh: ssh(255, 60, 3600), vm: { live: live('stopped'), gone: 0 } }), {}, 'unreachable'],
  ['D7 rc 255 fresh, no VM row', (b) => ({ ...b, ssh: ssh(255, 60, 3600), vm: { live: [], gone: 0 }, restart: null }), {}, 'unreachable'],
  ['D8 rc 0 probed 30 min ago', (b) => ({ ...b, ssh: ssh(0, 1800, 1800) }), {}, 'unknown'],
  ['D9 no ssh row', (b) => ({ ...b, ssh: null, lane_ssh_failures: null }), {}, 'unknown'],
  ['D10 the ssh read failed', (b) => ({ ...b, ssh: null, lane_ssh_failures: null }), { partial: ['ssh'] }, 'unknown'],
  ['D11 the VM read failed', (b) => ({ ...b, vm: null, restart: null }), { partial: ['vm'], vm_complete: null }, 'unknown'],
  ['D12 two live VMs', (b) => ({ ...b, vm: { live: [...live(), { ...live()[0], id: 'vm-b2' }], gone: 0 }, restart: null }), {}, 'unknown'],
  ['D13 the VM row is gone', (b) => ({ ...b, vm: { live: [], gone: 1 }, restart: null }), {}, 'unreachable'],
  ['D14 incomplete account read, no row', (b) => ({ ...b, vm: { live: [], gone: 0 }, restart: null }), { vm_complete: false }, 'unknown'],
];

test('M2 the decision rule, one case per row', async (t) => {
  for (const [name, bravo, top, want] of RULE) {
    const b = await stateOf(t, bravo, top);
    assert.equal(b.state, want, name);
  }
  const d10 = await stateOf(t, RULE[9][1], RULE[9][2]);
  assert.equal(d10.ssh.reachable, null, 'a failed read is null, never false');
  const d11 = await stateOf(t, RULE[10][1], RULE[10][2]);
  assert.equal(d11.vm.hosted, null);
  const d12 = await stateOf(t, RULE[11][1], RULE[11][2]);
  assert.equal(d12.vm.hosted, null);
  assert.equal(d12.vm.ambiguous, 2);
  const d13 = await stateOf(t, RULE[12][1], RULE[12][2]);
  assert.equal(d13.vm.hosted, false);
  const d14 = await stateOf(t, RULE[13][1], RULE[13][2]);
  assert.equal(d14.vm.hosted, null);
  const d8 = await stateOf(t, RULE[7][1], RULE[7][2]);
  assert.equal(d8.ssh.probe_stale, true);
  assert.equal(d8.ssh.reachable, false);
});

test('M2b D10 with the route missing (404): box_health says so, box_restart sends no POST', async (t) => {
  const { call, posts } = await withStub(t, answer(), { [HEALTH]: { status: 404, json: { error: 'not_found' } } });
  refused(await call('box_health', {}), `console route not available: ${HEALTH}`);
  refused(await call('box_restart', { box: 'watcher-bravo', confirm: true }), `registry_unavailable: console route not available: ${HEALTH}`);
  assert.equal(posts().length, 0);
});

test('M3 the box filter: case and space folded, box id accepted, unknown refused, one GET per call', async (t) => {
  const { call, stub } = await withStub(t);
  for (const box of ['WATCHER-BRAVO ', 'bravo', ' Bravo']) {
    const o = out(await call('box_health', { box }));
    assert.deepEqual(o.boxes.map((b) => b.box), ['watcher-bravo'], box);
  }
  refused(await call('box_health', { box: 'nope' }), 'unknown_box');
  assert.equal(stub.requests.length, 4);
  assert.ok(stub.requests.every((q) => q.method === 'GET' && q.path === HEALTH));
  refused(await call('box_health', { box: 'x'.repeat(65) }), 'invalid_arguments: box');
  refused(await call('box_health', { other: 1 }), 'invalid_arguments: other');
  assert.equal(stub.requests.length, 4, 'a bad argument sends nothing');
});

test('M3b an echo payload with no boxes list is a bad payload, never an empty fleet', async (t) => {
  const { call } = await withStub(t, { ok: true, path: HEALTH, authorization: `Bearer ${TOKEN}` });
  refused(await call('box_health', {}), `bad_payload: ${HEALTH}`);
});

test('M4 a planted key and the console token never reach box_health output', async (t) => {
  const health = answer((b) => ({ ...b, role: TOKEN }), { note: TOKEN });
  const { call } = await withStub(t, health);
  const r = await call('box_health', {});
  const text = JSON.stringify(r);
  assert.equal(text.includes(PLANTED), false, text);
  assert.equal(text.includes(TOKEN), false, text);
  assert.ok(text.includes('[redacted]'), 'positive control: the token sat in a shown field and was scrubbed');
});

test('M5 box_restart without confirm true sends 0 requests', async (t) => {
  const { call, stub } = await withStub(t);
  for (const extra of [{}, { confirm: 'true' }, { confirm: 1 }, { confirm: false }]) {
    refused(await call('box_restart', { box: 'watcher-bravo', ...extra }), 'confirm_required');
  }
  refused(await call('box_restart', { box: 'watcher-bravo', confirm: true, force: 'yes' }), 'invalid_arguments: force');
  assert.equal(stub.requests.length, 0);
});

test('M6 a box that answered ssh 1 min ago is refused; with force it queues one POST', async (t) => {
  const { call, posts, stub } = await withStub(t);
  refused(await call('box_restart', { box: 'watcher-alpha', confirm: true }), 'box_answered_ssh: 60s ago');
  assert.equal(posts().length, 0);
  assert.equal(stub.requests.length, 1, 'one GET, no POST');
  const o = out(await call('box_restart', { box: 'watcher-alpha', confirm: true, force: true }));
  assert.equal(o.queued, true);
  assert.equal(o.forced, true);
  const p = posts();
  assert.equal(p.length, 1);
  assert.equal(p[0].path, COMMANDS);
  assert.equal(p[0].body.box, 'hub');
  assert.equal(p[0].body.type, 'vm_restart');
  assert.equal(p[0].body.target, 'alpha');
  assert.equal(p[0].body.confirm, true);
});

test('M6b D5: rc 255 now but an answer 2 min ago is refused without force', async (t) => {
  const { call, posts } = await withStub(t, answer(RULE[4][1]));
  refused(await call('box_restart', { box: 'watcher-bravo', confirm: true }), 'box_answered_ssh: 120s ago');
  assert.equal(posts().length, 0);
});

test('M7 the hung box: one POST with the template, the account and a reason; queued with the id', async (t) => {
  const { call, posts } = await withStub(t);
  const o = out(await call('box_restart', { box: 'watcher-bravo', confirm: true }));
  const p = posts();
  assert.equal(p.length, 1);
  assert.deepEqual(
    { box: p[0].body.box, type: p[0].body.type, target: p[0].body.target, account: p[0].body.account, confirm: p[0].body.confirm },
    { box: 'hub', type: 'vm_restart', target: 'bravo', account: 'acct-fixture', confirm: true });
  assert.equal(p[0].body.reason, 'box_restart (mcp): ssh rc 255, last answer 2026-10-20T04:21:00Z');
  assert.equal(o.queued, true);
  assert.equal(o.id, 77);
  assert.equal(o.status, 'requested');
  assert.equal(o.deduped, false);
  assert.equal(o.box, 'watcher-bravo');
  assert.equal(o.box_id, 'bravo');
  assert.equal(o.forced, false);
  const own = out(await call('box_restart', { box: 'watcher-bravo', confirm: true, reason: 'operator: hung since 04:21' }));
  assert.equal(own.queued, true);
  assert.equal(posts()[1].body.reason, 'operator: hung since 04:21');
});

test('M8 not VM-hosted, or the VM state unknown: refused even with force, 0 POSTs', async (t) => {
  const cases = [
    ['D7', RULE[6][1], {}, 'watcher-bravo', 'not_vm_hosted'],
    ['D13', RULE[12][1], {}, 'watcher-bravo', 'not_vm_hosted'],
    ['D16', (b) => b, {}, 'hub', 'not_vm_hosted'],
    // A template next to facts that refuse it: the facts win.
    ['D7 with a template', (b) => ({ ...b, ssh: ssh(255, 60, 3600), vm: { live: [], gone: 0 } }), {}, 'watcher-bravo', 'not_vm_hosted'],
    ['D16 with a template', (b) => b, { boxes: [FIXTURE.boxes[0], FIXTURE.boxes[1], { ...FIXTURE.boxes[2], vm: { live: live(), gone: 0 }, restart: { box: 'hub', type: 'vm_restart', target: 'hub' } }] }, 'hub', 'not_vm_hosted'],
    ['D11', RULE[10][1], RULE[10][2], 'watcher-bravo', 'vm_state_unknown'],
    ['D14', RULE[13][1], RULE[13][2], 'watcher-bravo', 'vm_state_unknown'],
    ['D12', RULE[11][1], RULE[11][2], 'watcher-bravo', 'vm_ambiguous'],
    ['bad template', (b) => ({ ...b, restart: { ...b.restart, box: 'watcher-bravo' } }), {}, 'watcher-bravo', 'bad_payload: restart'],
    ['unknown', (b) => b, {}, 'nope', 'unknown_box'],
  ];
  for (const [name, bravo, top, box, code] of cases) {
    const { call, posts } = await withStub(t, answer(bravo, top));
    refused(await call('box_restart', { box, confirm: true, force: true }), code);
    assert.equal(posts().length, 0, name);
  }
});

test('M8b the ssh state unknown or stale: refused without force, queued with it', async (t) => {
  const cases = [
    ['D8', RULE[7][1], {}, 'ssh_state_stale'],
    ['D9', RULE[8][1], {}, 'ssh_state_unknown'],
    ['D10', RULE[9][1], RULE[9][2], 'ssh_state_unknown'],
  ];
  for (const [name, bravo, top, code] of cases) {
    const { call, posts } = await withStub(t, answer(bravo, top));
    refused(await call('box_restart', { box: 'watcher-bravo', confirm: true }), code);
    assert.equal(posts().length, 0, name);
    const o = out(await call('box_restart', { box: 'watcher-bravo', confirm: true, force: true }));
    assert.equal(o.queued, true, name);
    assert.equal(posts().length, 1, name);
  }
});

test('M9 the worker refuses (403 owner_only): one POST, no retry, the reason shown', async (t) => {
  const { call, posts } = await withStub(t, answer(), { [COMMANDS]: { status: 403, json: { error: 'owner_only' } } });
  refused(await call('box_restart', { box: 'watcher-bravo', confirm: true }), 'http_403: owner_only');
  assert.equal(posts().length, 1);
});

test('M9b a 2xx with no id is not queued', async (t) => {
  const { call } = await withStub(t, answer(), { [COMMANDS]: { status: 200, json: { ok: true } } });
  refused(await call('box_restart', { box: 'watcher-bravo', confirm: true }), `bad_payload: ${COMMANDS}`);
});

test('M10 box_restart answers carry no planted key and no token', async (t) => {
  const { call } = await withStub(t, answer((b) => ({ ...b, vm: { live: [{ ...live()[0], api_key: PLANTED }], gone: 0 } })));
  const texts = [];
  for (const args of [{ box: 'watcher-bravo', confirm: true }, { box: 'watcher-alpha', confirm: true }, { box: 'watcher-bravo' }]) {
    texts.push(JSON.stringify(await call('box_restart', args)));
  }
  for (const s of texts) {
    assert.equal(s.includes(PLANTED), false, s);
    assert.equal(s.includes(TOKEN), false, s);
  }
});

// A copy of mcp/ with one source edit in tools/box-health.mjs; the anchor
// must be found exactly once.
async function mutatedRegistry(t, anchor, replacement) {
  const dir = mkdtempSync(join(tmpdir(), 'mcp-box-health-mut-'));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  cpSync(MCP_DIR, dir, { recursive: true });
  const path = join(dir, 'tools', 'box-health.mjs');
  const src = readFileSync(path, 'utf8');
  assert.equal(src.split(anchor).length, 2, `mutation anchor not found exactly once: ${anchor}`);
  writeFileSync(path, src.replace(anchor, replacement));
  return loadTools(join(dir, 'tools'));
}

test('M11 mutation pins: the confirm guard and the 300 s window are what refuse', async (t) => {
  // The handler alone (no precheck) sends requests: the precheck is the guard.
  const { ctx, stub } = await withStub(t);
  await registry.get('box_restart').handler({ box: 'watcher-bravo' }, ctx);
  assert.ok(stub.requests.length > 0, 'without the precheck the call goes out');

  const noConfirm = await mutatedRegistry(t, "if (args.confirm !== true) return 'confirm_required';", '');
  const a = await withStub(t, answer(), {}, noConfirm);
  // confirm:false passes the schema check (a boolean), so only the guard stops it.
  await a.call('box_restart', { box: 'watcher-bravo', confirm: false });
  assert.ok(a.stub.requests.length > 0, 'with the confirm line removed, requests are sent');

  const noWindow = await mutatedRegistry(t, 'if (okAge !== null && okAge <= ANSWERED_S)', 'if (false)');
  const b = await withStub(t, answer(), {}, noWindow);
  await b.call('box_restart', { box: 'watcher-alpha', confirm: true });
  assert.equal(b.posts().length, 1, 'with the 300 s check removed, a reachable box is restarted');
});
