import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import worker, { computeDora } from '../src/index.js';
import { jobsSchemaSql } from './lib/jobs-schema.js';

// BH-1024 — A SECOND REVIEW ROUND MUST NOT ERASE THE FIRST, AND A VERDICT
// review-prs WRITES MUST BE REACHABLE THROUGH /api/verdict.
//
// WHY THIS FILE DRIVES REAL SQL. `job_artifacts` is keyed (job_id,
// artifact_kind), so every verdict write is an upsert and round 2 overwrites
// round 1 in place — schema.sql says so on purpose. The fix is an append-only
// `verdict_history` table, and every guarantee about it is a guarantee about
// SQL: the table exists after a re-apply, the append is idempotent BY CONTENT,
// and the read comes back oldest-first. A regex-routed fake D1 cannot prove any
// of that, so this file applies the real schema.sql into node:sqlite and hands
// the worker a ~40-line D1 shim over it. The routes run through
// `worker.fetch` — the production entry point, not a seam.
//
// `t.skip` when node:sqlite is missing, the settings-schema.test.js rule: a
// silent pass here would hide exactly the check that makes the file appliable.

const SCHEMA = jobsSchemaSql();
const SECRET = 'test-secret';
const PR = 'https://github.com/example-org/demo-os/pull/12';
const SHA1 = 'aaaaaaa1111aaaaaaa1111aaaaaaa1111aaaaaaa1';
const SHA2 = 'bbbbbbb2222bbbbbbb2222bbbbbbb2222bbbbbbb2';

// The D1 surface the worker actually uses: prepare().bind().first()/all()/run()
// and batch(). `undefined` is coerced to null because D1 refuses it and
// node:sqlite throws on it — one difference that would otherwise read as a bug
// in the handler rather than in the shim.
function d1(db) {
  const clean = (b) => b.map((v) => (v === undefined ? null : v));
  const stmt = (sql, binds = []) => ({
    bind: (...b) => stmt(sql, clean(b)),
    first: async () => db.prepare(sql).get(...binds) ?? null,
    all: async () => ({ results: db.prepare(sql).all(...binds) }),
    run: async () => {
      const r = db.prepare(sql).run(...binds);
      return { meta: { changes: r.changes, last_row_id: r.lastInsertRowid } };
    },
  });
  return { prepare: (sql) => stmt(sql), batch: async (ss) => Promise.all(ss.map((s) => s.run())) };
}

// THE LIVE DATABASE AS IT STANDS THE MINUTE THIS WORKER DEPLOYS (BH-1024 fix
// round 5). `bin/harness-sync.sh` runs `npx wrangler deploy` and nothing else —
// there is no `wrangler d1 execute` anywhere in bin/, cron/, fly/ or .github/,
// and wrangler.jsonc declares no `migrations_dir` — so re-applying schema.sql
// is a HAND step and a table that waits for it ships DEAD. This fixture is
// schema.sql with BH-1024's own CREATE removed: every case that runs against it
// is the real D1 the deploy lands on. Both strips are asserted in the case that
// uses them, so a rename can never turn this into a vacuous pass.
const SCHEMA_BEFORE_BH1024 = SCHEMA
  .replace(/CREATE TABLE IF NOT EXISTS verdict_history[\s\S]*?\n\);\n/, '')
  .replace(/CREATE INDEX IF NOT EXISTS idx_verdict_history_job[^\n]*\n/, '');

async function callWith(DB, path, { method = 'GET', body } = {}) {
  const req = new Request(`https://jobs.test${path}`, {
    method,
    headers: { authorization: `Bearer ${SECRET}`, 'content-type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const res = await worker.fetch(req, { DB, HARNESS_SECRET: SECRET });
  return { status: res.status, body: await res.json().catch(() => null) };
}

async function call(db, path, opts) {
  return callWith(d1(db), path, opts);
}

async function openDb(t, sql = SCHEMA) {
  let DatabaseSync;
  try {
    ({ DatabaseSync } = await import('node:sqlite'));
  } catch {
    t.skip('node:sqlite unavailable on this runtime');
    return null;
  }
  const db = new DatabaseSync(':memory:');
  db.exec(sql);
  return db;
}

const job = (db, over = {}) => {
  const j = { id: 'j-1', project: 'demo-os', kind: 'build', stage: 'review', box: 'b',
    ticket_id: 'BH-1', status: 'running', created_at: '2026-09-19T00:00:00Z',
    updated_at: '2026-09-19T00:00:00Z', ...over };
  db.prepare(`INSERT INTO jobs (id,project,kind,stage,box,ticket_id,status,created_at,updated_at)
              VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9)`)
    .run(j.id, j.project, j.kind, j.stage, j.box, j.ticket_id, j.status, j.created_at, j.updated_at);
  return j.id;
};

const putVerdict = (db, id, word, detail) =>
  call(db, `/api/jobs/${id}/artifacts`, {
    method: 'PUT',
    body: { artifact_kind: 'verdict', artifact_ref: word, detail, actor: 'test-box' },
  });

const rows = (db) => db.prepare('SELECT * FROM verdict_history ORDER BY id ASC').all();

test('the flag row ships at 0 and an operator edit survives a re-apply', async (t) => {
  const db = await openDb(t);
  if (!db) return;
  const seed = db.prepare("SELECT value, actor, note FROM settings WHERE key='verdict_single_home'").get();
  assert.ok(seed, 'schema.sql seeds no verdict_single_home row — nothing can land dark behind a flag that is not there');
  assert.equal(seed.value, '0', 'the flag must ship OFF: with it on, three lanes change behaviour on the deploy that adds it');
  assert.equal(seed.actor, 'seed');
  assert.match(String(seed.note), /BH-1024/);

  db.prepare("UPDATE settings SET value='1', actor='hub' WHERE key='verdict_single_home'").run();
  db.exec(SCHEMA);  // throws if the file is not re-runnable
  const after = db.prepare("SELECT value, actor FROM settings WHERE key='verdict_single_home'").get();
  assert.equal(after.value, '1', 're-applying schema.sql turned the flag back off under an operator');
  assert.equal(after.actor, 'hub');
  db.close();
});

test('a second review round appends a history row instead of erasing the first', async (t) => {
  const db = await openDb(t);
  if (!db) return;
  const id = job(db);

  const r1 = await putVerdict(db, id, 'BLOCK',
    JSON.stringify({ tier: '2', provenance: 'claude', reviewed_sha: SHA1, settled: true, source: 'run-build' }));
  assert.equal(r1.status, 200);
  assert.equal(r1.body.history_appended, true, 'the first verdict is a round and must be recorded as one');

  const r2 = await putVerdict(db, id, 'APPROVE',
    JSON.stringify({ tier: '1', provenance: 'claude', reviewed_sha: SHA2, settled: true, source: 'run-build' }));
  assert.equal(r2.status, 200);
  assert.equal(r2.body.history_appended, true);

  const h = rows(db);
  assert.equal(h.length, 2, 'two rounds, two rows — the upsert may overwrite the standing verdict, the history may not');
  assert.deepEqual(h.map((r) => r.verdict), ['BLOCK', 'APPROVE']);
  assert.deepEqual(h.map((r) => r.reviewed_sha), [SHA1, SHA2]);
  assert.deepEqual(h.map((r) => r.tier), ['2', '1']);
  assert.equal(h[0].provenance, 'claude');
  assert.equal(h[0].source, 'run-build');
  assert.equal(h[0].job_id, id);
  assert.ok(h[0].created_at, 'a round with no instant is not a history');
  assert.equal(JSON.parse(h[1].detail).reviewed_sha, SHA2, 'the detail rides verbatim, so a later reader loses nothing');

  // The STANDING verdict is still one row and still the current one. That rule
  // is what every merge gate acts on and this change must not touch it.
  const std = db.prepare("SELECT * FROM job_artifacts WHERE job_id=?1 AND artifact_kind='verdict'").all(id);
  assert.equal(std.length, 1);
  assert.equal(std[0].artifact_ref, 'APPROVE');
  db.close();
});

test('an identical replay of a verdict PUT appends nothing', async (t) => {
  const db = await openDb(t);
  if (!db) return;
  const id = job(db);
  const detail = JSON.stringify({ tier: '1', provenance: 'claude', reviewed_sha: SHA1, settled: true });
  await putVerdict(db, id, 'APPROVE', detail);
  const again = await putVerdict(db, id, 'APPROVE', detail);
  assert.equal(again.body.history_appended, false,
    'a lane that re-puts the same row on the next tick must not invent a second round');
  assert.equal(rows(db).length, 1);

  // ...and a real change still appends, so the dedupe is by CONTENT and not a
  // "one row per job" cap that would swallow every later round.
  const moved = await putVerdict(db, id, 'APPROVE',
    JSON.stringify({ tier: '1', provenance: 'claude', reviewed_sha: SHA2, settled: true }));
  assert.equal(moved.body.history_appended, true, 'a rebind onto a new sha is a new round');
  assert.equal(rows(db).length, 2);
  db.close();
});

test('a non-verdict artifact records no round at all', async (t) => {
  const db = await openDb(t);
  if (!db) return;
  const id = job(db);
  const r = await call(db, `/api/jobs/${id}/artifacts`, {
    method: 'PUT', body: { artifact_kind: 'pr_url', artifact_ref: PR },
  });
  assert.equal(r.status, 200);
  assert.equal(r.body.history_appended, false);
  assert.equal(rows(db).length, 0, 'a pr_url is not a judgement and must never enter the verdict history');
  db.close();
});

test('GET /api/verdict/history returns the rounds oldest first, and 404s a PR nobody recorded', async (t) => {
  const db = await openDb(t);
  if (!db) return;
  const id = job(db);
  await call(db, `/api/jobs/${id}/artifacts`, { method: 'PUT', body: { artifact_kind: 'pr_url', artifact_ref: PR } });
  await putVerdict(db, id, 'BLOCK', JSON.stringify({ tier: '2', reviewed_sha: SHA1, settled: true }));
  await putVerdict(db, id, 'APPROVE', JSON.stringify({ tier: '1', reviewed_sha: SHA2, settled: true }));

  const r = await call(db, `/api/verdict/history?pr=${encodeURIComponent(PR)}`);
  assert.equal(r.status, 200);
  assert.equal(r.body.job_id, id);
  assert.equal(r.body.pr, PR);
  assert.deepEqual(r.body.rounds.map((x) => x.verdict), ['BLOCK', 'APPROVE'],
    'oldest first: a history read backwards reads as "it was approved and then blocked"');
  assert.deepEqual(r.body.rounds.map((x) => x.reviewed_sha), [SHA1, SHA2]);
  assert.equal(r.body.truncated, false, 'the 200-round cap is NAMED, so a prefix can never read as a whole history');

  const miss = await call(db, `/api/verdict/history?pr=${encodeURIComponent(PR)}9`);
  assert.equal(miss.status, 404, 'no job recorded that PR is a REAL answer, never an empty rounds list');

  const bad = await call(db, '/api/verdict/history');
  assert.equal(bad.status, 400);
  db.close();
});

test('a verdict review-prs wrote is reachable through /api/verdict', async (t) => {
  const db = await openDb(t);
  if (!db) return;
  // Exactly the shape bin/review-prs.sh's ledger block writes: a short-lived
  // review-verdict job, a pr_url row, then the verdict bound to the head.
  const id = job(db, { id: 'rv-1', kind: 'review-verdict', ticket_id: 'example-org/demo-os#12' });
  await call(db, `/api/jobs/${id}/artifacts`, { method: 'PUT', body: { artifact_kind: 'pr_url', artifact_ref: PR } });
  await putVerdict(db, id, 'APPROVE', JSON.stringify({
    tier: '2', provenance: 'claude', served_by: 'claude', reviewed_sha: SHA1,
    settled: true, source: 'review-prs', pr: PR,
  }));

  const r = await call(db, `/api/verdict?pr=${encodeURIComponent(PR)}`);
  assert.equal(r.status, 200, 'an external PR review-prs reviewed must be visible to job_verdict');
  assert.equal(r.body.verdict, 'APPROVE');
  assert.equal(r.body.reviewed_sha, SHA1);
  assert.equal(r.body.job_id, 'rv-1');
  const d = JSON.parse(r.body.artifacts.find((a) => a.artifact_kind === 'verdict').detail);
  assert.equal(d.source, 'review-prs', 'the source is what lets the autopilot tell this lane\'s row from a build\'s');
  db.close();
});

test('a review-verdict row never takes a PR away from the job that built it', async (t) => {
  const db = await openDb(t);
  if (!db) return;
  // THE COLLISION THIS RESOLUTION EXISTS FOR. bin/review-prs.sh skips harness
  // PRs it recognises, and both halves of that filter fail OPEN into "review
  // it" — a gh 429 is enough. So a build PR can end up with a SECOND pr_url
  // row, newer than the build's, on a review-verdict job. `pr_url` is the only
  // key the fleet has, so the newest-wins rule would hand the sweep, mc_verdict
  // and every rebind the review lane's answer about a build they are gating;
  // a disagreeing pair parks the PR for good.
  const build = job(db, { id: 'build-1', kind: 'build' });
  await call(db, `/api/jobs/${build}/artifacts`, { method: 'PUT', body: { artifact_kind: 'pr_url', artifact_ref: PR } });
  await putVerdict(db, build, 'APPROVE', JSON.stringify({
    tier: '1', provenance: 'claude', reviewed_sha: SHA1, settled: true, source: 'run-build',
  }));
  const rv = job(db, { id: 'rv-1', kind: 'review-verdict', ticket_id: 'example-org/demo-os#12',
    created_at: '2026-09-19T05:00:00Z', updated_at: '2026-09-19T05:00:00Z' });
  await call(db, `/api/jobs/${rv}/artifacts`, { method: 'PUT', body: { artifact_kind: 'pr_url', artifact_ref: PR } });
  await putVerdict(db, rv, 'BLOCK', JSON.stringify({
    tier: '2', provenance: 'claude', reviewed_sha: SHA1, settled: true, source: 'review-prs',
  }));
  // Both PUTs stamp the worker's own clock, so without this the two pr_url rows
  // can share an instant and the case would pass on a tie rather than on the
  // rule. Dated forward: the review lane's row is unambiguously the NEWEST, and
  // newest-wins is precisely what must not decide here.
  db.prepare("UPDATE job_artifacts SET updated_at='2099-01-01T00:00:00Z' WHERE job_id='rv-1' AND artifact_kind='pr_url'").run();
  const newest = db.prepare(
    "SELECT job_id FROM job_artifacts WHERE artifact_kind='pr_url' AND artifact_ref=?1 ORDER BY updated_at DESC LIMIT 1"
  ).get(PR);
  assert.equal(newest.job_id, 'rv-1', 'the fixture must be the collision: the review lane holds the newest pr_url row');

  const v = await call(db, `/api/verdict?pr=${encodeURIComponent(PR)}`);
  assert.equal(v.status, 200);
  assert.equal(v.body.job_id, 'build-1',
    "the build's own verdict row is its ledger identity — a review lane writing the same pr_url must not become the standing verdict");
  assert.equal(v.body.verdict, 'APPROVE');
  assert.equal(v.body.reviewed_sha, SHA1);
  assert.equal(v.body.job.kind, 'build', 'the job that comes back is the one the artifacts belong to');

  const h = await call(db, `/api/verdict/history?pr=${encodeURIComponent(PR)}`);
  assert.equal(h.status, 200);
  assert.equal(h.body.job_id, 'build-1',
    'the STANDING owner is the job the verdict answers for — the history widened, the verdict did not');
  // CORRECTED in BH-1024 fix round 5, together with the route it pins. The
  // rounds are keyed on the PR now, not on the one job prLedgerJob picks, so
  // BOTH lanes' rounds come back and each names the job that wrote it. The
  // guarantee this line was written for is unchanged and asserted harder: the
  // build's own APPROVE is present, FIRST, and attributed to build-1. What
  // changes is that the review lane's BLOCK is no longer invisible to a ledger
  // reader — which is the direction docs/verification-map/verdict-ledger.md
  // used to have to warn about in prose.
  assert.deepEqual(h.body.rounds.map((r) => [r.job_id, r.verdict]),
    [['build-1', 'APPROVE'], ['rv-1', 'BLOCK']],
    "a history that showed only the review lane's round would report the build's own approval as gone");
  db.close();
});

test('the review-verdict row is still reachable when it is the only one', async (t) => {
  const db = await openDb(t);
  if (!db) return;
  // The preference is a TIE-BREAK, not a filter: an external PR has no build
  // job, and that is exactly the case bin/review-prs.sh's write exists for.
  const rv = job(db, { id: 'rv-1', kind: 'review-verdict' });
  await call(db, `/api/jobs/${rv}/artifacts`, { method: 'PUT', body: { artifact_kind: 'pr_url', artifact_ref: PR } });
  await putVerdict(db, rv, 'APPROVE', JSON.stringify({ reviewed_sha: SHA1, settled: true, source: 'review-prs' }));
  const v = await call(db, `/api/verdict?pr=${encodeURIComponent(PR)}`);
  assert.equal(v.body.job_id, 'rv-1');
  assert.equal(v.body.verdict, 'APPROVE');
  db.close();
});

test('a verdict PUT with no detail records the round the standing row actually says', async (t) => {
  const db = await openDb(t);
  if (!db) return;
  // The upsert keeps the old detail (`detail=COALESCE(?5, detail)`), which is
  // what `jobs-client.sh artifact-put verdict APPROVE` does — an operator verb
  // that sends no detail. A round read off the REQUEST would write "the
  // approval lost its sha" into the one table whose job is to say which sha was
  // approved, while the standing row still carried it.
  const id = job(db);
  await putVerdict(db, id, 'BLOCK', JSON.stringify({ tier: '2', provenance: 'claude', reviewed_sha: SHA1, settled: true }));
  const r = await call(db, `/api/jobs/${id}/artifacts`, {
    method: 'PUT', body: { artifact_kind: 'verdict', artifact_ref: 'APPROVE' },
  });
  assert.equal(r.status, 200);
  assert.equal(r.body.history_appended, true, 'BLOCK -> APPROVE is a new round whatever the detail did');
  const h = rows(db);
  assert.equal(h.length, 2);
  assert.equal(h[1].verdict, 'APPROVE');
  assert.equal(h[1].reviewed_sha, SHA1,
    'the round must carry the sha the standing row still carries, not a null the request never meant');
  assert.equal(h[1].tier, '2');
  assert.equal(JSON.parse(h[1].detail).reviewed_sha, SHA1);
  db.close();
});

test('the DORA read ignores a review-verdict job when it attributes a merged PR', async (t) => {
  const db = await openDb(t);
  if (!db) return;
  const id = job(db, { id: 'rv-1', kind: 'review-verdict', created_at: '2026-09-19T11:00:00Z' });
  await call(db, `/api/jobs/${id}/artifacts`, { method: 'PUT', body: { artifact_kind: 'pr_url', artifact_ref: PR } });
  await putVerdict(db, id, 'APPROVE', JSON.stringify({ tier: '1', reviewed_sha: SHA1, settled: true, source: 'review-prs' }));
  // The DORA window is computed from the WORKER's own clock (`since` = now -
  // days), so the one honest instant for this fixture is now: a pinned date
  // would age out of the window and turn this into a test that picks its own
  // red day. Nothing below compares times — only whether the merge is
  // attributed to the review-verdict job.
  const mergedAt = new Date().toISOString().replace(/\.\d{3}Z$/, 'Z');  // determinism: ok the window is relative to the worker's clock, so a pinned instant would age out of it
  db.prepare(`INSERT INTO ledgers (kind,key,status,job_id,created_at,updated_at)
              VALUES ('merge',?1,'merged','rv-1',?2,?2)`).run(PR, mergedAt);

  const r = await call(db, '/api/metrics/dora?days=14');
  assert.equal(r.status, 200);
  const rowsOut = r.body.projects.flatMap((p) => [p]);
  const fromJob = rowsOut.reduce((n, p) => n + p.lead_time.from_job_n, 0);
  assert.equal(fromJob, 0,
    'a review-verdict job is minutes old and never built the PR — attributing a merge to it reports a one-minute lead time for a week of work');
  assert.equal(r.body.totals.merged, 1, 'the merge itself is still counted; only its false attribution is dropped');
  db.close();
});

test('computeDora drops a review-verdict job from both the PR map and the approval clock', async () => {
  // The pure half of the same rule, on the row shape the route's join produces.
  const now = Date.parse('2026-09-19T12:00:00Z');
  const at = (msAgo) => new Date(now - msAgo).toISOString().replace(/\.\d{3}Z$/, 'Z');
  const artifacts = [
    { artifact_kind: 'pr_url', artifact_ref: PR, job_id: 'rv-1', job_kind: 'review-verdict',
      project: 'demo-os', ticket_id: 'x', job_created_at: at(60e3), created_at: at(60e3), updated_at: at(60e3) },
    { artifact_kind: 'verdict', artifact_ref: 'APPROVE', job_id: 'rv-1', job_kind: 'review-verdict',
      project: 'demo-os', job_created_at: at(60e3), created_at: at(60e3), updated_at: at(60e3) },
  ];
  const merges = [{ key: PR, status: 'merged', job_id: 'rv-1', created_at: at(30e3), updated_at: at(30e3) }];
  const out = computeDora({ days: 14, now, merges, artifacts, outcomes: [], prStates: [], repoMap: [], deploys: [] });
  const p = out.projects[0];
  assert.equal(out.totals.merged, 1);
  assert.equal(p.lead_time.from_job_n, 0, 'the review job is not the job that built the change');
  assert.equal(p.lead_time.unattributed_n, 1, 'and an unattributed merge says so rather than borrowing a number');
  assert.equal(p.merge_lane.n, 0, 'a review-prs APPROVE is not the approval a merge lane waited on');
});

// ── ROUND 4: the row shapes bin/review-prs.sh ACTUALLY writes ────────────────
// The two tests above pin the build-vs-review-verdict pair, and both fixtures
// leave out the row that is written BETWEEN them on every real tick: the lane
// job. `review_claim` (bin/review-prs.sh:212-225) opens a job of kind `review`
// per (PR, sha) and the BH-1064 block (:832-865) writes `verdict` — the RAW
// `APPROVE`/`REQUEST_CHANGES`, in a detail with NO `source` — and then `pr_url`
// onto it, seconds before this ticket's block opens its `review-verdict` job.
//
// So a rule spelled "the newest pr_url, unless its job is a review-verdict"
// resolves every reviewed PR to the LANE row: it is not a build, it is not a
// review-verdict, and it is newer than the build's. That is the build's verdict
// displaced on a harness PR, and on an external PR it is an answer with no
// `source`, which is the one field `job_verdict_covers … review-prs` filters on
// — so the autopilot skip could never fire in production.
//
// The rule these two pin is a RANKING, not a carve-out: a build's row first,
// then the row that carries the review lane's provenance, then newest.

test('the review lane row never takes a PR away from the job that built it', async (t) => {
  const db = await openDb(t);
  if (!db) return;
  const build = job(db, { id: 'build-1', kind: 'build',
    created_at: '2026-09-19T01:00:00Z', updated_at: '2026-09-19T01:00:00Z' });
  await call(db, `/api/jobs/${build}/artifacts`, { method: 'PUT', body: { artifact_kind: 'pr_url', artifact_ref: PR } });
  await putVerdict(db, build, 'APPROVE', JSON.stringify({
    tier: '1', provenance: 'claude', reviewed_sha: SHA1, settled: true, source: 'run-build',
  }));

  // The BH-1064 lane row, verbatim: kind `review`, the RAW review word, and a
  // detail that names the record and the head but no `source`.
  const lane = job(db, { id: 'lane-1', kind: 'review', ticket_id: null,
    created_at: '2026-09-19T05:00:00Z', updated_at: '2026-09-19T05:00:00Z' });
  await putVerdict(db, lane, 'REQUEST_CHANGES', JSON.stringify({
    tier: '2', provenance: 'claude', record: 'review-prs:demo-os:12', headbound: 'n/a',
    reviewed_sha: SHA1, settled: true,
  }));
  await call(db, `/api/jobs/${lane}/artifacts`, { method: 'PUT',
    body: { artifact_kind: 'pr_url', artifact_ref: PR, detail: JSON.stringify({ number: '12', lane: 'review-prs' }) } });

  const rv = job(db, { id: 'rv-1', kind: 'review-verdict', ticket_id: 'example-org/demo-os#12',
    created_at: '2026-09-19T05:00:01Z', updated_at: '2026-09-19T05:00:01Z' });
  await call(db, `/api/jobs/${rv}/artifacts`, { method: 'PUT', body: { artifact_kind: 'pr_url', artifact_ref: PR } });
  await putVerdict(db, rv, 'BLOCK', JSON.stringify({
    tier: '2', provenance: 'claude', reviewed_sha: SHA1, settled: true, source: 'review-prs',
  }));

  // One tick writes all three inside a second, so the fixture dates them apart
  // in the order review-prs writes them: the collision must be decided by the
  // RULE, never by a tie.
  db.prepare("UPDATE job_artifacts SET updated_at='2099-01-01T00:00:00Z' WHERE job_id='lane-1' AND artifact_kind='pr_url'").run();
  db.prepare("UPDATE job_artifacts SET updated_at='2099-01-01T00:00:01Z' WHERE job_id='rv-1' AND artifact_kind='pr_url'").run();

  const v = await call(db, `/api/verdict?pr=${encodeURIComponent(PR)}`);
  assert.equal(v.status, 200);
  assert.equal(v.body.job_id, 'build-1',
    "the lane row is neither a build nor a review-verdict, so a carve-out on `review-verdict` alone hands it the PR and the build's APPROVE becomes unreachable");
  assert.equal(v.body.verdict, 'APPROVE');
  assert.equal(v.body.job.kind, 'build');
  const d = JSON.parse(v.body.artifacts.find((a) => a.artifact_kind === 'verdict').detail);
  assert.equal(d.source, 'run-build');

  const h = await call(db, `/api/verdict/history?pr=${encodeURIComponent(PR)}`);
  assert.equal(h.status, 200);
  assert.equal(h.body.job_id, 'build-1', 'the standing owner is the same job the verdict answers for');
  // CORRECTED in BH-1024 fix round 5 with the route (see the case above). All
  // THREE rounds this PR collected come back, oldest first, each attributed —
  // and the BH-1064 lane row's RAW `REQUEST_CHANGES`, which no ledger reader
  // could see before, is one of them. The build's APPROVE is still first and
  // still the standing verdict.
  assert.deepEqual(h.body.rounds.map((r) => [r.job_id, r.verdict]),
    [['build-1', 'APPROVE'], ['lane-1', 'REQUEST_CHANGES'], ['rv-1', 'BLOCK']],
    'every round recorded against this PR comes back with the job that wrote it');
  db.close();
});

test('an external PR resolves to the row that carries `source`, not the lane row', async (t) => {
  const db = await openDb(t);
  if (!db) return;
  // No build job — the case bin/review-prs.sh's ledger write exists for. Both
  // rows describe the same review; only the review-verdict one carries the
  // `source` that `job_verdict_covers <pr> <sha> review-prs` filters on, so a
  // resolution that answers the lane row makes the autopilot skip dead code.
  const lane = job(db, { id: 'lane-1', kind: 'review',
    created_at: '2026-09-19T05:00:00Z', updated_at: '2026-09-19T05:00:00Z' });
  await putVerdict(db, lane, 'APPROVE', JSON.stringify({
    tier: '2', provenance: 'claude', record: 'review-prs:demo-os:12', headbound: 'n/a',
    reviewed_sha: SHA1, settled: true,
  }));
  await call(db, `/api/jobs/${lane}/artifacts`, { method: 'PUT', body: { artifact_kind: 'pr_url', artifact_ref: PR } });

  const rv = job(db, { id: 'rv-1', kind: 'review-verdict', ticket_id: 'example-org/demo-os#12',
    created_at: '2026-09-19T05:00:01Z', updated_at: '2026-09-19T05:00:01Z' });
  await call(db, `/api/jobs/${rv}/artifacts`, { method: 'PUT', body: { artifact_kind: 'pr_url', artifact_ref: PR } });
  await putVerdict(db, rv, 'APPROVE', JSON.stringify({
    tier: '2', provenance: 'claude', served_by: 'claude', reviewed_sha: SHA1,
    settled: true, source: 'review-prs', pr: PR,
  }));
  db.prepare("UPDATE job_artifacts SET updated_at='2099-01-01T00:00:00Z' WHERE job_id='lane-1' AND artifact_kind='pr_url'").run();
  db.prepare("UPDATE job_artifacts SET updated_at='2099-01-01T00:00:01Z' WHERE job_id='rv-1' AND artifact_kind='pr_url'").run();

  const v = await call(db, `/api/verdict?pr=${encodeURIComponent(PR)}`);
  assert.equal(v.status, 200);
  assert.equal(v.body.job_id, 'rv-1',
    'the lane row would answer with no `source`, and a sourceless row fails the review-prs filter — the skip this ticket sells would never fire');
  const d = JSON.parse(v.body.artifacts.find((a) => a.artifact_kind === 'verdict').detail);
  assert.equal(d.source, 'review-prs');
  assert.equal(d.served_by, 'claude');

  const h = await call(db, `/api/verdict/history?pr=${encodeURIComponent(PR)}`);
  assert.equal(h.body.job_id, 'rv-1', 'the history follows the same row the verdict does');
  db.close();
});

test('computeDora drops the review LANE job too, not only the review-verdict one', async () => {
  // Same blind spot, one table over. The BH-1064 lane row carries `pr_url` +
  // `verdict` for an external PR, and that job is a review claim minutes old —
  // attributing somebody else's merge to it reports a one-minute lead time and
  // counts a review lane's APPROVE as the approval a merge lane waited on.
  const now = Date.parse('2026-09-19T12:00:00Z');
  const at = (msAgo) => new Date(now - msAgo).toISOString().replace(/\.\d{3}Z$/, 'Z');
  const artifacts = [
    { artifact_kind: 'pr_url', artifact_ref: PR, job_id: 'lane-1', job_kind: 'review',
      project: 'demo-os', ticket_id: 'x', job_created_at: at(60e3), created_at: at(60e3), updated_at: at(60e3) },
    { artifact_kind: 'verdict', artifact_ref: 'APPROVE', job_id: 'lane-1', job_kind: 'review',
      project: 'demo-os', job_created_at: at(60e3), created_at: at(60e3), updated_at: at(60e3) },
  ];
  const merges = [{ key: PR, status: 'merged', job_id: 'lane-1', created_at: at(30e3), updated_at: at(30e3) }];
  const out = computeDora({ days: 14, now, merges, artifacts, outcomes: [], prStates: [], repoMap: [], deploys: [] });
  const p = out.projects[0];
  assert.equal(out.totals.merged, 1, 'the merge itself is still counted; only its false attribution is dropped');
  assert.equal(p.lead_time.from_job_n, 0, 'a review claim is not the job that built the change');
  assert.equal(p.lead_time.unattributed_n, 1);
  assert.equal(p.merge_lane.n, 0);
});

// ── BH-1024 fix round 5 (drain review round 1) ───────────────────────────────
// Everything below stands where the FLEET stands: a live D1 that schema.sql has
// never been re-applied to, a history write that fails, a PR that was reviewed
// twice, and two lanes writing the same verdict in the same instant.

test('the history table self-creates on a database that predates it', async (t) => {
  // THE BLOCK. schema.sql is not a migration on this fleet (see
  // SCHEMA_BEFORE_BH1024 above), so a `verdict` PUT against the live D1 threw
  // `no such table: verdict_history` the moment this worker deployed — after
  // the standing upsert had already landed. Every job_artifact_put verdict
  // would 500: job_verdict_rebind rc 1, mc_rebase rc 5, rebased approved PRs
  // parked in NEEDS_REBASE "rebind-failed" until a human ran `d1 execute`.
  const db = await openDb(t, SCHEMA_BEFORE_BH1024);
  if (!db) return;
  assert.match(SCHEMA, /CREATE TABLE IF NOT EXISTS verdict_history/,
    'schema.sql no longer creates verdict_history — this fixture strips nothing and the case is vacuous');
  assert.doesNotMatch(SCHEMA_BEFORE_BH1024, /CREATE TABLE IF NOT EXISTS verdict_history/,
    'the merge-base fixture still carries the CREATE, so it is not the database the deploy lands on');
  assert.doesNotMatch(SCHEMA_BEFORE_BH1024, /CREATE INDEX IF NOT EXISTS idx_verdict_history_job/,
    'the merge-base fixture still carries the index');
  assert.throws(() => db.prepare('SELECT 1 FROM verdict_history').all(),
    'the fixture database already has the table — it is not the pre-deploy one');

  const id = job(db);
  await call(db, `/api/jobs/${id}/artifacts`, { method: 'PUT', body: { artifact_kind: 'pr_url', artifact_ref: PR } });
  const r = await putVerdict(db, id, 'BLOCK',
    JSON.stringify({ tier: '2', provenance: 'claude', reviewed_sha: SHA1, settled: true, source: 'run-build' }));
  assert.equal(r.status, 200,
    'a verdict PUT 500s on the live D1 until the table creates itself the way CREATED_TABLES does for every other BH-658 table');
  assert.equal(r.body.history_appended, true, 'the round must be recorded, not silently skipped');
  assert.equal(rows(db).length, 1);
  assert.equal(rows(db)[0].verdict, 'BLOCK');

  const h = await call(db, `/api/verdict/history?pr=${encodeURIComponent(PR)}`);
  assert.equal(h.status, 200, 'the history route must self-create the table too — it can be the first reader after a deploy');
  assert.deepEqual(h.body.rounds.map((x) => x.verdict), ['BLOCK']);
  db.close();
});

test('worker index carries verdict_history in CREATED_TABLES, column for column with schema.sql', async () => {
  // The other half of the BLOCK: `ensureTable` can only create what the literal
  // map declares, and a map that drifts from schema.sql creates a table the
  // routes then fail against on a fresh database.
  const d = (await import('../src/index.js')).default;
  assert.ok(Array.isArray(d.CREATED_TABLES.verdict_history), 'CREATED_TABLES.verdict_history is missing');
  const ddl = d.CREATED_TABLES.verdict_history.join('\n');
  assert.match(ddl, /CREATE TABLE IF NOT EXISTS verdict_history/);
  assert.match(ddl, /idx_verdict_history_job/, 'the index ships with the table or the first history read is a scan');
  assert.doesNotMatch(ddl, /\bDROP\b/i, 'a CREATED_TABLES entry is additive only');
  for (const col of ['job_id', 'verdict', 'reviewed_sha', 'tier', 'provenance',
    'served_by', 'source', 'detail', 'actor', 'created_at']) {
    assert.match(ddl, new RegExp(`\\b${col}\\b`), `CREATED_TABLES.verdict_history is missing the column ${col}`);
  }
});

test('a history write that fails never 500s the standing verdict', async (t) => {
  // The standing verdict is a MERGE GATE; the history is a record. If the
  // append throws — a D1 blip, a table a future deploy has not created yet —
  // the artifact that was already written must still come back 200, and the
  // reason must ride out rather than be swallowed.
  const db = await openDb(t);
  if (!db) return;
  const id = job(db);
  const real = d1(db);
  const boom = () => { throw new Error('D1_ERROR: verdict_history is unavailable'); };
  const broken = {
    prepare: (sql) => (/verdict_history/.test(sql)
      ? { bind: () => ({ first: boom, all: boom, run: boom }), first: boom, all: boom, run: boom }
      : real.prepare(sql)),
    batch: real.batch,
  };
  const r = await callWith(broken, `/api/jobs/${id}/artifacts`, {
    method: 'PUT',
    body: { artifact_kind: 'verdict', artifact_ref: 'APPROVE', detail: JSON.stringify({ reviewed_sha: SHA1 }) },
  });
  assert.equal(r.status, 200, 'a failed history append must not take the standing verdict down with it');
  assert.equal(r.body.history_appended, false);
  assert.match(String(r.body.history_error || ''), /verdict_history/,
    'the reason is named, never swallowed — a blank failure is how a dead table stays invisible');
  const stored = db.prepare("SELECT artifact_ref FROM job_artifacts WHERE job_id=?1 AND artifact_kind='verdict'").get(id);
  assert.equal(stored.artifact_ref, 'APPROVE', 'the standing row landed before the history was touched and must stay landed');
  db.close();
});

test('a failed history append is SAID OUT LOUD, not only returned to a caller that discards it', async (t) => {
  // `history_error` rides out in the response body — and the only fleet caller
  // is `job_artifact_put`, which does `_jobs_req PUT … >/dev/null`: rc 0, body
  // dropped. So an append that fails on EVERY put (a D1 quota error, a column
  // drift between CREATED_TABLES and a hand-applied schema.sql) is invisible:
  // every verdict PUT still answers 200, every lane still logs "recorded in the
  // ledger", and `jobs-client.sh verdict-history <pr>` answers one round for
  // every PR — indistinguishable from "nothing changed". The worker is the only
  // place that KNOWS, so it has to say so where an operator can see a rate:
  // console.error lands in `wrangler tail` and the Cloudflare log.
  const db = await openDb(t);
  if (!db) return;
  const id = job(db);
  const real = d1(db);
  const boom = () => { throw new Error('D1_ERROR: too many rows written'); };
  const broken = {
    prepare: (sql) => (/verdict_history/.test(sql)
      ? { bind: () => ({ first: boom, all: boom, run: boom }), first: boom, all: boom, run: boom }
      : real.prepare(sql)),
    batch: real.batch,
  };
  const said = [];
  const realError = console.error;
  console.error = (...a) => { said.push(a.map(String).join(' ')); };
  let r;
  try {
    r = await callWith(broken, `/api/jobs/${id}/artifacts`, {
      method: 'PUT',
      body: { artifact_kind: 'verdict', artifact_ref: 'APPROVE', detail: JSON.stringify({ reviewed_sha: SHA1 }) },
    });
  } finally { console.error = realError; }
  assert.equal(r.status, 200, 'saying it out loud must not change the answer');
  assert.equal(said.length, 1,
    'a failed history append logs exactly once — silence here is the dead-feed smell, and a log per retry would be its own noise');
  assert.match(said[0], /verdict_history/,
    'the log line names the table, so a reader of wrangler tail knows what failed');
  assert.match(said[0], new RegExp(id),
    'the log line names the JOB, so a persistent failure can be traced to the lane putting the verdict');
  assert.match(said[0], /too many rows written/,
    "the vendor's own reason is carried through — never swallowed into a blank failure line");
  db.close();
});

test('/api/verdict/history returns every round of a re-reviewed PR, across its review-verdict jobs', async (t) => {
  // bin/review-prs.sh opens a review-verdict job per reviewed (PR, sha) and the
  // worker mints a fresh id whenever none is OPEN on that key, so a BLOCK ->
  // rebase -> APPROVE cycle on one external PR is rv-1 and rv-2. A history
  // keyed on the one job `prLedgerJob` picks answers "one round, APPROVE" about
  // a PR the table holds a BLOCK for — the opposite of what worker/jobs/README.md
  // and docs/verification-map/verdict-ledger.md promise.
  const db = await openDb(t);
  if (!db) return;
  const rv1 = job(db, { id: 'rv-1', kind: 'review-verdict', ticket_id: 'example-org/demo-os#12',
    created_at: '2026-09-19T01:00:00Z', updated_at: '2026-09-19T01:00:00Z', status: 'done' });
  await call(db, `/api/jobs/${rv1}/artifacts`, { method: 'PUT', body: { artifact_kind: 'pr_url', artifact_ref: PR } });
  await putVerdict(db, rv1, 'BLOCK', JSON.stringify({
    tier: '2', provenance: 'claude', reviewed_sha: SHA1, settled: true, source: 'review-prs' }));

  const rv2 = job(db, { id: 'rv-2', kind: 'review-verdict', ticket_id: 'example-org/demo-os#12',
    created_at: '2026-09-19T02:00:00Z', updated_at: '2026-09-19T02:00:00Z' });
  await call(db, `/api/jobs/${rv2}/artifacts`, { method: 'PUT', body: { artifact_kind: 'pr_url', artifact_ref: PR } });
  await putVerdict(db, rv2, 'APPROVE', JSON.stringify({
    tier: '1', provenance: 'claude', reviewed_sha: SHA2, settled: true, source: 'review-prs' }));

  assert.equal(rows(db).length, 2, 'the fixture must hold both rounds, or the route has nothing to lose');
  const h = await call(db, `/api/verdict/history?pr=${encodeURIComponent(PR)}`);
  assert.equal(h.status, 200);
  assert.deepEqual(h.body.rounds.map((x) => x.verdict), ['BLOCK', 'APPROVE'],
    'a re-reviewed PR must answer with every round it went through, oldest first — not the newest job alone');
  assert.deepEqual(h.body.rounds.map((x) => x.reviewed_sha), [SHA1, SHA2]);
  assert.deepEqual(h.body.rounds.map((x) => x.job_id), ['rv-1', 'rv-2'],
    'each round names the job that wrote it, so a reader can tell two lanes apart');
  assert.equal(h.body.job_id, 'rv-2',
    'the STANDING owner is still the one prLedgerJob picks — the history widened, the verdict did not');
  db.close();
});

test('the history of one PR never leaks into another', async (t) => {
  // The widened read is keyed on the PR url, so the filter is the whole
  // guarantee: a select that dropped it would hand every reader the fleet's
  // entire verdict history.
  const db = await openDb(t);
  if (!db) return;
  const other = 'https://github.com/example-org/demo-os/pull/99';
  const a = job(db, { id: 'rv-a', kind: 'review-verdict' });
  await call(db, `/api/jobs/${a}/artifacts`, { method: 'PUT', body: { artifact_kind: 'pr_url', artifact_ref: PR } });
  await putVerdict(db, a, 'APPROVE', JSON.stringify({ reviewed_sha: SHA1, settled: true, source: 'review-prs' }));
  const b = job(db, { id: 'rv-b', kind: 'review-verdict' });
  await call(db, `/api/jobs/${b}/artifacts`, { method: 'PUT', body: { artifact_kind: 'pr_url', artifact_ref: other } });
  await putVerdict(db, b, 'BLOCK', JSON.stringify({ reviewed_sha: SHA2, settled: true, source: 'review-prs' }));

  const h = await call(db, `/api/verdict/history?pr=${encodeURIComponent(PR)}`);
  assert.deepEqual(h.body.rounds.map((x) => x.job_id), ['rv-a'],
    "another PR's rounds came back — the history read lost its pr filter");
  db.close();
});

test('two concurrent verdict PUTs for one job append one round, not two', async (t) => {
  // D1 does not serialise across requests, and the append was read-compare-
  // insert across two awaits: run-build's settle write racing
  // review-rescue.sh's verdict_backfill on the same strandee could see the same
  // empty history and both insert. One conditional INSERT closes it.
  const db = await openDb(t);
  if (!db) return;
  const id = job(db);
  const detail = JSON.stringify({ tier: '2', provenance: 'claude', reviewed_sha: SHA1, settled: true, source: 'run-build' });
  const [a, b] = await Promise.all([
    putVerdict(db, id, 'BLOCK', detail),
    putVerdict(db, id, 'BLOCK', detail),
  ]);
  assert.equal(a.status, 200);
  assert.equal(b.status, 200);
  assert.equal(rows(db).length, 1,
    'both requests read an empty history before either wrote — the same verdict was recorded as two rounds');
  assert.equal([a, b].filter((r) => r.body.history_appended).length, 1,
    'exactly one of the two may claim the round; history_appended must come off the write, not off a stale read');
  db.close();
});
