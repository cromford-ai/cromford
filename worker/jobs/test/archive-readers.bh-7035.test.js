// BH-7035 (slice C0): the wide history readers that C0 of #6779 left pending
// read the archive store too: lane-spend, the daily digest (spend, autonomy),
// GET /api/model-routes?unrouted_since= and the outcome gap.
//
// A1-A3 drive lib/archive-read.js directly (archiveReach, a given `reach`,
// the `union` merge). O1-O3 drive the outcome-gap pure half and its candidate
// filter SQL. R2, R3, R4 and R6 drive the REAL worker.fetch over a hot
// node:sqlite D1 and an archive node:sqlite D1 in #6777's archive shape (the
// hot columns, archived_at, the hot key as primary key, idx_<table>_<time>).
// The fixtures are this file's own copy of the C0 ones; the clock is pinned
// (D60).
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { LANES_REGISTRY } from '../src/lib/core.js';
import { openDb, d1 } from './lib/d1-sqlite.bh-1030.js';
import { LIVE } from './lib/d1-volume.bh-6727.js';
import * as AR from '../src/lib/archive-read.js';
import * as OG from '../src/lib/outcome-gap.js';

const SECRET = 'test-secret-fixture';
const NOW_MS = Date.parse('2026-10-16T12:00:00Z');
const DAY = 86400e3;
const iso = (ms) => new Date(ms).toISOString().replace(/\.\d{3}Z$/, 'Z');
const ago = (days, h = 0) => iso(NOW_MS - days * DAY + h * 3600e3);
const dayOf = (days) => iso(NOW_MS - days * DAY).slice(0, 10);
const NOW = iso(NOW_MS);
const close = (a, b, msg) => assert.ok(
  (a === null && b === null) || Math.abs(a - b) < 1e-9, `${msg}: ${a} != ${b}`);

// ── stores ────────────────────────────────────────────────────────────────
async function hotStore() {
  const o = await openDb();
  assert.ok(o, 'node:sqlite is required');
  return o.db;
}

// #6777's archive shape, built from the hot table's own columns.
async function archiveStore() {
  const { DatabaseSync } = await import('node:sqlite');
  const hot = await hotStore();
  const db = new DatabaseSync(':memory:');
  const cols = (t) => hot.prepare(`PRAGMA table_info(${t})`).all()
    .map((c) => `${c.name} ${c.type || ''}`.trim());
  db.exec(`CREATE TABLE cost_rows (${cols('cost_rows').join(', ')}, archived_at TEXT NOT NULL, PRIMARY KEY (box, row_hash))`);
  db.exec('CREATE INDEX idx_cost_rows_ts ON cost_rows(ts)');
  db.exec(`CREATE TABLE stage_events (${cols('stage_events').filter((c) => !/^id /.test(c)).join(', ')}, id INTEGER PRIMARY KEY, archived_at TEXT NOT NULL)`);
  db.exec('CREATE INDEX idx_stage_events_created_at ON stage_events(created_at)');
  return db;
}

// A D1 binding with a spy: every prepare() is counted and logged with the
// binds it ran. `fail` makes prepare throw (an unreadable store).
function spyArchive(db, { fail = null } = {}) {
  const inner = db ? d1(db) : null;
  const spy = { calls: 0, log: [] };
  spy.binding = {
    prepare(sql) {
      spy.calls += 1;
      const entry = { sql, binds: [] };
      spy.log.push(entry);
      if (fail) throw new Error(fail);
      const s = inner.prepare(sql);
      const api = {
        bind(...v) { entry.binds = v; s.bind(...v); return api; },
        first: (c) => s.first(c),
        all: () => s.all(),
        run: () => s.run(),
      };
      return api;
    },
    batch: (stmts) => Promise.all(stmts.map((s) => s.run())),
  };
  return spy;
}

// ── fixtures ──────────────────────────────────────────────────────────────
// A cost row spec: { ts, usd, project, ticket, stage, runner, lane, job, arch }.
// `arch` puts it in the archive in the split world; the all-hot world holds
// every row in the hot store. The row index is the row_hash, so a row has the
// same key in both worlds.
function insCost(db, r, i, archived = false) {
  const row = {
    box: 'box-1', row_hash: `h${i}`, line_no: i + 1, ts: r.ts, project: r.project ?? null,
    stage: r.stage ?? 'execute', runner: r.runner ?? 'claude', ticket: r.ticket ?? null, job_id: r.job ?? null,
    cost_usd: r.usd === undefined ? 0.5 : r.usd, lane_id: r.lane ?? null, inserted_at: r.ts,
    ...(archived ? { archived_at: NOW } : {}),
  };
  const cols = Object.keys(row);
  db.prepare(`INSERT INTO cost_rows (${cols.join(',')}) VALUES (${cols.map(() => '?').join(',')})`).run(...Object.values(row));
}
// A stage event spec: [id, job_id, verdict, actor, created_at, arch].
function insEv(db, [id, job, verdict, actor, at], archived = false) {
  const cols = ['id', 'job_id', 'stage', 'verdict', 'actor', 'detail', 'created_at', ...(archived ? ['archived_at'] : [])];
  db.prepare(`INSERT INTO stage_events (${cols.join(',')}) VALUES (${cols.map(() => '?').join(',')})`)
    .run(id, job, 'execute', verdict, actor, 'x', at, ...(archived ? [NOW] : []));
}
function insJob(db, id, project, ticket, created = ago(200)) {
  db.prepare(`INSERT INTO jobs (id, project, ticket_id, kind, box, stage, status, created_at, updated_at)
              VALUES (?,?,?,?,?,?,?,?,?)`).run(id, project, ticket, 'build', 'box-1', 'done', 'done', created, created);
}
function insRoute(db, role, project = null) {
  db.prepare(`INSERT INTO model_routes (scope, project, role, position, model, runner, updated_by, updated_at)
              VALUES (?, ?, ?, 0, 'test-model-a', 'claude', 'test', ?)`).run(project ? 'project' : 'hub', project, role, NOW);
}
function insMerge(db, jobId, project, ticket, url, mergedAt) {
  insJob(db, jobId, project, ticket);
  db.prepare(`INSERT INTO job_artifacts (job_id, artifact_kind, artifact_ref, actor, created_at, updated_at)
              VALUES (?, 'pr_url', ?, 'hub', ?, ?)`).run(jobId, url, mergedAt, mergedAt);
  db.prepare(`INSERT INTO ledgers (kind, key, status, actor, created_at, updated_at)
              VALUES ('merge', ?, 'merged', 'hub', ?, ?)`).run(url, mergedAt, mergedAt);
}

// world({ costs, events, hotOnly }) -> { all, hot, arch }. hotOnly(db) seeds
// the hot-only tables (jobs, model_routes, job_artifacts, ledgers) in BOTH
// hot stores.
async function world({ costs = [], events = [], hotOnly = () => {} } = {}) {
  const all = await hotStore(), hot = await hotStore(), arch = await archiveStore();
  costs.forEach((r, i) => { insCost(all, r, i); insCost(r.arch ? arch : hot, r, i, !!r.arch); });
  for (const e of events) { insEv(all, e); insEv(e[5] ? arch : hot, e, !!e[5]); }
  hotOnly(all); hotOnly(hot);
  return { all, hot, arch };
}

// ── the real worker ──────────────────────────────────────────────────────
const pinned = new WeakSet();
async function get(t, env, path) {
  if (!pinned.has(t)) { t.mock.timers.enable({ apis: ['Date'], now: NOW_MS }); pinned.add(t); }
  const res = await worker.fetch(new Request(`https://jobs.test${path}`, {
    headers: { authorization: `Bearer ${SECRET}` },
  }), { HARNESS_SECRET: SECRET, ...env });
  const body = await res.json().catch(() => null);
  return { status: res.status, body };
}
async function ok(t, env, path) {
  const r = await get(t, env, path);
  assert.equal(r.status, 200, `${path}: ${JSON.stringify(r.body)}`);
  return r.body;
}

// ── the four worlds ──────────────────────────────────────────────────────
const LANES = LANES_REGISTRY.lanes.slice(0, 3).map((l) => l.id);
const D100 = dayOf(100);
const at100 = (h) => `${D100}T${String(h).padStart(2, '0')}:00:00Z`;
const LANE_PATH = `/api/metrics/lane-spend?day=${D100}`;
// 12 rows on D100 over 3 lanes, 8 archived; one unpriced; one archived row the
// day before (out of the window).
const LANE_COSTS = [
  ...Array.from({ length: 12 }, (_, i) => ({ ts: at100(i + 1), lane: LANES[i % 3], usd: i === 5 ? null : 0.25 * (i + 1), arch: i < 8 })),
  { ts: `${dayOf(101)}T23:00:00Z`, lane: LANES[0], usd: 9, arch: true },
];

const DIGEST_PATH = `/api/metrics/daily-digest?day=${D100}&human=operator`;
const DIGEST_COSTS = [
  { ts: at100(1), project: 'alpha', ticket: 'BH-1', usd: 3, job: 'j-1' },
  { ts: at100(2), project: 'alpha', ticket: 'BH-1', usd: 4, job: 'j-2', arch: true },
  { ts: at100(3), project: 'alpha', ticket: 'BH-2', usd: 5.5, job: 'j-3', arch: true },
  { ts: at100(4), project: 'bravo', ticket: 'BH-3', usd: 2.25, job: 'j-4' },
  { ts: at100(5), project: 'bravo', ticket: 'BH-3', usd: 0.5, job: 'j-5', arch: true },
  { ts: at100(6), project: 'bravo', ticket: 'BH-4', usd: 1, job: 'j-6', arch: true },
  { ts: at100(7), project: 'alpha', ticket: 'BH-5', usd: 0.125, job: 'j-7' },
  { ts: at100(8), project: 'alpha', ticket: 'BH-6', usd: null, arch: true },
  { ts: at100(9), project: 'alpha', ticket: null, usd: null },
  { ts: at100(10), project: 'alpha', ticket: null, usd: 6 },
  { ts: `${dayOf(101)}T22:00:00Z`, project: 'alpha', ticket: 'BH-9', usd: 50, arch: true },
];
// id 1 is archived and its job is in hot jobs only; id 2's job does not exist;
// id 4 is the watchdog (excluded); id 6 ties id 1's time (id DESC breaks it).
const DIGEST_EVENTS = [
  [1, 'build-alpha-1', 'REQUEUED', 'operator', at100(2), true],
  [2, 'build-gone', 'RELEASED', 'operator', at100(3), true],
  [3, 'build-alpha-1', 'DROPPED', 'operator', at100(4), false],
  [4, 'build-alpha-1', 'REQUEUED', 'jobs-watchdog', at100(5), true],
  [5, 'build-alpha-1', 'APPROVE', 'box-1', at100(6), true],
  [6, 'build-alpha-1', 'REQUEUED', 'operator', at100(2), false],
  [7, 'build-alpha-1', 'REQUEUED', 'operator', `${dayOf(101)}T22:00:00Z`, true],
];
const digestJobs = (db) => insJob(db, 'build-alpha-1', 'alpha', 'BH-1');

const ROUTES_PATH = `/api/model-routes?unrouted_since=${ago(120)}`;
const ROUTE_COSTS = [
  { ts: ago(110), stage: 'foo', project: 'p1', runner: 'codex', arch: true },
  { ts: ago(105), stage: 'Foo', project: 'p1', runner: 'claude', arch: true },
  { ts: ago(10), stage: 'foo', project: 'p1', runner: 'claude' },
  { ts: ago(100), stage: 'foo', project: 'p2', runner: 'claude', arch: true },
  { ts: ago(100), stage: 'bar', project: 'p1', runner: 'claude', arch: true },
  { ts: ago(90), stage: 'baz', project: null, runner: 'grok', arch: true },
  { ts: ago(130), stage: 'qux', project: 'p1', runner: 'claude', arch: true },
];
const routeRows = (db) => { insRoute(db, 'stage.bar'); insRoute(db, 'stage.foo', 'p2'); };

const GAP_DAY = dayOf(30);
const GAP_PATH = `/api/metrics/outcome-gap?day=${GAP_DAY}&lookback=180&days=7&min_usd=5&stages=execute,review`;
const GAP_TO = `${dayOf(29)}T00:00:00Z`;
const GAP_COSTS = [
  { ts: ago(40), project: 'alpha', ticket: 'GA-1', usd: 3, job: 'j-a1' },
  { ts: ago(150), project: 'alpha', ticket: 'GA-1', usd: 4, job: 'j-a0', arch: true },
  { ts: ago(140), project: 'alpha', ticket: 'GA-2', usd: 10, arch: true },
  { ts: ago(140), project: 'alpha', ticket: 'GA-3', usd: 8, stage: 'review', arch: true },
  { ts: ago(45), project: 'bravo', ticket: 'GA-4', usd: 6 },
  { ts: ago(45), project: 'bravo', ticket: 'GA-5', usd: 2 },
  { ts: ago(120), project: 'bravo', ticket: 'GA-5', usd: 1, arch: true },
  { ts: ago(31), project: 'bravo', ticket: 'GA-6', usd: 6 },
  { ts: ago(100), project: 'bravo', ticket: 'GA-7', usd: null, arch: true },
  { ts: ago(50), project: 'bravo', ticket: 'GA-7', usd: null },
  { ts: ago(100), project: 'bravo', ticket: 'GA-8', usd: null, stage: 'plan', arch: true },
];
const gapMerges = (db) => {
  insMerge(db, 'j-ga2', 'alpha', 'GA-2', 'https://github.com/example-org/alpha/pull/2', ago(35));
  insMerge(db, 'j-ga3', 'alpha', 'GA-3', 'https://github.com/example-org/alpha/pull/3', ago(10));
};

const tickets = (b) => b.projects.flatMap((p) => p.tickets.rows.map((r) => `${p.project}/${r.ticket}`)).sort();

// ═════════════════════════════ A: the helper ═════════════════════════════
async function reachEnv({ archRows = null, archive = 'store', fail = null } = {}) {
  let arch = null;
  if (archive === 'store') { arch = await archiveStore(); (archRows || []).forEach((r, i) => insCost(arch, r, i, true)); }
  if (archive === 'no-table') { const { DatabaseSync } = await import('node:sqlite'); arch = new DatabaseSync(':memory:'); }
  const spy = spyArchive(arch, { fail });
  return { env: { DB: d1(await hotStore()), ARCHIVE: spy.binding }, spy };
}
const ARCH_MAX = ago(60);
const ARCH_ROWS = [{ ts: ARCH_MAX }, { ts: ago(90) }];

test('A1: archiveReach answers each decision row with the right archive call count', async (t) => {
  assert.equal(typeof AR.archiveReach, 'function', 'archiveReach is not exported');
  const logs = [];
  t.mock.method(console, 'log', (...a) => logs.push(a.join(' ')));
  const rows = [
    ['a unbound', { archive: 'none' }, ago(120), 'unbound', 0],
    ['b now - 1 h', {}, iso(NOW_MS - 3600e3), 'not-needed', 0],
    ['c now - 24 h (edge)', {}, ago(1), 'not-needed', 0],
    ['d table missing', { archive: 'no-table' }, ago(120), 'not-needed', 1],
    ['e MAX NULL', { archRows: [] }, ago(120), 'not-needed', 1],
    ['f MAX + 1 s', {}, iso(Date.parse(ARCH_MAX) + 1000), 'not-needed', 1],
    ['g MAX (edge)', {}, ARCH_MAX, 'reach', 1],
    ['h MAX - 30 d', {}, iso(Date.parse(ARCH_MAX) - 30 * DAY), 'reach', 1],
    ['i MAX throws', { fail: 'D1_ERROR: overloaded' }, ago(120), 'unreadable', 1],
  ];
  for (const [name, o, since, want, calls] of rows) {
    let env, spy;
    if (o.archive === 'none') ({ env } = { env: { DB: d1(await hotStore()) } });
    else ({ env, spy } = await reachEnv({ archRows: ARCH_ROWS, ...o }));
    assert.equal(await AR.archiveReach(env, { table: 'cost_rows', since, now: NOW }), want, name);
    assert.equal(spy ? spy.calls : 0, calls, `${name}: archive prepare calls`);
    if (calls) assert.match(spy.log[0].sql, /^SELECT MAX\(ts\) AS m FROM cost_rows$/, name);
  }
  assert.ok(logs.some((l) => /overloaded/.test(l)), 'the MAX error is logged');
  // ARCHIVE with no prepare() is unbound too.
  assert.equal(await AR.archiveReach({ DB: null, ARCHIVE: {} }, { table: 'stage_events', since: ago(120), now: NOW }), 'unbound');
  await assert.rejects(() => AR.archiveReach({ ARCHIVE: {} }, { table: 'jobs', since: ago(120), now: NOW }), /no archive time column for jobs/);
});

test('A2: readHistory with a given reach makes no MAX read; reach runs the archive, not-needed makes 0 calls', async () => {
  const q = { sql: 'SELECT COUNT(*) AS n FROM cost_rows WHERE ts >= ?1', binds: [ago(120)] };
  const base = { table: 'cost_rows', since: ago(120), now: NOW, hot: q, method: 'first' };
  {
    const { env, spy } = await reachEnv({ archRows: ARCH_ROWS });
    const r = await AR.readHistory(env, { ...base, reach: 'reach' });
    assert.equal(r.state, 'read');
    assert.equal(r.archive.n, 2);
    assert.equal(spy.calls, 1, 'only the archive read, no MAX');
    assert.ok(!spy.log.some((e) => /MAX\(/.test(e.sql)));
  }
  for (const reach of ['not-needed', 'unbound', 'unreadable']) {
    const { env, spy } = await reachEnv({ archRows: ARCH_ROWS });
    const r = await AR.readHistory(env, { ...base, reach });
    assert.equal(r.state, reach);
    assert.equal(r.archive, null);
    assert.equal(r.hot.n, 0);
    assert.equal(spy.calls, 0, `${reach}: archive calls`);
  }
  // A given reach whose archive read throws is unreadable, the hot answer kept.
  const { env, spy } = await reachEnv({ archRows: ARCH_ROWS, fail: 'D1_ERROR: overloaded' });
  const r = await AR.readHistory(env, { ...base, reach: 'reach' });
  assert.equal(r.state, 'unreadable');
  assert.equal(r.hot.n, 0);
  assert.equal(spy.calls, 1);
});

test('A3: mergeAggregate union joins two comma lists, de-duplicated, empty parts dropped, order kept', () => {
  const u = (a, b) => AR.mergeAggregate({ r: a }, { r: b }, { r: 'union' }).r;
  assert.equal(u('a,b', 'b,c'), 'a,b,c');
  assert.equal(u(null, 'a'), 'a');
  assert.equal(u('', 'a'), 'a');
  assert.equal(u('b,,a', 'a,c,b'), 'b,a,c');
  assert.equal(u(null, null), null);
});

// ═════════════════════════════ O: outcome-gap pure half ═════════════════
const GRACE = '2026-09-10T00:00:00Z';
test('O1: passesHaving passes a sum over min_usd with a first row before grace, the edges included', () => {
  assert.equal(typeof OG.passesHaving, 'function', 'passesHaving is not exported');
  const p = (usd, first_ts) => OG.passesHaving({ usd, first_ts }, { minUsd: 5, grace: GRACE });
  assert.equal(p(5.01, '2026-09-01T00:00:00Z'), true);
  assert.equal(p(100, '2026-09-09T23:59:59Z'), true, 'first_ts 1 s before grace');
});

test('O2: passesHaving fails at min_usd, on a NULL sum, at grace and on a NULL first_ts (SQL NULL rules)', () => {
  assert.equal(typeof OG.passesHaving, 'function', 'passesHaving is not exported');
  assert.equal(OG.passesHaving({ usd: 5, first_ts: '2026-09-01T00:00:00Z' }, { minUsd: 5, grace: GRACE }), false, 'usd = min');
  assert.equal(OG.passesHaving({ usd: null, first_ts: '2026-09-01T00:00:00Z' }, { minUsd: 0, grace: GRACE }), false, 'usd NULL, min 0');
  assert.equal(OG.passesHaving({ usd: 9, first_ts: GRACE }, { minUsd: 5, grace: GRACE }), false, 'first_ts = grace');
  assert.equal(OG.passesHaving({ usd: 9, first_ts: null }, { minUsd: 5, grace: GRACE }), false, 'first_ts NULL');
});

test('O3: the outcome-gap candidate filter keeps unmerged tickets and drops one merged before `to`', async () => {
  assert.equal(typeof OG.gapUnmergedSql, 'function', 'gapUnmergedSql is not exported');
  const db = await hotStore(); gapMerges(db);
  const pairs = [['alpha', 'GA-2'], ['alpha', 'GA-3'], ['alpha', 'GA-9'], ['other', 'GA-2']];
  const kept = db.prepare(OG.gapUnmergedSql()).all(JSON.stringify(pairs), GAP_TO).map((r) => `${r.project}/${r.ticket}`).sort();
  assert.deepEqual(kept, ['alpha/GA-3', 'alpha/GA-9', 'other/GA-2'],
    'GA-2 merged before to is dropped; GA-3 merged after to is kept (edge); a merge in another project does not count');
});

// ═════════════════════════════ R2: same answer ═══════════════════════════
test('R2 lane-spend: lane sums over both stores equal the all-hot answer', async (t) => {
  const w = await world({ costs: LANE_COSTS });
  const want = await ok(t, { DB: d1(w.all) }, LANE_PATH);
  const got = await ok(t, { DB: d1(w.hot), ARCHIVE: spyArchive(w.arch).binding }, LANE_PATH);
  assert.equal(got.archive, 'read');
  for (const lane of LANES) {
    const g = got.lanes.find((l) => l.lane === lane), e = want.lanes.find((l) => l.lane === lane);
    assert.ok(g && e, `${lane} listed`);
    assert.equal(g.calls, e.calls, `${lane}.calls`);
    close(g.today_usd, e.today_usd, `${lane}.today_usd`);
    assert.equal(g.calls, 4, `${lane}: 4 calls on the day, archived ones included`);
  }
});

test('R2 digest: spend and autonomy over both stores equal the all-hot answer', async (t) => {
  const w = await world({ costs: DIGEST_COSTS, events: DIGEST_EVENTS, hotOnly: digestJobs });
  const want = await ok(t, { DB: d1(w.all) }, DIGEST_PATH);
  const got = await ok(t, { DB: d1(w.hot), ARCHIVE: spyArchive(w.arch).binding }, DIGEST_PATH);
  assert.equal(got.spend.ok, true, JSON.stringify(got.spend));
  assert.equal(got.autonomy.ok, true, JSON.stringify(got.autonomy));
  assert.equal(got.spend.archive, 'read');
  assert.equal(got.autonomy.archive, 'read');
  close(got.spend.usd, want.spend.usd, 'spend.usd');
  assert.equal(got.spend.calls, want.spend.calls);
  assert.equal(got.spend.calls, 10);
  assert.equal(got.spend.unpriced_calls, want.spend.unpriced_calls);
  assert.deepEqual(got.spend.top_tickets, want.spend.top_tickets);
  assert.deepEqual(got.spend.top_tickets.rows.map((r) => r.ticket), ['BH-1', 'BH-2', 'BH-3']);
  assert.equal(got.spend.top_tickets.rows[0].job_id, 'j-2');
  assert.equal(got.spend.top_tickets.truncated, true);
  assert.deepEqual(got.autonomy.manual_requeues, want.autonomy.manual_requeues);
  assert.equal(got.autonomy.manual_requeues.n, 4);
  assert.deepEqual(got.autonomy.manual_requeues.rows.map((r) => r.key), ['BH-1', 'build-gone', 'BH-1', 'BH-1']);
  assert.ok(got.autonomy.manual_requeues.rows.every((r) => !('id' in r)), 'no requeue row carries id');
  assert.equal(got.autonomy.human_interventions.by_table.stage_events, want.autonomy.human_interventions.by_table.stage_events);
  assert.equal(got.autonomy.human_interventions.by_table.stage_events, 4);
});

test('R2 model-routes: unrouted stages over both stores equal the all-hot answer', async (t) => {
  const w = await world({ costs: ROUTE_COSTS, hotOnly: routeRows });
  const want = await ok(t, { DB: d1(w.all) }, ROUTES_PATH);
  const got = await ok(t, { DB: d1(w.hot), ARCHIVE: spyArchive(w.arch).binding }, ROUTES_PATH);
  assert.equal(got.unrouted_archive, 'read');
  assert.deepEqual(got.unrouted_stages, want.unrouted_stages);
  assert.deepEqual(got.unrouted_stages.map((s) => s.stage), ['baz', 'foo'], 'bar has a hub rung-0 route');
  const foo = got.unrouted_stages.find((s) => s.stage === 'foo');
  assert.deepEqual(foo.projects, ['p1'], 'p2 has a project rung-0 route');
  assert.equal(foo.calls, 3);
  assert.equal(foo.last_seen, ago(10));
  assert.deepEqual(foo.runners, ['claude', 'codex']);
  assert.equal(got.unrouted_truncated, false);
});

test('R2 outcome-gap: the cohort over both stores equals the all-hot answer', async (t) => {
  const w = await world({ costs: GAP_COSTS, hotOnly: gapMerges });
  const want = await ok(t, { DB: d1(w.all) }, GAP_PATH);
  const got = await ok(t, { DB: d1(w.hot), ARCHIVE: spyArchive(w.arch).binding }, GAP_PATH);
  assert.equal(got.archive, 'read');
  assert.equal(want.archive, 'unbound');
  assert.deepEqual(tickets(got), tickets(want));
  assert.deepEqual(tickets(got), ['alpha/GA-1', 'alpha/GA-3', 'bravo/GA-4'],
    'GA-1 only crosses min_usd combined; GA-2 merged before to; GA-5 sums to 3; GA-6 is inside grace');
  assert.deepEqual(got.projects, want.projects);
  close(got.total_usd, want.total_usd, 'total_usd');
  assert.equal(got.tickets_n, want.tickets_n);
  assert.equal(got.unpriced_calls, want.unpriced_calls);
  assert.equal(got.unpriced_calls, 2);
  assert.equal(got.truncated, false);
});

test('R2 unreadable: an archive that throws gives 200, the hot-only answer and unreadable', async (t) => {
  const bad = () => spyArchive(null, { fail: 'D1_ERROR: overloaded' }).binding;
  t.mock.method(console, 'log', () => {});
  {
    const w = await world({ costs: LANE_COSTS });
    const want = await ok(t, { DB: d1(w.hot) }, LANE_PATH);
    const got = await ok(t, { DB: d1(w.hot), ARCHIVE: bad() }, LANE_PATH);
    assert.equal(got.archive, 'unreadable');
    assert.deepEqual(got.lanes, want.lanes);
  }
  {
    const w = await world({ costs: DIGEST_COSTS, events: DIGEST_EVENTS, hotOnly: digestJobs });
    const want = await ok(t, { DB: d1(w.hot) }, DIGEST_PATH);
    const got = await ok(t, { DB: d1(w.hot), ARCHIVE: bad() }, DIGEST_PATH);
    assert.equal(got.spend.archive, 'unreadable');
    assert.equal(got.autonomy.archive, 'unreadable');
    for (const k of ['usd', 'calls', 'unpriced_calls', 'top_tickets']) assert.deepEqual(got.spend[k], want.spend[k], k);
    assert.deepEqual(got.autonomy.manual_requeues, want.autonomy.manual_requeues);
  }
  {
    const w = await world({ costs: ROUTE_COSTS, hotOnly: routeRows });
    const want = await ok(t, { DB: d1(w.hot) }, ROUTES_PATH);
    const got = await ok(t, { DB: d1(w.hot), ARCHIVE: bad() }, ROUTES_PATH);
    assert.equal(got.unrouted_archive, 'unreadable');
    assert.deepEqual(got.unrouted_stages, want.unrouted_stages);
  }
  {
    const w = await world({ costs: GAP_COSTS, hotOnly: gapMerges });
    const want = await ok(t, { DB: d1(w.hot) }, GAP_PATH);
    const got = await ok(t, { DB: d1(w.hot), ARCHIVE: bad() }, GAP_PATH);
    assert.equal(got.archive, 'unreadable');
    assert.deepEqual(got.projects, want.projects);
    assert.equal(got.unpriced_calls, want.unpriced_calls);
  }
  // The read itself fails after the MAX answered: still the hot answer.
  {
    const w = await world({ costs: GAP_COSTS, hotOnly: gapMerges });
    const want = await ok(t, { DB: d1(w.hot) }, GAP_PATH);
    const inner = d1(w.arch);
    const ARCHIVE = { prepare(sql) { if (!/^SELECT MAX/.test(sql)) throw new Error('D1_ERROR: overloaded'); return inner.prepare(sql); } };
    const got = await ok(t, { DB: d1(w.hot), ARCHIVE }, GAP_PATH);
    assert.equal(got.archive, 'unreadable');
    assert.deepEqual(tickets(got), tickets(want));
    assert.deepEqual(tickets(got), ['bravo/GA-4']);
  }
});

test('R2 truncated (D12): an archive side at its cap marks the answer truncated, even when the merge filters it all out', async (t) => {
  // outcome-gap: 5001 archived groups, none over min_usd. The cohort is empty
  // and the archive side may still lack a ticket that belongs in it.
  {
    const costs = Array.from({ length: OG.GROUP_MAX + 1 }, (_, i) => ({ ts: ago(100), project: 'alpha', ticket: `TR-${i}`, usd: 0.01, arch: true }));
    const w = await world({ costs });
    const b = await ok(t, { DB: d1(w.hot), ARCHIVE: spyArchive(w.arch).binding }, GAP_PATH);
    assert.equal(b.archive, 'read');
    assert.equal(b.tickets_n, 0);
    assert.equal(b.truncated, true);
  }
  // model-routes: 501 archived pairs, every one routed at the hub.
  {
    const costs = Array.from({ length: 501 }, (_, i) => ({ ts: ago(100), stage: `s${i}`, project: 'p1', arch: true }));
    const w = await world({ costs, hotOnly: (db) => { for (let i = 0; i < 501; i++) insRoute(db, `stage.s${i}`); } });
    const b = await ok(t, { DB: d1(w.hot), ARCHIVE: spyArchive(w.arch).binding }, ROUTES_PATH);
    assert.equal(b.unrouted_archive, 'read');
    assert.deepEqual(b.unrouted_stages, []);
    assert.equal(b.unrouted_truncated, true);
  }
});

// ═════════════════════════════ R3: no archive on poll paths ══════════════
test('R3: the poll paths and today\'s reads make 0 archive prepare calls', async (t) => {
  const w = await world({ costs: [...LANE_COSTS, ...ROUTE_COSTS, { ts: ago(0, -2), stage: 'foo', project: 'p1', lane: LANES[0] }] });
  for (const path of [
    '/api/metrics/lane-spend',
    `/api/metrics/daily-digest?day=${dayOf(0)}`,
    '/api/model-routes',
    `/api/model-routes?unrouted_since=${iso(NOW_MS - 3600e3)}`,
  ]) {
    const spy = spyArchive(w.arch);
    await ok(t, { DB: d1(w.hot), ARCHIVE: spy.binding }, path);
    assert.equal(spy.calls, 0, `${path} made ${spy.calls} archive calls`);
  }
  // The shortest legal outcome-gap window (lookback=2) starts 36 h back, past
  // the 1-day floor: one MAX read, and no data read when nothing that new is
  // archived.
  const spy = spyArchive(w.arch);
  const b = await ok(t, { DB: d1(w.hot), ARCHIVE: spy.binding }, `/api/metrics/outcome-gap?day=${dayOf(0)}&lookback=2&days=1&stages=execute`);
  assert.equal(b.archive, 'not-needed');
  assert.equal(spy.calls, 1);
  assert.match(spy.log[0].sql, /^SELECT MAX\(ts\)/);
});

// ═════════════════════════════ R4: ARCHIVE unbound ═══════════════════════
// The pre-change SQL, verbatim, run on the same store.
const OLD_REQ = `SELECT j.project AS project, COALESCE(j.ticket_id, s.job_id) AS key, s.verdict AS verdict,
            s.actor AS actor, s.created_at AS at
       FROM stage_events s LEFT JOIN jobs j ON j.id=s.job_id
      WHERE s.verdict IN ('REQUEUED','RELEASED','DROPPED') AND s.actor IS NOT NULL
        AND TRIM(s.actor)<>'' AND LOWER(TRIM(s.actor))<>'jobs-watchdog'
        AND s.created_at>=?1 AND s.created_at<?2
      ORDER BY s.created_at DESC, s.id DESC LIMIT ?3`;
const OLD_UNROUTED = `SELECT lower(c.stage) AS stage, c.project AS project, count(*) AS calls
         FROM cost_rows c
        WHERE c.ts >= ?1 AND c.stage IS NOT NULL AND c.stage <> ''
          AND NOT EXISTS (SELECT 1 FROM model_routes m
                           WHERE m.role = 'stage.' || lower(c.stage) AND m.position = 0
                             AND (m.project IS NULL OR m.project = c.project))
        GROUP BY lower(c.stage), c.project ORDER BY lower(c.stage), c.project`;

test('R4: with ARCHIVE unbound each ported route answers from the hot store as before', async (t) => {
  {
    const w = await world({ costs: LANE_COSTS });
    const b = await ok(t, { DB: d1(w.all) }, LANE_PATH);
    assert.equal(b.archive, 'unbound');
    for (const lane of LANES) {
      const e = w.all.prepare('SELECT COUNT(*) AS calls, SUM(COALESCE(cost_usd,0)) AS usd FROM cost_rows WHERE lane_id=?1 AND ts>=?2 AND ts<?3')
        .get(lane, `${D100}T00:00:00Z`, `${dayOf(99)}T00:00:00Z`);
      const g = b.lanes.find((l) => l.lane === lane);
      assert.equal(g.calls, e.calls); close(g.today_usd, Math.round(e.usd * 100) / 100, lane);
    }
  }
  {
    const w = await world({ costs: DIGEST_COSTS, events: DIGEST_EVENTS, hotOnly: digestJobs });
    const b = await ok(t, { DB: d1(w.all) }, DIGEST_PATH);
    assert.equal(b.spend.archive, 'unbound');
    assert.equal(b.autonomy.archive, 'unbound');
    const tot = w.all.prepare('SELECT COUNT(*) AS calls, SUM(cost_usd) AS usd FROM cost_rows WHERE ts>=?1 AND ts<?2').get(`${D100}T00:00:00Z`, `${dayOf(99)}T00:00:00Z`);
    assert.equal(b.spend.calls, tot.calls); close(b.spend.usd, tot.usd, 'spend.usd');
    const req = w.all.prepare(OLD_REQ).all(`${D100}T00:00:00Z`, `${dayOf(99)}T00:00:00Z`, 21).map((r) => ({ ...r }));
    assert.deepEqual(b.autonomy.manual_requeues.rows, req);
  }
  {
    const w = await world({ costs: ROUTE_COSTS, hotOnly: routeRows });
    const b = await ok(t, { DB: d1(w.all) }, ROUTES_PATH);
    assert.equal(b.unrouted_archive, 'unbound');
    const old = w.all.prepare(OLD_UNROUTED).all(ago(120));
    assert.deepEqual(b.unrouted_stages.map((s) => [s.stage, s.calls]), [...new Set(old.map((r) => r.stage))]
      .map((s) => [s, old.filter((r) => r.stage === s).reduce((n, r) => n + r.calls, 0)]));
  }
  {
    const w = await world({ costs: GAP_COSTS, hotOnly: gapMerges });
    const b = await ok(t, { DB: d1(w.all) }, GAP_PATH);
    assert.equal(b.archive, 'unbound');
    const rows = w.all.prepare(OG.gapSql(2)).all(b.from, b.to, 5, `${dayOf(36)}T00:00:00Z`, 'execute', 'review', 5001);
    assert.deepEqual(tickets(b), rows.map((r) => `${r.project}/${r.ticket}`).sort());
  }
});

// ═════════════════════════════ R6: new statements use an index ══════════
const scansOf = (db, e) => db.prepare(`EXPLAIN QUERY PLAN ${e.sql}`).all(...e.binds.map((v) => (v === undefined ? null : v)))
  .map((x) => x.detail);

test('R6: every archive read and every new hot statement uses an index at live volume', async (t) => {
  const arch = await archiveStore();
  const nCost = LIVE.cost_rows, nEv = 50000;
  arch.exec('BEGIN');
  const c = arch.prepare(`INSERT INTO cost_rows (box, row_hash, line_no, ts, project, stage, runner, ticket, lane_id, cost_usd, inserted_at, archived_at)
                          VALUES (?,?,?,?,?,?,?,?,?,?,?,?)`);
  for (let i = 0; i < nCost; i++) {
    const ts = iso(NOW_MS - 30 * DAY - Math.floor((i / nCost) * 300 * DAY));
    c.run(`box-${i % 9}`, `a${i}`, i, ts, ['alpha', 'bravo'][i % 2], ['execute', 'foo', 'plan'][i % 3], 'claude',
      `T-${i % 700}`, LANES[i % 3], i % 7 ? 0.01 : null, ts, NOW);
  }
  const ev = arch.prepare('INSERT INTO stage_events (id, job_id, stage, verdict, actor, created_at, archived_at) VALUES (?,?,?,?,?,?,?)');
  for (let i = 0; i < nEv; i++) {
    ev.run(i + 1, `job-${i % 4000}`, 'plan', i % 5 ? 'APPROVE' : 'REQUEUED', 'operator', iso(NOW_MS - 400 * DAY + Math.floor((i / nEv) * 300 * DAY)), NOW);
  }
  arch.exec('COMMIT');
  const hot = await hotStore();
  hot.exec('BEGIN');
  for (let i = 0; i < 5000; i++) {
    insMerge(hot, `job-${i}`, ['alpha', 'bravo'][i % 2], `T-${i % 700}`, `https://github.com/example-org/r/pull/${i}`, ago(200 - (i % 100)));
  }
  for (let i = 0; i < 200; i++) insRoute(hot, `stage.s${i}`, i % 2 ? `p${i}` : null);
  hot.exec('COMMIT');
  const aSpy = spyArchive(arch), hSpy = spyArchive(hot);
  const env = { DB: hSpy.binding, ARCHIVE: aSpy.binding };
  const day = dayOf(100);
  const paths = [
    [`/api/metrics/lane-spend?day=${day}`, (b) => b.archive],
    [`/api/metrics/daily-digest?day=${dayOf(200)}&human=operator`, (b) => b.spend.archive === 'read' && b.autonomy.archive === 'read' ? 'read' : `${b.spend.archive}/${b.autonomy.archive}`],
    [`/api/model-routes?unrouted_since=${ago(200)}`, (b) => b.unrouted_archive],
    [`/api/metrics/outcome-gap?day=${dayOf(31)}&lookback=180&days=7&min_usd=0&stages=execute,foo`, (b) => b.archive],
  ];
  for (const [path, state] of paths) assert.equal(state(await ok(t, env, path)), 'read', path);
  const reads = aSpy.log.filter((e) => !/^SELECT MAX\(/.test(e.sql));
  assert.ok(reads.length >= 9, `captured ${reads.length} archive reads`);
  const SCAN = /^SCAN (?!v\b|json_each\b|CONSTANT ROW)/;
  for (const e of aSpy.log) {
    const lines = scansOf(arch, e);
    assert.deepEqual(lines.filter((l) => SCAN.test(l)), [], `full scan on the archive:\n  ${e.sql}\n  ${lines.join('\n  ')}`);
  }
  // The new hot statements: each reads a json_each list of archive keys.
  const fresh = hSpy.log.filter((e) => /json_each\(\?1\)/.test(e.sql));
  assert.ok(fresh.length >= 3, `captured ${fresh.length} new hot statements`);
  for (const e of fresh) {
    const lines = scansOf(hot, e);
    assert.deepEqual(lines.filter((l) => SCAN.test(l)), [], `full scan on the hot store:\n  ${e.sql}\n  ${lines.join('\n  ')}`);
  }
});
