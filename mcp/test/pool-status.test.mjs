// The pool_status tool in mcp/tools/pool-status.mjs (BH-7709). Every case goes
// through the REAL registry (loadTools + callTool) and the REAL consoleFetch
// against the stub console. globalThis.fetch is wrapped with a recorder BEFORE
// the tools load, so "0 network calls off the stub" is measured.
// The fixture is the worker's GET /api/pool/status answer for the lane's
// fixture log (worker/jobs/test/pool-tick.bh-7709.test.js X1 pins that).
//   P1 the 26-row fixture tick: the grouped counts     P2 the schema and refusals
//   P3 pool and spawn cap fields, null when absent      P4 a stale report
//   P5 no summary, no route, a bad body                 P6 a truncated row
//   P7 at most 5 examples, in log order                 P8 a secret in the answer
//   P9 stop, cap, knob and respawns are copied as given
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

// ---- the recorder, installed before any tool module is imported ----
const fetched = [];
const realFetch = globalThis.fetch;
let stubOrigin = null;
globalThis.fetch = (input, init) => {
  const url = String(input instanceof Request ? input.url : input);
  fetched.push(url);
  if (!stubOrigin || !url.startsWith(stubOrigin + '/')) return Promise.reject(new Error(`blocked off-stub fetch: ${url}`));
  return realFetch(input, init);
};

const { loadTools, callTool } = await import('../lib/tools.mjs');
const { startStub } = await import('./lib/stub-console.mjs');

const HERE = dirname(fileURLToPath(import.meta.url));
const FIXTURE = JSON.parse(readFileSync(join(HERE, 'fixtures/pool-status.bh-7709.json'), 'utf8'));
const clone = (v) => JSON.parse(JSON.stringify(v));
const TOKEN = 'tok-fixture-pool-status';
const ROUTE = '/api/coord/pool/status';
const PATH = `${ROUTE}?project=fixture-os`;

const registry = await loadTools(new URL('../tools/', import.meta.url));

async function withStub(t, answer = FIXTURE, opts = {}) {
  const stub = await startStub({ routes: { [PATH]: { json: answer } }, ...opts });
  stubOrigin = stub.url;
  t.after(() => stub.close());
  const ctx = { cfg: { url: stub.url, token: TOKEN, secret: null } };
  const call = (args) => callTool(registry, 'pool_status', args, ctx);
  return { stub, call };
}
const out = (r) => {
  assert.notEqual(r.isError, true, r.content?.[0]?.text);
  assert.deepEqual(JSON.parse(r.content[0].text), r.structuredContent);
  return r.structuredContent;
};
const refused = (r, re) => {
  assert.equal(r.isError, true, JSON.stringify(r));
  assert.match(r.content[0].text, re);
};
const patched = (fn) => { const a = clone(FIXTURE); fn(a); return a; };
const GROUPS = ['waits_for', 'hold', 'spawn_cap', 'env_bundle', 'quota', 'not_queued', 'other'];

test('P1 the fixture tick of 26 decided rows: 13 waits_for, 3 hold, 7 spawned, 3 not_queued', async (t) => {
  const { call, stub } = await withStub(t);
  const before = fetched.length;
  const o = out(await call({ project: 'fixture-os' }));
  assert.deepEqual(stub.requests.map((q) => `${q.method} ${q.path}`), [`GET ${PATH}`]);
  assert.equal(o.status, 'ok');
  assert.equal(o.skips.waits_for.count, 13);
  assert.equal(o.skips.hold.count, 3);
  assert.equal(o.spawned.count, 7);
  assert.equal(o.skips.not_queued.count, 3);
  for (const g of ['spawn_cap', 'env_bundle', 'quota', 'other']) assert.equal(o.skips[g].count, 0, g);
  assert.deepEqual(Object.keys(o.skips).sort(), [...GROUPS].sort());
  for (const g of GROUPS) assert.ok(o.skips[g].examples.length <= 5, g);
  assert.deepEqual(o.skips.hold.examples, ['FX-201', 'FX-202', 'FX-203']);
  assert.deepEqual(o.spawned.examples, ['FX-301', 'FX-302', 'FX-303', 'FX-304', 'FX-305']);
  assert.equal(o.last_tick.rows_decided, 26);
  assert.equal(o.last_tick.rows_spawned, 7);
  assert.equal(o.last_tick.started_at, '2026-10-21T07:50:00Z');
  assert.equal(o.last_tick.ended_at, '2026-10-21T07:51:52Z');
  assert.equal(o.last_tick.window_stop, 'done');
  assert.equal(o.last_tick.complete, true);
  assert.equal(o.last_tick.max_ticks_waits_1h, 2);
  assert.equal(o.last_tick.last_max_ticks_at, '2026-10-21T07:55:00Z');
  assert.equal(o.env_bundle_failures_1h, 2);
  assert.equal(o.project, 'fixture-os');
  assert.equal(o.truncated, false);
  const mine = fetched.slice(before);
  assert.equal(mine.length, 1, mine.join(','));
  assert.equal(mine.every((u) => u.startsWith(stubOrigin + '/')), true, mine.join(','));
});

test('P2 a read tool with a closed schema: project required, no confirm; a bad call sends nothing', async (t) => {
  const tool = registry.get('pool_status');
  assert.equal(tool?.kind, 'read');
  assert.equal(tool.inputSchema.additionalProperties, false);
  assert.deepEqual(tool.inputSchema.required, ['project']);
  assert.equal('confirm' in tool.inputSchema.properties, false);
  const { call, stub } = await withStub(t);
  refused(await call({}), /^invalid_arguments: project$/);
  refused(await call({ project: '' }), /^invalid_arguments: project$/);
  refused(await call({ project: 7 }), /^invalid_arguments: project$/);
  refused(await call({ project: 'x'.repeat(65) }), /^invalid_arguments: project$/);
  refused(await call({ project: 'fixture os' }), /^invalid_arguments: project$/);
  refused(await call({ project: '../x' }), /^invalid_arguments: project$/);
  refused(await call({ project: 'fixture-os', box: 'x' }), /^invalid_arguments: box$/);
  assert.equal(stub.requests.length, 0);
});

test('P3 pool and spawn cap fields are copied; a field the answer lacks is null, never 0', async (t) => {
  let { call } = await withStub(t);
  let o = out(await call({ project: 'fixture-os' }));
  assert.deepEqual(o.pool, {
    queued: 126, running: 2, spawning: 2, cap: 4, hotfix: 1,
    spawn_cap_per_key: { value: 2, window_s: 86400, source: 'default' },
  });
  ({ call } = await withStub(t, patched((a) => {
    for (const k of ['queued', 'running', 'spawning', 'cap', 'hotfix', 'spawn_cap_per_key', 'env_bundle_failures_1h']) delete a[k];
  })));
  o = out(await call({ project: 'fixture-os' }));
  for (const [k, v] of Object.entries(o.pool)) assert.equal(v, null, k);
  assert.equal(o.env_bundle_failures_1h, null);
  ({ call } = await withStub(t, patched((a) => {
    a.cap = null;
    a.spawn_cap_per_key = { value: 5, window_s: 3600, source: 'row' };
  })));
  o = out(await call({ project: 'fixture-os' }));
  assert.equal(o.pool.cap, null);
  assert.deepEqual(o.pool.spawn_cap_per_key, { value: 5, window_s: 3600, source: 'row' });
});

test('P4 a report older than 600 s is stale', async (t) => {
  let { call } = await withStub(t);
  let o = out(await call({ project: 'fixture-os' }));
  assert.equal(o.report_age_s, 20);
  assert.equal(o.stale, false);
  assert.equal(o.reported_at, '2026-10-21T08:00:10Z');
  ({ call } = await withStub(t, patched((a) => { a.reported_at = '2026-10-21T07:48:50Z'; })));
  o = out(await call({ project: 'fixture-os' }));
  assert.equal(o.report_age_s, 700);
  assert.equal(o.stale, true);
  ({ call } = await withStub(t, patched((a) => { a.reported_at = '2026-10-21T07:50:30Z'; })));
  assert.equal(out(await call({ project: 'fixture-os' })).stale, false, 'exactly 600 s is not stale');
  ({ call } = await withStub(t, patched((a) => { delete a.reported_at; })));
  o = out(await call({ project: 'fixture-os' }));
  assert.equal(o.report_age_s, null);
  assert.equal(o.stale, null);
});

test('P5 no summary row, a row with no tick, no route, a bad body', async (t) => {
  let { call } = await withStub(t, { project: 'fixture-os', version: 1, tick: null, reason: 'no summary row',
    spawn_cap_per_key: FIXTURE.spawn_cap_per_key, as_of: FIXTURE.as_of });
  let o = out(await call({ project: 'fixture-os' }));
  assert.equal(o.status, 'no_summary');
  assert.equal(o.reason, 'no summary row');
  assert.equal(o.pool.queued, null);
  assert.equal(o.skips, null);
  assert.equal(o.spawned, null);
  ({ call } = await withStub(t, patched((a) => {
    a.tick = null;
    a.reason = 'no tick header in the last 20000 log lines';
    for (const k of ['queued', 'running', 'spawning', 'cap', 'hotfix']) a[k] = null;
    a.decisions = null;
    a.decisions_truncated = null;
    a.last_tick = { ...a.last_tick, stop: 'shed', started_at: null, rows_decided: null };
  })));
  o = out(await call({ project: 'fixture-os' }));
  assert.equal(o.status, 'no_summary');
  assert.equal(o.reason, 'no tick header in the last 20000 log lines');
  assert.equal(o.skips, null);
  assert.equal(o.truncated, null);
  assert.equal(o.pool.queued, null);
  assert.equal(o.last_tick.rows_decided, null);
  assert.equal(o.last_tick.stop, 'shed', 'the last start stop does not need a tick');
  assert.equal(o.last_tick.max_ticks_waits_1h, 2, 'the hour counts do not need a tick');
  assert.equal(o.pool.spawn_cap_per_key.value, 2);
  ({ call } = await withStub(t, FIXTURE, { fail: { [PATH]: 404 } }));
  refused(await call({ project: 'fixture-os' }), /^console route not available: \/api\/coord\/pool\/status$/);
  ({ call } = await withStub(t, patched((a) => { a.project = 'fixture-q'; })));
  refused(await call({ project: 'fixture-os' }), /^bad_payload: /);
  ({ call } = await withStub(t, [FIXTURE]));
  refused(await call({ project: 'fixture-os' }), /^bad_payload: /);
});

test('P6 a truncated row says truncated: true', async (t) => {
  const { call } = await withStub(t, patched((a) => { a.decisions_truncated = true; a.last_tick.rows_decided = 640; }));
  const o = out(await call({ project: 'fixture-os' }));
  assert.equal(o.truncated, true);
  assert.equal(o.last_tick.rows_decided, 640);
  assert.equal(o.skips.waits_for.count, 13, 'the group counts are of the stored decisions');
});

test('P7 13 waits_for rows: exactly 5 examples, the first 5 in log order', async (t) => {
  const { call } = await withStub(t);
  const o = out(await call({ project: 'fixture-os' }));
  assert.deepEqual(o.skips.waits_for.examples, ['FX-101', 'FX-102', 'FX-103', 'FX-104', 'FX-105']);
  assert.deepEqual(o.skips.not_queued.examples, ['FX-401', 'FX-402', 'FX-403']);
  assert.deepEqual(o.skips.other.examples, []);
});

test('P8 a credential that reaches the answer comes back redacted', async (t) => {
  const { call } = await withStub(t, patched((a) => {
    a.decisions[0][0] = TOKEN;
    a.reason = `bearer ${TOKEN}`;
  }));
  const r = await call({ project: 'fixture-os' });
  const o = out(r);
  assert.equal(r.content[0].text.includes(TOKEN), false);
  assert.equal(o.skips.waits_for.examples[0], '[redacted]');
  const { call: c404 } = await withStub(t, FIXTURE, { fail: { [PATH]: 404 } });
  assert.equal((await c404({ project: 'fixture-os' })).content[0].text.includes(TOKEN), false);
});

test('P9 stop, cap, knob and respawns are copied as given', async (t) => {
  let { call } = await withStub(t);
  let o = out(await call({ project: 'fixture-os' }));
  assert.equal(o.last_tick.stop, 'max-ticks');
  assert.equal(o.last_tick.at, '2026-10-21T07:55:00Z');
  assert.equal(o.last_tick.cap, 4);
  assert.equal(o.last_tick.knob, 'POOL_TICK_MAX_PARALLEL');
  assert.deepEqual(o.respawns, [{ key: 'FX-301', count: 2, last_result: 'PLAN_BLOCKED', last_at: '2026-10-21T07:50:30Z' }]);
  assert.equal(o.respawns_since, '2026-10-21T06:30:00Z');
  assert.equal(o.respawns_truncated, false);
  ({ call } = await withStub(t, patched((a) => {
    a.last_tick = { ...a.last_tick, stop: 'budget', at: a.last_tick.ended_at, cap: null, knob: 'POOL_TICK_BUDGET_S' };
    a.respawns = [];
  })));
  o = out(await call({ project: 'fixture-os' }));
  assert.equal(o.last_tick.stop, 'budget');
  assert.equal(o.last_tick.cap, null);
  assert.equal(o.last_tick.knob, 'POOL_TICK_BUDGET_S');
  assert.deepEqual(o.respawns, []);
});
