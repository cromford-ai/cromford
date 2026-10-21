// BH-7716: the placement value `fly-dedicated` (the dedicated lane host).
//   - lane_placement.<lane> or lane_placement.<lane>.<project> = fly-dedicated,
//     for a lane in the settings row lane_dedicated.lanes, routes the lane's
//     rows to the box `fly-dedicated` (bin/lane-run-worker.sh --box
//     fly-dedicated on the machine of the group lane_fleet.group.dedicated).
//     A project row wins over the lane row, as on the hub (lp_decide).
//   - A no-box claim never takes a merge-conductor row of the box (the hub
//     takes it back itself), and takes a blocked-resolver row only after
//     lane_run.group_fallback_s. A group claim (only_prefixes) never does.
//   - GET /api/lane-runs/stats?fleet=dedicated counts the box's rows only and
//     says whether any row is placed on the box (`placed`).
//   - parseGroup takes box, volume, volume_gb and workers.
// The placement rule is tests/fixtures/bh-7716/dedicated-placement-cases.tsv,
// the table the shell side (tests/lane-dedicated-placement.bh-7716-test.sh)
// reads too. Driven through the REAL router over the composed schema.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import { CLAIM_SQL, FLEET_STATS_SQL, REFUSED_SQL } from '../src/routes/lane-runs.js';
import { placementOf, placementsFrom } from '../src/lib/lane-box-placement.js';
import { parseGroup } from '../src/lib/lane-fleet-groups.js';

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
  "INSERT INTO settings (key,value,note,actor,updated_at) VALUES (?,?,'t','t','2026-10-20T00:00:00Z') ON CONFLICT(key) DO UPDATE SET value=excluded.value",
).run(key, value);
// One fixed anchor. A test that uses ago() pins Date to it (mock timers), so the
// worker's own clock read (the fallback cutoff) is the same instant.
const NOW_MS = Date.parse('2026-10-20T12:00:00Z');
const ago = (s) => new Date(NOW_MS - s * 1000).toISOString().replace(/\.\d{3}Z$/, 'Z');
const FRESH = '2099-01-01T00:00:00Z';
const OLD = '2026-01-01T00:00:00Z';
const BOX = 'fly-dedicated';
const DED = { machine: 'mid1-w1', box: BOX };
const CASES = readFileSync(new URL('../../../tests/fixtures/bh-7716/dedicated-placement-cases.tsv', import.meta.url), 'utf8')
  .split('\n').filter((l) => l !== '' && !l.startsWith('#')).map((l) => l.split('\t'));
const SEED = readFileSync(new URL('../schema.d/202610201600-bh-7716-dedicated-lane-host.sql', import.meta.url), 'utf8');
// The group row of the go-live steps (docs/notes/2026-10-20-BH-7716-dedicated-lane-host.md).
const GROUP = readFileSync(new URL('../../../tests/fixtures/bh-7716/dedicated-group.json', import.meta.url), 'utf8').trim();

// rowsOf <case rows column> <lanes_row column> -> settings rows [{key, value}].
const rowsOf = (rows, lanes) => {
  const out = rows.split(';;').map((kv) => {
    const i = kv.indexOf('=');
    return { key: kv.slice(0, i), value: kv.slice(i + 1).replace(/\\n/g, '\n') };
  });
  if (lanes !== '-') out.push({ key: 'lane_dedicated.lanes', value: lanes === '~' ? '' : lanes });
  return out;
};

test('BH-7716 lane_runs placed fly-dedicated', async (t) => {
  const probe = await openDb();
  if (probe === null) { t.skip('node:sqlite unavailable in this runtime'); return; }

  await t.test('P0 every row of the shared case table resolves as the shell resolves it', () => {
    assert.ok(CASES.length >= 20, `read ${CASES.length} rows`);
    let n = 0;
    for (const [lane, proj, rows, lanes, place, box] of CASES) {
      if (proj === '-') continue;
      n += 1;
      const got = placementOf(placementsFrom(rowsOf(rows, lanes)), lane, proj);
      assert.equal(got, place === 'box' ? box : null, `${rows} lanes=${lanes} -> ${lane}|${proj}`);
    }
    assert.ok(n >= 20, `checked ${n} rows`);
  });

  await t.test('S0 the seed: the allow list and the refresh knob; no group row and no lane_placement row; the go-live group row parses', async () => {
    assert.doesNotMatch(SEED, /'lane_placement\./, 'the fragment flips no placement row');
    assert.doesNotMatch(SEED, /'lane_fleet\.group\./, 'the group row is a go-live write');
    const { db } = await openDb();
    const v = (k) => (db.prepare('SELECT value FROM settings WHERE key=?').get(k) || {}).value;
    assert.equal(v('lane_dedicated.lanes'), 'merge-conductor,blocked-resolver');
    assert.equal(v('lane_run.warm_refresh_s'), '300');
    assert.equal(v('lane_fleet.group.dedicated'), undefined);
    const g = parseGroup('dedicated', GROUP, new Set(), new Set(), new Set());
    assert.equal(g.err, undefined, g.err);
    assert.deepEqual(g.group, {
      name: 'dedicated', app: 'lane-run-dedicated', vm_size: 'performance-8x', vm_memory: 16384,
      max_machines: 1, warm_floor: 1, projects: [], box: BOX, volume: 'repos', volume_gb: null, workers: 6,
    });
    assert.equal(db.prepare("SELECT COUNT(*) AS n FROM settings WHERE key LIKE 'lane\\_placement.%' ESCAPE '\\' AND actor='seed' AND value LIKE '%dedicated%'").get().n, 0);
  });

  await t.test('G1 parseGroup: box fields in range; a second group on one box, workers 17, projects on a box group are invalid', () => {
    const ok = (o, boxes = new Set()) => parseGroup('g', JSON.stringify(o), new Set(), new Set(), boxes);
    const base = { app: 'lane-run-ded', max_machines: 1, box: BOX };
    assert.equal(ok(base).group.projects.length, 0, 'projects absent on a box group');
    assert.equal(ok({ ...base, volume_gb: 50, workers: 16 }).group.workers, 16);
    assert.match(ok({ ...base, workers: 17 }).err, /workers/);
    assert.match(ok({ ...base, workers: 0 }).err, /workers/);
    assert.match(ok({ ...base, volume: 'Bad-Name' }).err, /volume/);
    assert.match(ok({ ...base, volume_gb: 501 }).err, /volume_gb/);
    assert.match(ok({ ...base, box: 'bad/name' }).err, /box/);
    assert.match(ok({ ...base, projects: ['project-5'] }).err, /projects/);
    assert.match(ok(base, new Set([BOX])).err, /box/);
    const plain = parseGroup('p', JSON.stringify({ app: 'lane-run-p', max_machines: 2, projects: ['a'] }), new Set(), new Set());
    assert.equal('box' in plain.group, false, 'a projects group answer is unchanged (no box fields)');
    assert.match(parseGroup('p', JSON.stringify({ app: 'lane-run-p', max_machines: 2 }), new Set(), new Set()).err, /projects/,
      'a group without box still needs projects');
  });

  await t.test('G2 GET /api/lane-fleet/groups answers the box fields', async () => {
    const { db, DB } = await openDb();
    setting(db, 'lane_fleet.group.dedicated', GROUP);
    const g = await call(DB, 'GET', '/api/lane-fleet/groups');
    assert.equal(g.status, 200);
    const d = g.body.groups.find((x) => x.name === 'dedicated');
    assert.ok(d, JSON.stringify(g.body));
    assert.equal(d.box, BOX);
    assert.equal(d.volume, 'repos');
    assert.equal(d.workers, 6);
    assert.deepEqual(d.projects, []);
  });

  await t.test('C1 lane row fly-dedicated: the box claim takes merge-conductor and blocked-resolver rows of every project, nothing else', async () => {
    const { db, DB } = await openDb();
    setting(db, 'lane_placement.merge-conductor', 'fly-dedicated');
    setting(db, 'lane_placement.blocked-resolver', ' Fly-Dedicated ');
    const ids = {};
    for (const [l, p] of [['merge-conductor', 'project-5'], ['blocked-resolver', 'project-3'], ['triage', 'project-5'], ['merge-conductor-pr', 'project-5.5.aaaabbbbcccc']]) {
      ids[`${l}|${p}`] = (await enqueue(DB, l, p)).body.id;
      at(db, ids[`${l}|${p}`], FRESH);
    }
    const a = await claim(DB, DED);
    assert.equal(a.status, 200);
    assert.equal(a.body.box, BOX, 'the answer names the box');
    const b = await claim(DB, { ...DED, machine: 'mid1-w2' });
    assert.equal(b.status, 200);
    assert.deepEqual([`${a.body.lane}|${a.body.project}`, `${b.body.lane}|${b.body.project}`].sort(),
      ['blocked-resolver|project-3', 'merge-conductor|project-5']);
    assert.equal((await claim(DB, DED)).status, 204, 'triage and merge-conductor-pr are not the box rows');
    assert.equal(row(db, ids['triage|project-5']).status, 'queued');
    assert.equal(row(db, ids['merge-conductor|project-5']).claimed_by === 'mid1-w1' || row(db, ids['merge-conductor|project-5']).claimed_by === 'mid1-w2', true);
  });

  await t.test('C2 another box never takes a fly-dedicated row; a box:x project row under the lane row goes to box x', async () => {
    const { db, DB } = await openDb();
    setting(db, 'lane_placement.merge-conductor', 'fly-dedicated');
    setting(db, 'lane_placement.merge-conductor.project-6-os', 'box:box-project-6-os-1');
    const a = (await enqueue(DB, 'merge-conductor', 'project-5')).body.id;
    const b = (await enqueue(DB, 'merge-conductor', 'project-6-os')).body.id;
    assert.equal((await claim(DB, { machine: 'other', box: 'other' })).status, 204);
    const x = await claim(DB, { machine: 'box-project-6-os-1', box: 'box-project-6-os-1' });
    assert.equal(x.body.id, b);
    const d = await claim(DB, DED);
    assert.equal(d.body.id, a);
    assert.equal((await claim(DB, DED)).status, 204, 'the box:x row is not the dedicated box\'s');
  });

  await t.test('C3 a project row wins: hub and fly project rows under a fly-dedicated lane row are not the box\'s', async () => {
    const { db, DB } = await openDb();
    setting(db, 'lane_placement.merge-conductor', 'fly-dedicated');
    setting(db, 'lane_placement.merge-conductor.project-3', 'hub');
    setting(db, 'lane_placement.merge-conductor.project-4', 'fly');
    const ded = (await enqueue(DB, 'merge-conductor', 'project-5')).body.id;
    const fly = (await enqueue(DB, 'merge-conductor', 'project-4')).body.id;
    const hub = (await enqueue(DB, 'merge-conductor', 'project-3')).body.id;
    assert.equal((await claim(DB, DED)).body.id, ded);
    assert.equal((await claim(DB, DED)).status, 204);
    const f = await claim(DB, {});
    assert.ok([fly, hub].includes(f.body.id), 'a Fly claim takes the fly (and the hub) project row');
    assert.notEqual(f.body.id, ded);
  });

  await t.test('C4 a no-box claim: merge-conductor never (any age); blocked-resolver at 899 s no, 901 s yes; 0 = never; a group claim never', async (st) => {
    st.mock.timers.enable({ apis: ['Date'], now: NOW_MS });
    const { db, DB } = await openDb();
    setting(db, 'lane_placement.merge-conductor', 'fly-dedicated');
    setting(db, 'lane_placement.blocked-resolver', 'fly-dedicated');
    setting(db, 'lane_run.group_fallback_s', '900');
    const mc = (await enqueue(DB, 'merge-conductor', 'project-5')).body.id;
    const br = (await enqueue(DB, 'blocked-resolver', 'project-5')).body.id;
    at(db, mc, OLD);
    at(db, br, ago(899));
    assert.equal((await claim(DB, {})).status, 204, 'blocked-resolver at 899 s and merge-conductor at any age stay the box\'s');
    at(db, br, ago(901));
    assert.equal((await claim(DB, { only_prefixes: ['project-5.'] })).status, 204, 'a group claim never falls back');
    const c = await claim(DB, {});
    assert.equal(c.status, 200);
    assert.equal(c.body.id, br, 'the default fleet takes the blocked-resolver row past the fallback');
    assert.equal(c.body.box, undefined);
    assert.equal((await claim(DB, {})).status, 204, 'the merge-conductor row never falls back');
    assert.equal(row(db, mc).status, 'queued');
    db.prepare("UPDATE lane_runs SET status='queued', claimed_by=NULL, lease_until=NULL WHERE id=?").run(br);
    setting(db, 'lane_run.group_fallback_s', '0');
    assert.equal((await claim(DB, {})).status, 204, 'group_fallback_s 0 = never');
    assert.equal((await claim(DB, DED)).status, 200, 'the box still takes it');
  });

  await t.test('C5 an expired lease of <mid>-w1 is reclaimed by <mid>-w2; a release keeps attempts', async () => {
    const { db, DB } = await openDb();
    setting(db, 'lane_placement.merge-conductor', 'fly-dedicated');
    const id = (await enqueue(DB, 'merge-conductor', 'project-5')).body.id;
    assert.equal((await claim(DB, DED)).body.id, id);
    db.prepare('UPDATE lane_runs SET lease_until=? WHERE id=?').run(OLD, id);
    const c2 = await claim(DB, { ...DED, machine: 'mid1-w2' });
    assert.equal(c2.body.id, id);
    assert.equal(row(db, id).claimed_by, 'mid1-w2');
    assert.equal(row(db, id).attempts, 2);
    const r = await call(DB, 'POST', `/api/lane-runs/${id}/release`, { machine: 'mid1-w2' });
    assert.equal(r.status, 200);
    assert.equal(row(db, id).status, 'queued');
    assert.equal(row(db, id).attempts, 2, 'attempts kept');
    assert.equal((await claim(DB, { ...DED, machine: 'mid1-w3' })).body.id, id);
  });

  await t.test('C6 skip_prefixes on a Fly claim never ends a fly-dedicated row (REFUSED_SQL)', async () => {
    const { db, DB } = await openDb();
    setting(db, 'lane_placement.merge-conductor', 'fly-dedicated');
    const id = (await enqueue(DB, 'merge-conductor', 'project-5')).body.id;
    const ctl = (await enqueue(DB, 'triage', 'project-5')).body.id;
    at(db, id, OLD); at(db, ctl, OLD);
    await claim(DB, { skip_prefixes: ['project-5'] });
    assert.equal(row(db, id).status, 'queued');
    assert.equal(row(db, ctl).status, 'died', 'control: the Fly row is refused and ended');
  });

  await t.test('T1 stats: fleet=dedicated counts the box rows and says placed; default does not count them; rollback = placed false', async () => {
    const { db, DB } = await openDb();
    assert.equal((await call(DB, 'GET', '/api/lane-runs/stats?fleet=dedicated')).status, 400, 'no group row = no fleet');
    setting(db, 'lane_fleet.group.dedicated', GROUP);
    let s = await call(DB, 'GET', '/api/lane-runs/stats?fleet=dedicated');
    assert.equal(s.status, 200);
    assert.equal(s.body.placed, false, 'nothing placed yet');
    assert.equal(s.body.box, BOX);
    assert.deepEqual(s.body.lanes, []);
    setting(db, 'lane_placement.merge-conductor', 'fly-dedicated');
    const id = (await enqueue(DB, 'merge-conductor', 'project-5')).body.id;
    at(db, id, OLD);
    await enqueue(DB, 'triage', 'project-5');
    s = await call(DB, 'GET', '/api/lane-runs/stats?fleet=dedicated&run_p50=1');
    assert.equal(s.body.placed, true);
    assert.deepEqual(s.body.lanes.map((l) => [l.lane, l.queued]), [['merge-conductor', 1]]);
    for (const q of ['?fleet=default', '']) {
      const d = await call(DB, 'GET', `/api/lane-runs/stats${q}`);
      const mc = d.body.lanes.find((l) => l.lane === 'merge-conductor');
      assert.ok(!mc || mc.queued === 0, `${q || 'plain'}: the box row is not Fly work`);
      assert.equal(d.body.lanes.find((l) => l.lane === 'triage').queued, 1);
    }
    setting(db, 'lane_placement.merge-conductor', 'hub');
    s = await call(DB, 'GET', '/api/lane-runs/stats?fleet=dedicated');
    assert.equal(s.body.placed, false, 'rollback: the row back to hub');
    assert.deepEqual(s.body.lanes, []);
  });

  await t.test('T2 stats fleet=default counts a blocked-resolver box row past the fallback', async (st) => {
    st.mock.timers.enable({ apis: ['Date'], now: NOW_MS });
    const { db, DB } = await openDb();
    setting(db, 'lane_placement.blocked-resolver', 'fly-dedicated');
    setting(db, 'lane_run.group_fallback_s', '900');
    const id = (await enqueue(DB, 'blocked-resolver', 'project-5')).body.id;
    at(db, id, ago(899));
    let d = await call(DB, 'GET', '/api/lane-runs/stats?fleet=default');
    assert.equal(d.body.lanes.find((l) => l.lane === 'blocked-resolver'), undefined);
    at(db, id, ago(901));
    d = await call(DB, 'GET', '/api/lane-runs/stats?fleet=default');
    assert.equal(d.body.lanes.find((l) => l.lane === 'blocked-resolver').queued, 1);
  });

  await t.test('E1 EXPLAIN QUERY PLAN on 20 000 rows: the dedicated binds keep idx_lane_runs_claim', async () => {
    const { db } = await openDb();
    const ins = db.prepare(`INSERT INTO lane_runs (lane, project, args_json, enqueued_at, status, attempts, rc, finished_at)
                            VALUES (?,?,?,?,?,?,?,?)`);
    const projects = ['project-6-os', 'project-5', 'project-3', 'project-4', 'project-2'];
    db.exec('BEGIN');
    for (let i = 0; i < 20000; i++) {
      const ts = new Date(Date.UTC(2026, 9, 1) + i * 60e3).toISOString().replace(/\.\d{3}Z$/, 'Z');
      const queued = i >= 19800;
      ins.run(i % 2 ? 'merge-conductor' : 'blocked-resolver', projects[i % 5] + (i < 19990 ? `-${i}` : ''),
        '["bin/x.sh"]', ts, queued ? 'queued' : 'done', queued ? 0 : 1, queued ? null : 0, queued ? null : ts);
    }
    db.exec('COMMIT');
    db.exec('ANALYZE');
    const T0 = '2026-10-15T00:00:00Z';
    const keys = '["merge-conductor|*","blocked-resolver|*"]';
    const ex = '["merge-conductor|project-3"]';
    const fbk = '["blocked-resolver|*"]';
    const plan = (sql, binds) => db.prepare(`EXPLAIN QUERY PLAN ${sql}`).all(...binds).map((r) => r.detail);
    const idx = (p) => p.some((l) => /lane_runs USING (COVERING )?INDEX idx_lane_runs_claim/.test(l));
    const scan = (p) => p.some((l) => /^SCAN lane_runs\b(?!.*USING)/.test(l));
    const claimB = (only, skip) => ['m1', T0, '2026-10-15T00:02:00Z', null, null, null, null, null, null, null, only, skip, ex, fbk, T0];
    for (const [name, sql, b] of [
      ['claim box', CLAIM_SQL, claimB(keys, null)],
      ['claim fly', CLAIM_SQL, claimB(null, keys)],
      ['refused', REFUSED_SQL, [T0, T0, null, '["x"]', 'p', null, null, null, null, keys, ex, fbk, T0]],
      ['fleet stats default', FLEET_STATS_SQL, [null, null, null, null, T0, keys, ex, fbk, T0, null]],
      ['fleet stats box', FLEET_STATS_SQL, [null, null, null, null, T0, null, ex, null, null, keys]]]) {
      const p = plan(sql, b);
      assert.ok(idx(p), `${name}: ${p.join(' | ')}`);
      assert.ok(!scan(p), `${name} no full SCAN: ${p.join(' | ')}`);
    }
    const r = db.prepare(CLAIM_SQL).get(...claimB(keys, null));
    assert.ok(r && ['merge-conductor', 'blocked-resolver'].includes(r.lane), `box claim got ${r && `${r.lane}|${r.project}`}`);
  });
});
