import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import worker from '../src/index.js';
import { ensureColumns } from '../src/lib/core.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import { jobsSchemaSql } from './lib/jobs-schema.js';

// BH-4953 (BH-4950.0) — PR gate facts as `state='gate'` rows in
// pr_state_events, and the one query that answers "needs lead review".
//
// Every route case drives `worker.fetch` (D2) over the real schema.sql in
// node:sqlite, so the fold and the eligibility rule are the SQL and JS that
// ship, not a stub. The N7 order case seeds rows straight into the table
// because the route stamps `at` from the wall clock and the order key IS `at`;
// the rows it writes are the exact shape recordGateEvent writes.
//
// `t.skip` when node:sqlite is absent: a silent pass would hide the checks.

const SCHEMA = jobsSchemaSql();
const SECRET = 'test-secret';
const REPO = 'o/r';
const NEW_COLS = ['draft', 'closed', 'held', 'hotfix', 'ci_green_sha', 'builder_approved_sha',
  'lead_verdict_sha', 'lead_verdict_word', 'reviewing_sha', 'review_failed_sha', 'nudged_sha'];
const A = 'aaa1111';
const B = 'bbb2222';

async function call(DB, path, { method = 'GET', body } = {}) {
  const req = new Request(`https://jobs.test${path}`, {
    method,
    headers: { 'content-type': 'application/json', authorization: `Bearer ${SECRET}` },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const res = await worker.fetch(req, { DB, HARNESS_SECRET: SECRET });
  return { status: res.status, body: await res.json().catch(() => null) };
}

let seq = 0;
// One gate event through the real POST. `since` is the caller's source, so
// every call gets its own unless the case is testing a replay.
async function gate(DB, number, fields, { repo = REPO, since } = {}) {
  seq += 1;
  const r = await call(DB, '/api/pr-state-events', {
    method: 'POST',
    body: { repo, number, state: 'gate', since: since || `src-${seq}`, reason: 'test', actor: 'box', ...fields },
  });
  assert.ok(r.status === 201 || r.status === 200, `gate POST ${JSON.stringify(fields)} -> ${r.status} ${JSON.stringify(r.body)}`);
  return r;
}
// The three facts that make a PR eligible, on one sha.
const eligible = (DB, number, sha = A, extra = {}, opts) =>
  gate(DB, number, { head: sha, ci_green_sha: sha, builder_approved_sha: sha, ...extra }, opts);

async function needs(DB, q = `repo=${REPO}`) {
  const r = await call(DB, `/api/pr-state/needs-review?${q}`);
  assert.equal(r.status, 200, JSON.stringify(r.body));
  return r.body;
}
const nums = (body) => body.rows.map((r) => r.number);

async function open(t) {
  const o = await openDb();
  if (!o) { t.skip('node:sqlite unavailable on this runtime'); return null; }
  return o;
}

// ── Contract ────────────────────────────────────────────────────────────────
test('C1: the 11 gate columns exist after one gate read, and schema.sql has no bare ALTER', async (t) => {
  const o = await open(t); if (!o) return;
  const r = await call(o.DB, `/api/pr-state/gate?repo=${REPO}`);
  assert.equal(r.status, 200, JSON.stringify(r.body));
  const have = new Set(o.db.prepare('PRAGMA table_info(pr_state_events)').all().map((c) => c.name));
  for (const c of NEW_COLS) assert.ok(have.has(c), `missing column ${c}`);
  assert.equal(/ALTER\s+TABLE\s+pr_state_events/i.test(SCHEMA), false);
});

test('C2: GATE_FIELDS is head plus the 11 columns', async () => {
  const mod = await import('../src/lib/pr-gate.js');
  assert.deepEqual([...mod.GATE_FIELDS].sort(), ['head', ...NEW_COLS].sort());
  assert.equal(mod.GATE_FIELDS.length, 12);
});

// ── Routes ──────────────────────────────────────────────────────────────────
test('R1/R2: a gate POST stores only the fields sent, and a replay is a duplicate', async (t) => {
  const o = await open(t); if (!o) return;
  const body = { repo: REPO, number: 7, state: 'gate', since: 'd1', ci_green_sha: A };
  const first = await call(o.DB, '/api/pr-state-events', { method: 'POST', body });
  assert.equal(first.status, 201, JSON.stringify(first.body));
  assert.equal(first.body.recorded, true);
  const row = o.db.prepare('SELECT * FROM pr_state_events').get();
  assert.equal(row.state, 'gate');
  assert.equal(row.since, 'd1');
  assert.equal(row.ci_green_sha, A);
  for (const c of NEW_COLS.filter((c) => c !== 'ci_green_sha')) assert.equal(row[c], null, c);
  assert.equal(row.head, null);

  const again = await call(o.DB, '/api/pr-state-events', { method: 'POST', body });
  assert.equal(again.status, 200);
  assert.equal(again.body.duplicate, true);
  assert.equal(o.db.prepare('SELECT COUNT(*) AS n FROM pr_state_events').get().n, 1);
});

test('R3: a conductor-shaped POST is unchanged and sets no gate column', async (t) => {
  const o = await open(t); if (!o) return;
  const r = await call(o.DB, '/api/pr-state-events', {
    method: 'POST', body: { repo: REPO, number: 7, state: 'OPEN', since: 's', head: 'abc1234' },
  });
  assert.equal(r.status, 201);
  const row = o.db.prepare('SELECT * FROM pr_state_events').get();
  assert.equal(row.state, 'OPEN');
  assert.equal(row.head, 'abc1234');
  for (const c of NEW_COLS) assert.equal(row[c] ?? null, null, c);
});

test('R4: a bad sha or a bad 0/1 int is a 400 naming the field, and nothing is written', async (t) => {
  const o = await open(t); if (!o) return;
  const base = { repo: REPO, number: 7, state: 'gate', since: 'x' };
  const cases = [
    [{ ...base, ci_green_sha: 'XYZ' }, 'ci_green_sha'],
    [{ ...base, ci_green_sha: 'abc' }, 'ci_green_sha'],
    [{ ...base, head: 'not-a-sha' }, 'head'],
    [{ ...base, held: 2 }, 'held'],
    [{ ...base, draft: 'yes' }, 'draft'],
    [{ repo: REPO, number: 7, held: 1 }, 'since'],
  ];
  for (const [body, field] of cases) {
    const r = await call(o.DB, '/api/pr-state-events', { method: 'POST', body });
    assert.equal(r.status, 400, `${JSON.stringify(body)} -> ${r.status}`);
    assert.match(r.body.error, new RegExp(field), JSON.stringify(r.body));
  }
  assert.equal(o.db.prepare('SELECT COUNT(*) AS n FROM pr_state_events').get().n, 0);
});

test('R5: GET /api/pr-state/gate folds the facts per PR; no repo is a 400', async (t) => {
  const o = await open(t); if (!o) return;
  await gate(o.DB, 7, { head: A, url: 'https://github.com/o/r/pull/7' });
  await gate(o.DB, 7, { ci_green_sha: A, held: 1 });
  await gate(o.DB, 7, { held: 0 });
  const r = await call(o.DB, `/api/pr-state/gate?repo=${REPO}`);
  assert.equal(r.status, 200);
  assert.ok(r.body.as_of);
  assert.equal(r.body.rows.length, 1);
  const f = r.body.rows[0];
  assert.equal(f.number, 7);
  assert.equal(f.head, A);
  assert.equal(f.ci_green_sha, A);
  assert.equal(f.held, 0);
  assert.equal(f.builder_approved_sha, null);
  assert.equal(f.url, 'https://github.com/o/r/pull/7');
  const none = await call(o.DB, '/api/pr-state/gate');
  assert.equal(none.status, 400);
});

test('R6: a needs-review row carries exactly the contract keys', async (t) => {
  const o = await open(t); if (!o) return;
  await eligible(o.DB, 7);
  const body = await needs(o.DB);
  assert.ok(body.as_of);
  assert.equal(body.rows.length, 1);
  assert.deepEqual(Object.keys(body.rows[0]).sort(),
    ['approved_at', 'head', 'hotfix', 'number', 'nudged', 'repo', 'url'].sort());
  const row = body.rows[0];
  assert.equal(row.repo, REPO);
  assert.equal(row.head, A);
  assert.equal(row.hotfix, 0);
  assert.equal(row.nudged, 0);
  assert.equal(row.url, 'https://github.com/o/r/pull/7');
  assert.ok(row.approved_at);
});

test('R7: the observable outcome — listed, gone after a verdict, back on a new head', async (t) => {
  const o = await open(t); if (!o) return;
  await gate(o.DB, 7, { head: A });
  await gate(o.DB, 7, { ci_green_sha: A });
  await gate(o.DB, 7, { builder_approved_sha: A });
  assert.deepEqual(nums(await needs(o.DB)), [7]);
  await gate(o.DB, 7, { lead_verdict_sha: A, lead_verdict_word: 'MERGE' });
  assert.deepEqual((await needs(o.DB)).rows, []);
  await gate(o.DB, 7, { head: B });
  await gate(o.DB, 7, { ci_green_sha: B });
  await gate(o.DB, 7, { builder_approved_sha: B });
  const back = await needs(o.DB);
  assert.deepEqual(nums(back), [7]);
  assert.equal(back.rows[0].head, B);
});

// ── needs-review eligibility ─────────────────────────────────────────────────
test('N1: draft, held and closed are each excluded; held=1 then held=0 is included', async (t) => {
  const o = await open(t); if (!o) return;
  await eligible(o.DB, 1, A, { draft: 1 });
  await eligible(o.DB, 2, A, { held: 1 });
  await eligible(o.DB, 3, A, { closed: 1 });
  await eligible(o.DB, 4, A, { held: 1 });
  await gate(o.DB, 4, { held: 0 });
  await eligible(o.DB, 5, A, { draft: 0, closed: 0 });
  assert.deepEqual(nums(await needs(o.DB)).sort(), [4, 5]);
});

test('N2: head != approve and head != ci are each excluded', async (t) => {
  const o = await open(t); if (!o) return;
  await gate(o.DB, 1, { head: B, ci_green_sha: B, builder_approved_sha: A });
  await gate(o.DB, 2, { head: B, ci_green_sha: A, builder_approved_sha: B });
  await eligible(o.DB, 3, B);
  assert.deepEqual(nums(await needs(o.DB)), [3]);
});

test('N3/N4: a verdict on the head, or a failed review on the head, excludes', async (t) => {
  const o = await open(t); if (!o) return;
  await eligible(o.DB, 1, A, { lead_verdict_sha: A });
  await eligible(o.DB, 2, A, { review_failed_sha: A });
  // Old-head verdict and failure do not exclude the new head.
  await eligible(o.DB, 3, B, { lead_verdict_sha: A, review_failed_sha: A });
  assert.deepEqual(nums(await needs(o.DB)), [3]);
});

test('N5: head moved after the verdict: off with CI only, back once approve catches up', async (t) => {
  const o = await open(t); if (!o) return;
  await eligible(o.DB, 7, A);
  await gate(o.DB, 7, { lead_verdict_sha: A });
  await gate(o.DB, 7, { head: B, ci_green_sha: B });
  assert.deepEqual(nums(await needs(o.DB)), []);
  await gate(o.DB, 7, { builder_approved_sha: B });
  assert.deepEqual(nums(await needs(o.DB)), [7]);
});

test('N6: no head fact, a conductor head, and another repo are never listed', async (t) => {
  const o = await open(t); if (!o) return;
  await gate(o.DB, 1, { ci_green_sha: A, builder_approved_sha: A });
  // PR 2's head comes only from a conductor (non-gate) row.
  const c = await call(o.DB, '/api/pr-state-events', {
    method: 'POST', body: { repo: REPO, number: 2, state: 'READY', since: 's', head: A },
  });
  assert.equal(c.status, 201);
  await gate(o.DB, 2, { ci_green_sha: A, builder_approved_sha: A });
  // PR 4 has a verdict and a failure but no head, CI or approve fact:
  // null === null must not make it eligible.
  await gate(o.DB, 4, { held: 0, lead_verdict_sha: A, review_failed_sha: B });
  await eligible(o.DB, 3, A, {}, { repo: 'o/other' });
  assert.deepEqual(nums(await needs(o.DB)), []);
  assert.deepEqual(nums(await needs(o.DB, 'repo=o/other')), [3]);
});

test('N7: order is nudged, then hotfix, then oldest approval, then number; limit slices', async (t) => {
  const o = await open(t); if (!o) return;
  await ensureColumns({ DB: o.DB }, 'pr_state_events');
  const ins = o.db.prepare(
    `INSERT INTO pr_state_events (repo, number, state, since, alerted, at, reason, head, ci_green_sha,
       builder_approved_sha, hotfix, nudged_sha)
     VALUES (?, ?, 'gate', ?, '-', ?, 'test', ?, ?, ?, ?, ?)`);
  const seed = (n, at, { hotfix = null, nudged = null } = {}) =>
    ins.run(REPO, n, `s${n}`, at, A, A, A, hotfix, nudged);
  seed(70, '2026-10-01T00:00:00Z');                       // A: plain, earliest (highest number)
  seed(20, '2026-10-05T00:00:00Z', { hotfix: 1 });         // B: hotfix
  seed(30, '2026-10-06T00:00:00Z', { nudged: A });         // C: nudged on head
  seed(50, '2026-10-03T00:00:00Z');                       // D: plain, later
  seed(40, '2026-10-03T00:00:00Z');                       // E: same at as D, lower number
  // A nudge on an OLD sha is not a nudge.
  seed(60, '2026-10-04T00:00:00Z', { nudged: B });
  assert.deepEqual(nums(await needs(o.DB)), [30, 20, 70, 40, 50, 60]);
  const two = await needs(o.DB, `repo=${REPO}&limit=2`);
  assert.deepEqual(nums(two), [30, 20]);
  assert.equal(two.rows[0].nudged, 1);
  assert.equal(two.rows[1].hotfix, 1);
  assert.equal(two.rows[0].approved_at, '2026-10-06T00:00:00Z');
  const bad = await call(o.DB, `/api/pr-state/needs-review?repo=${REPO}&limit=abc`);
  assert.equal(bad.status, 400);
});

test('N7b: approved_at is the FIRST event that set the current approve sha', async (t) => {
  const o = await open(t); if (!o) return;
  await ensureColumns({ DB: o.DB }, 'pr_state_events');
  const ins = o.db.prepare(
    `INSERT INTO pr_state_events (repo, number, state, since, alerted, at, reason, head, ci_green_sha, builder_approved_sha)
     VALUES (?, ?, 'gate', ?, '-', ?, 'test', ?, ?, ?)`);
  ins.run(REPO, 1, 'a', '2026-10-01T00:00:00Z', null, null, B);   // an older approve on another sha
  ins.run(REPO, 1, 'b', '2026-10-02T00:00:00Z', A, A, A);
  ins.run(REPO, 1, 'c', '2026-10-04T00:00:00Z', null, null, A);   // reconcile re-send of the same approve
  ins.run(REPO, 2, 'd', '2026-10-03T00:00:00Z', A, A, A);
  const body = await needs(o.DB);
  assert.deepEqual(nums(body), [1, 2]);
  assert.equal(body.rows[0].approved_at, '2026-10-02T00:00:00Z');
});

test('N8: a newer event carrying only held=0 does not blank ci_green_sha', async (t) => {
  const o = await open(t); if (!o) return;
  await eligible(o.DB, 7, A);
  await gate(o.DB, 7, { held: 0 });
  assert.deepEqual(nums(await needs(o.DB)), [7]);
  const f = (await call(o.DB, `/api/pr-state/gate?repo=${REPO}`)).body.rows[0];
  assert.equal(f.ci_green_sha, A);
});

test('N9: an empty repo is a 200 with rows: [], never a 404', async (t) => {
  const o = await open(t); if (!o) return;
  const r = await call(o.DB, `/api/pr-state/needs-review?repo=${REPO}`);
  assert.equal(r.status, 200);
  assert.deepEqual(r.body.rows, []);
  const none = await call(o.DB, '/api/pr-state/needs-review');
  assert.equal(none.status, 400);
});

// ── The current-state readers stay gate-blind ───────────────────────────────
test('V1: a gate row does not become the PR\'s current state on GET /api/pr-state', async (t) => {
  const o = await open(t); if (!o) return;
  const b = await call(o.DB, '/api/pr-state-events', {
    method: 'POST', body: { repo: REPO, number: 9, state: 'BLOCKED_HUMAN', since: '2026-10-01T00:00:00Z' },
  });
  assert.equal(b.status, 201);
  await eligible(o.DB, 9, A);
  await eligible(o.DB, 11, A);   // a PR with ONLY gate rows has no current state
  const r = await call(o.DB, `/api/pr-state?repo=${REPO}`);
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.deepEqual(r.body.rows.map((x) => [x.number, x.state]), [[9, 'BLOCKED_HUMAN']]);
});

test('V2: the daily digest still lists a BLOCKED_HUMAN PR after a gate row', async (t) => {
  const o = await open(t); if (!o) return;
  const ANCHOR = Date.now();  // determinism: ok the digest route reads yesterday from its own clock
  const day = new Date(ANCHOR - 24 * 3600e3).toISOString().slice(0, 10);
  const since = `${day}T01:00:00Z`;
  o.db.prepare(`INSERT INTO pr_state_events (repo, number, state, since, reason, at) VALUES (?, ?, ?, ?, ?, ?)`)
    .run(REPO, 9, 'BLOCKED_HUMAN', since, 'needs a human', since);
  await eligible(o.DB, 9, A);
  const res = await worker.fetch(
    new Request(`https://jobs.test/api/metrics/daily-digest?day=${day}`, { headers: { authorization: `Bearer ${SECRET}` } }),
    { DB: o.DB, HARNESS_SECRET: SECRET },
  );
  const d = await res.json();
  assert.equal(res.status, 200, JSON.stringify(d));
  assert.ok(d.holds.rows.some((r) => r.source === 'BLOCKED_HUMAN' && r.key === '#9'), JSON.stringify(d.holds));
  assert.deepEqual(d.human_verdict_prs.rows.map((r) => r.number), [9]);
});
