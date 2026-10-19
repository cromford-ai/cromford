// BH-7434: lane-run fleet groups. A group is a settings row
// lane_fleet.group.<name> = {app, vm_size, vm_memory, max_machines, projects}.
//   - POST /api/lane-runs/claim takes `only_prefixes`: a machine of a group
//     claims only rows whose `project || '.'` starts with one of them, so
//     `project-6-os.` names project-6-os and its merge-conductor rows.
//   - A claim without only_prefixes (the default fleet) never takes a row of a
//     grouped project, except a queued row that waited longer than
//     lane_run.group_fallback_s (the group fleet is down or behind).
//   - The group skip never withdraws a row (REFUSED_SQL is skip_prefixes only).
//   - GET /api/lane-runs/stats?fleet=<group|default> counts only that fleet's
//     queued rows through idx_lane_runs_claim; GET /api/lane-fleet/groups lists
//     the valid groups; GET /api/lane-fleet/machines?app= scopes the rows.
// Driven through the REAL router over the composed schema (node:sqlite shim).
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import { CLAIM_SQL, FLEET_STATS_SQL } from '../src/routes/lane-runs.js';

const SECRET = 'fixture-harness-secret';
const call = (DB, method, path, body) => {
  const headers = { 'content-type': 'application/json', authorization: `Bearer ${SECRET}` };
  const req = new Request(`https://jobs.test${path}`, {
    method, headers, body: body === undefined ? undefined : JSON.stringify(body),
  });
  return worker.fetch(req, { DB, HARNESS_SECRET: SECRET })
    .then(async (res) => ({ status: res.status, body: await res.json().catch(() => null) }));
};
const enqueue = (DB, lane, project) => call(DB, 'POST', '/api/lane-runs', { lane, project, args: ['bin/x.sh'] });
const claim = (DB, extra = {}) => call(DB, 'POST', '/api/lane-runs/claim', { machine: 'm1', ...extra });
const row = (db, id) => db.prepare('SELECT * FROM lane_runs WHERE id = ?').get(id);
const at = (db, id, ts) => db.prepare('UPDATE lane_runs SET enqueued_at=? WHERE id=?').run(ts, id);
const setting = (db, key, value) => db.prepare(
  "INSERT INTO settings (key,value,note,actor,updated_at) VALUES (?,?,'t','t','2026-10-19T00:00:00Z') ON CONFLICT(key) DO UPDATE SET value=excluded.value",
).run(key, value);
// OLD waited far past any fallback; FRESH (2099) has not waited at all.
const OLD = '2026-01-01T00:00:00Z';
const FRESH = '2099-01-01T00:00:00Z';
const MK = JSON.stringify({ app: 'lane-run-mk', vm_size: 'performance-4x', vm_memory: 8192, max_machines: 4, projects: ['project-6-os'] });
const TS = JSON.stringify({ app: 'lane-run-ts', vm_size: 'shared-cpu-4x', vm_memory: 4096, max_machines: 2, projects: ['project-5'] });
const drain = async (DB, extra) => {
  const got = [];
  for (;;) {
    const c = await claim(DB, extra);
    if (c.status !== 200) { assert.equal(c.status, 204); break; }
    got.push(c.body.project);
  }
  return got.sort();
};

test('BH-7434 lane-run fleet groups', async (t) => {
  const probe = await openDb();
  if (probe === null) { t.skip('node:sqlite unavailable in this runtime'); return; }

  await t.test('G1 only_prefixes [project-6-os.] takes project-6-os rows only, never project-5 or project-6-os-x', async () => {
    const { db, DB } = await openDb();
    const ids = {};
    for (const [lane, p] of [['triage', 'project-6-os'], ['merge-conductor-pr', 'project-6-os.5.aaaabbbbcccc'],
      ['triage', 'project-5'], ['triage', 'project-6-os-x'], ['merge-conductor-pr', 'project-5.9.aaaabbbbcccc']]) {
      ids[p] = (await enqueue(DB, lane, p)).body.id;
      at(db, ids[p], FRESH);
    }
    const got = await drain(DB, { only_prefixes: ['project-6-os.'] });
    assert.deepEqual(got, ['project-6-os', 'project-6-os.5.aaaabbbbcccc']);
    for (const p of ['project-5', 'project-6-os-x', 'project-5.9.aaaabbbbcccc']) {
      assert.equal(row(db, ids[p]).status, 'queued', `${p} stays queued`);
      assert.equal(row(db, ids[p]).attempts, 0);
    }
  });

  await t.test('G2 a bad only_prefixes answers 400 and changes no row', async () => {
    const { db, DB } = await openDb();
    await enqueue(DB, 'triage', 'project-6-os');
    const before = JSON.stringify(db.prepare('SELECT * FROM lane_runs').all());
    for (const v of ['x', [''], ['a/b'], [7], ['a'.repeat(66)], Array.from({ length: 65 }, (_, i) => `p${i}.`), { p: 1 }]) {
      const c = await claim(DB, { only_prefixes: v });
      assert.equal(c.status, 400, `400 for ${JSON.stringify(v).slice(0, 40)}`);
      assert.match(c.body.error, /only_prefixes/);
    }
    assert.equal(JSON.stringify(db.prepare('SELECT * FROM lane_runs').all()), before);
  });

  await t.test('G3 the default fleet skips every grouped project; ungrouped rows are claimed', async () => {
    const { db, DB } = await openDb();
    setting(db, 'lane_fleet.group.project-6', MK);
    setting(db, 'lane_fleet.group.project-5', TS);
    const ids = {};
    for (const [lane, p] of [['triage', 'project-6-os'], ['merge-conductor-pr', 'project-6-os.5.aaaabbbbcccc'],
      ['triage', 'project-5'], ['triage', 'project-3'], ['triage', 'project-6-os-x']]) {
      ids[p] = (await enqueue(DB, lane, p)).body.id;
      at(db, ids[p], FRESH);
    }
    assert.deepEqual(await drain(DB, {}), ['project-6-os-x', 'project-3']);
    for (const p of ['project-6-os', 'project-6-os.5.aaaabbbbcccc', 'project-5']) {
      assert.equal(row(db, ids[p]).status, 'queued', `${p} waits for its group fleet`);
    }
    assert.deepEqual(await drain(DB, { only_prefixes: ['project-5.'] }), ['project-5']);
  });

  await t.test('G4 no group row: the default claim is today (takes every project, oldest first)', async () => {
    const { db, DB } = await openDb();
    const a = await enqueue(DB, 'triage', 'project-6-os'); at(db, a.body.id, '2026-10-15T00:00:00Z');
    const b = await enqueue(DB, 'triage', 'project-5'); at(db, b.body.id, '2026-10-15T00:00:01Z');
    const c = await claim(DB);
    assert.equal(c.body.id, a.body.id);
    assert.equal((await claim(DB)).body.id, b.body.id);
  });

  await t.test('G5 fallback: a grouped row that waited past lane_run.group_fallback_s is claimable by the default fleet', async () => {
    const { db, DB } = await openDb();
    setting(db, 'lane_fleet.group.project-6', MK);
    const old = await enqueue(DB, 'triage', 'project-6-os'); at(db, old.body.id, OLD);
    const fresh = await enqueue(DB, 'merge-conductor-pr', 'project-6-os.5.aaaabbbbcccc'); at(db, fresh.body.id, FRESH);
    const c = await claim(DB);
    assert.equal(c.status, 200);
    assert.equal(c.body.id, old.body.id, 'the stale grouped row falls back');
    assert.equal((await claim(DB)).status, 204, 'the fresh grouped row still waits for its fleet');
    // 0 = never fall back.
    const { db: db2, DB: DB2 } = await openDb();
    setting(db2, 'lane_fleet.group.project-6', MK);
    setting(db2, 'lane_run.group_fallback_s', '0');
    const o2 = await enqueue(DB2, 'triage', 'project-6-os'); at(db2, o2.body.id, OLD);
    assert.equal((await claim(DB2)).status, 204);
    assert.equal(row(db2, o2.body.id).status, 'queued');
  });

  await t.test('G5b fallback covers a grouped row claimed with an expired lease (its group machine died)', async () => {
    const { db, DB } = await openDb();
    setting(db, 'lane_fleet.group.project-6', MK);
    const r = await enqueue(DB, 'triage', 'project-6-os');
    db.prepare("UPDATE lane_runs SET status='claimed', claimed_by='mkdead', claimed_at=?, lease_until=?, enqueued_at=?, attempts=1 WHERE id=?")
      .run(OLD, '2026-01-01T00:02:00Z', OLD, r.body.id);
    const st = await call(DB, 'GET', '/api/lane-runs/stats?fleet=default');
    assert.equal(st.body.lanes.find((l) => l.lane === 'triage').queued, 1, 'the default fleet\'s scale signal counts it');
    const c = await claim(DB);
    assert.equal(c.status, 200);
    assert.equal(c.body.id, r.body.id, 'the default fleet takes the dead claim');
    // A fresh grouped row whose claim expired still waits for its own fleet.
    const f = await enqueue(DB, 'triage2', 'project-6-os');
    db.prepare("UPDATE lane_runs SET status='claimed', claimed_by='mkdead', claimed_at=?, lease_until=?, enqueued_at=? WHERE id=?")
      .run(OLD, '2026-01-01T00:02:00Z', FRESH, f.body.id);
    assert.equal((await claim(DB)).status, 204);
  });

  await t.test('G6 the group skip never withdraws a row (skip_prefixes still does)', async () => {
    const { db, DB } = await openDb();
    setting(db, 'lane_fleet.group.project-6', MK);
    setting(db, 'lane_run.group_fallback_s', '0');
    const g = await enqueue(DB, 'merge-conductor-pr', 'project-6-os.5.aaaabbbbcccc'); at(db, g.body.id, OLD);
    const s = await enqueue(DB, 'merge-conductor-pr', 'px.1.aaaabbbbcccc'); at(db, s.body.id, OLD);
    assert.equal((await claim(DB, { skip_prefixes: ['px.'] })).status, 204);
    assert.equal(row(db, g.body.id).status, 'queued', 'the grouped row is not withdrawn');
    assert.equal(row(db, s.body.id).status, 'died', 'the skipped row is withdrawn as before');
  });

  await t.test('G6b skip_prefixes withdraws only rows of its own fleet: never a grouped row, never another group\'s', async () => {
    const { db, DB } = await openDb();
    setting(db, 'lane_fleet.group.project-6', MK);
    setting(db, 'lane_run.group_fallback_s', '0');
    const g = await enqueue(DB, 'merge-conductor-pr', 'project-6-os.5.aaaabbbbcccc'); at(db, g.body.id, OLD);
    const d = await enqueue(DB, 'merge-conductor-pr', 'project-3.7.aaaabbbbcccc'); at(db, d.body.id, OLD);
    // A default machine that cannot read either repo.
    assert.equal((await claim(DB, { skip_prefixes: ['project-6-os.', 'project-3.'] })).status, 204);
    assert.equal(row(db, g.body.id).status, 'queued', 'the grouped row is the group fleet\'s to refuse');
    assert.equal(row(db, d.body.id).status, 'died', 'the default fleet\'s own row is withdrawn as before');
    // A group machine that cannot read project-3 never ends it either.
    const d2 = await enqueue(DB, 'merge-conductor-pr', 'project-3.8.aaaabbbbcccc'); at(db, d2.body.id, OLD);
    assert.equal((await claim(DB, { only_prefixes: ['project-6-os.'], skip_prefixes: ['project-3.'] })).status, 200);
    assert.equal(row(db, d2.body.id).status, 'queued');
  });

  await t.test('G7 GET /api/lane-fleet/groups: valid groups by name, invalid rows named and ignored', async () => {
    const { db, DB } = await openDb();
    assert.deepEqual((await call(DB, 'GET', '/api/lane-fleet/groups')).body.groups, [], 'no row = no group');
    setting(db, 'lane_fleet.group.project-5', TS);
    setting(db, 'lane_fleet.group.project-6', MK);
    setting(db, 'lane_fleet.group.badjson', '{nope');
    setting(db, 'lane_fleet.group.badapp', JSON.stringify({ app: 'builder-x', projects: ['project-3'] }));
    setting(db, 'lane_fleet.group.zdupe', JSON.stringify({ app: 'lane-run-dupe', max_machines: 1, projects: ['project-5'] }));
    setting(db, 'lane_fleet.group.Bad_Name', JSON.stringify({ app: 'lane-run-bn', max_machines: 1, projects: ['project-3'] }));
    setting(db, 'lane_fleet.group.nomax', JSON.stringify({ app: 'lane-run-nm', projects: ['project-3'] }));
    setting(db, 'lane_fleet.group.zeromax', JSON.stringify({ app: 'lane-run-zm', max_machines: 0, projects: ['project-3'] }));
    const r = await call(DB, 'GET', '/api/lane-fleet/groups');
    assert.equal(r.status, 200);
    assert.deepEqual(r.body.groups.map((g) => g.name), ['project-6', 'project-5']);
    assert.deepEqual(r.body.groups[0], {
      name: 'project-6', app: 'lane-run-mk', vm_size: 'performance-4x', vm_memory: 8192, max_machines: 4,
      warm_floor: null, projects: ['project-6-os'],
    });
    assert.deepEqual(r.body.invalid.map((g) => g.name).sort(), ['Bad_Name', 'badapp', 'badjson', 'nomax', 'zdupe', 'zeromax']);
    // An invalid row groups nothing: project-3 is still the default fleet's.
    const o = await enqueue(DB, 'triage', 'project-3'); at(db, o.body.id, FRESH);
    assert.equal((await claim(DB)).body.project, 'project-3');
  });

  await t.test('G8 stats ?fleet=: each fleet counts its own queued rows; unknown fleet 400; no fleet = today', async () => {
    const { db, DB } = await openDb();
    setting(db, 'lane_fleet.group.project-6', MK);
    for (const [lane, p, ts] of [['triage', 'project-6-os', FRESH], ['merge-conductor-pr', 'project-6-os.5.aaaabbbbcccc', OLD],
      ['triage', 'project-3', FRESH], ['review', 'project-3', FRESH]]) {
      at(db, (await enqueue(DB, lane, p)).body.id, ts);
    }
    const g = await call(DB, 'GET', '/api/lane-runs/stats?run_p50=1&fleet=project-6');
    assert.equal(g.status, 200);
    const q = (b) => Object.fromEntries(b.lanes.map((l) => [l.lane, l.queued]));
    assert.deepEqual(q(g.body), { 'merge-conductor-pr': 1, triage: 1 });
    assert.ok(g.body.lanes.find((l) => l.lane === 'merge-conductor-pr').oldest_queued_wait_s > 1000);
    const d = await call(DB, 'GET', '/api/lane-runs/stats?run_p50=1&fleet=default');
    // The OLD project-6-os merge row is past the fallback: the default fleet counts it too.
    assert.deepEqual(q(d.body), { 'merge-conductor-pr': 1, review: 1, triage: 1 });
    assert.equal((await call(DB, 'GET', '/api/lane-runs/stats?fleet=nosuch')).status, 400);
    assert.equal((await call(DB, 'GET', '/api/lane-runs/stats?fleet=Bad!')).status, 400);
    const all = await call(DB, 'GET', '/api/lane-runs/stats');
    assert.deepEqual(q(all.body), { 'merge-conductor-pr': 1, review: 1, triage: 2 });
    assert.equal(typeof all.body.lanes[0].done, 'number', 'no fleet: the full counts, as today');
  });

  await t.test('G9 machines ?app= scopes rows and last_failed_at; POST takes app', async () => {
    const { DB } = await openDb();
    const post = (b) => call(DB, 'POST', '/api/lane-fleet/machines', b);
    assert.equal((await post({ machine_id: 'aaaa00000001', state: 'started' })).status, 201);
    assert.equal((await post({ machine_id: 'bbbb00000001', state: 'started', app: 'lane-run-mk' })).status, 201);
    assert.equal((await post({ machine_id: 'bbbb00000002', state: 'stopped', app: 'lane-run-mk', failed: true })).status, 201);
    assert.equal((await post({ machine_id: 'cccc00000001', state: 'started', app: 'Bad App' })).status, 400);
    const ids = (b) => b.machines.map((m) => m.machine_id);
    const all = await call(DB, 'GET', '/api/lane-fleet/machines');
    assert.deepEqual(ids(all.body).sort(), ['aaaa00000001', 'bbbb00000001'], 'no app: every row, as today');
    const d = await call(DB, 'GET', '/api/lane-fleet/machines?app=lane-run');
    assert.deepEqual(ids(d.body), ['aaaa00000001']);
    assert.equal(d.body.last_failed_at, null, 'a group failure does not hold the default fleet');
    const g = await call(DB, 'GET', '/api/lane-fleet/machines?app=lane-run-mk');
    assert.deepEqual(ids(g.body), ['bbbb00000001']);
    assert.ok(g.body.last_failed_at);
    assert.equal((await call(DB, 'GET', '/api/lane-fleet/machines?app=Bad%20App')).status, 400);
  });

  await t.test('G10 EXPLAIN QUERY PLAN on 20 000 rows: only_prefixes, the group skip and the fleet stats keep idx_lane_runs_claim', async () => {
    const { db } = await openDb();
    const ins = db.prepare(`INSERT INTO lane_runs (lane, project, args_json, enqueued_at, status, attempts, rc, finished_at)
                            VALUES (?,?,?,?,?,?,?,?)`);
    const projects = ['project-6-os', 'project-5', 'project-3', 'project-4', 'project-2'];
    db.exec('BEGIN');
    for (let i = 0; i < 20000; i++) {
      const ts = new Date(Date.UTC(2026, 9, 1) + i * 60e3).toISOString().replace(/\.\d{3}Z$/, 'Z');
      const queued = i >= 19800;
      ins.run(i % 2 ? 'triage' : 'merge-conductor-pr', i % 2 ? `${projects[i % 5]}-${i}` : `${projects[i % 5]}.${i}.aaaabbbbcccc`,
        '["bin/x.sh"]', ts, queued ? 'queued' : 'done', queued ? 0 : 1, queued ? null : 0, queued ? null : ts);
    }
    db.exec('COMMIT');
    db.exec('ANALYZE');
    const T0 = '2026-10-15T00:00:00Z';
    const plan = (sql, binds) => db.prepare(`EXPLAIN QUERY PLAN ${sql}`).all(...binds).map((r) => r.detail);
    const claimBinds = (only, gskip, cutoff) => ['m1', T0, '2026-10-15T00:02:00Z', null, null, null, null, only, gskip, cutoff];
    const base = plan(CLAIM_SQL, claimBinds(null, null, null));
    const lr = (lines) => lines.filter((l) => /\blane_runs\b/.test(l));
    for (const [name, b] of [['only', claimBinds('["project-6-os."]', null, null)],
      ['group skip', claimBinds(null, '["project-6-os.","project-5."]', '2026-10-14T23:45:00Z')]]) {
      const p = plan(CLAIM_SQL, b);
      assert.deepEqual(lr(p), lr(base), `${name}: the same lane_runs access path as the plain claim`);
      assert.ok(p.some((l) => /lane_runs USING (COVERING )?INDEX idx_lane_runs_claim/.test(l)), `${name}: ${p.join(' | ')}`);
      assert.ok(!p.some((l) => /^SCAN lane_runs\b(?!.*USING)/.test(l)), `${name}: no full SCAN: ${p.join(' | ')}`);
    }
    const r = db.prepare(CLAIM_SQL).get(...claimBinds('["project-6-os."]', null, null));
    assert.ok(r && /^project-6-os\./.test(r.project), `claimed ${r && r.project}`);
    for (const b of [[null, '["project-6-os."]', null, null, T0], [null, null, '["project-6-os."]', '2026-10-14T23:45:00Z', T0]]) {
      const p = plan(FLEET_STATS_SQL, b);
      assert.ok(p.some((l) => /lane_runs USING (COVERING )?INDEX idx_lane_runs_claim/.test(l)), `fleet stats: ${p.join(' | ')}`);
      assert.ok(!p.some((l) => /^SCAN lane_runs\b(?!.*USING)/.test(l)), `fleet stats no full SCAN: ${p.join(' | ')}`);
    }
  });
});
