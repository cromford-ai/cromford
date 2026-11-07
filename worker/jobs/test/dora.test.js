import test from 'node:test';
import assert from 'node:assert/strict';
import worker, { computeDora, percentile, doraRepo, doraPrNumber } from '../src/index.js';

// GET /api/metrics/dora and the derivation behind it.
//
// WHAT IS ACTUALLY UNDER TEST. Not "does it return 200" — a DORA panel that
// returns 200 with confident wrong numbers is worse than no panel, because
// somebody will go and optimise the thing it named. The properties pinned here
// are the ones whose failure is SILENT:
//
//   * a merge with an unreadable timestamp must leave BOTH sides of every rate,
//     never just the numerator — an inflated denominator makes a change-failure
//     rate improve for free;
//   * a PR that was reverted AND reopened is ONE bad merge, so a rate can never
//     exceed 1;
//   * a rebuilt ticket has two jobs against one PR and the lead time must be
//     measured from the FIRST, not the last attempt;
//   * a BLOCK verdict must not start the merge-lane clock;
//   * a project with nothing measurable answers null with n=0, never 0;
//   * the gaps this fleet has (no deploy record, no pr_state history) are NAMED
//     in the payload rather than papered over with a number.

const SECRET = 'test-secret';
// The fixtures are relative to NOW, and the route under test reads the REAL
// request time (its `t`), so NOW must track the real clock. A fixed date drifts
// out of the route's 14-day window as the calendar moves (went red 2026-09-24).
// Floored to the hour so a run never straddles a boundary mid-suite.
const NOW = Math.floor(Date.now() / 3600e3) * 3600e3; // determinism: ok fixtures must be relative to the route's real request clock
const iso = (msAgo) => new Date(NOW - msAgo).toISOString().replace(/\.\d{3}Z$/, 'Z');
const HOURS = 3600e3;
const DAYS = 24 * HOURS;

const PR = (repo, n) => `https://github.com/${repo}/pull/${n}`;

function fakeDB(state) {
  const calls = [];
  const result = (sql, binds) => {
    calls.push({ sql: sql.replace(/\s+/g, ' ').trim(), binds });
    // The two ledger reads are DIFFERENT queries against one table, and the
    // route's correctness depends on them not being confused: one is filtered
    // to merged rows inside the window, the other is every pr_state row. A stub
    // that answered "all ledgers" to both would pass on a worker that counted
    // conductor states as merges.
    if (/FROM ledgers\s+WHERE kind='merge'/.test(sql)) {
      const since = binds[0];
      return { rows: (state.merges || []).filter((r) => r.status === 'merged'
        && String(r.created_at ?? '') >= String(since)) };
    }
    if (/FROM ledgers\s+WHERE kind='pr_state'/.test(sql)) {
      return { rows: state.prStates || [] };
    }
    // The THIRD ledger read, and the one that turns "merged" into "live": a
    // stub answering these three from one list would pass on a worker that
    // counted conductor states as departures.
    if (/FROM ledgers\s+WHERE kind='deploy'/.test(sql)) {
      const since = binds[0];
      return { rows: (state.deploys || [])
        .filter((r) => String(r.created_at ?? '') >= String(since)) };
    }
    // BH-482.3: the launch read, the seventh. Filtered FOR REAL on the window
    // bind, because the guarantee under test is that this read is narrowed by
    // `since` exactly like the merge read — a stub answering every launch row
    // would pass on a worker measuring the whole table under a 14-day label.
    if (/MIN\(issue_created_at\)/.test(sql)) {
      if (state.launchReadFails) throw new Error('D1_ERROR: no such column: issue_created_at');
      return { rows: (state.launches || [])
        .filter((r) => String(r.first_spawn_at ?? '') >= String(binds[0])) };
    }
    if (/FROM job_artifacts a JOIN jobs j/.test(sql)) {
      const since = binds[0];
      return {
        rows: (state.artifacts || [])
          .filter((a) => ['pr_url', 'verdict'].includes(a.artifact_kind))
          .filter((a) => String(a.updated_at ?? '') >= String(since))
          .map((a) => {
            const j = (state.jobs || []).find((x) => x.id === a.job_id) || {};
            return {
              ...a,
              project: j.project ?? null,
              ticket_id: j.ticket_id ?? null,
              job_created_at: j.created_at ?? null,
            };
          })
      };
    }
    if (/FROM outcome_metrics/.test(sql)) {
      const since = binds[0];
      return { rows: (state.outcomes || []).filter((o) => String(o.created_at ?? '') >= String(since)) };
    }
    if (/FROM merge_queue/.test(sql)) return { rows: state.mergeQueue || [] };
    // The column self-migration probe (BH-482.0). Defaults to the FULL set, so
    // every other test here reads a `jobs` table that needs no ALTER; a test
    // names a shorter list to prove one. Without this the fall-through below
    // would answer "no columns at all" and every DORA call would migrate.
    if (/PRAGMA table_info\(jobs\)/.test(sql)) {
      const cols = state.jobsCols || [
        'id', 'project', 'ticket_id', 'kind', 'box', 'stage', 'status',
        'budget_usd', 'spent_usd', 'created_at', 'updated_at', 'meta',
        'issue_created_at', 'first_spawn_at'];
      return { rows: cols.map((name) => ({ name })) };
    }
    return { rows: [] };
  };
  const stmt = (sql) => ({
    bind: (...binds) => ({
      first: async () => result(sql, binds).rows[0] || null,
      all: async () => ({ results: result(sql, binds).rows }),
      run: async () => { result(sql, binds); return { meta: { changes: 1 } }; }
    }),
    first: async () => result(sql, []).rows[0] || null,
    all: async () => ({ results: result(sql, []).rows }),
    run: async () => { result(sql, []); return { meta: { changes: 1 } }; }
  });
  return { prepare: stmt, batch: async (xs) => xs, _calls: calls };
}

const call = (path, { secret = SECRET, state = {} } = {}) => {
  const db = fakeDB(state);
  const req = new Request(`https://jobs.test${path}`, {
    headers: secret === null ? {} : { authorization: `Bearer ${secret}` }
  });
  return worker.fetch(req, { DB: db, HARNESS_SECRET: SECRET })
    .then(async (res) => ({ status: res.status, body: await res.json().catch(() => null), db }));
};

// --- the primitives ----------------------------------------------------------

test('a repo and a number are only ever read off a real github pull url', () => {
  assert.equal(doraRepo(PR('example-org/project-3', 12)), 'example-org/project-3');
  assert.equal(doraPrNumber(PR('example-org/project-3', 12)), 12);
  // These arrive in D1 from shell. A near-miss has to be null, not a slug this
  // code invented, or the panel founds a project row on a url nobody wrote.
  assert.equal(doraRepo('https://github.com/example-org/project-3/issues/12'), null);
  assert.equal(doraRepo('https://evil.example/example-org/project-3/pull/12'), null);
  assert.equal(doraRepo(null), null);
});

test('nearest-rank percentile names a value that was actually observed', () => {
  const xs = [10, 20, 30, 40];
  assert.equal(percentile(xs, 50), 20);
  assert.equal(percentile(xs, 90), 40);
  // One sample is its own p50 AND its own p90 — a p90 of null there would read
  // as "not measured" on a metric that was measured once.
  assert.equal(percentile([7], 90), 7);
  assert.equal(percentile([], 50), null);
});

// --- the derivation ----------------------------------------------------------

const base = (over = {}) => ({
  days: 14, since: iso(14 * DAYS), now: NOW, project: null,
  merges: [], artifacts: [], outcomes: [], prStates: [], repoMap: [], deploys: [], ...over
});

// One row exactly as bin/deploy-train.sh writes it: kind='deploy', keyed
// <owner/repo>@<sha production was verified to serve>, the batch in the detail.
const DEP = (repo, sha, { at, prs = [], project = null, status = 'verified', live = null } = {}) => ({
  key: `${repo}@${sha}`,
  status,
  created_at: at,
  updated_at: at,
  detail: JSON.stringify({
    project, sha, departure: at, prod_url: 'https://os.example/api/internal/version',
    waited_s: 42, merges: prs.length || 1, shas: [sha], prs,
    ...(status === 'verified' ? { verified_at: at } : { failed_at: at, live, reason: 'not serving' })
  })
});

test('lead time runs from the build job to the merge, and says so', () => {
  const out = computeDora(base({
    merges: [{ kind: 'merge', key: PR('example-org/project-3', 5), status: 'merged', created_at: iso(1 * DAYS) }],
    artifacts: [{
      artifact_kind: 'pr_url', artifact_ref: PR('example-org/project-3', 5), job_id: 'build-project-3-1',
      created_at: iso(3 * DAYS), updated_at: iso(3 * DAYS),
      project: 'project-3', ticket_id: 'TK-1', job_created_at: iso(3 * DAYS)
    }]
  }));
  const p = out.projects[0];
  assert.equal(p.project, 'project-3');
  assert.equal(p.lead_time.n, 1);
  assert.equal(p.lead_time.p50_s, 2 * 86400);
  assert.equal(p.lead_time.from_job_n, 1);
  // The honesty requirement: the payload must never imply it reached production.
  assert.equal(p.lead_time.deploy_verified, false);
  assert.match(p.lead_time.basis, /PR merged$/);
  assert.match(p.lead_time.evidence, /ledgers\(kind='merge'\)/);
});

test('a rebuilt ticket is measured from its FIRST job, not its last attempt', () => {
  const url = PR('example-org/project-3', 9);
  const out = computeDora(base({
    merges: [{ key: url, status: 'merged', created_at: iso(1 * DAYS) }],
    artifacts: [
      // The takeover job, written LAST, is the one a naive "newest wins" picks.
      { artifact_kind: 'pr_url', artifact_ref: url, job_id: 'build-project-3-2',
        created_at: iso(2 * HOURS), updated_at: iso(2 * HOURS),
        project: 'project-3', job_created_at: iso(2 * HOURS) },
      { artifact_kind: 'pr_url', artifact_ref: url, job_id: 'build-project-3-1',
        created_at: iso(6 * DAYS), updated_at: iso(6 * DAYS),
        project: 'project-3', job_created_at: iso(6 * DAYS) }
    ]
  }));
  // 6d ago -> 1d ago is five days. Taking the takeover would have reported 22h
  // and made a five-day change look like an afternoon.
  assert.equal(out.projects[0].lead_time.p50_s, 5 * 86400);
});

test('a PR with no job falls back to when the conductor first saw it, counted separately', () => {
  const url = PR('example-org/project-3', 11);
  const out = computeDora(base({
    merges: [{ key: url, status: 'merged', created_at: iso(1 * DAYS) }],
    prStates: [{ key: 'example-org/project-3#11', status: 'MERGED', created_at: iso(4 * DAYS), updated_at: iso(1 * DAYS) }],
    mergeQueue: [{ project: 'project-3', repo: 'example-org/project-3' }],
    repoMap: [{ project: 'project-3', repo: 'example-org/project-3' }]
  }));
  const p = out.projects[0];
  assert.equal(p.lead_time.p50_s, 3 * 86400);
  // The two bases are never averaged into one undifferentiated column.
  assert.equal(p.lead_time.from_job_n, 0);
  assert.equal(p.lead_time.from_pr_seen_n, 1);
});

test('a merge whose timestamp cannot be read leaves BOTH sides of every rate', () => {
  const good = PR('example-org/project-3', 1);
  const broken = PR('example-org/project-3', 2);
  const out = computeDora(base({
    merges: [
      { key: good, status: 'merged', created_at: iso(1 * DAYS) },
      { key: broken, status: 'merged', created_at: 'not a date' },
      // parked never reached main; asking whether it held has no subject.
      { key: PR('example-org/project-3', 3), status: 'parked', created_at: iso(1 * DAYS) }
    ],
    outcomes: [{ repo: 'example-org/project-3', pr: good, outcome: 'reverted', created_at: iso(12 * HOURS) }],
    repoMap: [{ project: 'project-3', repo: 'example-org/project-3' }]
  }));
  const p = out.projects[0];
  assert.equal(p.merged, 1);
  // 1/1, not 1/2 and not 1/3. Either wrong denominator reads as a healthier
  // fleet than the one that exists.
  assert.equal(p.change_failure.rate, 1);
});

test('one PR reverted AND reopened is one bad merge, so a rate can never exceed 1', () => {
  const url = PR('example-org/project-3', 7);
  const out = computeDora(base({
    merges: [{ key: url, status: 'merged', created_at: iso(2 * DAYS) }],
    outcomes: [
      { repo: 'example-org/project-3', pr: url, outcome: 'reverted', created_at: iso(1 * DAYS) },
      { repo: 'example-org/project-3', pr: url, outcome: 'reopened', created_at: iso(20 * HOURS) },
      // main-red is reported beside the rate, never inside it.
      { repo: 'example-org/project-3', pr: url, outcome: 'merged_then_red', created_at: iso(19 * HOURS) }
    ],
    repoMap: [{ project: 'project-3', repo: 'example-org/project-3' }]
  }));
  const p = out.projects[0];
  assert.equal(p.change_failure.bad, 1);
  assert.equal(p.change_failure.rate, 1);
  assert.equal(p.change_failure.main_red, 1);
});

test('a BLOCK verdict does not start the merge-lane clock', () => {
  const url = PR('example-org/project-3', 21);
  const state = (word) => computeDora(base({
    merges: [{ key: url, status: 'merged', created_at: iso(1 * DAYS) }],
    artifacts: [
      { artifact_kind: 'pr_url', artifact_ref: url, job_id: 'j1',
        created_at: iso(2 * DAYS), updated_at: iso(2 * DAYS),
        project: 'project-3', job_created_at: iso(2 * DAYS) },
      { artifact_kind: 'verdict', artifact_ref: word, job_id: 'j1',
        created_at: iso(30 * HOURS), updated_at: iso(30 * HOURS), project: 'project-3' }
    ]
  })).projects[0].merge_lane;
  assert.equal(state('APPROVE').n, 1);
  assert.equal(state('APPROVE').p50_s, 6 * 3600);
  // A blocked PR that later merged by hand has no approval instant, and a zero
  // here would report the slowest possible lane as the fastest.
  assert.equal(state('BLOCK').n, 0);
  assert.equal(state('BLOCK').p50_s, null);
});

test('time to restore is the next landing after the failure, and carries its caveat', () => {
  const bad = PR('example-org/project-3', 30);
  const fix = PR('example-org/project-3', 31);
  const out = computeDora(base({
    merges: [
      { key: bad, status: 'merged', created_at: iso(5 * DAYS) },
      { key: fix, status: 'merged', created_at: iso(2 * DAYS) }
    ],
    outcomes: [{ repo: 'example-org/project-3', pr: bad, outcome: 'reverted', created_at: iso(3 * DAYS) }],
    repoMap: [{ project: 'project-3', repo: 'example-org/project-3' }]
  }));
  const ttr = out.projects[0].time_to_restore;
  assert.equal(ttr.n, 1);
  assert.equal(ttr.p50_s, 1 * 86400);
  assert.equal(ttr.unrestored, 0);
  assert.match(ttr.caveat, /upper bound/);
});

test('a failure with nothing merged after it is UNRESTORED, not restored instantly', () => {
  const bad = PR('example-org/project-3', 40);
  const out = computeDora(base({
    merges: [{ key: bad, status: 'merged', created_at: iso(5 * DAYS) }],
    outcomes: [{ repo: 'example-org/project-3', pr: bad, outcome: 'reverted', created_at: iso(1 * DAYS) }],
    repoMap: [{ project: 'project-3', repo: 'example-org/project-3' }]
  }));
  const ttr = out.projects[0].time_to_restore;
  assert.equal(ttr.n, 0);
  assert.equal(ttr.p50_s, null);
  assert.equal(ttr.unrestored, 1);
});

test('deployment frequency is merges per day and refuses to call itself a deploy', () => {
  const merges = [1, 2, 3, 4, 5, 6, 7].map((n) => ({
    key: PR('example-org/project-3', n), status: 'merged', created_at: iso(n * 12 * HOURS)
  }));
  const out = computeDora(base({ merges, repoMap: [{ project: 'project-3', repo: 'example-org/project-3' }] }));
  const df = out.projects[0].deployment_frequency;
  assert.equal(df.count, 7);
  assert.equal(df.per_day, 0.5);
  assert.equal(df.deploy_verified, false);
  assert.match(df.basis, /NOT verified production departures/);
});

test('the slowest list is capped, ordered, and every row carries what a link needs', () => {
  const merges = [];
  const artifacts = [];
  for (let n = 1; n <= 12; n++) {
    const url = PR('example-org/project-3', n);
    merges.push({ key: url, status: 'merged', created_at: iso(1 * DAYS) });
    artifacts.push({
      artifact_kind: 'pr_url', artifact_ref: url, job_id: `j${n}`,
      created_at: iso((1 + n) * DAYS), updated_at: iso((1 + n) * DAYS),
      project: 'project-3', ticket_id: `TK-${n}`, job_created_at: iso((1 + n) * DAYS)
    });
  }
  const p = computeDora(base({ merges, artifacts })).projects[0];
  assert.equal(p.slowest.length, 10);
  assert.equal(p.slowest[0].number, 12);
  assert.ok(p.slowest[0].lead_s > p.slowest[1].lead_s);
  // No dead rows downstream: the console can only link what the payload names.
  assert.equal(p.slowest[0].pr, PR('example-org/project-3', 12));
  assert.equal(p.slowest[0].job_id, 'j12');
  assert.equal(p.slowest[0].ticket_id, 'TK-12');
  // The internal sort key never leaks into the response.
  assert.equal(p.slowest[0].merged_ms, undefined);
});

test('a project with nothing measurable answers null, never zero', () => {
  const out = computeDora(base({
    merges: [{ key: PR('example-org/project-3', 1), status: 'merged', created_at: iso(30 * DAYS) }]
  }));
  assert.deepEqual(out.projects, []);
  assert.equal(out.totals.merged, 0);
  assert.equal(out.totals.change_failure_rate, null);
  assert.equal(out.totals.lead_time.p50_s, null);
  assert.equal(out.totals.lead_time.n, 0);
});

test('the gaps are named in the payload, with the source that would close each', () => {
  const out = computeDora(base());
  const metrics = out.gaps.map((g) => g.metric).join(' | ');
  assert.match(metrics, /deployment frequency/);
  assert.match(metrics, /merge-lane/);
  assert.match(metrics, /time to restore/);
  for (const g of out.gaps) {
    assert.ok(g.missing && g.why && g.would_need, `gap "${g.metric}" must name what is missing and what would close it`);
  }
  // The deploy gap must name the script that already knows the answer, or the
  // next person to read this has to rediscover it.
  assert.match(out.gaps[0].why, /deploy-train/);
});

// --- the route ---------------------------------------------------------------

test('no bearer, no dora', async () => {
  assert.equal((await call('/api/metrics/dora', { secret: null })).status, 401);
  assert.equal((await call('/api/metrics/dora', { secret: 'nope' })).status, 401);
});

// BH-482.0: this route is the second place the launch-lead-time columns are
// touched, and it is a READ — so the migration has to happen before the first
// query, not before the first write. A worker that only migrated on the claim
// path would 500 here on any box whose D1 predates BH-482.
test('the dora read self-applies the jobs columns before its first ledger read', async () => {
  const PRE_BH482 = ['id', 'project', 'ticket_id', 'kind', 'box', 'stage', 'status',
    'budget_usd', 'spent_usd', 'created_at', 'updated_at', 'meta'];
  const r = await call('/api/metrics/dora?days=1', { state: { jobsCols: PRE_BH482 } });
  assert.equal(r.status, 200);
  const sql = r.db._calls.map((c) => c.sql);
  assert.deepEqual(sql.filter((q) => /ALTER TABLE jobs ADD COLUMN/.test(q)), [
    'ALTER TABLE jobs ADD COLUMN issue_created_at TEXT',
    'ALTER TABLE jobs ADD COLUMN first_spawn_at TEXT'
  ]);
  const alter = sql.findIndex((q) => /ALTER TABLE jobs/.test(q));
  const read = sql.findIndex((q) => /FROM ledgers/.test(q));
  assert.ok(alter >= 0 && read >= 0 && alter < read,
    `alter/read order was ${alter}/${read}`);
  // A database that already carries both columns is never ALTERed.
  const current = await call('/api/metrics/dora?days=1', { state: {} });
  assert.equal(current.status, 200);
  assert.equal(current.db._calls.filter((c) => /ALTER TABLE jobs/.test(c.sql)).length, 0);
});

test('the route answers per project, and ?project= narrows it to one', async () => {
  const state = {
    jobs: [
      { id: 'j-project-3', project: 'project-3', ticket_id: 'TK-1', created_at: iso(3 * DAYS) },
      { id: 'j-project-2', project: 'project-2', ticket_id: 'TK-9', created_at: iso(2 * DAYS) }
    ],
    merges: [
      { key: PR('example-org/project-3', 5), status: 'merged', created_at: iso(1 * DAYS) },
      { key: PR('example-org/project-2', 6), status: 'merged', created_at: iso(1 * DAYS) }
    ],
    artifacts: [
      { artifact_kind: 'pr_url', artifact_ref: PR('example-org/project-3', 5), job_id: 'j-project-3',
        created_at: iso(3 * DAYS), updated_at: iso(3 * DAYS) },
      { artifact_kind: 'verdict', artifact_ref: 'APPROVE', job_id: 'j-project-3',
        created_at: iso(26 * HOURS), updated_at: iso(26 * HOURS) },
      { artifact_kind: 'pr_url', artifact_ref: PR('example-org/project-2', 6), job_id: 'j-project-2',
        created_at: iso(2 * DAYS), updated_at: iso(2 * DAYS) }
    ],
    outcomes: [{ repo: 'example-org/project-3', pr: PR('example-org/project-3', 5), outcome: 'reverted', created_at: iso(6 * HOURS) }]
  };

  const all = await call('/api/metrics/dora?days=14', { state });
  assert.equal(all.status, 200);
  assert.equal(all.body.window.days, 14);
  assert.equal(all.body.projects.length, 2);
  assert.equal(all.body.totals.merged, 2);
  const project_3 = all.body.projects.find((p) => p.project === 'project-3');
  assert.equal(project_3.lead_time.p50_s, 2 * 86400);
  assert.equal(project_3.merge_lane.p50_s, 2 * 3600);
  assert.equal(project_3.change_failure.rate, 1);
  assert.ok(all.body.as_of);

  const one = await call('/api/metrics/dora?project=project-2', { state });
  assert.equal(one.status, 200);
  assert.equal(one.body.window.project, 'project-2');
  assert.equal(one.body.projects.length, 1);
  assert.equal(one.body.projects[0].project, 'project-2');
  // The narrowed view's totals must be the narrowed set, or the header tiles
  // report the fleet while the table reports one project.
  assert.equal(one.body.totals.merged, 1);
});

test('the window is clamped and the attribution read looks further back than it', async () => {
  const state = { jobs: [], merges: [], artifacts: [], outcomes: [] };
  const r = await call('/api/metrics/dora?days=900', { state });
  assert.equal(r.body.window.days, 90);

  const zero = await call('/api/metrics/dora?days=0', { state });
  assert.equal(zero.body.window.days, 14, 'days=0 must fall back, never divide by zero');
  const junk = await call('/api/metrics/dora?days=abc', { state });
  assert.equal(junk.body.window.days, 14);

  // The merge read and the artifact read must NOT share a cutoff: a PR merged
  // today can belong to a job opened months ago, and a shared cutoff silently
  // drops exactly the slowest changes this panel exists to find.
  const calls = r.db._calls;
  const mergeSince = calls.find((c) => /kind='merge'/.test(c.sql)).binds[0];
  const artifactSince = calls.find((c) => /job_artifacts a JOIN jobs j/.test(c.sql)).binds[0];
  assert.ok(artifactSince < mergeSince, 'the attribution window must reach back past the metric window');
});

test('the route reads and never writes', async () => {
  const r = await call('/api/metrics/dora', { state: { merges: [], artifacts: [] } });
  assert.equal(r.status, 200);
  for (const c of r.db._calls) {
    assert.doesNotMatch(c.sql, /^(INSERT|UPDATE|DELETE|ALTER|CREATE)/i,
      `a measurement endpoint must not write: ${c.sql}`);
  }
});

// --- the deploy record: lead time that reaches production --------------------
//
// Everything above measures to the MERGE. These pin the half that only exists
// once bin/deploy-train.sh writes its VERIFIED branch down: a lead time that
// ends where the user is, and a deployment frequency that counts departures
// instead of merges. The failure being guarded against is a panel that
// SILENTLY keeps reporting merge-time numbers under a label saying "deployed".

test('lead time ends at the verified deploy when a departure names the PR', () => {
  const url = PR('example-org/project-3', 5);
  const out = computeDora(base({
    merges: [{ key: url, status: 'merged', created_at: iso(2 * DAYS) }],
    artifacts: [{
      artifact_kind: 'pr_url', artifact_ref: url, job_id: 'j1',
      created_at: iso(4 * DAYS), updated_at: iso(4 * DAYS),
      project: 'project-3', ticket_id: 'TK-1', job_created_at: iso(4 * DAYS)
    }],
    deploys: [DEP('example-org/project-3', 'abc1234', { at: iso(1 * DAYS), prs: [url], project: 'project-3' })]
  }));
  const lt = out.projects[0].lead_time;
  // Job 4d ago -> merged 2d ago -> LIVE 1d ago. Stopping at the merge reports
  // two days for a change that took three to reach anybody.
  assert.equal(lt.p50_s, 3 * 86400);
  assert.equal(lt.to_deploy_n, 1);
  assert.equal(lt.to_merge_n, 0);
  assert.equal(lt.deploy_verified, true);
  assert.match(lt.basis, /production/);
  assert.match(lt.evidence, /kind='deploy'/);
  // The drill-down row must say which clock it stopped on, or a reader cannot
  // tell a three-day deploy from a three-day review.
  assert.equal(out.projects[0].slowest[0].lead_end, 'deploy_verified');
});

test('a merge with no departure keeps its merge clock, and the mix is counted rather than averaged away', () => {
  const deployed = PR('example-org/project-3', 5);
  const stuck = PR('example-org/project-3', 6);
  const out = computeDora(base({
    merges: [
      { key: deployed, status: 'merged', created_at: iso(4 * DAYS) },
      { key: stuck, status: 'merged', created_at: iso(2 * DAYS) }
    ],
    artifacts: [deployed, stuck].map((u, i) => ({
      artifact_kind: 'pr_url', artifact_ref: u, job_id: `j${i}`,
      created_at: iso(6 * DAYS), updated_at: iso(6 * DAYS),
      project: 'project-3', job_created_at: iso(6 * DAYS)
    })),
    // Verified before the second merge landed, so it cannot have carried it and
    // there is no later departure to carry it either.
    deploys: [DEP('example-org/project-3', 'abc1234', { at: iso(3 * DAYS), prs: [deployed], project: 'project-3' })]
  }));
  const lt = out.projects[0].lead_time;
  assert.equal(lt.to_deploy_n, 1);
  assert.equal(lt.to_merge_n, 1);
  assert.equal(lt.deploy_verified, true);
  // One column, two clocks — the basis has to say so rather than pick one.
  assert.match(lt.basis, /production/);
  assert.match(lt.basis, /merged/);
});

test('a departure verified BEFORE a merge can never claim it', () => {
  const url = PR('example-org/project-3', 8);
  const out = computeDora(base({
    merges: [{ key: url, status: 'merged', created_at: iso(1 * DAYS) }],
    artifacts: [{
      artifact_kind: 'pr_url', artifact_ref: url, job_id: 'j1',
      created_at: iso(3 * DAYS), updated_at: iso(3 * DAYS),
      project: 'project-3', job_created_at: iso(3 * DAYS)
    }],
    // A stale row naming this PR from an earlier, unrelated departure. Taking
    // it would report a NEGATIVE deploy time as the fastest lead time on screen.
    deploys: [DEP('example-org/project-3', 'old1234', { at: iso(2 * DAYS), prs: [url], project: 'project-3' })]
  }));
  const lt = out.projects[0].lead_time;
  assert.equal(lt.p50_s, 2 * 86400, 'falls back to the merge, never backwards');
  assert.equal(lt.to_deploy_n, 0);
  assert.equal(lt.to_merge_n, 1);
});

test('a departure that named no PRs still carries its repo: the next verified arrival after the merge', () => {
  const url = PR('example-org/project-3', 12);
  const out = computeDora(base({
    merges: [{ key: url, status: 'merged', created_at: iso(2 * DAYS) }],
    artifacts: [{
      artifact_kind: 'pr_url', artifact_ref: url, job_id: 'j1',
      created_at: iso(3 * DAYS), updated_at: iso(3 * DAYS),
      project: 'project-3', job_created_at: iso(3 * DAYS)
    }],
    deploys: [
      // A self-sourced or merge-queue departure has no build dir to read a PR
      // url out of. Without the repo+time fallback those measure nothing.
      DEP('example-org/project-3', 'aaa1111', { at: iso(2.5 * DAYS), project: 'project-3' }),
      DEP('example-org/project-3', 'bbb2222', { at: iso(1.5 * DAYS), project: 'project-3' }),
      DEP('example-org/project-3', 'ccc3333', { at: iso(1 * DAYS), project: 'project-3' })
    ]
  }));
  const lt = out.projects[0].lead_time;
  // The FIRST arrival after the merge (1.5d ago), not the latest one.
  assert.equal(lt.p50_s, 1.5 * 86400);
  assert.equal(lt.to_deploy_n, 1);
});

test('deployment frequency counts VERIFIED departures, not merges, once any exist', () => {
  const urls = [1, 2, 3].map((n) => PR('example-org/project-3', n));
  const out = computeDora(base({
    merges: urls.map((u, i) => ({ key: u, status: 'merged', created_at: iso((3 - i) * DAYS) })),
    repoMap: [{ project: 'project-3', repo: 'example-org/project-3' }],
    deploys: [
      // One train, three merges. Counting merges reports three deploys.
      DEP('example-org/project-3', 'abc1234', { at: iso(12 * HOURS), prs: urls, project: 'project-3' }),
      // A departure that never arrived is not a deployment.
      DEP('example-org/project-3', 'dead999', { at: iso(6 * HOURS), project: 'project-3', status: 'failed', live: 'old0000' })
    ]
  }));
  const df = out.projects[0].deployment_frequency;
  assert.equal(df.count, 1);
  assert.equal(df.per_day, Number((1 / 14).toFixed(3)));
  assert.equal(df.merges, 3, 'the merge count rides along rather than being overwritten');
  assert.equal(df.failed_departures, 1);
  assert.equal(df.deploy_verified, true);
  assert.match(df.basis, /verified/i);
  assert.match(df.evidence, /kind='deploy'/);
});

test('a project that departed but merged nothing in this window still gets a row', () => {
  const out = computeDora(base({
    // Merged before the window, deployed inside it — the shape of a train that
    // finally got through after a red build. Dropping the project here would
    // hide its departures from the table while totals still counted them.
    merges: [{ key: PR('example-org/project-3', 1), status: 'merged', created_at: iso(30 * DAYS) }],
    repoMap: [{ project: 'project-3', repo: 'example-org/project-3' }],
    deploys: [DEP('example-org/project-3', 'abc1234', { at: iso(1 * DAYS), project: 'project-3' })]
  }));
  assert.equal(out.projects.length, 1);
  const p = out.projects[0];
  assert.equal(p.project, 'project-3');
  assert.equal(p.merged, 0);
  assert.equal(p.deployment_frequency.count, 1);
  // Nothing measurable is still null, never zero — a project with no merges in
  // the window has no lead time, however many trains it ran.
  assert.equal(p.lead_time.p50_s, null);
  assert.equal(p.lead_time.n, 0);
  assert.equal(p.change_failure.rate, null);
  assert.equal(out.totals.departures, 1);
});

test('with no deploy rows at all the frequency is still merges per day, and still says so', () => {
  const out = computeDora(base({
    merges: [1, 2].map((n) => ({ key: PR('example-org/project-3', n), status: 'merged', created_at: iso(n * DAYS) })),
    repoMap: [{ project: 'project-3', repo: 'example-org/project-3' }]
  }));
  const df = out.projects[0].deployment_frequency;
  assert.equal(df.deploy_verified, false);
  assert.match(df.basis, /NOT verified production departures/);
});

test('the deploy gap stops claiming the record does not exist once departures are recorded', () => {
  const url = PR('example-org/project-3', 5);
  const withDeploys = computeDora(base({
    merges: [{ key: url, status: 'merged', created_at: iso(2 * DAYS) }],
    repoMap: [{ project: 'project-3', repo: 'example-org/project-3' }],
    deploys: [DEP('example-org/project-3', 'abc1234', { at: iso(1 * DAYS), prs: [url], project: 'project-3' })]
  }));
  // Still named — a gap that half-closed is not a gap that closed — but it must
  // no longer say the record is missing, and it must name who is covered.
  assert.doesNotMatch(withDeploys.gaps[0].why, /writes that only as a line/);
  assert.match(`${withDeploys.gaps[0].missing} ${withDeploys.gaps[0].why}`, /project-3/);
  // With nothing recorded, the original gap is untouched.
  assert.match(computeDora(base()).gaps[0].why, /deploy-train/);
});

// --- launch lead time: the board's clock, not the fleet's ---------------------
//
// Everything above starts measuring when a build job was created. This starts
// where the CLIENT starts: the instant the ticket appeared on the board. The
// failures guarded against are the quiet ones — a row whose spawn reads earlier
// than its issue averaged in as a negative wait, a project dropped from the
// table because it merged nothing yet, and a read that failed taking the whole
// panel down with it.

// One grouped row exactly as the seventh read returns it: one per
// (project, ticket), both stamps non-null.
const LAUNCH = (project, ticket, issueAgo, spawnAgo) => ({
  project, ticket_id: ticket,
  issue_created_at: typeof issueAgo === 'string' ? issueAgo : iso(issueAgo),
  first_spawn_at: typeof spawnAgo === 'string' ? spawnAgo : iso(spawnAgo)
});

// Waits of 10m, 1h and 5h, all inside the window.
const WAITS = [
  LAUNCH('project-3', 'TK-1', 2 * DAYS, 2 * DAYS - 600e3),
  LAUNCH('project-3', 'TK-2', 2 * DAYS, 2 * DAYS - 3600e3),
  LAUNCH('project-3', 'TK-3', 2 * DAYS, 2 * DAYS - 5 * HOURS)
];

test('launch lead time is issue created to first spawn, per project and in totals', () => {
  const out = computeDora(base({ launches: WAITS }));
  const ll = out.projects[0].launch_lead_time;
  assert.equal(ll.n, 3);
  assert.equal(ll.p50_s, 3600);
  assert.equal(ll.p90_s, 5 * 3600);
  assert.equal(ll.dropped_n, 0);
  assert.match(ll.basis, /issue created → first build job registered/);
  // The header tile reads totals, so a totals block that silently omitted the
  // metric would report the fleet as unmeasured while the table shows numbers.
  assert.equal(out.totals.launch_lead_time.n, 3);
  assert.equal(out.totals.launch_lead_time.p50_s, 3600);
  assert.equal(out.totals.launch_lead_time.dropped_n, 0);
});

test('a spawn stamped before its issue is dropped, never averaged', () => {
  const out = computeDora(base({
    launches: [
      WAITS[0], WAITS[1],
      // Clock skew or a hand-filed stamp. Averaged in, it reports a negative
      // wait as the fastest launch on the screen.
      LAUNCH('project-3', 'TK-9', 1 * DAYS, 1 * DAYS + 3600e3),
      LAUNCH('project-3', 'TK-10', 'garbage', iso(1 * DAYS)),
      // The fast path: filed and picked up inside the same second. A zero wait
      // is a MEASUREMENT — dropping it would quietly delete the best launches
      // this fleet makes from the number that reports them.
      LAUNCH('project-3', 'TK-11', 1 * DAYS, 1 * DAYS)
    ]
  }));
  const ll = out.projects[0].launch_lead_time;
  assert.equal(ll.n, 3, 'only the rows that parse and do not run backwards are measured');
  assert.equal(ll.dropped_n, 2);
  assert.equal(ll.p50_s, 600, 'the p50 of the three kept rows, not of five');
  assert.equal(out.totals.launch_lead_time.dropped_n, 2);
});

test('a project with launches but no merges still gets a row', () => {
  const out = computeDora(base({ launches: [LAUNCH('project-4', 'CT-1', 1 * DAYS, 1 * DAYS - 600e3)] }));
  assert.equal(out.projects.length, 1);
  const p = out.projects[0];
  assert.equal(p.project, 'project-4');
  assert.equal(p.merged, 0);
  assert.equal(p.launch_lead_time.n, 1);
  assert.equal(p.launch_lead_time.p50_s, 600);
  // Nothing measurable about the merge half is still null, never zero.
  assert.equal(p.lead_time.n, 0);
  assert.equal(p.lead_time.p50_s, null);
});

test('?project= narrows launches and their totals', async () => {
  const state = {
    launches: [
      LAUNCH('project-3', 'TK-1', 2 * DAYS, 2 * DAYS - 600e3),
      LAUNCH('project-3', 'TK-2', 2 * DAYS, 2 * DAYS - 3600e3),
      LAUNCH('project-2', 'TK-9', 1 * DAYS, 1 * DAYS - 7200e3)
    ]
  };
  const all = await call('/api/metrics/dora?days=14', { state });
  assert.equal(all.status, 200);
  assert.equal(all.body.totals.launch_lead_time.n, 3);

  const one = await call('/api/metrics/dora?days=14&project=project-2', { state });
  assert.equal(one.status, 200);
  assert.equal(one.body.projects.length, 1);
  assert.equal(one.body.projects[0].project, 'project-2');
  assert.equal(one.body.projects[0].launch_lead_time.n, 1);
  assert.equal(one.body.projects[0].launch_lead_time.p50_s, 7200);
  // The narrowed totals must be the narrowed set, or the tile reports the fleet
  // while the table reports one project.
  assert.equal(one.body.totals.launch_lead_time.n, 1);
  assert.equal(one.body.totals.launch_lead_time.p50_s, 7200);
});

test('the route reads launches over the window and never writes; a failed read degrades to a gap', async () => {
  const state = {
    launches: [
      LAUNCH('project-3', 'TK-1', 2 * DAYS, 2 * DAYS - 600e3),
      // Spawned before the window opened: the read's own WHERE must leave it out.
      LAUNCH('project-3', 'TK-OLD', 40 * DAYS, 39 * DAYS)
    ]
  };
  const r = await call('/api/metrics/dora?days=14', { state });
  assert.equal(r.status, 200);
  assert.equal(r.body.totals.launch_lead_time.n, 1);
  const launchRead = r.db._calls.find((c) => /MIN\(issue_created_at\)/.test(c.sql));
  assert.ok(launchRead, 'the route must read the launch stamps');
  const mergeSince = r.db._calls.find((c) => /kind='merge'/.test(c.sql)).binds[0];
  assert.equal(launchRead.binds[0], mergeSince, 'the launch read rides the same window as the merges');
  for (const c of r.db._calls) {
    assert.doesNotMatch(c.sql, /^(INSERT|UPDATE|DELETE|ALTER|CREATE)/i,
      `a measurement endpoint must not write: ${c.sql}`);
  }

  // A read that fails takes ITSELF out of the payload, not the six that worked.
  const broken = await call('/api/metrics/dora?days=14', { state: { ...state, launchReadFails: true } });
  assert.equal(broken.status, 200, 'one failed read must never 500 the panel');
  assert.equal(broken.body.totals.launch_lead_time, undefined);
  for (const p of broken.body.projects) assert.equal(p.launch_lead_time, undefined);
  const gap = broken.body.gaps.find((g) => /launch lead time/.test(g.metric));
  assert.ok(gap, 'a metric that could not be read is named, never silently absent');
  assert.match(gap.why, /D1_ERROR/);
});

test('with no launches the gap names the GitHub-Issues limitation, and disappears once rows exist', () => {
  const none = computeDora(base()).gaps.find((g) => /launch lead time/.test(g.metric));
  assert.ok(none);
  assert.match(none.why, /only GitHub-Issues builds record/);
  // The key is still PRESENT and zero-shaped: a healthy worker with no data must
  // be distinguishable from an old worker that has no such metric.
  assert.deepEqual(computeDora(base()).totals.launch_lead_time.n, 0);
  assert.deepEqual(computeDora(base()).totals.launch_lead_time.p50_s, null);
  // Every row dropped is not "no data": the gap says which of the two it was.
  const allDropped = computeDora(base({
    launches: [LAUNCH('project-3', 'TK-9', 1 * DAYS, 1 * DAYS + 3600e3)]
  })).gaps.find((g) => /launch lead time/.test(g.metric));
  assert.match(allDropped.why, /every row in this window was dropped/);

  const measured = computeDora(base({ launches: WAITS }));
  assert.equal(measured.gaps.find((g) => /launch lead time/.test(g.metric)), undefined);
  // The gaps contract the console depends on is unchanged: the deploy gap is
  // still first, and every entry still names what would close it.
  assert.match(measured.gaps[0].why, /deploy-train/);
  for (const g of computeDora(base()).gaps) {
    assert.ok(g.missing && g.why && g.would_need, `gap "${g.metric}" must say what is missing`);
  }
});

test('the route reads the deploy ledger over the same window and reports it', async () => {
  const url = PR('example-org/project-3', 5);
  const state = {
    jobs: [{ id: 'j-project-3', project: 'project-3', ticket_id: 'TK-1', created_at: iso(4 * DAYS) }],
    merges: [{ key: url, status: 'merged', created_at: iso(2 * DAYS) }],
    artifacts: [{ artifact_kind: 'pr_url', artifact_ref: url, job_id: 'j-project-3',
      created_at: iso(4 * DAYS), updated_at: iso(4 * DAYS) }],
    deploys: [
      DEP('example-org/project-3', 'abc1234', { at: iso(1 * DAYS), prs: [url], project: 'project-3' }),
      // Older than the window: must not be read back in as a departure.
      DEP('example-org/project-3', 'old0000', { at: iso(40 * DAYS), prs: [], project: 'project-3' })
    ]
  };
  const r = await call('/api/metrics/dora?days=14', { state });
  assert.equal(r.status, 200);
  const p = r.body.projects[0];
  assert.equal(p.lead_time.p50_s, 3 * 86400);
  assert.equal(p.lead_time.deploy_verified, true);
  assert.equal(p.deployment_frequency.count, 1);
  assert.equal(r.body.totals.departures, 1);
  // The deploy read is its own query, filtered to the window like the merges.
  const dep = r.db._calls.find((c) => /kind='deploy'/.test(c.sql));
  assert.ok(dep, 'the route must read the deploy ledger');
  assert.doesNotMatch(dep.sql, /^(INSERT|UPDATE|DELETE)/i);
});
