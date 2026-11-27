// BH-9308 (BH-9120.4): the log routes take a range plus search, filters,
// server sort, keyset cursor, totals, a series and a CSV export.
//   GET /api/jobs       (routes/jobs.js)
//   GET /api/lane-runs  (routes/lane-runs-metrics.js)
// Driven through the REAL router (worker.fetch) over the node:sqlite D1, so
// the real SQL runs. Each test opens its own in-memory D1 and seeds its own
// ids. The assertions read rows, CSV text and EXPLAIN QUERY PLAN lines.
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { JOBS_SELECT } from '../src/lib/core.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import { openVolumeDb, capturingD1, plan, NOW_ISO, isoAgo } from './lib/d1-volume.bh-6727.js';

const SECRET = 'fixture-harness-secret';
const WEEK = 'from=2026-10-01T00:00:00Z&to=2026-10-08T00:00:00Z';

async function get(DB, path) {
  const res = await worker.fetch(new Request(`https://jobs.test${path}`, {
    headers: { authorization: `Bearer ${SECRET}` },
  }), { DB, HARNESS_SECRET: SECRET });
  const text = await res.text();
  let body = null;
  try { body = JSON.parse(text); } catch { body = null; }
  return { status: res.status, body, text, headers: res.headers };
}

// ── seeds ─────────────────────────────────────────────────────────────────
// job(db, {id, project, kind, box, status, created, ticket, meta, lane})
function job(db, r) {
  db.prepare(`INSERT INTO jobs (id, project, ticket_id, kind, box, stage, status, created_at, updated_at, meta)
              VALUES (?,?,?,?,?,?,?,?,?,?)`).run(
    r.id, r.project || 'p1', r.ticket ?? null, r.kind || 'build', r.box || 'box-1', 'execute',
    r.status || 'done', r.created, r.updated || r.created, r.meta ?? null);
  if (r.lane) db.prepare('INSERT INTO job_claims (job_id, lane, updated_at) VALUES (?,?,?)').run(r.id, r.lane, r.created);
}
// run(db, {lane, project, status, enq, by, rc, args, prof, attempts}) -> id
function run(db, r) {
  const info = db.prepare(
    `INSERT INTO lane_runs (lane, project, args_json, enqueued_at, enqueued_by, claimed_at, claimed_by,
       attempts, status, rc, prof_line, finished_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)`
  ).run(r.lane || 'demo', r.project || 'p1', r.args ?? '["bin/x.sh"]', r.enq, 'hub',
    r.by ? r.enq : null, r.by ?? null, r.attempts ?? 0, r.status || 'queued', r.rc ?? null, r.prof ?? null,
    r.status === 'done' || r.status === 'died' ? r.enq : null);
  return Number(info.lastInsertRowid);
}
const setting = (db, k, v) => db.prepare(
  "INSERT INTO settings (key,value,note,actor,updated_at) VALUES (?,?,'fixture','fixture','2026-11-26T00:00:00Z') ON CONFLICT(key) DO UPDATE SET value=excluded.value"
).run(k, v);

const jobIds = (r) => r.body.jobs.map((j) => j.id);
const runIds = (r) => r.body.runs.map((x) => x.id);
// CSV body -> array of row arrays (no quoted commas in these fixtures).
const csvRows = (text) => text.split('\r\n').filter((l) => l !== '');
const day = (d, h = 12) => `2026-10-${String(d).padStart(2, '0')}T${String(h).padStart(2, '0')}:00:00Z`;

// Walk every page from `path` through next_cursor; returns the pages.
async function pages(DB, path, key) {
  const out = [];
  let cursor = null;
  for (let i = 0; i < 20; i++) {
    const r = await get(DB, `${path}${cursor ? `&cursor=${cursor}` : ''}`);
    assert.equal(r.status, 200, JSON.stringify(r.body));
    out.push(r.body[key].map((x) => x.id));
    cursor = r.body.next_cursor;
    if (!cursor) return { pages: out, last: r };
  }
  throw new Error('more than 20 pages');
}

const NODE_OK = (await openDb()) !== null;
const skip = !NODE_OK && 'node:sqlite is absent';

// ── /api/jobs ─────────────────────────────────────────────────────────────

test('JR1 a jobs range with sort returns only rows created inside [from, to)', { skip }, async () => {
  const { db, DB } = await openDb();
  job(db, { id: 'jr1-before', created: '2026-09-30T23:59:59Z' });
  job(db, { id: 'jr1-first', created: '2026-10-01T00:00:00Z' });
  job(db, { id: 'jr1-last', created: '2026-10-07T23:59:59Z' });
  job(db, { id: 'jr1-after', created: '2026-10-08T00:00:00Z' });
  const r = await get(DB, `/api/jobs?${WEEK}&sort=created_at&dir=asc`);
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.deepEqual(jobIds(r), ['jr1-first', 'jr1-last']);
  assert.equal(r.body.next_cursor, null);
  const t = await get(DB, `/api/jobs?${WEEK}&totals=1`);
  assert.equal(t.body.totals.total, 2);
});

test('JQ1 q matches literal text only; q=_ is not every row; q without from is a 400', { skip }, async () => {
  const { db, DB } = await openDb();
  job(db, { id: 'jq1-lit', created: day(2), meta: '{"note":"save 50%_x today"}' });
  job(db, { id: 'jq1-near', created: day(3), meta: '{"note":"save 50abx today"}' });
  job(db, { id: 'jq1-tkt', created: day(4), ticket: 'BH-777' });
  job(db, { id: 'jq1-kind', created: day(5), kind: 'lead-review' });
  job(db, { id: 'jq1-slash', created: day(6), meta: 'path a\\b here' });
  job(db, { id: 'jq1-slash2', created: day(6, 13), meta: 'path ab here' });
  const q = async (s) => jobIds(await get(DB, `/api/jobs?${WEEK}&q=${encodeURIComponent(s)}`)).sort();
  assert.deepEqual(await q('50%_x'), ['jq1-lit']);
  assert.deepEqual(await q('_'), ['jq1-lit']);
  assert.deepEqual(await q('%'), ['jq1-lit']);
  assert.deepEqual(await q('a\\b'), ['jq1-slash']);
  assert.deepEqual(await q('bh-777'), ['jq1-tkt'], 'ticket_id is searched (LIKE is case-blind for ASCII)');
  assert.deepEqual(await q('lead-rev'), ['jq1-kind'], 'kind is searched');
  assert.equal((await q('   ')).length, 6, 'a blank q is no search');
  const r = await get(DB, '/api/jobs?q=50');
  assert.equal(r.status, 400);
  assert.deepEqual(r.body, { error: 'q needs a from/to range' });
});

test('JL1 lane, project, status and q combine with AND', { skip }, async () => {
  const { db, DB } = await openDb();
  job(db, { id: 'jl1-hit', project: 'pa', status: 'failed', created: day(2), meta: 'review me', lane: 'execute/pa/claude' });
  job(db, { id: 'jl1-lane', project: 'pa', status: 'failed', created: day(2), meta: 'review me', lane: 'plan/pa/claude' });
  job(db, { id: 'jl1-proj', project: 'pb', status: 'failed', created: day(2), meta: 'review me', lane: 'execute/pa/claude' });
  job(db, { id: 'jl1-stat', project: 'pa', status: 'done', created: day(2), meta: 'review me', lane: 'execute/pa/claude' });
  job(db, { id: 'jl1-q', project: 'pa', status: 'failed', created: day(2), meta: 'other', lane: 'execute/pa/claude' });
  job(db, { id: 'jl1-nolane', project: 'pa', status: 'failed', created: day(2), meta: 'review me' });
  const r = await get(DB, `/api/jobs?${WEEK}&lane=${encodeURIComponent('execute/pa/claude')}&project=pa&status=failed&q=review&totals=1`);
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.deepEqual(jobIds(r), ['jl1-hit']);
  assert.equal(r.body.totals.total, 1);
  const l = await get(DB, '/api/jobs?lane=execute%2Fpa%2Fclaude');
  assert.deepEqual(l.body, { error: 'lane needs a from/to range' });
});

test('JS1 sort=kind asc pages over ALL rows in range, not the newest page re-sorted', { skip }, async () => {
  const { db, DB } = await openDb();
  const all = [];
  for (let i = 0; i < 250; i++) {
    const r = { id: `js1-${String(i).padStart(3, '0')}`, kind: `k${String((i * 97) % 250).padStart(3, '0')}`,
      created: new Date(Date.parse('2026-10-01T00:00:00Z') + i * 60e3).toISOString().replace(/\.\d{3}Z$/, 'Z') };
    job(db, r);
    all.push(r);
  }
  all.sort((a, b) => (a.kind < b.kind ? -1 : a.kind > b.kind ? 1 : a.id < b.id ? -1 : 1));
  const r = await get(DB, `/api/jobs?${WEEK}&sort=kind&dir=asc&limit=50`);
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.deepEqual(jobIds(r), all.slice(0, 50).map((x) => x.id));
  assert.ok(r.body.next_cursor, 'a full page carries next_cursor');
  const desc = await get(DB, `/api/jobs?${WEEK}&sort=kind&dir=desc&limit=50`);
  assert.deepEqual(jobIds(desc), all.slice(-50).reverse().map((x) => x.id));
});

test('JC1 three pages through next_cursor equal the CSV rows; csv_row_cap truncates', { skip }, async () => {
  const { db, DB } = await openDb();
  for (let i = 0; i < 12; i++) {
    job(db, { id: `jc1-${String(i).padStart(2, '0')}`, kind: ['b', 'a', 'c'][i % 3], created: day(1 + (i % 6), 10 + i),
      lane: i % 2 ? 'execute/p1/claude' : undefined });
  }
  job(db, { id: 'jc1-out', kind: 'a', created: day(9) });
  const base = `/api/jobs?${WEEK}&sort=kind&dir=asc&limit=5`;
  const p = await pages(DB, base, 'jobs');
  assert.deepEqual(p.pages.map((x) => x.length), [5, 5, 2]);
  assert.equal(p.last.body.next_cursor, null);
  const paged = p.pages.flat();
  assert.equal(new Set(paged).size, 12, 'no row twice, none missed');
  const c = await get(DB, `/api/jobs?${WEEK}&sort=kind&dir=asc&limit=5&format=csv`);
  assert.equal(c.status, 200);
  assert.match(c.headers.get('content-type'), /^text\/csv/);
  assert.match(c.headers.get('content-disposition'), /filename="jobs-2026-10-01T00_00_00Z.csv"/);
  const lines = csvRows(c.text);
  assert.equal(lines[0], 'id,project,ticket_id,kind,box,stage,status,lane,budget_usd,spent_usd,created_at,updated_at');
  assert.deepEqual(lines.slice(1).map((l) => l.split(',')[0]), paged);
  const withLane = lines.slice(1).find((l) => l.startsWith('jc1-01,'));
  assert.equal(withLane.split(',')[7], 'execute/p1/claude');
  setting(db, 'mc.period.csv_row_cap', '5');
  const t = await get(DB, `/api/jobs?${WEEK}&sort=kind&dir=asc&format=csv`);
  assert.ok(t.text.endsWith('# truncated at 5\r\n'), t.text);
  assert.deepEqual(csvRows(t.text).slice(1, 6).map((l) => l.split(',')[0]), paged.slice(0, 5));
  const e = await get(DB, `/api/jobs?from=2026-01-01T00:00:00Z&to=2026-01-02T00:00:00Z&format=csv`);
  assert.equal(e.text, 'id,project,ticket_id,kind,box,stage,status,lane,budget_usd,spent_usd,created_at,updated_at\r\n');
});

test('JT1 totals, series by day and week (an empty bucket is null), 4 statements max', { skip }, async () => {
  const { db, DB } = await openDb();
  const st = ['running', 'running', 'done', 'done', 'done', 'failed', 'parked'];
  st.forEach((s, i) => job(db, { id: `jt1-${i}`, status: s, created: i < 3 ? day(1, 3 + i) : day(3, 3 + i) }));
  job(db, { id: 'jt1-out', status: 'done', created: day(8) });
  const log = [];
  const r = await get(capturingD1(db, log), `/api/jobs?${WEEK}&totals=1&series=day&sort=created_at`);
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.deepEqual(r.body.totals, { total: 7, running: 2, done: 3, failed: 1, other: 1 });
  assert.deepEqual(r.body.series, [
    { bucket: '2026-10-01', value: 3 }, { bucket: '2026-10-02', value: null }, { bucket: '2026-10-03', value: 4 },
    { bucket: '2026-10-04', value: null }, { bucket: '2026-10-05', value: null }, { bucket: '2026-10-06', value: null },
    { bucket: '2026-10-07', value: null },
  ]);
  assert.ok(log.length <= 4, `statements: ${log.length}`);
  const w = await get(DB, `/api/jobs?${WEEK}&series=week`);
  assert.deepEqual(w.body.series, [{ bucket: '2026-09-28', value: 7 }, { bucket: '2026-10-05', value: null }]);
  const h = await get(DB, '/api/jobs?from=2026-10-01T02:00:00Z&to=2026-10-01T06:00:00Z&series=hour');
  assert.deepEqual(h.body.series, [
    { bucket: '2026-10-01T02:00:00Z', value: null }, { bucket: '2026-10-01T03:00:00Z', value: 1 },
    { bucket: '2026-10-01T04:00:00Z', value: 1 }, { bucket: '2026-10-01T05:00:00Z', value: 1 },
  ]);
  const z = await get(DB, '/api/jobs?from=2026-01-01&to=2026-01-02&totals=1');
  assert.deepEqual(z.body.totals, { total: 0, running: 0, done: 0, failed: 0, other: 0 });
});

test('JN1 no range param and from-only keep the BH-9304 SQL text', { skip }, async () => {
  const { db, DB } = await openDb();
  job(db, { id: 'jn1-a', status: 'running', kind: 'build', created: day(2) });
  const a = [];
  await get(capturingD1(db, a), '/api/jobs');
  assert.deepEqual(a.map((s) => s.sql), [`${JOBS_SELECT} ORDER BY j.created_at DESC LIMIT 100`]);
  const b = [];
  const rb = await get(capturingD1(db, b), '/api/jobs?status=running&kind=build&limit=500');
  assert.deepEqual(jobIds(rb), ['jn1-a']);
  assert.deepEqual(b.map((s) => s.sql), [`${JOBS_SELECT} WHERE j.status=?1 AND j.kind=?2 ORDER BY j.created_at DESC LIMIT 500`]);
  const c = [];
  const rc = await get(capturingD1(db, c), `/api/jobs?${WEEK}`);
  assert.deepEqual(jobIds(rc), ['jn1-a']);
  assert.equal(rc.body.next_cursor, undefined, 'no sort, no cursor: no next_cursor key');
  const page = c.filter((s) => /FROM jobs j LEFT JOIN job_heartbeats/.test(s.sql)).map((s) => s.sql);
  assert.deepEqual(page, [`${JOBS_SELECT} WHERE j.created_at>=?1 AND j.created_at<?2 ORDER BY j.created_at DESC LIMIT 100`]);
});

test('JE1 49k jobs, 30-day range + q + sort: indexed page, lean CSV with no correlated subquery', { skip }, async () => {
  const vol = await openVolumeDb();
  const range = `from=${encodeURIComponent(isoAgo(30 * 24))}&to=${encodeURIComponent(NOW_ISO)}`;
  const planOf = async (path, re) => {
    const log = [];
    const r = await get(capturingD1(vol.db, log), path);
    assert.equal(r.status, 200, r.text.slice(0, 200));
    const hits = log.filter((s) => re.test(s.sql));
    assert.ok(hits.length > 0, `no statement matched ${re}`);
    return hits.map((h) => plan(vol.db, h.sql, ...h.binds));
  };
  const noFullScan = (lines) => {
    assert.ok(!lines.some((l) => /^SCAN j\b(?! USING)/.test(l)), lines.join(' | '));
    assert.ok(!lines.some((l) => /^SCAN (jobs|job_claims|job_heartbeats|job_phases)\b(?! USING)/.test(l)), lines.join(' | '));
  };
  const [pagePlan] = await planOf(`/api/jobs?${range}&q=T-1&sort=created_at&limit=200`, /FROM jobs j LEFT JOIN job_heartbeats/);
  noFullScan(pagePlan);
  assert.ok(pagePlan.some((l) => /idx_jobs_created/.test(l)), pagePlan.join(' | '));
  const [csvPlan] = await planOf(`/api/jobs?${range}&q=T-1&sort=created_at&format=csv`, /FROM jobs j LEFT JOIN job_claims/);
  noFullScan(csvPlan);
  assert.ok(!csvPlan.some((l) => /CORRELATED/.test(l)), csvPlan.join(' | '));
  const aggPlans = await planOf(`/api/jobs?${range}&q=T-1&totals=1&series=day`, /COUNT\(\*\)/);
  assert.equal(aggPlans.length, 2);
  for (const p of aggPlans) noFullScan(p);
  console.log(`JE1 page plan: ${pagePlan.join(' | ')}`);
  console.log(`JE1 csv plan: ${csvPlan.join(' | ')}`);
});

// ── /api/lane-runs ────────────────────────────────────────────────────────

test('LR1 a lane-runs range on enqueued_at: only in-range rows, newest first', { skip }, async () => {
  const { db, DB } = await openDb();
  run(db, { enq: '2026-09-30T23:59:59Z', project: 'lr1a' });
  const first = run(db, { enq: '2026-10-01T00:00:00Z', project: 'lr1b' });
  const last = run(db, { enq: '2026-10-07T23:59:59Z', project: 'lr1c' });
  run(db, { enq: '2026-10-08T00:00:00Z', project: 'lr1d' });
  const r = await get(DB, `/api/lane-runs?${WEEK}`);
  assert.equal(r.status, 200, r.text);
  assert.deepEqual(runIds(r), [last, first]);
  assert.equal(r.body.truncated, false);
  assert.equal(r.body.next_cursor, null);
  assert.equal(r.body.limit, 200);
});

test('LQ1 q searches args_json, lane, project, claimed_by and prof_line, with escapes', { skip }, async () => {
  const { db, DB } = await openDb();
  const lit = run(db, { enq: day(2), project: 'lq1a', args: '["bin/x.sh","50%_x"]' });
  run(db, { enq: day(2), project: 'lq1b', args: '["bin/x.sh","50abx"]' });
  const lane = run(db, { enq: day(3), project: 'lq1c', lane: 'zebra-lane' });
  const by = run(db, { enq: day(3), project: 'lq1d', status: 'claimed', by: 'machine-qq' });
  const prof = run(db, { enq: day(4), project: 'lq1e', status: 'done', by: 'm1', rc: 0, prof: 'PROF unicorn ms=1' });
  const proj = run(db, { enq: day(4), project: 'yak-project' });
  const q = async (s) => runIds(await get(DB, `/api/lane-runs?${WEEK}&q=${encodeURIComponent(s)}`)).sort((a, b) => a - b);
  assert.deepEqual(await q('50%_x'), [lit]);
  assert.deepEqual(await q('_'), [lit]);
  assert.deepEqual(await q('zebra'), [lane]);
  assert.deepEqual(await q('machine-qq'), [by]);
  assert.deepEqual(await q('unicorn'), [prof]);
  assert.deepEqual(await q('yak'), [proj]);
  const r = await get(DB, '/api/lane-runs?q=zebra');
  assert.deepEqual(r.body, { error: 'q needs a from/to range' });
});

test('LF1 lane, project, machine and status combine; failed = done + rc<>0; done excludes rc<>0', { skip }, async () => {
  const { db, DB } = await openDb();
  const ok0 = run(db, { enq: day(2), lane: 'L1', project: 'pa', status: 'done', by: 'm1', rc: 0 });
  const okNull = run(db, { enq: day(2, 13), lane: 'L1', project: 'pb', status: 'done', by: 'm1', rc: null });
  const bad = run(db, { enq: day(3), lane: 'L1', project: 'pa', status: 'done', by: 'm1', rc: 3 });
  const bad2 = run(db, { enq: day(3, 13), lane: 'L1', project: 'pa', status: 'done', by: 'm2', rc: 127 });
  const died = run(db, { enq: day(4), lane: 'L1', project: 'pa', status: 'died', by: 'm1', rc: 137 });
  run(db, { enq: day(4), lane: 'L2', project: 'pa', status: 'done', by: 'm1', rc: 3 });
  const ids = async (qs) => runIds(await get(DB, `/api/lane-runs?${WEEK}&${qs}`)).sort((a, b) => a - b);
  assert.deepEqual(await ids('lane=L1&status=failed'), [bad, bad2]);
  assert.deepEqual(await ids('lane=L1&status=done'), [ok0, okNull]);
  assert.deepEqual(await ids('lane=L1&project=pa&machine=m1&status=failed'), [bad]);
  assert.deepEqual(await ids('lane=L1&project=pa&machine=m1'), [ok0, bad, died]);
  assert.deepEqual(await ids('lane=L1&status=died'), [died]);
  const f = await get(DB, '/api/lane-runs?status=failed');
  assert.deepEqual(f.body, { error: 'status must be one of queued|claimed|done|died' });
});

test('LS1 sort over all rows in range (lane asc, attempts desc with a number cursor)', { skip }, async () => {
  const { db, DB } = await openDb();
  const all = [];
  for (let i = 0; i < 250; i++) {
    const r = { lane: `lane-${String((i * 97) % 250).padStart(3, '0')}`, project: `p${i}`, attempts: (i * 7) % 5,
      enq: new Date(Date.parse('2026-10-01T00:00:00Z') + i * 60e3).toISOString().replace(/\.\d{3}Z$/, 'Z') };
    r.id = run(db, r);
    all.push(r);
  }
  const byLane = [...all].sort((a, b) => (a.lane < b.lane ? -1 : a.lane > b.lane ? 1 : a.id - b.id));
  const r = await get(DB, `/api/lane-runs?${WEEK}&sort=lane&dir=asc&limit=50`);
  assert.equal(r.status, 200, r.text);
  assert.deepEqual(runIds(r), byLane.slice(0, 50).map((x) => x.id));
  assert.equal(r.body.truncated, true);
  const byAtt = [...all].sort((a, b) => (b.attempts - a.attempts) || (b.id - a.id)).map((x) => x.id);
  const p = await pages(DB, `/api/lane-runs?${WEEK}&sort=attempts&dir=desc&limit=100`, 'runs');
  assert.deepEqual(p.pages.flat(), byAtt);
});

test('LC1 three pages through next_cursor equal the CSV rows', { skip }, async () => {
  const { db, DB } = await openDb();
  for (let i = 0; i < 10; i++) {
    run(db, { enq: day(1 + (i % 5), 10 + i), project: ['pb', 'pa', 'pc'][i % 3], lane: `lc1-${i}`,
      status: 'done', by: 'm1', rc: i % 4 ? 0 : 2 });
  }
  run(db, { enq: day(9), project: 'pa', lane: 'lc1-out' });
  const p = await pages(DB, `/api/lane-runs?${WEEK}&sort=project&dir=asc&limit=4`, 'runs');
  assert.deepEqual(p.pages.map((x) => x.length), [4, 4, 2]);
  const paged = p.pages.flat();
  const c = await get(DB, `/api/lane-runs?${WEEK}&sort=project&dir=asc&limit=4&format=csv`);
  assert.equal(c.status, 200);
  assert.match(c.headers.get('content-disposition'), /filename="lane-runs-2026-10-01T00_00_00Z.csv"/);
  const lines = csvRows(c.text);
  assert.equal(lines[0], 'id,lane,project,status,rc,enqueued_at,claimed_at,claimed_by,finished_at,attempts');
  assert.deepEqual(lines.slice(1).map((l) => Number(l.split(',')[0])), paged);
  setting(db, 'mc.period.csv_row_cap', '3');
  const t = await get(DB, `/api/lane-runs?${WEEK}&format=csv`);
  assert.ok(t.text.endsWith('# truncated at 3\r\n'), t.text);
});

test('LT1 lane-runs totals and series (an empty bucket is null)', { skip }, async () => {
  const { db, DB } = await openDb();
  run(db, { enq: day(1, 1), project: 'lt1a', status: 'queued' });
  run(db, { enq: day(1, 2), project: 'lt1b', status: 'claimed', by: 'm1' });
  run(db, { enq: day(1, 3), project: 'lt1c', status: 'done', by: 'm1', rc: 0 });
  run(db, { enq: day(3, 3), project: 'lt1d', status: 'done', by: 'm1', rc: null });
  run(db, { enq: day(3, 4), project: 'lt1e', status: 'done', by: 'm1', rc: 1 });
  run(db, { enq: day(3, 5), project: 'lt1f', status: 'died', by: 'm1', rc: 137 });
  run(db, { enq: day(9), project: 'lt1g', status: 'done', by: 'm1', rc: 1 });
  const log = [];
  const r = await get(capturingD1(db, log), `/api/lane-runs?${WEEK}&totals=1&series=day`);
  assert.equal(r.status, 200, r.text);
  assert.deepEqual(r.body.totals, { total: 6, queued: 1, claimed: 1, done: 2, failed: 1, died: 1 });
  assert.deepEqual(r.body.series.map((s) => s.value), [3, null, 3, null, null, null, null]);
  assert.equal(r.body.series[0].bucket, '2026-10-01');
  assert.ok(log.filter((s) => !/^PRAGMA/.test(s.sql)).length <= 4, `statements: ${log.map((s) => s.sql).join(' || ')}`);
  const z = await get(DB, '/api/lane-runs?from=2026-01-01&to=2026-01-02&totals=1');
  assert.deepEqual(z.body.totals, { total: 0, queued: 0, claimed: 0, done: 0, failed: 0, died: 0 });
});

const LANE_RUNS_NO_RANGE_SQL = `SELECT id, lane, project, status, enqueued_at, claimed_at, claimed_by, finished_at, rc, attempts, harness_commit
           FROM lane_runs
          WHERE (?1 IS NULL OR lane=?1) AND (?2 IS NULL OR claimed_by=?2) AND (?3 IS NULL OR status=?3)
          ORDER BY id DESC LIMIT ?4`;

test('LN0 lane-runs with no from: the current SQL text and answer', { skip }, async () => {
  const { db, DB } = await openDb();
  const a = run(db, { enq: day(1), project: 'ln0a', lane: 'ln0' });
  const b = run(db, { enq: day(9), project: 'ln0b', lane: 'ln0' });
  const c = run(db, { enq: '2025-01-01T00:00:00Z', project: 'ln0c', lane: 'ln0' });
  const log = [];
  const r = await get(capturingD1(db, log), '/api/lane-runs?lane=ln0&limit=2');
  assert.equal(r.status, 200, r.text);
  assert.deepEqual(runIds(r), [c, b]);
  assert.equal(r.body.truncated, true);
  assert.equal(r.body.limit, 2);
  assert.equal(r.body.next_cursor, undefined);
  assert.equal(r.body.totals, undefined);
  assert.deepEqual(log.filter((s) => /FROM lane_runs/.test(s.sql)).map((s) => s.sql), [LANE_RUNS_NO_RANGE_SQL]);
  assert.deepEqual(log.find((s) => /FROM lane_runs/.test(s.sql)).binds, ['ln0', null, null, 3]);
  assert.equal(log.filter((s) => /FROM settings/.test(s.sql)).length, 0, 'no knob read with no range');
  assert.ok(a);
  for (const p of ['q=x', 'project=p1', 'sort=id', 'dir=asc', 'cursor=abc', 'totals=1', 'series=day', 'format=csv']) {
    const n = await get(DB, `/api/lane-runs?${p}`);
    assert.equal(n.status, 400, p);
    assert.deepEqual(n.body, { error: `${p.split('=')[0]} needs a from/to range` }, p);
  }
});

test('LE1 200k lane_runs, 30-day range with and without project: index plans, no full scan', { skip }, async () => {
  const { db, DB } = await openDb();
  const ANCHOR = Date.parse('2026-11-01T00:00:00Z');
  const N = 200000, SPAN = 60 * 86400e3;
  const PROJECTS = ['alpha', 'bravo', 'charlie', 'delta', 'echo', 'foxtrot', 'golf', 'hotel', 'india', 'juliet', 'kilo', 'lima', 'mike'];
  const iso = (msv) => new Date(msv).toISOString().replace(/\.\d{3}Z$/, 'Z');
  const ins = db.prepare(
    `INSERT INTO lane_runs (lane, project, args_json, enqueued_at, enqueued_by, claimed_at, claimed_by,
       attempts, status, rc, prof_line, finished_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)`);
  db.exec('BEGIN');
  for (let i = 0; i < N; i++) {
    const enq = iso(ANCHOR - SPAN + Math.floor((i / N) * SPAN));
    ins.run(`lane-${i % 40}`, PROJECTS[i % 13], `["bin/lane-${i % 40}.sh","${PROJECTS[i % 13]}"]`, enq, 'hub',
      enq, `m${i % 7}`, 1, 'done', i % 9 ? 0 : 1, null, enq);
  }
  db.exec('COMMIT');
  const range = 'from=2026-10-02T00:00:00Z&to=2026-11-01T00:00:00Z';
  const plans = async (qs) => {
    const log = [];
    const r = await get(capturingD1(db, log), `/api/lane-runs?${range}${qs}&totals=1&series=day`);
    assert.equal(r.status, 200, r.text.slice(0, 200));
    const hits = log.filter((s) => /FROM lane_runs/.test(s.sql));
    assert.equal(hits.length, 3, 'page, totals, series');
    return hits.map((h) => plan(db, h.sql, ...h.binds));
  };
  const check = (lines, idx) => {
    assert.ok(lines.some((l) => idx.test(l)), lines.join(' | '));
    assert.ok(!lines.some((l) => /^SCAN lane_runs\b(?! USING)/.test(l)), lines.join(' | '));
    assert.ok(!lines.some((l) => /CORRELATED/.test(l)), lines.join(' | '));
  };
  const plain = await plans('');
  for (const p of plain) check(p, /USING (COVERING )?INDEX idx_lane_runs_enqueued \(enqueued_at>\? AND enqueued_at<\?\)/);
  const proj = await plans('&project=golf');
  for (const p of proj) check(p, /USING (COVERING )?INDEX idx_lane_runs_project_enqueued \(project=\? AND enqueued_at>\? AND enqueued_at<\?\)/);
  console.log(`LE1 page plan: ${plain[0].join(' | ')}`);
  console.log(`LE1 page plan with project: ${proj[0].join(' | ')}`);
  console.log(`LE1 totals plan: ${plain[1].join(' | ')}`);
  console.log(`LE1 totals plan with project: ${proj[1].join(' | ')}`);
  const csvLog = [];
  const c = await get(capturingD1(db, csvLog), `/api/lane-runs?${range}&format=csv`);
  assert.equal(c.status, 200);
  const csvSql = csvLog.find((s) => /FROM lane_runs/.test(s.sql));
  check(plan(db, csvSql.sql, ...csvSql.binds), /idx_lane_runs_enqueued/);
});

// ── negatives ─────────────────────────────────────────────────────────────

const enc = (o) => Buffer.from(JSON.stringify(o)).toString('base64url');

test('NEG every refused value is a 400 and no table is read after the settings read', { skip }, async () => {
  const { db } = await openDb();
  job(db, { id: 'neg-1', created: day(2) });
  run(db, { enq: day(2) });
  const cases = [
    ['from=1', /from is not an ISO date/],
    [`from=${encodeURIComponent('2026-10-01;DROP')}`, /from is not an ISO date/],
    [`${WEEK}&sort=${encodeURIComponent('ts;--')}`, /^sort must be one of /],
    [`${WEEK}&dir=sideways`, /^dir must be asc or desc$/],
    [`${WEEK}&series=minute`, /^series must be hour, day or week$/],
    [`${WEEK}&series=${encodeURIComponent('strftime(\'%s\',x)')}`, /^series must be hour, day or week$/],
    [`${WEEK}&cursor=abc`, /^cursor is not valid$/],
    [`${WEEK}&cursor=${enc(['x'])}`, /^cursor is not valid$/],
    ['from=2026-01-01&to=2026-10-01&series=hour', /^range has over 2000 hour buckets \(mc\.period\.max_buckets\)$/],
    [`${WEEK}&format=xml`, /^format must be csv$/],
    [`${WEEK}&totals=2`, /^totals must be 1$/],
    ['q=abc', /^q needs a from\/to range$/],
    ['series=day', /^series needs a from\/to range$/],
  ];
  const routeCases = {
    '/api/jobs': [...cases, [`${WEEK}&sort=created_at&cursor=${enc([5, 'neg-1'])}`, /^cursor is not valid$/],
      [`${WEEK}&cursor=${enc(['2026-10-02T12:00:00Z', 7])}`, /^cursor is not valid$/]],
    '/api/lane-runs': [...cases, [`${WEEK}&sort=id&cursor=${enc(['x', 1])}`, /^cursor is not valid$/],
      [`${WEEK}&cursor=${enc(['2026-10-02T12:00:00Z', 'x'])}`, /^cursor is not valid$/],
      [`${WEEK}&status=bogus`, /^status must be one of /], [`${WEEK}&project=${encodeURIComponent('a b')}`, /^project must match/]],
  };
  for (const [route, list] of Object.entries(routeCases)) {
    for (const [qs, re] of list) {
      const log = [];
      const r = await get(capturingD1(db, log), `${route}?${qs}`);
      assert.equal(r.status, 400, `${route}?${qs}: ${r.text}`);
      assert.match(r.body.error, re, `${route}?${qs}`);
      assert.ok(log.length <= 1, `${route}?${qs}: ${log.map((s) => s.sql).join(' || ')}`);
      assert.ok(log.every((s) => /FROM settings/.test(s.sql)), `${route}?${qs}: a table read ran: ${log.map((s) => s.sql).join(' || ')}`);
    }
  }
});

// ── LK: the log screens' row caps are settings rows (lead BLOCK hardcoded-knob)
// The period report's top rows and the LANE/PROJECT chip cap were literals in
// the console (limit: 20, .slice(0, 30)). They are mc.period.report_top_rows
// and mc.period.filter_chip_cap, served by GET /api/period/knobs; 20 and 30
// are only the code fallbacks.
test('LK1 the composed schema seeds report_top_rows and filter_chip_cap; a row overrides; junk uses the fallback', { skip }, async () => {
  const { db, DB } = await openDb();
  const seeded = db.prepare("SELECT key, value FROM settings WHERE key IN ('mc.period.report_top_rows','mc.period.filter_chip_cap') ORDER BY key").all()
    .map((r) => [r.key, r.value]);
  assert.deepEqual(seeded, [['mc.period.filter_chip_cap', '30'], ['mc.period.report_top_rows', '20']]);
  let r = await get(DB, '/api/period/knobs');
  assert.equal(r.status, 200, r.text);
  assert.equal(r.body.knobs.report_top_rows, 20);
  assert.equal(r.body.knobs.filter_chip_cap, 30);
  assert.equal(r.body.source.report_top_rows, 'row');
  setting(db, 'mc.period.report_top_rows', '7');
  setting(db, 'mc.period.filter_chip_cap', '12');
  r = await get(DB, '/api/period/knobs');
  assert.deepEqual([r.body.knobs.report_top_rows, r.body.knobs.filter_chip_cap], [7, 12]);
  // 0, over the route limit cap (500 / 200) and junk are not valid: fallback.
  for (const [top, chips] of [['0', '0'], ['201', '501'], ['abc', '1.5']]) {
    setting(db, 'mc.period.report_top_rows', top);
    setting(db, 'mc.period.filter_chip_cap', chips);
    r = await get(DB, '/api/period/knobs');
    assert.deepEqual([r.body.knobs.report_top_rows, r.body.knobs.filter_chip_cap], [20, 30], `${top}/${chips}`);
    assert.deepEqual([r.body.source.report_top_rows, r.body.source.filter_chip_cap], ['fallback', 'fallback']);
  }
});
