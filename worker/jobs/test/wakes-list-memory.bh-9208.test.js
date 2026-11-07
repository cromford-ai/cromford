// BH-9208: GET /api/wakes is bounded by two settings rows, names its columns
// and reports the bound it used (Sentry CROMFORD-HARNESS-1Z, "Worker exceeded
// memory limit" with the stack in this route's D1 read).
//
// Every case runs the REAL route (worker.fetch) on a real SQLite D1
// (test/lib/d1-sqlite.bh-1030.js). Each case opens its own DB and seeds its own
// rows, so no case depends on another or on order.
//
// The knobs (fallback in src/routes/wakes.js, seed in schema.d/):
//   wakes.list_default_rows  rows with no ?limit   (code default 200)
//   wakes.list_max_rows      most rows in one page (code default 500)
// determinism: ok-file clock-rolling-window since= is a wake id cursor, not a time; the fixtures pin no clock window
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import { plan } from './lib/d1-volume.bh-6727.js';

const SECRET = 'test-secret';
const COLS = ['id', 'repo', 'kind', 'key', 'event', 'minute', 'at', 'acked_at'];
const NAMES = ['alpha', 'beta', 'gamma', 'delta', 'project-3', 'project-4', 'project-1', 'project-2',
  'cromford', 'project-5', 'cromford', 'lens', 'atlas'];
const KINDS = ['pr', 'checks', 'push', 'deploy', 'issue', 'deploy_failed', 'merge_group'];
const sha = (i) => (i * 2654435761 >>> 0).toString(16).padStart(8, '0').repeat(5);

// A fresh DB with `n` wakes rows and no wakes.list_* settings rows. 1 in 3 is acked.
async function freshDb(n = 0) {
  const o = await openDb();
  if (!o) return null;
  o.db.exec("DELETE FROM settings WHERE key LIKE 'wakes.list_%'");
  if (n > 0) {
    const ins = o.db.prepare('INSERT INTO wakes (repo,kind,key,event,minute,at,acked_at) VALUES (?,?,?,?,?,?,?)');
    o.db.exec('BEGIN');
    for (let i = 1; i <= n; i++) {
      const kind = KINDS[i % KINDS.length];
      const at = `2026-11-07T${String(Math.floor(i / 3600) % 24).padStart(2, '0')}:${String(Math.floor(i / 60) % 60).padStart(2, '0')}:${String(i % 60).padStart(2, '0')}Z`;
      ins.run(`example-org/${NAMES[i % NAMES.length]}`, kind, kind === 'push' ? sha(i) : String(i),
        kind === 'checks' ? 'check_suite' : 'pull_request', at.slice(0, 16), at,
        i % 3 === 0 ? '2026-11-07T23:59:00Z' : null);
    }
    o.db.exec('COMMIT');
  }
  return o;
}
function setRow(o, key, value) {
  o.db.prepare("INSERT OR REPLACE INTO settings (key,value,note,actor,updated_at) VALUES (?,?,'test','test','2026-11-07T00:00:00Z')")
    .run(key, value);
}

// A D1 that records the SQL, binds and result size of every read.
function counting(DB, log, { failSettings = false } = {}) {
  return {
    prepare(sql) {
      if (failSettings && /FROM settings/.test(sql)) throw new Error('settings read failed (test)');
      const s = DB.prepare(sql);
      let binds = [];
      const api = {
        bind(...v) { binds = v; s.bind(...v); return api; },
        async first(c) { const r = await s.first(c); log.push({ sql, binds, rows: r ? 1 : 0 }); return r; },
        async all() { const r = await s.all(); log.push({ sql, binds, rows: (r.results || []).length }); return r; },
        run() { return s.run(); },
      };
      return api;
    },
    batch(stmts) { return DB.batch(stmts); },
  };
}

async function get(o, path, opts = {}) {
  const log = [];
  const res = await worker.fetch(new Request(`https://jobs.test${path}`, {
    headers: { authorization: `Bearer ${SECRET}` },
  }), { DB: counting(o.DB, log, opts), HARNESS_SECRET: SECRET });
  assert.equal(res.status, 200, `${path} answered ${res.status}`);
  return { body: await res.json(), log, wakeReads: log.filter((r) => /FROM wakes/.test(r.sql)) };
}

const big = await freshDb(50000);

test('M1: 50,000 rows, ?limit=100000 -> every read holds <= 500 rows and the body reports limit 500', { skip: !big }, async () => {
  for (const path of ['/api/wakes?since=0&limit=100000', '/api/wakes?limit=100000']) {
    const { body, wakeReads } = await get(big, path);
    assert.ok(wakeReads.length > 0, `${path}: no wakes read`);
    for (const r of wakeReads) assert.ok(r.rows <= 500, `${path}: a read held ${r.rows} rows`);
    assert.equal(body.wakes.length, 500, path);
    assert.equal(body.limit, 500, `${path}: body.limit`);
  }
});

test('M2: paging by since= reads every row once, in order, never more than 500 a page', { skip: !big }, async () => {
  let since = 0, peak = 0, seen = 0, last = 0;
  for (let page = 0; page < 200; page++) {
    const { body, wakeReads } = await get(big, `/api/wakes?since=${since}&limit=500`);
    for (const r of wakeReads) peak = Math.max(peak, r.rows);
    for (const w of body.wakes) { assert.ok(w.id > last, `id ${w.id} after ${last}`); last = w.id; seen++; }
    if (body.wakes.length < 500) break;
    since = last;
  }
  assert.equal(seen, 50000);
  assert.equal(last, 50000);
  assert.ok(peak <= 500, `peak ${peak}`);
});

test('E1: each shape of the read has a LIMIT and walks an index, with no scan and no sort', { skip: !big }, async () => {
  for (const path of ['/api/wakes', '/api/wakes?since=100', '/api/wakes?since=100&repo=example-org%2Fproject-3',
    '/api/wakes?since=100&kind=checks']) {
    const { wakeReads } = await get(big, path);
    const r = wakeReads[0];
    assert.match(r.sql, /\bLIMIT \d+\b/, path);
    const lines = plan(big.db, r.sql, ...r.binds);
    const txt = lines.join(' | ');
    assert.ok(lines.some((l) => /idx_wakes_unacked|INTEGER PRIMARY KEY|idx_wakes_repo_id|idx_wakes_kind_id/.test(l)), `${path}: ${txt}`);
    assert.ok(!lines.some((l) => /^SCAN wakes\b/.test(l)), `${path} scans wakes: ${txt}`);
    assert.ok(!lines.some((l) => /TEMP B-TREE FOR ORDER BY/.test(l)), `${path} sorts: ${txt}`);
  }
});

test('E2: the read names its 8 columns, never SELECT *', { skip: !big }, async () => {
  const { body, wakeReads } = await get(big, '/api/wakes?since=0&limit=3');
  for (const r of wakeReads) assert.ok(!/SELECT \*/i.test(r.sql), r.sql);
  assert.equal(body.wakes.length, 3);
  for (const w of body.wakes) assert.deepEqual(Object.keys(w).sort(), [...COLS].sort());
});

test('K1/K2: no settings rows -> limit 200 with no ?limit, 500 with ?limit=500', async (t) => {
  const o = await freshDb(600);
  if (!o) return t.skip('node:sqlite absent');
  const a = await get(o, '/api/wakes?since=0');
  assert.equal(a.body.limit, 200);
  assert.equal(a.body.wakes.length, 200);
  const b = await get(o, '/api/wakes?since=0&limit=500');
  assert.equal(b.body.limit, 500);
  assert.equal(b.body.wakes.length, 500);
});

test('K3: wakes.list_max_rows=50 -> ?limit=500 gives 50 rows', async (t) => {
  const o = await freshDb(600);
  if (!o) return t.skip('node:sqlite absent');
  setRow(o, 'wakes.list_max_rows', '50');
  const { body } = await get(o, '/api/wakes?since=0&limit=500');
  assert.equal(body.limit, 50);
  assert.equal(body.wakes.length, 50);
});

test('K4: a junk wakes.list_max_rows uses the fallback 500', async (t) => {
  for (const v of ['abc', '0', '1001', '5.5', '']) {
    const o = await freshDb(600);
    if (!o) return t.skip('node:sqlite absent');
    setRow(o, 'wakes.list_max_rows', v);
    const { body } = await get(o, '/api/wakes?since=0&limit=500');
    assert.equal(body.limit, 500, `row value ${JSON.stringify(v)}`);
    assert.equal(body.wakes.length, 500, `row value ${JSON.stringify(v)}`);
  }
});

test('K5: the default is never above the max', async (t) => {
  const o = await freshDb(600);
  if (!o) return t.skip('node:sqlite absent');
  setRow(o, 'wakes.list_default_rows', '300');
  setRow(o, 'wakes.list_max_rows', '100');
  const { body } = await get(o, '/api/wakes?since=0');
  assert.equal(body.limit, 100);
  assert.equal(body.wakes.length, 100);
});

test('K6: wakes.list_default_rows=20 -> no ?limit, 0 and abc give 20; -5 gives 1', async (t) => {
  const o = await freshDb(600);
  if (!o) return t.skip('node:sqlite absent');
  setRow(o, 'wakes.list_default_rows', '20');
  for (const q of ['', '&limit=0', '&limit=abc']) {
    const { body } = await get(o, `/api/wakes?since=0${q}`);
    assert.equal(body.limit, 20, q || 'no ?limit');
    assert.equal(body.wakes.length, 20, q || 'no ?limit');
  }
  const { body } = await get(o, '/api/wakes?since=0&limit=-5');
  assert.equal(body.limit, 1);
  assert.equal(body.wakes.length, 1);
});

test('K7: a settings read that throws -> 200 with the fallback limit and the rows', async (t) => {
  const o = await freshDb(600);
  if (!o) return t.skip('node:sqlite absent');
  const warn = console.warn; const warned = [];
  console.warn = (...a) => warned.push(a.join(' '));
  try {
    const { body, wakeReads } = await get(o, '/api/wakes?since=0', { failSettings: true });
    assert.equal(body.limit, 200);
    assert.equal(body.wakes.length, 200);
    assert.equal(wakeReads.length, 1);
  } finally { console.warn = warn; }
  assert.ok(warned.some((l) => /wakes: settings read failed, using fallbacks/.test(l)), warned.join('\n'));
});
