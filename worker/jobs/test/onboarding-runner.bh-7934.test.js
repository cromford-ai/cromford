// BH-7934.2 (#7949): the runner's routes, GET /api/onboarding/runs (list by
// state or project) and POST /api/onboarding/runs/:id/beat (claim and step
// beats), plus the retention rule onboarding_runs.finished. Driven through the
// REAL worker.fetch on node:sqlite with the composed jobs schema. Each case
// opens its own fresh DB and uses its own Idempotency-Key.
//   R1  list by state / project; limit and filter refusals
//   R2  claim -> running
//   R3  second claim -> 409 not_queued; unknown id -> 404
//   R4  register/prompt running then done: timestamps, run.station, updated_at
//   R5  label failed with 6000 bytes -> the last 4096 stored; run failed; later steps skipped
//   R6  a multibyte excerpt is cut on a character boundary
//   R7  the run is done only after ready is done
//   R8  a cancelled run: claim and beat -> 409 cancelled, no row changed
//   R9  no bearer -> 401, no row changed
//   R10 error_code accept and refuse
//   R11 retention deletes a 31-day finished run and its steps, keeps the rest
//   R12 retention race guard: a run set back to queued after the id read is kept
//   R13 the settings rows exist; a 100-byte cap stores 100 bytes
//   R14 EXPLAIN QUERY PLAN on 5,000 runs / 35,000 steps
//   R15 the routes are gated, in their own fragment, with no coord-writes row
//   R16 bad-transition and unknown-station refusals write nothing
import test from 'node:test';
import assert from 'node:assert/strict';
import { readdirSync, readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import worker, { ROUTES, OPEN_ROUTES } from '../src/index.js';
import { matchRoute } from '../src/lib/router.js';
import { RULES } from '../src/routes/retention.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import { plan, fullScans } from './lib/d1-volume.bh-6727.js';
import { RUN_SKIP_SQL, LIST_BY_STATE_SQL, LIST_BY_PROJECT_SQL } from '../src/routes/onboarding-runner.js';

const SECRET = 'tok-fixture-bh7949';
const PATH = '/api/onboarding/runs';
const BODY = { repo: 'example-org/acme-os', project: 'acme-os', tracker: 'github-issues', box: 'shared' };
const STATIONS = ['register', 'prompt', 'label', 'box', 'clone', 'smoke', 'ready'];
const REPO = fileURLToPath(new URL('../../../', import.meta.url));

async function fresh(t) {
  const o = await openDb();
  if (!o) { t.skip('node:sqlite unavailable'); return null; }
  return o;
}
async function call(DB, method, path, { body, key, bearer = true } = {}) {
  const headers = { 'content-type': 'application/json' };
  if (bearer) headers.authorization = `Bearer ${SECRET}`;
  if (key !== undefined) headers['idempotency-key'] = key;
  const res = await worker.fetch(new Request(`https://jobs.test${path}`, {
    method, headers, ...(body !== undefined ? { body: JSON.stringify(body) } : {}),
  }), { DB, HARNESS_SECRET: SECRET });
  return { status: res.status, body: await res.json().catch(() => null) };
}
async function create(DB, key, body = BODY) {
  const r = await call(DB, 'POST', PATH, { body, key });
  assert.equal(r.status, 201, JSON.stringify(r.body));
  return r.body.id;
}
// The fields this feature owns, one by one (never a whole-body pin).
const has = (body, want) => { for (const [k, v] of Object.entries(want)) assert.deepEqual(body && body[k], v, `${k} in ${JSON.stringify(body)}`); };
const beat = (DB, id, body, opts = {}) => call(DB, 'POST', `${PATH}/${id}/beat`, { body, ...opts });
const get = (DB, id) => call(DB, 'GET', `${PATH}/${id}`);
const list = (DB, qs) => call(DB, 'GET', `${PATH}?${qs}`);
const snapshot = (db) => JSON.stringify([
  db.prepare('SELECT * FROM onboarding_runs ORDER BY id').all(),
  db.prepare('SELECT * FROM onboarding_steps ORDER BY run_id, ord').all(),
]);
const step = (db, id, station) => db.prepare('SELECT * FROM onboarding_steps WHERE run_id = ? AND station = ?').get(id, station);
const run = (db, id) => db.prepare('SELECT * FROM onboarding_runs WHERE id = ?').get(id);
const ago = (min) => new Date(Date.now() - min * 60e3).toISOString().replace(/\.\d{3}Z$/, 'Z');  // determinism: ok offsets from the clock, compared only to the route's own clock
async function claimed(o, key) {
  const id = await create(o.DB, key);
  const c = await beat(o.DB, id, { claim: true });
  assert.equal(c.status, 200, JSON.stringify(c.body));
  return id;
}
async function pass(o, id, station) {
  for (const state of ['running', 'done']) {
    const r = await beat(o.DB, id, { station, state, ...(state === 'done' ? { log_excerpt: `${station} ok` } : {}) });
    assert.equal(r.status, 200, `${station} ${state}: ${JSON.stringify(r.body)}`);
  }
}

test('R1 list by state and by project; limit and filter refusals', async (t) => {
  const o = await fresh(t); if (!o) return;
  const a = await create(o.DB, 'key-fixture-r1-a');
  const b = await create(o.DB, 'key-fixture-r1-b', { ...BODY, repo: 'example-org/acme-os-2' });
  o.db.prepare('UPDATE onboarding_runs SET created_at = ? WHERE id = ?').run(ago(10), a);
  assert.equal((await beat(o.DB, a, { claim: true })).status, 200);
  const q = await list(o.DB, 'state=queued&limit=1');
  assert.equal(q.status, 200, JSON.stringify(q.body));
  assert.deepEqual(q.body.runs.map((r) => r.id), [b]);
  assert.ok(!('inputs_json' in q.body.runs[0]) && !('inputs' in q.body.runs[0]), 'the list carries no inputs');
  for (const k of ['id', 'project', 'repo', 'state', 'station', 'created_at', 'updated_at', 'finished_at']) assert.ok(k in q.body.runs[0], k);
  const dflt = await list(o.DB, 'state=running');
  assert.deepEqual(dflt.body.runs.map((r) => r.id), [a], 'limit absent = 1');
  const p = await list(o.DB, 'project=acme-os&limit=5');
  assert.equal(p.status, 200);
  assert.deepEqual(p.body.runs.map((r) => r.id), [b, a], 'newest first');
  assert.deepEqual((await list(o.DB, 'project=other&limit=5')).body.runs, []);
  for (const qs of ['state=queued&limit=0', 'state=queued&limit=21', 'state=queued&limit=x', 'state=queued&limit=1.5',
    'limit=1', '', 'state=queued&project=acme-os', 'state=bogus', 'project=Bad_Name']) {
    const r = await list(o.DB, qs);
    assert.equal(r.status, 400, `${qs}: ${JSON.stringify(r.body)}`);
  }
  assert.equal((await list(o.DB, 'limit=1')).body.error, 'filter_required');
  has((await list(o.DB, 'state=queued&limit=21')).body, { error: 'invalid_field', field: 'limit' });
  assert.equal((await list(o.DB, 'state=queued&limit=20')).status, 200, 'limit 20 is the max');
});

test('R2 claim -> 200 running; GET by id shows running', async (t) => {
  const o = await fresh(t); if (!o) return;
  const id = await create(o.DB, 'key-fixture-r2');
  const c = await beat(o.DB, id, { claim: true });
  assert.equal(c.status, 200, JSON.stringify(c.body));
  has(c.body, { id, state: 'running', claimed: true });
  assert.equal((await get(o.DB, id)).body.run.state, 'running');
});

test('R3 a second claim -> 409 not_queued; an unknown id -> 404; a malformed id -> 404', async (t) => {
  const o = await fresh(t); if (!o) return;
  const id = await claimed(o, 'key-fixture-r3');
  const before = snapshot(o.db);
  const c = await beat(o.DB, id, { claim: true });
  assert.equal(c.status, 409);
  assert.equal(c.body.error, 'not_queued');
  assert.equal(snapshot(o.db), before);
  const u = await beat(o.DB, 'ob_00000000000000000000', { claim: true });
  assert.equal(u.status, 404);
  assert.equal(u.body.error, 'not_found');
  assert.equal((await beat(o.DB, 'ob_XYZ', { claim: true })).status, 404);
  assert.equal((await beat(o.DB, id, { claim: 'yes' })).status, 400, 'claim must be true');
  assert.equal((await beat(o.DB, id, {})).status, 400);
});

test('R4 register and prompt running then done: started_at, finished_at, run.station, updated_at', async (t) => {
  const o = await fresh(t); if (!o) return;
  const id = await claimed(o, 'key-fixture-r4');
  o.db.prepare('UPDATE onboarding_runs SET updated_at = ? WHERE id = ?').run(ago(60), id);
  const old = run(o.db, id).updated_at;
  const r = await beat(o.DB, id, { station: 'register', state: 'running' });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  has(r.body, { id, run_state: 'running', station: 'register', step_state: 'running' });
  let s = step(o.db, id, 'register');
  assert.equal(s.state, 'running');
  assert.ok(s.started_at && !s.finished_at);
  assert.equal(run(o.db, id).station, 'register');
  assert.ok(run(o.db, id).updated_at > old, 'updated_at moves');
  await beat(o.DB, id, { station: 'register', state: 'done', log_excerpt: 'registered acme-os' });
  s = step(o.db, id, 'register');
  assert.equal(s.state, 'done');
  assert.ok(s.finished_at && s.started_at <= s.finished_at);
  assert.equal(s.log_excerpt, 'registered acme-os');
  assert.equal(s.error_code, null);
  await pass(o, id, 'prompt');
  assert.equal(step(o.db, id, 'prompt').state, 'done');
  assert.equal(run(o.db, id).station, 'prompt');
  assert.equal(run(o.db, id).state, 'running');
  assert.equal(run(o.db, id).finished_at, null);
});

test('R5 label failed with 6000 bytes: the last 4096 stored, run failed at label, later steps skipped', async (t) => {
  const o = await fresh(t); if (!o) return;
  const id = await claimed(o, 'key-fixture-r5');
  await pass(o, id, 'register');
  await pass(o, id, 'prompt');
  await beat(o.DB, id, { station: 'label', state: 'running' });
  const big = Array.from({ length: 6000 }, (_, i) => String.fromCharCode(33 + (i % 90))).join('');
  const r = await beat(o.DB, id, { station: 'label', state: 'failed', log_excerpt: big, error_code: 'app_no_issues_write' });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  has(r.body, { id, run_state: 'failed', station: 'label', step_state: 'failed' });
  const s = step(o.db, id, 'label');
  assert.equal(s.state, 'failed');
  assert.equal(Buffer.byteLength(s.log_excerpt), 4096);
  assert.equal(s.log_excerpt, big.slice(-4096));
  assert.equal(s.error_code, 'app_no_issues_write');
  assert.ok(s.finished_at);
  const rr = run(o.db, id);
  assert.equal(rr.state, 'failed');
  assert.equal(rr.station, 'label');
  assert.ok(rr.finished_at);
  for (const st of ['box', 'clone', 'smoke', 'ready']) assert.equal(step(o.db, id, st).state, 'skipped', st);
  for (const st of ['register', 'prompt']) assert.equal(step(o.db, id, st).state, 'done', st);
  const after = await beat(o.DB, id, { station: 'box', state: 'running' });
  assert.equal(after.status, 409);
  assert.equal(after.body.error, 'not_running');
  // the default code, and short excerpts are kept as they are
  const id2 = await claimed(o, 'key-fixture-r5-b');
  await beat(o.DB, id2, { station: 'register', state: 'running' });
  await beat(o.DB, id2, { station: 'register', state: 'done', log_excerpt: 'y'.repeat(4096) });
  assert.equal(step(o.db, id2, 'register').log_excerpt, 'y'.repeat(4096), '4096 bytes kept as is');
  await beat(o.DB, id2, { station: 'prompt', state: 'running' });
  const f = await beat(o.DB, id2, { station: 'prompt', state: 'failed', log_excerpt: 'z'.repeat(4095) });
  assert.equal(f.status, 200);
  assert.equal(step(o.db, id2, 'prompt').error_code, 'station_failed', 'the default code');
  assert.equal(step(o.db, id2, 'prompt').log_excerpt, 'z'.repeat(4095), '4095 bytes kept as is');
});

test('R6 a 6000-byte multibyte excerpt is cut to at most 4096 bytes on a character boundary', async (t) => {
  const o = await fresh(t); if (!o) return;
  const id = await claimed(o, 'key-fixture-r6');
  await beat(o.DB, id, { station: 'register', state: 'running' });
  const big = 'x' + '€'.repeat(2000);  // 1 + 6000 bytes; 4096 is not a multiple of 3
  assert.equal(Buffer.byteLength(big), 6001);
  const r = await beat(o.DB, id, { station: 'register', state: 'done', log_excerpt: big });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  const got = step(o.db, id, 'register').log_excerpt;
  assert.ok(Buffer.byteLength(got) <= 4096 && Buffer.byteLength(got) >= 4094, String(Buffer.byteLength(got)));
  assert.ok(!got.includes('�'), 'no replacement character');
  assert.ok(big.endsWith(got), 'the stored text is the tail of the input');
  assert.equal(got, '€'.repeat(1365));
});

test('R7 every station done -> the run is done with finished_at, only after ready', async (t) => {
  const o = await fresh(t); if (!o) return;
  const id = await claimed(o, 'key-fixture-r7');
  for (const st of STATIONS.slice(0, 6)) await pass(o, id, st);
  assert.equal(run(o.db, id).state, 'running', 'still running before ready');
  assert.equal(run(o.db, id).finished_at, null);
  await beat(o.DB, id, { station: 'ready', state: 'running' });
  const r = await beat(o.DB, id, { station: 'ready', state: 'done' });
  has(r.body, { id, run_state: 'done', station: 'ready', step_state: 'done' });
  const g = await get(o.DB, id);
  assert.equal(g.body.run.state, 'done');
  assert.ok(g.body.run.finished_at);
  for (const s of g.body.steps) {
    assert.equal(s.state, 'done', s.station);
    assert.ok(s.started_at <= s.finished_at, s.station);
  }
});

test('R8 a cancelled run: claim and step beat -> 409 cancelled, no row changed', async (t) => {
  const o = await fresh(t); if (!o) return;
  const q = await create(o.DB, 'key-fixture-r8-q');
  o.db.prepare("UPDATE onboarding_runs SET state = 'cancelled' WHERE id = ?").run(q);
  let before = snapshot(o.db);
  const c = await beat(o.DB, q, { claim: true });
  assert.equal(c.status, 409);
  assert.equal(c.body.error, 'cancelled');
  assert.equal(snapshot(o.db), before);
  const id = await claimed(o, 'key-fixture-r8-r');
  await beat(o.DB, id, { station: 'register', state: 'running' });
  o.db.prepare("UPDATE onboarding_runs SET state = 'cancelled' WHERE id = ?").run(id);
  before = snapshot(o.db);
  for (const b of [{ station: 'register', state: 'done' }, { station: 'register', state: 'failed', error_code: 'x' }, { station: 'prompt', state: 'running' }]) {
    const r = await beat(o.DB, id, b);
    assert.equal(r.status, 409, JSON.stringify(b));
    assert.equal(r.body.error, 'cancelled');
  }
  assert.equal(snapshot(o.db), before);
});

test('R8b a cancel that lands between the read and the write wins', async (t) => {
  let cancelOn = null;
  const o = await openDb({
    beforeRun(sql, binds) {
      if (cancelOn && /UPDATE onboarding_steps/.test(sql) && binds[0] === cancelOn) {
        o.db.prepare("UPDATE onboarding_runs SET state = 'cancelled' WHERE id = ?").run(cancelOn);
        cancelOn = null;
      }
    },
  });
  if (!o) { t.skip('node:sqlite unavailable'); return; }
  const id = await claimed(o, 'key-fixture-r8b');
  cancelOn = id;
  const r = await beat(o.DB, id, { station: 'register', state: 'running' });
  assert.equal(r.status, 409, JSON.stringify(r.body));
  assert.equal(r.body.error, 'cancelled');
  assert.equal(step(o.db, id, 'register').state, 'queued', 'the step write lost to the cancel');
  assert.equal(run(o.db, id).state, 'cancelled');
  for (const [i, end] of ['done', 'failed'].entries()) {
    const id2 = await claimed(o, `key-fixture-r8b-${i}`);
    await beat(o.DB, id2, { station: 'register', state: 'running' });
    cancelOn = id2;
    const r2 = await beat(o.DB, id2, { station: 'register', state: end, log_excerpt: 'late' });
    assert.equal(r2.status, 409, JSON.stringify(r2.body));
    const s = step(o.db, id2, 'register');
    assert.equal(s.state, 'running', `a ${end} write lost to the cancel`);
    assert.equal(s.log_excerpt, null);
    assert.equal(step(o.db, id2, 'prompt').state, 'queued', 'no skip either');
  }
});

test('R9 no bearer -> 401 on both routes, no row changed', async (t) => {
  const o = await fresh(t); if (!o) return;
  const id = await create(o.DB, 'key-fixture-r9');
  const before = snapshot(o.db);
  assert.equal((await beat(o.DB, id, { claim: true }, { bearer: false })).status, 401);
  assert.equal((await call(o.DB, 'GET', `${PATH}?state=queued&limit=1`, { bearer: false })).status, 401);
  assert.equal(snapshot(o.db), before);
});

test('R10 error_code accept and refuse', async (t) => {
  const o = await fresh(t); if (!o) return;
  for (const [i, code] of ['app_no_issues_write', 'a', 'a'.repeat(40)].entries()) {
    const id = await claimed(o, `key-fixture-r10-ok-${i}`);
    await beat(o.DB, id, { station: 'register', state: 'running' });
    const r = await beat(o.DB, id, { station: 'register', state: 'failed', error_code: code });
    assert.equal(r.status, 200, `${code}: ${JSON.stringify(r.body)}`);
    assert.equal(step(o.db, id, 'register').error_code, code);
  }
  const id = await claimed(o, 'key-fixture-r10-bad');
  await beat(o.DB, id, { station: 'register', state: 'running' });
  const before = snapshot(o.db);
  for (const code of ['a'.repeat(41), 'App_No', 'box-unreachable', '', 'x;drop', 7]) {
    const r = await beat(o.DB, id, { station: 'register', state: 'failed', error_code: code });
    assert.equal(r.status, 400, `${code}: ${JSON.stringify(r.body)}`);
    has(r.body, { error: 'invalid_field', field: 'error_code' });
  }
  const d = await beat(o.DB, id, { station: 'register', state: 'done', error_code: 'app_no_issues_write' });
  assert.equal(d.status, 400, 'error_code only with failed');
  for (const b of [{ station: 'nope', state: 'running' }, { station: 'register', state: 'skipped' }, { station: 'register', state: 'done', log_excerpt: 5 }]) {
    assert.equal((await beat(o.DB, id, b)).status, 400, JSON.stringify(b));
  }
  assert.equal(snapshot(o.db), before);
});

const rule = () => RULES.find((r) => r.rule === 'onboarding_runs.finished');
function seedRun(db, id, state, updatedMinAgo) {
  const ts = ago(updatedMinAgo);
  db.prepare(`INSERT INTO onboarding_runs (id, project, repo, inputs_json, state, created_at, updated_at)
    VALUES (?, 'p', 'o/p', '{}', ?, ?, ?)`).run(id, state, ts, ts);
  STATIONS.forEach((s, k) => db.prepare("INSERT INTO onboarding_steps (run_id, station, ord, state) VALUES (?, ?, ?, 'done')").run(id, s, k + 1));
}
const steps = (db, id) => db.prepare('SELECT COUNT(*) AS n FROM onboarding_steps WHERE run_id = ?').get(id).n;

test('R11 retention: a 31-day finished run and its steps are gone, the rest are kept, one audit row', async (t) => {
  const o = await fresh(t); if (!o) return;
  assert.ok(rule(), 'the onboarding_runs.finished rule exists');
  assert.equal(rule().key, 'onboarding_runs_retention_days');
  assert.equal(rule().def, 30);
  const D = 24 * 60;
  const ids = {
    done31: 'ob_d0000000000000000031', failed31: 'ob_f0000000000000000031', cancelled31: 'ob_c0000000000000000031',
    running31: 'ob_a0000000000000000031', queued31: 'ob_b0000000000000000031', done1: 'ob_d0000000000000000001',
    done29: 'ob_d0000000000000000029',
  };
  seedRun(o.db, ids.done31, 'done', 31 * D);
  seedRun(o.db, ids.failed31, 'failed', 31 * D);
  seedRun(o.db, ids.cancelled31, 'cancelled', 31 * D);
  seedRun(o.db, ids.running31, 'running', 31 * D);
  seedRun(o.db, ids.queued31, 'queued', 31 * D);
  seedRun(o.db, ids.done1, 'done', D);
  seedRun(o.db, ids.done29, 'done', 29 * D);
  o.db.prepare("INSERT OR REPLACE INTO settings (key, value, note, actor, updated_at) VALUES ('retention.dry_run', '0', 't', 't', '2026-10-23T00:00:00Z')").run();
  const r = await call(o.DB, 'POST', '/api/retention/run', { body: {} });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  const out = r.body.rules.find((x) => x.rule === 'onboarding_runs.finished');
  assert.ok(out, 'the run answer names the rule');
  assert.equal(out.error, null);
  assert.equal(out.removed, 3);
  for (const k of ['done31', 'failed31', 'cancelled31']) {
    assert.equal(run(o.db, ids[k]), undefined, k);
    assert.equal(steps(o.db, ids[k]), 0, `${k} steps`);
  }
  for (const k of ['running31', 'queued31', 'done1', 'done29']) {
    assert.ok(run(o.db, ids[k]), k);
    assert.equal(steps(o.db, ids[k]), 7, `${k} steps`);
  }
  const audit = o.db.prepare("SELECT * FROM retention_runs WHERE rule = 'onboarding_runs.finished'").all();
  assert.equal(audit.length, 1);
  assert.equal(audit[0].removed, 3);
  assert.equal(audit[0].dry_run, 0);
});

test('R12 retention race guard: a run set back to queued after the id read keeps its row and its steps', async (t) => {
  const o = await fresh(t); if (!o) return;
  const id = 'ob_e0000000000000000031';
  seedRun(o.db, id, 'failed', 31 * 24 * 60);
  const got = (await o.DB.prepare(rule().ids).bind(ago(30 * 24 * 60), 10).all()).results.map((x) => x.id);
  assert.deepEqual(got, [id], 'the id read picks the failed run');
  o.db.prepare("UPDATE onboarding_runs SET state = 'queued' WHERE id = ?").run(id);  // a retry lands here
  const arr = JSON.stringify(got);
  await o.DB.batch([...rule().pre.map((s) => o.DB.prepare(s).bind(arr)), o.DB.prepare(rule().del).bind(arr)]);
  assert.ok(run(o.db, id), 'the run is kept');
  assert.equal(steps(o.db, id), 7, 'its steps are kept');
});

test('R13 the settings rows are seeded; the excerpt cap is read from its row', async (t) => {
  const o = await fresh(t); if (!o) return;
  const val = (k) => (o.db.prepare('SELECT value FROM settings WHERE key = ?').get(k) || {}).value;
  assert.equal(val('onboarding.log_excerpt_max_bytes'), '4096');
  assert.equal(val('onboarding.list_limit_max'), '20');
  assert.equal(val('onboarding_runs_retention_days'), '30');
  o.db.prepare("UPDATE settings SET value = '100' WHERE key = 'onboarding.log_excerpt_max_bytes'").run();
  o.db.prepare("UPDATE settings SET value = '3' WHERE key = 'onboarding.list_limit_max'").run();
  const id = await claimed(o, 'key-fixture-r13');
  await beat(o.DB, id, { station: 'register', state: 'running' });
  await beat(o.DB, id, { station: 'register', state: 'done', log_excerpt: 'q'.repeat(500) });
  assert.equal(step(o.db, id, 'register').log_excerpt, 'q'.repeat(100));
  assert.equal((await list(o.DB, 'state=running&limit=4')).status, 400, 'list max read from its row');
  assert.equal((await list(o.DB, 'state=running&limit=3')).status, 200);
});

test('R14 EXPLAIN QUERY PLAN on 5,000 runs and 35,000 steps', async (t) => {
  const o = await fresh(t); if (!o) return;
  const { db } = o;
  const STATES = ['queued', 'running', 'failed', 'done', 'cancelled'];
  db.exec('BEGIN');
  for (let b = 0; b < 50; b++) {
    const runs = [], rb = [], st = [], sb = [];
    for (let j = 0; j < 100; j++) {
      const i = b * 100 + j, id = `ob_${String(i).padStart(20, '0')}`, ts = ago(5000 - i);
      runs.push('(?,?,?,?,?,?,?)');
      rb.push(id, `proj-${i % 50}`, `o/proj-${i % 50}`, '{}', STATES[i % 5], ts, ts);
      STATIONS.forEach((s, k) => { st.push('(?,?,?,?)'); sb.push(id, s, k + 1, 'queued'); });
    }
    db.prepare(`INSERT INTO onboarding_runs (id, project, repo, inputs_json, state, created_at, updated_at) VALUES ${runs.join(',')}`).run(...rb);
    for (let k = 0; k < st.length; k += 100) {
      db.prepare(`INSERT INTO onboarding_steps (run_id, station, ord, state) VALUES ${st.slice(k, k + 100).join(',')}`).run(...sb.slice(k * 4, (k + 100) * 4));
    }
  }
  db.exec('COMMIT');
  db.exec('ANALYZE');
  const T = ['onboarding_runs', 'onboarding_steps'];
  const check = (sql, binds, index) => {
    const p = plan(db, sql, ...binds);
    assert.deepEqual(fullScans(p, T), [], p.join(' | '));
    assert.ok(p.some((l) => l.includes(index)), `${index} not in: ${p.join(' | ')}`);
    return p;
  };
  const p1 = check(LIST_BY_STATE_SQL, ['running', 20], 'idx_onboarding_runs_state_updated');
  assert.ok(!p1.some((l) => /TEMP B-TREE/.test(l)), p1.join(' | '));
  check(LIST_BY_PROJECT_SQL, ['proj-7', 20], 'idx_onboarding_runs_project_created');
  check(RUN_SKIP_SQL, ['ob_00000000000000000042', 3], 'idx_onboarding_steps_run_ord');
  const r = rule();
  check(r.ids, [ago(100), 500], 'idx_onboarding_runs_state_updated');
});

test('R15 the routes are gated, in their own fragment, and no coord-writes row names /beat', () => {
  const id = 'ob_0123456789abcdef0123';
  const hit = matchRoute(ROUTES, 'POST', `${PATH}/${id}/beat`);
  assert.ok(hit, 'beat resolves in ROUTES');
  assert.equal(hit.m[1], id);
  assert.ok(matchRoute(ROUTES, 'GET', PATH), 'the list resolves in ROUTES');
  assert.equal(matchRoute(OPEN_ROUTES, 'POST', `${PATH}/${id}/beat`), null);
  assert.equal(matchRoute(OPEN_ROUTES, 'GET', PATH), null);
  const frag = readFileSync(new URL('./route-table.d/bh-7934-onboarding-runner.txt', import.meta.url), 'utf8');
  assert.match(frag, /^GET \/api\/onboarding\/runs$/m);
  assert.match(frag, /^POST re:.*beat/m);
  const dir = `${REPO}console-ui/functions/_lib/coord-writes.d/`;
  let names = [];
  try { names = readdirSync(dir); } catch { /* no dir: nothing can name it */ }
  for (const n of names) assert.ok(!/\/beat/.test(readFileSync(dir + n, 'utf8')), `${n} names /beat`);
});

test('R16 a bad transition, an unknown station and a done step re-opened write nothing', async (t) => {
  const o = await fresh(t); if (!o) return;
  const id = await claimed(o, 'key-fixture-r16');
  await pass(o, id, 'register');
  const before = snapshot(o.db);
  const cases = [
    [{ station: 'register', state: 'running' }, 409, 'bad_transition'],
    [{ station: 'prompt', state: 'done' }, 409, 'bad_transition'],
    [{ station: 'prompt', state: 'failed' }, 409, 'bad_transition'],
    [{ station: 'tracker', state: 'running' }, 400, 'unknown_station'],
  ];
  for (const [b, status, error] of cases) {
    const r = await beat(o.DB, id, b);
    assert.equal(r.status, status, JSON.stringify(b));
    assert.equal(r.body.error, error, JSON.stringify(b));
  }
  assert.equal(snapshot(o.db), before);
  const q = await create(o.DB, 'key-fixture-r16-q');
  const r = await beat(o.DB, q, { station: 'register', state: 'running' });
  assert.equal(r.status, 409, 'a step beat needs a running run');
  assert.equal(r.body.error, 'not_running');
});
