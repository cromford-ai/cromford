// BH-7059 (slice C1): the sixth routes/cost.js history reader,
// GET /api/metrics/cost-rows, reads the archive store too, through
// lib/archive-read.js (readHistory + mergeRows).
//
// Every case drives the REAL worker.fetch over a hot node:sqlite D1 and an
// archive node:sqlite D1 in #6777's archive shape (the hot columns,
// archived_at, PRIMARY KEY (box, row_hash), idx_cost_rows_ts). The fixtures
// are this file's own copy of the bh-7059 C0 ones; the clock is pinned (D60).
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { openDb, d1 } from './lib/d1-sqlite.bh-1030.js';
import { LIVE } from './lib/d1-volume.bh-6727.js';

const SECRET = 'test-secret-fixture';
const NOW_MS = Date.parse('2026-10-16T12:00:00Z');
const DAY = 86400e3;
const iso = (ms) => new Date(ms).toISOString().replace(/\.\d{3}Z$/, 'Z');
const ago = (days, h = 0) => iso(NOW_MS - days * DAY + h * 3600e3);
const NOW = iso(NOW_MS);
const TODAY0 = `${NOW.slice(0, 10)}T00:00:00Z`;
const SINCE110 = ago(110);

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

// ── fixtures ──────────────────────────────────────────────────────────────
// A cost row spec: { ts, usd, box, hash, lane, arch }. `arch` puts it in the
// archive in the split world; the all-hot world holds every row hot. The
// row_hash defaults to the row index, so a row has one key in both worlds.
function insCost(db, r, i, archived = false) {
  const row = {
    box: r.box ?? 'box-a', row_hash: r.hash ?? `h${i}`, line_no: i + 1, ts: r.ts, project: 'alpha',
    stage: 'build', runner: 'claude', auth_account: 'acct-a',
    cost_usd: r.usd === undefined ? 0.5 : r.usd, lane_id: r.lane ?? null, row_source: null,
    inserted_at: r.ts, ...(archived ? { archived_at: NOW } : {}),
  };
  const cols = Object.keys(row);
  db.prepare(`INSERT INTO cost_rows (${cols.join(',')}) VALUES (${cols.map(() => '?').join(',')})`).run(...Object.values(row));
}

async function world(costs) {
  const all = await hotStore(), hot = await hotStore(), arch = await archiveStore();
  costs.forEach((r, i) => { insCost(all, r, i); insCost(r.arch ? arch : hot, r, i, !!r.arch); });
  return { all, hot, arch };
}

// Two boxes, 12 rows: 7 archived (95-105 days ago), 5 hot (recent).
const COSTS = [
  { ts: ago(105), box: 'box-a', arch: true },
  { ts: ago(104), box: 'box-b', arch: true, usd: 1.5 },
  { ts: ago(103), box: 'box-b', arch: true, usd: null },
  { ts: ago(102), box: 'box-a', arch: true },
  { ts: ago(101), box: 'box-b', arch: true, usd: 2 },
  { ts: ago(100), box: 'box-a', arch: true },
  { ts: ago(95), box: 'box-b', arch: true, lane: 'lane-l' },
  { ts: ago(20), box: 'box-a' },
  { ts: ago(10), box: 'box-b', usd: 0.25 },
  { ts: ago(3), box: 'box-a', lane: 'lane-l' },
  { ts: ago(0, -3), box: 'box-b', lane: 'lane-l' },
  { ts: ago(0, -1), box: 'box-a', lane: 'lane-l' },
];

// node:sqlite rows have a null prototype; the route answers JSON.
const plain = (rows) => JSON.parse(JSON.stringify(rows));

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

// ═════════════════ R2: the split answer equals the all-hot answer ══════════
test('R2: ?box= and ?since=110d answer the all-hot rows, archive read, 2 archive calls', async (t) => {
  const w = await world(COSTS);
  for (const path of ['/api/metrics/cost-rows?box=box-b', `/api/metrics/cost-rows?since=${SINCE110}&limit=500`]) {
    const want = await ok(t, { DB: d1(w.all) }, path);
    const spy = spyArchive(w.arch);
    const got = await ok(t, { DB: d1(w.hot), ARCHIVE: spy.binding }, path);
    assert.ok(want.cost_rows.length > 0, path);
    assert.ok(want.cost_rows.some((r) => r.ts < ago(90)), `${path}: the fixture must reach archived ages`);
    assert.deepEqual(got.cost_rows, want.cost_rows, path);
    for (const r of got.cost_rows) assert.equal('archived_at' in r, false, `${path}: archived_at leaked`);
    assert.deepEqual(got.cost_rows.map((r) => Object.keys(r).sort()), want.cost_rows.map((r) => Object.keys(r).sort()));
    assert.equal(got.archive, 'read', path);
    assert.equal(spy.calls, 2, `${path}: MAX + the page; got ${spy.calls}`);
  }
});

test('R2: since 100d, until 90d, archive MAX 50d ago (until before MAX) reads the archive', async (t) => {
  const w = await world([...COSTS, { ts: ago(50), box: 'box-a', arch: true }]);
  const path = `/api/metrics/cost-rows?since=${ago(100)}&until=${ago(90)}`;
  const want = await ok(t, { DB: d1(w.all) }, path);
  const spy = spyArchive(w.arch);
  const got = await ok(t, { DB: d1(w.hot), ARCHIVE: spy.binding }, path);
  assert.equal(want.cost_rows.length, 2);
  assert.deepEqual(got.cost_rows, want.cost_rows);
  assert.equal(got.archive, 'read');
  assert.equal(spy.calls, 2);
});

test('R2-dup: one (box, row_hash) in both stores answers one row, the hot copy', async (t) => {
  const hot = await hotStore(), arch = await archiveStore();
  insCost(hot, { ts: ago(100), box: 'box-a', hash: 'dup', usd: 9 }, 0);
  insCost(arch, { ts: ago(100), box: 'box-a', hash: 'dup', usd: 1 }, 0, true);
  insCost(arch, { ts: ago(101), box: 'box-a', hash: 'other' }, 1, true);
  const got = await ok(t, { DB: d1(hot), ARCHIVE: spyArchive(arch).binding }, '/api/metrics/cost-rows?box=box-a');
  assert.equal(got.archive, 'read');
  assert.deepEqual(got.cost_rows.map((r) => [r.row_hash, r.cost_usd]), [['dup', 9], ['other', 0.5]]);
});

test('R2-box: the same row_hash in two boxes, one hot and one archived, answers both', async (t) => {
  const hot = await hotStore(), arch = await archiveStore();
  insCost(hot, { ts: ago(99), box: 'box-a', hash: 'same' }, 0);
  insCost(arch, { ts: ago(100), box: 'box-b', hash: 'same' }, 0, true);
  const got = await ok(t, { DB: d1(hot), ARCHIVE: spyArchive(arch).binding }, `/api/metrics/cost-rows?since=${SINCE110}`);
  assert.equal(got.archive, 'read');
  assert.deepEqual(got.cost_rows.map((r) => [r.box, r.row_hash]), [['box-a', 'same'], ['box-b', 'same']]);
});

test('R2-cap: hot 3 rows + archive 5 older, limit=4, answers the 4 newest across both', async (t) => {
  const rows = [
    { ts: ago(5) }, { ts: ago(4) }, { ts: ago(3) },
    { ts: ago(100), arch: true }, { ts: ago(101), arch: true }, { ts: ago(102), arch: true },
    { ts: ago(103), arch: true }, { ts: ago(104), arch: true },
  ];
  const w = await world(rows);
  const got = await ok(t, { DB: d1(w.hot), ARCHIVE: spyArchive(w.arch).binding }, '/api/metrics/cost-rows?box=box-a&limit=4');
  assert.equal(got.archive, 'read');
  assert.deepEqual(got.cost_rows.map((r) => r.ts), [ago(3), ago(4), ago(5), ago(100)]);
});

test('R2-page: walking since=110d limit=3 back with until= answers every row, as cost-rows-read.sh does', async (t) => {
  const w = await world(COSTS);
  const env = { DB: d1(w.hot), ARCHIVE: spyArchive(w.arch).binding };
  const seen = new Map();
  let until = '';
  for (let page = 0; page < 20; page++) {
    const got = await ok(t, env, `/api/metrics/cost-rows?since=${SINCE110}&limit=3${until ? `&until=${until}` : ''}`);
    let fresh = 0;
    for (const r of got.cost_rows) {
      const k = `${r.box}\u0000${r.row_hash}`;
      if (!seen.has(k)) { seen.set(k, r); fresh += 1; }
    }
    if (got.cost_rows.length < 3 || fresh === 0) break;
    until = got.cost_rows[got.cost_rows.length - 1].ts;
  }
  const want = (await ok(t, { DB: d1(w.all) }, `/api/metrics/cost-rows?since=${SINCE110}&limit=2000`)).cost_rows;
  const sortK = (rows) => rows.map((r) => `${r.box}/${r.row_hash}`).sort();
  assert.deepEqual(sortK([...seen.values()]), sortK(want));
  assert.equal(seen.size, COSTS.length);
});

// ═════════════════ R3: a poll path never reaches the archive ══════════════
test('R3: recent since windows make 0 archive calls with a bound archive that holds rows', async (t) => {
  const w = await world(COSTS);
  for (const path of [
    `/api/metrics/cost-rows?since=${ago(0, -2)}`,
    `/api/metrics/cost-rows?since=${ago(1)}&limit=500`,
    `/api/metrics/cost-rows?since=${TODAY0}&lane_id=lane-l`,
  ]) {
    const want = await ok(t, { DB: d1(w.all) }, path);
    const spy = spyArchive(w.arch);
    const got = await ok(t, { DB: d1(w.hot), ARCHIVE: spy.binding }, path);
    assert.equal(spy.calls, 0, `${path}: ${spy.calls} archive call(s)`);
    assert.equal(got.archive, 'not-needed', path);
    assert.deepEqual(got.cost_rows, want.cost_rows, path);
  }
});

test('R3: since 100d, archive MAX 120d ago makes 1 archive call (MAX only)', async (t) => {
  const w = await world([{ ts: ago(120), arch: true }, { ts: ago(5) }]);
  const spy = spyArchive(w.arch);
  const got = await ok(t, { DB: d1(w.hot), ARCHIVE: spy.binding }, `/api/metrics/cost-rows?since=${ago(100)}`);
  assert.equal(spy.calls, 1);
  assert.equal(got.archive, 'not-needed');
  assert.deepEqual(got.cost_rows.map((r) => r.ts), [ago(5)]);
});

// ═════════════════ R4: unbound answers as before ═════════════════════════
test('R4: no ARCHIVE binding answers main\'s SQL on the same hot rows, archive unbound', async (t) => {
  const w = await world(COSTS);
  const cases = [
    ['/api/metrics/cost-rows', 'SELECT * FROM cost_rows ORDER BY ts DESC LIMIT 200', []],
    ['/api/metrics/cost-rows?box=box-b&limit=3', 'SELECT * FROM cost_rows WHERE box=?1 ORDER BY ts DESC LIMIT 3', ['box-b']],
    [`/api/metrics/cost-rows?since=${SINCE110}&until=${ago(50)}`,
      'SELECT * FROM cost_rows WHERE ts>=?1 AND ts<=?2 ORDER BY ts DESC LIMIT 200', [SINCE110, ago(50)]],
  ];
  for (const [path, sql, binds] of cases) {
    const got = await ok(t, { DB: d1(w.hot) }, path);
    const want = plain((await d1(w.hot).prepare(sql).bind(...binds).all()).results);
    assert.deepEqual(got.cost_rows, want, path);
    assert.equal(got.archive, 'unbound', path);
    assert.deepEqual(Object.keys(got).sort(), ['archive', 'as_of', 'cost_rows'], path);
  }
});

// ═════════════════ R5u: an unreadable archive ═════════════════════════════
test('R5u: an archive that throws answers 200, the hot-only rows, archive unreadable', async (t) => {
  const w = await world(COSTS);
  const path = `/api/metrics/cost-rows?since=${SINCE110}`;
  const hotOnly = plain((await d1(w.hot).prepare(`SELECT * FROM cost_rows WHERE ts>=?1 ORDER BY ts DESC LIMIT 200`).bind(SINCE110).all()).results);
  t.mock.method(console, 'log', () => {});
  const spy = spyArchive(w.arch, { fail: 'D1_ERROR: overloaded' });
  const got = await ok(t, { DB: d1(w.hot), ARCHIVE: spy.binding }, path);
  assert.equal(got.archive, 'unreadable');
  assert.deepEqual(got.cost_rows, hotOnly);
  // The page read fails, MAX fine: still unreadable, still the hot page.
  const inner = d1(w.arch);
  const ARCHIVE = { prepare(sql) { if (/^SELECT \* FROM cost_rows/.test(sql)) throw new Error('D1_ERROR: overloaded'); return inner.prepare(sql); } };
  const got2 = await ok(t, { DB: d1(w.hot), ARCHIVE }, path);
  assert.equal(got2.archive, 'unreadable');
  assert.deepEqual(got2.cost_rows, hotOnly);
});

// ═════════════════ R6: archive reads use an index ═════════════════════════
test('R6: the archive page statement for since/until uses idx_cost_rows_ts at live volume', async (t) => {
  const arch = await archiveStore();
  const n = LIVE.cost_rows;
  arch.exec('BEGIN');
  const c = arch.prepare(`INSERT INTO cost_rows (box, row_hash, line_no, ts, project, stage, runner, auth_account, lane_id, row_source, cost_usd, inserted_at, archived_at)
                          VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)`);
  for (let i = 0; i < n; i++) {
    const ts = iso(NOW_MS - 30 * DAY - Math.floor((i / n) * 300 * DAY));
    c.run(`box-${i % 9}`, `a${i}`, i, ts, 'alpha', 'build', 'claude', 'acct-a', null, null, 0.01, ts, NOW);
  }
  arch.exec('COMMIT');
  const hot = await hotStore();
  const spy = spyArchive(arch);
  const got = await ok(t, { DB: d1(hot), ARCHIVE: spy.binding }, `/api/metrics/cost-rows?since=${ago(200)}&until=${ago(100)}&limit=500`);
  assert.equal(got.archive, 'read');
  assert.equal(got.cost_rows.length, 500);
  const pages = spy.log.filter((e) => !/^SELECT MAX\(/.test(e.sql));
  assert.equal(pages.length, 1);
  for (const e of spy.log) {
    const lines = arch.prepare(`EXPLAIN QUERY PLAN ${e.sql}`).all(...e.binds).map((x) => x.detail);
    assert.ok(lines.some((l) => /USING (COVERING )?INDEX idx_cost_rows_ts/.test(l)), `no idx_cost_rows_ts:\n  ${e.sql}\n  ${lines.join('\n  ')}`);
    assert.deepEqual(lines.filter((l) => /^SCAN cost_rows/.test(l)), [], `full scan on the archive:\n  ${e.sql}\n  ${lines.join('\n  ')}`);
  }
});
