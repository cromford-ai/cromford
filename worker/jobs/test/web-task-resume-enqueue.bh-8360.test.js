// BH-8360 (slice C0): the resume-run enqueue. When a person answers a web-task
// human step (POST /api/web-task/answer, status 'answered') and the run that
// asked has stopped (lane_runs.status done or died), the answer enqueues ONE
// new web-task lane run of the same project with the stopped run's args_json,
// enqueued_by 'web-task-resume:<step_id>'. The settings row
// web_task.resume_enqueue turns it on (1); the default is 0 (off).
//
// Driven through the REAL worker.fetch (worker/jobs/src/index.js) over a
// node:sqlite D1 with the composed jobs schema. The clock is pinned. Each case
// seeds its own runs under its own project name; the steps are made by the
// real ask route.
//
// K1      the composed schema seeds the switch row as 0
// E1-E3   enqueued: a code step of a done run (then claim, resume, poll: the
//         code once); an approve step of a died run; the Telegram callback form
// N1-N12  not enqueued: switch off or not 0..1; cancel; a queued, claimed or
//         lease-passed old run; a non-web-task run; expired; superseded;
//         another live run of the project; a second answer; two projects; a
//         lost race of the answer UPDATE
// L1      the code is in no answer and no lane_runs column
// X1      EXPLAIN QUERY PLAN at 5000 rows: PK lookups, no SCAN of lane_runs
// C1      statement count: off 3, enqueued 4, skipped 5
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { openDb, d1 } from './lib/d1-sqlite.bh-1030.js';
import { createHash } from 'node:crypto';

const ROUTE = await import('../src/routes/web-task-human.js');

const SECRET = 'fixture-harness-secret';
const KEY1 = Buffer.from('fixture-key-web-vault-bh7595-001').toString('base64');
const NOW_MS = Date.parse('2026-10-25T12:00:00Z');
const iso = (ms) => new Date(ms).toISOString().replace(/\.\d{3}Z$/, 'Z');
const NOW = iso(NOW_MS);
const SITE = 'app.example.com';
const TOKEN1 = 'fixture-run-token-8360-a';
const PROMPT = 'Enter the 6-digit code sent to your phone';
const CODE = '927364';
const SWITCH = 'web_task.resume_enqueue';
const sha = (x) => createHash('sha256').update(x).digest('hex');
let seq = 0;
const uniq = (tag) => `p8360-${tag}-${++seq}`;
const argsOf = (project) => JSON.stringify(['bin/web-task-run.sh', project, `BH-${seq}`]);

async function store(t, hooks = {}) {
  t.mock.timers.enable({ apis: ['Date'], now: NOW_MS });
  const o = await openDb(hooks);
  if (!o) { t.skip('node:sqlite unavailable'); return null; }
  return { db: o.db, env: { DB: o.DB, HARNESS_SECRET: SECRET, WEB_VAULT_KEY_1: KEY1 } };
}

async function call(env, path, body, runToken) {
  const headers = { 'content-type': 'application/json', authorization: `Bearer ${SECRET}` };
  if (runToken) headers['x-web-vault-run-token'] = runToken;
  const res = await worker.fetch(new Request(`https://jobs.test${path}`, { method: 'POST', headers, body: JSON.stringify(body) }), env);
  const text = await res.text();
  let parsed = null;
  try { parsed = JSON.parse(text); } catch { parsed = { raw: text }; }
  return { status: res.status, body: parsed, text };
}

function setting(db, key, value) {
  db.prepare(`INSERT INTO settings (key,value,note,actor,updated_at) VALUES (?,?,'',?,?)
              ON CONFLICT(key) DO UPDATE SET value=excluded.value`).run(key, String(value), 'test', NOW);
}
function run(db, { project, machine = 'm1', token = TOKEN1, args = argsOf(project) }) {
  const id = Number(db.prepare(`INSERT INTO lane_runs (lane, project, args_json, enqueued_at, enqueued_by, claimed_at, claimed_by, lease_until, attempts, status)
                            VALUES ('web-task', ?, ?, ?, 'operator', ?, ?, ?, 1, 'claimed')`)
    .run(project, args, NOW, NOW, machine, iso(NOW_MS + 3600e3)).lastInsertRowid);
  db.prepare('INSERT INTO web_vault_run_token (run_id, machine, token_hash, created_at) VALUES (?, ?, ?, ?)').run(id, machine, sha(token), NOW);
  return id;
}
const setRun = (db, id, status) => db.prepare('UPDATE lane_runs SET status=?, finished_at=? WHERE id=?').run(status, NOW, id);
const runsOf = (db, project) => db.prepare('SELECT * FROM lane_runs WHERE project=? ORDER BY id').all(project).map((r) => ({ ...r }));
const stepRow = (db, id) => ({ ...db.prepare('SELECT * FROM web_task_human_step WHERE id=?').get(id) });
const askOf = (env, b) => call(env, '/api/web-task/human/ask', { machine: 'm1', site: SITE, kind: 'code', prompt: PROMPT, ...b }, TOKEN1);
const answer = (env, b) => call(env, '/api/web-task/answer', b);

// A run of its own project asks one step (the real ask route) and then gets
// oldStatus. -> {s, project, r1, a}.
async function asked(t, { kind = 'code', oldStatus = 'done', on = 1, hooks } = {}) {
  const s = await store(t, hooks); if (!s) return null;
  const project = uniq(kind);
  setting(s.db, `lane.web-task.${project}.allowed_domains`, SITE);
  if (on !== null) setting(s.db, SWITCH, on);
  const r1 = run(s.db, { project });
  const a = await askOf(s.env, { run_id: r1, project, kind });
  assert.equal(a.status, 200, a.text);
  if (oldStatus !== 'claimed') setRun(s.db, r1, oldStatus);
  return { s, project, r1, a: a.body };
}
const codeAnswer = (o) => ({ run_id: o.r1, step_id: o.a.step_id, nonce: o.a.nonce, action: 'code', code: CODE });

function assertEnqueued(o, r) {
  assert.equal(r.status, 200, r.text);
  assert.equal(r.body.resume, 'enqueued', r.text);
  const rows = runsOf(o.s.db, o.project);
  assert.equal(rows.length, 2, JSON.stringify(rows));
  const [old, neu] = rows;
  assert.equal(r.body.resume_run_id, neu.id);
  assert.deepEqual([neu.lane, neu.project, neu.status, neu.args_json, neu.enqueued_by, neu.enqueued_at, neu.claimed_by],
    ['web-task', o.project, 'queued', old.args_json, `web-task-resume:${o.a.step_id}`, NOW, null]);
  assert.equal(stepRow(o.s.db, o.a.step_id).status, 'answered');
  return neu;
}
function assertSkipped(o, r, why) {
  assert.equal(r.status, 200, r.text);
  assert.deepEqual([r.body.ok, r.body.status, r.body.resume, r.body.resume_run_id, r.body.resume_why],
    [true, 'answered', 'skipped', null, why], r.text);
  assert.equal(stepRow(o.s.db, o.a.step_id).status, 'answered', 'the answer is recorded');
}

test('K1 the composed schema seeds web_task.resume_enqueue = 0', async (t) => {
  const s = await store(t); if (!s) return;
  const row = s.db.prepare('SELECT value, actor FROM settings WHERE key=?').get(SWITCH);
  assert.ok(row, 'the seed row exists');
  assert.equal(String(row.value), '0');
});

test('E1 a code step of a done run: one new queued run; claim, resume and poll give the code once', async (t) => {
  const o = await asked(t); if (!o) return;
  const r = await answer(o.s.env, codeAnswer(o));
  const neu = assertEnqueued(o, r);
  // The new row is an ordinary queued row: the claim takes it and mints a run token.
  const c = await call(o.s.env, '/api/lane-runs/claim', { machine: 'm2', lanes: ['web-task'] });
  assert.equal(c.status, 200, c.text);
  assert.deepEqual([c.body.id, c.body.project, c.body.args], [neu.id, o.project, JSON.parse(neu.args_json)]);
  assert.equal(typeof c.body.vault_token, 'string');
  const stepId = Number(neu.enqueued_by.split(':')[1]);
  const rs = await call(o.s.env, '/api/web-task/human/resume', { run_id: neu.id, machine: 'm2', project: o.project, site: SITE, step_id: stepId }, c.body.vault_token);
  assert.deepEqual([rs.status, rs.body.status], [200, 'answered'], rs.text);
  const p = await call(o.s.env, '/api/web-task/human/poll', { run_id: neu.id, machine: 'm2', step_id: stepId }, c.body.vault_token);
  assert.deepEqual([p.status, p.body.state, p.body.code], [200, 'answered', CODE], p.text);
  const again = await call(o.s.env, '/api/web-task/human/poll', { run_id: neu.id, machine: 'm2', step_id: stepId }, c.body.vault_token);
  assert.deepEqual([again.body.state, again.body.code], ['consumed', undefined]);
});

test('E2 an approve step of a died run, done answer: enqueued', async (t) => {
  const o = await asked(t, { kind: 'approve', oldStatus: 'died' }); if (!o) return;
  const r = await answer(o.s.env, { run_id: o.r1, step_id: o.a.step_id, nonce: o.a.nonce, action: 'done' });
  assertEnqueued(o, r);
});

test('E3 the Telegram callback form wt:<step>:<nonce>:d: enqueued', async (t) => {
  const o = await asked(t, { kind: 'approve' }); if (!o) return;
  const r = await answer(o.s.env, { callback_query: { data: `wt:${o.a.step_id}:${o.a.nonce}:d` } });
  assertEnqueued(o, r);
});

test('N1 row missing: the answer body is the pre-change shape, 0 new rows', async (t) => {
  const o = await asked(t, { on: null }); if (!o) return;
  o.s.db.prepare('DELETE FROM settings WHERE key=?').run(SWITCH);
  const r = await answer(o.s.env, codeAnswer(o));
  assert.equal(r.status, 200, r.text);
  assert.deepEqual(r.body, { ok: true, step_id: o.a.step_id, status: 'answered' });
  assert.equal(runsOf(o.s.db, o.project).length, 1);
});

test('N1b row 0, 2, yes, -1, 1.0: off, 0 new rows', async (t) => {
  for (const v of ['0', '2', 'yes', '-1', '1.0']) {
    const o = await asked(t, { on: v }); if (!o) return;
    const r = await answer(o.s.env, codeAnswer(o));
    assert.deepEqual(r.body, { ok: true, step_id: o.a.step_id, status: 'answered' }, `value ${v}`);
    assert.equal(runsOf(o.s.db, o.project).length, 1, `value ${v}`);
    t.mock.timers.reset();
  }
});

test('N2 switch 1, cancel: cancelled, no resume field, 0 new rows', async (t) => {
  const o = await asked(t); if (!o) return;
  const r = await answer(o.s.env, { run_id: o.r1, step_id: o.a.step_id, nonce: o.a.nonce, action: 'cancel' });
  assert.equal(r.status, 200, r.text);
  assert.deepEqual(r.body, { ok: true, step_id: o.a.step_id, status: 'cancelled' });
  assert.equal(runsOf(o.s.db, o.project).length, 1);
});

test('N3 old run queued: skipped run_live', async (t) => {
  const o = await asked(t, { oldStatus: 'queued' }); if (!o) return;
  assertSkipped(o, await answer(o.s.env, codeAnswer(o)), 'run_live');
  assert.equal(runsOf(o.s.db, o.project).length, 1);
});

test('N4 old run claimed with a live lease: skipped run_live', async (t) => {
  const o = await asked(t, { oldStatus: 'claimed' }); if (!o) return;
  assertSkipped(o, await answer(o.s.env, codeAnswer(o)), 'run_live');
  assert.equal(runsOf(o.s.db, o.project).length, 1);
});

test('N4b a claimed old run is never copied, even with lane_runs_live dropped', async (t) => {
  const o = await asked(t, { oldStatus: 'claimed' }); if (!o) return;
  // lane_runs_live alone refuses the INSERT today; the status filter is the
  // guard of its own, and dropping the index is the only way to reach it.
  o.s.db.exec('DROP INDEX lane_runs_live');
  assertSkipped(o, await answer(o.s.env, codeAnswer(o)), 'run_live');
  assert.equal(runsOf(o.s.db, o.project).length, 1);
});

test('N5 old run claimed, lease passed: skipped run_live (the lane-run claim re-takes it)', async (t) => {
  const o = await asked(t, { oldStatus: 'claimed' }); if (!o) return;
  o.s.db.prepare('UPDATE lane_runs SET lease_until=? WHERE id=?').run(iso(NOW_MS - 1000), o.r1);
  assertSkipped(o, await answer(o.s.env, codeAnswer(o)), 'run_live');
  assert.equal(runsOf(o.s.db, o.project).length, 1);
});

test('N6 a step of a non-web-task run: skipped not_web_task', async (t) => {
  const o = await asked(t); if (!o) return;
  o.s.db.prepare("UPDATE lane_runs SET lane='other-lane' WHERE id=?").run(o.r1);
  assertSkipped(o, await answer(o.s.env, codeAnswer(o)), 'not_web_task');
  assert.equal(runsOf(o.s.db, o.project).length, 1);
});

test('N7 an expired step: 410, 0 new rows', async (t) => {
  const o = await asked(t); if (!o) return;
  o.s.db.prepare('UPDATE web_task_human_step SET expires_at=? WHERE id=?').run(NOW, o.a.step_id);
  const r = await answer(o.s.env, codeAnswer(o));
  assert.deepEqual([r.status, r.body.refused], [410, 'expired']);
  assert.equal(runsOf(o.s.db, o.project).length, 1);
});

test('N8 a superseded step: 409 old_nonce, 0 new rows', async (t) => {
  const o = await asked(t, { oldStatus: 'claimed' }); if (!o) return;
  const a2 = await askOf(o.s.env, { run_id: o.r1, project: o.project });
  assert.equal(a2.status, 200);
  setRun(o.s.db, o.r1, 'done');
  const r = await answer(o.s.env, codeAnswer(o));
  assert.deepEqual([r.status, r.body.refused], [409, 'old_nonce']);
  assert.equal(runsOf(o.s.db, o.project).length, 1);
});

test('N9 another web-task run of the project is queued: skipped already_live, resume_run_id null', async (t) => {
  const o = await asked(t); if (!o) return;
  o.s.db.prepare(`INSERT INTO lane_runs (lane, project, args_json, enqueued_at, enqueued_by, status)
                  VALUES ('web-task', ?, '["bin/other.sh"]', ?, 'operator', 'queued')`).run(o.project, NOW);
  assertSkipped(o, await answer(o.s.env, codeAnswer(o)), 'already_live');
  assert.equal(runsOf(o.s.db, o.project).filter((x) => x.enqueued_by !== 'operator').length, 0);
});

test('N10 the same answer twice: the second is 409 already_answered; exactly 1 new row', async (t) => {
  const o = await asked(t); if (!o) return;
  assertEnqueued(o, await answer(o.s.env, codeAnswer(o)));
  const r2 = await answer(o.s.env, codeAnswer(o));
  assert.deepEqual([r2.status, r2.body.refused], [409, 'already_answered']);
  assert.equal(runsOf(o.s.db, o.project).length, 2);
});

test('N11 two projects with stopped runs and steps: only the answered step\'s project gets a row', async (t) => {
  const o = await asked(t); if (!o) return;
  const other = uniq('other');
  setting(o.s.db, `lane.web-task.${other}.allowed_domains`, SITE);
  const rB = run(o.s.db, { project: other });
  assert.equal((await askOf(o.s.env, { run_id: rB, project: other })).status, 200);
  setRun(o.s.db, rB, 'done');
  assertEnqueued(o, await answer(o.s.env, codeAnswer(o)));
  assert.equal(runsOf(o.s.db, other).length, 1);
});

test('N12 the answer UPDATE loses a race (another answer won): 409, 0 new rows', async (t) => {
  let db = null, step = null;
  const o = await asked(t, { hooks: { beforeRun: (sql) => {
    if (step !== null && /^UPDATE web_task_human_step SET status=\?2/.test(sql)) {
      const id = step; step = null;
      db.prepare("UPDATE web_task_human_step SET status='answered', answered_at=? WHERE id=?").run(NOW, id);
    }
  } } });
  if (!o) return;
  db = o.s.db; step = o.a.step_id;
  const r = await answer(o.s.env, codeAnswer(o));
  assert.deepEqual([r.status, r.body.refused], [409, 'already_answered'], r.text);
  assert.equal(runsOf(o.s.db, o.project).length, 1, 'the lost answer enqueues nothing');
});

test('L1 the code is in no answer body and no lane_runs column', async (t) => {
  const o = await asked(t); if (!o) return;
  const r = await answer(o.s.env, codeAnswer(o));
  assertEnqueued(o, r);
  assert.equal(r.text.includes(CODE), false);
  for (const row of runsOf(o.s.db, o.project)) assert.equal(JSON.stringify(row).includes(CODE), false);
});

test('X1 EXPLAIN QUERY PLAN at 5000 rows: PK lookups and the live index, no SCAN of lane_runs', async (t) => {
  const s = await store(t); if (!s) return;
  const ins = s.db.prepare(`INSERT INTO lane_runs (lane, project, args_json, enqueued_at, status) VALUES (?, ?, '[]', ?, ?)`);
  const st = s.db.prepare(`INSERT INTO web_task_human_step (run_id, project, site, kind, prompt, nonce_hash, status, created_at, wait_until, expires_at)
                           VALUES (?, ?, ?, 'code', 'p', ?, 'open', ?, ?, ?)`);
  s.db.exec('BEGIN');
  for (let i = 1; i <= 5000; i++) {
    const lane = i % 3 ? 'web-task' : 'build';
    const id = Number(ins.run(lane, `px${i % 400}`, NOW, i % 7 ? 'done' : 'died').lastInsertRowid);
    st.run(id, `px${i % 400}`, SITE, `h${i}`, NOW, NOW, NOW);
  }
  s.db.exec('COMMIT');
  s.db.exec('ANALYZE');
  const plan = (sql, n) => s.db.prepare(`EXPLAIN QUERY PLAN ${sql}`).all(...Array(n).fill(1)).map((r) => r.detail);
  assert.equal(typeof ROUTE.RESUME_ENQUEUE_SQL, 'string', 'RESUME_ENQUEUE_SQL is exported');
  assert.equal(typeof ROUTE.RESUME_SKIP_SQL, 'string', 'RESUME_SKIP_SQL is exported');
  const enq = plan(ROUTE.RESUME_ENQUEUE_SQL, 2);
  assert.ok(enq.some((d) => /SEARCH s USING INTEGER PRIMARY KEY/.test(d)), JSON.stringify(enq));
  assert.ok(enq.some((d) => /SEARCH o USING INTEGER PRIMARY KEY/.test(d)), JSON.stringify(enq));
  assert.equal(enq.some((d) => /^SCAN/.test(d)), false, JSON.stringify(enq));
  const skip = plan(ROUTE.RESUME_SKIP_SQL, 1);
  assert.ok(skip.some((d) => /SEARCH o USING INTEGER PRIMARY KEY/.test(d)), JSON.stringify(skip));
  assert.ok(skip.some((d) => /SEARCH l USING (COVERING )?INDEX (lane_runs_live|idx_lane_runs_lane)/.test(d)), JSON.stringify(skip));
  assert.equal(skip.some((d) => /^SCAN/.test(d)), false, JSON.stringify(skip));
});

// Counts every statement the route sends to D1; a batch counts its members.
function counted(inner, log) {
  return {
    prepare(sql) {
      const st = inner.prepare(sql);
      const api = {
        _inner: st,
        bind(...v) { st.bind(...v); return api; },
        first(c) { log.push(['read', sql]); return st.first(c); },
        all() { log.push(['read', sql]); return st.all(); },
        run() { log.push(['write', sql]); return st.run(); },
      };
      return api;
    },
    batch(x) { for (const a of x) log.push(['batched', a._inner._isRead ? 'read' : 'write']); return inner.batch(x.map((a) => a._inner)); },
  };
}

test('C1 statement count: off 3, enqueued 4, skipped 5', async (t) => {
  for (const [on, oldStatus, n, resume] of [[0, 'done', 3, undefined], [1, 'done', 4, 'enqueued'], [1, 'queued', 5, 'skipped']]) {
    const o = await asked(t, { on, oldStatus }); if (!o) return;
    const log = [];
    const r = await answer({ ...o.s.env, DB: counted(d1(o.s.db), log) }, codeAnswer(o));
    assert.equal(r.status, 200, r.text);
    assert.equal(r.body.resume, resume, r.text);
    assert.equal(log.length, n, `${resume}: ${JSON.stringify(log)}`);
    t.mock.timers.reset();
  }
});
