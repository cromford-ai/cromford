// BH-9154 (Fix 5 of BH-9066): the daily review counter. GET /api/review-counts
// and POST /api/review-counts/rollup over review_counts_daily, driven through
// the REAL worker.fetch on node:sqlite with the composed jobs schema
// (worker/jobs/schema.d/). Every seeded time is an offset from one anchor.
//
//   C1  a rollup counts one cost_rows row per model call, by kind through the
//       review_counts.kind_map row; refused calls (rc 74..79), non-review
//       stages and rows older than the rollup window are not counted
//   C2  the 7 kinds come back in order; a kind with no rule is null, never 0
//   C3  merged PRs come from the merge ledger (repo -> project through the
//       projects table), rebinds from review-saving REUSED events only
//   C4  wrong project = 0 rows
//   C5  no bearer = 401 on GET and POST
//   C6  GET rolls up by itself when the last rollup is older than
//       review_counts.rollup_every_s, and not again inside that window
//   C7  a rollup rewrites only the last review_counts.rollup_days days
//   C8  the kind map is the settings row: a changed row moves the count
//   C9  days over review_counts.max_days (or not a whole number) is 400
//   C10 EXPLAIN QUERY PLAN at 10,000 seeded cost rows: no read the GET and the
//       rollup run scans cost_rows, ledgers, stage_events or review_counts_daily
//   C11 retention: the review_counts_daily.archive rule is off in the seed; set
//       on, it moves an old row to the archive D1 and deletes it from hot; a
//       dry run deletes nothing; its id read uses the primary key
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { openDb, d1 } from './lib/d1-sqlite.bh-1030.js';
import { capturingD1, plan, fullScans } from './lib/d1-volume.bh-6727.js';

const SECRET = 'tok-fixture-bh9154';
const NOW = Date.now();  // determinism: ok the single anchor; every seeded time is an offset from it
const ago = (secs) => new Date(NOW - secs * 1000).toISOString().replace(/\.\d{3}Z$/, 'Z');
const dayOf = (iso) => iso.slice(0, 10);
const KINDS = ['lens', 'fix-rereview', 'lead', 'conductor', 'autopilot', 'rescue', 'resolver'];

async function fresh(t) {
  const o = await openDb();
  if (!o) { t.skip('node:sqlite unavailable'); return null; }
  return o;
}
function call(DB, path, { method = 'GET', body, bearer = true, env = {} } = {}) {
  return worker.fetch(new Request(`https://jobs.test${path}`, {
    method,
    headers: { ...(bearer ? { authorization: `Bearer ${SECRET}` } : {}), 'content-type': 'application/json' },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
  }), { DB, HARNESS_SECRET: SECRET, ...env }).then(async (res) => ({ status: res.status, body: await res.json().catch(() => null) }));
}
function setting(db, key, value) {
  db.prepare(`INSERT INTO settings (key,value,note,actor,updated_at) VALUES (?,?,'',?,?)
              ON CONFLICT(key) DO UPDATE SET value=excluded.value`).run(key, String(value), 'test', ago(0));
}
let seq = 0;
function cost(db, { project = 'p1', stage, lane = null, ts = ago(60), rc = 0 }) {
  seq++;
  db.prepare(`INSERT INTO cost_rows (box, row_hash, line_no, ts, project, stage, runner, rc, cost_usd, lane_id, inserted_at)
              VALUES (?,?,?,?,?,?,?,?,?,?,?)`).run('box-a', `h-${seq}`, seq, ts, project, stage, 'claude', rc, 0.5, lane, ts);
}
function merged(db, repo, n, at = ago(60)) {
  db.prepare(`INSERT INTO ledgers (kind, key, status, created_at, updated_at) VALUES ('merge', ?, 'merged', ?, ?)`)
    .run(`https://github.com/${repo}/pull/${n}`, at, at);
}
function saving(db, project, verdict, at = ago(60)) {
  seq++;
  const id = `rs-${seq}`;
  db.prepare(`INSERT INTO jobs (id, project, kind, box, status, stage, created_at, updated_at) VALUES (?,?,?,?,?,?,?,?)`)
    .run(id, project, 'review-saving', 'box-a', 'done', 'done', at, at);
  db.prepare(`INSERT INTO stage_events (job_id, stage, verdict, actor, detail, created_at) VALUES (?,?,?,?,?,?)`)
    .run(id, 'review-saving', verdict, 'box-a', 'how=patch-id', at);
}
function project(db, name, repo) {
  db.prepare(`INSERT INTO projects (project, repo, cron_offset, created_at, updated_at) VALUES (?,?,0,?,?)`).run(name, repo, ago(0), ago(0));
}
// The world C1-C4 read: 9 counted review calls on p1 today, plus the rows that
// must NOT count.
function seedWorld(db) {
  project(db, 'p1', 'example-org/p1');
  for (let i = 0; i < 3; i++) cost(db, { stage: 'lead-review', lane: 'lead-review' });
  cost(db, { stage: 'review', lane: 'fly-pool' });
  cost(db, { stage: 'review', lane: 'fly-pool' });
  cost(db, { stage: 'review', lane: 'merge-conductor' });
  cost(db, { stage: 'review', lane: 'review-autopilot' });
  cost(db, { stage: 'review', lane: 'review-rescue' });
  cost(db, { stage: 'review', lane: 'blocked-resolver' });
  cost(db, { stage: 'execute', lane: 'fly-pool' });                       // a build call, not a review
  cost(db, { stage: 'lead-review', lane: 'lead-review', rc: 74 });       // refused: nothing was called
  cost(db, { stage: 'lead-review', lane: 'lead-review', ts: ago(5 * 86400) }); // outside the rollup window
  cost(db, { project: 'p2', stage: 'lead-review', lane: 'lead-review' });
  merged(db, 'example-org/p1', 101);
  merged(db, 'example-org/p1', 102);
  merged(db, 'example-org/p2', 7);
  saving(db, 'p1', 'REUSED');
  saving(db, 'p1', 'REUSED');
  saving(db, 'p1', 'TRIVIAL_ESCALATED');
}
const today = (body) => body.days.find((d) => d.day === dayOf(ago(60)));

test('C1-C3 a rollup counts review calls by kind, merged PRs and rebinds for the day', async (t) => {
  const o = await fresh(t); if (!o) return;
  seedWorld(o.db);
  const r = await call(o.DB, '/api/review-counts/rollup', { method: 'POST', body: {} });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.ok(r.body.rows > 0, JSON.stringify(r.body));
  const g = await call(o.DB, '/api/review-counts?project=p1');
  assert.equal(g.status, 200, JSON.stringify(g.body));
  assert.deepEqual(g.body.kinds, KINDS);
  const d = today(g.body);
  assert.ok(d, JSON.stringify(g.body.days));
  assert.equal(d.kinds.lead, 3);
  assert.equal(d.kinds.lens, 2);
  assert.equal(d.kinds.conductor, 1);
  assert.equal(d.kinds.autopilot, 1);
  assert.equal(d.kinds.rescue, 1);
  assert.equal(d.kinds.resolver, 1);
  assert.equal(d.kinds['fix-rereview'], null, 'no rule in the seed map: unknown, never 0');
  assert.ok(g.body.unmapped.includes('fix-rereview'));
  assert.equal(d.reviews, 9);
  assert.equal(d.merged_prs, 2);
  assert.equal(d.rebinds, 2);
  assert.equal(d.per_merged, 4.5);
});

test('C2 every one of the 7 kinds is a key of every day', async (t) => {
  const o = await fresh(t); if (!o) return;
  seedWorld(o.db);
  const g = await call(o.DB, '/api/review-counts?project=p1');
  for (const d of g.body.days) assert.deepEqual(Object.keys(d.kinds).sort(), [...KINDS].sort());
});

test('C3 the all-projects view sums p1 and p2', async (t) => {
  const o = await fresh(t); if (!o) return;
  seedWorld(o.db);
  const g = await call(o.DB, '/api/review-counts');
  const d = today(g.body);
  assert.equal(d.kinds.lead, 4);
  assert.equal(d.merged_prs, 3, 'p2 has no projects row, so its repo name is the project');
  assert.equal(d.reviews, 10);
});

test('C4 a project with no rows answers 0 days', async (t) => {
  const o = await fresh(t); if (!o) return;
  seedWorld(o.db);
  const g = await call(o.DB, '/api/review-counts?project=other-project');
  assert.equal(g.status, 200);
  assert.equal(g.body.days.length, 0);
});

test('C5 no bearer is 401 on GET and on the rollup POST', async (t) => {
  const o = await fresh(t); if (!o) return;
  assert.equal((await call(o.DB, '/api/review-counts', { bearer: false })).status, 401);
  assert.equal((await call(o.DB, '/api/review-counts/rollup', { method: 'POST', body: {}, bearer: false })).status, 401);
});

test('C6 GET rolls up on its own when stale, and not again inside review_counts.rollup_every_s', async (t) => {
  const o = await fresh(t); if (!o) return;
  seedWorld(o.db);
  const g1 = await call(o.DB, '/api/review-counts?project=p1');
  assert.equal(today(g1.body).kinds.lead, 3, 'the first GET rolled up with no POST');
  assert.ok(g1.body.rolled_at);
  cost(o.db, { stage: 'lead-review', lane: 'lead-review' });
  const g2 = await call(o.DB, '/api/review-counts?project=p1');
  assert.equal(today(g2.body).kinds.lead, 3, 'inside the window the GET does not recompute');
  setting(o.db, 'review_counts.rollup_every_s', '0');
  const g3 = await call(o.DB, '/api/review-counts?project=p1');
  assert.equal(today(g3.body).kinds.lead, 4, 'with the window 0 the GET recomputes');
});

test('C7 a rollup rewrites only the last review_counts.rollup_days days', async (t) => {
  const o = await fresh(t); if (!o) return;
  const old = dayOf(ago(10 * 86400));
  o.db.prepare(`INSERT INTO review_counts_daily (day, project, kind, n, merged_prs, rebinds, updated_at)
                VALUES (?, 'p1', 'lead', 42, NULL, NULL, ?)`).run(old, ago(10 * 86400));
  cost(o.db, { stage: 'lead-review', lane: 'lead-review', ts: ago(10 * 86400) });
  await call(o.DB, '/api/review-counts/rollup', { method: 'POST', body: {} });
  const row = o.db.prepare(`SELECT n FROM review_counts_daily WHERE day=? AND project='p1' AND kind='lead'`).get(old);
  assert.equal(row.n, 42, 'a day outside the window is not recomputed');
});

test('C8 the kind map is the settings row', async (t) => {
  const o = await fresh(t); if (!o) return;
  seedWorld(o.db);
  setting(o.db, 'review_counts.kind_map', JSON.stringify([
    { kind: 'lens', stage: 'lead-review' },
    { kind: 'fix-rereview', stage: 'review', lane: 'fly-pool' },
  ]));
  await call(o.DB, '/api/review-counts/rollup', { method: 'POST', body: {} });
  const d = today((await call(o.DB, '/api/review-counts?project=p1')).body);
  assert.equal(d.kinds.lens, 3);
  assert.equal(d.kinds['fix-rereview'], 2);
  assert.equal(d.kinds.lead, null);
});

test('C9 days must be a whole number up to review_counts.max_days', async (t) => {
  const o = await fresh(t); if (!o) return;
  assert.equal((await call(o.DB, '/api/review-counts?days=31')).status, 400);
  assert.equal((await call(o.DB, '/api/review-counts?days=abc')).status, 400);
  assert.equal((await call(o.DB, '/api/review-counts?days=0')).status, 400);
  const ok = await call(o.DB, '/api/review-counts?days=30');
  assert.equal(ok.status, 200);
  assert.equal(ok.body.max_days, 30);
  setting(o.db, 'review_counts.max_days', '5');
  assert.equal((await call(o.DB, '/api/review-counts?days=6')).status, 400);
  // only `days` days come back
  seedWorld(o.db);
  o.db.prepare(`INSERT INTO review_counts_daily (day, project, kind, n, merged_prs, rebinds, updated_at)
                VALUES (?, 'p1', 'lead', 1, NULL, NULL, ?)`).run(dayOf(ago(4 * 86400)), ago(0));
  const two = await call(o.DB, '/api/review-counts?days=2&project=p1');
  assert.ok(two.body.days.every((d) => d.day >= dayOf(ago(86400))), JSON.stringify(two.body.days));
});

test('C10 at 10,000 seeded cost rows no GET or rollup read scans a large table', async (t) => {
  const o = await fresh(t); if (!o) return;
  const db = o.db;
  db.exec('BEGIN');
  const stages = [['review', 'fly-pool'], ['lead-review', 'lead-review'], ['execute', 'fly-pool'], ['plan', 'fly-pool']];
  for (let i = 0; i < 10000; i++) {
    const [stage, lane] = stages[i % stages.length];
    cost(db, { project: `p${i % 13}`, stage, lane, ts: ago(Math.floor((i / 10000) * 30 * 86400)) });
  }
  for (let i = 0; i < 2000; i++) merged(db, `o/p${i % 13}`, i, ago(i * 600));
  for (let i = 0; i < 500; i++) saving(db, `p${i % 13}`, i % 2 ? 'REUSED' : 'TRIVIAL', ago(i * 900));
  for (let d = 0; d < 60; d++) {
    for (let p = 0; p < 13; p++) {
      db.prepare(`INSERT OR IGNORE INTO review_counts_daily (day, project, kind, n, merged_prs, rebinds, updated_at)
                  VALUES (?,?,?,?,?,?,?)`).run(dayOf(ago((d + 3) * 86400)), `p${p}`, 'lead', d, null, null, ago(0));
    }
  }
  db.exec('COMMIT');
  db.exec('ANALYZE');
  const log = [];
  const R = capturingD1(db, log);
  assert.equal((await call(R, '/api/review-counts')).status, 200);
  assert.equal((await call(R, '/api/review-counts?project=p3')).status, 200);
  const reads = log.filter((r) => /cost_rows|ledgers|stage_events|review_counts_daily/.test(r.sql));
  assert.ok(reads.some((r) => /FROM cost_rows/.test(r.sql)), 'the rollup read cost_rows');
  assert.ok(reads.some((r) => /FROM review_counts_daily/.test(r.sql)), 'the GET read the rollup table');
  for (const r of reads) {
    const lines = plan(db, r.sql, ...r.binds);
    assert.deepEqual(fullScans(lines, ['cost_rows', 'ledgers', 'stage_events', 'review_counts_daily', 'jobs']), [],
      `${r.sql.slice(0, 100)}: ${lines.join(' | ')}`);
  }
});

async function archiveDb() {
  const { DatabaseSync } = await import('node:sqlite');
  const db = new DatabaseSync(':memory:');
  return { db, ARCHIVE: d1(db) };
}
async function retention(env, body = {}) {
  const res = await worker.fetch(new Request('https://jobs.test/api/retention/run', {
    method: 'POST', headers: { authorization: `Bearer ${SECRET}`, 'content-type': 'application/json' }, body: JSON.stringify(body),
  }), { HARNESS_SECRET: SECRET, ...env });
  const b = await res.json().catch(() => null);
  return { status: res.status, rule: b && b.rules ? b.rules.find((x) => x.rule === 'review_counts_daily.archive') : null, body: b };
}

test('C11 retention moves an old day to the archive, a dry run deletes nothing, the id read uses the key', async (t) => {
  const o = await fresh(t); if (!o) return;
  const ins = o.db.prepare(`INSERT INTO review_counts_daily (day, project, kind, n, merged_prs, rebinds, updated_at)
                            VALUES (?, 'p1', ?, ?, ?, ?, ?)`);
  ins.run(dayOf(ago(200 * 86400)), 'lead', 5, null, null, ago(200 * 86400));
  ins.run(dayOf(ago(200 * 86400)), 'total', 5, 2, 1, ago(200 * 86400));
  ins.run(dayOf(ago(3 * 86400)), 'lead', 7, null, null, ago(3 * 86400));
  const a = await archiveDb();
  // the seed is 0: the rule is off until ARCHIVE is bound and the row is set
  let r = await retention({ DB: o.DB, ARCHIVE: a.ARCHIVE });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.ok(r.rule, 'the rule is registered');
  assert.equal(r.rule.off, true, 'off in the seed');
  assert.equal(r.rule.error, null);
  setting(o.db, 'retention.review_counts_daily.days', '180');
  // retention.dry_run is 1 in the seed: count, delete nothing
  r = await retention({ DB: o.DB, ARCHIVE: a.ARCHIVE });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.ok(r.rule, 'the rule is registered');
  assert.equal(r.rule.counted, 2);
  assert.equal(o.db.prepare('SELECT COUNT(*) AS n FROM review_counts_daily').get().n, 3);
  setting(o.db, 'retention.dry_run', '0');
  r = await retention({ DB: o.DB, ARCHIVE: a.ARCHIVE });
  assert.equal(r.rule.error, null, JSON.stringify(r.rule));
  assert.equal(r.rule.removed, 2);
  assert.deepEqual(o.db.prepare('SELECT day FROM review_counts_daily').all().map((x) => x.day), [dayOf(ago(3 * 86400))]);
  const arch = a.db.prepare('SELECT kind, n, merged_prs, rebinds FROM review_counts_daily ORDER BY kind').all().map((x) => ({ ...x }));
  assert.deepEqual(arch, [{ kind: 'lead', n: 5, merged_prs: null, rebinds: null }, { kind: 'total', n: 5, merged_prs: 2, rebinds: 1 }]);
  const audit = o.db.prepare(`SELECT removed FROM retention_runs WHERE rule='review_counts_daily.archive'`).all();
  assert.equal(audit.length, 2, 'one audit row per run that was on');
  // unbound archive: nothing moves
  ins.run(dayOf(ago(300 * 86400)), 'lead', 1, null, null, ago(0));
  r = await retention({ DB: o.DB });
  assert.equal(r.rule.removed, 0);
  assert.match(String(r.rule.error), /archive not bound/);
  const { RULES } = await import('../src/routes/retention.js');
  const rule = RULES.find((x) => x.rule === 'review_counts_daily.archive');
  const lines = plan(o.db, rule.ids, ago(180 * 86400), 500);
  assert.deepEqual(fullScans(lines, ['review_counts_daily']), [], lines.join(' | '));
});
