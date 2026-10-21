// BH-7709: POST /api/pool/tick-summary (the hub lane bin/pool-tick-summary.sh
// writes one row per pool project) and GET /api/pool/status (read by the MCP
// pool_status tool through /api/coord/pool/status, and by the BH-7725 unblock
// collector through _jobs_req). Driven through the REAL worker.fetch on
// node:sqlite with the composed jobs schema.
//   W1-W4 the POST rule       W5 GET project validation   W6 upsert + flat answer
//   W7 the spawn cap rows     W8 EXPLAIN QUERY PLAN with 200 rows
//   W9 the fields the BH-7725 collector reads           W10 one project's row only
//   X1 the lane on the fixture log -> the worker -> the real pool_status tool
import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { copyFileSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import { plan, fullScans } from './lib/d1-volume.bh-6727.js';

const SECRET = 'tok-fixture-bh7709';
const SQL = await import('../src/routes/pool-tick.js').catch(() => ({}));
const ISO_RE = /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$/;
const REPO = fileURLToPath(new URL('../../../', import.meta.url));

async function fresh(t) {
  const o = await openDb();
  if (!o) { t.skip('node:sqlite unavailable'); return null; }
  return o;
}
function call(DB, method, path, body, auth = true) {
  const headers = { 'content-type': 'application/json' };
  if (auth) headers.authorization = `Bearer ${SECRET}`;
  const init = { method, headers };
  if (method !== 'GET') init.body = JSON.stringify(body ?? {});
  return worker.fetch(new Request(`https://jobs.test${path}`, init), { DB, HARNESS_SECRET: SECRET })
    .then(async (res) => ({ status: res.status, body: await res.json().catch(() => null) }));
}
const post = (DB, b, auth) => call(DB, 'POST', '/api/pool/tick-summary', b, auth);
const get = (DB, p) => call(DB, 'GET', `/api/pool/status${p === undefined ? '' : `?project=${encodeURIComponent(p)}`}`);
const rows = (db) => db.prepare('SELECT * FROM pool_tick_summary ORDER BY project').all();

// A row in the shape the lane writes.
function row(project, over = {}) {
  return {
    project, tail_lines: 20000, tick: 'ok', reason: null,
    queued: 9, running: 1, spawning: 1, cap: 2, hotfix: 0,
    last_tick: {
      at: '2026-10-21T07:55:00Z', started_at: '2026-10-21T07:50:00Z', ended_at: '2026-10-21T07:51:00Z', complete: true,
      rows_decided: 2, rows_spawned: 1, stop: 'max-ticks', window_stop: 'done', cap: 4, knob: 'POOL_TICK_MAX_PARALLEL',
      in_progress_since: null, max_ticks_waits_1h: 1, last_max_ticks_at: '2026-10-21T07:55:00Z',
    },
    decisions: [['BH-1', 'hold'], ['BH-2', 'spawned']], decisions_truncated: false,
    env_bundle_failures_1h: 1,
    respawns: [{ key: 'BH-2', count: 3, last_result: 'PLAN_BLOCKED', last_at: '2026-10-21T07:50:30Z' }],
    respawns_since: '2026-10-21T00:00:00Z', respawns_truncated: false,
    ...over,
  };
}
const withTick = (over) => row('p1', { last_tick: { ...row('p1').last_tick, ...over } });

test('W1 a body without 1..200 rows is a 400 and writes nothing', async (t) => {
  const o = await fresh(t); if (!o) return;
  for (const b of [{}, { rows: [] }, { rows: 'x' }, { rows: Array.from({ length: 201 }, (_, i) => row(`p${i}`)) }]) {
    const r = await post(o.DB, b);
    assert.equal(r.status, 400, JSON.stringify(b).slice(0, 80));
    assert.match(r.body.error, /rows/);
  }
  assert.equal(rows(o.db).length, 0);
});

test('W2 a bad row is counted in rejected and not written; the good rows are', async (t) => {
  const o = await fresh(t); if (!o) return;
  const bad = [
    row('bad project'), row('x'.repeat(65)), row('p2', { tail_lines: -1 }), row('p3', { env_bundle_failures_1h: 1.5 }),
    row('p5', { reason: 'x'.repeat(201) }), row('p6', { tick: 'yes' }), row('p7', { queued: '9' }), row('p8', { cap: 'lots' }),
    row('p9', { decisions: [['BH-1', 'sleepy']] }), row('p10', { decisions: [['BH 1', 'hold']] }),
    row('p11', { decisions: Array.from({ length: 501 }, (_, i) => [`K-${i}`, 'hold']) }), row('p12', { decisions_truncated: 'no' }),
    row('p13', { respawns: [{ key: 'BH-1', count: 0, last_result: null, last_at: '2026-10-21T07:00:00Z' }] }),
    row('p14', { respawns: [{ key: 'BH-1', count: 2, last_result: 'PLAN BLOCKED', last_at: '2026-10-21T07:00:00Z' }] }),
    row('p15', { respawns: Array.from({ length: 51 }, (_, i) => ({ key: `K-${i}`, count: 2, last_result: null, last_at: '2026-10-21T07:00:00Z' })) }),
    row('p16', { respawns_since: 'today' }),
    withTick({ stop: 'cap' }), withTick({ stop: 'max_ticks' }), withTick({ window_stop: 'max-ticks' }), withTick({ knob: 'POOL_SPAWN' }),
    withTick({ started_at: 'yesterday' }), withTick({ complete: 'yes' }), withTick({ cap: -1 }), withTick({ last_max_ticks_at: '2026-10-21 07:00' }),
    row('p17', { last_tick: 'x' }), 'not an object',
  ];
  const r = await post(o.DB, { rows: [row('good-a'), ...bad, row('good-b'), row('good-a', { tail_lines: 5 })] });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.written, 2);
  assert.equal(r.body.rejected, bad.length + 1, 'a project named twice is rejected the second time');
  assert.match(r.body.as_of, ISO_RE);
  assert.deepEqual(rows(o.db).map((x) => x.project), ['good-a', 'good-b']);
  assert.equal(JSON.parse(rows(o.db)[0].summary_json).tail_lines, 20000);
});

test('W3 the stored row keeps only the known fields; a no-header row with null counts is valid', async (t) => {
  const o = await fresh(t); if (!o) return;
  const extra = { ...row('p1'), secret: 'tok-fixture-planted' };
  extra.last_tick = { ...extra.last_tick, line: 'tok-fixture-planted' };
  const none = row('p2', {
    tick: null, reason: 'no tick header in the last 20000 log lines', queued: null, running: null, spawning: null, cap: null, hotfix: null,
    decisions: null, decisions_truncated: null, respawns: [], respawns_since: null,
    last_tick: { ...row('p2').last_tick, at: '2026-10-21T07:55:00Z', stop: 'shed', started_at: null, ended_at: null, complete: null,
      rows_decided: null, rows_spawned: null, window_stop: null, cap: null, knob: null },
  });
  assert.equal((await post(o.DB, { rows: [extra, none] })).body.written, 2);
  const [a, b] = rows(o.db);
  assert.equal(a.summary_json.includes('tok-fixture-planted'), false);
  assert.equal(JSON.parse(b.summary_json).tick, null);
  assert.equal(JSON.parse(b.summary_json).last_tick.stop, 'shed');
  assert.match(a.reported_at, ISO_RE);
});

test('W4 no bearer is a 401 for both routes', async (t) => {
  const o = await fresh(t); if (!o) return;
  assert.equal((await post(o.DB, { rows: [row('p1')] }, false)).status, 401);
  assert.equal((await call(o.DB, 'GET', '/api/pool/status?project=p1', undefined, false)).status, 401);
  assert.equal(rows(o.db).length, 0);
});

test('W5 GET /api/pool/status with no project or a bad one is a 400', async (t) => {
  const o = await fresh(t); if (!o) return;
  assert.equal((await get(o.DB)).status, 400);
  assert.equal((await get(o.DB, '')).status, 400);
  assert.equal((await get(o.DB, 'bad project')).status, 400);
  assert.equal((await get(o.DB, 'x'.repeat(65))).status, 400);
});

test('W6 a second report overwrites the project row; the GET answer is flat (pool-status v1)', async (t) => {
  const o = await fresh(t); if (!o) return;
  await post(o.DB, { rows: [row('p1')] });
  await post(o.DB, { rows: [row('p1', { env_bundle_failures_1h: 7, queued: 126 })] });
  const x = rows(o.db);
  assert.equal(x.length, 1);
  const g = await get(o.DB, 'p1');
  assert.equal(g.status, 200);
  assert.equal(g.body.version, 1);
  assert.equal(g.body.project, 'p1');
  assert.equal(g.body.tick, 'ok');
  assert.equal(g.body.env_bundle_failures_1h, 7);
  assert.equal(g.body.queued, 126);
  assert.equal(g.body.spawning, 1);
  assert.equal(g.body.reported_at, x[0].reported_at);
  assert.match(g.body.as_of, ISO_RE);
  assert.deepEqual(g.body.decisions, [['BH-1', 'hold'], ['BH-2', 'spawned']]);
  assert.equal(g.body.last_tick.rows_decided, 2);
  assert.equal(g.body.respawns_since, '2026-10-21T00:00:00Z');
  assert.equal('summary' in g.body, false, 'no nested summary object');
});

test('W7 the per-key spawn cap: the project row, then the fleet row, then 2 / 86400', async (t) => {
  const o = await fresh(t); if (!o) return;
  const set = (k, v) => o.db.prepare("INSERT OR REPLACE INTO settings (key, value, updated_at) VALUES (?, ?, '2026-10-21T00:00:00Z')").run(k, v);
  o.db.prepare("DELETE FROM settings WHERE key IN ('pool_spawn_cap_per_key', 'pool_spawn_cap_window_s')").run();
  const cap = async () => (await get(o.DB, 'Fixture-OS')).body.spawn_cap_per_key;
  assert.deepEqual(await cap(), { value: 2, window_s: 86400, source: 'default' });
  set('pool_spawn_cap_per_key', 'abc');
  assert.equal((await cap()).source, 'default', 'a junk value is no row');
  set('pool_spawn_cap_per_key', '3');
  set('pool_spawn_cap_window_s', '3600');
  assert.deepEqual(await cap(), { value: 3, window_s: 3600, source: 'row' });
  set('lane.fly-pool.fixture-os.pool_spawn_cap_per_key', '5');
  assert.equal((await cap()).value, 5, 'the lowercased project row wins');
  set('lane.fly-pool.other.pool_spawn_cap_per_key', '9');
  assert.equal((await cap()).value, 5, "another project's row is never read");
  // the cap is in the answer with no summary row too
  assert.equal((await get(o.DB, 'Fixture-OS')).body.tick, null);
});

test('W8 EXPLAIN QUERY PLAN with 200 rows: the GET and the upsert use the PRIMARY KEY', async (t) => {
  const o = await fresh(t); if (!o) return;
  assert.ok(SQL.UPSERT_SQL && SQL.READ_SQL && SQL.SETTINGS_SQL, 'pool-tick.js exports its SQL');
  const ins = o.db.prepare(SQL.UPSERT_SQL);
  for (let i = 0; i < 200; i++) ins.run(`p-${i}`, '2026-10-21T00:00:00Z', '{}');
  assert.equal(rows(o.db).length, 200);
  for (const [sql, binds] of [[SQL.UPSERT_SQL, ['p-1', '2026-10-21T00:00:00Z', '{}']], [SQL.READ_SQL, ['p-1']]]) {
    const p = plan(o.db, sql, ...binds);
    assert.deepEqual(fullScans(p, ['pool_tick_summary']), [], p.join(' | '));
    if (sql === SQL.READ_SQL) assert.ok(p.some((l) => /USING INDEX sqlite_autoindex_pool_tick_summary_1/.test(l)), p.join(' | '));
  }
  const s = plan(o.db, SQL.SETTINGS_SQL, 'a', 'b', 'c');
  assert.deepEqual(fullScans(s, ['settings']), [], s.join(' | '));
});

// The fields bin/lib/unblock/collectors/infra.sh (BH-7725) reads, with its own
// jq guard: queued and running numbers, last_tick.{at,stop,cap,knob},
// respawns[].{key,count,last_result,last_at}. No row: no queued key at all.
test('W9 the BH-7725 collector contract', async (t) => {
  const o = await fresh(t); if (!o) return;
  await post(o.DB, { rows: [row('p1')] });
  const b = (await get(o.DB, 'p1')).body;
  assert.equal(typeof b.queued, 'number');
  assert.equal(typeof b.running, 'number');
  assert.match(b.last_tick.at, ISO_RE);
  assert.ok(['budget', 'age', 'code', 'done', 'max-ticks', 'shed', 'hold'].includes(b.last_tick.stop), b.last_tick.stop);
  assert.equal(b.last_tick.cap, 4);
  assert.equal(b.last_tick.knob, 'POOL_TICK_MAX_PARALLEL');
  assert.ok(Array.isArray(b.respawns));
  for (const r of b.respawns) {
    assert.equal(typeof r.key, 'string');
    assert.equal(typeof r.count, 'number');
    assert.ok(r.last_result === null || typeof r.last_result === 'string');
    assert.match(r.last_at, ISO_RE);
  }
  const none = (await get(o.DB, 'p-none')).body;
  assert.equal('queued' in none, false);
  assert.equal('running' in none, false);
  assert.equal(none.tick, null);
  assert.equal(none.reason, 'no summary row');
});

test("W10 a GET reads one project's row: another project is tick null (0 rows of the other)", async (t) => {
  const o = await fresh(t); if (!o) return;
  await post(o.DB, { rows: [row('p1')] });
  const g = await get(o.DB, 'p2');
  assert.equal(g.status, 200);
  assert.equal(g.body.project, 'p2');
  assert.equal(g.body.tick, null);
  assert.equal('decisions' in g.body, false);
  assert.equal((await get(o.DB, 'p1')).body.queued, 9);
});

// The MCP side of X1: the tool's consoleFetch goes to this worker.
function viaConsole(DB) {
  return async (cfg, method, path) => {
    const r = await call(DB, method, path.replace(/^\/api\/coord\//, '/api/'));
    if (r.status >= 200 && r.status < 300) return { ok: true, status: r.status, data: r.body };
    return { ok: false, status: r.status, error: `http_${r.status}` };
  };
}
const mcp = await import('../../../mcp/lib/tools.mjs');
const registry = await mcp.loadTools(new URL('../../../mcp/tools/', import.meta.url));

// The shipped lane on the fixture log, in a scratch harness whose jobs client
// writes the POST body to a file instead of sending it.
function runLane() {
  const H = mkdtempSync(join(tmpdir(), 'pool-tick-x1-'));
  try {
    for (const d of ['bin', 'logs', 'flags', 'locks']) mkdirSync(join(H, d));
    copyFileSync(join(REPO, 'bin/pool-tick-summary.sh'), join(H, 'bin/pool-tick-summary.sh'));
    copyFileSync(join(REPO, 'tests/fixtures/pool-tick-summary.bh-7709/fly-pool.log'), join(H, 'logs/fly-pool.log'));
    for (const p of ['fixture-os', 'fixture-q']) writeFileSync(join(H, 'flags', `fly-pool-${p}`), '');
    writeFileSync(join(H, 'bin/jobs-client.sh'), '_jobs_req() { printf \'%s\' "$3" > "$HARNESS/body.json"; JOBS_HTTP=200; }\n');
    execFileSync('bash', [join(H, 'bin/pool-tick-summary.sh')], {
      env: { PATH: process.env.PATH, HARNESS: H, LANE_GATE_DISABLE: '1', POOL_TICK_SUMMARY_NOW: String(Date.parse('2026-10-21T08:00:00Z') / 1000) },
    });
    return JSON.parse(readFileSync(join(H, 'body.json'), 'utf8'));
  } finally {
    rmSync(H, { recursive: true, force: true });
  }
}

test('X1 the lane on the fixture log -> POST -> GET -> pool_status: the 26-row grouped counts', async (t) => {
  const o = await fresh(t); if (!o) return;
  const body = runLane();
  assert.deepEqual(body.rows.map((r) => r.project).sort(), ['fixture-os', 'fixture-q']);
  const p = await post(o.DB, body);
  assert.equal(p.status, 200, JSON.stringify(p.body));
  assert.equal(p.body.written, 2);
  assert.equal(p.body.rejected, 0);
  const ctx = { cfg: { url: 'http://console.invalid', token: 'tok-fixture-x1', secret: null }, consoleFetch: viaConsole(o.DB) };
  const r = await mcp.callTool(registry, 'pool_status', { project: 'fixture-os' }, ctx);
  assert.notEqual(r.isError, true, r.content?.[0]?.text);
  const s = r.structuredContent;
  assert.equal(s.skips.waits_for.count, 13);
  assert.equal(s.skips.hold.count, 3);
  assert.equal(s.spawned.count, 7);
  assert.equal(s.skips.not_queued.count, 3);
  assert.equal(s.skips.other.count, 0);
  assert.equal(s.last_tick.rows_decided, 26);
  assert.equal(s.last_tick.rows_spawned, 7);
  assert.equal(s.last_tick.stop, 'max-ticks');
  assert.equal(s.env_bundle_failures_1h, 2);
  assert.equal(s.pool.queued, 126);
  assert.equal(s.pool.spawn_cap_per_key.value, 2);
  assert.equal(s.respawns[0].key, 'FX-301');
  assert.equal(s.stale, false);
  // The MCP fixture is this same answer: the tool test reads what the worker writes.
  const fix = JSON.parse(readFileSync(join(REPO, 'mcp/test/fixtures/pool-status.bh-7709.json'), 'utf8'));
  const g = (await get(o.DB, 'fixture-os')).body;
  for (const k of ['tick', 'queued', 'running', 'spawning', 'cap', 'hotfix', 'last_tick', 'decisions', 'decisions_truncated',
    'env_bundle_failures_1h', 'respawns', 'respawns_since', 'respawns_truncated', 'reason', 'tail_lines', 'spawn_cap_per_key', 'version']) {
    assert.deepEqual(g[k], fix[k], k);
  }
});
