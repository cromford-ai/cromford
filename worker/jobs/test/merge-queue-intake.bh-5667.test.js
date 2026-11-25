// BH-5667 (BH-5008 child 1): live merge-queue intake and GET /api/merge-queue/live.
// Every delivery goes through the REAL worker.fetch, signed, onto the REAL
// schema.sql in node:sqlite, so the assertions are on rows, not on SQL text.
// env.DB.batch is wrapped in BEGIN/COMMIT/ROLLBACK here, because D1's batch is
// one transaction and the shim's is not.
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import { wakeOf } from '../src/lib/core.js';
import {
  REPO, SECRET, DRAFT, MEMBERS, BASE_SHA, deliveries, negatives, sendDelivery,
  prDelivery, checkDelivery, suiteDelivery, CHECK_NAMES,
} from './fixtures/merge-queue-bh-5008.js';
import { isMergeQueueRef, mapMergeQueueDelivery } from '../src/lib/merge-queue-intake.js';
import { jobClass, queueStageStmt, QUEUE_STAGES } from '../src/lib/merge-queue-stage.js';
import { medianStatements } from '../src/lib/merge-queue-intake-medians.js';
import { stageStatements } from '../src/lib/merge-queue-intake-stages.js';
import { applyProgress } from '../src/lib/merge-queue-live-progress.js';
import { applyStages } from '../src/lib/merge-queue-live-stages.js';
import { routes as reconcileRoutes } from '../src/routes/merge-queue-reconcile.js';

const TABLES = ['merge_queue_batches', 'merge_queue_checks', 'merge_queue_check_medians'];
const SETTING_AT = '2026-10-09T00:00:00Z';

function txBatch(db, DB) {
  return async (stmts) => {
    db.exec('BEGIN');
    try {
      const out = [];
      for (const s of stmts) out.push(await s.run());
      db.exec('COMMIT');
      return out;
    } catch (e) {
      db.exec('ROLLBACK');
      throw e;
    }
  };
}

async function setup(t, { settings = { merge_queue_repos: REPO }, projects = [], hooks = {} } = {}) {
  const o = await openDb(hooks);
  if (!o) { t.skip('node:sqlite unavailable'); return null; }
  o.DB.batch = txBatch(o.db, o.DB);
  for (const [k, v] of Object.entries(settings)) {
    o.db.prepare(`INSERT OR REPLACE INTO settings (key,value,note,actor,updated_at) VALUES (?,?,?,?,?)`)
      .run(k, v, 'test', 'test', SETTING_AT);
  }
  for (const [project, repo] of projects) {
    o.db.prepare(`INSERT INTO projects (project, repo, cron_offset, created_at, updated_at) VALUES (?,?,0,?,?)`)
      .run(project, repo, SETTING_AT, SETTING_AT);
  }
  const env = { DB: o.DB, HARNESS_SECRET: 'bearer', GITHUB_WEBHOOK_SECRET: SECRET };
  const count = (table, where = '') => o.db.prepare(`SELECT COUNT(*) AS n FROM ${table} ${where}`).get().n;
  const dump = () => Object.fromEntries(TABLES.map((tb) => [tb,
    o.db.prepare(`SELECT * FROM ${tb} ORDER BY 1,2,3`).all().map((r) => ({ ...r }))]));
  const get = async (path) => {
    const res = await worker.fetch(new Request(`https://jobs.test${path}`, { headers: { authorization: 'Bearer bearer' } }), env);
    return { status: res.status, headers: res.headers, body: await res.json().catch(() => null) };
  };
  return { ...o, env, count, dump, get };
}

async function sendAll(ctx, list = deliveries, opts = {}) {
  const out = [];
  for (const d of list) out.push(await sendDelivery(worker, ctx.env, d, opts.fresh ? { id: `${d.id}-again` } : {}));
  return out;
}

function stubFetch() {
  const real = globalThis.fetch;
  const calls = [];
  globalThis.fetch = async (...a) => { calls.push(a); throw new Error('no network in this test'); };
  return { calls, restore: () => { globalThis.fetch = real; } };
}

// ── 1. the fixture becomes rows ─────────────────────────────────────────────
test('1 fixture deliveries give 1 batch with 3 members and 14 check rows, 10 completed, 1 failure', async (t) => {
  const c = await setup(t); if (!c) return;
  const res = await sendAll(c);
  assert.deepEqual(res.map((r) => r.status), deliveries.map(() => 200), 'every positive delivery answers 200');
  const b = c.db.prepare(`SELECT * FROM merge_queue_batches WHERE repo=? AND draft_pr=?`).get(REPO, DRAFT);
  assert.ok(b, 'batch row for the draft');
  assert.deepEqual(JSON.parse(b.members_json), MEMBERS);
  assert.equal(b.base_sha, BASE_SHA);
  assert.equal(b.started_at, '2026-10-09T03:00:00Z');
  assert.equal(b.finished_at, null);
  assert.equal(b.outcome, null);
  assert.equal(b.bisect_parent, null);
  const b2 = c.db.prepare(`SELECT members_json FROM merge_queue_batches WHERE draft_pr=9002`).get();
  assert.deepEqual(JSON.parse(b2.members_json), [101, 102]);
  const checks = c.db.prepare(`SELECT * FROM merge_queue_checks WHERE draft_pr=? ORDER BY name`).all(DRAFT);
  assert.equal(checks.length, 14);
  assert.equal(checks.filter((r) => r.status === 'completed').length, 10);
  assert.deepEqual(checks.filter((r) => r.conclusion === 'failure').map((r) => r.name), ['Jobs worker']);
  const byName = Object.fromEntries(checks.map((r) => [r.name, r]));
  assert.equal(byName['tests (3)'].job_class, 'tests');
  assert.equal(byName['bash -n'].job_class, 'bash -n');
  assert.ok(byName.lint.url.startsWith(`https://github.com/${REPO}/actions/`));
  assert.equal(byName.lint.finished_at, '2026-10-09T03:09:00Z');
  assert.equal(byName['tests (8)'].finished_at, null);
  // BH-5668 (child 2) fills the medians: one row per green completion's name
  // (9 of the 10 completed; the failed `Jobs worker` writes none).
  assert.equal(c.count('merge_queue_check_medians'), 9);
  assert.equal(c.count('merge_queue_check_medians', `WHERE name='Jobs worker'`), 0);
  // BH-5669 (child 3) fills the stage seam: batched + checking for 9001's 3
  // members, batched for 9002's 2. Child 3's own suite pins each row.
  assert.equal(c.count('pr_state_events', `WHERE state='queue'`), 8, 'stage rows from child 3');
});

// ── 2/3. redelivery is idempotent ───────────────────────────────────────────
test('2 same deliveries twice (same ids) give identical rows, answered as duplicates', async (t) => {
  const c = await setup(t); if (!c) return;
  await sendAll(c);
  const first = c.dump();
  const again = await sendAll(c);
  assert.deepEqual(c.dump(), first);
  assert.ok(again.every((r) => r.status === 200 && r.body.duplicate === true), 'each replay is a duplicate');
});

test('3 the same payloads under NEW delivery ids give the same rows (PK upserts)', async (t) => {
  const c = await setup(t); if (!c) return;
  await sendAll(c);
  const first = c.dump();
  await sendAll(c, deliveries, { fresh: true });
  assert.deepEqual(c.dump(), first);
});

// ── 4. out-of-order created after completed ─────────────────────────────────
test('4 check_run.created after completed for the same name keeps completed', async (t) => {
  const c = await setup(t); if (!c) return;
  await sendDelivery(worker, c.env, checkDelivery('o-1', { name: 'lint', action: 'completed', status: 'completed', conclusion: 'success' }));
  await sendDelivery(worker, c.env, checkDelivery('o-2', { name: 'lint', action: 'created' }));
  const r = c.db.prepare(`SELECT status, conclusion, finished_at FROM merge_queue_checks WHERE name='lint'`).get();
  assert.deepEqual({ ...r }, { status: 'completed', conclusion: 'success', finished_at: '2026-10-09T03:09:00Z' });
});

// ── 5. closed outcomes ──────────────────────────────────────────────────────
test('5 closed: merged only when merged===true; failed with a failed check; else closed', async (t) => {
  const c = await setup(t); if (!c) return;
  const closedAt = '2026-10-09T03:20:00Z';
  // 9001 has a failing check row.
  await sendAll(c);
  await sendDelivery(worker, c.env, prDelivery('cl-1', { action: 'closed', closed_at: closedAt }));
  // 9002 has no check rows.
  await sendDelivery(worker, c.env, prDelivery('cl-2', { action: 'closed', number: 9002, ref: 'mergify/merge-queue/x-9002', closed_at: closedAt }));
  // 9003: merged === true.
  await sendDelivery(worker, c.env, prDelivery('cl-3', { action: 'closed', number: 9003, ref: 'mergify/merge-queue/x-9003', merged: true, closed_at: closedAt }));
  // 9004: merged is the STRING "true", which is not a merge.
  await sendDelivery(worker, c.env, prDelivery('cl-4', { action: 'closed', number: 9004, ref: 'mergify/merge-queue/x-9004', merged: 'true', closed_at: closedAt }));
  const out = Object.fromEntries(c.db.prepare(`SELECT draft_pr, outcome, finished_at FROM merge_queue_batches`).all()
    .map((r) => [r.draft_pr, [r.outcome, r.finished_at]]));
  assert.deepEqual(out[9001], ['failed', closedAt]);
  assert.deepEqual(out[9002], ['closed', closedAt]);
  assert.deepEqual(out[9003], ['merged', closedAt]);
  assert.deepEqual(out[9004], ['closed', closedAt]);
  // A late synchronize and a second close cannot reopen or rewrite a finished batch.
  const before = c.dump();
  await sendDelivery(worker, c.env, prDelivery('cl-5', { action: 'synchronize', body: 'Branch and [#555] are embarked' }));
  await sendDelivery(worker, c.env, prDelivery('cl-6', { action: 'closed', merged: true, closed_at: '2026-10-09T04:00:00Z' }));
  assert.deepEqual(c.dump(), before);
});

// ── 6. adversarial negatives ────────────────────────────────────────────────
for (const neg of negatives) {
  test(`6 negative: ${neg.name} writes 0 merge-queue rows`, async (t) => {
    const c = await setup(t); if (!c) return;
    const r = await sendDelivery(worker, c.env, neg);
    assert.ok([200, 202].includes(r.status), `answered ${r.status}`);
    for (const tb of TABLES) assert.equal(c.count(tb), 0, `${tb} has rows`);
    assert.equal(c.count('pr_state_events', `WHERE state='queue'`), 0);
    assert.equal(r.body.queue, undefined, 'no queue key on the answer');
  });
}

test('6 negative: labeled queued still records its wake, as before BH-5667', async (t) => {
  const c = await setup(t); if (!c) return;
  const neg = negatives.find((n) => n.name.includes('labeled'));
  const r = await sendDelivery(worker, c.env, neg);
  assert.equal(r.status, 200);
  assert.deepEqual(r.body.wake && [r.body.wake.kind, r.body.wake.key], ['pr', '101']);
});

test('6 isMergeQueueRef accepts only mergify/merge-queue/<suffix>', () => {
  for (const ok of ['mergify/merge-queue/abc', 'refs/heads/mergify/merge-queue/7d3a-1', 'mergify/merge-queue/main/pr-1']) {
    assert.equal(isMergeQueueRef(ok), true, ok);
  }
  for (const no of ['mergify/merge-queue', 'mergify/merge-queue/', 'ticket/mergify/merge-queue-x', 'mergify/merge-queue-x/1',
    'refs/tags/mergify/merge-queue/1', '', null, undefined, 'mergify/merge-queue/a b']) {
    assert.equal(isMergeQueueRef(no), false, String(no));
  }
});

test('6 an unarmed repo writes nothing; a projects row arms it', async (t) => {
  const bare = await setup(t, { settings: {} }); if (!bare) return;
  await sendAll(bare);
  for (const tb of TABLES) assert.equal(bare.count(tb), 0, `${tb} written for an unarmed repo`);
  const armed = await setup(t, { settings: {}, projects: [['example', REPO.toLowerCase()]] }); if (!armed) return;
  await sendAll(armed);
  assert.equal(armed.count('merge_queue_batches'), 2);
});

test('6 check_run on an MQ ref with no matching pull_requests entry writes no row', async (t) => {
  const c = await setup(t); if (!c) return;
  await sendDelivery(worker, c.env, checkDelivery('np-1', { noPrs: true }));
  await sendDelivery(worker, c.env, checkDelivery('np-2', { prRef: 'mergify/merge-queue/other' }));
  assert.equal(c.count('merge_queue_checks'), 0);
});

// ── 7. wakeOf is unchanged ──────────────────────────────────────────────────
test('7 wakeOf output for every fixture delivery is the pre-BH-5667 value', () => {
  const sha = '2222222222222222222222222222222222222222';
  const want = [
    { kind: 'pr', key: '9001' },
    ...CHECK_NAMES.map(() => null),
    ...CHECK_NAMES.slice(0, 10).map(() => ({ kind: 'checks', key: sha })),
    { kind: 'pr', key: '9002' },
  ];
  assert.deepEqual(deliveries.map((d) => wakeOf(d.event, d.payload)), want);
});

test('7 a check_run.created on an MQ ref is 200 with queue rows and no wake; on a ticket branch it is 202 ignored', async (t) => {
  const c = await setup(t); if (!c) return;
  const r = await sendDelivery(worker, c.env, checkDelivery('w-1', { name: 'lint' }));
  assert.equal(r.status, 200);
  assert.deepEqual(r.body.queue, { rows: 1 });
  assert.equal(r.body.wake, undefined);
  assert.equal(c.count('wakes'), 0);
  assert.equal(c.count('webhook_deliveries', `WHERE delivery_id='w-1'`), 1);
  const n = await sendDelivery(worker, c.env, checkDelivery('w-2', { name: 'lint', ref: 'ticket/bh-101', draft: 101 }));
  assert.equal(n.status, 202);
  assert.equal(n.body.ignored, 'check_run');
  assert.equal(c.count('merge_queue_checks'), 1);
  // A wake-bearing MQ delivery carries both.
  const o = await sendDelivery(worker, c.env, prDelivery('w-3'));
  assert.equal(o.status, 200);
  assert.deepEqual([o.body.wake.kind, o.body.wake.key], ['pr', '9001']);
  // The batch row, plus child 3's batched (#9001) row for each of the 3 members.
  assert.deepEqual(o.body.queue, { rows: 4 });
  // check_suite.completed: a wake, no check row (A5).
  const s = await sendDelivery(worker, c.env, suiteDelivery('w-4'));
  assert.equal(s.status, 200);
  assert.equal(s.body.queue, undefined);
  assert.equal(c.count('merge_queue_checks'), 1);
});

test('7 a queue-bearing delivery without a delivery id still writes its rows', async (t) => {
  const c = await setup(t); if (!c) return;
  const r = await sendDelivery(worker, c.env, checkDelivery('x', { name: 'lint' }), { noId: true });
  assert.equal(r.status, 200);
  assert.deepEqual(r.body.queue, { rows: 1 });
  assert.equal(c.count('merge_queue_checks'), 1);
  assert.equal(c.count('webhook_deliveries'), 0);
});

// ── 8. stage rows never move the conductor's state ──────────────────────────
test('8 a queue stage row does not change GET /api/pr-state; it is idempotent; an unknown stage throws', async (t) => {
  const c = await setup(t); if (!c) return;
  const post = await worker.fetch(new Request('https://jobs.test/api/pr-state-events', {
    method: 'POST', headers: { authorization: 'Bearer bearer', 'content-type': 'application/json' },
    body: JSON.stringify({ repo: REPO, number: 101, state: 'open', since: '2026-10-09T01:00:00Z', actor: 'conductor' }),
  }), c.env);
  assert.equal(post.status, 201);
  const before = await c.get(`/api/pr-state?repo=${encodeURIComponent(REPO)}`);
  assert.equal(before.status, 200);
  const stmt = queueStageStmt(c.DB, { repo: REPO, pr: 101, stage: 'checking (3/14)', since: '2026-10-09T03:05:00Z', actor: 'test' });
  await c.DB.batch([stmt]);
  await c.DB.batch([queueStageStmt(c.DB, { repo: REPO, pr: 101, stage: 'checking (3/14)', since: '2026-10-09T03:05:00Z', actor: 'test' })]);
  assert.equal(c.count('pr_state_events', `WHERE state='queue'`), 1, 'the same stage row twice is one row');
  const q = c.db.prepare(`SELECT reason, alerted FROM pr_state_events WHERE state='queue'`).get();
  assert.deepEqual({ ...q }, { reason: 'checking (3/14)', alerted: '-' });
  const after = await c.get(`/api/pr-state?repo=${encodeURIComponent(REPO)}`);
  assert.deepEqual(after.body.rows, before.body.rows);
  // The event log still lists it, and not_state=queue hides it.
  const all = await c.get('/api/pr-state-events?limit=1');
  assert.equal(all.body.rows[0].state, 'queue');
  const ticks = await c.get('/api/pr-state-events?limit=1&not_state=queue');
  assert.equal(ticks.body.rows[0].state, 'open');
  const bad = await c.get('/api/pr-state-events?limit=1&not_state=Queue;--');
  assert.equal(bad.status, 400);
  for (const stage of ['queue-ejected', 'queue-ejected (ci)', 'merged-ish', '', 'Checking']) {
    assert.throws(() => queueStageStmt(c.DB, { repo: REPO, pr: 101, stage, since: 'x' }), /stage/, stage);
  }
  assert.throws(() => queueStageStmt(c.DB, { repo: 'not a slug', pr: 1, stage: 'queued', since: 'x' }), /repo/);
  assert.throws(() => queueStageStmt(c.DB, { repo: REPO, pr: 0, stage: 'queued', since: 'x' }), /pr/);
  assert.ok(QUEUE_STAGES.includes('deploy_verified') && QUEUE_STAGES.length === 12);
});

test('8 the digest current-state read skips queue rows', async (t) => {
  const c = await setup(t); if (!c) return;
  const ins = c.db.prepare(`INSERT INTO pr_state_events (repo, number, state, since, alerted, at, actor) VALUES (?,?,?,?,?,?,?)`);
  ins.run(REPO, 101, 'BLOCKED_HUMAN', '2026-10-09T01:00:00Z', '-', '2026-10-09T01:00:00Z', 'conductor');
  await c.DB.batch([queueStageStmt(c.DB, { repo: REPO, pr: 101, stage: 'queued', since: '2026-10-09T02:00:00Z', at: '2026-10-09T02:00:00Z' })]);
  const { PR_STATE_NO_GATE } = await import('../src/lib/daily-digest/state-sections.js');
  const rows = c.db.prepare(`SELECT number, state FROM ${PR_STATE_NO_GATE}`).all();
  assert.deepEqual(rows.map((r) => [r.number, r.state]), [[101, 'BLOCKED_HUMAN']]);
});

test('8 jobClass strips one suffix', () => {
  assert.equal(jobClass('test (3)'), 'test');
  assert.equal(jobClass('shard 2'), 'shard');
  assert.equal(jobClass('lint/1'), 'lint');
  assert.equal(jobClass('build'), 'build');
  assert.equal(jobClass('  tests (1) (2)  '), 'tests (1)');
  assert.equal(jobClass('(3)'), '(3)');
  assert.equal(jobClass('7'), '7');
});

// ── 9. the observable outcome ───────────────────────────────────────────────
test('9 observable outcome: GET /api/merge-queue/live returns the batch from D1 rows only', async (t) => {
  const c = await setup(t); if (!c) return;
  const f = stubFetch();
  try {
    await sendAll(c);
    const r = await c.get('/api/merge-queue/live');
    assert.equal(r.status, 200);
    assert.equal(r.headers.get('cache-control'), 'max-age=4');
    assert.equal(r.body.complete, true);
    assert.deepEqual(r.body.waiting, []);
    // Child 3 fills prs from the stage rows the intake wrote.
    assert.deepEqual(Object.keys(r.body.prs).sort(), MEMBERS.map((n) => `${REPO}#${n}`));
    assert.equal(typeof r.body.as_of, 'string');
    const drafts = r.body.batches.map((b) => b.draft).sort();
    assert.deepEqual(drafts, [9001, 9002]);
    const b = r.body.batches.find((x) => x.draft === DRAFT);
    assert.deepEqual(b, {
      repo: REPO, draft: DRAFT, url: `https://github.com/${REPO}/pull/${DRAFT}`, members: MEMBERS,
      // Child 3: a failed check makes an open batch `failing`, and names it.
      base_sha: BASE_SHA, stage: 'failing', checks: { done: 10, total: 14 },
      // BH-5668 (child 2): every check weighs 480 s (its own median, the
      // `tests` class median, or the equal share for the failed check), and
      // every open check started at 03:01, more than 480 s ago.
      progress: 0.714, eta_s: 0, eta_basis: 'class',
      failing: { name: 'Jobs worker', url: `https://github.com/${REPO}/actions/runs/7001/job/${8000 + DRAFT}` },
      bisect: null, outcome: null,
    });
    const b2 = r.body.batches.find((x) => x.draft === 9002);
    assert.deepEqual(b2.checks, { done: 0, total: 0 });
    assert.deepEqual([b2.progress, b2.eta_s, b2.eta_basis], [0, null, 'partial']);
    assert.equal(f.calls.length, 0, 'intake and read made no network call');
  } finally { f.restore(); }
});

test('9 the live route needs the bearer, and an empty queue is an empty list', async (t) => {
  const c = await setup(t); if (!c) return;
  const res = await worker.fetch(new Request('https://jobs.test/api/merge-queue/live'), c.env);
  assert.equal(res.status, 401);
  const r = await c.get('/api/merge-queue/live');
  assert.equal(r.status, 200);
  assert.deepEqual(r.body.batches, []);
  assert.equal(r.body.complete, true);
});

// ── 10. the window ──────────────────────────────────────────────────────────
test('10 a batch finished before the window is absent; a wider window setting shows it', async (t) => {
  const c = await setup(t); if (!c) return;
  await sendAll(c);
  const old = new Date(Date.now() - 901 * 1000).toISOString().replace(/\.\d{3}Z$/, 'Z'); // determinism: ok the window is relative to the route's own clock
  c.db.prepare(`UPDATE merge_queue_batches SET finished_at=?, outcome='closed' WHERE draft_pr=9002`).run(old);
  let r = await c.get('/api/merge-queue/live');
  assert.deepEqual(r.body.batches.map((b) => b.draft), [DRAFT]);
  assert.equal(r.body.window_s, 900);
  assert.equal(r.body.window_source, 'default');
  c.db.prepare(`INSERT OR REPLACE INTO settings (key,value,note,actor,updated_at) VALUES ('merge_queue_live_window_s','2000','t','t',?)`).run(SETTING_AT);
  r = await c.get('/api/merge-queue/live');
  assert.deepEqual(r.body.batches.map((b) => b.draft).sort(), [9001, 9002]);
  assert.equal(r.body.window_s, 2000);
  assert.equal(r.body.window_source, 'setting');
  c.db.prepare(`UPDATE settings SET value='-5' WHERE key='merge_queue_live_window_s'`).run();
  r = await c.get('/api/merge-queue/live');
  assert.equal(r.body.window_s, 900);
  assert.equal(r.body.window_source, 'default');
});

test('10 over 50 batches is complete:false', async (t) => {
  const c = await setup(t); if (!c) return;
  const ins = c.db.prepare(`INSERT INTO merge_queue_batches (repo, draft_pr, started_at, updated_at) VALUES (?,?,?,?)`);
  for (let i = 1; i <= 51; i++) ins.run(REPO, 10000 + i, `2026-10-09T03:${String(i % 60).padStart(2, '0')}:00Z`, SETTING_AT);
  const r = await c.get('/api/merge-queue/live');
  assert.equal(r.body.batches.length, 50);
  assert.equal(r.body.complete, false);
});

// ── 11. project filter ──────────────────────────────────────────────────────
test('11 ?project=nope is 404; a project name or a repo slug filters', async (t) => {
  const c = await setup(t, { projects: [['example', REPO]] }); if (!c) return;
  await sendAll(c);
  const other = prDelivery('p-1', { repo: 'Example-Org/other-repo', number: 9100, ref: 'mergify/merge-queue/x-9100' });
  c.db.prepare(`UPDATE settings SET value=? WHERE key='merge_queue_repos'`).run(`${REPO}, Example-Org/other-repo`);
  assert.equal((await sendDelivery(worker, c.env, other)).status, 200);
  assert.equal((await c.get('/api/merge-queue/live?project=nope')).status, 404);
  const byName = await c.get('/api/merge-queue/live?project=example');
  assert.deepEqual(byName.body.batches.map((b) => b.draft).sort(), [9001, 9002]);
  const bySlug = await c.get(`/api/merge-queue/live?project=${encodeURIComponent('Example-Org/other-repo')}`);
  assert.deepEqual(bySlug.body.batches.map((b) => b.draft), [9100]);
  const all = await c.get('/api/merge-queue/live');
  assert.equal(all.body.batches.length, 3);
});

// ── 12. atomicity ───────────────────────────────────────────────────────────
// BH-9934: a throw after the signature check is a dead letter: 200 and one
// `github:dead` row, so GitHub does not redeliver in a loop. The batch still
// commits nothing: no `github` delivery row, no queue row, no wake.
test('12 a failing queue statement is a dead letter (200) and commits no delivery row', async (t) => {
  const c = await setup(t); if (!c) return;
  const real = c.DB.batch;
  c.DB.batch = async (stmts) => real([...stmts.slice(0, -1), { run: async () => { throw new Error('boom'); } }]);
  for (const d of [checkDelivery('at-1', { name: 'lint' }), prDelivery('at-2')]) {
    const r = await sendDelivery(worker, c.env, d);
    assert.equal(r.status, 200, d.id);
    assert.equal(r.body.dead_letter, true, d.id);
    assert.equal(c.count('webhook_deliveries', `WHERE vendor='github' AND delivery_id='${d.id}'`), 0);
    assert.equal(c.count('webhook_deliveries', `WHERE vendor='github:dead' AND delivery_id='${d.id}'`), 1);
  }
  assert.equal(c.count('wakes'), 0);
  for (const tb of TABLES) assert.equal(c.count(tb), 0);
  // GitHub redelivers the same id once the fault is gone, and it lands.
  c.DB.batch = real;
  assert.equal((await sendDelivery(worker, c.env, checkDelivery('at-1', { name: 'lint' }))).status, 200);
  assert.equal(c.count('merge_queue_checks'), 1);
});

test('12 the queue INSERT failing rolls back the delivery row with it (one batch, delivery first; BH-9934 dead letter)', async (t) => {
  let fail = true;
  const hooks = { beforeRun(sql) { if (fail && /INSERT INTO merge_queue_(checks|batches)/.test(sql)) throw new Error('disk I/O error'); } };
  const c = await setup(t, { hooks }); if (!c) return;
  for (const d of [checkDelivery('ab-1', { name: 'lint' }), prDelivery('ab-2')]) {
    const r = await sendDelivery(worker, c.env, d);
    assert.equal(r.status, 200, d.id);
    assert.equal(r.body.dead_letter, true, d.id);
    assert.equal(c.count('webhook_deliveries', `WHERE vendor='github' AND delivery_id='${d.id}'`), 0, `${d.id}: delivery committed without its rows`);
    assert.equal(c.count('webhook_deliveries', `WHERE vendor='github:dead' AND delivery_id='${d.id}'`), 1, `${d.id}: no dead letter`);
  }
  assert.equal(c.count('wakes'), 0);
  fail = false;
  assert.equal((await sendDelivery(worker, c.env, checkDelivery('ab-1', { name: 'lint' }))).status, 200);
  assert.equal(c.count('merge_queue_checks'), 1);
});

test('12 a mapper read that throws (schema not applied) is a dead letter (200) with no other rows', async (t) => {
  const c = await setup(t); if (!c) return;
  c.db.exec('DROP TABLE merge_queue_checks');
  const r = await sendDelivery(worker, c.env, checkDelivery('ns-1', { name: 'lint' }));
  assert.equal(r.status, 200);
  assert.equal(r.body.dead_letter, true);
  assert.equal(c.count('webhook_deliveries', "WHERE vendor='github'"), 0);
  assert.equal(c.count('webhook_deliveries', "WHERE vendor='github:dead' AND delivery_id='ns-1'"), 1);
  c.db.exec('DROP TABLE merge_queue_batches');
  const live = await c.get('/api/merge-queue/live');
  assert.equal(live.status, 503);
  assert.match(live.body.error, /schema not applied/);
});

// ── seams (T4) ──────────────────────────────────────────────────────────────
test('seams: the stub seams are working no-ops with the contract names', async (t) => {
  const c = await setup(t); if (!c) return;
  assert.deepEqual(await medianStatements(c.DB, { repo: REPO }), []);
  assert.deepEqual(await stageStatements(c.DB, 'check_run', {}, {}), []);
  const p = { batches: [], waiting: [], prs: {} };
  assert.equal(await applyProgress(c.env, p), p);
  assert.equal(await applyStages(c.env, p), p);
  assert.deepEqual(reconcileRoutes.map(([m, path]) => `${m} ${path}`), ['GET /api/merge-queue/reconcile', 'POST /api/merge-queue/reconcile']);
  assert.equal(await mapMergeQueueDelivery(c.DB, 'push', {}, { repo: REPO, at: SETTING_AT }), null);
});
