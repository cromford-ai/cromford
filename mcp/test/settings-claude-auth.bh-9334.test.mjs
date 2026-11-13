// BH-9334 C0: the MCP settings tool knows claude_auth.<project> and
// runner_lock.<project>. setting_get shows their knob entry (an enum, its
// values, its default); setting_set refuses them as not_settable with the
// bin/protected-setting.sh pointer before any PUT, because the worker wants the
// human verdict token for both and the proxy cannot send it. Real tool registry
// (loadTools + callTool), ctx.consoleFetch as a recorder; no network.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

globalThis.fetch = (input) => Promise.reject(new Error(`blocked fetch: ${String(input)}`));
const { loadTools, callTool } = await import('../lib/tools.mjs');

const HERE = dirname(fileURLToPath(import.meta.url));
const MCP_DIR = join(HERE, '..');
const REGISTRY = JSON.parse(readFileSync(join(HERE, 'fixtures/lanes-registry.bh-7712.json'), 'utf8'));
const clone = (v) => JSON.parse(JSON.stringify(v));
const ROWS = '/api/coord/settings';
const REG = '/api/coord/lanes/registry';
const row = (key) => `${ROWS}/${encodeURIComponent(key)}`;
const NOTE = 'move this project to its own API key; roll back by setting it to oauth';
const ok = (data) => ({ ok: true, status: 200, data });
const one = (key, r) => ok({ key, setting: r, source: r ? 'settings' : 'none', as_of: '2026-11-13T00:00:00Z' });

const registry = await loadTools(join(MCP_DIR, 'tools'));
const CFG = { url: 'http://console.invalid', token: 'tok-fixture-settings', secret: null, allowlist: [] };

async function call(name, args, key, r = null) {
  const sent = [];
  const routes = { [`GET ${row(key)}`]: one(key, r), [`GET ${REG}`]: ok(clone(REGISTRY)) };
  const fn = async (cfg, method, path, body) => {
    sent.push({ method, path, body });
    if (method === 'PUT') return ok({ setting: { key, value: body.value } });
    return routes[`${method} ${path}`] ?? { ok: false, status: 404, error: 'http_404' };
  };
  const out = await callTool(registry, name, args, { cfg: CFG, consoleFetch: fn, log: () => {} });
  return { out, puts: sent.filter((s) => s.method === 'PUT') };
}
const knobOf = (res) => { assert.notEqual(res.out.isError, true, JSON.stringify(res.out)); return res.out.structuredContent.knob; };

test('M1 setting_get claude_auth.<p> returns the enum knob, not settable', async () => {
  const k = knobOf(await call('setting_get', { key: 'claude_auth.proj-a' }, 'claude_auth.proj-a'));
  assert.ok(k, 'knob must resolve');
  assert.equal(k.type, 'enum');
  assert.deepEqual(k.values, ['oauth', 'api-key']);
  assert.equal(k.default, 'oauth');
  assert.equal(k.settable, false);
  assert.equal(k.project_scoped, true);
  assert.equal(k.owner, 'claude_auth');
  assert.match(k.note, /bin\/protected-setting\.sh/);
});

test('M2 setting_set claude_auth.<p>=api-key is not_settable with the pointer, no PUT', async () => {
  const r = await call('setting_set', { key: 'claude_auth.proj-a', value: 'api-key', note: NOTE, confirm: true }, 'claude_auth.proj-a');
  assert.equal(r.out.isError, true, JSON.stringify(r.out));
  assert.match(r.out.content[0].text, /^not_settable: claude_auth/);
  assert.match(r.out.content[0].text, /bin\/protected-setting\.sh/);
  assert.equal(r.puts.length, 0);
});

test('M3 runner_lock.<p> resolves with values [claude] and no default', async () => {
  const k = knobOf(await call('setting_get', { key: 'runner_lock.proj-a' }, 'runner_lock.proj-a'));
  assert.ok(k, 'knob must resolve');
  assert.deepEqual(k.values, ['claude']);
  assert.equal(k.default, null);
  assert.equal(k.settable, false);
  assert.ok(k.zero_means);
});

test('M4 setting_set runner_lock.<p>=codex with force sends no PUT', async () => {
  const r = await call('setting_set', { key: 'runner_lock.proj-a', value: 'codex', note: NOTE, confirm: true, force: true }, 'runner_lock.proj-a');
  assert.equal(r.out.isError, true, JSON.stringify(r.out));
  assert.match(r.out.content[0].text, /^not_settable/);
  assert.equal(r.puts.length, 0);
});

test('M5 a lane knob still resolves as before', async () => {
  const key = 'lane.fly-pool-tick.pool_tick_max_parallel';
  const k = knobOf(await call('setting_get', { key }, key));
  assert.equal(k.kind, 'lane');
  assert.equal(k.env, 'POOL_TICK_MAX_PARALLEL');
  assert.equal('values' in k, false);
});

test('M6 a three-part claude_auth.a.b does not resolve to the knob', async () => {
  const k = knobOf(await call('setting_get', { key: 'claude_auth.a.b' }, 'claude_auth.a.b'));
  assert.equal(k, null);
});
