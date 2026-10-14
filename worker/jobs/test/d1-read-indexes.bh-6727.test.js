// BH-6727: the hot reads of the harness-jobs D1 use an index, on a D1 seeded at
// the live row counts of the 2026-10-14 incident (wakes 206k, cost_rows 95k, jobs 49k,
// job_heartbeats 46k, ledgers 27k). Live, these five shapes read 100-160M rows
// an hour and D1 answered "overloaded" 875 times in 5 hours.
//
// Each case runs the REAL route (or the real section reader) against the
// seeded D1, records the statements it read with (capturingD1), and runs
// EXPLAIN QUERY PLAN on the hot one with the binds the route used. No ANALYZE
// is run: D1 has no statistics either, and that is when SQLite chose the scans.
// A plan line `SCAN <hot table>` is a full read of the table or of one of its
// indexes, and fails the case. The one allowed scan is the jobs list with no
// filter: an ordered walk of idx_jobs_created that stops at the LIMIT.
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { readCoreSections } from '../src/lib/daily-digest/core-sections.js';
import { openVolumeDb, capturingD1, plan, NOW_ISO, isoAgo } from './lib/d1-volume.bh-6727.js';

const SECRET = 'test-secret';
const HOT = ['wakes', 'jobs', 'cost_rows', 'ledgers', 'job_artifacts', 'job_heartbeats'];
const vol = await openVolumeDb();

async function reads(path) {
  const log = [];
  const DB = capturingD1(vol.db, log);
  const res = await worker.fetch(new Request(`https://jobs.test${path}`, {
    headers: { authorization: `Bearer ${SECRET}` },
  }), { DB, HARNESS_SECRET: SECRET });
  assert.equal(res.status, 200, `${path} answered ${res.status}`);
  return log;
}
// The plan of the one captured statement that matches `re`.
function planOf(log, re) {
  const hit = log.filter((r) => re.test(r.sql));
  assert.ok(hit.length > 0, `no statement matched ${re}`);
  return plan(vol.db, hit[0].sql, ...hit[0].binds.map((v) => (v === undefined ? null : v)));
}
function noFullScan(lines, allow = []) {
  const bad = lines.filter((l) => {
    const m = /^SCAN (\w+)/.exec(l);
    return m && HOT.includes(m[1]) && !allow.some((a) => a.test(l));
  });
  assert.deepEqual(bad, [], `full scan of a hot table:\n  ${lines.join('\n  ')}`);
}

test('I1: GET /api/wakes/summary?hours=1 reads the window through idx_wakes_at, not every wake', { skip: !vol }, async () => {
  const lines = planOf(await reads('/api/wakes/summary?hours=1'), /FROM wakes WHERE at >=/);
  noFullScan(lines);
  assert.ok(lines.some((l) => /SEARCH wakes USING INDEX idx_wakes_at/.test(l)), lines.join(' | '));
});

test('I2: GET /api/wakes?since=&repo= walks (repo, id)', { skip: !vol }, async () => {  // determinism: ok since= is a wake id cursor, not a time
  const lines = planOf(await reads('/api/wakes?since=100&repo=o%2Falpha&limit=200'), /FROM wakes WHERE id >/);  // determinism: ok since= is a wake id cursor, not a time
  noFullScan(lines);
  assert.ok(lines.some((l) => /idx_wakes_repo_id \(repo=\? AND id>\?\)/.test(l)), lines.join(' | '));
});

test('I3: GET /api/jobs reads the newest rows off an index ending in created_at, with no sort', { skip: !vol }, async () => {
  const cases = [
    ['/api/jobs?status=done&limit=100', /idx_jobs_status_created/],
    ['/api/jobs?status=running&limit=500&stale_min=30', /idx_jobs_status_created/],
    ['/api/jobs?project=alpha&limit=100', /idx_jobs_project_created/],
    ['/api/jobs?project=alpha&status=running&limit=100', /idx_jobs_project_status_created/],
    ['/api/jobs?project=alpha&ticket_id=T-1&kind=build&limit=5', /idx_jobs_project_ticket_created/],
    ['/api/jobs?limit=100', /idx_jobs_created/],
  ];
  for (const [path, idx] of cases) {
    const lines = planOf(await reads(path), /FROM jobs j LEFT JOIN job_heartbeats/);
    noFullScan(lines, [/^SCAN j USING INDEX idx_jobs_created$/]);
    assert.ok(lines.some((l) => idx.test(l)), `${path}: ${lines.join(' | ')}`);
    assert.ok(!lines.some((l) => /TEMP B-TREE FOR ORDER BY/.test(l)), `${path} sorts the rows: ${lines.join(' | ')}`);
    assert.ok(lines.some((l) => /SEARCH h USING INDEX sqlite_autoindex_job_heartbeats_1|SEARCH h USING PRIMARY KEY/.test(l)),
      `${path}: the heartbeat join is a key lookup: ${lines.join(' | ')}`);
  }
});

test('I4: GET /api/metrics/cost-rows?since=&until= reads the ts range through idx_cost_rows_ts', { skip: !vol }, async () => {  // determinism: ok fixtures are offsets from the clock anchor in lib/d1-volume; the plan does not depend on the rows
  const lines = planOf(await reads(`/api/metrics/cost-rows?since=${isoAgo(17)}&until=${NOW_ISO}&limit=500`),  // determinism: ok fixtures are offsets from the clock anchor in lib/d1-volume; the plan does not depend on the rows
    /FROM cost_rows/);
  noFullScan(lines);
  assert.ok(lines.some((l) => /idx_cost_rows_ts/.test(l)), lines.join(' | '));
});

test('I5: the daily digest finds merged tickets from the merge window, not per jobs row', { skip: !vol }, async () => {
  const log = [];
  const DB = capturingD1(vol.db, log);
  await readCoreSections(DB, { from: isoAgo(48), to: isoAgo(24), day: isoAgo(48).slice(0, 10) }, { now: NOW_ISO });
  const lines = planOf(log, /MIN\(issue_created_at\)|MIN\(j\.issue_created_at\)/);
  noFullScan(lines);
  assert.ok(!lines.some((l) => /CORRELATED/.test(l)), `a correlated subquery re-runs per row: ${lines.join(' | ')}`);
  assert.ok(lines.some((l) => /idx_ledgers_kind_status_created/.test(l)), lines.join(' | '));
});

test('I6: the digest answer is the same rows as the old correlated query', { skip: !vol }, async () => {
  const from = isoAgo(48), to = isoAgo(24);
  const old = vol.db.prepare(
    `SELECT project, ticket_id, MIN(issue_created_at) AS issue_created_at FROM jobs
      WHERE issue_created_at IS NOT NULL AND ticket_id IS NOT NULL
        AND EXISTS (SELECT 1 FROM job_artifacts a JOIN jobs j2 ON j2.id=a.job_id
                     WHERE a.artifact_kind='pr_url'
                       AND a.artifact_ref IN (SELECT key FROM ledgers
                                             WHERE kind='merge' AND status='merged' AND created_at>=?1 AND created_at<?2)
                       AND j2.project=jobs.project AND j2.ticket_id=jobs.ticket_id)
      GROUP BY project, ticket_id ORDER BY project, ticket_id`).all(from, to);
  const log = [];
  await readCoreSections(capturingD1(vol.db, log), { from, to, day: from.slice(0, 10) }, { now: NOW_ISO });
  const q = log.find((r) => /MIN\(j\.issue_created_at\)|MIN\(issue_created_at\)/.test(r.sql));
  const neu = vol.db.prepare(`SELECT * FROM (${q.sql}) ORDER BY project, ticket_id`).all(from, to);
  assert.ok(old.length > 0, 'the fixture has merged tickets in the window');
  assert.deepEqual(neu.map((r) => ({ ...r })), old.map((r) => ({ ...r })));
});

test('I7: GET /api/metrics/dora reads build launches through idx_jobs_kind_spawn', { skip: !vol }, async () => {
  const lines = planOf(await reads('/api/metrics/dora?days=30'), /MIN\(first_spawn_at\)/);  // determinism: ok fixtures are offsets from the clock anchor in lib/d1-volume; the plan does not depend on the rows
  noFullScan(lines);
  assert.ok(lines.some((l) => /idx_jobs_kind_spawn/.test(l)), lines.join(' | '));
});
