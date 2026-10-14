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
import { openDb } from './lib/d1-sqlite.bh-1030.js';

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

// I8 (BH-6750 follow-up of the #6749 review): the same-rows check on hand-built
// rows, because the volume fixture gives every (project, ticket) one job. Each
// case below is one way the merge -> artifact -> job -> ticket walk can differ.
const OLD_DIGEST_SQL = `SELECT project, ticket_id, MIN(issue_created_at) AS issue_created_at FROM jobs
      WHERE issue_created_at IS NOT NULL AND ticket_id IS NOT NULL
        AND EXISTS (SELECT 1 FROM job_artifacts a JOIN jobs j2 ON j2.id=a.job_id
                     WHERE a.artifact_kind='pr_url'
                       AND a.artifact_ref IN (SELECT key FROM ledgers
                                             WHERE kind='merge' AND status='merged' AND created_at>=?1 AND created_at<?2)
                       AND j2.project=jobs.project AND j2.ticket_id=jobs.ticket_id)
      GROUP BY project, ticket_id ORDER BY project, ticket_id`;

test('I8: the digest rewrite returns the old rows on the edge cases', async (t) => {
  const o = await openDb();
  if (!o) return t.skip('node:sqlite unavailable');
  const { db } = o;
  const from = isoAgo(48), to = isoAgo(24), inside = isoAgo(36), before = isoAgo(60);
  const d1 = isoAgo(200), d2 = isoAgo(150), d3 = isoAgo(100);
  const job = db.prepare(`INSERT INTO jobs (id, project, ticket_id, kind, box, stage, status, created_at, updated_at, issue_created_at)
                          VALUES (?, ?, ?, 'build', 'b', 'done', 'done', ?, ?, ?)`);
  const pr = db.prepare(`INSERT INTO job_artifacts (job_id, artifact_kind, artifact_ref, created_at, updated_at) VALUES (?, 'pr_url', ?, ?, ?)`);
  const merge = db.prepare(`INSERT INTO ledgers (kind, key, status, created_at, updated_at) VALUES ('merge', ?, ?, ?, ?)`);
  const add = (id, project, ticket, issued, url) => { job.run(id, project, ticket, d1, d1, issued); if (url) pr.run(id, url, d1, d1); };
  // A: the merged job has a NULL issue_created_at; its dated siblings set the MIN.
  add('a1', 'p1', 'T-A', null, 'u/a'); add('a2', 'p1', 'T-A', d2, null); add('a3', 'p1', 'T-A', d1, null);
  // B: two jobs carry the same pr_url, on two tickets; both tickets count.
  add('b1', 'p1', 'T-B1', d3, 'u/b'); add('b2', 'p1', 'T-B2', d2, 'u/b');
  // C: the same ticket_id in two projects; only p1's PR merged.
  add('c1', 'p1', 'T-C', d2, 'u/c'); add('c2', 'p2', 'T-C', d1, 'u/c-other');
  // D: merged before the window. E: in the window but not merged.
  add('d1', 'p1', 'T-D', d1, 'u/d'); add('e1', 'p1', 'T-E', d1, 'u/e');
  // F: merged in the window, but every job of the ticket has a NULL date.
  add('f1', 'p1', 'T-F', null, 'u/f'); add('f2', 'p1', 'T-F', null, null);
  // G: merged in the window, but the job has no ticket_id.
  add('g1', 'p1', null, d1, 'u/g');
  for (const u of ['u/a', 'u/b', 'u/c', 'u/f', 'u/g']) merge.run(u, 'merged', inside, inside);
  merge.run('u/d', 'merged', before, before);
  merge.run('u/e', 'parked', inside, inside);
  merge.run('u/c-other', 'merged', before, before);

  const old = db.prepare(OLD_DIGEST_SQL).all(from, to).map((r) => ({ ...r }));
  const log = [];
  await readCoreSections(capturingD1(db, log), { from, to, day: from.slice(0, 10) }, { now: NOW_ISO });
  const q = log.find((r) => /MIN\(j\.issue_created_at\)/.test(r.sql));
  assert.ok(q, 'the digest ran the rewritten read');
  const neu = db.prepare(`SELECT * FROM (${q.sql}) ORDER BY project, ticket_id`).all(from, to).map((r) => ({ ...r }));
  assert.deepEqual(old, [
    { project: 'p1', ticket_id: 'T-A', issue_created_at: d1 },
    { project: 'p1', ticket_id: 'T-B1', issue_created_at: d3 },
    { project: 'p1', ticket_id: 'T-B2', issue_created_at: d2 },
    { project: 'p1', ticket_id: 'T-C', issue_created_at: d2 },
  ], 'the old query answers the cases as written');
  assert.deepEqual(neu, old);
});

test('I7: GET /api/metrics/dora reads build launches through idx_jobs_kind_spawn', { skip: !vol }, async () => {
  const lines = planOf(await reads('/api/metrics/dora?days=30'), /MIN\(first_spawn_at\)/);  // determinism: ok fixtures are offsets from the clock anchor in lib/d1-volume; the plan does not depend on the rows
  noFullScan(lines);
  assert.ok(lines.some((l) => /idx_jobs_kind_spawn/.test(l)), lines.join(' | '));
});
