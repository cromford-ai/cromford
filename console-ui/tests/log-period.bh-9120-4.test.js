// BH-9308 (BH-9120.4): the four log screens get a range, search, filters, a
// CSV and a period report. This file drives the console half:
//
// H*  /api/cockpit/history range path, through the real Pages onRequest over an
//     in-memory node:sqlite CONSOLE_DB (the real SQL runs).
// HE  EXPLAIN at 50k runs with the console-ui/schema.d indexes.
// C*  /api/cockpit/commands (new), same harness.
// LP* src/lib/log-period.js helpers. LR1 laneRunList URLs (T3).
// SR* the four period-report seams. E1/E2 the report panel. SO1 SortableTable onSort.
// UI-* the real App: each screen reached from its side-menu link, then a
//      search typed into the toolbar.
// Each test seeds its own rows; the clock is pinned (determinism lint).
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { DatabaseSync } from 'node:sqlite';
import { h, render as mount } from 'preact';
import { flush } from './helpers/settle.js';
import { installDom, routedFetch, all, fire, type } from './helpers/fake-dom.bh-5750.js';

const NOW = Date.parse('2026-11-14T15:20:00Z');
Date.now = () => NOW;

const setUrl = (to) => {
  const u = new URL(to, 'http://console.test');
  Object.assign(window.location, { pathname: u.pathname, search: u.search, hash: u.hash });
};
const store = new Map();
let printed = 0;
globalThis.window = {
  location: { pathname: '/', search: '', hash: '' },
  dispatchEvent() { return true; }, addEventListener() {}, removeEventListener() {},
  history: { pushState(_s, _t, to) { setUrl(to); }, replaceState(_s, _t, to) { setUrl(to); } },
  scrollTo() {},
  print() { printed++; },
  localStorage: { getItem: (k) => (store.has(k) ? store.get(k) : null), setItem: (k, v) => store.set(k, String(v)), removeItem: (k) => store.delete(k) },
  matchMedia: () => ({ matches: false, addEventListener() {}, removeEventListener() {} })
};

const { onRequest } = await import('../functions/api/cockpit/[[path]].js');
const LP = await import('../src/lib/log-period.js');
const { laneRunList } = await import('../src/lib/lane-runs-api.js');
const { REPORTS } = await import('../src/screens/period-report.d/index.js');
const { SortableTable } = await import('../src/ui/SortableTable.js');
const { App } = await import('../src/app.js');
const { resetPeriodKnobs } = await import('../src/api.js');
const { commandRows } = await import('../src/lib/commands.js');
const { html } = await import('../src/router.js');

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const WEEK = { from: '2026-10-01T00:00:00Z', to: '2026-10-08T00:00:00Z', bucket: 'auto', compare: false };
const WQ = 'from=2026-10-01T00:00:00Z&to=2026-10-08T00:00:00Z';

// ------------------------------------------------------- the CONSOLE_DB half

const SCHEMA = `
  CREATE TABLE runs (id INTEGER PRIMARY KEY, rkey TEXT, project TEXT, kind TEXT, rc INTEGER, summary TEXT,
    started_at TEXT, finished_at TEXT);
  CREATE TABLE commands (id INTEGER PRIMARY KEY AUTOINCREMENT, ckey TEXT UNIQUE, type TEXT, project TEXT, payload TEXT,
    status TEXT DEFAULT 'pending', attempts INTEGER DEFAULT 0, lease_until TEXT, result TEXT,
    created_at TEXT, updated_at TEXT);`;
const INDEX_FILE = path.join(root, 'schema.d', '202611261813-bh-9308-console-log-indexes.sql');

function consoleDb({ indexes = false } = {}) {
  const s = new DatabaseSync(':memory:');
  s.exec(SCHEMA);
  if (indexes) s.exec(fs.readFileSync(INDEX_FILE, 'utf8'));
  const log = [];
  const DB = {
    prepare(sql) {
      const stmt = s.prepare(sql);
      let binds = [];
      const api = {
        bind(...b) { binds = b; return api; },
        all: async () => { log.push({ sql, binds }); return { results: stmt.all(...binds) }; },
        first: async () => { log.push({ sql, binds }); return stmt.get(...binds) || null; }
      };
      return api;
    }
  };
  return { s, DB, log };
}

function seedRuns(s, rows) {
  const ins = s.prepare('INSERT INTO runs (id, rkey, project, kind, rc, summary, started_at, finished_at) VALUES (?,?,?,?,?,?,?,?)');
  for (const r of rows) ins.run(r.id, r.rkey || `r${r.id}`, r.project || 'project-3', r.kind || 'triage', r.rc ?? 0, r.summary || 'tickets=1', r.started_at, r.started_at);
}
function seedCommands(s, rows) {
  const ins = s.prepare('INSERT INTO commands (id, ckey, type, project, payload, status, attempts, result, created_at, updated_at) VALUES (?,?,?,?,?,?,?,?,?,?)');
  for (const r of rows) ins.run(r.id, r.ckey || `c${r.id}`, r.type || 'run_triage', r.project || 'project-3', r.payload || '{}', r.status || 'done', 1, r.result || null, r.created_at, r.created_at);
}

let cookieSeq = 0;
// The sign-in probe answers 200; the knob fetch answers `knobs` ([status, body]) or throws.
async function cockpit(pathAndQuery, DB, { knobs = [200, { knobs: { max_range_days: 366, csv_row_cap: 100000, default_preset: 'last_7_days', max_buckets: 2000 } }] } = {}) {
  const real = globalThis.fetch;
  const fetched = [];
  globalThis.fetch = async (u) => {
    fetched.push(String(u));
    if (String(u).includes('/api/period/knobs')) {
      if (knobs === 'throw') throw new Error('down');
      return new Response(JSON.stringify(knobs[1]), { status: knobs[0] });
    }
    return new Response('', { status: 200 });
  };
  try {
    const [p, q = ''] = pathAndQuery.split('?');
    const res = await onRequest({
      request: new Request(`https://mc.test/api/cockpit/${p}${q ? `?${q}` : ''}`, { headers: { cookie: `dash=lp${++cookieSeq}` } }),
      env: { CONSOLE_DB: DB, HARNESS_SECRET: 'sek' },
      params: { path: p.split('/') }
    });
    const text = await res.text();
    let body = null;
    try { body = JSON.parse(text); } catch { body = null; }
    return { status: res.status, body, text, type: res.headers.get('content-type'), fetched };
  } finally { globalThis.fetch = real; }
}

const runIds = (r) => r.body.runs.map((x) => x.id);

test('H1 history with a range: only runs started in [from, to); no from = today\'s answer', async () => {
  const { s, DB, log } = consoleDb();
  seedRuns(s, [
    { id: 1, started_at: '2026-09-30T23:59:59Z' },
    { id: 2, started_at: '2026-10-01T00:00:00Z' },
    { id: 3, started_at: '2026-10-07T23:59:59Z' },
    { id: 4, started_at: '2026-10-08T00:00:00Z' }
  ]);
  const r = await cockpit(`history?${WQ}`, DB);
  assert.equal(r.status, 200, r.text);
  assert.deepEqual(runIds(r), [3, 2]);
  assert.equal(r.body.total, 2);
  assert.deepEqual(r.body.totals, { total: 2, ok: 2, failed: 0 });
  assert.equal(r.body.knobs_source, 'row');
  // No from: the old statements, no knob fetch, every run.
  log.length = 0;
  const old = await cockpit('history', DB);
  assert.deepEqual(runIds(old), [4, 3, 2, 1]);
  assert.equal(old.fetched.filter((u) => u.includes('period/knobs')).length, 0);
  assert.ok(log.every((l) => !/started_at\s*>=/.test(l.sql)), 'no range clause');
  assert.equal(old.body.next_cursor, null);
});

test('H2 q escapes % and _; q, cursor, series and format need a range', async () => {
  const { s, DB } = consoleDb();
  seedRuns(s, [
    { id: 1, summary: 'deal 50%_off today', started_at: '2026-10-02T00:00:00Z' },
    { id: 2, summary: 'deal 50xxoff today', started_at: '2026-10-02T00:00:00Z' },
    { id: 3, summary: 'plain', started_at: '2026-10-02T00:00:00Z' }
  ]);
  const lit = await cockpit(`history?${WQ}&q=${encodeURIComponent('50%_off')}`, DB);
  assert.deepEqual(runIds(lit), [1]);
  const under = await cockpit(`history?${WQ}&q=_`, DB);
  assert.deepEqual(runIds(under), [1], '_ is a literal underscore, not "any char"');
  for (const p of ['q=x', 'cursor=abc', 'series=day', 'format=csv']) {
    const r = await cockpit(`history?${p}`, DB);
    assert.equal(r.status, 400, p);
    assert.match(r.body.error, /needs a from\/to range/, p);
  }
});

test('H3 project + kind + outcome + q combine (AND)', async () => {
  const { s, DB } = consoleDb();
  seedRuns(s, [
    { id: 1, project: 'p1', kind: 'triage', rc: 1, summary: 'review x', started_at: '2026-10-02T00:00:00Z' },
    { id: 2, project: 'p2', kind: 'triage', rc: 1, summary: 'review x', started_at: '2026-10-02T00:00:00Z' },
    { id: 3, project: 'p1', kind: 'build', rc: 1, summary: 'review x', started_at: '2026-10-02T00:00:00Z' },
    { id: 4, project: 'p1', kind: 'triage', rc: 0, summary: 'review x', started_at: '2026-10-02T00:00:00Z' },
    { id: 5, project: 'p1', kind: 'triage', rc: 1, summary: 'other', started_at: '2026-10-02T00:00:00Z' }
  ]);
  const r = await cockpit(`history?${WQ}&project=p1&kind=triage&outcome=failed&q=review`, DB);
  assert.deepEqual(runIds(r), [1]);
  assert.deepEqual(r.body.totals, { total: 1, ok: 0, failed: 1 });
});

test('H4 keyset pages by cursor, never OFFSET; the CSV equals the pages; the cap line', async () => {
  const { s, DB, log } = consoleDb();
  const rows = [];
  for (let i = 1; i <= 25; i++) rows.push({ id: i, started_at: `2026-10-0${1 + (i % 5)}T0${i % 10}:00:00Z` });
  seedRuns(s, rows);
  const seen = [];
  let cursor = null;
  for (let page = 0; page < 3; page++) {
    const r = await cockpit(`history?${WQ}&limit=10${cursor ? `&cursor=${cursor}` : ''}`, DB);
    assert.equal(r.status, 200, r.text);
    seen.push(...runIds(r));
    cursor = r.body.next_cursor;
    if (page < 2) assert.ok(cursor, `page ${page + 1} hands a cursor`);
  }
  assert.equal(cursor, null, 'the last page says it is the last');
  assert.equal(seen.length, 25);
  assert.equal(new Set(seen).size, 25, 'no row twice');
  assert.ok(log.every((l) => !/OFFSET/i.test(l.sql)), 'no OFFSET in any SQL');
  const csv = await cockpit(`history?${WQ}&format=csv`, DB);
  assert.equal(csv.status, 200);
  assert.match(csv.type, /text\/csv/);
  const lines = csv.text.trim().split('\r\n');
  assert.equal(lines[0], 'id,rkey,project,kind,rc,summary,started_at,finished_at');
  assert.deepEqual(lines.slice(1).map((l) => Number(l.split(',')[0])), seen, 'CSV rows = the pages, same order');
  const capped = await cockpit(`history?${WQ}&format=csv`, DB, { knobs: [200, { knobs: { csv_row_cap: 5 } }] });
  const cl = capped.text.trim().split('\r\n');
  assert.equal(cl.length, 1 + 5 + 1);
  assert.equal(cl[cl.length - 1], '# truncated at 5');
  // A cursor that does not decode is a 400, not page 1.
  for (const bad of ['abc', Buffer.from('[1]').toString('base64url'), Buffer.from('["x","y"]').toString('base64url')]) {
    const r = await cockpit(`history?${WQ}&cursor=${bad}`, DB);
    assert.equal(r.status, 400, bad);
    assert.equal(r.body.error, 'cursor is not valid');
  }
});

test('H5 series per day with null gaps; a failed knob fetch uses the fallbacks and says so', async () => {
  const { s, DB } = consoleDb();
  seedRuns(s, [
    { id: 1, started_at: '2026-10-01T05:00:00Z' },
    { id: 2, started_at: '2026-10-01T06:00:00Z' },
    { id: 3, started_at: '2026-10-03T00:00:00Z' }
  ]);
  const r = await cockpit(`history?from=2026-10-01T00:00:00Z&to=2026-10-04T00:00:00Z&series=day`, DB, { knobs: 'throw' });
  assert.equal(r.status, 200, r.text);
  assert.equal(r.body.knobs_source, 'fallback');
  assert.deepEqual(r.body.series, [
    { bucket: '2026-10-01', value: 2 }, { bucket: '2026-10-02', value: null }, { bucket: '2026-10-03', value: 1 }
  ]);
  const many = await cockpit(`history?${WQ}&series=hour`, DB, { knobs: [200, { knobs: { max_buckets: 24 } }] });
  assert.equal(many.status, 400);
  assert.match(many.body.error, /over 24 hour buckets/);
  for (const bad of ['minute', encodeURIComponent("strftime('%s',started_at)")]) {
    const b = await cockpit(`history?${WQ}&series=${bad}`, DB);
    assert.equal(b.status, 400, bad);
  }
  const badFrom = await cockpit(`history?from=${encodeURIComponent('2026-10-01;DROP')}`, DB);
  assert.equal(badFrom.status, 400);
});

test('HE 50k runs: a 30-day range uses idx_runs_started (and the project index), no full SCAN runs', async () => {
  const { s, DB, log } = consoleDb({ indexes: true });
  s.exec('BEGIN');
  const ins = s.prepare('INSERT INTO runs (id, rkey, project, kind, rc, summary, started_at, finished_at) VALUES (?,?,?,?,?,?,?,?)');
  const base = Date.parse('2026-11-14T00:00:00Z');
  for (let i = 0; i < 50000; i++) {
    const at = new Date(base - Math.floor((50000 - i) * (120 * 86400e3 / 50000))).toISOString().replace(/\.\d{3}Z$/, 'Z');
    ins.run(i + 1, `r${i}`, `p${i % 13}`, i % 3 ? 'triage' : 'build', i % 7 ? 0 : 1, `summary ${i}`, at, at);
  }
  s.exec('COMMIT');
  const planOf = (sql, binds) => s.prepare(`EXPLAIN QUERY PLAN ${sql}`).all(...binds).map((x) => x.detail);
  for (const [qs, idx] of [['', /idx_runs_started/], ['&project=p3', /idx_runs_project_started/]]) {
    log.length = 0;
    const r = await cockpit(`history?from=2026-10-15T00:00:00Z&to=2026-11-14T00:00:00Z&q=summary${qs}`, DB);
    assert.equal(r.status, 200, r.text);
    for (const st of log.filter((l) => /FROM runs/.test(l.sql))) {
      const lines = planOf(st.sql, st.binds);
      assert.ok(lines.some((l) => idx.test(l)), `${qs}: ${lines.join(' | ')}`);
      assert.ok(!lines.some((l) => /^SCAN runs\b(?!.*USING)/.test(l)), lines.join(' | '));
    }
  }
  s.exec('BEGIN');
  const ci = s.prepare('INSERT INTO commands (ckey, type, project, payload, status, created_at, updated_at) VALUES (?,?,?,?,?,?,?)');
  for (let i = 0; i < 20000; i++) {
    const at = new Date(base - i * 600e3).toISOString().replace(/\.\d{3}Z$/, 'Z');
    ci.run(`c${i}`, 'run_triage', `p${i % 13}`, '{}', 'done', at, at);
  }
  s.exec('COMMIT');
  log.length = 0;
  const c = await cockpit('commands?from=2026-10-15T00:00:00Z&to=2026-11-14T00:00:00Z&q=p3', DB);
  assert.equal(c.status, 200, c.text);
  for (const st of log.filter((l) => /FROM commands/.test(l.sql))) {
    const lines = planOf(st.sql, st.binds);
    assert.ok(lines.some((l) => /idx_commands_created/.test(l)), lines.join(' | '));
    assert.ok(!lines.some((l) => /^SCAN commands\b(?!.*USING)/.test(l)), lines.join(' | '));
  }
});

const cmdIds = (r) => r.body.commands.map((x) => x.id);

test('C1 commands needs a range; range on created_at; rows feed commandRows unchanged', async () => {
  const { s, DB } = consoleDb();
  seedCommands(s, [
    { id: 1, created_at: '2026-09-30T23:59:59Z' },
    { id: 2, created_at: '2026-10-01T00:00:00Z', payload: JSON.stringify({ actor: 'operator', project: 'project-3' }) },
    { id: 3, created_at: '2026-10-08T00:00:00Z' }
  ]);
  const none = await cockpit('commands', DB);
  assert.equal(none.status, 400);
  assert.match(none.body.error, /from/);
  const r = await cockpit(`commands?${WQ}`, DB);
  assert.equal(r.status, 200, r.text);
  assert.deepEqual(cmdIds(r), [2]);
  const { rows, malformed } = commandRows(r.body);
  assert.equal(malformed, false);
  assert.equal(rows[0].actor, 'operator');
  assert.equal(rows[0].status, 'done');
});

test('C2 commands q escapes; type + project + status + q combine; totals by status', async () => {
  const { s, DB } = consoleDb();
  seedCommands(s, [
    { id: 1, type: 'merge_pr', status: 'dead_letter', result: 'merge 50%_x failed', created_at: '2026-10-02T00:00:00Z' },
    { id: 2, type: 'merge_pr', status: 'dead_letter', result: 'merge 50aax failed', created_at: '2026-10-02T00:00:00Z' },
    { id: 3, type: 'run_triage', status: 'dead_letter', result: 'merge 50%_x', created_at: '2026-10-02T00:00:00Z' },
    { id: 4, type: 'merge_pr', status: 'done', result: 'merge 50%_x', created_at: '2026-10-02T00:00:00Z' },
    { id: 5, type: 'merge_pr', project: 'p9', status: 'dead_letter', result: 'merge 50%_x', created_at: '2026-10-02T00:00:00Z' }
  ]);
  const r = await cockpit(`commands?${WQ}&type=merge_pr&project=project-3&status=dead_letter&q=${encodeURIComponent('50%_x')}`, DB);
  assert.deepEqual(cmdIds(r), [1]);
  const all5 = await cockpit(`commands?${WQ}`, DB);
  assert.deepEqual(all5.body.totals, { total: 5, pending: 0, claimed: 0, done: 1, failed: 0, dead_letter: 4, other: 0 });
  const bad = await cockpit(`commands?${WQ}&status=${encodeURIComponent("x' OR 1=1")}`, DB);
  assert.equal(bad.status, 400);
});

test('C3 commands keyset pages = CSV rows; no OFFSET', async () => {
  const { s, DB, log } = consoleDb();
  const rows = [];
  for (let i = 1; i <= 23; i++) rows.push({ id: i, created_at: `2026-10-0${1 + (i % 4)}T10:00:00Z` });
  seedCommands(s, rows);
  const seen = [];
  let cursor = null;
  do {
    const r = await cockpit(`commands?${WQ}&limit=10${cursor ? `&cursor=${cursor}` : ''}`, DB);
    assert.equal(r.status, 200, r.text);
    seen.push(...cmdIds(r));
    cursor = r.body.next_cursor;
  } while (cursor);
  assert.equal(seen.length, 23);
  assert.ok(log.every((l) => !/OFFSET/i.test(l.sql)));
  const csv = await cockpit(`commands?${WQ}&format=csv`, DB);
  const lines = csv.text.trim().split('\r\n');
  assert.equal(lines[0], 'id,ckey,type,project,status,attempts,result,created_at,updated_at');
  assert.deepEqual(lines.slice(1).map((l) => Number(l.split(',')[0])), seen);
});

test('C4 commands series per day, gaps null', async () => {
  const { s, DB } = consoleDb();
  seedCommands(s, [{ id: 1, created_at: '2026-10-01T01:00:00Z' }, { id: 2, created_at: '2026-10-03T01:00:00Z' }]);
  const r = await cockpit('commands?from=2026-10-01&to=2026-10-04&series=day', DB);
  assert.deepEqual(r.body.series, [
    { bucket: '2026-10-01', value: 1 }, { bucket: '2026-10-02', value: null }, { bucket: '2026-10-03', value: 1 }
  ]);
});

// --------------------------------------------------------------- LP helpers

test('LP1 logHref keeps the period and the other filters, drops a cleared key and the cursor', () => {
  const href = LP.logHref('/jobs', `?${WQ}&project=p1&q=old&cursor=abc`, { q: 'new', project: null });
  const u = new URL(href, 'http://x');
  assert.equal(u.pathname, '/jobs');
  assert.equal(u.searchParams.get('from'), WEEK.from);
  assert.equal(u.searchParams.get('to'), WEEK.to);
  assert.equal(u.searchParams.get('q'), 'new');
  assert.equal(u.searchParams.has('project'), false);
  assert.equal(u.searchParams.has('cursor'), false);
});

test('LP2 readLogParams round-trips the URL; logCsvHref carries the filter and format=csv', () => {
  const p = LP.readLogParams(`?${WQ}&q=a b&lane=x&junk=1`, LP.LOG_KEYS.jobs);
  assert.equal(p.q, 'a b');
  assert.equal(p.lane, 'x');
  assert.equal(p.project, null);
  assert.equal('junk' in p, false);
  const back = LP.readLogParams(new URL(LP.logHref('/jobs', `?${WQ}`, p), 'http://x').search, LP.LOG_KEYS.jobs);
  assert.deepEqual(back, p);
  const csv = new URL(LP.logCsvHref('/api/coord/jobs', WEEK, p), 'http://x');
  assert.equal(csv.pathname, '/api/coord/jobs');
  assert.equal(csv.searchParams.get('format'), 'csv');
  assert.equal(csv.searchParams.get('q'), 'a b');
  assert.equal(csv.searchParams.get('lane'), 'x');
  assert.equal(csv.searchParams.get('from'), WEEK.from);
  assert.equal(csv.searchParams.has('project'), false);
});

test('LP3 seriesBucket: auto picks by range length, an explicit bucket wins', () => {
  assert.equal(LP.seriesBucket({ from: '2026-11-14T00:00:00Z', to: null, bucket: 'auto' }, NOW), 'hour');
  assert.equal(LP.seriesBucket(WEEK, NOW), 'day');
  assert.equal(LP.seriesBucket({ ...WEEK, bucket: 'week' }, NOW), 'week');
});

test('LP4 logPollMs: 0 for a range that ended, the interval for an open one', () => {
  assert.equal(LP.logPollMs(WEEK, NOW, 30000), 0);
  assert.equal(LP.logPollMs({ from: '2026-11-14T00:00:00Z', to: null }, NOW, 30000), 30000);
  assert.equal(LP.logPollMs({ from: '2026-11-14T00:00:00Z', to: '2026-11-15T00:00:00Z' }, NOW, 30000), 30000);
});

test('LR1 laneRunList passes the new params only when they have a value', async () => {
  const calls = [];
  globalThis.fetch = async (u) => { calls.push(String(u)); return { ok: true, status: 200, text: async () => '{"runs":[]}' }; };
  await laneRunList({});
  await laneRunList({ lane: 'x', from: WEEK.from, to: WEEK.to, q: '50%', project: 'p', sort: 'lane', dir: 'asc', cursor: 'c1', totals: 1, status: 'failed' });
  assert.equal(calls[0], '/api/coord/lane-runs');
  const sp = new URL(calls[1], 'http://x').searchParams;
  assert.deepEqual(Object.fromEntries(sp), { lane: 'x', status: 'failed', from: WEEK.from, to: WEEK.to, q: '50%', project: 'p', sort: 'lane', dir: 'asc', cursor: 'c1', totals: '1' });
});

// ------------------------------------------------------------------ SR seams

test('SR1-SR4 each seam reads its path through api.periodGet and returns {totals, series, topRows, columns}', async () => {
  const cases = {
    jobs: ['/api/coord/jobs', { jobs: [{ id: 'j1', project: 'p', kind: 'build', status: 'done', created_at: 'a' }], totals: { total: 1, running: 0, done: 1, failed: 0, other: 0 } }],
    lanes: ['/api/coord/lane-runs', { runs: [{ id: 7, lane: 'l', project: 'p', status: 'done', enqueued_at: 'a' }], totals: { total: 1 } }],
    history: ['/api/cockpit/history', { runs: [{ id: 9, project: 'p', kind: 'triage', rc: 0, started_at: 'a' }], totals: { total: 1, ok: 1, failed: 0 } }],
    commands: ['/api/cockpit/commands', { commands: [{ id: 3, type: 't', project: 'p', status: 'done', created_at: 'a' }], totals: { total: 1 } }]
  };
  for (const [name, [p, body]] of Object.entries(cases)) {
    const seam = REPORTS[name];
    assert.equal(typeof seam.title, 'string', name);
    const asked = [];
    const api = { periodGet: async (pp, q) => { asked.push([pp, q]); return { ...body, series: [{ bucket: '2026-10-01', value: 1 }, { bucket: '2026-10-02', value: null }] }; } };
    const out = await seam.load(api, WEEK);
    assert.equal(asked.length, 1, name);
    assert.equal(asked[0][0], p, name);
    assert.equal(asked[0][1].from, WEEK.from);
    assert.equal(asked[0][1].keep.totals, 1);
    assert.equal(asked[0][1].keep.series, 'day');
    assert.equal(asked[0][1].keep.limit, 20);
    assert.deepEqual(out.totals, body.totals, name);
    assert.equal(out.series[1].value, null, `${name}: an empty bucket stays null`);
    assert.equal(out.topRows.length, 1, name);
    assert.ok(Array.isArray(out.columns) && out.columns.length > 2, name);
    for (const c of out.columns) assert.ok(c in out.topRows[0], `${name}: column ${c} is on the row`);
  }
  for (const other of ['costs', 'outcomes', 'dora', 'ci', 'utilization']) assert.equal(REPORTS[other], null, other);
});

// ------------------------------------------------------------------ DOM bits

const mounted = new Set();
test.afterEach(() => { for (const r of mounted) mount(null, r); mounted.clear(); resetPeriodKnobs(); });
function mountInto(vnode) {
  const doc = installDom();
  const el = doc.createElement('div');
  mounted.add(el);
  mount(vnode, el);
  return el;
}
const cls = (n) => ((n.attrs && n.attrs.class) || '').split(/\s+/).filter(Boolean);
const byCls = (r, c) => all(r).filter((n) => n.nodeType === 1 && cls(n).includes(c));
const byTag = (r, t) => all(r).filter((n) => n.localName === t);
const button = (r, label) => byTag(r, 'button').find((b) => b.textContent.trim() === label);
const text = (r) => r.textContent.replace(/\s+/g, ' ');
const link = (r, label) => byTag(r, 'a').find((a) => a.textContent.trim() === label);

test('E1/E2 the report panel: an empty period says "no data for this period"; a failed read shows the ErrorBox; Print prints', async () => {
  const empty = { title: 'T', load: async () => ({ totals: { total: 0 }, series: [], topRows: [], columns: ['id'] }) };
  const el = mountInto(h(LP.LogReportPanel, { report: empty, period: WEEK }));
  await flush();
  assert.match(text(el), /no data for this period/);
  assert.doesNotMatch(text(el), /TOTAL\s*0/);
  const bad = { title: 'T', load: async () => { throw new Error('boom read'); } };
  const el2 = mountInto(h(LP.LogReportPanel, { report: bad, period: WEEK }));
  await flush();
  assert.match(text(el2), /boom read/);
  assert.ok(byCls(el2, 'errorbox').length + byTag(el2, 'button').filter((b) => /RETRY/i.test(b.textContent)).length > 0, 'an ErrorBox');
  const full = { title: 'T', load: async () => ({ totals: { total: 3, done: 2 }, series: [{ bucket: 'a', value: 3 }], topRows: [{ id: 1, status: 'done' }], columns: ['id', 'status'] }) };
  const el3 = mountInto(h(LP.LogReportPanel, { report: full, period: WEEK }));
  await flush();
  assert.equal(byTag(el3, 'svg').length, 1, 'the chart');
  assert.ok(byTag(el3, 'td').some((td) => td.textContent.trim() === 'done'), 'the top rows');
  fire(button(el3, 'Print'), 'click');
  assert.equal(printed, 1);
});

test('SO1 SortableTable onSort gets (key, dir); without it the table sorts as before', async () => {
  const got = [];
  const cols = [{ key: 'a', label: 'A', cell: (r) => r.a }, { key: 'b', label: 'B', cell: (r) => r.b }];
  const rows = [{ a: 2, b: 'x' }, { a: 1, b: 'y' }];
  const el = mountInto(html`<${SortableTable} columns=${cols} rows=${rows} onSort=${(k, d) => got.push([k, d])}/>`);
  await flush();
  fire(byTag(el, 'button').find((b) => /^B/.test(b.textContent.trim())), 'click');
  await flush();
  fire(byTag(el, 'button').find((b) => /^B/.test(b.textContent.trim())), 'click');
  assert.deepEqual(got, [['b', 'asc'], ['b', 'desc']]);
  const el2 = mountInto(html`<${SortableTable} columns=${cols} rows=${rows}/>`);
  await flush();
  assert.deepEqual(byTag(el2, 'td').filter((_, i) => i % 2 === 0).map((t) => t.textContent.trim()), ['1', '2']);
});

// ----------------------------------------------------- UI: the four screens

const JOB = (id, extra = {}) => ({
  id, project: 'project-3', kind: 'build', box: 'b1', stage: 'execute', status: 'done', heartbeating: false,
  age_s: 600, activity_age_s: 600, spent_usd: 1, budget_usd: 5, created_at: '2026-10-03T00:00:00Z', updated_at: '2026-10-03T00:00:00Z', ...extra
});

function appFetch(extra) {
  return routedFetch((u) => {
    const hit = extra(u);
    if (hit) return hit;
    if (u.startsWith('/api/coord/period/knobs')) return [200, { knobs: { default_preset: 'last_7_days' } }];
    if (u.includes('/staff/roster')) return [200, { agents: [] }];
    if (u.includes('lanes')) return [200, { lanes: [] }];
    if (u.includes('burn')) return [200, { burn: [], days: 14 }];
    if (u.includes('flags')) return [200, { flags: [] }];
    return [200, {}];
  });
}
async function viaMenu(label, extra) {
  setUrl(`/nowhere?${WQ}`);
  const calls = appFetch(extra);
  const el = mountInto(h(App));
  await flush();
  const nav = all(el).find((n) => n.localName === 'nav' && n.attrs.id === 'sidemenu');
  const a = byTag(nav, 'a').find((x) => x.textContent.trim() === label);
  assert.ok(a, `side menu link ${label}`);
  fire(a, 'click');
  await flush();
  return { el, calls };
}
async function search(el, value) {
  const input = byTag(el, 'input').find((i) => i.attrs.name === 'q');
  assert.ok(input, 'a search box');
  type(input, value);
  const form = byTag(el, 'form').find((f) => all(f).includes(input));
  fire(form, 'submit');
  await flush();
}
const params = (u) => Object.fromEntries(new URL(u, 'http://x').searchParams);
const csvLink = (el) => byTag(el, 'a').find((a) => a.textContent.trim() === 'Download CSV');

test('UI-J JOBS from the side menu: a search sends q with the period, only the answer\'s rows render, CSV and report links carry it', async () => {
  const { el, calls } = await viaMenu('JOBS', (u) => {
    if (u.startsWith('/api/coord/jobs?') && u.includes('q=review')) return [200, { jobs: [JOB('job-review-1')], totals: { total: 1, running: 0, done: 1, failed: 0, other: 0 }, next_cursor: null, as_of: 'x' }];
    if (u.startsWith('/api/coord/jobs?') && !u.includes('status=running')) return [200, { jobs: [JOB('job-a'), JOB('job-b')], as_of: 'x' }];
    return null;
  });
  assert.equal(window.location.pathname, '/jobs');
  await search(el, 'review');
  assert.equal(params(window.location.search).q, 'review');
  assert.equal(params(window.location.search).from, WEEK.from);
  const sent = calls.map((c) => c.url).filter((u) => u.startsWith('/api/coord/jobs?') && u.includes('q=review'));
  assert.equal(sent.length, 1);
  assert.deepEqual({ ...params(sent[0]) }, { ...params(sent[0]), q: 'review', from: WEEK.from, to: WEEK.to, totals: '1' });
  assert.ok(link(el, 'job-review-1'), 'the matching row');
  assert.ok(!link(el, 'job-a'), 'an unfiltered row is gone');
  const qBox = byTag(el, 'input').find((i) => i.attrs.name === 'q');
  assert.equal(qBox.value ?? qBox.attrs.value, 'review', 'the box shows the URL search');
  const csv = params(csvLink(el).attrs.href);
  assert.equal(csv.q, 'review');
  assert.equal(csv.format, 'csv');
  assert.equal(csv.from, WEEK.from);
  assert.ok(new URL(csvLink(el).attrs.href, 'http://x').pathname === '/api/coord/jobs');
  // A header click asks the server for the order.
  fire(byTag(el, 'button').find((b) => /^PROJECT/.test(b.textContent.trim())), 'click');
  await flush();
  assert.equal(params(window.location.search).sort, 'project');
  assert.ok(calls.some((c) => c.url.includes('sort=project')), 'the read carries sort');
});

test('UI-L LANES from the side menu with status=failed: the period runs read carries from/to/q/status, rows and CSV follow', async () => {
  const { el, calls } = await viaMenu('LANES', (u) => {
    if (u.startsWith('/api/coord/lane-runs/metrics')) return [200, { hours: 24, lanes: [], machines: [], as_of: 'x' }];
    if (u.startsWith('/api/coord/lane-runs?') && u.includes('q=review')) return [200, { runs: [{ id: 41, lane: 'review-lane', project: 'p', status: 'done', rc: 1, enqueued_at: '2026-10-02T00:00:00Z', attempts: 1 }], totals: { total: 1, queued: 0, claimed: 0, done: 0, failed: 1, died: 0 }, next_cursor: null, truncated: false, as_of: 'x' }];
    if (u.startsWith('/api/coord/lane-runs?')) return [200, { runs: [{ id: 40, lane: 'other', project: 'p', status: 'done', rc: 0, enqueued_at: '2026-10-02T00:00:00Z', attempts: 1 }], totals: { total: 1 }, next_cursor: null, truncated: false, as_of: 'x' }];
    return null;
  });
  assert.equal(window.location.pathname, '/lane-runs');
  const failedChip = byTag(el, 'a').find((a) => a.textContent.trim() === 'failed');
  assert.ok(failedChip, 'a status chip');
  fire(failedChip, 'click');
  await flush();
  await search(el, 'review');
  const p = params(window.location.search);
  assert.equal(p.status, 'failed');
  assert.equal(p.q, 'review');
  const sent = calls.map((c) => c.url).filter((u) => u.startsWith('/api/coord/lane-runs?') && u.includes('q=review'));
  assert.ok(sent.length >= 1);
  const sp = params(sent[sent.length - 1]);
  assert.equal(sp.status, 'failed');
  assert.equal(sp.from, WEEK.from);
  assert.equal(sp.to, WEEK.to);
  assert.ok(link(el, '41'), 'the matching run');
  assert.ok(!link(el, '40'), 'the other run is gone');
  const csv = params(csvLink(el).attrs.href);
  assert.equal(csv.status, 'failed');
  assert.equal(csv.q, 'review');
  assert.equal(csv.format, 'csv');
});

test('UI-H HISTORY from the side menu: the RUNS read sends the range and q; the chips keep from/to/q', async () => {
  const { el, calls } = await viaMenu('HISTORY', (u) => {
    if (u.startsWith('/api/cockpit/history?') && u.includes('q=triage')) return [200, { runs: [{ id: 77, project: 'project-3', kind: 'triage', rc: 1, summary: 'triage tick', started_at: '2026-10-02T00:00:00Z', finished_at: '2026-10-02T00:01:00Z' }], total: 1, failed: 1, totals: { total: 1, ok: 0, failed: 1 }, next_cursor: null }];
    if (u.startsWith('/api/cockpit/history?')) return [200, { runs: [{ id: 76, project: 'project-3', kind: 'build', rc: 0, summary: 'build tick', started_at: '2026-10-02T00:00:00Z', finished_at: 'x' }], total: 1, failed: 0, next_cursor: null }];
    return null;
  });
  assert.equal(window.location.pathname, '/history');
  const first = calls.map((c) => c.url).find((u) => u.startsWith('/api/cockpit/history?'));
  assert.equal(params(first).from, WEEK.from, 'the RUNS read sends the range');
  await search(el, 'triage');
  assert.ok(byTag(el, 'a').some((a) => a.attrs.href === '/runs/77'), 'the matching run');
  assert.ok(!byTag(el, 'a').some((a) => a.attrs.href === '/runs/76'), 'the other run is gone');
  fire(button(el, 'NON-ZERO EXIT'), 'click');
  await flush();
  const p = params(window.location.search);
  assert.equal(p.outcome, 'failed');
  assert.equal(p.q, 'triage');
  assert.equal(p.from, WEEK.from);
  const csv = params(csvLink(el).attrs.href);
  assert.equal(csv.q, 'triage');
  assert.equal(csv.outcome, 'failed');
});

test('UI-C COMMAND LOG from the side menu: the period read is /api/cockpit/commands with q; filters keep the range', async () => {
  const { el, calls } = await viaMenu('COMMAND LOG', (u) => {
    if (u.startsWith('/api/cockpit/commands?') && u.includes('q=merge')) return [200, { commands: [{ id: 501, type: 'merge_pr', project: 'project-3', status: 'dead_letter', payload: '{}', created_at: '2026-10-02T00:00:00Z' }], totals: { total: 1, dead_letter: 1 }, next_cursor: null }];
    if (u.startsWith('/api/cockpit/commands?')) return [200, { commands: [{ id: 500, type: 'run_triage', project: 'project-3', status: 'done', payload: '{}', created_at: '2026-10-02T00:00:00Z' }], totals: { total: 1 }, next_cursor: null }];
    return null;
  });
  assert.equal(window.location.pathname, '/history/commands');
  const first = calls.map((c) => c.url).find((u) => u.startsWith('/api/cockpit/commands?'));
  assert.ok(first, 'the period read');
  assert.equal(params(first).from, WEEK.from);
  assert.ok(!calls.some((c) => c.url.startsWith('/api/dash/commands')), 'the period view does not read the dash list');
  await search(el, 'merge');
  assert.ok(all(el).some((n) => n.attrs && n.attrs.id === 'cmd-501'), 'the matching command');
  assert.ok(!all(el).some((n) => n.attrs && n.attrs.id === 'cmd-500'), 'the other command is gone');
  fire(button(el, 'dead_letter'), 'click');
  await flush();
  const p = params(window.location.search);
  assert.equal(p.status, 'dead_letter');
  assert.equal(p.q, 'merge');
  assert.equal(p.from, WEEK.from);
  const csv = params(csvLink(el).attrs.href);
  assert.equal(csv.q, 'merge');
  assert.equal(new URL(csvLink(el).attrs.href, 'http://x').pathname, '/api/cockpit/commands');
});

test('UI-R the Period report toggle opens the panel in place from the JOBS screen', async () => {
  const { el } = await viaMenu('JOBS', (u) => {
    if (u.startsWith('/api/coord/jobs?') && u.includes('series=')) return [200, { jobs: [JOB('job-top')], totals: { total: 1, running: 0, done: 1, failed: 0, other: 0 }, series: [{ bucket: '2026-10-01', value: 1 }], as_of: 'x' }];
    if (u.startsWith('/api/coord/jobs?')) return [200, { jobs: [JOB('job-a')], as_of: 'x' }];
    return null;
  });
  fire(link(el, 'Period report'), 'click');
  await flush();
  assert.equal(params(window.location.search).report, '1');
  assert.ok(button(el, 'Print'), 'the report panel is open');
  assert.equal(byCls(el, 'period-chart').length, 1);
});

// ------------------------------------------------- LK the row caps are knobs
// Lead BLOCK (hardcoded-knob): the report's top rows (limit: 20) and the
// LANE / PROJECT chip cap (.slice(0, 30)) were literals. They are the
// settings rows mc.period.report_top_rows and mc.period.filter_chip_cap, read
// through api.periodKnobs; 20 and 30 are only the code fallbacks.

test('LK2 logKnob and chipValues read the knob, else the documented fallback', () => {
  assert.deepEqual({ ...LP.LOG_KNOB_FALLBACKS }, { report_top_rows: 20, filter_chip_cap: 30 });
  assert.equal(LP.logKnob({ report_top_rows: 7 }, 'report_top_rows'), 7);
  for (const bad of [null, undefined, {}, { report_top_rows: 0 }, { report_top_rows: '7' }, { report_top_rows: 1.5 }]) {
    assert.equal(LP.logKnob(bad, 'report_top_rows'), 20, JSON.stringify(bad));
  }
  const rows = ['c', 'a', 'b', 'a', null, 'd'].map((lane, i) => ({ id: i, lane }));
  assert.deepEqual(LP.chipValues(rows, 'lane', { filter_chip_cap: 2 }), ['a', 'b']);
  const many = Array.from({ length: 40 }, (_, i) => ({ id: i, lane: `l${String(i).padStart(2, '0')}` }));
  assert.equal(LP.chipValues(many, 'lane', null).length, 30, 'no knob: the fallback cap');
  assert.equal(LP.chipValues(many, 'lane', { filter_chip_cap: 35 }).length, 35);
});

test('LK3 each log seam sends limit = mc.period.report_top_rows; the panel hands the knobs to load', async () => {
  for (const name of ['jobs', 'lanes', 'history', 'commands']) {
    const asked = [];
    const api = { periodGet: async (pp, q) => { asked.push(q); return { totals: { total: 0 } }; } };
    await REPORTS[name].load(api, WEEK, { report_top_rows: 7 });
    await REPORTS[name].load(api, WEEK);
    assert.deepEqual(asked.map((q) => q.keep.limit), [7, 20], name);
  }
  const got = [];
  const spy = { title: 'K', load: async (_api, _p, knobs) => { got.push(knobs); return { totals: { total: 0 } }; } };
  mountInto(h(LP.LogReportPanel, { report: spy, period: WEEK, knobs: { report_top_rows: 9 } }));
  await flush();
  assert.equal(got.length >= 1 && got[got.length - 1].report_top_rows, 9);
  for (const f of ['src/screens/period-report.d/jobs.js', 'src/screens/period-report.d/lanes.js',
    'src/screens/period-report.d/history.js', 'src/screens/period-report.d/commands.js',
    'src/screens/Jobs.js', 'src/screens/LaneRuns.js']) {
    const src = fs.readFileSync(path.join(root, f), 'utf8');
    assert.doesNotMatch(src, /limit:\s*20\b/, `${f}: a literal top-row cap`);
    assert.doesNotMatch(src, /\.slice\(0,\s*30\)/, `${f}: a literal chip cap`);
  }
});
