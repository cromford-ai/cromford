// BH-7712: the settings MCP tools in mcp/tools/settings.mjs (setting_get,
// setting_set). Every case loads the REAL registry (loadTools + callTool). Most
// inject ctx.consoleFetch as a recorder with fixture answers; A11 runs the real
// `node mcp/server.mjs` against the stub console. globalThis.fetch is wrapped
// before any tool loads and refuses every URL off a stub, so "0 network calls"
// is measured, not read off the source.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { createInterface } from 'node:readline';
import { cpSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

// ---- the fetch recorder, installed before any tool module is imported ----
const fetched = [];
const realFetch = globalThis.fetch;
const stubOrigins = new Set();
globalThis.fetch = (input, init) => {
  const url = String(input instanceof Request ? input.url : input);
  fetched.push(url);
  if (![...stubOrigins].some((o) => url.startsWith(o + '/'))) return Promise.reject(new Error(`blocked off-stub fetch: ${url}`));
  return realFetch(input, init);
};

const { loadTools, callTool } = await import('../lib/tools.mjs');
const { startStub } = await import('./lib/stub-console.mjs');

const HERE = dirname(fileURLToPath(import.meta.url));
const MCP_DIR = join(HERE, '..');
const SERVER = join(MCP_DIR, 'server.mjs');
const REGISTRY = JSON.parse(readFileSync(join(HERE, 'fixtures/lanes-registry.bh-7712.json'), 'utf8'));
const clone = (v) => JSON.parse(JSON.stringify(v));

const ROWS = '/api/coord/settings';
const REG = '/api/coord/lanes/registry';
const row = (key) => `${ROWS}/${encodeURIComponent(key)}`;

const KEY = 'lane.fly-pool-tick.pool_tick_max_parallel';
const NOTE = 'drain the backlog faster; roll back by setting it to 0';
const ROW_12 = { key: KEY, value: '12', note: 'old note', actor: 'ops@example.test', updated_at: '2026-10-20T10:00:00Z' };

const ok = (data) => ({ ok: true, status: 200, data });
const one = (key, r) => ok({ key, setting: r, source: r ? 'settings' : 'none', as_of: '2026-10-20T15:00:00Z' });

// A consoleFetch stand-in: answers from `routes` keyed by "<METHOD> <path>",
// and records every request it was asked to send.
function recorder(routes = {}) {
  const sent = [];
  const fn = async (cfg, method, path, body) => {
    sent.push({ method, path, body });
    const r = routes[`${method} ${path}`];
    if (r === undefined) return { ok: false, status: 404, error: 'http_404' };
    return typeof r === 'function' ? r(body) : r;
  };
  return { sent, fn };
}

const registry = await loadTools(join(MCP_DIR, 'tools'));
const CFG = { url: 'http://console.invalid', token: 'tok-fixture-settings', secret: null, allowlist: [] };

async function call(name, args, routes, reg = registry) {
  const rec = recorder(routes);
  const r = await callTool(reg, name, args, { cfg: CFG, consoleFetch: rec.fn, log: () => {} });
  return { r, sent: rec.sent, gets: rec.sent.filter((s) => s.method === 'GET'), puts: rec.sent.filter((s) => s.method === 'PUT') };
}

const baseRoutes = (extra = {}) => ({
  [`GET ${row(KEY)}`]: one(KEY, ROW_12),
  [`GET ${REG}`]: ok(clone(REGISTRY)),
  ...extra,
});

function refused(out, code, { requests } = {}) {
  assert.equal(out.r.isError, true, JSON.stringify(out.r));
  assert.ok(out.r.content[0].text.startsWith(code), `${out.r.content[0].text} should start with ${code}`);
  assert.equal(out.puts.length, 0, 'a refusal never sends the PUT');
  if (requests !== undefined) assert.equal(out.sent.length, requests, JSON.stringify(out.sent));
}

const answer = (out) => {
  assert.notEqual(out.r.isError, true, JSON.stringify(out.r));
  return out.r.structuredContent;
};

const setArgs = (extra = {}) => ({ key: KEY, value: 12, note: NOTE, confirm: true, ...extra });

// ---- A1: the registry ----

test('A1 get/set: loadTools lists setting_get (read) and setting_set (write, confirm required), both schemas closed', () => {
  const g = registry.get('setting_get');
  const s = registry.get('setting_set');
  assert.ok(g && s);
  assert.equal(g.kind, 'read');
  assert.equal('confirm' in g.inputSchema.properties, false);
  assert.equal(s.kind, 'write');
  assert.ok(s.inputSchema.required.includes('confirm'));
  assert.ok(s.inputSchema.required.includes('note'));
  for (const t of [g, s]) assert.equal(t.inputSchema.additionalProperties, false, t.name);
});

// ---- A2/A2b/A3: setting_get ----

test('A2 get by key: row value, note, actor, updated_at and the knob entry, from 2 GETs', async () => {
  const out = await call('setting_get', { key: KEY }, baseRoutes());
  const a = answer(out);
  assert.equal(a.key, KEY);
  assert.equal(a.value, '12');
  assert.equal(a.note, 'old note');
  assert.equal(a.actor, 'ops@example.test');
  assert.equal(a.updated_at, '2026-10-20T10:00:00Z');
  assert.equal(a.source, 'settings');
  assert.deepEqual(a.knob, {
    owner: 'fly-pool-tick', kind: 'lane', env: 'POOL_TICK_MAX_PARALLEL', type: 'int', default: 0, min: 0, max: 256,
    unit: 'builds', zero_means: 'no cap', note: 'How many pool builds one tick may start. 0 = no cap.',
    settable: true, project_scoped: false,
  });
  assert.deepEqual(out.sent.map((s) => `${s.method} ${s.path}`).sort(), [`GET ${REG}`, `GET ${row(KEY)}`].sort());
});

test('A2 get reads the row and the registry in parallel', async () => {
  let inflight = 0;
  let peak = 0;
  const slow = (v) => async () => { inflight++; peak = Math.max(peak, inflight); await new Promise((r) => setTimeout(r, 20)); inflight--; return v; };
  const out = await call('setting_get', { key: KEY }, { [`GET ${row(KEY)}`]: slow(one(KEY, ROW_12)), [`GET ${REG}`]: slow(ok(clone(REGISTRY))) });
  answer(out);
  assert.equal(peak, 2, 'both reads were in flight at once');
});

test('A2b get on a key with no row: value null, source none, the knob default still shown', async () => {
  const k = 'lane.lane-reaper.widgets.lane_reap_deadline_secs';
  const a = answer(await call('setting_get', { key: k }, { [`GET ${row(k)}`]: one(k, null), [`GET ${REG}`]: ok(clone(REGISTRY)) }));
  assert.equal(a.value, null);
  assert.equal(a.source, 'none');
  assert.equal(a.knob.default, 3600);
  assert.equal(a.knob.project_scoped, true);
});

test('A2b get with the registry read failing: the row shows, knob null, partial names the route', async () => {
  const a = answer(await call('setting_get', { key: KEY }, baseRoutes({ [`GET ${REG}`]: { ok: false, status: 500, error: 'http_500' } })));
  assert.equal(a.value, '12');
  assert.equal(a.knob, null);
  assert.deepEqual(a.partial, [REG]);
});

test('A2b get with the row read failing: the tool fails with that error', async () => {
  const out = await call('setting_get', { key: KEY }, baseRoutes({ [`GET ${row(KEY)}`]: { ok: false, status: 503, error: 'http_503' } }));
  assert.equal(out.r.isError, true);
  assert.equal(out.r.content[0].text, 'http_503');
});

test('A3 get by prefix: only matching rows, sorted, each with its knob', async () => {
  const settings = [
    { key: 'lib.token-health.token_health_warn_h', value: '24', note: null, actor: 'a', updated_at: 't1' },
    { key: KEY, value: '12', note: 'n', actor: 'a', updated_at: 't2' },
    { key: 'lane.fly-pool-tick.pool_tick_cmd', value: 'x', note: null, actor: 'a', updated_at: 't3' },
    { key: 'hub_load.shed', value: 'off', note: null, actor: 'a', updated_at: 't4' },
  ];
  const out = await call('setting_get', { prefix: 'lane.fly-pool-tick.' }, { [`GET ${ROWS}`]: ok({ settings, as_of: 'T' }), [`GET ${REG}`]: ok(clone(REGISTRY)) });
  const a = answer(out);
  assert.equal(a.prefix, 'lane.fly-pool-tick.');
  assert.deepEqual(a.rows.map((r) => r.key), ['lane.fly-pool-tick.pool_tick_cmd', KEY]);
  assert.equal(a.rows[1].knob.max, 256);
  assert.equal(a.rows[0].knob.settable, false);
  assert.equal(a.total, 2);
  assert.equal(a.truncated, false);
  assert.equal(out.sent.length, 2);
});

test('A3 get by prefix caps at 100 rows and says so: total 150, truncated', async () => {
  const settings = Array.from({ length: 150 }, (_, i) => ({ key: `lane.x.k${String(149 - i).padStart(3, '0')}`, value: '1', note: null, actor: 'a', updated_at: 't' }));
  const a = answer(await call('setting_get', { prefix: 'lane.' }, { [`GET ${ROWS}`]: ok({ settings }), [`GET ${REG}`]: ok(clone(REGISTRY)) }));
  assert.equal(a.rows.length, 100);
  assert.equal(a.total, 150);
  assert.equal(a.truncated, true);
  assert.equal(a.rows[0].key, 'lane.x.k000');
});

test('A3 get with no argument lists every row; a body with no settings array is bad_payload', async () => {
  const a = answer(await call('setting_get', {}, { [`GET ${ROWS}`]: ok({ settings: [ROW_12] }), [`GET ${REG}`]: ok(clone(REGISTRY)) }));
  assert.equal(a.prefix, null);
  assert.equal(a.total, 1);
  const bad = await call('setting_get', {}, { [`GET ${ROWS}`]: ok({ nope: 1 }), [`GET ${REG}`]: ok(clone(REGISTRY)) });
  assert.equal(bad.r.isError, true);
  assert.equal(bad.r.content[0].text, `bad_payload: ${ROWS}`);
});

test('A3 get with key and prefix, or a bad key, sends 0 requests', async () => {
  refused(await call('setting_get', { key: KEY, prefix: 'lane.' }, baseRoutes()), 'key_or_prefix_not_both', { requests: 0 });
  refused(await call('setting_get', { key: 'LANE.FLY-POOL-TICK.POOL_TICK_MAX_PARALLEL' }, baseRoutes()), 'invalid_arguments: key', { requests: 0 });
  refused(await call('setting_get', { prefix: 'a b' }, baseRoutes()), 'invalid_arguments: prefix', { requests: 0 });
  refused(await call('setting_get', { key: 'x'.repeat(65) }, baseRoutes()), 'invalid_arguments: key', { requests: 0 });
});

// ---- A4-A8: setting_set ----

test('A4 set without confirm true (absent, "true", 1, false): confirm_required, 0 requests', async () => {
  for (const c of [undefined, 'true', 1, false]) {
    const args = setArgs({ confirm: c });
    if (c === undefined) delete args.confirm;
    refused(await call('setting_set', args, baseRoutes()), 'confirm_required', { requests: 0 });
  }
});

test('A5 set above the registry max (257 > 256) or below min (-1 < 0): value_out_of_range, GETs only', async () => {
  for (const v of [257, '257', -1, '-1']) {
    const out = await call('setting_set', setArgs({ value: v }), baseRoutes());
    refused(out, 'value_out_of_range');
    assert.equal(out.gets.length, 2);
  }
});

test('A5b set on an int knob: "1.5", "12abc", 1.5 refuse; "", true, null, {} refuse with 0 requests; "12" and 12 go through', async () => {
  for (const v of ['1.5', '12abc', 1.5, ' 12 x']) {
    const out = await call('setting_set', setArgs({ value: v }), baseRoutes());
    refused(out, 'value_type');
  }
  for (const v of ['', '   ', true, null, {}, Number.NaN]) {
    refused(await call('setting_set', setArgs({ value: v }), baseRoutes()), 'invalid_arguments: value', { requests: 0 });
  }
  for (const v of ['12', 12, ' 12 ']) {
    const out = await call('setting_set', setArgs({ value: v }), baseRoutes({ [`PUT ${ROWS}`]: ok({ setting: ROW_12 }) }));
    answer(out);
    assert.equal(out.puts.length, 1);
    assert.equal(out.puts[0].body.value, '12');
  }
});

test('A5b set on a float knob checks finite number and range', async () => {
  const k = 'lane.lane-reaper.lane_reap_ratio';
  const routes = { [`GET ${row(k)}`]: one(k, null), [`GET ${REG}`]: ok(clone(REGISTRY)), [`PUT ${ROWS}`]: ok({ setting: { key: k, value: '0.25' } }) };
  refused(await call('setting_set', setArgs({ key: k, value: 'abc' }), routes), 'value_type');
  refused(await call('setting_set', setArgs({ key: k, value: 1.5 }), routes), 'value_out_of_range');
  const out = await call('setting_set', setArgs({ key: k, value: '0.25' }), routes);
  answer(out);
  assert.equal(out.puts.length, 1);
});

test('A6 set with no note, "", "   ", or a non-string note: note_required, 0 requests', async () => {
  for (const n of [undefined, '', '   ', 7]) {
    const args = setArgs({ note: n });
    if (n === undefined) delete args.note;
    refused(await call('setting_set', args, baseRoutes()), 'note_required', { requests: 0 });
  }
});

test('A6b set with a note that does not say how to roll back, or is short: note_must_say_why_and_rollback, 0 requests', async () => {
  for (const n of ['raising the cap for the drain', 'revert: x', 'x', 'a reason that is long enough but has no way back']) {
    refused(await call('setting_set', setArgs({ note: n }), baseRoutes()), 'note_must_say_why_and_rollback', { requests: 0 });
  }
  refused(await call('setting_set', setArgs({ note: 'y'.repeat(500) + ' roll back to 0 later' }), baseRoutes()), 'invalid_arguments: note', { requests: 0 });
});

test('A7 set an unknown knob key without force: unknown_knob, GETs only; A7b with force: one PUT', async () => {
  const k = 'hub_load.shed';
  const routes = { [`GET ${row(k)}`]: one(k, { key: k, value: 'on', note: null, actor: 'a', updated_at: 't' }), [`GET ${REG}`]: ok(clone(REGISTRY)),
    [`PUT ${ROWS}`]: ok({ setting: { key: k, value: 'off', note: NOTE, actor: 'ops@example.test', updated_at: 't2' } }) };
  const out = await call('setting_set', setArgs({ key: k, value: 'off' }), routes);
  refused(out, 'unknown_knob');
  assert.equal(out.gets.length, 2);
  const forced = await call('setting_set', setArgs({ key: k, value: 'off', force: true }), routes);
  const a = answer(forced);
  assert.equal(forced.puts.length, 1);
  assert.equal(a.forced, true);
  assert.equal(a.knob, null);
  assert.equal(a.old.value, 'on');
  assert.equal(a.new.value, 'off');
  refused(await call('setting_set', setArgs({ key: k, value: 'off', force: 'yes' }), routes), 'invalid_arguments: force', { requests: 0 });
});

test('A7c set a settable:false knob, even with force: not_settable, no PUT', async () => {
  const k = 'lane.fly-pool-tick.pool_tick_cmd';
  const routes = { [`GET ${row(k)}`]: one(k, null), [`GET ${REG}`]: ok(clone(REGISTRY)), [`PUT ${ROWS}`]: ok({ setting: {} }) };
  refused(await call('setting_set', setArgs({ key: k, value: 'evil', force: true }), routes), 'not_settable');
  refused(await call('setting_set', setArgs({ key: k, value: 'evil' }), routes), 'not_settable');
});

test('A7d set with a failed row or registry read never sends the PUT', async () => {
  const put = { [`PUT ${ROWS}`]: ok({ setting: ROW_12 }) };
  refused(await call('setting_set', setArgs(), baseRoutes({ ...put, [`GET ${REG}`]: { ok: false, status: 500, error: 'http_500' } })), 'registry_unavailable: http_500');
  refused(await call('setting_set', setArgs(), baseRoutes({ ...put, [`GET ${REG}`]: ok({ nope: 1 }) })), 'registry_unavailable');
  refused(await call('setting_set', setArgs(), baseRoutes({ ...put, [`GET ${row(KEY)}`]: { ok: false, status: 503, error: 'http_503' } })), 'http_503');
  refused(await call('setting_set', setArgs({ force: true, key: 'hub_load.shed', value: 'off' }),
    { ...put, [`GET ${row('hub_load.shed')}`]: one('hub_load.shed', null) }), 'registry_unavailable');
});

test('A8 set valid: one PUT {key, value, note, reason} with no actor; old is the GET row, new is the PUT answer', async () => {
  const stored = { key: KEY, value: '13', note: NOTE, actor: 'person@example.test', updated_at: '2026-10-20T15:01:00Z' };
  const out = await call('setting_set', setArgs({ value: 12 }), baseRoutes({ [`PUT ${ROWS}`]: ok({ setting: stored }) }));
  const a = answer(out);
  assert.equal(out.puts.length, 1);
  assert.equal(out.puts[0].path, ROWS);
  assert.deepEqual(out.puts[0].body, { key: KEY, value: '12', note: NOTE, reason: NOTE });
  assert.equal('actor' in out.puts[0].body, false);
  assert.deepEqual(a.old, { value: '12', note: 'old note', actor: 'ops@example.test', updated_at: '2026-10-20T10:00:00Z' });
  assert.deepEqual(a.new, { value: '13', note: NOTE, actor: 'person@example.test', updated_at: '2026-10-20T15:01:00Z' });
  assert.equal(a.forced, false);
  assert.equal(a.knob.max, 256);
  // The reads came before the PUT.
  assert.equal(out.sent.at(-1).method, 'PUT');
});

test('A8 set on a key with no row answers old null; a PUT 2xx without a setting is an error, never a success', async () => {
  const k = 'lane.lane-reaper.lane_reap_deadline_secs';
  const routes = { [`GET ${row(k)}`]: one(k, null), [`GET ${REG}`]: ok(clone(REGISTRY)) };
  const a = answer(await call('setting_set', setArgs({ key: k, value: 600 }), { ...routes, [`PUT ${ROWS}`]: ok({ setting: { key: k, value: '600' } }) }));
  assert.equal(a.old, null);
  assert.equal(a.new.value, '600');
  const bad = await call('setting_set', setArgs({ key: k, value: 600 }), { ...routes, [`PUT ${ROWS}`]: ok({ nope: 1 }) });
  assert.equal(bad.r.isError, true);
  assert.match(bad.r.content[0].text, /^bad_payload: \/api\/coord\/settings \(write sent, answer unreadable; read it back with setting_get\)$/);
  const refusedPut = await call('setting_set', setArgs({ key: k, value: 600 }), { ...routes, [`PUT ${ROWS}`]: { ok: false, status: 400, error: 'http_400: value too long' } });
  assert.equal(refusedPut.r.content[0].text, 'http_400: value too long');
});

test('A8 set then get round-trip: the set answer new.value equals what get reads back', async () => {
  let stored = ROW_12;
  const routes = {
    [`GET ${row(KEY)}`]: () => one(KEY, stored),
    [`GET ${REG}`]: ok(clone(REGISTRY)),
    [`PUT ${ROWS}`]: (body) => { stored = { key: body.key, value: body.value, note: body.note, actor: 'p', updated_at: 'u' }; return ok({ setting: stored }); },
  };
  const s = answer(await call('setting_set', setArgs({ value: 40 }), routes));
  const g = answer(await call('setting_get', { key: KEY }, routes));
  assert.equal(s.new.value, '40');
  assert.equal(g.value, s.new.value);
});

// ---- A9/A10: secrets ----

test('A9 secret rows: get by key and by prefix redacts the worker sig, a secret-named key and a secret-shaped value', async () => {
  const raw = {
    sig: 'sigvalue-fixture-1', tok: 'tok-fixture-raw-2', sk: 'sk-fixture-abcdef', bearer: 'Bearer abc.def-fixture',
  };
  const settings = [
    { key: 'human_verdict_mode.sig', value: null, redacted: true, note: null, actor: 'w', updated_at: 't' },
    { key: 'lane.x.api_token', value: raw.tok, note: null, actor: 'a', updated_at: 't' },
    { key: 'account.widgets', value: raw.sk, note: null, actor: 'a', updated_at: 't' },
    { key: 'account.other', value: raw.bearer, note: null, actor: 'a', updated_at: 't' },
    { key: 'lane.x.cfg_sig', value: raw.sig, note: null, actor: 'a', updated_at: 't' },
    { key: 'lib.token-health.token_health_warn_h', value: '24', note: null, actor: 'a', updated_at: 't' },
    { key: 'lane.x.note', value: 'rotate the token monthly, roll back by hand', note: null, actor: 'a', updated_at: 't' },
  ];
  const out = await call('setting_get', {}, { [`GET ${ROWS}`]: ok({ settings }), [`GET ${REG}`]: ok(clone(REGISTRY)) });
  const a = answer(out);
  const by = Object.fromEntries(a.rows.map((r) => [r.key, r]));
  for (const k of ['human_verdict_mode.sig', 'lane.x.api_token', 'account.widgets', 'account.other', 'lane.x.cfg_sig']) {
    assert.equal(by[k].value, null, k);
    assert.equal(by[k].redacted, true, k);
  }
  assert.equal(by['lib.token-health.token_health_warn_h'].value, '24');
  assert.equal(by['lib.token-health.token_health_warn_h'].redacted, undefined);
  assert.equal(by['lib.token-health.token_health_warn_h'].knob.env, 'TOKEN_HEALTH_WARN_H');
  assert.equal(by['lane.x.note'].value, 'rotate the token monthly, roll back by hand');
  for (const v of Object.values(raw)) assert.ok(!out.r.content[0].text.includes(v), `${v} leaked`);

  for (const s of settings.slice(1, 5)) {
    const one1 = await call('setting_get', { key: s.key }, { [`GET ${row(s.key)}`]: one(s.key, s), [`GET ${REG}`]: ok(clone(REGISTRY)) });
    const b = answer(one1);
    assert.equal(b.value, null, s.key);
    assert.equal(b.redacted, true, s.key);
    assert.ok(!one1.r.content[0].text.includes(s.value), `${s.key} leaked`);
  }
});

test('A9 secret: set redacts a stored secret in old and new rows', async () => {
  const k = 'hub_load.shed';
  const routes = { [`GET ${row(k)}`]: one(k, { key: k, value: 'ghp_fixtureoldvalue', note: null, actor: 'a', updated_at: 't' }), [`GET ${REG}`]: ok(clone(REGISTRY)),
    [`PUT ${ROWS}`]: ok({ setting: { key: k, value: 'sk-fixture-new', note: NOTE, actor: 'a', updated_at: 't' } }) };
  const out = await call('setting_set', setArgs({ key: k, value: 'off', force: true }), routes);
  const a = answer(out);
  assert.equal(a.old.value, null);
  assert.equal(a.old.redacted, true);
  assert.equal(a.new.value, null);
  assert.equal(a.new.redacted, true);
  for (const v of ['ghp_fixtureoldvalue', 'sk-fixture-new']) assert.ok(!out.r.content[0].text.includes(v));
});

test('A10 secret: set with a secret-shaped value or a secret-named key is secret_value_refused, 0 requests', async () => {
  for (const extra of [
    { key: 'hub_load.shed', value: 'ghp_fixture123', force: true },
    { key: 'hub_load.shed', value: 'sk-fixture', force: true },
    { key: 'hub_load.shed', value: 'Bearer x', force: true },
    { key: 'hub_load.shed', value: 'AKIAFIXTURE', force: true },
    { key: 'lane.x.api_token', value: 'plain', force: true },
    { key: 'lane.x.db_password', value: 'plain', force: true },
  ]) {
    refused(await call('setting_set', setArgs(extra), baseRoutes()), 'secret_value_refused', { requests: 0 });
  }
});

// ---- A13: the resolver table, through setting_get ----

test('A13 get resolver table: which keys resolve to a registry knob', async () => {
  const cases = [
    [KEY, 'POOL_TICK_MAX_PARALLEL'],
    ['lane.lane-reaper.widgets.lane_reap_deadline_secs', 'LANE_REAP_DEADLINE_SECS'],
    ['lib.token-health.token_health_warn_h', 'TOKEN_HEALTH_WARN_H'],
    ['hub_load.shed', null],
    ['lane.fly-pool-tick.no_such_knob', null],
    ['lane.no-such-lane.pool_cap', null],
    ['lane.fly-pool-tick', null],
    ['lane.a.b.c.d', null],
    ['lib.fly-pool-tick.pool_tick_max_parallel', null],
    ['conductor_remote_spawn.widgets', null],
  ];
  for (const [k, env] of cases) {
    const a = answer(await call('setting_get', { key: k }, { [`GET ${row(k)}`]: one(k, null), [`GET ${REG}`]: ok(clone(REGISTRY)) }));
    assert.equal(a.knob?.env ?? null, env, k);
  }
});

// ---- A14: mutation pins (D1) ----

function mutatedRegistry(t, anchor, replacement) {
  const dir = mkdtempSync(join(tmpdir(), 'mcp-mut-'));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  cpSync(MCP_DIR, dir, { recursive: true });
  const path = join(dir, 'tools', 'settings.mjs');
  const src = readFileSync(path, 'utf8');
  assert.equal(src.split(anchor).length, 2, `mutation anchor not found exactly once: ${anchor}`);
  writeFileSync(path, src.replace(anchor, replacement));
  return loadTools(join(dir, 'tools'));
}

test('A14 set mutation: with the confirm check removed, a confirm:false call sends requests (A4 would go red)', async (t) => {
  const reg = await mutatedRegistry(t, "if (args.confirm !== true) return 'confirm_required';", '');
  const out = await call('setting_set', setArgs({ confirm: false }), baseRoutes({ [`PUT ${ROWS}`]: ok({ setting: ROW_12 }) }), reg);
  assert.ok(out.sent.length > 0, 'the mutant must send requests');
  assert.notEqual(out.r.content[0].text, 'confirm_required');
});

test('A14 set mutation: with the max check removed, 257 goes to the PUT (A5 would go red)', async (t) => {
  const reg = await mutatedRegistry(t, 'if (typeof knob.max === \'number\' && n > knob.max)', 'if (false)');
  const out = await call('setting_set', setArgs({ value: 257 }), baseRoutes({ [`PUT ${ROWS}`]: ok({ setting: ROW_12 }) }), reg);
  assert.equal(out.puts.length, 1, 'the mutant must send the PUT');
});

test('A14 secret mutation: with the secret-row rule removed, a secret-named row leaks', async (t) => {
  const reg = await mutatedRegistry(t, 'const isSecretRow = (r) =>', 'const isSecretRow = () => false; const unusedRule = (r) =>');
  const k = 'lane.x.api_token';
  const out = await call('setting_get', { key: k }, { [`GET ${row(k)}`]: one(k, { key: k, value: 'tok-fixture-raw-2' }), [`GET ${REG}`]: ok(clone(REGISTRY)) }, reg);
  assert.ok(out.r.content[0].text.includes('tok-fixture-raw-2'));
});

// ---- A11: the real server process, no secret leaks ----

function spawnServer(env) {
  const child = spawn(process.execPath, [SERVER], { env: { PATH: process.env.PATH, ...env }, stdio: ['pipe', 'pipe', 'pipe'] });
  let stderr = '';
  child.stderr.on('data', (c) => { stderr += c; });
  const pending = new Map();
  createInterface({ input: child.stdout }).on('line', (line) => {
    const m = JSON.parse(line);
    pending.get(m.id)?.(m);
    pending.delete(m.id);
  });
  const exited = new Promise((r) => child.on('exit', r));
  let id = 0;
  const rpc = (method, params) => new Promise((resolve) => {
    pending.set(++id, resolve);
    child.stdin.write(JSON.stringify({ jsonrpc: '2.0', id, method, params }) + '\n');
  });
  return { rpc, end: async () => { child.stdin.end(); await exited; return stderr; }, kill: () => child.kill() };
}

test('A11 secret: the real server answers setting_get and setting_set; neither the console secret nor the cookie surfaces', async (t) => {
  const SECRET = 'sec-fixture-settings';
  const COOKIE = 'ck-fixture-settings';
  const leaky = `see ${COOKIE} and ${SECRET}`;
  const stored = { key: KEY, value: leaky, note: NOTE, actor: 'person@example.test', updated_at: 'u' };
  const stub = await startStub({
    cookie: COOKIE,
    routes: {
      [row(KEY)]: { json: { key: KEY, setting: { ...ROW_12, value: leaky }, source: 'settings', as_of: 'T' } },
      [REG]: { json: clone(REGISTRY) },
      [ROWS]: { json: { settings: [{ ...ROW_12, value: leaky }], setting: stored } },
    },
  });
  stubOrigins.add(stub.url);
  t.after(() => { stubOrigins.delete(stub.url); return stub.close(); });
  const srv = spawnServer({ HARNESS_CONSOLE_URL: stub.url, HARNESS_CONSOLE_SECRET: SECRET });
  t.after(() => srv.kill());

  const list = await srv.rpc('tools/list', {});
  const names = list.result.tools.map((x) => x.name);
  assert.ok(names.includes('setting_get') && names.includes('setting_set'));

  const seen = [];
  const keep = (r) => {
    seen.push(JSON.stringify(r));
    return r.result;
  };
  const g = keep(await srv.rpc('tools/call', { name: 'setting_get', arguments: { key: KEY } }));
  assert.notEqual(g.isError, true, JSON.stringify(g));
  assert.equal(g.structuredContent.knob.max, 256);
  const p = keep(await srv.rpc('tools/call', { name: 'setting_get', arguments: { prefix: 'lane.' } }));
  assert.notEqual(p.isError, true, JSON.stringify(p));
  const s = keep(await srv.rpc('tools/call', { name: 'setting_set', arguments: setArgs({ value: 12 }) }));
  assert.notEqual(s.isError, true, JSON.stringify(s));
  assert.equal(s.structuredContent.new.actor, 'person@example.test');

  const puts = stub.requests.filter((q) => q.method === 'PUT');
  assert.equal(puts.length, 1);
  assert.deepEqual(puts[0].body, { key: KEY, value: '12', note: NOTE, reason: NOTE });
  assert.equal(puts[0].cookie, `dash=${COOKIE}`, 'positive control: the cookie was sent');
  const stderr = await srv.end();
  for (const v of [SECRET, COOKIE]) {
    assert.deepEqual(seen.filter((x) => x.includes(v)), [], `${v} surfaced in a result`);
    assert.ok(!stderr.includes(v), stderr);
  }
  assert.ok(seen.some((x) => x.includes('[redacted]')), 'positive control: the redactor ran on the leaky value');
});

// ---- A12: no network outside a stub ----

test('A12 the fetch recorder saw 0 requests to any origin other than a stub', () => {
  assert.deepEqual(fetched.filter((u) => !u.startsWith('http://127.0.0.1:')), []);
});
