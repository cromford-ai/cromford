// BH-9304 (BH-9120.0): GET /api/jobs takes a from/to range, through the real
// worker.fetch route table, on the node:sqlite D1 (the real SQL runs).
//
// J1 in-range rows only; J2 with project; J3 a bad range is a 400 and reads no
// jobs; J4 no range param = today's SQL text and answer; J5 from only = up to
// the server clock. E1/E2 EXPLAIN QUERY PLAN at BH-6727 volume (49k jobs).
// Each test opens its own in-memory D1 and seeds its own ids.
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { JOBS_SELECT } from '../src/lib/core.js';
import { parseRange } from '../src/lib/period.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import { openVolumeDb, capturingD1, plan, NOW_ISO, isoAgo } from './lib/d1-volume.bh-6727.js';
import { iso } from './lib/harness.js';

const SECRET = 'test-secret';

function seed(db, rows) {
  const ins = db.prepare(`INSERT INTO jobs (id, project, kind, box, stage, status, created_at, updated_at)
                          VALUES (?,?,?,?,?,?,?,?)`);
  for (const [id, project, created] of rows) ins.run(id, project, 'build', 'box-1', 'execute', 'done', created, created);
}

async function get(DB, path) {
  const res = await worker.fetch(new Request(`https://jobs.test${path}`, {
    headers: { authorization: `Bearer ${SECRET}` },
  }), { DB, HARNESS_SECRET: SECRET });
  return { status: res.status, body: await res.json() };
}
const ids = (body) => body.jobs.map((j) => j.id);
const WEEK = 'from=2026-10-01T00:00:00Z&to=2026-10-08T00:00:00Z';

test('J1 GET /api/jobs?from=&to= returns only the rows created inside [from, to)', async (t) => {
  const o = await openDb();
  if (!o) return t.skip('node:sqlite is absent');
  seed(o.db, [
    ['j1-before', 'p1', '2026-09-30T23:59:59Z'],
    ['j1-first', 'p1', '2026-10-01T00:00:00Z'],
    ['j1-last', 'p1', '2026-10-07T23:59:59Z'],
    ['j1-after', 'p1', '2026-10-08T00:00:00Z'],
  ]);
  const r = await get(o.DB, `/api/jobs?${WEEK}&limit=200`);
  assert.equal(r.status, 200);
  assert.deepEqual(ids(r.body), ['j1-last', 'j1-first']);
});

test('J2 a range plus project: another project inside the range is absent', async (t) => {
  const o = await openDb();
  if (!o) return t.skip('node:sqlite is absent');
  seed(o.db, [
    ['j2-in', 'p1', '2026-10-03T00:00:00Z'],
    ['j2-other', 'p2', '2026-10-03T00:00:00Z'],
    ['j2-out', 'p1', '2026-10-09T00:00:00Z'],
  ]);
  const r = await get(o.DB, `/api/jobs?project=p1&${WEEK}`);
  assert.equal(r.status, 200);
  assert.deepEqual(ids(r.body), ['j2-in']);
});

test('J3 a bad range is a 400 with the reason, and no jobs statement runs', async (t) => {
  const o = await openDb();
  if (!o) return t.skip('node:sqlite is absent');
  seed(o.db, [['j3-a', 'p1', '2026-10-03T00:00:00Z']]);
  const cases = [
    ['from=1', 'from is not an ISO date (YYYY-MM-DD or YYYY-MM-DDTHH:MM[:SS]Z)'],
    [`from=${encodeURIComponent('2026-10-01;DROP')}`, 'from is not an ISO date (YYYY-MM-DD or YYYY-MM-DDTHH:MM[:SS]Z)'],
    ['from=2026-10-08&to=2026-10-01', 'from must be before to'],
    ['from=2025-10-01&to=2026-10-03', 'range is over 366 days (mc.period.max_range_days)'],
    ['to=2026-10-01', 'from is required when to is given'],
    ['from=', 'from is not an ISO date (YYYY-MM-DD or YYYY-MM-DDTHH:MM[:SS]Z)'],
  ];
  for (const [qs, reason] of cases) {
    const log = [];
    const r = await get(capturingD1(o.db, log), `/api/jobs?${qs}`);
    assert.equal(r.status, 400, qs);
    assert.deepEqual(r.body, { error: reason }, qs);
    assert.equal(log.filter((s) => /FROM jobs/.test(s.sql)).length, 0, `${qs}: a jobs read ran`);
    assert.equal(log.filter((s) => /FROM settings/.test(s.sql)).length, 1, `${qs}: one knob read`);
  }
});

test('J4 with no range param the SQL text and the answer are unchanged', async (t) => {
  const o = await openDb();
  if (!o) return t.skip('node:sqlite is absent');
  seed(o.db, [
    ['j4-a', 'p1', '2026-10-01T00:00:00Z'],
    ['j4-b', 'p1', '2026-10-05T00:00:00Z'],
    ['j4-c', 'p2', '2026-10-09T00:00:00Z'],
  ]);
  const log = [];
  const r = await get(capturingD1(o.db, log), '/api/jobs?project=p1&status=done&limit=200');
  assert.equal(r.status, 200);
  assert.deepEqual(ids(r.body), ['j4-b', 'j4-a']);
  // The text main built before BH-9304, copied here as a literal suffix.
  assert.deepEqual(log.map((s) => s.sql),
    [`${JOBS_SELECT} WHERE j.project=?1 AND j.status=?2 ORDER BY j.created_at DESC LIMIT 200`]);
  assert.deepEqual(log[0].binds, ['p1', 'done']);
  const all = [];
  const r2 = await get(capturingD1(o.db, all), '/api/jobs');
  assert.deepEqual(ids(r2.body), ['j4-c', 'j4-b', 'j4-a']);
  assert.deepEqual(all.map((s) => s.sql), [`${JOBS_SELECT} ORDER BY j.created_at DESC LIMIT 100`]);
});

test('J5 from only: rows from `from` up to the server clock, never a later row', async (t) => {
  const o = await openDb();
  if (!o) return t.skip('node:sqlite is absent');
  const day = 86400e3;
  seed(o.db, [
    ['j5-old', 'p1', iso(3 * day)],
    ['j5-in', 'p1', iso(1 * day)],
    ['j5-future', 'p1', iso(-3600e3)],
  ]);
  const log = [];
  const r = await get(capturingD1(o.db, log), `/api/jobs?from=${encodeURIComponent(iso(2 * day))}`);
  assert.equal(r.status, 200);
  assert.deepEqual(ids(r.body), ['j5-in']);
  const jobsSql = log.find((s) => /FROM jobs j/.test(s.sql));
  assert.match(jobsSql.sql, / WHERE j\.created_at>=\?1 AND j\.created_at<\?2 ORDER BY j\.created_at DESC LIMIT 100$/);
  assert.equal(jobsSql.binds[1], r.body.as_of, 'the open end is the server clock');
});

test('J6 the URL the console sends parses to the same pair the route binds', () => {
  const url = new URL('https://jobs.test/api/jobs?from=2026-10-01T00%3A00%3A00Z&to=2026-10-08T00%3A00%3A00Z&limit=200');
  assert.deepEqual(parseRange(url, {}, Date.parse('2026-11-14T00:00:00Z')),
    { from: '2026-10-01T00:00:00Z', to: '2026-10-08T00:00:00Z' });
});

const vol = await openVolumeDb();

async function planOfRange(path) {
  const log = [];
  const r = await get(capturingD1(vol.db, log), path);
  assert.equal(r.status, 200, `${path}: ${JSON.stringify(r.body)}`);
  const hit = log.find((s) => /FROM jobs j LEFT JOIN job_heartbeats/.test(s.sql));
  assert.ok(hit, 'the route ran the jobs read');
  assert.match(hit.sql, /j\.created_at>=\?\d+ AND j\.created_at<\?\d+/);
  return plan(vol.db, hit.sql, ...hit.binds);
}
function assertIndexed(lines, idx) {
  assert.ok(lines.some((l) => idx.test(l)), lines.join(' | '));
  // No full read of jobs: a SCAN of j is allowed only as an ordered walk of an index.
  assert.ok(!lines.some((l) => /^SCAN j\b(?! USING INDEX)/.test(l)), lines.join(' | '));
  assert.ok(!lines.some((l) => /^SCAN (jobs|job_heartbeats|job_claims|job_phases)\b/.test(l)), lines.join(' | '));
  // JOBS_SELECT's existing per-row phase lookups (bounded by LIMIT) are key
  // searches; no correlated subquery scans a table.
  for (let i = 0; i < lines.length; i++) {
    if (/CORRELATED/.test(lines[i])) assert.ok(!/^SCAN /.test(lines[i + 1] || ''), lines.join(' | '));
  }
  assert.ok(!lines.some((l) => /TEMP B-TREE FOR ORDER BY/.test(l)), lines.join(' | '));
}

const RANGE = `from=${encodeURIComponent(isoAgo(30 * 24))}&to=${encodeURIComponent(NOW_ISO)}`;

test('E1 a 30-day range at 49k jobs reads idx_jobs_created, no plain SCAN jobs', { skip: !vol }, async () => {
  const lines = await planOfRange(`/api/jobs?${RANGE}&limit=200`);
  assertIndexed(lines, /idx_jobs_created \(created_at>\? AND created_at<\?\)/);
});

test('E2 a 30-day range plus project reads idx_jobs_project_created', { skip: !vol }, async () => {
  const lines = await planOfRange(`/api/jobs?project=alpha&${RANGE}&limit=200`);
  assertIndexed(lines, /idx_jobs_project_created \(project=\? AND created_at>\? AND created_at<\?\)/);
});
