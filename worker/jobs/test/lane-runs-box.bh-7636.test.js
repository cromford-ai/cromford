// BH-7636: placement `box:<name>` for merge-conductor and fly-pool.
//   - lane_placement.<lane>.<project> = box:<name> (a PROJECT row of lane
//     merge-conductor or fly-pool only) routes that (lane, project) row to the
//     named box: POST /api/lane-runs/claim with `box: <name>` takes only the
//     rows placed on that box, and a claim without `box` (every Fly machine)
//     never takes them, at any age, and never ends them through REFUSED_SQL.
//   - A box claim that owns no row answers 204 with no lane_runs statement.
//   - GET /api/lane-runs/stats (plain and ?fleet=) does not count a box row,
//     so a box row never sizes a Fly fleet.
//   - POST /api/lane-runs/<id>/withdraw with `expired: 1` also ends a claimed
//     row whose lease ran out (the hub's box-silent take-back).
//   - GET /api/lane-runs/by-prefix rows carry lease_until.
// The parse rule is tests/fixtures/bh-7636/box-placement-cases.tsv, the table
// the shell side (tests/lane-placement-box.bh-7636-test.sh) reads too.
// Driven through the REAL router over the composed schema (node:sqlite shim).
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import { CLAIM_SQL, FLEET_STATS_SQL, REFUSED_SQL } from '../src/routes/lane-runs.js';
import { boxPlacementsFrom, parseBoxValue } from '../src/lib/lane-box-placement.js';

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
const OLD = '2026-01-01T00:00:00Z';
const FRESH = '2099-01-01T00:00:00Z';
const BOX = 'box-project-6-os-1';
const MKEY = 'lane_placement.merge-conductor.project-6-os';
const MK = JSON.stringify({ app: 'lane-run-mk', max_machines: 4, projects: ['project-6-os'] });
const drain = async (DB, extra) => {
  const got = [];
  for (;;) {
    const c = await claim(DB, extra);
    if (c.status !== 200) { assert.equal(c.status, 204); break; }
    got.push(`${c.body.lane}|${c.body.project}`);
  }
  return got.sort();
};
// The four rows every claim case starts from, all FRESH unless moved.
const seedRows = async (db, DB) => {
  const ids = {};
  for (const [lane, p] of [['merge-conductor', 'project-6-os'], ['merge-conductor-pr', 'project-6-os.5.aaaabbbbcccc'],
    ['merge-conductor', 'project-6-os-x'], ['triage', 'project-5']]) {
    ids[`${lane}|${p}`] = (await enqueue(DB, lane, p)).body.id;
    at(db, ids[`${lane}|${p}`], FRESH);
  }
  return ids;
};
const CASES = readFileSync(new URL('../../../tests/fixtures/bh-7636/box-placement-cases.tsv', import.meta.url), 'utf8')
  .split('\n').filter((l) => l !== '' && !l.startsWith('#')).map((l) => l.split('\t'));

test('BH-7636 lane_runs placed on a box', async (t) => {
  const probe = await openDb();
  if (probe === null) { t.skip('node:sqlite unavailable in this runtime'); return; }

  await t.test('P0 every row of the shared case table parses as the shell parses it', () => {
    assert.ok(CASES.length >= 20, `read ${CASES.length} rows`);
    for (const [lane, proj, key, val, hub, place, box] of CASES) {
      const rows = [{ key, value: val.replace(/\\n/g, '\n') }];
      if (hub !== '-') rows.push({ key: `lane_placement.${lane}.hub_only`, value: hub });
      const got = boxPlacementsFrom(rows).get(`${lane}|${proj}`);
      assert.equal(got, place === 'box' ? box : undefined, `${key}='${val}' hub_only=${hub} -> ${lane}|${proj}`);
    }
    assert.equal(parseBoxValue(' BOX:box-project-6-os-1\n'), BOX);
    assert.equal(parseBoxValue('box:\u212Aelvin'), null, 'only ASCII A-Z lowercases, as tr does (U+212A KELVIN SIGN stays)');
  });

  await t.test('C1 the box claim takes its own row only (not another lane, not project-6-os-x, not a Fly row)', async () => {
    const { db, DB } = await openDb();
    setting(db, MKEY, `box:${BOX}`);
    const ids = await seedRows(db, DB);
    assert.deepEqual(await drain(DB, { machine: BOX, box: BOX }), ['merge-conductor|project-6-os']);
    db.prepare("UPDATE lane_runs SET status='queued', claimed_by=NULL, lease_until=NULL WHERE id=?").run(ids['merge-conductor|project-6-os']);
    const c = await claim(DB, { machine: BOX, box: BOX });
    assert.equal(c.body.box, BOX, 'a box claim answer names the box (the worker refuses an answer without it)');
    db.prepare("UPDATE lane_runs SET status='claimed', claimed_by=? WHERE id=?").run(BOX, c.body.id);
    const r = row(db, ids['merge-conductor|project-6-os']);
    assert.equal(r.status, 'claimed');
    assert.equal(r.claimed_by, BOX);
    for (const k of ['merge-conductor-pr|project-6-os.5.aaaabbbbcccc', 'merge-conductor|project-6-os-x', 'triage|project-5']) {
      assert.equal(row(db, ids[k]).status, 'queued', `${k} stays queued`);
      assert.equal(row(db, ids[k]).attempts, 0);
    }
  });

  await t.test('C2 another box and a bad box name never take the row', async () => {
    const { db, DB } = await openDb();
    setting(db, MKEY, `box:${BOX}`);
    const ids = await seedRows(db, DB);
    assert.equal((await claim(DB, { machine: 'other-box', box: 'other-box' })).status, 204);
    const before = JSON.stringify(db.prepare('SELECT * FROM lane_runs').all());
    for (const v of ['bad/name', '', 7, 'box:x', 'a'.repeat(65)]) {
      const c = await claim(DB, { box: v });
      assert.equal(c.status, 400, `400 for ${JSON.stringify(v)}`);
      assert.match(c.body.error, /box/);
    }
    assert.equal(JSON.stringify(db.prepare('SELECT * FROM lane_runs').all()), before);
    assert.equal(row(db, ids['merge-conductor|project-6-os']).status, 'queued');
  });

  await t.test('C3 a Fly claim never takes the box row: fresh, past group_fallback_s, default or group fleet', async () => {
    const { db, DB } = await openDb();
    setting(db, MKEY, `box:${BOX}`);
    const ids = await seedRows(db, DB);
    const id = ids['merge-conductor|project-6-os'];
    assert.deepEqual(await drain(DB, {}), ['merge-conductor-pr|project-6-os.5.aaaabbbbcccc',
      'merge-conductor|project-6-os-x', 'triage|project-5']);
    assert.equal(row(db, id).status, 'queued');
    // Near miss of the BH-7434 fallback: a grouped project's row older than
    // lane_run.group_fallback_s goes to the default fleet, a box row never.
    setting(db, 'lane_fleet.group.mk', MK);
    at(db, id, OLD);
    assert.equal((await claim(DB, {})).status, 204, 'default fleet past the fallback');
    assert.equal((await claim(DB, { only_prefixes: ['project-6-os.'] })).status, 204, 'the project-6-os group fleet');
    assert.equal(row(db, id).status, 'queued');
    assert.equal(row(db, id).attempts, 0);
    const c = await claim(DB, { machine: BOX, box: ` ${BOX.toUpperCase()} ` });
    assert.equal(c.status, 200, 'the box (name trimmed and lowercased) takes it, group row or not');
    assert.equal(c.body.id, id);
  });

  await t.test('C5 a box that owns no row: 204 and no lane_runs statement (no sweep, no claim)', async () => {
    const { db, DB } = await openDb();
    const id = (await enqueue(DB, 'merge-conductor', 'project-5')).body.id;
    db.prepare("UPDATE lane_runs SET status='claimed', claimed_by='m9', lease_until=?, attempts=9 WHERE id=?").run(OLD, id);
    const seen = [];
    const spy = new Proxy(DB, {
      get(o, k) {
        if (k === 'prepare') return (sql) => { seen.push(sql); return o.prepare(sql); };
        const v = o[k];
        return typeof v === 'function' ? v.bind(o) : v;
      },
    });
    assert.equal((await claim(spy, { machine: BOX, box: BOX })).status, 204);
    assert.deepEqual(seen.filter((s) => /lane_runs/.test(s)), [], 'no lane_runs statement');
    assert.equal(row(db, id).status, 'claimed', 'sweepDead did not run');
  });

  await t.test('C6 skip_prefixes on a Fly claim never ends the box row (REFUSED_SQL); a Fly row is ended', async () => {
    const { db, DB } = await openDb();
    setting(db, MKEY, `box:${BOX}`);
    const ids = await seedRows(db, DB);
    at(db, ids['merge-conductor|project-6-os'], OLD);
    at(db, ids['merge-conductor-pr|project-6-os.5.aaaabbbbcccc'], OLD);
    await claim(DB, { skip_prefixes: ['project-6-os'] });
    assert.equal(row(db, ids['merge-conductor|project-6-os']).status, 'queued', 'box row not refused');
    assert.equal(row(db, ids['merge-conductor-pr|project-6-os.5.aaaabbbbcccc']).status, 'died', 'control: Fly row refused');
  });

  await t.test('C7 stats (plain and fleet=default) do not count the box row', async () => {
    const { db, DB } = await openDb();
    setting(db, MKEY, `box:${BOX}`);
    const ids = await seedRows(db, DB);
    at(db, ids['merge-conductor|project-6-os'], OLD);
    for (const q of ['', '?fleet=default']) {
      const s = await call(DB, 'GET', `/api/lane-runs/stats${q}`);
      assert.equal(s.status, 200);
      const mc = s.body.lanes.find((l) => l.lane === 'merge-conductor');
      assert.equal(mc.queued, 1, `${q || 'plain'}: project-6-os-x only`);
      assert.ok(mc.oldest_queued_wait_s < 60, `${q || 'plain'}: the OLD box row is not the oldest wait (${mc.oldest_queued_wait_s})`);
    }
  });

  await t.test('C8 undo: the row back to hub, a Fly claim takes it', async () => {
    const { db, DB } = await openDb();
    setting(db, MKEY, `box:${BOX}`);
    const id = (await enqueue(DB, 'merge-conductor', 'project-6-os')).body.id;
    assert.equal((await claim(DB, {})).status, 204);
    setting(db, MKEY, 'hub');
    const c = await claim(DB, {});
    assert.equal(c.status, 200);
    assert.equal(c.body.id, id);
    assert.equal(c.body.box, undefined, 'a Fly claim answer has no box');
    assert.equal((await claim(DB, { machine: BOX, box: BOX })).status, 204, 'the box owns nothing now');
  });

  await t.test('C9 a hub_only row on the lane keeps the project off the box', async () => {
    const { db, DB } = await openDb();
    setting(db, MKEY, `box:${BOX}`);
    setting(db, 'lane_placement.merge-conductor.hub_only', 'reads hub files');
    await enqueue(DB, 'merge-conductor', 'project-6-os');
    assert.equal((await claim(DB, { machine: BOX, box: BOX })).status, 204);
  });

  await t.test('W1 withdraw expired:1 ends a claimed row whose lease ran out, never a live one', async () => {
    const { db, DB } = await openDb();
    const id = (await enqueue(DB, 'merge-conductor', 'project-6-os')).body.id;
    db.prepare("UPDATE lane_runs SET status='claimed', claimed_by=?, lease_until=? WHERE id=?").run(BOX, FRESH, id);
    let w = await call(DB, 'POST', `/api/lane-runs/${id}/withdraw`, { by: 'hub-x', why: 'box-silent', expired: 1 });
    assert.equal(w.status, 409, 'live lease');
    assert.equal(w.body.reason, 'not_queued');
    db.prepare('UPDATE lane_runs SET lease_until=? WHERE id=?').run(OLD, id);
    w = await call(DB, 'POST', `/api/lane-runs/${id}/withdraw`, { by: 'hub-x', why: 'box-silent' });
    assert.equal(w.status, 409, 'expired lease without expired:1');
    w = await call(DB, 'POST', `/api/lane-runs/${id}/withdraw`, { by: 'hub-x', why: 'box-silent', expired: true });
    assert.equal(w.status, 409, 'expired must be the number 1');
    w = await call(DB, 'POST', `/api/lane-runs/${id}/withdraw`, { by: 'hub-x', why: 'box-silent', expired: 1 });
    assert.equal(w.status, 200);
    assert.equal(row(db, id).status, 'died');
    assert.match(row(db, id).prof_line, /^withdrawn by=hub-x box-silent/);
    const hb = await call(DB, 'POST', `/api/lane-runs/${id}/heartbeat`, { machine: BOX });
    assert.equal(hb.status, 409, 'the box that comes back loses its row');
  });

  await t.test('R1 by-prefix rows carry lease_until', async () => {
    const { db, DB } = await openDb();
    const id = (await enqueue(DB, 'merge-conductor', 'project-6-os')).body.id;
    db.prepare("UPDATE lane_runs SET status='claimed', claimed_by=?, lease_until=? WHERE id=?").run(BOX, '2026-10-20T01:02:03Z', id);
    const r = await call(DB, 'GET', '/api/lane-runs/by-prefix?lane=merge-conductor&project_prefix=project-6-os&limit=5');
    assert.equal(r.status, 200);
    assert.equal(r.body.rows[0].lease_until, '2026-10-20T01:02:03Z');
  });

  await t.test('E1 EXPLAIN QUERY PLAN on 20 000 rows: the box binds keep idx_lane_runs_claim', async () => {
    const { db } = await openDb();
    const ins = db.prepare(`INSERT INTO lane_runs (lane, project, args_json, enqueued_at, status, attempts, rc, finished_at)
                            VALUES (?,?,?,?,?,?,?,?)`);
    const projects = ['project-6-os', 'project-5', 'project-3', 'project-4', 'project-2'];
    db.exec('BEGIN');
    for (let i = 0; i < 20000; i++) {
      const ts = new Date(Date.UTC(2026, 9, 1) + i * 60e3).toISOString().replace(/\.\d{3}Z$/, 'Z');
      const queued = i >= 19800;
      ins.run(i % 2 ? 'merge-conductor' : 'fly-pool', projects[i % 5] + (i < 19990 ? `-${i}` : ''),
        '["bin/x.sh"]', ts, queued ? 'queued' : 'done', queued ? 0 : 1, queued ? null : 0, queued ? null : ts);
    }
    db.exec('COMMIT');
    db.exec('ANALYZE');
    const T0 = '2026-10-15T00:00:00Z';
    const keys = '["merge-conductor|project-6-os","fly-pool|project-6-os"]';
    const plan = (sql, binds) => db.prepare(`EXPLAIN QUERY PLAN ${sql}`).all(...binds).map((r) => r.detail);
    const idx = (p) => p.some((l) => /lane_runs USING (COVERING )?INDEX idx_lane_runs_claim/.test(l));
    const scan = (p) => p.some((l) => /^SCAN lane_runs\b(?!.*USING)/.test(l));
    const claimB = (only, skip) => ['m1', T0, '2026-10-15T00:02:00Z', null, null, null, null, null, null, null, only, skip];
    for (const [name, sql, b] of [
      ['claim box', CLAIM_SQL, claimB(keys, null)],
      ['claim fly', CLAIM_SQL, claimB(null, keys)],
      ['refused', REFUSED_SQL, [T0, T0, null, '["x"]', 'p', null, null, null, null, keys]],
      ['fleet stats', FLEET_STATS_SQL, [null, null, null, null, T0, keys]]]) {
      const p = plan(sql, b);
      assert.ok(idx(p), `${name}: ${p.join(' | ')}`);
      assert.ok(!scan(p), `${name} no full SCAN: ${p.join(' | ')}`);
    }
    const r = db.prepare(CLAIM_SQL).get(...claimB(keys, null));
    assert.ok(r && r.project === 'project-6-os', `box claim got ${r && `${r.lane}|${r.project}`}`);
    const f = db.prepare(CLAIM_SQL).get(...claimB(null, keys));
    assert.ok(f && f.project !== 'project-6-os', `fly claim got ${f && f.project}`);
  });
});
