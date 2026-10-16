// BH-7059 (slice C0): the five routes/cost.js history readers that #6777
// does not touch read the archive store too, through lib/archive-read.js:
// GET /api/metrics/llm-spend (the lane statement and the aggregate) and
// GET /api/metrics/cost-anchored (rowSums and the span sums).
//
// Every case drives the REAL worker.fetch over a hot node:sqlite D1 and an
// archive node:sqlite D1 in #6777's archive shape (the hot columns,
// archived_at, the hot key as primary key, idx_cost_rows_ts). The fixtures are
// this file's own copy of the bh-7035 ones; the clock is pinned (D60).
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import {
  parseAccountMap, anchorWindow, meterAccounts, anchorSpanCandidates, computeAnchored,
} from '../src/lib/core.js';
import { openDb, d1 } from './lib/d1-sqlite.bh-1030.js';
import { LIVE } from './lib/d1-volume.bh-6727.js';

const SECRET = 'test-secret-fixture';
const NOW_MS = Date.parse('2026-10-16T12:00:00Z');
const DAY = 86400e3;
const iso = (ms) => new Date(ms).toISOString().replace(/\.\d{3}Z$/, 'Z');
const ago = (days, h = 0) => iso(NOW_MS - days * DAY + h * 3600e3);
const dayOf = (days) => iso(NOW_MS - days * DAY).slice(0, 10);
const NOW = iso(NOW_MS);
const TODAY0 = `${dayOf(0)}T00:00:00Z`;

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
  const cols = hot.prepare('PRAGMA table_info(cost_rows)').all().map((c) => `${c.name} ${c.type || ''}`.trim());
  db.exec(`CREATE TABLE cost_rows (${cols.join(', ')}, archived_at TEXT NOT NULL, PRIMARY KEY (box, row_hash))`);
  db.exec('CREATE INDEX idx_cost_rows_ts ON cost_rows(ts)');
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
const maxReads = (spy) => spy.log.filter((e) => /^SELECT MAX\(ts\)/.test(e.sql)).length;

// ── fixtures ──────────────────────────────────────────────────────────────
// A cost row spec: { ts, usd, box, account, stage, project, lane, source, arch }.
// `arch` puts it in the archive in the split world; the all-hot world holds
// every row in the hot store. The row index is the row_hash, so a row has the
// same key in both worlds.
function insCost(db, r, i, archived = false) {
  const row = {
    box: r.box ?? 'box-1', row_hash: `h${i}`, line_no: i + 1, ts: r.ts, project: r.project ?? null,
    stage: r.stage ?? 'build', runner: 'claude', auth_account: r.account ?? null,
    cost_usd: r.usd === undefined ? 0.5 : r.usd, lane_id: r.lane ?? null, row_source: r.source ?? null,
    inserted_at: r.ts, ...(archived ? { archived_at: NOW } : {}),
  };
  const cols = Object.keys(row);
  db.prepare(`INSERT INTO cost_rows (${cols.join(',')}) VALUES (${cols.map(() => '?').join(',')})`).run(...Object.values(row));
}
function insSnap(db, box, ts, used) {
  db.prepare(`INSERT INTO extra_usage_snapshots (box, ts, weekly_pct, extra_enabled, extra_used_usd, spend_limit_reached)
              VALUES (?, ?, 100, 1, ?, 0)`).run(box, ts, used);
}

// world({ costs, hotOnly }) -> { all, hot, arch }. hotOnly(db) seeds the
// hot-only tables in BOTH hot stores.
async function world({ costs = [], hotOnly = () => {} } = {}) {
  const all = await hotStore(), hot = await hotStore(), arch = await archiveStore();
  costs.forEach((r, i) => { insCost(all, r, i); insCost(r.arch ? arch : hot, r, i, !!r.arch); });
  hotOnly(all); hotOnly(hot);
  return { all, hot, arch };
}

// ── the real worker ──────────────────────────────────────────────────────
const pinned = new WeakSet();
async function ok(t, env, path) {
  if (!pinned.has(t)) { t.mock.timers.enable({ apis: ['Date'], now: NOW_MS }); pinned.add(t); }
  const res = await worker.fetch(new Request(`https://jobs.test${path}`, {
    headers: { authorization: `Bearer ${SECRET}` },
  }), { HARNESS_SECRET: SECRET, ...env });
  const body = await res.json().catch(() => null);
  assert.equal(res.status, 200, `${path}: ${JSON.stringify(body)}`);
  return body;
}

// ── llm-spend world ──────────────────────────────────────────────────────
// 6 rows of stage build on lane L: 4 of them 100 days ago and archived (one
// refused, one settled), 2 hot today. One row of lane M, archived. One
// unstamped (lane_id NULL) build row, archived: the lane+stage statement
// counts it, the lane-only statement does not.
const LANE_L = 'lane-l', LANE_M = 'lane-m';
const SPEND_COSTS = [
  { ts: ago(100), lane: LANE_L, usd: 1.25, arch: true },
  { ts: ago(100, 1), lane: LANE_L, usd: 0, source: 'refused', arch: true },
  { ts: ago(100, 2), lane: LANE_L, usd: 0, source: 'settled', arch: true },
  { ts: ago(99), lane: LANE_L, usd: 2.5, arch: true },
  { ts: ago(0, -2), lane: LANE_L, usd: 0.75 },
  { ts: ago(0, -1), lane: LANE_L, usd: null },
  { ts: ago(98), lane: LANE_M, usd: 4, arch: true },
  { ts: ago(97), lane: null, usd: 8, arch: true },
];
const SINCE110 = ago(110);
const SPEND_PATHS = [
  `/api/metrics/llm-spend?stage=build&lane=${LANE_L}&since=${SINCE110}`,
  `/api/metrics/llm-spend?lane=${LANE_L}&since=${SINCE110}`,
  `/api/metrics/llm-spend?stage=build&since=${SINCE110}`,
];
const SPEND_KEYS = ['usd', 'calls', 'refused', 'settled'];

// ── cost-anchored world ──────────────────────────────────────────────────
// One metered account (meter-box -> acct-a) fully in overage on D100 with
// three polls; cost rows for 2 boxes and 2 accounts on that day, half
// archived; one archived row the day before (out of the window).
const D100 = dayOf(100);
const at100 = (h) => `${D100}T${String(h).padStart(2, '0')}:00:00Z`;
const ANCHOR_ENV = { COST_ANCHOR_ACCOUNT_MAP: 'meter-box=acct-a' };
const ANCHOR_PATH = `/api/metrics/cost-anchored?day=${D100}`;
const ANCHOR_COSTS = [
  { ts: at100(2), box: 'box-1', account: 'acct-a', usd: 1, arch: true },
  { ts: at100(3), box: 'box-1', account: 'acct-a', usd: 2 },
  { ts: at100(4), box: 'box-2', account: 'acct-a', usd: 3, arch: true },
  { ts: at100(5), box: 'box-2', account: 'acct-b', usd: 0.5 },
  { ts: at100(6), box: 'box-1', account: 'acct-b', usd: 0.25, arch: true },
  { ts: at100(7), box: 'box-2', account: 'acct-a', usd: 4 },
  { ts: at100(23), box: 'box-1', account: 'acct-a', usd: 16, arch: true },
  { ts: `${dayOf(101)}T23:00:00Z`, box: 'box-1', account: 'acct-a', usd: 64, arch: true },
];
const anchorSnaps = (db) => {
  insSnap(db, 'meter-box', at100(1), 10);
  insSnap(db, 'meter-box', at100(8), 15);
  insSnap(db, 'meter-box', at100(12), 30);
};
const anchorView = (b) => ({ accounts: b.accounts, per_box: b.per_box, totals: b.totals });

// ═════════════════════════════ R2: same answer ═══════════════════════════
test('R2 llm-spend: lane and aggregate sums over both stores equal the all-hot answer', async (t) => {
  const w = await world({ costs: SPEND_COSTS });
  for (const path of SPEND_PATHS) {
    const want = await ok(t, { DB: d1(w.all) }, path);
    const spy = spyArchive(w.arch);
    const got = await ok(t, { DB: d1(w.hot), ARCHIVE: spy.binding }, path);
    assert.equal(got.archive, 'read', path);
    for (const k of SPEND_KEYS) assert.equal(got[k], want[k], `${path} ${k}`);
    assert.equal(spy.calls, 2, `${path}: 1 MAX + 1 aggregate`);
  }
  // The fixture is not vacuous: the archive holds most of each answer.
  const lane = await ok(t, { DB: d1(w.all) }, SPEND_PATHS[0]);
  assert.deepEqual(SPEND_KEYS.map((k) => lane[k]), [12.5, 7, 1, 1]);
  const laneOnly = await ok(t, { DB: d1(w.all) }, SPEND_PATHS[1]);
  assert.deepEqual(SPEND_KEYS.map((k) => laneOnly[k]), [4.5, 6, 1, 1]);
  const agg = await ok(t, { DB: d1(w.all) }, SPEND_PATHS[2]);
  assert.deepEqual(SPEND_KEYS.map((k) => agg[k]), [16.5, 8, 1, 1]);
});

test('R2 cost-anchored: accounts, per_box and totals over both stores equal the all-hot answer', async (t) => {
  const w = await world({ costs: ANCHOR_COSTS, hotOnly: anchorSnaps });
  const want = await ok(t, { DB: d1(w.all), ...ANCHOR_ENV }, ANCHOR_PATH);
  const spy = spyArchive(w.arch);
  const got = await ok(t, { DB: d1(w.hot), ARCHIVE: spy.binding, ...ANCHOR_ENV }, ANCHOR_PATH);
  assert.equal(got.archive, 'read');
  assert.deepEqual(anchorView(got), anchorView(want));
  assert.equal(maxReads(spy), 1, 'the span reads reuse the rowSums reach');
  // 1 MAX + 1 rowSums + 1 span (one candidate account).
  assert.equal(spy.calls, 3);
  // Not vacuous: acct-a's span sum (01:00-12:00) is 1+2+3+4 = 10, 4 of it archived.
  const a = want.accounts.find((x) => x.label === 'acct-a');
  assert.ok(a, `acct-a listed: ${JSON.stringify(want.accounts)}`);
  assert.equal(a.state, 'metered', JSON.stringify(a));
  assert.equal(a.rows_usd_span, 10, JSON.stringify(a));
  assert.equal(a.rows_usd, 26, JSON.stringify(a));
});

// ═════════════════════════════ R3: 0 archive calls ═══════════════════════
test('R3: the gate paths, today\'s reads and the 24h window make 0 archive prepare calls', async (t) => {
  const w = await world({ costs: [...SPEND_COSTS, ...ANCHOR_COSTS], hotOnly: anchorSnaps });
  for (const path of [
    `/api/metrics/llm-spend?stage=build&since=${TODAY0}`,
    `/api/metrics/llm-spend?lane=${LANE_L}`,
    `/api/metrics/llm-spend?lane=${LANE_L}&stage=build`,
    '/api/metrics/llm-spend?project=p&stage=s',
    `/api/metrics/llm-spend?stage=build&since=${ago(1)}`,
    '/api/metrics/cost-anchored',
    '/api/metrics/cost-anchored?window=24h',
  ]) {
    const spy = spyArchive(w.arch);
    const b = await ok(t, { DB: d1(w.hot), ARCHIVE: spy.binding, ...ANCHOR_ENV }, path);
    assert.equal(spy.calls, 0, `${path} made ${spy.calls} archive calls`);
    assert.equal(b.archive, 'not-needed', path);
  }
});

// ═════════════════════════════ R4: ARCHIVE unbound ═══════════════════════
// The pre-change SQL, verbatim, run on the same store.
const OLD_LANE_STAGE = "SELECT SUM(COALESCE(cost_usd,0)) AS usd, COUNT(*) AS calls," +
  " SUM(CASE WHEN row_source='refused' THEN 1 ELSE 0 END) AS refused," +
  " SUM(CASE WHEN row_source='settled' THEN 1 ELSE 0 END) AS settled" +
  " FROM cost_rows WHERE stage=?4 AND ts>=?1 AND (?2 IS NULL OR ts<=?2)" +
  " AND (?5 IS NULL OR project=?5) AND (lane_id=?3 OR lane_id IS NULL)";
const OLD_AGG = `SELECT SUM(COALESCE(cost_usd,0)) AS usd, COUNT(*) AS calls,
                SUM(CASE WHEN row_source='refused' THEN 1 ELSE 0 END) AS refused,
                SUM(CASE WHEN row_source='settled' THEN 1 ELSE 0 END) AS settled
           FROM cost_rows WHERE stage=?1 AND ts>=?2`;
const OLD_ROWSUMS = `SELECT box, auth_account AS account, SUM(COALESCE(cost_usd,0)) AS usd, COUNT(*) AS calls
             FROM cost_rows WHERE ts>=?1 AND ts<?2
            GROUP BY box, auth_account LIMIT 500`;
const OLD_SPAN = `SELECT SUM(COALESCE(cost_usd,0)) AS usd FROM cost_rows
          WHERE auth_account=?1 AND ts>=?2 AND ts<=?3`;

test('R4: with ARCHIVE unbound both routes answer from the hot store as main did', async (t) => {
  const w = await world({ costs: [...SPEND_COSTS, ...ANCHOR_COSTS], hotOnly: anchorSnaps });
  {
    const b = await ok(t, { DB: d1(w.all) }, SPEND_PATHS[0]);
    assert.equal(b.archive, 'unbound');
    const e = w.all.prepare(OLD_LANE_STAGE).get(SINCE110, null, LANE_L, 'build', null);
    assert.deepEqual(SPEND_KEYS.map((k) => b[k]), SPEND_KEYS.map((k) => Number(e[k] || 0)));
  }
  {
    const b = await ok(t, { DB: d1(w.all) }, SPEND_PATHS[2]);
    assert.equal(b.archive, 'unbound');
    const e = w.all.prepare(OLD_AGG).get('build', SINCE110);
    assert.deepEqual(SPEND_KEYS.map((k) => b[k]), SPEND_KEYS.map((k) => Number(e[k] || 0)));
  }
  {
    const b = await ok(t, { DB: d1(w.all), ...ANCHOR_ENV }, ANCHOR_PATH);
    assert.equal(b.archive, 'unbound');
    // main's handler, its reads verbatim, on the same rows.
    const win = anchorWindow({ day: D100, now: NOW_MS });
    const accountMap = parseAccountMap(ANCHOR_ENV.COST_ANCHOR_ACCOUNT_MAP);
    const snaps = w.all.prepare('SELECT * FROM extra_usage_snapshots WHERE ts>=?1 AND ts<?2 ORDER BY ts ASC').all(win.from, win.to);
    const meters = meterAccounts({ snapshots: snaps, accountMap, from: win.from, to: win.to });
    const spanSums = {};
    for (const m of anchorSpanCandidates(meters)) spanSums[m.label] = w.all.prepare(OLD_SPAN).get(m.label, m.span_from, m.span_to).usd || 0;
    const want = computeAnchored({
      ...win, meters, spanSums, rowSums: w.all.prepare(OLD_ROWSUMS).all(win.from, win.to),
      prCosts: [], merges: [], maxFactor: b.max_factor, limit: 500, prCostsCap: 3000,
    });
    assert.deepEqual(anchorView(b), anchorView(want));
  }
});

// ═════════════════════════════ R5u: unreadable ═══════════════════════════
test('R5u: an archive that throws gives 200, the hot-only sums and unreadable', async (t) => {
  t.mock.method(console, 'log', () => {});
  const bad = () => spyArchive(null, { fail: 'D1_ERROR: overloaded' }).binding;
  const w = await world({ costs: [...SPEND_COSTS, ...ANCHOR_COSTS], hotOnly: anchorSnaps });
  for (const path of SPEND_PATHS) {
    const want = await ok(t, { DB: d1(w.hot) }, path);
    const got = await ok(t, { DB: d1(w.hot), ARCHIVE: bad() }, path);
    assert.equal(got.archive, 'unreadable', path);
    for (const k of SPEND_KEYS) assert.equal(got[k], want[k], `${path} ${k}`);
  }
  {
    const want = await ok(t, { DB: d1(w.hot), ...ANCHOR_ENV }, ANCHOR_PATH);
    const got = await ok(t, { DB: d1(w.hot), ARCHIVE: bad(), ...ANCHOR_ENV }, ANCHOR_PATH);
    assert.equal(got.archive, 'unreadable');
    assert.deepEqual(anchorView(got), anchorView(want));
  }
  // The MAX answers, then the data reads fail: still the hot answer, unreadable.
  {
    const want = await ok(t, { DB: d1(w.hot), ...ANCHOR_ENV }, ANCHOR_PATH);
    const inner = d1(w.arch);
    const ARCHIVE = { prepare(sql) { if (!/^SELECT MAX/.test(sql)) throw new Error('D1_ERROR: overloaded'); return inner.prepare(sql); } };
    const got = await ok(t, { DB: d1(w.hot), ARCHIVE, ...ANCHOR_ENV }, ANCHOR_PATH);
    assert.equal(got.archive, 'unreadable');
    assert.deepEqual(anchorView(got), anchorView(want));
  }
  // Only the span read fails: the response still says unreadable.
  {
    const inner = d1(w.arch);
    const ARCHIVE = { prepare(sql) { if (/auth_account=\?1/.test(sql)) throw new Error('D1_ERROR: overloaded'); return inner.prepare(sql); } };
    const got = await ok(t, { DB: d1(w.hot), ARCHIVE, ...ANCHOR_ENV }, ANCHOR_PATH);
    assert.equal(got.archive, 'unreadable');
  }
});

// ═════════════════════════════ R6: archive reads use an index ═════════════
test('R6: every archive statement of the R2 paths uses idx_cost_rows_ts at live volume', async (t) => {
  const arch = await archiveStore();
  const n = LIVE.cost_rows;
  arch.exec('BEGIN');
  const c = arch.prepare(`INSERT INTO cost_rows (box, row_hash, line_no, ts, project, stage, runner, auth_account, lane_id, row_source, cost_usd, inserted_at, archived_at)
                          VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)`);
  for (let i = 0; i < n; i++) {
    const ts = iso(NOW_MS - 30 * DAY - Math.floor((i / n) * 300 * DAY));
    c.run(`box-${i % 9}`, `a${i}`, i, ts, ['alpha', 'bravo'][i % 2], ['build', 'execute', 'plan'][i % 3], 'claude',
      ['acct-a', 'acct-b'][i % 2], [LANE_L, LANE_M, null][i % 3], i % 11 ? null : 'refused', i % 7 ? 0.01 : null, ts, NOW);
  }
  arch.exec('COMMIT');
  const hot = await hotStore();
  anchorSnaps(hot);
  const spy = spyArchive(arch);
  const env = { DB: d1(hot), ARCHIVE: spy.binding, ...ANCHOR_ENV };
  for (const path of [...SPEND_PATHS, ANCHOR_PATH]) assert.equal((await ok(t, env, path)).archive, 'read', path);
  const reads = spy.log.filter((e) => !/^SELECT MAX\(/.test(e.sql));
  assert.equal(reads.length, 5, `3 llm-spend reads + rowSums + 1 span; got ${reads.length}`);
  for (const e of spy.log) {
    const lines = arch.prepare(`EXPLAIN QUERY PLAN ${e.sql}`).all(...e.binds.map((v) => (v === undefined ? null : v))).map((x) => x.detail);
    assert.ok(lines.some((l) => /USING (COVERING )?INDEX idx_cost_rows_ts/.test(l)), `no idx_cost_rows_ts:\n  ${e.sql}\n  ${lines.join('\n  ')}`);
    assert.deepEqual(lines.filter((l) => /^SCAN cost_rows/.test(l)), [], `full scan on the archive:\n  ${e.sql}\n  ${lines.join('\n  ')}`);
  }
});
