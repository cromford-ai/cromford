// BH-9501 (BH-9441.4): GET /api/metrics/approve-then-block, the digest metric
// "lead review blocked after an in-build APPROVE". Driven through the REAL
// worker.fetch on node:sqlite with the composed jobs schema (worker/jobs/schema.d/).
//   W1 a cohort of 4 PRs in 2 repos, 2 blocked after the approve: share 0.5
//   W2 every "does not count" case gives blocked 0 for that PR
//   W3 days=7 and days=14 move an approve at D-10 out of and into the cohort
//   W4 bad day/days are 400 with no read; no bearer is 401; the route is in the table
//   W5 EXPLAIN QUERY PLAN on 50,000 rows: idx_pr_state_events_state_at, no SCAN
//   W6 an empty window: cohort 0, share null, repos []
//   W7 a thrown read propagates (the runtime's 500), never a 200 with zeros
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import worker from '../src/index.js';
import { ensureColumns, ensureTable } from '../src/lib/core.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import { capturingD1, plan, fullScans } from './lib/d1-volume.bh-6727.js';

const SECRET = 'tok-fixture-bh9501';
const D = '2026-11-10';                 // the digest day; the window ends 2026-11-11T00:00:00Z
const END = Date.parse('2026-11-11T00:00:00Z');
// at(daysBefore, minute): an ISO time `daysBefore` days before the window end, plus minutes.
const at = (daysBefore, minute = 0) =>
  new Date(END - daysBefore * 86400e3 + minute * 60e3).toISOString().replace(/\.\d{3}Z$/, 'Z');
const SHA = (c) => c.repeat(40);

async function fresh(t) {
  const o = await openDb();
  if (!o) { t.skip('node:sqlite unavailable'); return null; }
  await ensureTable({ DB: o.DB }, 'pr_state_events');
  await ensureColumns({ DB: o.DB }, 'pr_state_events');
  return o;
}
function call(DB, path, { bearer = true } = {}) {
  return worker.fetch(new Request(`https://jobs.test${path}`, {
    headers: bearer ? { authorization: `Bearer ${SECRET}` } : {},
  }), { DB, HARNESS_SECRET: SECRET }).then(async (res) => ({ status: res.status, body: await res.json().catch(() => null) }));
}
let seq = 0;
// The rows the two production writers make (lib/pr-gate-intake.js):
// recordBuilderApprove and recordLeadVerdict (lead, human or risk-tier).
function approve(db, repo, number, when, sha = SHA('a')) {
  ins(db, { repo, number, state: 'gate', at: when, reason: `builder-verdict:job-${++seq}`, builder_approved_sha: sha });
}
function verdict(db, repo, number, when, word, source = 'lead', sha = SHA('b')) {
  ins(db, { repo, number, state: 'gate', at: when, reason: `verdict:${source}`, lead_verdict_sha: sha, lead_verdict_word: word });
}
function ins(db, r) {
  db.prepare(`INSERT INTO pr_state_events (repo, number, state, since, alerted, at, reason, actor, builder_approved_sha, lead_verdict_sha, lead_verdict_word)
              VALUES (?,?,?,?,'-',?,?,'worker',?,?,?)`)
    .run(r.repo, r.number, r.state, r.since || `src-${++seq}`, r.at, r.reason ?? null,
      r.builder_approved_sha ?? null, r.lead_verdict_sha ?? null, r.lead_verdict_word ?? null);
}
const get = (DB, q = `day=${D}`) => call(DB, `/api/metrics/approve-then-block?${q}`);

test('W1 a cohort of 4 PRs in 2 repos, 2 blocked after the in-build APPROVE: share 0.5, per repo', async (t) => {
  const o = await fresh(t); if (!o) return;
  const A = 'example-org/cromford', B = 'example-org/project-9';
  // A#1: approve, then a lead BLOCK on the same sha -> blocked.
  approve(o.db, A, 1, at(3)); verdict(o.db, A, 1, at(3, 30), 'BLOCK', 'lead', SHA('a'));
  // A#2: approve, then a lead MERGE -> not blocked.
  approve(o.db, A, 2, at(2)); verdict(o.db, A, 2, at(2, 30), 'MERGE');
  // B#1: approve, then a lead BLOCK on a later head sha -> blocked.
  approve(o.db, B, 1, at(5)); verdict(o.db, B, 1, at(4), 'BLOCK', 'lead', SHA('c'));
  // B#7: approve only -> in the cohort, not blocked.
  approve(o.db, B, 7, at(1));
  const r = await get(o.DB);
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.ok, true);
  assert.equal(r.body.day, D);
  assert.equal(r.body.days, 14);
  assert.equal(r.body.from, '2026-10-28T00:00:00Z');
  assert.equal(r.body.to, '2026-11-11T00:00:00Z');
  assert.equal(r.body.cohort, 4);
  assert.equal(r.body.blocked, 2);
  assert.equal(r.body.share, 0.5);
  assert.deepEqual(r.body.repos, [
    { repo: A, cohort: 2, blocked: 1, share: 0.5 },
    { repo: B, cohort: 2, blocked: 1, share: 0.5 },
  ]);
});

test('W1b approve, lead MERGE, then lead BLOCK counts; two repos with one number are two PRs', async (t) => {
  const o = await fresh(t); if (!o) return;
  approve(o.db, 'o/x', 5, at(6)); verdict(o.db, 'o/x', 5, at(5), 'MERGE'); verdict(o.db, 'o/x', 5, at(4), 'BLOCK');
  approve(o.db, 'o/y', 5, at(6));
  const r = await get(o.DB);
  assert.equal(r.body.cohort, 2, JSON.stringify(r.body));
  assert.equal(r.body.blocked, 1, JSON.stringify(r.body));
  assert.deepEqual(r.body.repos.map((x) => [x.repo, x.cohort, x.blocked]), [['o/x', 1, 1], ['o/y', 1, 0]]);
});

test('W2 the does-not-count cases each give blocked 0', async (t) => {
  const cases = {
    'lead BLOCK before the only approve': (db) => { verdict(db, 'o/r', 1, at(4), 'BLOCK'); approve(db, 'o/r', 1, at(3)); },
    'approve then lead MERGE-WITH-NOTES': (db) => { approve(db, 'o/r', 1, at(4)); verdict(db, 'o/r', 1, at(3), 'MERGE-WITH-NOTES'); },
    'approve then a human BLOCK': (db) => { approve(db, 'o/r', 1, at(4)); verdict(db, 'o/r', 1, at(3), 'BLOCK', 'human'); },
    'approve then a risk-tier BLOCK': (db) => { approve(db, 'o/r', 1, at(4)); verdict(db, 'o/r', 1, at(3), 'BLOCK', 'risk-tier'); },
    'approve then a non-gate row with the BLOCK fields': (db) => {
      approve(db, 'o/r', 1, at(4));
      ins(db, { repo: 'o/r', number: 1, state: 'open', at: at(3), reason: 'verdict:lead', lead_verdict_word: 'BLOCK' });
    },
  };
  for (const [name, seed] of Object.entries(cases)) {
    const o = await fresh(t); if (!o) return;
    seed(o.db);
    const r = await get(o.DB);
    assert.equal(r.status, 200, name);
    assert.equal(r.body.cohort, 1, `${name}: ${JSON.stringify(r.body)}`);
    assert.equal(r.body.blocked, 0, `${name}: ${JSON.stringify(r.body)}`);
  }
  // Not in the cohort at all: a lead BLOCK with no approve; an approve on D-14
  // (before the window start) with its BLOCK inside the window.
  const o = await fresh(t); if (!o) return;
  verdict(o.db, 'o/r', 2, at(3), 'BLOCK');
  approve(o.db, 'o/r', 3, at(14, -1)); verdict(o.db, 'o/r', 3, at(13), 'BLOCK');
  const r = await get(o.DB);
  assert.equal(r.body.cohort, 0, JSON.stringify(r.body));
  assert.equal(r.body.blocked, 0, JSON.stringify(r.body));
});

test('W3 days=7 leaves an approve at D-10 out; days=14 takes it in', async (t) => {
  const o = await fresh(t); if (!o) return;
  approve(o.db, 'o/r', 9, at(10)); verdict(o.db, 'o/r', 9, at(1), 'BLOCK');
  approve(o.db, 'o/r', 8, at(2));
  const r7 = await get(o.DB, `days=7&day=${D}`);
  assert.equal(r7.body.days, 7);
  assert.equal(r7.body.from, '2026-11-04T00:00:00Z');
  assert.deepEqual([r7.body.cohort, r7.body.blocked], [1, 0], JSON.stringify(r7.body));
  const r14 = await get(o.DB, `days=14&day=${D}`);
  assert.deepEqual([r14.body.cohort, r14.body.blocked], [2, 1], JSON.stringify(r14.body));
});

test('W4 bad day/days are 400 with no read; no bearer is 401; the route is in the table', async (t) => {
  const o = await fresh(t); if (!o) return;
  const log = [];
  const DB = capturingD1(o.db, log);
  for (const q of ['day=2026-13-01', 'day=nope', '', 'day=2999-01-01', `days=0&day=${D}`, `days=61&day=${D}`,
    `days=x&day=${D}`, `days=&day=${D}`, `days=1.5&day=${D}`]) {
    const r = await get(DB, q);
    assert.equal(r.status, 400, `${q}: ${JSON.stringify(r.body)}`);
    assert.ok(r.body.error, q);
  }
  assert.equal(log.filter((x) => /pr_state_events/.test(x.sql) && /^\s*SELECT/i.test(x.sql)).length, 0, 'no read on a 400');
  assert.equal((await call(o.DB, `/api/metrics/approve-then-block?day=${D}`, { bearer: false })).status, 401);
  const frag = readFileSync(new URL('./route-table.d/bh-9501-approve-then-block.txt', import.meta.url), 'utf8')
    .split('\n').filter((l) => l && !l.startsWith('#'));
  assert.deepEqual(frag, ['GET /api/metrics/approve-then-block']);
});

test('W5 on 50,000 rows the read uses idx_pr_state_events_state_at and never scans pr_state_events', async (t) => {
  const o = await fresh(t); if (!o) return;
  const { db } = o;
  const STATES = ['open', 'review', 'merged', 'gate', 'ci', 'closed'];
  db.exec('BEGIN');
  const s = db.prepare(`INSERT INTO pr_state_events (repo, number, state, since, alerted, at, reason, builder_approved_sha, lead_verdict_word)
                        VALUES (?,?,?,?,'-',?,?,?,?)`);
  for (let i = 0; i < 50000; i++) {
    const st = STATES[i % STATES.length];
    const lead = Math.floor(i / STATES.length) % 2 === 1;
    // 180 days of history, so the 14-day window is a small slice of it.
    const when = at((i % 180) + 0.5);
    s.run(`o/repo-${i % 12}`, i % 4000, st, `s-${i}`, when,
      st === 'gate' ? (lead ? 'verdict:lead' : `builder-verdict:j${i}`) : null,
      st === 'gate' && !lead ? SHA('a') : null, st === 'gate' && lead ? 'BLOCK' : null);
  }
  db.exec('COMMIT');
  db.exec('ANALYZE');
  const log = [];
  const r = await get(capturingD1(db, log));
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.ok(r.body.cohort > 0, 'the seeded window has a cohort');
  const reads = log.filter((x) => /FROM pr_state_events/.test(x.sql));
  assert.equal(reads.length, 1, reads.map((x) => x.sql).join(' | '));
  const lines = plan(db, reads[0].sql, ...reads[0].binds);
  assert.deepEqual(fullScans(lines, ['pr_state_events']), [], lines.join(' | '));
  assert.ok(lines.some((l) => /USING (COVERING )?INDEX idx_pr_state_events_state_at \(state=\? AND at>\? AND at<\?\)/.test(l)), lines.join(' | '));
});

test('W6 an empty window: cohort 0, blocked 0, share null, repos []', async (t) => {
  const o = await fresh(t); if (!o) return;
  const r = await get(o.DB);
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.deepEqual([r.body.ok, r.body.cohort, r.body.blocked, r.body.share, r.body.repos], [true, 0, 0, null, []]);
});

test('W7 a thrown read propagates (500), never a 200 with zeros', async (t) => {
  const o = await fresh(t); if (!o) return;
  const DB = {
    prepare(sql) {
      const s = o.DB.prepare(sql);
      if (!/^SELECT repo, number/.test(sql)) return s;
      return { bind: () => ({ all: async () => { throw new Error('D1_ERROR: boom'); } }) };
    },
    batch: (x) => o.DB.batch(x),
  };
  // The worker does not catch it into a body: the throw reaches the runtime,
  // which answers 500 (the flags-overload.bh-6805 idiom).
  await assert.rejects(() => get(DB), /D1_ERROR: boom/);
});
