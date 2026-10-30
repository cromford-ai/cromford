// BH-6779 (slice C0): the history readers read the archive store too.
//
// H1-H8 drive lib/archive-read.js directly. R1 holds the reader inventory
// (test/archive-readers.d/*.json) against the source. R2, R3, R4 and R6 drive
// the REAL worker.fetch over a hot node:sqlite D1 and an archive node:sqlite
// D1. The archive tables copy #6777's archive shape by hand (the hot columns,
// archived_at, the hot key as primary key, idx_<table>_<time>), because
// ensureArchiveTable is not on main yet. The clock is pinned (D60).
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join, relative } from 'node:path';
import worker from '../src/index.js';
import { openDb, d1 } from './lib/d1-sqlite.bh-1030.js';
import { LIVE } from './lib/d1-volume.bh-6727.js';

// Loaded by dynamic import so the R cases still run (and fail on their own)
// when the helper does not exist yet.
const AR = await import('../src/lib/archive-read.js').catch(() => null);

const HERE = dirname(fileURLToPath(import.meta.url));
const WORKER = join(HERE, '..');
const SECRET = 'test-secret-fixture';
const NOW_MS = Date.parse('2026-10-15T12:00:00Z');
const DAY = 86400e3;
const iso = (ms) => new Date(ms).toISOString().replace(/\.\d{3}Z$/, 'Z');
const ago = (days) => iso(NOW_MS - days * DAY);
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

// The archive binding with a spy: every prepare() is counted and logged with
// the binds it ran. `fail` makes prepare throw (an unreadable archive).
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
  };
  return spy;
}

// ── cost_rows fixture: 40 rows over 120 days ─────────────────────────────
const COST_COLS = ['box', 'row_hash', 'line_no', 'ts', 'project', 'stage', 'runner', 'model', 'billing_mode',
  'ticket', 'run_id', 'job_id', 'cost_usd', 'input_toks', 'output_toks', 'cache_read', 'cache_write', 'inserted_at'];
const PROJECTS = ['alpha', 'bravo', null];
const COSTS = Array.from({ length: 40 }, (_, i) => {
  const ts = iso(NOW_MS - i * 3 * DAY - 3600e3);
  return [`box-${i % 3}`, `h${i}`, i + 1, ts, PROJECTS[i % 3], ['plan', 'execute', 'review'][i % 3], 'claude',
    i % 4 ? 'm-a' : 'm-b', ['metered', 'subscription', null][i % 3], i % 5 ? `BH-${i % 7}` : null,
    `run-${i}`, `job-${i}`, i % 6 === 5 ? null : 0.25 * (i + 1), 100 + i, 10 + i, 1000 + i, i, ts];
});
const insCost = (db, rows, archived = false) => {
  const cols = archived ? [...COST_COLS, 'archived_at'] : COST_COLS;
  const st = db.prepare(`INSERT INTO cost_rows (${cols.join(',')}) VALUES (${cols.map(() => '?').join(',')})`);
  for (const r of rows) st.run(...(archived ? [...r, NOW] : r));
};
// The 25 oldest rows (index 15..39, 45 to 117 days old) are archived.
// `dup` leaves one of them in hot as well (copied, not yet deleted).
async function costSplit({ dup = false } = {}) {
  const all = await hotStore(); insCost(all, COSTS);
  const hot = await hotStore(); insCost(hot, COSTS.slice(0, 15));
  if (dup) insCost(hot, [COSTS[20]]);
  const arch = await archiveStore(); insCost(arch, COSTS.slice(15), true);
  return { all, hot, arch };
}

// ── stage_events fixture: a job created 200 days ago, 30 events ──────────
const JOB_OLD = 'build-alpha-old', JOB_NEW = 'build-alpha-new';
function insJob(db, id, created) {
  db.prepare(`INSERT INTO jobs (id, project, ticket_id, kind, box, stage, status, created_at, updated_at)
              VALUES (?,?,?,?,?,?,?,?,?)`).run(id, 'alpha', 'BH-1', 'build', 'box-1', 'done', 'done', created, created);
}
const EVENTS = Array.from({ length: 30 }, (_, i) =>
  [i + 1, JOB_OLD, ['plan', 'execute', 'review'][i % 3], i % 2 ? 'APPROVE' : null, 'box-1', `d${i}`, ago(200 - i * 5)]);
const OTHER = Array.from({ length: 6 }, (_, i) => [100 + i, 'build-bravo-x', 'plan', null, 'box-2', 'x', ago(190 - i)]);
const insEv = (db, rows, archived = false) => {
  const cols = ['id', 'job_id', 'stage', 'verdict', 'actor', 'detail', 'created_at', ...(archived ? ['archived_at'] : [])];
  const st = db.prepare(`INSERT INTO stage_events (${cols.join(',')}) VALUES (${cols.map(() => '?').join(',')})`);
  for (const r of rows) st.run(...(archived ? [...r, NOW] : r));
};
async function eventSplit() {
  const all = await hotStore(); insJob(all, JOB_OLD, ago(200)); insEv(all, [...EVENTS, ...OTHER]);
  const hot = await hotStore(); insJob(hot, JOB_OLD, ago(200)); insEv(hot, EVENTS.slice(20));
  const arch = await archiveStore(); insEv(arch, [...EVENTS.slice(0, 20), ...OTHER], true);
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
const groupKey = (g, by) => JSON.stringify(by.map((d) => g[d]));
function sameGroups(got, want, by, msg) {
  assert.equal(got.length, want.length, `${msg}: group count`);
  const w = new Map(want.map((g) => [groupKey(g, by), g]));
  got.forEach((g, i) => {
    const e = w.get(groupKey(g, by));
    assert.ok(e, `${msg}: unexpected group ${groupKey(g, by)}`);
    for (const k of ['calls', 'unpriced_calls', 'last_ts', 'last_run_id', 'last_job_id', 'last_project']) {
      assert.equal(g[k], e[k], `${msg}: ${groupKey(g, by)}.${k}`);
    }
    for (const k of ['usd', 'cash_usd', 'equiv_usd']) close(g[k], e[k], `${msg}: ${groupKey(g, by)}.${k}`);
    assert.equal(groupKey(g, by), groupKey(want[i], by), `${msg}: order at ${i}`);
  });
}
function sameTotal(got, want, msg) {
  for (const k of ['calls', 'unpriced_calls']) assert.equal(got[k], want[k], `${msg}: total.${k}`);
  for (const k of ['usd', 'cash_usd', 'equiv_usd']) close(got[k], want[k], `${msg}: total.${k}`);
}

// ═════════════════════════════ H: the helper ═════════════════════════════
const HOT_Q = { sql: 'SELECT COUNT(*) AS n, SUM(cost_usd) AS usd FROM cost_rows WHERE ts >= ?1', binds: [] };
async function decide(env, since, opts = {}) {
  return AR.readHistory(env, { table: 'cost_rows', since, now: NOW, method: 'first',
    hot: { ...HOT_Q, binds: [since] }, ...opts });
}
async function helperEnv({ archRows = null, archive = 'store', fail = null } = {}) {
  const hot = await hotStore(); insCost(hot, COSTS.slice(0, 15));
  let arch = null;
  if (archive === 'store') { arch = await archiveStore(); if (archRows) insCost(arch, archRows, true); }
  if (archive === 'no-table') { const { DatabaseSync } = await import('node:sqlite'); arch = new DatabaseSync(':memory:'); }
  const spy = spyArchive(arch, { fail });
  return { env: { DB: d1(hot), ARCHIVE: spy.binding }, spy };
}

test('H0: lib/archive-read.js exists and exports the four functions', () => {
  assert.ok(AR, 'src/lib/archive-read.js did not load');
  for (const f of ['readHistory', 'mergeRows', 'mergeAggregate', 'mergeGroups']) {
    assert.equal(typeof AR[f], 'function', `${f} is not exported`);
  }
});

test('H1: ARCHIVE unbound (absent, or no prepare) is hot only, state unbound', async () => {
  assert.ok(AR);
  const hot = await hotStore(); insCost(hot, COSTS.slice(0, 15));
  for (const ARCHIVE of [undefined, {}]) {
    const r = await decide({ DB: d1(hot), ARCHIVE }, ago(120));
    assert.equal(r.state, 'unbound');
    assert.equal(r.archive, null);
    assert.equal(r.hot.n, 15);
  }
});

test('H2: since within 1 day of now makes 0 archive calls, the edge included', async () => {
  assert.ok(AR);
  for (const since of [iso(NOW_MS - 3600e3), ago(1)]) {
    const { env, spy } = await helperEnv({ archRows: COSTS.slice(15) });
    const r = await decide(env, since);
    assert.equal(r.state, 'not-needed', since);
    assert.equal(r.archive, null);
    assert.equal(spy.calls, 0, `${since}: archive prepare calls`);
  }
  // One second past the floor reads the archive's newest time.
  const { env, spy } = await helperEnv({ archRows: COSTS.slice(15) });
  await decide(env, iso(NOW_MS - DAY - 1000));
  assert.ok(spy.calls >= 1, 'a since older than 1 day must consult the archive');
});

test('H3: a missing archive table or an empty one is not-needed after one MAX read', async () => {
  assert.ok(AR);
  for (const archive of ['no-table', 'store']) {
    const { env, spy } = await helperEnv({ archive });
    const r = await decide(env, ago(120));
    assert.equal(r.state, 'not-needed', archive);
    assert.equal(r.archive, null);
    assert.equal(spy.calls, 1, `${archive}: only the MAX statement runs`);
    assert.match(spy.log[0].sql, /^SELECT MAX\(ts\) AS m FROM cost_rows$/);
  }
});

test('H4: since after the archive MAX is not-needed; since equal to MAX reads it', async () => {
  assert.ok(AR);
  const max = COSTS[15][3];  // the newest archived ts
  {
    const { env, spy } = await helperEnv({ archRows: COSTS.slice(15) });
    const r = await decide(env, iso(Date.parse(max) + 1000));
    assert.equal(r.state, 'not-needed');
    assert.equal(spy.calls, 1);
  }
  {
    const { env, spy } = await helperEnv({ archRows: COSTS.slice(15) });
    const r = await decide(env, max);
    assert.equal(r.state, 'read');
    assert.equal(spy.calls, 2);
    assert.equal(r.archive.n, 1, 'the row AT the MAX is in range');
  }
});

test('H5: since 30 days before an archive MAX of 90 days ago reads the archive', async () => {
  assert.ok(AR);
  const rows = COSTS.slice(30);  // 90 to 117 days old
  const { env, spy } = await helperEnv({ archRows: rows });
  const since = iso(Date.parse(rows[0][3]) - 30 * DAY);
  const r = await decide(env, since);
  assert.equal(r.state, 'read');
  assert.equal(spy.calls, 2);
  assert.equal(r.archive.n, rows.filter((x) => x[3] >= since).length);
  assert.equal(r.hot.n, 15);
  // A distinct archive statement and binds are used when given.
  const { env: env2 } = await helperEnv({ archRows: rows });
  const r2 = await decide(env2, since, { archive: { sql: 'SELECT COUNT(*) AS n FROM cost_rows WHERE ts >= ?1 AND model=?2', binds: [since, 'm-a'] } });
  assert.equal(r2.archive.n, rows.filter((x) => x[3] >= since && x[7] === 'm-a').length);
  await assert.rejects(() => AR.readHistory(env, { table: 'jobs', since, now: NOW, hot: HOT_Q }), /no archive time column for jobs/);
});

test('H6: an archive error is the hot answer with state unreadable, never thrown, never empty', async (t) => {
  assert.ok(AR);
  const logs = [];
  t.mock.method(console, 'log', (...a) => logs.push(a.join(' ')));
  // At the MAX read.
  const { env, spy } = await helperEnv({ fail: 'D1_ERROR: overloaded' });
  const r = await decide(env, ago(120));
  assert.equal(r.state, 'unreadable');
  assert.equal(r.archive, null);
  assert.equal(r.hot.n, 15);
  assert.equal(spy.calls, 1);
  assert.ok(logs.some((l) => /overloaded/.test(l)), 'the error is logged');
  // At the read itself: the MAX answers, the read fails.
  const arch = await archiveStore(); insCost(arch, COSTS.slice(15), true);
  const hot = await hotStore(); insCost(hot, COSTS.slice(0, 15));
  let n = 0;
  const inner = d1(arch);
  const ARCHIVE = { prepare(sql) { n += 1; if (n === 2) throw new Error('D1_ERROR: overloaded'); return inner.prepare(sql); } };
  const r2 = await decide({ DB: d1(hot), ARCHIVE }, ago(120));
  assert.equal(r2.state, 'unreadable');
  assert.equal(r2.hot.n, 15);
  // Through the real route: 200, hot rows, archive "unreadable".
  const s = await costSplit();
  const bad = spyArchive(s.arch, { fail: 'D1_ERROR: overloaded' });
  const b = await ok(t, { DB: d1(s.hot), ARCHIVE: bad.binding }, `/api/metrics/cost-breakdown?group=rows&since=${ago(120)}`);
  assert.equal(b.archive, 'unreadable');
  assert.equal(b.rows.length, 15);
});

test('H7: mergeRows dedupes on the key (hot copy wins), sorts and caps', () => {
  assert.ok(AR);
  const hot = [{ box: 'a', row_hash: '1', ts: '2026-01-03', src: 'hot' }, { box: 'a', row_hash: '2', ts: '2026-01-01', src: 'hot' }];
  const arch = [{ box: 'a', row_hash: '2', ts: '2026-01-01', src: 'arch' }, { box: 'b', row_hash: '3', ts: '2026-01-02', src: 'arch' },
    { box: 'a', row_hash: '4', ts: '2025-12-01', src: 'arch' }];
  const key = (r) => `${r.box}\u0000${r.row_hash}`;
  const compare = (x, y) => (x.ts < y.ts ? 1 : x.ts > y.ts ? -1 : 0);
  const m = AR.mergeRows(hot, arch, { key, compare, limit: 10 });
  assert.deepEqual(m.map((r) => r.row_hash), ['1', '3', '2', '4']);
  assert.equal(m.find((r) => r.row_hash === '2').src, 'hot');
  assert.deepEqual(AR.mergeRows(hot, arch, { key, compare, limit: 2 }).map((r) => r.row_hash), ['1', '3']);
  assert.equal(AR.mergeRows(hot, null, { key, compare, limit: 10 }), hot, 'no archive answer leaves the hot rows as they are');
});

test('H8: mergeAggregate NULL rules and mergeGroups bare columns and truncation', () => {
  assert.ok(AR);
  const spec = { a: 'sum', b: 'sum', c: 'max', d: 'min' };
  assert.deepEqual(AR.mergeAggregate({ a: null, b: null, c: '2026-01-01', d: 5 }, { a: 2, b: null, c: '2026-02-01', d: 3 }, spec),
    { a: 2, b: null, c: '2026-02-01', d: 3 });
  assert.deepEqual(AR.mergeAggregate({ a: 1, b: 2, c: null, d: null }, { a: 4, b: 3, c: '2026-01-01', d: 7 }, spec),
    { a: 5, b: 5, c: '2026-01-01', d: 7 });
  const x = { a: 1 };
  assert.equal(AR.mergeAggregate(x, null, spec), x);

  const gs = { calls: 'sum', usd: 'sum', last_ts: 'max' };
  const hot = [{ p: 'x', calls: 1, usd: 1, last_ts: '2026-03-01', last_run_id: 'hot-x' }, { p: 'y', calls: 1, usd: 9, last_ts: '2026-01-01', last_run_id: 'hot-y' }];
  const arch = [{ p: 'y', calls: 2, usd: 1, last_ts: '2026-02-01', last_run_id: 'arch-y' }, { p: 'x', calls: 3, usd: null, last_ts: '2026-01-01', last_run_id: 'arch-x' },
    { p: null, calls: 1, usd: 5, last_ts: '2026-01-01', last_run_id: 'arch-null' }];
  const compare = (a, b) => (b.usd ?? 0) - (a.usd ?? 0);
  const m = AR.mergeGroups(hot, arch, { by: ['p'], spec: gs, pickBy: 'last_ts', compare, limit: 10 });
  assert.deepEqual(m.rows.map((g) => g.p), ['y', null, 'x']);
  const y = m.rows[0], gx = m.rows[2];
  assert.equal(y.calls, 3); assert.equal(y.usd, 10); assert.equal(y.last_ts, '2026-02-01');
  assert.equal(y.last_run_id, 'arch-y', 'bare columns come from the row with the newer last_ts');
  assert.equal(gx.usd, 1, 'NULL + 1 = 1'); assert.equal(gx.last_run_id, 'hot-x');
  assert.equal(m.truncated, false);
  // Capped merge, and a side at the cap, are both truncated (D12).
  assert.equal(AR.mergeGroups(hot, arch, { by: ['p'], spec: gs, pickBy: 'last_ts', compare, limit: 2 }).truncated, true);
  assert.equal(AR.mergeGroups(hot, arch, { by: ['p'], spec: gs, pickBy: 'last_ts', compare, limit: 3 }).truncated, true,
    'the archive side returned limit rows');
  assert.equal(AR.mergeGroups(hot, null, { by: ['p'], spec: gs, pickBy: 'last_ts', compare, limit: 3 }).truncated, false);
});

// ═════════════════════════════ R1: inventory ═════════════════════════════
const FRAG_DIR = join(HERE, 'archive-readers.d');
const INVENTORY = readdirSync(FRAG_DIR).filter((f) => f.endsWith('.json'))
  .flatMap((f) => JSON.parse(readFileSync(join(FRAG_DIR, f), 'utf8')).readers);
const READ_RE = /\b(FROM|JOIN)\s+(cost_rows|stage_events_daily|stage_events)\b/g;
function srcFiles(dir = join(WORKER, 'src')) {
  return readdirSync(dir, { withFileTypes: true }).flatMap((e) =>
    e.isDirectory() ? srcFiles(join(dir, e.name)) : e.name.endsWith('.js') ? [join(dir, e.name)] : []);
}
// TEST-CHANGE (BH-8398): the retention rules moved to src/routes/retention.d/ (BH-8407).
const EXCLUDED = (rel) => /^src\/routes\/retention(\.js|\.d\/[^/]+\.js)$/.test(rel) || /^src\/lib\/archive[^/]*\.js$/.test(rel);
// readerCounts(files) — per file, the FROM/JOIN reads of the three tables.
function readerCounts(files = srcFiles(), read = (p) => readFileSync(p, 'utf8')) {
  const out = {};
  for (const p of files) {
    const rel = relative(WORKER, p);
    if (EXCLUDED(rel)) continue;
    const n = (read(p).match(READ_RE) || []).length;
    if (n) out[rel] = n;
  }
  return out;
}
const inventoryCounts = () => INVENTORY.reduce((o, r) => ({ ...o, [r.file]: (o[r.file] || 0) + 1 }), {});

test('R1a: every read of the three tables in src has an inventory row, and no row is stale', () => {
  assert.deepEqual(readerCounts(), inventoryCounts());
  // The check goes red on a new reader with no row (D1): a scratch copy of a
  // route with one more read.
  const target = join(WORKER, 'src/routes/model-watch.js');
  const mutated = readerCounts(srcFiles(), (p) => readFileSync(p, 'utf8') + (p === target ? '\nconst x = "SELECT 1 FROM cost_rows";' : ''));
  assert.notDeepEqual(mutated, inventoryCounts());
});

test('R1b: each row\'s match is found in its file', () => {
  for (const r of INVENTORY) {
    const s = readFileSync(join(WORKER, r.file), 'utf8');
    assert.ok(s.includes(r.match), `${r.file}:${r.line_hint}: match not found: ${JSON.stringify(r.match)}`);
  }
});

test('R1c: a wide reader is ported or pending with a slice; every row has a known class and status', () => {
  for (const r of INVENTORY) {
    assert.ok(['wide', 'narrow', 'poll', 'action'].includes(r.class), `${r.file}:${r.line_hint} class ${r.class}`);
    assert.ok(['ported', 'hot-only', 'pending'].includes(r.status), `${r.file}:${r.line_hint} status ${r.status}`);
    assert.ok(['cost_rows', 'stage_events', 'stage_events_daily'].includes(r.table));
    if (r.class === 'wide') {
      assert.ok(r.status === 'ported' || (r.status === 'pending' && r.slice), `${r.file}:${r.line_hint} is wide and ${r.status}`);
    } else {
      assert.equal(r.status, 'hot-only', `${r.file}:${r.line_hint}: a ${r.class} reader stays on the hot store`);
    }
  }
});

test('R1d: a ported row\'s file imports lib/archive-read.js; only that lib touches env.ARCHIVE', () => {
  const ported = [...new Set(INVENTORY.filter((r) => r.status === 'ported').map((r) => r.file))];
  assert.ok(ported.length >= 3, 'this slice ports three files');
  for (const f of ported) {
    const s = readFileSync(join(WORKER, f), 'utf8');
    // TEST-CHANGE (BH-7035): a ported file may sit one level under src/lib/
    // (lib/daily-digest/core-sections.js imports "../archive-read.js").
    const m = /from\s+["']((?:\.\.\/lib|\.\.|\.)\/archive-read\.js)["']/.exec(s);
    assert.ok(m !== null, `${f} does not import archive-read.js`);
  }
  // TEST-CHANGE: a lib under src/lib/ whose file name contains "archive" may
  // read env.ARCHIVE. Main added such libs after this test was written
  // (BH-6780: ledger-archive.js, ledger-archive-claim.js), and a list of names
  // breaks on the next one. Routes (src/routes/**) and every other file may not.
  for (const p of srcFiles()) {
    const rel = relative(WORKER, p);
    if (/^src\/lib\/[^/]*archive[^/]*\.js$/.test(rel)) continue;
    assert.ok(!/\bARCHIVE\b/.test(readFileSync(p, 'utf8')), `${rel} reads the ARCHIVE binding by hand`);
  }
});

test('R1e: a narrow or poll row with a fixed window says it, at 60 days or less', () => {
  for (const r of INVENTORY.filter((x) => x.class === 'narrow')) {
    assert.equal(typeof r.window_days, 'number', `${r.file}:${r.line_hint} has no window_days`);
    assert.ok(r.window_days <= 60, `${r.file}:${r.line_hint} window ${r.window_days} d is not narrow`);
    assert.ok(r.window, `${r.file}:${r.line_hint} has no window text`);
  }
});

// ═════════════════════════════ R2: same answer ═══════════════════════════
test('R2 cost-breakdown: rows, groups and total over both stores equal the all-hot answer', async (t) => {
  // Rows mode, with one row in BOTH stores: it appears once.
  {
    const s = await costSplit({ dup: true });
    const qs = `/api/metrics/cost-breakdown?group=rows&limit=500&since=${ago(120)}`;
    const want = await ok(t, { DB: d1(s.all) }, qs);
    const spy = spyArchive(s.arch);
    const got = await ok(t, { DB: d1(s.hot), ARCHIVE: spy.binding }, qs);
    assert.equal(got.archive, 'read');
    assert.equal(got.rows.length, 40);
    assert.deepEqual(got.rows.map((r) => `${r.box}/${r.row_hash}`), want.rows.map((r) => `${r.box}/${r.row_hash}`));
    assert.deepEqual(got.rows.map((r) => r.cost_usd), want.rows.map((r) => r.cost_usd));
    assert.ok(got.rows.every((r) => !('archived_at' in r)));
    assert.equal(got.truncated, false);
    // The cap holds across both stores.
    const capped = await ok(t, { DB: d1(s.hot), ARCHIVE: spyArchive(s.arch).binding }, qs.replace('limit=500', 'limit=20'));
    assert.deepEqual(capped.rows.map((r) => r.row_hash), want.rows.slice(0, 20).map((r) => r.row_hash));
    assert.equal(capped.truncated, true);
  }
  // Grouped modes and the total, on a clean split (an aggregate cannot dedupe).
  const s = await costSplit();
  for (const group of ['project', 'ticket', 'project,stage']) {
    const qs = `/api/metrics/cost-breakdown?group=${group}&since=${ago(120)}`;
    const want = await ok(t, { DB: d1(s.all) }, qs);
    const got = await ok(t, { DB: d1(s.hot), ARCHIVE: spyArchive(s.arch).binding }, qs);
    assert.equal(got.archive, 'read', group);
    sameGroups(got.groups, want.groups, group.split(','), group);
    sameTotal(got.total, want.total, group);
    assert.equal(got.truncated, false);
    assert.ok(got.total.calls === 40, `${group}: total covers all 40 rows`);
  }
});

test('R2 model-watch: usage sums over both stores equal the all-hot answer', async (t) => {
  const s = await costSplit();
  for (const model of ['m-a', 'm-b']) {
    const qs = `/api/model-watch/usage?model=${model}&since=${ago(120)}`;
    const want = await ok(t, { DB: d1(s.all) }, qs);
    const got = await ok(t, { DB: d1(s.hot), ARCHIVE: spyArchive(s.arch).binding }, qs);
    assert.equal(got.archive, 'read');
    for (const k of ['rows', 'input_toks', 'output_toks', 'cache_read', 'cache_write']) {
      assert.equal(got[k], want[k], `${model}.${k}`);
    }
    const hotOnly = s.hot.prepare('SELECT COUNT(*) AS n FROM cost_rows WHERE model=?1').get(model).n;
    assert.ok(got.rows > hotOnly, `${model}: the archive rows are counted (${got.rows} vs ${hotOnly} hot)`);
  }
});

test('R2 job-detail: the events of a 200-day-old job include the archived ones, in id order', async (t) => {
  const s = await eventSplit();
  const path = `/api/jobs/${JOB_OLD}`;
  const want = await ok(t, { DB: d1(s.all) }, path);
  const spy = spyArchive(s.arch);
  const got = await ok(t, { DB: d1(s.hot), ARCHIVE: spy.binding }, path);
  assert.equal(got.archive, 'read');
  assert.deepEqual(got.events.map((e) => e.id), want.events.map((e) => e.id));
  assert.equal(got.events.length, 30);
  assert.deepEqual(got.events, want.events, 'archived events carry the hot columns only');
});

// ═════════════════════════════ R3: no archive on narrow and poll paths ═══
test('R3: narrow readers and poll paths make 0 archive prepare calls', async (t) => {
  const s = await costSplit();
  const e = await eventSplit();
  insJob(e.hot, JOB_NEW, iso(NOW_MS - 3600e3));
  const cases = [
    [s.hot, '/api/lanes/status'],
    [s.hot, '/api/metrics/llm-sites'],
    [s.hot, '/api/metrics/triage-paid-unchanged'],
    [s.hot, '/api/progress/stamps'],
    [s.hot, '/api/metrics/lane-spend'],
    [s.hot, '/api/metrics/cost-breakdown'],
    [s.hot, '/api/metrics/cost-breakdown?group=rows'],
    [s.hot, `/api/model-watch/usage?model=m-a&since=${iso(NOW_MS - 3600e3)}`],
    [e.hot, `/api/jobs/${JOB_OLD}/live`],
    [e.hot, `/api/jobs/${JOB_NEW}`],
  ];
  for (const [db, path] of cases) {
    const spy = spyArchive(path.includes('/jobs/') ? e.arch : s.arch);
    const r = await get(t, { DB: d1(db), ARCHIVE: spy.binding }, path);
    assert.ok(r.status < 500, `${path} answered ${r.status}: ${JSON.stringify(r.body)}`);
    assert.equal(spy.calls, 0, `${path} made ${spy.calls} archive calls`);
  }
});

// ═════════════════════════════ R4: ARCHIVE unbound ═══════════════════════
// The pre-change SQL, verbatim, run on the same store.
const OLD_ROWS = `SELECT ts, box, project, stage, runner, model, billing_mode, ticket, job_id, run_id, pr,
                  cost_usd, rc, duration_s
             FROM cost_rows WHERE ts >= ?1 AND ts <= ?2 ORDER BY ts DESC LIMIT 200`;
const OLD_AGG = `COUNT(*) AS calls,
       SUM(cost_usd) AS usd,
       SUM(CASE WHEN billing_mode='metered' THEN COALESCE(cost_usd,0) ELSE 0 END) AS cash_usd,
       SUM(CASE WHEN billing_mode='subscription' THEN COALESCE(cost_usd,0) ELSE 0 END) AS equiv_usd,
       SUM(cost_usd IS NULL) AS unpriced_calls`;
const OLD_GROUPS = `SELECT NULLIF(TRIM(project),'') AS project, ${OLD_AGG}, MAX(ts) AS last_ts
             FROM cost_rows WHERE ts >= ?1 AND ts <= ?2
            GROUP BY 1 ORDER BY SUM(COALESCE(cost_usd,0)) DESC, 1 LIMIT 500`;

test('R4: with ARCHIVE unbound each ported route answers from the hot store as before', async (t) => {
  const s = await costSplit();
  const since = ago(120);
  {
    const b = await ok(t, { DB: d1(s.all) }, `/api/metrics/cost-breakdown?group=rows&since=${since}`);
    assert.equal(b.archive, 'unbound');
    const want = s.all.prepare(OLD_ROWS).all(since, NOW);
    assert.deepEqual(b.rows.map(({ row_hash, ...r }) => ({ ...r })), want.map((r) => ({ ...r })));
  }
  {
    const b = await ok(t, { DB: d1(s.all) }, `/api/metrics/cost-breakdown?group=project&since=${since}`);
    assert.equal(b.archive, 'unbound');
    assert.deepEqual(b.groups, s.all.prepare(OLD_GROUPS).all(since, NOW).map((r) => ({ ...r })));
    const tot = s.all.prepare(`SELECT ${OLD_AGG} FROM cost_rows WHERE ts >= ?1 AND ts <= ?2`).get(since, NOW);
    sameTotal(b.total, tot, 'unbound total');
  }
  {
    const b = await ok(t, { DB: d1(s.all) }, `/api/model-watch/usage?model=m-a&since=${since}`);
    assert.equal(b.archive, 'unbound');
    const want = s.all.prepare('SELECT COUNT(*) AS rows, SUM(input_toks) AS input_toks FROM cost_rows WHERE model=?1 AND ts>=?2').get('m-a', since);
    assert.equal(b.rows, want.rows); assert.equal(b.input_toks, want.input_toks);
  }
  {
    const e = await eventSplit();
    const b = await ok(t, { DB: d1(e.hot) }, `/api/jobs/${JOB_OLD}`);
    assert.equal(b.archive, 'unbound');
    assert.deepEqual(b.events, e.hot.prepare('SELECT * FROM stage_events WHERE job_id=?1 ORDER BY id ASC LIMIT 500').all(JOB_OLD).map((r) => ({ ...r })));
  }
});

// ═════════════════════════════ R6: archive reads use an index ═══════════
test('R6: every archive statement the ported routes run uses an index at live volume', async (t) => {
  const arch = await archiveStore();
  const nCost = LIVE.cost_rows, nEv = 50000;
  arch.exec('BEGIN');
  const c = arch.prepare(`INSERT INTO cost_rows (box, row_hash, line_no, ts, project, stage, runner, model, cost_usd, input_toks, inserted_at, archived_at)
                          VALUES (?,?,?,?,?,?,?,?,?,?,?,?)`);
  for (let i = 0; i < nCost; i++) {
    const ts = iso(NOW_MS - 30 * DAY - Math.floor((i / nCost) * 300 * DAY));
    c.run(`box-${i % 9}`, `a${i}`, i, ts, PROJECTS[i % 2], 'build', 'claude', i % 3 ? 'm-a' : 'm-b', 0.01, 5, ts, NOW);
  }
  const ev = arch.prepare('INSERT INTO stage_events (id, job_id, stage, actor, created_at, archived_at) VALUES (?,?,?,?,?,?)');
  for (let i = 0; i < nEv; i++) {
    ev.run(i + 1, i % 50 === 0 ? JOB_OLD : `job-${i % 4000}`, 'plan', 'box-1', iso(NOW_MS - 400 * DAY + Math.floor((i / nEv) * 300 * DAY)), NOW);
  }
  arch.exec('COMMIT');
  const hot = await hotStore(); insCost(hot, COSTS.slice(0, 15)); insJob(hot, JOB_OLD, ago(200));
  const spy = spyArchive(arch);
  const env = { DB: d1(hot), ARCHIVE: spy.binding };
  const since = ago(200);
  for (const path of [
    `/api/metrics/cost-breakdown?group=rows&since=${since}`,
    `/api/metrics/cost-breakdown?group=project&since=${since}`,
    `/api/metrics/cost-breakdown?group=ticket&since=${since}`,
    `/api/metrics/cost-breakdown?group=project,stage&since=${since}&project=alpha`,
    `/api/model-watch/usage?model=m-b&since=${since}`,
    `/api/jobs/${JOB_OLD}`,
  ]) {
    const b = await ok(t, env, path);
    assert.equal(b.archive, 'read', path);
  }
  const reads = spy.log.filter((r) => !/^SELECT MAX\(/.test(r.sql));
  assert.ok(reads.length >= 7, `captured ${reads.length} archive reads`);
  for (const r of spy.log) {
    const lines = arch.prepare(`EXPLAIN QUERY PLAN ${r.sql}`).all(...r.binds.map((v) => (v === undefined ? null : v))).map((x) => x.detail);
    const scans = lines.filter((l) => /^SCAN (cost_rows|stage_events)\b/.test(l));
    assert.deepEqual(scans, [], `full scan on the archive:\n  ${r.sql}\n  ${lines.join('\n  ')}`);
  }
});

// ═════════════════ R7: request values are binds, never SQL text ══════════
// The merge conductor refused e90b196c on check:sql-command-injection. The
// rule: no request value reaches the statement text. Every filter value and
// the rows `limit` go in as `?` binds, on the hot store and the archive.
test('R7: no request value reaches the SQL text of a cost-breakdown read; each is a bind', async (t) => {
  const { hot, arch } = await costSplit();
  const S = 'zzsentinel';
  const cases = [
    { path: `/api/metrics/cost-breakdown?group=rows&limit=437&since=${ago(120)}`
        + `&project=${S}p&stage=${S}s&runner=${S}r&model=${S}m&billing_mode=${S}b&ticket=${S}t`,
      binds: [`${S}p`, `${S}s`, `${S}r`, `${S}m`, `${S}b`, `${S}t`, 437] },
    { path: `/api/metrics/cost-breakdown?group=project,ticket&since=${ago(120)}&project=${S}p&ticket=`,
      binds: [`${S}p`] },
    { path: `/api/metrics/cost-breakdown?group=model&since=${ago(120)}&runner=${S}r`, binds: [`${S}r`] },
  ];
  for (const c of cases) {
    const db = spyArchive(hot), ar = spyArchive(arch);
    await ok(t, { DB: db.binding, ARCHIVE: ar.binding }, c.path);
    const reads = [...db.log, ...ar.log].filter((e) => /^\s*SELECT\b/i.test(e.sql) && /\bcost_rows\b/.test(e.sql)
      && !/^\s*SELECT MAX\(ts\) AS m FROM cost_rows$/.test(e.sql));
    assert.ok(reads.length >= 2, `${c.path}: the hot and the archive read ran (${reads.length})`);
    for (const e of reads) {
      assert.ok(!e.sql.includes(S), `${c.path}: a filter value is in the SQL text:\n  ${e.sql}`);
      assert.ok(!/\b437\b/.test(e.sql), `${c.path}: limit is in the SQL text:\n  ${e.sql}`);
    }
    const bound = new Set(reads.flatMap((e) => e.binds));
    for (const v of c.binds) assert.ok(bound.has(v), `${c.path}: ${JSON.stringify(v)} is not a bind`);
  }
  // A group outside the allowlist is a 400 before any cost_rows read.
  const db = spyArchive(hot);
  const r = await get(t, { DB: db.binding }, `/api/metrics/cost-breakdown?group=${encodeURIComponent("project) OR 1=1 --")}`);
  assert.equal(r.status, 400);
  assert.equal(db.log.filter((e) => /\bcost_rows\b/.test(e.sql) && /^\s*SELECT\b/i.test(e.sql)).length, 0);
});
