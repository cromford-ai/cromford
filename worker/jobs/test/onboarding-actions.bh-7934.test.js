// BH-7950 (BH-7934.3): POST /api/onboarding/runs/:id/retry and /cancel.
// Driven through the REAL worker.fetch on node:sqlite with the composed jobs
// schema. Each case opens its own fresh DB and seeds its own run ids with
// direct INSERTs (the shapes the contract's create and the runner write).
//   A1 retry on a run failed at label -> label queued (retries 1, error NULL),
//      box..ready queued, register/prompt still done, run queued, GET agrees
//   A2 retry on done/queued/running/cancelled -> 409 not_failed, rows unchanged;
//      unknown id -> 404 not_found
//   A3 cancel from queued/running/failed -> cancelled + finished_at, non-done
//      steps skipped, done steps unchanged
//   A4 cancel on done/cancelled -> 409 already_terminal, rows unchanged
//   A5 two concurrent retries -> one 200, one 409, retries=1
//   A6 no bearer -> 401, rows unchanged
//   A7 the routes are gated (ROUTES, not OPEN_ROUTES); a malformed id -> 404
//      unknown endpoint
//   A8 retry after cancel -> 409; cancel after retry -> 200
//   A9 EXPLAIN QUERY PLAN for every exported statement on 5,000 runs / 35,000
//      steps: no full scan and no correlated subquery
//   A10 GET /api/onboarding/projects/:project/latest -> the newest run of that
//      project only, {run:null} for a project with none, 401 with no bearer
import test from 'node:test';
import assert from 'node:assert/strict';
import worker, { ROUTES, OPEN_ROUTES } from '../src/index.js';
import { matchRoute } from '../src/lib/router.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import { plan, fullScans } from './lib/d1-volume.bh-6727.js';

const SECRET = 'tok-fixture-bh7950';
const STATIONS = ['register', 'prompt', 'label', 'box', 'clone', 'smoke', 'ready'];
const T0 = '2026-10-22T10:00:00Z';
const T1 = '2026-10-22T10:01:00Z';
const T2 = '2026-10-22T10:02:00Z';
const idOf = (n) => 'ob_' + n.toString(16).padStart(20, '0');

async function fresh(t) {
  const o = await openDb();
  if (!o) { t.skip('node:sqlite unavailable'); return null; }
  return o;
}

// One run and its 7 steps. stepStates: 7 states in ord order; failedAt names
// the failed step's error_code and excerpt.
function seed(db, id, runState, stepStates, { errorCode = 'app_no_issues_write' } = {}) {
  const terminal = ['done', 'failed', 'cancelled'].includes(runState);
  db.prepare(`INSERT INTO onboarding_runs (id, project, repo, inputs_json, state, station, created_by, created_at, updated_at, finished_at)
    VALUES (?, 'acme-os', 'example-org/acme-os', '{"box":"shared","project":"acme-os","repo":"example-org/acme-os","tracker":"github-issues"}', ?, NULL, NULL, ?, ?, ?)`)
    .run(id, runState, T0, T1, terminal ? T1 : null);
  stepStates.forEach((st, i) => {
    const started = st === 'queued' || st === 'skipped' ? null : T0;
    const finished = st === 'done' || st === 'failed' ? T1 : null;
    db.prepare(`INSERT INTO onboarding_steps (run_id, station, ord, state, started_at, finished_at, log_excerpt, retries, error_code)
      VALUES (?, ?, ?, ?, ?, ?, ?, 0, ?)`)
      .run(id, STATIONS[i], i + 1, st, started, finished, st === 'queued' ? null : `log of ${STATIONS[i]}`, st === 'failed' ? errorCode : null);
  });
}

const FAILED_AT_LABEL = ['done', 'done', 'failed', 'skipped', 'skipped', 'skipped', 'skipped'];
const RUNNING_AT_BOX = ['done', 'done', 'done', 'running', 'queued', 'queued', 'queued'];
const ALL_QUEUED = Array(7).fill('queued');
const ALL_DONE = Array(7).fill('done');
const CANCELLED_AFTER_PROMPT = ['done', 'done', 'skipped', 'skipped', 'skipped', 'skipped', 'skipped'];

const runRow = (db, id) => db.prepare('SELECT * FROM onboarding_runs WHERE id = ?').get(id);
const stepRows = (db, id) => db.prepare('SELECT * FROM onboarding_steps WHERE run_id = ? ORDER BY ord').all(id);
const snapshot = (db) => JSON.stringify([
  db.prepare('SELECT * FROM onboarding_runs ORDER BY id').all(),
  db.prepare('SELECT * FROM onboarding_steps ORDER BY run_id, ord').all(),
]);

async function call(DB, method, path, { bearer = true, body } = {}) {
  const headers = { 'content-type': 'application/json' };
  if (bearer) headers.authorization = `Bearer ${SECRET}`;
  const res = await worker.fetch(new Request(`https://jobs.test${path}`, {
    method, headers, ...(body !== undefined ? { body: JSON.stringify(body) } : {}),
  }), { DB, HARNESS_SECRET: SECRET });
  return { status: res.status, body: await res.json().catch(() => null) };
}
// The coord proxy forwards {actor} on these rows; the route ignores it.
const retry = (DB, id, opts) => call(DB, 'POST', `/api/onboarding/runs/${id}/retry`, { body: { actor: 'operator' }, ...opts });
const cancel = (DB, id, opts) => call(DB, 'POST', `/api/onboarding/runs/${id}/cancel`, { body: { actor: 'operator' }, ...opts });

test('A1 retry on a run failed at label: the failed and later steps go back to queued, done steps and the other run stay', async (t) => {
  const o = await fresh(t); if (!o) return;
  const id = idOf(0xa1);
  const other = idOf(0xa1f);
  seed(o.db, id, 'failed', FAILED_AT_LABEL);
  seed(o.db, other, 'failed', FAILED_AT_LABEL);
  const before = stepRows(o.db, id);
  const otherBefore = JSON.stringify([runRow(o.db, other), stepRows(o.db, other)]);
  const r = await retry(o.DB, id);
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.id, id);
  assert.equal(r.body.state, 'queued');
  const steps = stepRows(o.db, id);
  assert.deepEqual(steps.map((s) => s.state), ['done', 'done', 'queued', 'queued', 'queued', 'queued', 'queued']);
  const label = steps[2];
  assert.equal(label.station, 'label');
  assert.equal(label.retries, 1);
  assert.equal(label.error_code, null);
  for (const i of [0, 1]) assert.deepEqual(steps[i], before[i], `${STATIONS[i]} is unchanged`);
  for (const i of [3, 4, 5, 6]) assert.equal(steps[i].retries, 0, `${STATIONS[i]} retries stay 0`);
  const run = runRow(o.db, id);
  assert.equal(run.state, 'queued');
  assert.equal(run.finished_at, null);
  assert.notEqual(run.updated_at, T1);
  // The other run is untouched.
  assert.equal(JSON.stringify([runRow(o.db, other), stepRows(o.db, other)]), otherBefore);
  // The contract's GET reads the same.
  const g = await call(o.DB, 'GET', `/api/onboarding/runs/${id}`);
  assert.equal(g.status, 200);
  assert.equal(g.body.run.state, 'queued');
  assert.equal(g.body.run.finished_at, null);
  assert.deepEqual(g.body.steps.map((s) => s.state), ['done', 'done', 'queued', 'queued', 'queued', 'queued', 'queued']);
  assert.equal(g.body.steps[2].retries, 1);
});

test('A1b a second failure after a retry: retries counts up to 2', async (t) => {
  const o = await fresh(t); if (!o) return;
  const id = idOf(0xa1b);
  seed(o.db, id, 'failed', FAILED_AT_LABEL);
  assert.equal((await retry(o.DB, id)).status, 200);
  o.db.prepare("UPDATE onboarding_steps SET state='failed', error_code='station_failed' WHERE run_id=? AND station='label'").run(id);
  o.db.prepare("UPDATE onboarding_steps SET state='skipped' WHERE run_id=? AND ord > 3").run(id);
  o.db.prepare("UPDATE onboarding_runs SET state='failed', finished_at=? WHERE id=?").run(T2, id);
  assert.equal((await retry(o.DB, id)).status, 200);
  assert.equal(stepRows(o.db, id)[2].retries, 2);
});

test('A1c near miss: a skipped step BEFORE the failed one stays skipped; only later steps are requeued', async (t) => {
  const o = await fresh(t); if (!o) return;
  const id = idOf(0xa1c);
  seed(o.db, id, 'failed', ['done', 'skipped', 'done', 'failed', 'skipped', 'skipped', 'skipped'], { errorCode: 'box_unreachable' });
  const r = await retry(o.DB, id);
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.deepEqual(stepRows(o.db, id).map((s) => s.state), ['done', 'skipped', 'done', 'queued', 'queued', 'queued', 'queued']);
});

test('A2 retry on done, queued, running, cancelled -> 409 not_failed and nothing changes; unknown id -> 404', async (t) => {
  const o = await fresh(t); if (!o) return;
  const cases = [['done', ALL_DONE], ['queued', ALL_QUEUED], ['running', RUNNING_AT_BOX], ['cancelled', CANCELLED_AFTER_PROMPT]];
  cases.forEach(([state, steps], i) => seed(o.db, idOf(0xa20 + i), state, steps));
  const snap = snapshot(o.db);
  for (const [i, [state]] of cases.entries()) {
    const r = await retry(o.DB, idOf(0xa20 + i));
    assert.equal(r.status, 409, `${state}: ${JSON.stringify(r.body)}`);
    assert.equal(r.body.error, 'not_failed');
    assert.equal(r.body.state, state);
  }
  assert.equal(snapshot(o.db), snap, 'a refused retry changed a row');
  const u = await retry(o.DB, idOf(0xa2f));
  assert.equal(u.status, 404, JSON.stringify(u.body));
  assert.equal(u.body.error, 'not_found');
  assert.equal(snapshot(o.db), snap);
});

test('A3 cancel from queued, running, failed -> cancelled with finished_at; non-done steps skipped, done steps unchanged', async (t) => {
  const o = await fresh(t); if (!o) return;
  const cases = [['queued', ALL_QUEUED], ['running', RUNNING_AT_BOX], ['failed', FAILED_AT_LABEL]];
  for (const [i, [state, states]] of cases.entries()) {
    const id = idOf(0xa30 + i);
    seed(o.db, id, state, states);
    const before = stepRows(o.db, id);
    const r = await cancel(o.DB, id);
    assert.equal(r.status, 200, `${state}: ${JSON.stringify(r.body)}`);
    assert.equal(r.body.id, id);
    assert.equal(r.body.state, 'cancelled');
    const run = runRow(o.db, id);
    assert.equal(run.state, 'cancelled');
    assert.ok(run.finished_at && run.finished_at !== T1, `${state}: finished_at is the cancel time (${run.finished_at})`);
    assert.equal(run.updated_at, run.finished_at);
    const after = stepRows(o.db, id);
    after.forEach((s, k) => {
      if (states[k] === 'done') assert.deepEqual(s, before[k], `${state}: done step ${s.station} is unchanged`);
      else assert.equal(s.state, 'skipped', `${state}: step ${s.station} (${states[k]}) is skipped`);
    });
  }
});

test('A4 cancel on done or cancelled -> 409 already_terminal and nothing changes', async (t) => {
  const o = await fresh(t); if (!o) return;
  seed(o.db, idOf(0xa40), 'done', ALL_DONE);
  seed(o.db, idOf(0xa41), 'cancelled', CANCELLED_AFTER_PROMPT);
  const snap = snapshot(o.db);
  for (const [n, state] of [[0xa40, 'done'], [0xa41, 'cancelled']]) {
    const r = await cancel(o.DB, idOf(n));
    assert.equal(r.status, 409, `${state}: ${JSON.stringify(r.body)}`);
    assert.equal(r.body.error, 'already_terminal');
    assert.equal(r.body.state, state);
  }
  assert.equal(snapshot(o.db), snap);
  const u = await cancel(o.DB, idOf(0xa4f));
  assert.equal(u.status, 404);
  assert.equal(u.body.error, 'not_found');
  // A second cancel on a run this test cancelled is refused too.
  seed(o.db, idOf(0xa42), 'running', RUNNING_AT_BOX);
  assert.equal((await cancel(o.DB, idOf(0xa42))).status, 200);
  const twice = await cancel(o.DB, idOf(0xa42));
  assert.equal(twice.status, 409);
  assert.equal(twice.body.error, 'already_terminal');
});

test('A5 two concurrent retries: one 200, one 409, the failed step retried once', async (t) => {
  const o = await fresh(t); if (!o) return;
  const id = idOf(0xa5);
  seed(o.db, id, 'failed', FAILED_AT_LABEL);
  const rs = await Promise.all([retry(o.DB, id), retry(o.DB, id)]);
  assert.deepEqual(rs.map((r) => r.status).sort(), [200, 409], JSON.stringify(rs));
  assert.equal(rs.find((r) => r.status === 409).body.error, 'not_failed');
  assert.equal(stepRows(o.db, id)[2].retries, 1);
});

test('A6 no bearer -> 401 on retry and cancel, nothing changes', async (t) => {
  const o = await fresh(t); if (!o) return;
  seed(o.db, idOf(0xa6), 'failed', FAILED_AT_LABEL);
  const snap = snapshot(o.db);
  for (const fn of [retry, cancel]) {
    const r = await fn(o.DB, idOf(0xa6), { bearer: false });
    assert.equal(r.status, 401);
  }
  assert.equal(snapshot(o.db), snap);
});

test('A7 the routes are gated, and a malformed id is an unknown endpoint', async (t) => {
  for (const verb of ['retry', 'cancel']) {
    const path = `/api/onboarding/runs/${idOf(7)}/${verb}`;
    assert.ok(matchRoute(ROUTES, 'POST', path), `POST ${verb} is in ROUTES`);
    assert.equal(matchRoute(OPEN_ROUTES, 'POST', path), null, `POST ${verb} is not open`);
    assert.equal(matchRoute(ROUTES, 'GET', path), null, `GET ${verb} is not a route`);
  }
  const o = await fresh(t); if (!o) return;
  for (const bad of ['ob_XYZ', 'ob_' + '0'.repeat(19), 'ob_' + 'A'.repeat(20)]) {
    const r = await retry(o.DB, bad);
    assert.equal(r.status, 404, bad);
    assert.equal(r.body.error, 'unknown endpoint', bad);
  }
});

test('A8 retry after cancel -> 409; cancel after retry -> 200', async (t) => {
  const o = await fresh(t); if (!o) return;
  const a = idOf(0xa80);
  seed(o.db, a, 'failed', FAILED_AT_LABEL);
  assert.equal((await cancel(o.DB, a)).status, 200);
  const r = await retry(o.DB, a);
  assert.equal(r.status, 409);
  assert.equal(r.body.error, 'not_failed');
  assert.equal(r.body.state, 'cancelled');
  assert.equal(stepRows(o.db, a)[2].retries, 0);
  const b = idOf(0xa81);
  seed(o.db, b, 'failed', FAILED_AT_LABEL);
  assert.equal((await retry(o.DB, b)).status, 200);
  const c = await cancel(o.DB, b);
  assert.equal(c.status, 200);
  assert.deepEqual(stepRows(o.db, b).map((s) => s.state), ['done', 'done', 'skipped', 'skipped', 'skipped', 'skipped', 'skipped']);
});

test('A9 EXPLAIN QUERY PLAN on 5,000 runs / 35,000 steps: every statement seeks, none scans or correlates', async (t) => {
  const o = await fresh(t); if (!o) return;
  const SQL = await import('../src/routes/onboarding-actions.js');
  const { db } = o;
  const states = ['queued', 'running', 'failed', 'done', 'cancelled'];
  db.exec('BEGIN');
  for (let b = 0; b < 50; b++) {
    const runs = [], rb = [], steps = [], sb = [];
    for (let j = 0; j < 100; j++) {
      const i = b * 100 + j, id = idOf(i);
      runs.push('(?,?,?,?,?,?,?,?,?,?)');
      rb.push(id, `proj-${i % 50}`, `o/proj-${i % 50}`, '{}', states[i % 5], null, null, T0, T0, null);
      STATIONS.forEach((s, k) => { steps.push('(?,?,?,?)'); sb.push(id, s, k + 1, k === 2 && i % 5 === 2 ? 'failed' : 'queued'); });
    }
    db.prepare(`INSERT INTO onboarding_runs (id, project, repo, inputs_json, state, station, created_by, created_at, updated_at, finished_at) VALUES ${runs.join(',')}`).run(...rb);
    for (let k = 0; k < steps.length; k += 100) {
      db.prepare(`INSERT INTO onboarding_steps (run_id, station, ord, state) VALUES ${steps.slice(k, k + 100).join(',')}`).run(...sb.slice(k * 4, (k + 100) * 4));
    }
  }
  db.exec('COMMIT');
  db.exec('ANALYZE');
  assert.equal(db.prepare('SELECT COUNT(*) AS n FROM onboarding_steps').get().n, 35000);
  const id = idOf(4322);
  const names = ['RETRY_LATER_SQL', 'RETRY_FAILED_SQL', 'RETRY_RUN_SQL', 'CANCEL_STEPS_SQL', 'CANCEL_RUN_SQL', 'STATE_SQL', 'LATEST_SQL'];
  for (const name of names) {
    assert.equal(typeof SQL[name], 'string', `${name} is exported`);
    const binds = name === 'LATEST_SQL' ? ['proj-7'] : /\?2/.test(SQL[name]) ? [id, T2] : [id];
    const p = plan(db, SQL[name], ...binds);
    assert.deepEqual(fullScans(p, ['onboarding_runs', 'onboarding_steps']), [], `${name}: ${p.join(' | ')}`);
    assert.ok(!p.some((l) => /CORRELATED/.test(l)), `${name} has a correlated subquery: ${p.join(' | ')}`);
    assert.ok(p.some((l) => /^SEARCH onboarding_(runs|steps) USING (PRIMARY KEY|INDEX|COVERING INDEX)/.test(l)), `${name}: ${p.join(' | ')}`);
  }
});

test('A10 the latest read gives the newest run of that project only, null when there is none', async (t) => {
  const o = await fresh(t); if (!o) return;
  const { db, DB } = o;
  seed(db, idOf(1), 'failed', FAILED_AT_LABEL);
  seed(db, idOf(2), 'running', RUNNING_AT_BOX);
  db.prepare("UPDATE onboarding_runs SET created_at = ? WHERE id = ?").run(T2, idOf(2));
  db.prepare(`INSERT INTO onboarding_runs (id, project, repo, inputs_json, state, created_at, updated_at)
    VALUES (?, 'other-os', 'example-org/other-os', '{}', 'queued', '2026-10-22T11:00:00Z', '2026-10-22T11:00:00Z')`).run(idOf(3));
  const before = snapshot(db);
  const r = await call(DB, 'GET', '/api/onboarding/projects/acme-os/latest');
  assert.equal(r.status, 200);
  assert.deepEqual(r.body, { run: { id: idOf(2), state: 'running', created_at: T2 } });
  const none = await call(DB, 'GET', '/api/onboarding/projects/empty-os/latest');
  assert.equal(none.status, 200);
  assert.deepEqual(none.body, { run: null });
  const anon = await call(DB, 'GET', '/api/onboarding/projects/acme-os/latest', { bearer: false });
  assert.equal(anon.status, 401);
  assert.equal(snapshot(db), before, 'a read changes no row');
});
