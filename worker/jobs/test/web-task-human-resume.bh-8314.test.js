// BH-8314 (slice C0): a later answer starts a new run that resumes. The route
// POST /api/web-task/human/resume lets a NEW claimed web-task run of the same
// project and site take over an open or answered step of a run that stopped.
//
// Driven through the REAL worker.fetch (worker/jobs/src/index.js, so the route
// fragment is proven too) over a node:sqlite D1 with the composed jobs schema.
// The clock is pinned (D60). Each case seeds its own runs and steps; the steps
// are made by the real ask route, so the rows are the shape production writes.
//
// R1-R3   accepts: an open step of a done run; an answered step of a died run;
//         a reclaimed run (same id, new machine and token) resumes its own step
// R4      the idempotent repeat writes nothing
// R5      the refusals of the new run (readRefusal) and bad forms write nothing
// R6      no_step, other_task, old_nonce, already_answered, cancelled, expired
// R7      run_live: the old run still holds a live lease (lane_runs_live makes
//         that unreachable today; the case drops the index to pin the guard)
// R8      raced: another rebind wins between the read and the UPDATE
// R9      after a rebind the poll serves the new run and refuses the old one;
//         the resume answer holds no code and no nonce
// R10     statement count: 4 parallel reads + 1 UPDATE on the 200 path
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { openDb, d1 } from './lib/d1-sqlite.bh-1030.js';
import { createHash } from 'node:crypto';

// Loaded by dynamic import, so each case fails on its own while the module is absent.
const RESUME = await import('../src/routes/web-task-human-resume.js').catch(() => null);

const SECRET = 'fixture-harness-secret';
const KEY1 = Buffer.from('fixture-key-web-vault-bh7595-001').toString('base64');
const NOW_MS = Date.parse('2026-10-25T12:00:00Z');
const iso = (ms) => new Date(ms).toISOString().replace(/\.\d{3}Z$/, 'Z');
const NOW = iso(NOW_MS);
const SITE = 'app.example.com';
const TOKEN1 = 'fixture-run-token-8314-a';
const TOKEN2 = 'fixture-run-token-8314-b';
const PROMPT = 'Enter the 6-digit code sent to your phone';
const CODE = '481516';
const sha = (x) => createHash('sha256').update(x).digest('hex');

async function store(t, hooks = {}) {
  t.mock.timers.enable({ apis: ['Date'], now: NOW_MS });
  const o = await openDb(hooks);
  if (!o) { t.skip('node:sqlite unavailable'); return null; }
  const env = { DB: o.DB, HARNESS_SECRET: SECRET, WEB_VAULT_KEY_1: KEY1 };
  return { db: o.db, env };
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
// A web-task lane_runs row, plus the run-token row its claim minted.
function run(db, { project = 'p1', machine = 'm1', token = TOKEN1, status = 'claimed', lease = iso(NOW_MS + 3600e3) } = {}) {
  const id = Number(db.prepare(`INSERT INTO lane_runs (lane, project, args_json, enqueued_at, claimed_at, claimed_by, lease_until, attempts, status)
                            VALUES ('web-task', ?, '[]', ?, ?, ?, ?, 1, ?)`)
    .run(project, NOW, NOW, machine, lease, status).lastInsertRowid);
  db.prepare('INSERT INTO web_vault_run_token (run_id, machine, token_hash, created_at) VALUES (?, ?, ?, ?)').run(id, machine, sha(token), NOW);
  return id;
}
const finish = (db, id, status = 'done') => db.prepare("UPDATE lane_runs SET status=?, finished_at=? WHERE id=?").run(status, NOW, id);
const step = (db, id) => ({ ...db.prepare('SELECT * FROM web_task_human_step WHERE id=?').get(id) });

const askOf = (env, b, token = TOKEN1) =>
  call(env, '/api/web-task/human/ask', { machine: 'm1', project: 'p1', site: SITE, kind: 'code', prompt: PROMPT, ...b }, token);
const resume = (env, b, token = TOKEN2) =>
  call(env, '/api/web-task/human/resume', { machine: 'm2', project: 'p1', site: SITE, ...b }, token);
const poll = (env, b, token) => call(env, '/api/web-task/human/poll', b, token);

// Run 1 asks (the real ask route) and stops; run 2 is a new claimed run of the
// same project on machine m2. -> {s, r1, r2, a} where a is the ask answer.
async function stopped(t, { hooks, oldStatus = 'done', project = 'p1' } = {}) {
  const s = await store(t, hooks); if (!s) return null;
  setting(s.db, `lane.web-task.${project}.allowed_domains`, SITE);
  const r1 = run(s.db, { project });
  const a = await askOf(s.env, { run_id: r1, project });
  assert.equal(a.status, 200, JSON.stringify(a.body));
  if (oldStatus) finish(s.db, r1, oldStatus);
  const r2 = oldStatus ? run(s.db, { project, machine: 'm2', token: TOKEN2 }) : null;
  return { s, r1, r2, a: a.body };
}

test('R0 the module exists and exports its SQL', () => {
  assert.ok(RESUME, 'src/routes/web-task-human-resume.js exists');
  assert.match(RESUME.REBIND_SQL, /run_id=\?3/);
});

test('R1 an open step of a done run: run 2 takes it over; one row changes', async (t) => {
  const o = await stopped(t); if (!o) return;
  const { s, r1, r2, a } = o;
  const r = await resume(s.env, { run_id: r2, step_id: a.step_id });
  assert.equal(r.status, 200, r.text);
  assert.deepEqual([r.body.ok, r.body.step_id, r.body.status, r.body.kind], [true, a.step_id, 'open', 'code']);
  const row = step(s.db, a.step_id);
  assert.deepEqual([row.run_id, row.status], [r2, 'open']);
  assert.notEqual(row.run_id, r1);
});

test('R2 an answered step of a died run: taken over, the answer kept', async (t) => {
  const o = await stopped(t, { oldStatus: 'died' }); if (!o) return;
  const { s, r1, r2, a } = o;
  const ans = await call(s.env, '/api/web-task/answer', { run_id: r1, step_id: a.step_id, nonce: a.nonce, action: 'code', code: CODE });
  assert.equal(ans.status, 200, ans.text);
  const r = await resume(s.env, { run_id: r2, step_id: a.step_id });
  assert.equal(r.status, 200, r.text);
  assert.equal(r.body.status, 'answered');
  const row = step(s.db, a.step_id);
  assert.deepEqual([row.run_id, row.status, typeof row.code_ct], [r2, 'answered', 'string']);
});

test('R3 a reclaimed run (same id, new machine and token) resumes its own step: 200, nothing written', async (t) => {
  const o = await stopped(t, { oldStatus: null }); if (!o) return;
  const { s, r1, a } = o;
  // The claim of an expired lease takes the same row and mints a new token.
  s.db.prepare("UPDATE lane_runs SET claimed_by='m2', lease_until=? WHERE id=?").run(iso(NOW_MS + 3600e3), r1);
  s.db.prepare('UPDATE web_vault_run_token SET machine=?, token_hash=? WHERE run_id=?').run('m2', sha(TOKEN2), r1);
  const before = JSON.stringify(step(s.db, a.step_id));
  const r = await resume(s.env, { run_id: r1, step_id: a.step_id });
  assert.equal(r.status, 200, r.text);
  assert.equal(r.body.status, 'open');
  assert.equal(JSON.stringify(step(s.db, a.step_id)), before);
});

test('R4 a repeat by the same new run is 200 and writes nothing', async (t) => {
  const o = await stopped(t); if (!o) return;
  const { s, r2, a } = o;
  assert.equal((await resume(s.env, { run_id: r2, step_id: a.step_id })).status, 200);
  const before = JSON.stringify(step(s.db, a.step_id));
  const r = await resume(s.env, { run_id: r2, step_id: a.step_id });
  assert.deepEqual([r.status, r.body.ok, r.body.status], [200, true, 'open']);
  assert.equal(JSON.stringify(step(s.db, a.step_id)), before);
});

test('R5 the new run refusals (403) and bad forms (400) write nothing', async (t) => {
  const o = await stopped(t); if (!o) return;
  const { s, r1, r2, a } = o;
  setting(s.db, 'lane.web-task.p2.allowed_domains', SITE);
  const before = JSON.stringify(step(s.db, a.step_id));
  const cases = [
    [{ run_id: r2, step_id: a.step_id }, 'fixture-run-token-guess', 403, 'bad_token'],
    [{ run_id: r2, step_id: a.step_id, machine: 'm9' }, TOKEN2, 403, 'not_claimer'],
    [{ run_id: r1, step_id: a.step_id, machine: 'm1' }, TOKEN1, 403, 'not_claimed'],
    [{ run_id: 999999, step_id: a.step_id }, TOKEN2, 403, 'no_run'],
    [{ run_id: r2, step_id: a.step_id, project: 'p2' }, TOKEN2, 403, 'wrong_project'],
    [{ run_id: r2, step_id: a.step_id, site: 'evil.example.org' }, TOKEN2, 403, 'site_not_allowed'],
  ];
  for (const [b, tok, st, why] of cases) {
    const r = await resume(s.env, b, tok);
    assert.deepEqual([r.status, r.body.refused], [st, why], `${why}: ${r.text}`);
  }
  s.db.prepare('UPDATE lane_runs SET lease_until=? WHERE id=?').run(iso(NOW_MS - 1000), r2);
  const le = await resume(s.env, { run_id: r2, step_id: a.step_id });
  assert.deepEqual([le.status, le.body.refused], [403, 'lease_expired']);
  s.db.prepare('UPDATE lane_runs SET lease_until=? WHERE id=?').run(iso(NOW_MS + 3600e3), r2);
  for (const b of [{ run_id: r2, step_id: 'x' }, { run_id: r2, step_id: 0 }, { run_id: '01', step_id: a.step_id },
    { run_id: r2, step_id: a.step_id, machine: '' }, { run_id: r2, step_id: a.step_id, site: 'https://a.example.com/' },
    { run_id: r2, step_id: a.step_id, project: '' }]) {
    const r = await resume(s.env, b);
    assert.equal(r.status, 400, `${JSON.stringify(b)}: ${r.text}`);
  }
  const wrong = await call(s.env, '/api/web-task/human/resume', { run_id: r2, step_id: a.step_id, machine: 'm2', project: 'p1', site: SITE }, null);
  assert.equal(wrong.status, 403, 'no run token: refused');
  assert.equal(JSON.stringify(step(s.db, a.step_id)), before, 'no refusal wrote the step');
});

test('R6 no_step, other_task, old_nonce, already_answered, cancelled and expired write nothing', async (t) => {
  const o = await stopped(t); if (!o) return;
  const { s, r2, a } = o;
  setting(s.db, 'lane.web-task.p1.allowed_domains', `${SITE},b.example.com`);
  const ns = await resume(s.env, { run_id: r2, step_id: a.step_id + 1000 });
  assert.deepEqual([ns.status, ns.body.refused], [404, 'no_step']);
  const ot = await resume(s.env, { run_id: r2, step_id: a.step_id, site: 'b.example.com' });
  assert.deepEqual([ot.status, ot.body.refused], [403, 'other_task'], 'same project, another site');
  const byStatus = [['superseded', 409, 'old_nonce'], ['consumed', 409, 'already_answered'], ['cancelled', 409, 'cancelled']];
  for (const [st, code, why] of byStatus) {
    s.db.prepare('UPDATE web_task_human_step SET status=? WHERE id=?').run(st, a.step_id);
    const r = await resume(s.env, { run_id: r2, step_id: a.step_id });
    assert.deepEqual([r.status, r.body.refused], [code, why], st);
    assert.notEqual(step(s.db, a.step_id).run_id, r2, `${st}: not rebound`);
  }
  s.db.prepare("UPDATE web_task_human_step SET status='open', expires_at=? WHERE id=?").run(NOW, a.step_id);
  const ex = await resume(s.env, { run_id: r2, step_id: a.step_id });
  assert.deepEqual([ex.status, ex.body.refused], [410, 'expired'], 'expires_at = now exactly is expired');
  assert.notEqual(step(s.db, a.step_id).run_id, r2);
  s.db.prepare('UPDATE web_task_human_step SET expires_at=? WHERE id=?').run(iso(NOW_MS + 1000), a.step_id);
  assert.equal((await resume(s.env, { run_id: r2, step_id: a.step_id })).status, 200, 'one second before expiry is fine');
});

test('R7 run_live: an old run with a live lease keeps its step (lane_runs_live dropped to reach it)', async (t) => {
  const s = await store(t); if (!s) return;
  // lane_runs_live allows one queued/claimed run per (lane, project), so a
  // second claimed run of p1 cannot exist today. The guard is defence in
  // depth; dropping the index in this test DB is the only way to reach it.
  s.db.exec('DROP INDEX lane_runs_live');
  setting(s.db, 'lane.web-task.p1.allowed_domains', SITE);
  const r1 = run(s.db);
  const a = (await askOf(s.env, { run_id: r1 })).body;
  const r2 = run(s.db, { machine: 'm2', token: TOKEN2 });
  const r = await resume(s.env, { run_id: r2, step_id: a.step_id });
  assert.deepEqual([r.status, r.body.refused], [409, 'run_live'], r.text);
  assert.equal(step(s.db, a.step_id).run_id, r1);
  // The same old run, lease passed: the step is taken over.
  s.db.prepare('UPDATE lane_runs SET lease_until=? WHERE id=?').run(NOW, r1);
  const r3 = await resume(s.env, { run_id: r2, step_id: a.step_id });
  assert.equal(r3.status, 200, r3.text);
  assert.equal(step(s.db, a.step_id).run_id, r2);
});

test('R8 raced: another rebind wins between the read and the UPDATE: 409 raced, the winner kept', async (t) => {
  let db = null, race = null;
  const o = await stopped(t, { hooks: { beforeRun: (sql, binds) => {
    if (race && /SET run_id=\?1/.test(sql)) { const w = race; race = null; db.prepare('UPDATE web_task_human_step SET run_id=? WHERE id=?').run(w, binds[1]); }
  } } });
  if (!o) return;
  const { s, r2, a } = o;
  db = s.db;
  race = 777777;
  const r = await resume(s.env, { run_id: r2, step_id: a.step_id });
  assert.deepEqual([r.status, r.body.refused], [409, 'raced'], r.text);
  assert.equal(step(s.db, a.step_id).run_id, 777777, 'the winner is kept');
});

test('R9 after a rebind the poll serves the new run, refuses the old one; no code or nonce in the resume answer', async (t) => {
  const o = await stopped(t); if (!o) return;
  const { s, r1, r2, a } = o;
  const ans = await call(s.env, '/api/web-task/answer', { run_id: r1, step_id: a.step_id, nonce: a.nonce, action: 'code', code: CODE });
  assert.equal(ans.status, 200);
  const r = await resume(s.env, { run_id: r2, step_id: a.step_id });
  assert.equal(r.status, 200);
  assert.equal(r.text.includes(CODE), false, 'no code in the resume answer');
  assert.equal(r.text.includes(a.nonce), false, 'no nonce in the resume answer');
  // Run 1 is done, so it is refused before the step check; with a live run
  // row it would get other_run. Pin both.
  const old = await poll(s.env, { run_id: r1, machine: 'm1', step_id: a.step_id }, TOKEN1);
  assert.deepEqual([old.status, old.body.refused], [403, 'not_claimed']);
  s.db.prepare("UPDATE lane_runs SET status='claimed', project='p1-old' WHERE id=?").run(r1);
  const other = await poll(s.env, { run_id: r1, machine: 'm1', step_id: a.step_id }, TOKEN1);
  assert.deepEqual([other.status, other.body.refused], [403, 'other_run']);
  const p = await poll(s.env, { run_id: r2, machine: 'm2', step_id: a.step_id }, TOKEN2);
  assert.deepEqual([p.status, p.body.state, p.body.action, p.body.code], [200, 'answered', 'code', CODE]);
  const again = await resume(s.env, { run_id: r2, step_id: a.step_id });
  assert.deepEqual([again.status, again.body.status], [200, 'consumed'], 'the idempotent answer reports the step as it is');
  assert.equal(again.text.includes(CODE), false);
});

test('R10 the 200 path makes 4 parallel reads and 1 UPDATE', async (t) => {
  const o = await stopped(t); if (!o) return;
  const { s, r2, a } = o;
  const log = [];
  const inner = d1(s.db);
  const DB = {
    prepare(sql) {
      const st = inner.prepare(sql);
      const api = {
        bind(...v) { st.bind(...v); return api; },
        first(c) { log.push(['read', sql]); return st.first(c); },
        all() { log.push(['read', sql]); return st.all(); },
        run() { log.push(['write', sql]); return st.run(); },
      };
      return api;
    },
    batch(x) { log.push(['batch', x.length]); return inner.batch(x); },
  };
  const r = await resume({ ...s.env, DB }, { run_id: r2, step_id: a.step_id });
  assert.equal(r.status, 200, r.text);
  assert.equal(log.filter((x) => x[0] === 'read').length, 4, JSON.stringify(log));
  assert.deepEqual(log.filter((x) => x[0] !== 'read').map((x) => x[0]), ['write'], JSON.stringify(log));
  assert.ok(log.some((x) => /FROM web_task_human_step s LEFT JOIN lane_runs r ON r\.id = s\.run_id WHERE s\.id = \?1/.test(x[1])), 'the step read joins the old run by PK');
});
