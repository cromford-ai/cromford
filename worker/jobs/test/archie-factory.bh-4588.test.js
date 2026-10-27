// BH-4588 (BH-4574.6): GET /api/archie/factory-report, driven through the REAL
// worker.fetch against the REAL composed schema (the node:sqlite D1 shim).
// The seed rows copy the shapes the real writers store: archie_actions as
// POST /api/archie/actions writes them (waves 1-5 playbooks, actions and
// evidence), merge ledgers keyed by PR url, cost_rows, merge_queue_batches.
//
// W1 counts match the seed, and the committed fixture
//    tests/fixtures/archie-fm-report.bh-4588/report.json (read by the bash
//    renderer's R1 and the console's C1) still holds the same section fields
//    and counts. This test never writes the fixture.
// W2 an empty day: every section says why it is empty; empty.json (the bash
//    renderer's R2) is that answer.
// W3 the one-thing priority table.
// W4 wrong tenant: project=other-proj reads 0 rows of the seeded projects.
// W5 EXPLAIN QUERY PLAN at volume: every data read uses its named index.
// W6 one call is at most 7 statements.
// W7 junk params are a 400 naming the field; limit over the cap is refused.
// W8 one failed read is that section's ok:false, the rest stay ok, status 200.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import { FACTORY_SQL } from '../src/routes/archie-factory.js';

const SECRET = 'test-secret';
const DAY = '2026-10-22';
const FIXTURE = new URL('../../../tests/fixtures/archie-fm-report.bh-4588/report.json', import.meta.url);
const EMPTY_FIXTURE = new URL('../../../tests/fixtures/archie-fm-report.bh-4588/empty.json', import.meta.url);

const get = (DB, qs) => {
  const req = new Request(`https://jobs.test/api/archie/factory-report?${qs}`, {
    headers: { authorization: `Bearer ${SECRET}` },
  });
  return worker.fetch(req, { DB, HARNESS_SECRET: SECRET }).then(async (res) => ({
    status: res.status, body: await res.json().catch(() => null),
  }));
};

let seq = 0;
function action(db, o) {
  seq += 1;
  const at = o.at || `${DAY}T${String(8 + (seq % 10)).padStart(2, '0')}:${String(seq % 60).padStart(2, '0')}:00Z`;
  const r = {
    dedupe_key: `fx:${o.playbook}:${seq}`, day: at.slice(0, 10), project: 'cromford', repo: 'example-org/cromford',
    pr: 0, mode: 'on', why: 'fixture', evidence: {}, actor: 'archie-fm', ...o,
  };
  db.prepare(`INSERT INTO archie_actions (dedupe_key, day, project, repo, pr, playbook, mode, action, outcome, why, evidence,
      attempts, actor, created_at, updated_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,1,?,?,?)`)
    .run(r.dedupe_key, r.day, r.project, r.repo, r.pr, r.playbook, r.mode, r.action, r.outcome, r.why,
      JSON.stringify(r.evidence), r.actor, at, at);
}
const merge = (db, url, at) => db.prepare(
  "INSERT INTO ledgers (kind, key, status, job_id, actor, detail, created_at, updated_at) VALUES ('merge', ?, 'merged', NULL, 'merge-sweep', NULL, ?, ?)"
).run(url, at, at);
const job = (db, id, project, url) => {
  db.prepare("INSERT INTO jobs (id, project, ticket_id, kind, box, stage, status, created_at, updated_at) VALUES (?,?,?,'build','hub','done','done',?,?)")
    .run(id, project, 'BH-1', `${DAY}T01:00:00Z`, `${DAY}T01:00:00Z`);
  db.prepare("INSERT INTO job_artifacts (job_id, artifact_kind, artifact_ref, created_at, updated_at) VALUES (?, 'pr_url', ?, ?, ?)")
    .run(id, url, `${DAY}T01:00:00Z`, `${DAY}T01:00:00Z`);
};
const cost = (db, project, usd, ts, n) => db.prepare(
  "INSERT INTO cost_rows (box, row_hash, line_no, ts, project, stage, cost_usd, inserted_at) VALUES ('hub', ?, ?, ?, ?, 'execute', ?, ?)"
).run(`h${n}`, n, ts, project, usd, ts);
const batch = (db, repo, n, outcome, at) => db.prepare(
  "INSERT INTO merge_queue_batches (repo, draft_pr, finished_at, outcome, updated_at) VALUES (?, ?, ?, ?, ?)"
).run(repo, n, at, outcome, at);
const setting = (db, k, v) => db.prepare(
  "INSERT INTO settings (key, value, note, actor, updated_at) VALUES (?, ?, 'fixture', 'test', 't') ON CONFLICT(key) DO UPDATE SET value=excluded.value"
).run(k, v);

// THE SEEDED DAY. 3 merges over 2 projects (one with no job artifact: its
// project comes from the projects row), queue 3 batches and 2 queue actions,
// stuck 2 cleared + 1 open, tickets 1 filed + 1 commented + 1 shipped,
// spend on 2 projects (one fully unpriced), one failed action, and rows on
// the day before that must not count.
function seedDay(db) {
  db.prepare("INSERT INTO projects (project, repo, cron_offset, created_at, updated_at) VALUES ('cromford','example-org/cromford',0,'t','t'), ('project-4','example-org/project-4',1,'t','t')").run();
  const u = (r, n) => `https://github.com/example-org/${r}/pull/${n}`;
  job(db, 'build-cromford-BH-1-1', 'cromford', u('cromford', 101));
  job(db, 'build-project-4-CT-1-1', 'project-4', u('project-4', 12));
  merge(db, u('cromford', 101), `${DAY}T09:00:00Z`);
  merge(db, u('cromford', 103), `${DAY}T15:00:00Z`);
  merge(db, u('project-4', 12), `${DAY}T11:00:00Z`);
  merge(db, u('project-4', 11), '2026-10-21T23:59:59Z');
  action(db, { playbook: 'rebase-repair', pr: 101, action: 'repair', outcome: 'done', why: 'merged main and pushed with lease' });
  action(db, { playbook: 'stacked-parent-merged', project: 'project-4', repo: 'example-org/project-4', pr: 12, action: 'restack', outcome: 'done', why: 'parent #11 merged; restacked onto main' });
  action(db, { playbook: 'watch-main-red', project: 'hub', action: 'kick_lane', outcome: 'requested', why: 'main red 70 min; kicked main-red-bisect', evidence: { alert_id: 'main-red-cromford' } });
  action(db, { playbook: 'queue-enqueue', project: 'project-4', repo: 'example-org/project-4', pr: 13, action: 'enqueue', outcome: 'done', why: 'approved and green; enqueued' });
  action(db, { playbook: 'queue-culprit', pr: 102, action: 'block_verdict', outcome: 'failed', why: 'solo run could not start' });
  action(db, { playbook: 'improve', project: 'hub', action: 'file_ticket', outcome: 'done', why: 'watch|disk|hub|run_cleanup recurred 3 times', evidence: { fp: '0123456789ab', issue_url: 'https://github.com/example-org/cromford/issues/9001', existing: false } });
  action(db, { playbook: 'watch-ticket', project: 'hub', action: 'file_ticket', outcome: 'done', why: 'commented on the open escalation', evidence: { issue: 'https://github.com/example-org/cromford/issues/8999', existing: true } });
  action(db, { playbook: 'improve', project: 'hub', action: 'track_merged', outcome: 'done', why: 'fix #9000 merged in #103', evidence: { fp: 'abcdef012345', issue: 9000, pr: 103, before: 4 } });
  action(db, { playbook: 'rebase-repair', pr: 99, action: 'repair', outcome: 'done', why: 'yesterday', at: '2026-10-21T12:00:00Z' });
  let n = 0;
  cost(db, 'cromford', 1.5, `${DAY}T10:00:00Z`, ++n);
  cost(db, 'cromford', 2.25, `${DAY}T12:00:00Z`, ++n);
  cost(db, 'cromford', null, `${DAY}T13:00:00Z`, ++n);
  cost(db, 'project-4', null, `${DAY}T14:00:00Z`, ++n);
  cost(db, 'project-4', 9, '2026-10-21T14:00:00Z', ++n);
  batch(db, 'example-org/cromford', 7001, 'merged', `${DAY}T09:30:00Z`);
  batch(db, 'example-org/cromford', 7002, 'failed', `${DAY}T10:30:00Z`);
  batch(db, 'example-org/project-4', 7003, 'merged', `${DAY}T11:30:00Z`);
  batch(db, 'example-org/project-4', 7004, 'merged', '2026-10-23T00:00:01Z');
}

// The fields both readers use, compared between the live answer and the fixture.
const sectionFields = (r) => ({
  day: r.day,
  merges: { ok: r.merges.ok, total: r.merges.total, by_project: r.merges.by_project.map((g) => [g.project, g.n, g.prs.map((p) => p.url)]) },
  queue: { ok: r.queue.ok, batches: r.queue.batches, actions: r.queue.actions },
  stuck: { ok: r.stuck.ok, cleared: r.stuck.cleared, open: r.stuck.open, failed: r.stuck.failed, items: r.stuck.items.map((i) => [i.playbook, i.outcome, i.url]) },
  tickets: { ok: r.tickets.ok, filed: r.tickets.filed, commented: r.tickets.commented, shipped: r.tickets.shipped, verified: r.tickets.verified },
  spend: { ok: r.spend.ok, by_project: r.spend.by_project.map((p) => [p.project, p.usd, p.calls, p.unpriced_calls, p.cap_usd, p.over]) },
  actions: { ok: r.actions.ok, n: r.actions.rows.length, truncated: r.actions.truncated, ids: r.actions.rows.map((a) => [a.playbook, a.outcome, a.pr]) },
  mode: { ok: r.mode.ok, fleet: r.mode.fleet, off: r.mode.off },
  one_thing: r.one_thing.kind,
});

test('BH-4588 GET /api/archie/factory-report', async (t) => {
  const probe = await openDb();
  if (probe === null) { t.skip('node:sqlite unavailable in this runtime'); return; }

  await t.test('W1 the seeded day: every count equals the seeded rows; the committed fixture agrees', async () => {
    const { DB, db } = await openDb();
    seedDay(db);
    const r = await get(DB, `day=${DAY}`);
    assert.equal(r.status, 200, JSON.stringify(r.body));
    const b = r.body;
    assert.equal(b.merges.total, 3);
    assert.deepEqual(b.merges.by_project.map((g) => [g.project, g.n]), [['cromford', 2], ['project-4', 1]]);
    assert.ok(b.merges.by_project[0].prs.some((p) => p.url.endsWith('/cromford/pull/103')), 'a merge with no artifact still counts');
    assert.deepEqual(b.queue.batches, { total: 3, by_outcome: { merged: 2, failed: 1 } });
    assert.equal(b.queue.actions.total, 2);
    assert.deepEqual(b.queue.actions.by_outcome, { done: 1, failed: 1 });
    assert.equal(b.stuck.cleared, 2);
    assert.equal(b.stuck.open, 1);
    assert.equal(b.stuck.failed, 0);
    assert.equal(b.stuck.items.length, 3);
    assert.ok(b.stuck.items.some((i) => i.url === 'https://github.com/example-org/cromford/pull/101' && i.outcome === 'done'));
    assert.equal(b.tickets.filed, 1);
    assert.equal(b.tickets.commented, 1);
    assert.equal(b.tickets.shipped, 1);
    const bh = b.spend.by_project.find((p) => p.project === 'cromford');
    assert.equal(bh.usd, 3.75);
    assert.equal(bh.calls, 3);
    assert.equal(bh.unpriced_calls, 1);
    assert.equal(bh.cap_usd, 11323.76);
    assert.equal(bh.over, false);
    const ct = b.spend.by_project.find((p) => p.project === 'project-4');
    assert.equal(ct.usd, null, 'an all-unpriced day is unknown, never 0');
    assert.equal(ct.over, false);
    assert.equal(b.actions.rows.length, 8);
    assert.equal(b.actions.truncated, false);
    assert.ok(b.actions.rows.every((a) => typeof a.evidence === 'object'));
    assert.equal(b.mode.fleet, 'observe');
    assert.equal(b.one_thing.kind, 'failed');
    for (const k of ['mode', 'merges', 'queue', 'stuck', 'tickets', 'spend', 'actions']) {
      assert.equal(b[k].ok, true, k);
      assert.equal(b[k].empty_reason, undefined, k);
    }
    const fixture = JSON.parse(readFileSync(FIXTURE, 'utf8'));
    assert.deepEqual(sectionFields(fixture), sectionFields(b), 'the committed fixture is the route output for this seed');
  });

  await t.test('W2 an empty day: every section is ok and says why it is empty', async () => {
    const { DB } = await openDb();
    const r = await get(DB, 'day=2026-10-01');
    assert.equal(r.status, 200);
    for (const k of ['merges', 'queue', 'stuck', 'tickets', 'spend', 'actions']) {
      assert.equal(r.body[k].ok, true, k);
      assert.match(r.body[k].empty_reason || '', /2026-10-01/, k);
    }
    assert.equal(r.body.one_thing.kind, 'none');
    const empty = JSON.parse(readFileSync(EMPTY_FIXTURE, 'utf8'));
    for (const k of ['merges', 'queue', 'stuck', 'tickets', 'spend', 'actions']) {
      assert.equal(empty[k].empty_reason, r.body[k].empty_reason, `the committed empty fixture's ${k}`);
    }
    assert.deepEqual(sectionFields(empty), sectionFields(r.body), 'the committed empty fixture is the route output for an empty day');
  });

  await t.test('W3 the one thing: failed > over cap > stuck open > nothing; unread spend never claims over cap', async () => {
    let { DB, db } = await openDb();
    seedDay(db);
    setting(db, 'budget.project.cromford.day_usd', '1');
    let r = await get(DB, `day=${DAY}`);
    assert.equal(r.body.one_thing.kind, 'failed', 'failed outranks over cap');
    assert.match(r.body.one_thing.text, /^1 Archie action failed on 2026-10-22\. The latest: queue-culprit on example-org\/cromford#102/);
    db.prepare("DELETE FROM archie_actions WHERE outcome='failed'").run();
    r = await get(DB, `day=${DAY}`);
    assert.equal(r.body.one_thing.kind, 'over_cap', 'over cap outranks stuck open');
    assert.match(r.body.one_thing.text, /cromford spent \$3\.75 on 2026-10-22, over its \$1\.00 day cap/);
    setting(db, 'budget.project.cromford.day_usd', '11323.76');
    r = await get(DB, `day=${DAY}`);
    assert.equal(r.body.one_thing.kind, 'stuck_open');
    db.prepare("UPDATE archie_actions SET outcome='done' WHERE outcome='requested'").run();
    r = await get(DB, `day=${DAY}`);
    assert.equal(r.body.one_thing.kind, 'none');
    ({ DB, db } = await openDb());
    seedDay(db);
    db.prepare("DELETE FROM archie_actions WHERE outcome IN ('failed','requested')").run();
    setting(db, 'budget.project.cromford.day_usd', '1');
    const throwing = { ...DB, prepare: (sql) => (/FROM cost_rows/.test(sql) ? (() => { throw new Error('D1_ERROR: fixture cost read down'); })() : DB.prepare(sql)) };
    r = await get(throwing, `day=${DAY}`);
    assert.equal(r.body.spend.ok, false);
    assert.equal(r.body.one_thing.kind, 'none', 'an unreadable spend section never claims over cap');
  });

  await t.test('W4 wrong tenant: project=other-proj reads 0 actions, 0 merges, 0 spend', async () => {
    const { DB, db } = await openDb();
    seedDay(db);
    const r = await get(DB, `day=${DAY}&project=other-proj`);
    assert.equal(r.status, 200);
    assert.equal(r.body.actions.rows.length, 0);
    assert.equal(r.body.merges.total, 0);
    assert.equal(r.body.spend.by_project.length, 0);
    assert.equal(r.body.queue.batches.total, 0);
    assert.equal(r.body.stuck.total, 0);
    const own = await get(DB, `day=${DAY}&project=project-4`);
    assert.equal(own.body.merges.total, 1);
    assert.deepEqual(own.body.actions.rows.map((a) => a.project), ['project-4', 'project-4']);
    assert.equal(own.body.queue.batches.total, 1);
  });

  await t.test('W5 EXPLAIN at volume: each data read uses its index, no full SCAN', async () => {
    const { db } = await openDb();
    db.exec('BEGIN');
    const ins = db.prepare(`INSERT INTO archie_actions (dedupe_key, day, project, repo, pr, playbook, mode, action, outcome, why,
        evidence, attempts, actor, created_at, updated_at) VALUES (?,?,?,?,?,?,?,?,?,?,'{}',1,'fx',?,?)`);
    const pbs = ['rebase-repair', 'queue-enqueue', 'watch-disk', 'improve', 'stacked-parent-merged'];
    for (let i = 0; i < 20000; i += 1) {
      const d = new Date(Date.UTC(2026, 7, 24) + (i % 60) * 86400000).toISOString().slice(0, 10);
      ins.run(`v:${i}`, d, i % 2 ? 'cromford' : 'project-4', 'example-org/cromford', i % 500, pbs[i % 5], 'on', 'repair', 'done', 'v', `${d}T10:00:00Z`, `${d}T10:00:00Z`);
    }
    const c = db.prepare("INSERT INTO cost_rows (box, row_hash, line_no, ts, project, cost_usd, inserted_at) VALUES ('hub', ?, ?, ?, ?, 0.1, 't')");
    for (let i = 0; i < 50000; i += 1) {
      c.run(`v${i}`, i, new Date(Date.UTC(2026, 7, 24) + i * 100000).toISOString().replace(/\.\d{3}Z$/, 'Z'), i % 3 ? 'cromford' : 'project-4');
    }
    const l = db.prepare("INSERT INTO ledgers (kind, key, status, created_at, updated_at) VALUES (?, ?, ?, ?, ?)");
    for (let i = 0; i < 5000; i += 1) {
      const at = new Date(Date.UTC(2026, 7, 24) + i * 1000000).toISOString().replace(/\.\d{3}Z$/, 'Z');
      l.run(i % 2 ? 'merge' : 'pr_state', `https://github.com/example-org/cromford/pull/${i}`, i % 4 ? 'merged' : 'parked', at, at);
    }
    const bq = db.prepare("INSERT INTO merge_queue_batches (repo, draft_pr, finished_at, outcome, updated_at) VALUES ('example-org/cromford', ?, ?, 'merged', 't')");
    for (let i = 0; i < 5000; i += 1) bq.run(i, new Date(Date.UTC(2026, 7, 24) + i * 1000000).toISOString().replace(/\.\d{3}Z$/, 'Z'));
    db.exec('COMMIT');
    db.exec('ANALYZE');
    const plan = (sql, ...binds) => db.prepare(`EXPLAIN QUERY PLAN ${sql}`).all(...binds).map((r) => r.detail);
    const from = `${DAY}T00:00:00Z`; const to = '2026-10-23T00:00:00Z';
    const cases = [
      ['agg', plan(FACTORY_SQL.SQL_AGG(false), DAY), /idx_archie_actions_day/],
      ['agg+project', plan(FACTORY_SQL.SQL_AGG(true), DAY, 'project-4'), /idx_archie_actions_day/],
      ['rows', plan(FACTORY_SQL.SQL_ROWS(false), DAY, 301), /idx_archie_actions_day/],
      ['rows+project', plan(FACTORY_SQL.SQL_ROWS(true), DAY, 301, 'project-4'), /idx_archie_actions_day/],
      ['merges', plan(FACTORY_SQL.SQL_MERGES, from, to, 2001), /idx_ledgers_kind_status_created/],
      ['spend', plan(FACTORY_SQL.SQL_SPEND(false), from, to), /idx_cost_rows_(project_)?ts/],
      ['spend+project', plan(FACTORY_SQL.SQL_SPEND(true), from, to, 'project-4'), /idx_cost_rows_(project_)?ts/],
      ['batches', plan(FACTORY_SQL.SQL_BATCHES, from, to), /idx_mq_batches_finished/],
    ];
    for (const [name, steps, want] of cases) {
      assert.ok(steps.some((s) => want.test(s)), `${name}: ${steps.join(' | ')}`);
      for (const s of steps) {
        assert.doesNotMatch(s, /^SCAN (archie_actions|cost_rows|ledgers|l|merge_queue_batches|job_artifacts|a|jobs|j)\b(?! USING)/, `${name}: ${s}`);
      }
    }
    const merges = plan(FACTORY_SQL.SQL_MERGES, from, to, 2001);
    assert.ok(merges.some((s) => /SEARCH a USING (COVERING )?INDEX idx_artifacts_ref/.test(s)), merges.join(' | '));
    assert.ok(merges.some((s) => /SEARCH j USING INDEX sqlite_autoindex_jobs_1/.test(s)), merges.join(' | '));
  });

  await t.test('W6 one call runs at most 7 statements', async () => {
    const { DB, db } = await openDb();
    seedDay(db);
    let n = 0;
    const counting = { ...DB, prepare: (sql) => { n += 1; return DB.prepare(sql); } };
    const r = await get(counting, `day=${DAY}`);
    assert.equal(r.status, 200);
    assert.ok(n <= 7, `statements: ${n}`);
    assert.ok(n >= 7, `every read ran: ${n}`);
  });

  await t.test('W7 junk is a 400 naming the field; a limit over the actions_limit row is refused, not clamped', async () => {
    const { DB, db } = await openDb();
    for (const [qs, field] of [['', 'day'], ['day=yesterday', 'day'], ['day=2026-02-30', 'day'], ['day=2026-1-01', 'day'],
      [`day=${DAY}&project=Bad_Proj`, 'project'], [`day=${DAY}&limit=0`, 'limit'], [`day=${DAY}&limit=301`, 'limit'],
      [`day=${DAY}&limit=abc`, 'limit']]) {
      const r = await get(DB, qs);
      assert.equal(r.status, 400, qs);
      assert.equal(r.body.error, field, qs);
    }
    assert.equal((await get(DB, `day=${DAY}&limit=301`)).body.max, 300, 'the cap is read from archie.report.actions_limit (seeded 300)');
    seedDay(db);
    setting(db, 'archie.report.actions_limit', '5');
    const r = await get(DB, `day=${DAY}`);
    assert.equal(r.body.actions.rows.length, 5);
    assert.equal(r.body.actions.truncated, true, 'a capped day says truncated');
    assert.equal(r.body.actions.limit, 5);
    assert.equal(r.body.stuck.cleared, 2, 'the cap never shortens a count');
    assert.equal((await get(DB, `day=${DAY}&limit=6`)).status, 400);
    const two = await get(DB, `day=${DAY}&limit=2`);
    assert.equal(two.body.actions.rows.length, 2);
  });

  await t.test('W8 a failed read is that section ok:false; the rest stay ok; status 200', async () => {
    const { DB, db } = await openDb();
    seedDay(db);
    const throwing = { ...DB, prepare: (sql) => (/FROM cost_rows/.test(sql) ? (() => { throw new Error('D1_ERROR: fixture cost read down'); })() : DB.prepare(sql)) };
    const r = await get(throwing, `day=${DAY}`);
    assert.equal(r.status, 200);
    assert.equal(r.body.spend.ok, false);
    assert.match(r.body.spend.error, /fixture cost read down/);
    for (const k of ['mode', 'merges', 'queue', 'stuck', 'tickets', 'actions']) assert.equal(r.body[k].ok, true, k);
    const noSettings = { ...DB, prepare: (sql) => (/FROM settings/.test(sql) ? (() => { throw new Error('D1_ERROR: settings down'); })() : DB.prepare(sql)) };
    const s = await get(noSettings, `day=${DAY}`);
    assert.equal(s.status, 200);
    assert.equal(s.body.mode.ok, false, 'an unreadable mode is not a mode');
    assert.equal(s.body.spend.ok, false, 'no caps read: spend vs caps is not measured');
    assert.equal(s.body.merges.total, 3);
  });
});
