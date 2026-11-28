// BH-9929 (T8): the contract-change step ledger, driven through the REAL
// worker.fetch against the composed jobs schema (the node:sqlite D1 shim).
// 0 network calls: the D1 is an in-process sqlite database.
//
//   C1  POST is an upsert on (project, parent_ticket, step): 2 POSTs are 1
//       row, and a later POST with only verdict + approved_by keeps backup_ref
//   C2  a bad step, a bad project or a bad parent_ticket is 400 and writes no
//       row; no bearer is 401 on POST and on GET
//   C3  GET by project returns only that project's rows, newest first; a
//       wrong project is 0 rows; parent_ticket + step reads one row
//   C4  limit is capped at the settings row
//       lib.contract-change.contract_changes_list_max (fallback 100)
//   C5  EXPLAIN QUERY PLAN on 10,000 seeded rows: the list query uses
//       idx_contract_changes_project_updated and no temp sort; the retention
//       id read uses idx_contract_changes_updated
//   C6  retention: a dry run moves nothing; a live run archives an old row
//       and keeps a fresh one
//   C7  GET answers each step PR's live verdict from the verdicts table (the
//       stored `pending` never stands for a reviewed PR): the newest reviewed
//       head, a human row first on it, a box row and a retracted row ignored,
//       a PR with no verdict row keeps the stored value; the verdict read
//       uses idx_verdicts_pr_head
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';

const SECRET = 'test-secret-fixture';
const DAY = 86400e3;
const isoSec = (ms) => new Date(ms).toISOString().replace(/\.\d{3}Z$/, 'Z');
const req = (DB, method, path, body, { bearer = true } = {}) => worker.fetch(new Request(`https://jobs.test${path}`, {
  method,
  headers: { ...(bearer ? { authorization: `Bearer ${SECRET}` } : {}), 'content-type': 'application/json' },
  ...(body === undefined ? {} : { body: JSON.stringify(body) }),
}), { DB, HARNESS_SECRET: SECRET }).then(async (res) => ({ status: res.status, body: await res.json().catch(() => null) }));
const post = (DB, body, o) => req(DB, 'POST', '/api/contract-changes', body, o);
const get = (DB, qs, o) => req(DB, 'GET', `/api/contract-changes?${qs}`, undefined, o);
const step = (project, parent_ticket, s, over = {}) => ({ project, parent_ticket, step: s, ...over });

test('BH-9929 contract changes', async (t) => {
  const probe = await openDb();
  if (probe === null) { t.skip('node:sqlite unavailable in this runtime'); return; }

  await t.test('C1 a re-POST is an upsert and keeps stored fields', async () => {
    const { DB, db } = await openDb();
    const r1 = await post(DB, step('project-6-os', 9101, 'contract', {
      pr_url: 'https://github.com/example-org/project-6/pull/1', head_sha: 'abc1234', classes: 'drop-column',
      backup_ref: 'branch mk-pre-9101', restore_ref: 'scratch rc 0',
    }));
    assert.equal(r1.status, 200, JSON.stringify(r1.body));
    assert.equal(r1.body.row.verdict, null);
    const r2 = await post(DB, step('project-6-os', 9101, 'contract', { verdict: 'MERGE', approved_by: 'operator', backup_ref: '' }));
    assert.equal(r2.status, 200, JSON.stringify(r2.body));
    assert.equal(r2.body.row.id, r1.body.row.id);
    const all = db.prepare('SELECT * FROM contract_changes WHERE parent_ticket=?').all(9101);
    assert.equal(all.length, 1);
    assert.equal(all[0].backup_ref, 'branch mk-pre-9101');
    assert.equal(all[0].restore_ref, 'scratch rc 0');
    assert.equal(all[0].pr_url, 'https://github.com/example-org/project-6/pull/1');
    assert.equal(all[0].verdict, 'MERGE');
    assert.equal(all[0].approved_by, 'operator');
    assert.ok(all[0].created_at && all[0].updated_at);
    // A non-empty value does overwrite.
    await post(DB, step('project-6-os', 9101, 'contract', { head_sha: 'def5678' }));
    assert.equal(db.prepare('SELECT head_sha FROM contract_changes WHERE parent_ticket=?').get(9101).head_sha, 'def5678');
    // Another step is another row.
    assert.equal((await post(DB, step('project-6-os', 9101, 'expand'))).status, 200);
    assert.equal(db.prepare('SELECT count(*) AS n FROM contract_changes WHERE parent_ticket=?').get(9101).n, 2);
  });

  await t.test('C2 bad input is 400 and no bearer is 401', async () => {
    const { DB, db } = await openDb();
    for (const [body, err] of [
      [step('project-3', 9201, 'drop'), /^step/],
      [step('project-3', 9201, ''), /^step/],
      [step('project-3', 9201, 'Expand'), /^step/],
      [step('', 9201, 'expand'), /^project$/],
      [step('project-3 OS', 9201, 'expand'), /^project$/],
      [step('project-3', 0, 'expand'), /^parent_ticket$/],
      [step('project-3', -3, 'expand'), /^parent_ticket$/],
      [step('project-3', '12x', 'expand'), /^parent_ticket$/],
      [step('project-3', 9201, 'expand', { verdict: 5 }), /^verdict$/],
    ]) {
      const r = await post(DB, body);
      assert.equal(r.status, 400, JSON.stringify(body));
      assert.match(r.body.error, err);
    }
    assert.equal(db.prepare('SELECT count(*) AS n FROM contract_changes').get().n, 0);
    assert.equal((await post(DB, step('project-3', 9201, 'expand'), { bearer: false })).status, 401);
    assert.equal(db.prepare('SELECT count(*) AS n FROM contract_changes').get().n, 0);
    assert.equal((await get(DB, 'project=project-3', { bearer: false })).status, 401);
    assert.equal((await get(DB, '')).status, 400);
    assert.equal((await get(DB, 'project=project-3&step=drop')).status, 400);
  });

  await t.test('C3 GET returns only the asked project, newest first', async () => {
    const { DB, db } = await openDb();
    for (const s of ['expand', 'migrate', 'contract']) assert.equal((await post(DB, step('project-6-os', 9301, s))).status, 200);
    assert.equal((await post(DB, step('project-3', 9302, 'expand', { backup_ref: 'b1' }))).status, 200);
    db.prepare("UPDATE contract_changes SET updated_at='2026-11-01T00:00:00Z' WHERE step='expand' AND project='project-6-os'").run();
    db.prepare("UPDATE contract_changes SET updated_at='2026-11-03T00:00:00Z' WHERE step='migrate'").run();
    db.prepare("UPDATE contract_changes SET updated_at='2026-11-02T00:00:00Z' WHERE step='contract'").run();
    const mk = await get(DB, 'project=project-6-os');
    assert.equal(mk.status, 200, JSON.stringify(mk.body));
    assert.deepEqual(mk.body.rows.map((r) => r.step), ['migrate', 'contract', 'expand']);
    assert.ok(mk.body.rows.every((r) => r.project === 'project-6-os'));
    assert.equal(mk.body.limit, 100);
    const om = await get(DB, 'project=project-3');
    assert.deepEqual(om.body.rows.map((r) => [r.parent_ticket, r.step, r.backup_ref]), [[9302, 'expand', 'b1']]);
    const none = await get(DB, 'project=project-1');
    assert.equal(none.status, 200);
    assert.deepEqual(none.body.rows, []);
    const one = await get(DB, 'project=project-6-os&parent_ticket=9301&step=contract');
    assert.deepEqual(one.body.rows.map((r) => r.step), ['contract']);
    assert.equal((await get(DB, 'project=project-3&parent_ticket=9301&step=expand')).body.rows.length, 0);
  });

  await t.test('C4 limit is capped at the settings row', async () => {
    const { DB, db } = await openDb();
    const ins = db.prepare('INSERT INTO contract_changes (project, parent_ticket, step, created_at, updated_at) VALUES (?,?,?,?,?)');
    for (let i = 0; i < 8; i++) ins.run('cap-os', 9400 + i, 'expand', '2026-11-01T00:00:00Z', isoSec(Date.parse('2026-11-01T00:00:00Z') + i * 1000));
    assert.equal((await get(DB, 'project=cap-os&limit=2')).body.rows.length, 2);
    assert.equal((await get(DB, 'project=cap-os&limit=50')).body.rows.length, 8);
    db.prepare("INSERT OR REPLACE INTO settings (key,value,note,actor,updated_at) VALUES ('lib.contract-change.contract_changes_list_max','3','t','test','2026-11-24T00:00:00Z')").run();
    const capped = await get(DB, 'project=cap-os&limit=50');
    assert.equal(capped.body.limit, 3);
    assert.equal(capped.body.rows.length, 3);
    assert.equal((await get(DB, 'project=cap-os')).body.rows.length, 3);
    assert.equal((await get(DB, 'project=cap-os&limit=0')).status, 400);
  });

  await t.test('C5 EXPLAIN on 10,000 seeded rows uses the indexes', async () => {
    const { db } = await openDb();
    const ins = db.prepare('INSERT INTO contract_changes (project, parent_ticket, step, backup_ref, created_at, updated_at) VALUES (?,?,?,?,?,?)');
    const steps = ['expand', 'migrate', 'contract'];
    const base = Date.parse('2026-01-01T00:00:00Z');
    db.exec('BEGIN');
    for (let i = 0; i < 10000; i++) {
      const ts = isoSec(base + i * 60e3);
      ins.run(`proj-${i % 13}`, Math.floor(i / 3) + 1, steps[i % 3], `b-${i}`, ts, ts);
    }
    db.exec('COMMIT');
    db.exec('ANALYZE');
    const plan = (sql, ...b) => db.prepare(`EXPLAIN QUERY PLAN ${sql}`).all(...b).map((x) => x.detail);
    const { SQL } = await import('../src/routes/contract-changes.js');
    const list = plan(SQL.list, 'proj-3', 100);
    assert.ok(list.some((l) => l.includes('USING INDEX idx_contract_changes_project_updated')), list.join(' | '));
    assert.ok(!list.some((l) => /^SCAN contract_changes\b/.test(l) && !/USING/.test(l)), list.join(' | '));
    assert.ok(!list.some((l) => /TEMP B-TREE/.test(l)), list.join(' | '));
    const one = plan(SQL.listTicketStep, 'proj-3', 5, 'expand', 1);
    assert.ok(one.some((l) => /^SEARCH contract_changes USING INDEX sqlite_autoindex_contract_changes_1/.test(l)), one.join(' | '));
    const { default: RULES } = await import('../src/routes/retention.d/bh-9929-contract-changes.js');
    const ids = plan(RULES[0].ids, '2026-01-02T00:00:00Z', 500);
    assert.ok(ids.some((l) => l.includes('idx_contract_changes_updated')), ids.join(' | '));
  });

  await t.test('C6 retention archives an old row and keeps a fresh one', async () => {
    const { DB, db } = await openDb();
    await post(DB, step('ret-os', 9601, 'expand', { backup_ref: 'old-b' }));
    await post(DB, step('ret-os', 9602, 'expand', { backup_ref: 'new-b' }));
    const old = isoSec(Date.now() - 800 * DAY);  // determinism: ok the retention route cuts at its own clock, so the seed is relative to it
    db.prepare('UPDATE contract_changes SET updated_at=? WHERE parent_ticket=9601').run(old);
    const run = () => req(DB, 'POST', '/api/retention/run', {}).then((r) => r.body);
    const dry = await run();
    assert.equal(dry.dry_run, true);
    assert.equal(dry.rules.find((r) => r.rule === 'contract_changes.archive').counted, 1);
    assert.equal(db.prepare('SELECT count(*) AS n FROM contract_changes').get().n, 2);
    db.prepare("UPDATE settings SET value='0' WHERE key='retention.dry_run'").run();
    const live = await run();
    const rule = live.rules.find((r) => r.rule === 'contract_changes.archive');
    assert.equal(rule.error, null);
    assert.equal(rule.removed, 1);
    assert.deepEqual(db.prepare('SELECT parent_ticket FROM contract_changes').all().map((r) => r.parent_ticket), [9602]);
    const arch = db.prepare('SELECT * FROM contract_changes_archive').all();
    assert.deepEqual(arch.map((r) => [r.parent_ticket, r.backup_ref]), [[9601, 'old-b']]);
    assert.ok(arch[0].archived_at);
  });

  await t.test('C7 GET answers the live verdict of each step PR', async () => {
    const { DB, db } = await openDb();
    const PRU = (n) => `https://github.com/example-org/project-3/pull/${n}`;
    await post(DB, step('live-os', 9701, 'expand', { pr_url: PRU(11), verdict: 'pending' }));
    await post(DB, step('live-os', 9701, 'migrate', { pr_url: PRU(12), verdict: 'pending' }));
    await post(DB, step('live-os', 9701, 'contract', { pr_url: PRU(13), verdict: 'pending' }));
    const H1 = '1'.repeat(40); const H2 = '2'.repeat(40);
    const v = db.prepare('INSERT INTO verdicts (repo, pr, head_sha, verdict, source, reviewer, created_at) VALUES (?,?,?,?,?,?,?)');
    // PR 11: a lead BLOCK on an old head, a lead MERGE on the newest head.
    v.run('example-org/project-3', 11, H1, 'BLOCK', 'lead', 'mac-lead', '2026-11-24T01:00:00Z');
    v.run('example-org/project-3', 11, H2, 'MERGE', 'lead', 'mac-lead', '2026-11-24T02:00:00Z');
    // PR 13: a human MERGE, then a later lead BLOCK on the same head (the human
    // row is final on its head), plus a box row and a retracted lead row.
    v.run('example-org/project-3', 13, H1, 'MERGE', 'human', 'operator', '2026-11-24T03:00:00Z');
    v.run('example-org/project-3', 13, H1, 'BLOCK', 'lead', 'mac-lead', '2026-11-24T04:00:00Z');
    v.run('example-org/project-3', 13, H1, 'BLOCK', 'box', 'hub', '2026-11-24T05:00:00Z');
    const rid = v.run('example-org/project-3', 13, H2, 'BLOCK', 'lead', 'mac-lead', '2026-11-24T06:00:00Z').lastInsertRowid;
    db.prepare('INSERT INTO verdict_retractions (verdict_id, reason, actor, created_at) VALUES (?,?,?,?)')
      .run(rid, 'test', 'operator', '2026-11-24T07:00:00Z');
    const r = await get(DB, 'project=live-os');
    assert.equal(r.status, 200, JSON.stringify(r.body));
    const by = Object.fromEntries(r.body.rows.map((x) => [x.step, x]));
    assert.equal(by.expand.verdict, 'MERGE');
    assert.equal(by.expand.verdict_source, 'lead');
    assert.equal(by.expand.verdict_head, H2);
    assert.equal(by.contract.verdict, 'MERGE');
    assert.equal(by.contract.verdict_source, 'human');
    assert.equal(by.contract.verdict_reviewer, 'operator');
    assert.equal(by.migrate.verdict, 'pending');
    assert.equal(by.migrate.verdict_source, 'recorded');
    // The stored row is not rewritten by a read.
    assert.equal(db.prepare("SELECT verdict FROM contract_changes WHERE step='expand' AND parent_ticket=9701").get().verdict, 'pending');
    const { SQL } = await import('../src/routes/contract-changes.js');
    const plan = db.prepare(`EXPLAIN QUERY PLAN ${SQL.prVerdict}`).all('example-org/project-3', 13).map((x) => x.detail);
    assert.ok(plan.some((l) => l.includes('idx_verdicts_pr_head')), plan.join(' | '));
    assert.ok(!plan.some((l) => /^SCAN verdicts\b/.test(l)), plan.join(' | '));
  });
});
