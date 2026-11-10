// BH-9187 (C0): the staff agent contract, driven through the REAL worker.fetch
// against the composed jobs schema (the node:sqlite D1 shim).
//
//   C1  the same item claimed 3 times: 1 finding row, 1 seen row, seen_count 3,
//       last_checked_at moves; answers 200, 409, 409
//   C1b a finding claimed before BH-9187 (no seen row): the first repeat
//       stores seen_count 2 and first_seen_at = the finding's claimed_at
//   C1c a new finding row over a seen row a deleted finding left: count 1,
//       first_seen_at = now
//   C2  a second agent claims the item: the owner's seen row +1, agent stays
//   C3  a suppressed claim and a staff-filed claim write no seen row
//   C4  a seen upsert that fails leaves the claim answer, plus seen:"unrecorded"
//   C5  the contract settings rows: 7 agents x level/metric/target/file_max_day
//   L1  POST action: idempotent on (agent, lever, key); a different payload on
//       the same key is 409 key_mismatch; a missing or non-number metricBefore
//       is 400; an agent off the roster is 404
//   L2  a sample 23h59m after the action does not settle it
//   L3  a sample at 24h settles it: equal value moved 0, lower value moved 1,
//       and a sample for another metric or agent settles nothing
//   L4  action -> sample at +24h lower -> scorecard actions 1, settled 1,
//       moved 1, precision 1
//   L5  a dry-run action never settles and counts only in dry_runs
//   L6  0 settled -> precision null; metric now and metric 7 days ago from
//       samples at -8d, -6d and now
//   L7  staff.settle_hours is read: 1 h settles a 2 h old action; a bad row
//       uses 24 and the answer says settle_hours_fallback
//   E1  EXPLAIN QUERY PLAN on 50k samples / 20k actions / 20k seen rows: the
//       scorecard reads, the settle UPDATE, the seen upsert and the retention
//       id reads use their named indexes, never a full table scan
//   R1  retention: the dry run deletes 0; a live run deletes only old samples,
//       old SETTLED actions and orphan seen rows
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import { fingerprint } from '../../../agent-core/src/index.js';

const SECRET = 'test-secret';
const ANCHOR = Date.now();  // determinism: ok the single anchor; every seeded time is an offset before it, and the route's clock only moves forward from it
const isoAgo = (s) => new Date(ANCHOR - s * 1000).toISOString().replace(/\.\d{3}Z$/, 'Z');
const H = 3600;
const call = (DB, path, { method = 'POST', body } = {}) => worker.fetch(new Request(`https://jobs.test${path}`, {
  method,
  headers: { authorization: `Bearer ${SECRET}`, 'content-type': 'application/json' },
  body: body === undefined ? undefined : JSON.stringify(body),
}), { DB, HARNESS_SECRET: SECRET }).then(async (res) => ({ status: res.status, body: await res.json().catch(() => null) }));

const claim = (DB, item, { agent = 'watchman', source = {} } = {}) => call(DB, '/api/staff/findings/claim', {
  body: {
    agent, item, title: 'Fixture finding',
    source: { kind: 'alert', url: 'https://example.com/alerts/fixture-1', labels: ['ops'], ...source },
    observedAt: '2026-11-06T00:00:00Z',
  },
});
const seenRows = (db) => db.prepare('SELECT * FROM staff_finding_seen ORDER BY fingerprint').all();
// Each lever test adds its own roster agent, so no two tests share a name.
const addAgent = (db, name) => db.prepare(
  "INSERT INTO staff_agents (name, role, accountable, soul_path, updated_at) VALUES (?, 'fixture', 'operator', 'prompts/staff/x.md', '2026-11-06T00:00:00Z')"
).run(name);
const action = (DB, agent, over = {}) => call(DB, '/api/staff/levers/actions', {
  body: { agent, lever: 'file-fix', target: 'cromford@fixture-sha', dryRun: false, metric: 'hours_behind_main', metricBefore: 5, key: 'fixture-key-1', ...over },
});
const sample = (DB, agent, value, metric = 'hours_behind_main') => call(DB, '/api/staff/levers/metric', { body: { agent, metric, value } });
const scorecard = (DB, agent, q = '') => call(DB, `/api/staff/levers/scorecard?agent=${agent}${q}`, { method: 'GET' });
const backdate = (db, agent, secondsAgo) => db.prepare('UPDATE staff_lever_actions SET acted_at=? WHERE agent=?').run(isoAgo(secondsAgo), agent);
const actions = (db, agent) => db.prepare('SELECT * FROM staff_lever_actions WHERE agent=? ORDER BY id').all(agent);

test('BH-9187 staff contract', async (t) => {
  const probe = await openDb();
  if (probe === null) { t.skip('node:sqlite unavailable in this runtime'); return; }

  await t.test('C1 one row per fingerprint: three claims, seen_count 3', async () => {
    const { DB, db } = await openDb();
    const item = { repo: 'a/b', rule: 'c1-fixture' };
    const r1 = await claim(DB, item);
    assert.equal(r1.status, 200, JSON.stringify(r1.body));
    assert.equal(r1.body.seen_count, 1);
    db.prepare('UPDATE staff_finding_seen SET last_checked_at=?').run(isoAgo(600));
    const r2 = await claim(DB, item);
    const r3 = await claim(DB, item);
    assert.deepEqual([r2.status, r3.status], [409, 409]);
    assert.equal(r3.body.error, 'already_claimed');
    assert.equal(r3.body.seen_count, 3);
    assert.equal(db.prepare('SELECT count(*) AS n FROM staff_findings').get().n, 1);
    const rows = seenRows(db);
    assert.equal(rows.length, 1);
    assert.equal(rows[0].fingerprint, fingerprint(item));
    assert.equal(rows[0].seen_count, 3);
    assert.equal(rows[0].agent, 'watchman');
    assert.ok(rows[0].last_checked_at > isoAgo(600), `last_checked_at did not move: ${rows[0].last_checked_at}`);
    assert.equal(r3.body.last_checked_at, rows[0].last_checked_at);
    assert.equal(r3.body.first_seen_at, rows[0].first_seen_at);
  });

  await t.test('C1b a legacy finding: first repeat is seen_count 2 from claimed_at', async () => {
    const { DB, db } = await openDb();
    const item = { repo: 'a/b', rule: 'c1b-legacy' };
    assert.equal((await claim(DB, item)).status, 200);
    const legacy = isoAgo(20 * 86400);
    db.exec('DELETE FROM staff_finding_seen');                         // the pre-BH-9187 state: a finding, no seen row
    db.prepare('UPDATE staff_findings SET claimed_at=? WHERE fingerprint=?').run(legacy, fingerprint(item));
    const r = await claim(DB, item);
    assert.equal(r.status, 409);
    assert.equal(r.body.seen_count, 2);
    assert.equal(r.body.first_seen_at, legacy);
    const rows = seenRows(db);
    assert.equal(rows.length, 1);
    assert.deepEqual([rows[0].seen_count, rows[0].first_seen_at, rows[0].agent], [2, legacy, 'watchman']);
    assert.equal((await claim(DB, item)).body.seen_count, 3);
  });

  await t.test('C1c a new finding row resets a seen row its deleted finding left', async () => {
    const { DB, db } = await openDb();
    const item = { repo: 'a/b', rule: 'c1c-reborn' };
    const fp = fingerprint(item);
    db.prepare("INSERT INTO staff_finding_seen (fingerprint, agent, seen_count, first_seen_at, last_checked_at) VALUES (?, 'inspector', 40, ?, ?)")
      .run(fp, isoAgo(400 * 86400), isoAgo(600));
    const r = await claim(DB, item);
    assert.equal(r.status, 200, JSON.stringify(r.body));
    assert.equal(r.body.seen_count, 1);
    const rows = seenRows(db);
    assert.deepEqual([rows[0].seen_count, rows[0].agent], [1, 'watchman']);
    assert.equal(rows[0].first_seen_at, r.body.finding.claimed_at ?? rows[0].last_checked_at);
    assert.ok(Date.parse(rows[0].first_seen_at) > Date.parse(isoAgo(60)));
  });

  await t.test('C2 another agent repeats the item: the owner row +1', async () => {
    const { DB, db } = await openDb();
    const item = { repo: 'a/b', rule: 'c2-fixture' };
    assert.equal((await claim(DB, item)).status, 200);
    const r = await claim(DB, item, { agent: 'inspector' });
    assert.equal(r.status, 409);
    assert.equal(r.body.seen_count, 2);
    const rows = seenRows(db);
    assert.equal(rows.length, 1);
    assert.equal(rows[0].agent, 'watchman');
    assert.equal(rows[0].seen_count, 2);
  });

  await t.test('C3 a suppressed or staff-filed claim writes no seen row', async () => {
    const { DB, db } = await openDb();
    const item = { repo: 'a/b', rule: 'c3-fixture' };
    db.prepare("INSERT INTO staff_suppressions (fingerprint, reason, approver, expires_at, status, created_at) VALUES (?, 'fixture noise', 'operator', '2099-01-01T00:00:00Z', 'active', '2026-11-06T00:00:00Z')")
      .run(fingerprint(item));
    const s = await claim(DB, item);
    assert.equal(s.body.error, 'suppressed');
    const f = await claim(DB, { repo: 'a/b', rule: 'c3-own' }, { source: { labels: ['staff:watchman'] } });
    assert.equal(f.body.error, 'staff_filed');
    assert.equal(seenRows(db).length, 0);
    assert.equal(s.body.seen_count, undefined);
  });

  await t.test('C4 a failed seen upsert leaves the claim, and says unrecorded', async () => {
    const { DB, db } = await openDb();
    db.exec('DROP TABLE staff_finding_seen');
    const r = await claim(DB, { repo: 'a/b', rule: 'c4-fixture' });
    assert.equal(r.status, 200, JSON.stringify(r.body));
    assert.equal(r.body.claimed, true);
    assert.equal(r.body.seen, 'unrecorded');
    assert.equal(r.body.seen_count, undefined);
    assert.equal(db.prepare('SELECT count(*) AS n FROM staff_findings').get().n, 1);
  });

  await t.test('C5 the contract settings rows are seeded', async () => {
    const { db } = await openDb();
    const want = {
      inspector: ['hours_behind_main', '2'], clerk: ['needs_count', '300'], dispatcher: ['ready_unqueued_2h', '0'],
      watchman: ['live_unrotated_secrets', '0'], quartermaster: ['orphan_usd_day', '0'],
      millwright: ['failed_bakes_and_broken_boxes', '0'], archivist: ['causes_fixed_by_hand_twice', '0'],
    };
    const get = (k) => (db.prepare('SELECT value FROM settings WHERE key=?').get(k) || {}).value;
    for (const [a, [metric, target]] of Object.entries(want)) {
      assert.equal(get(`staff.${a}.level`), 'observe', a);
      assert.equal(get(`staff.${a}.metric`), metric, a);
      assert.equal(get(`staff.${a}.target`), target, a);
      assert.equal(get(`staff.${a}.file_max_day`), '3', a);
    }
    assert.equal(get('staff.settle_hours'), '24');
    assert.equal(get('staff.scorecard_days'), '7');
    assert.equal(get('staff.scorecard_days_max'), '30');
    assert.equal(get('retention.staff_metric_samples.days'), '90');
    assert.equal(get('retention.staff_lever_actions.days'), '365');
    assert.equal(get('retention.staff_finding_seen.orphan_days'), '1');
  });

  await t.test('L1 actions are idempotent per key and bound to their payload', async () => {
    const { DB, db } = await openDb();
    addAgent(db, 'lv-l1');
    const a = await action(DB, 'lv-l1');
    assert.equal(a.status, 200, JSON.stringify(a.body));
    assert.equal(a.body.existing, undefined);
    assert.match(a.body.action.action_key, /^[0-9a-f]{64}$/);
    const b = await action(DB, 'lv-l1');
    assert.equal(b.status, 200);
    assert.equal(b.body.existing, true);
    assert.equal(b.body.action.id, a.body.action.id);
    assert.equal(actions(db, 'lv-l1').length, 1);
    const c = await action(DB, 'lv-l1', { metricBefore: 6 });
    assert.equal(c.status, 409);
    assert.equal(c.body.error, 'key_mismatch');
    for (const mb of [undefined, 'abc', null, Infinity]) {
      const r = await action(DB, 'lv-l1', { key: 'fixture-key-bad', metricBefore: mb });
      assert.equal(r.status, 400, `metricBefore ${mb}`);
      assert.equal(r.body.error, 'metricBefore');
    }
    assert.equal((await action(DB, 'lv-l1', { key: 'fixture-key-dry', dryRun: 'yes' })).status, 400);
    assert.equal((await action(DB, 'lv-nobody')).status, 404);
    assert.equal(actions(db, 'lv-l1').length, 1);
  });

  await t.test('L2 a sample 23h59m after the action settles nothing', async () => {
    const { DB, db } = await openDb();
    addAgent(db, 'lv-l2');
    await action(DB, 'lv-l2');
    backdate(db, 'lv-l2', 24 * H - 60);
    const s = await sample(DB, 'lv-l2', 1);
    assert.equal(s.status, 200, JSON.stringify(s.body));
    assert.equal(s.body.settled, 0);
    assert.equal(actions(db, 'lv-l2')[0].settled_at, null);
  });

  await t.test('L3 a sample at 24h settles: equal moved 0, lower moved 1, other metric or agent nothing', async () => {
    const { DB, db } = await openDb();
    addAgent(db, 'lv-l3a'); addAgent(db, 'lv-l3b'); addAgent(db, 'lv-l3c');
    for (const a of ['lv-l3a', 'lv-l3b', 'lv-l3c']) { await action(DB, a); backdate(db, a, 24 * H); }
    assert.equal((await sample(DB, 'lv-l3a', 5, 'needs_count')).body.settled, 0);
    assert.equal(actions(db, 'lv-l3a')[0].settled_at, null);
    const eq = await sample(DB, 'lv-l3a', 5);
    assert.equal(eq.body.settled, 1);
    const ra = actions(db, 'lv-l3a')[0];
    assert.equal(ra.moved, 0);
    assert.equal(ra.metric_after, 5);
    const lo = await sample(DB, 'lv-l3b', 4.5);
    assert.equal(lo.body.settled, 1);
    assert.equal(actions(db, 'lv-l3b')[0].moved, 1);
    const hi = await sample(DB, 'lv-l3c', 9);
    assert.equal(hi.body.settled, 1);
    assert.equal(actions(db, 'lv-l3c')[0].moved, 0);
    // A settled row is never settled again.
    assert.equal((await sample(DB, 'lv-l3b', 1)).body.settled, 0);
    assert.equal(actions(db, 'lv-l3b')[0].metric_after, 4.5);
  });

  await t.test('L4 action, lower sample at +24h, scorecard precision 1', async () => {
    const { DB, db } = await openDb();
    addAgent(db, 'lv-l4');
    await action(DB, 'lv-l4');
    backdate(db, 'lv-l4', 24 * H + 5);
    assert.equal((await sample(DB, 'lv-l4', 1)).body.settled, 1);
    const s = await scorecard(DB, 'lv-l4', '&metric=hours_behind_main');
    assert.equal(s.status, 200, JSON.stringify(s.body));
    assert.equal(s.body.actions, 1);
    assert.equal(s.body.settled, 1);
    assert.equal(s.body.moved, 1);
    assert.equal(s.body.precision, 1);
    assert.equal(s.body.metric_now.value, 1);
  });

  await t.test('L5 a dry run never settles and counts only in dry_runs', async () => {
    const { DB, db } = await openDb();
    addAgent(db, 'lv-l5');
    await action(DB, 'lv-l5', { dryRun: true });
    backdate(db, 'lv-l5', 48 * H);
    assert.equal((await sample(DB, 'lv-l5', 0)).body.settled, 0);
    assert.equal(actions(db, 'lv-l5')[0].settled_at, null);
    const s = await scorecard(DB, 'lv-l5', '&metric=hours_behind_main');
    assert.equal(s.body.actions, 0);
    assert.equal(s.body.dry_runs, 1);
    assert.equal(s.body.settled, 0);
  });

  await t.test('L6 precision null with 0 settled; metric now and 7 days ago', async () => {
    const { DB, db } = await openDb();
    // A roster agent with a seeded metric row: the scorecard reads it.
    const ins = db.prepare('INSERT INTO staff_metric_samples (agent, metric, value, sampled_at) VALUES (?,?,?,?)');
    ins.run('inspector', 'hours_behind_main', 8, isoAgo(8 * 86400));
    ins.run('inspector', 'hours_behind_main', 6, isoAgo(6 * 86400));
    ins.run('inspector', 'needs_count', 99, isoAgo(60));
    ins.run('inspector', 'hours_behind_main', 3, isoAgo(30));
    await action(DB, 'inspector');
    const s = await scorecard(DB, 'inspector');
    assert.equal(s.status, 200, JSON.stringify(s.body));
    assert.equal(s.body.metric, 'hours_behind_main');
    assert.equal(s.body.target, 2);
    assert.equal(s.body.level, 'observe');
    assert.equal(s.body.days, 7);
    assert.equal(s.body.metric_now.value, 3);
    assert.equal(s.body.metric_then.value, 8);
    assert.equal(s.body.actions, 1);
    assert.equal(s.body.settled, 0);
    assert.equal(s.body.precision, null);
    for (const q of ['&days=0', '&days=31', '&days=abc']) assert.equal((await scorecard(DB, 'inspector', q)).status, 400, q);
    // The window rows are read: a 5-day default reads the -6d sample as then;
    // a max of 40 accepts days=31.
    db.prepare("UPDATE settings SET value='5' WHERE key='staff.scorecard_days'").run();
    const five = await scorecard(DB, 'inspector');
    assert.equal(five.body.days, 5);
    assert.equal(five.body.metric_then.value, 6);
    db.prepare("UPDATE settings SET value='40' WHERE key='staff.scorecard_days_max'").run();
    assert.equal((await scorecard(DB, 'inspector', '&days=31')).status, 200);
    assert.equal((await scorecard(DB, 'lv-nobody')).status, 404);
  });

  await t.test('L7 staff.settle_hours is read; a bad row falls back to 24', async () => {
    const { DB, db } = await openDb();
    addAgent(db, 'lv-l7');
    await action(DB, 'lv-l7');
    backdate(db, 'lv-l7', 2 * H);
    db.prepare("UPDATE settings SET value='abc' WHERE key='staff.settle_hours'").run();
    const fb = await sample(DB, 'lv-l7', 1);
    assert.equal(fb.body.settled, 0);
    assert.equal(fb.body.settle_hours_fallback, true);
    db.prepare("UPDATE settings SET value='1' WHERE key='staff.settle_hours'").run();
    const ok = await sample(DB, 'lv-l7', 1);
    assert.equal(ok.body.settled, 1);
    assert.equal(ok.body.settle_hours_fallback, undefined);
  });

  await t.test('E1 the hot reads use their indexes at seeded volume', async () => {
    const { db } = await openDb();
    db.exec('BEGIN');
    const s = db.prepare('INSERT INTO staff_metric_samples (agent, metric, value, sampled_at) VALUES (?,?,?,?)');
    for (let i = 0; i < 50000; i++) s.run(`a${i % 50}`, `m${i % 3}`, i, isoAgo(i * 60));
    const a = db.prepare('INSERT INTO staff_lever_actions (action_key, agent, lever, target, dry_run, metric, metric_before, acted_at, settled_at) VALUES (?,?,?,?,?,?,?,?,?)');
    for (let i = 0; i < 20000; i++) a.run(String(i).padStart(64, '0'), `a${i % 50}`, 'l', 't', i % 7 === 0 ? 1 : 0, `m${i % 3}`, 1, isoAgo(i * 300), i % 2 ? isoAgo(i * 300 - 60) : null);
    const f = db.prepare('INSERT INTO staff_finding_seen (fingerprint, agent, seen_count, first_seen_at, last_checked_at) VALUES (?,?,1,?,?)');
    for (let i = 0; i < 20000; i++) f.run(String(i).padStart(64, 'f'), `a${i % 50}`, isoAgo(i * 300), isoAgo(i * 300));
    db.exec('COMMIT');
    db.exec('ANALYZE');
    const plan = (sql, ...b) => db.prepare(`EXPLAIN QUERY PLAN ${sql}`).all(...b).map((x) => x.detail);
    const uses = (lines, idx) => assert.ok(lines.some((l) => l.includes(idx)), `${idx} not used: ${lines.join(' | ')}`);
    const noScan = (lines) => assert.deepEqual(lines.filter((l) => /^SCAN (staff_\w+|s|f)\b/.test(l) && !/USING/.test(l)), [], lines.join(' | '));
    const { SQL } = await import('../src/routes/staff-levers.js');
    const { default: RULES } = await import('../src/routes/retention.d/bh-9187-staff-contract.js');
    for (const [q, idx, b] of [
      [SQL.now, 'idx_staff_metric_samples_agent', ['a1', 'm1']],
      [SQL.then, 'idx_staff_metric_samples_agent', ['a1', 'm1', isoAgo(7 * 86400)]],
      [SQL.counts, 'idx_staff_lever_actions_agent', ['a1', isoAgo(7 * 86400)]],
      [SQL.settle, 'idx_staff_lever_actions_due', [isoAgo(0), 1, 'a1', 'm1', isoAgo(86400)]],
    ]) { const l = plan(q, ...b); uses(l, idx); noScan(l); }
    for (const r of RULES) {
      const l = plan(r.ids, isoAgo(30 * 86400), 500);
      noScan(l);
      for (const sql of [...(r.pre || []), r.del]) noScan(plan(sql, '[1]'));
    }
    uses(plan(RULES.find((r) => r.table === 'staff_metric_samples').ids, isoAgo(86400), 500), 'idx_staff_metric_samples_at');
    uses(plan(RULES.find((r) => r.table === 'staff_lever_actions').ids, isoAgo(86400), 500), 'idx_staff_lever_actions_settled');
    uses(plan(RULES.find((r) => r.table === 'staff_finding_seen').ids, isoAgo(86400), 500), 'idx_staff_finding_seen_checked');
  });

  await t.test('R1 retention: dry run deletes 0; live deletes only the old, settled and orphan rows', async () => {
    const { DB, db } = await openDb();
    const smp = db.prepare('INSERT INTO staff_metric_samples (agent, metric, value, sampled_at) VALUES (?,?,?,?)');
    smp.run('r1', 'm', 1, isoAgo(100 * 86400));   // old: goes
    smp.run('r1', 'm', 2, isoAgo(10 * 86400));    // recent: stays
    const act = db.prepare('INSERT INTO staff_lever_actions (action_key, agent, lever, target, dry_run, metric, metric_before, acted_at, settled_at) VALUES (?,?,?,?,0,?,1,?,?)');
    act.run('1'.repeat(64), 'r1', 'l', 't', 'm', isoAgo(400 * 86400), isoAgo(399 * 86400)); // old settled: goes
    act.run('2'.repeat(64), 'r1', 'l', 't', 'm', isoAgo(400 * 86400), null);               // old unsettled: stays
    act.run('3'.repeat(64), 'r1', 'l', 't', 'm', isoAgo(30 * 86400), isoAgo(29 * 86400));  // recent settled: stays
    const r = await claim(DB, { repo: 'a/b', rule: 'r1-live' });                          // seen row with a finding: stays
    assert.equal(r.status, 200);
    db.prepare('UPDATE staff_finding_seen SET last_checked_at=?').run(isoAgo(5 * 86400)); // old, but its finding lives
    db.prepare("INSERT INTO staff_finding_seen (fingerprint, agent, seen_count, first_seen_at, last_checked_at) VALUES (?, 'watchman', 4, ?, ?)")
      .run('e'.repeat(64), isoAgo(5 * 86400), isoAgo(5 * 86400));                        // orphan, old: goes
    db.prepare("INSERT INTO staff_finding_seen (fingerprint, agent, seen_count, first_seen_at, last_checked_at) VALUES (?, 'watchman', 1, ?, ?)")
      .run('d'.repeat(64), isoAgo(60), isoAgo(60));                                      // orphan, fresh: stays
    const counts = () => [
      db.prepare('SELECT count(*) AS n FROM staff_metric_samples').get().n,
      db.prepare('SELECT count(*) AS n FROM staff_lever_actions').get().n,
      db.prepare('SELECT count(*) AS n FROM staff_finding_seen').get().n,
    ];
    const run = (body = {}) => call(DB, '/api/retention/run', { body });
    const dry = await run();
    assert.equal(dry.status, 200, JSON.stringify(dry.body));
    assert.deepEqual(counts(), [2, 3, 3]);
    db.prepare("UPDATE settings SET value='0' WHERE key='retention.dry_run'").run();
    const liveRun = await run();
    assert.equal(liveRun.status, 200, JSON.stringify(liveRun.body));
    assert.deepEqual(counts(), [1, 2, 2]);
    assert.deepEqual(db.prepare('SELECT action_key FROM staff_lever_actions ORDER BY action_key').all().map((x) => x.action_key[0]), ['2', '3']);
    assert.deepEqual(db.prepare('SELECT fingerprint FROM staff_finding_seen ORDER BY fingerprint').all().map((x) => x.fingerprint[0]).sort(),
      [fingerprint({ repo: 'a/b', rule: 'r1-live' })[0], 'd'].sort());
  });
});
