// BH-9440: the planned-files read (GET /api/file-claims, the job_claims rows
// bin/sibling-serial.sh and bin/lib/file-claims.sh fclaim_list_dir read every
// pool tick) uses an index at seeded volume.
//
// 5,000 jobs over 13 projects, 200 of them running, each running job with a
// live claim and every 3rd finished job with an old one. The REAL route runs
// through capturingD1, so the statement EXPLAINed is the one the worker sent,
// with its binds. No ANALYZE is run: D1 has no statistics either.
//
//   X1  the route answers the project's live claims (the read is the real one)
//   X2  its plan SEARCHes jobs through an index and job_claims by its key:
//       no `SCAN j` / `SCAN jobs`, no `SCAN c` / `SCAN job_claims`, no
//       CORRELATED subquery
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { ensureColumns } from '../src/lib/core.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import { capturingD1, plan } from './lib/d1-volume.bh-6727.js';

const SECRET = 'test-secret';
const ANCHOR = Date.now(); // determinism: ok the single anchor every seeded timestamp is derived from
const iso = (ms) => new Date(ms).toISOString().replace(/\.\d{3}Z$/, 'Z');
const PROJECTS = ['alpha', 'bravo', 'charlie', 'delta', 'echo', 'foxtrot', 'golf', 'hotel', 'india', 'juliet', 'kilo', 'lima', 'mike'];
const N = 5000, RUNNING = 200;

test('BH-9440 GET /api/file-claims uses an index at 5,000 jobs', async (t) => {
  const opened = await openDb();
  if (opened === null) { t.skip('node:sqlite unavailable in this runtime'); return; }
  const { db, DB } = opened;
  await ensureColumns({ DB }, 'job_claims');
  const job = db.prepare(`INSERT INTO jobs (id, project, ticket_id, kind, box, stage, status, created_at, updated_at)
                          VALUES (?,?,?,?,?,?,?,?,?)`);
  const claim = db.prepare(`INSERT INTO job_claims (job_id, planned_files, files_claimed_at, files_expires_at, updated_at)
                            VALUES (?,?,?,?,?)`);
  db.exec('BEGIN');
  for (let i = 0; i < N; i++) {
    const p = PROJECTS[i % PROJECTS.length], id = `build-${p}-${i}`;
    const running = i >= N - RUNNING;
    const created = iso(ANCHOR - (N - i) * 60e3);
    job.run(id, p, `T-${i}`, 'build', `box-${i % 9}`, running ? 'execute' : 'done', running ? 'running' : 'done', created, created);
    if (running) claim.run(id, `src/${p}/${i}.ts`, created, iso(ANCHOR + 4 * 3600e3), created);
    else if (i % 3 === 0) claim.run(id, `src/${p}/${i}.ts`, created, iso(ANCHOR - 3600e3), created);
  }
  db.exec('COMMIT');

  const log = [];
  const req = new Request('https://jobs.test/api/file-claims?project=alpha', { headers: { authorization: `Bearer ${SECRET}` } });
  const res = await worker.fetch(req, { DB: capturingD1(db, log), HARNESS_SECRET: SECRET });
  const body = await res.json();

  await t.test('X1 the route answers the live claims of one project', () => {
    assert.equal(res.status, 200, JSON.stringify(body));
    const want = Array.from({ length: RUNNING }, (_, k) => N - RUNNING + k).filter((i) => i % PROJECTS.length === 0).length;
    assert.equal(body.claims.length, want);
    assert.ok(body.claims.every((c) => c.job_id.startsWith('build-alpha-')), 'one project only');
  });

  await t.test('X2 the claims read SEARCHes both tables by an index', () => {
    const st = log.find((s) => /FROM jobs j JOIN job_claims c ON c\.job_id=j\.id/.test(s.sql) && /files_expires_at > \?2/.test(s.sql));
    assert.ok(st, `the route ran the claims read (statements: ${log.map((s) => s.sql.slice(0, 60)).join(' | ')})`);
    const lines = plan(db, st.sql, ...st.binds);
    const bad = lines.filter((l) => /^SCAN (j|jobs|c|job_claims)\b/.test(l) && !/USING (COVERING )?INDEX|USING INTEGER PRIMARY KEY|USING PRIMARY KEY/.test(l));
    assert.deepEqual(bad, [], `no full scan: ${lines.join(' / ')}`);
    assert.ok(!lines.some((l) => /CORRELATED/.test(l)), `no correlated subquery: ${lines.join(' / ')}`);
    assert.ok(lines.some((l) => /^SEARCH j USING (COVERING )?INDEX idx_jobs_project_status/.test(l)), `jobs by (project, status): ${lines.join(' / ')}`);
    assert.ok(lines.some((l) => /^SEARCH c USING (INDEX|PRIMARY KEY|COVERING INDEX)/.test(l)), `job_claims by its key: ${lines.join(' / ')}`);
  });
});
