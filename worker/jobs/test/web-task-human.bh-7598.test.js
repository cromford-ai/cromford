// BH-7598 (slice C0): a person completes a 2FA step of a web-task run.
//
// Driven through the REAL worker.fetch over a node:sqlite D1 with the composed
// jobs schema. The clock is pinned (D60). Codes are `fixture`-free digits on
// purpose only where the format needs digits; tokens and keys carry `fixture`.
//
// K1      the table, its 3 indexes and its 5 seed rows
// A1-A5   ask: a claimed run gets a step; refusals write no row; a second ask
//         supersedes the first; the wait is a knob read; the Telegram chat and
//         the login list come from settings rows
// N1-N6   the answer decision table (accepts and refusals; a refusal leaves
//         the row unchanged); the code at rest is ciphertext; key missing
// L1      an answer after wait_until but before expires_at is stored
// P1-P4   poll: a code is returned once; another run's step and a bad token
//         are refused; approve, cancel and superseded; channel outcomes
// P5      a lost race: a second answer or a second poll that wins between the
//         read and the conditional UPDATE leaves this one with no code
// R1      retention: a 31-day-old step goes, a 1-day-old one stays; dry run
// E1      EXPLAIN QUERY PLAN at 5,000 steps: every hot read uses an index;
//         the ask makes 3 reads
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import { plan, fullScans, capturingD1 } from './lib/d1-volume.bh-6727.js';
import { RULES } from '../src/routes/retention.js';
import { createHash } from 'node:crypto';

// Loaded by dynamic import, so each case fails on its own while the module is absent.
const HUMAN = await import('../src/routes/web-task-human.js').catch(() => null);

const SECRET = 'fixture-harness-secret';
const KEY1 = Buffer.from('fixture-key-web-vault-bh7595-001').toString('base64');
const NOW_MS = Date.parse('2026-10-23T12:00:00Z');
const DAY = 86400e3;
const iso = (ms) => new Date(ms).toISOString().replace(/\.\d{3}Z$/, 'Z');
const ago = (days) => iso(NOW_MS - days * DAY);
const NOW = iso(NOW_MS);
const SITE = 'app.example.com';
const RUN_TOKEN = 'fixture-run-token-7598';
const PROMPT = 'Enter the 6-digit code sent to your phone';
const CODE = '481516';
const sha = (x) => createHash('sha256').update(x).digest('hex');

async function store(t, extra = {}, hooks = {}) {
  t.mock.timers.enable({ apis: ['Date'], now: NOW_MS });
  const o = await openDb(hooks);
  if (!o) { t.skip('node:sqlite unavailable'); return null; }
  const env = { DB: o.DB, HARNESS_SECRET: SECRET, WEB_VAULT_KEY_1: KEY1, ...extra };
  return { db: o.db, env };
}

async function call(env, path, body, { bearer = SECRET, runToken = null } = {}) {
  const headers = { 'content-type': 'application/json' };
  if (bearer !== null) headers.authorization = `Bearer ${bearer}`;
  if (runToken !== null) headers['x-web-vault-run-token'] = runToken;
  const res = await worker.fetch(new Request(`https://jobs.test${path}`, {
    method: 'POST', headers, body: JSON.stringify(body),
  }), env);
  const text = await res.text();
  let parsed = null;
  try { parsed = JSON.parse(text); } catch { parsed = { raw: text }; }
  return { status: res.status, body: parsed };
}

function setting(db, key, value) {
  db.prepare(`INSERT INTO settings (key,value,note,actor,updated_at) VALUES (?,?,'',?,?)
              ON CONFLICT(key) DO UPDATE SET value=excluded.value`).run(key, String(value), 'test', NOW);
}
// A claimed web-task lane_runs row, plus the run-token row its claim minted.
function run(db, { project = 'p1', claimed_by = 'm1', token = RUN_TOKEN } = {}) {
  const id = Number(db.prepare(`INSERT INTO lane_runs (lane, project, args_json, enqueued_at, claimed_at, claimed_by, lease_until, attempts, status)
                            VALUES ('web-task', ?, '[]', ?, ?, ?, ?, 1, 'claimed')`)
    .run(project, NOW, NOW, claimed_by, iso(NOW_MS + 3600e3)).lastInsertRowid);
  db.prepare('INSERT INTO web_vault_run_token (run_id, machine, token_hash, created_at) VALUES (?, ?, ?, ?)').run(id, claimed_by, sha(token), NOW);
  return id;
}
const allow = (db, project = 'p1', list = SITE) => setting(db, `lane.web-task.${project}.allowed_domains`, list);
const steps = (db) => db.prepare('SELECT * FROM web_task_human_step ORDER BY id').all().map((r) => ({ ...r }));
const step = (db, id) => ({ ...db.prepare('SELECT * FROM web_task_human_step WHERE id=?').get(id) });
const n = (db) => Number(db.prepare('SELECT COUNT(*) AS n FROM web_task_human_step').get().n);

const ask = (env, b = {}, token = RUN_TOKEN) =>
  call(env, '/api/web-task/human/ask', { machine: 'm1', project: 'p1', site: SITE, kind: 'code', prompt: PROMPT, ...b }, { runToken: token });
const answer = (env, b) => call(env, '/api/web-task/answer', b);
const poll = (env, b, token = RUN_TOKEN) => call(env, '/api/web-task/human/poll', { machine: 'm1', ...b }, { runToken: token });

// A seeded run with one open step: {s, id, a} where a is the ask answer body.
async function opened(t, b = {}, extra = {}) {
  const s = await store(t, extra); if (!s) return null;
  allow(s.db, b.project || 'p1');
  const id = run(s.db, { project: b.project || 'p1' });
  const r = await ask(s.env, { run_id: id, ...b });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  return { s, id, a: r.body };
}

// ── K1 ──────────────────────────────────────────────────────────────────────
test('K1 the table, its 3 indexes and its 5 seed rows exist', async (t) => {
  const s = await store(t); if (!s) return;
  const idx = Object.fromEntries(s.db.prepare("SELECT name, sql FROM sqlite_master WHERE type='index' AND tbl_name='web_task_human_step'").all().map((r) => [r.name, r.sql]));
  assert.match(idx.uq_web_task_human_nonce || '', /UNIQUE INDEX[^(]*\(nonce_hash\)/);
  assert.match(idx.idx_web_task_human_run || '', /\(run_id, status\)/);
  assert.match(idx.idx_web_task_human_created || '', /\(created_at\)/);
  const seeds = Object.fromEntries(s.db.prepare("SELECT key, value FROM settings WHERE key LIKE 'web_task.human_%' OR key = 'retention.web_task_human_step.days'").all().map((r) => [r.key, r.value]));
  assert.deepEqual(Object.keys(seeds).sort(), [
    'retention.web_task_human_step.days', 'web_task.human_answer_ttl_s', 'web_task.human_logins',
    'web_task.human_poll_s', 'web_task.human_wait_s',
  ]);
  assert.equal(seeds['web_task.human_wait_s'], '300');
  assert.equal(seeds['web_task.human_poll_s'], '5');
  assert.equal(seeds['web_task.human_answer_ttl_s'], '86400');
  assert.equal(seeds['web_task.human_logins'], 'operator');
  assert.equal(seeds['retention.web_task_human_step.days'], '30');
  const cols = s.db.prepare('PRAGMA table_info(web_task_human_step)').all().map((c) => c.name);
  assert.ok(cols.includes('nonce_hash') && cols.includes('code_ct') && cols.includes('code_iv'));
  assert.equal(cols.some((c) => /^(nonce|code)$/.test(c)), false, 'no plain nonce or code column');
});

// ── A1-A5 ───────────────────────────────────────────────────────────────────
test('A1 ask: a claimed run gets a step; D1 keeps the nonce hash only', async (t) => {
  const o = await opened(t); if (!o) return;
  const { s, id, a } = o;
  assert.equal(typeof a.step_id, 'number');
  assert.match(a.nonce, /^[A-Za-z0-9_-]{22}$/);
  assert.ok(Buffer.byteLength(`wt:${a.step_id}:${a.nonce}:d`) <= 64, 'fits Telegram callback_data');
  assert.equal(a.wait_until, iso(NOW_MS + 300e3));
  assert.equal(a.expires_at, iso(NOW_MS + DAY));
  assert.equal(a.poll_s, 5);
  assert.deepEqual(a.logins, ['operator']);
  assert.equal(a.tg_chat, null, 'no chat row: null, never a guess');
  const row = step(s.db, a.step_id);
  assert.deepEqual([row.run_id, row.project, row.site, row.kind, row.prompt, row.status], [id, 'p1', SITE, 'code', PROMPT, 'open']);
  assert.equal(row.nonce_hash, sha(a.nonce));
  assert.equal(JSON.stringify(steps(s.db)).includes(a.nonce), false, 'no cell holds the nonce');
});

test('A2 ask: bad_token, wrong_project, site_not_allowed are 403 with no row; bad input is 400', async (t) => {
  const s = await store(t); if (!s) return;
  allow(s.db);
  const id = run(s.db);
  const cases = [
    [{ run_id: id }, 'fixture-run-token-guess', 'bad_token'],
    [{ run_id: id, project: 'p2' }, RUN_TOKEN, 'wrong_project'],
    [{ run_id: id, site: 'evil.example.org' }, RUN_TOKEN, 'site_not_allowed'],
    [{ run_id: id, machine: 'm2' }, RUN_TOKEN, 'not_claimer'],
    [{ run_id: id + 100 }, RUN_TOKEN, 'no_run'],
  ];
  for (const [b, tok, why] of cases) {
    const r = await ask(s.env, b, tok);
    assert.equal(r.status, 403, why);
    assert.equal(r.body.refused, why);
  }
  for (const b of [{ kind: 'captcha' }, { prompt: '' }, { prompt: 'x'.repeat(513) }, { prompt: 'line one\nline two' }, { run_id: 'x' }]) {
    const r = await ask(s.env, { run_id: id, ...b });
    assert.equal(r.status, 400, JSON.stringify(b));
  }
  assert.equal(n(s.db), 0);
  assert.equal((await ask(s.env, { run_id: id, prompt: 'x'.repeat(512) })).status, 200, '512 bytes is in bounds');
});

test('A3 ask: a second ask of the same run supersedes the first', async (t) => {
  const o = await opened(t); if (!o) return;
  const { s, id, a } = o;
  const b = await ask(s.env, { run_id: id, kind: 'approve', prompt: 'Approve the sign-in on your phone' });
  assert.equal(b.status, 200);
  assert.notEqual(b.body.nonce, a.nonce);
  assert.equal(step(s.db, a.step_id).status, 'superseded');
  assert.equal(step(s.db, b.body.step_id).status, 'open');
});

test('A4 ask: the wait, the poll and the TTL are settings reads', async (t) => {
  const s = await store(t); if (!s) return;
  allow(s.db);
  setting(s.db, 'web_task.human_wait_s', 60);
  setting(s.db, 'web_task.human_poll_s', 2);
  setting(s.db, 'web_task.human_answer_ttl_s', 7200);
  const r = await ask(s.env, { run_id: run(s.db) });
  assert.deepEqual([r.body.wait_until, r.body.poll_s, r.body.expires_at], [iso(NOW_MS + 60e3), 2, iso(NOW_MS + 7200e3)]);
  setting(s.db, 'web_task.human_wait_s', 'junk');
  setting(s.db, 'web_task.human_answer_ttl_s', 60);
  allow(s.db, 'p2');
  const r2 = await ask(s.env, { run_id: run(s.db, { project: 'p2' }), project: 'p2' });
  assert.equal(r2.body.wait_until, iso(NOW_MS + 300e3), 'a bad row takes the documented fallback');
  assert.equal(r2.body.expires_at, r2.body.wait_until, 'expires_at is never before wait_until');
});

test('A5 ask: the Telegram chat and the logins come from settings rows', async (t) => {
  const s = await store(t); if (!s) return;
  allow(s.db);
  setting(s.db, 'lib.lane-alert.lane_alert_dm_chat', '1000000001');
  setting(s.db, 'web_task.human_logins', 'operator, fixture-op ,bad login');
  const r = await ask(s.env, { run_id: run(s.db) });
  assert.equal(r.body.tg_chat, '1000000001');
  assert.deepEqual(r.body.logins, ['operator', 'fixture-op']);
});

// ── N1-N6: the answer decision table ───────────────────────────────────────
test('N1 answer accepts: plain code, Telegram reply code, callback done, callback cancel', async (t) => {
  const o = await opened(t); if (!o) return;
  const { s, id, a } = o;
  const r = await answer(s.env, { run_id: id, step_id: a.step_id, nonce: a.nonce, action: 'code', code: CODE });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(JSON.stringify(r.body).includes(CODE), false, 'the answer never echoes the code');
  let row = step(s.db, a.step_id);
  assert.deepEqual([row.status, row.answer_via, row.answered_at], ['answered', 'api', NOW]);
  // A Telegram reply to the photo ask (its text is the caption).
  const b = (await ask(s.env, { run_id: id })).body;
  const tr = await answer(s.env, { message: { text: ` ${CODE} `, reply_to_message: { caption: `p1 on ${SITE}\n${PROMPT}\nref: wt:${b.step_id}:${b.nonce}` } } });
  assert.equal(tr.status, 200, JSON.stringify(tr.body));
  row = step(s.db, b.step_id);
  assert.deepEqual([row.status, row.answer_via], ['answered', 'telegram']);
  const c = (await ask(s.env, { run_id: id, kind: 'approve', prompt: 'Approve on your phone' })).body;
  assert.equal((await answer(s.env, { callback_query: { data: `wt:${c.step_id}:${c.nonce}:d` } })).status, 200);
  row = step(s.db, c.step_id);
  assert.deepEqual([row.status, row.answer_via, row.code_ct], ['answered', 'telegram', null]);
  const d = (await ask(s.env, { run_id: id, kind: 'approve', prompt: 'Approve on your phone' })).body;
  assert.equal((await answer(s.env, { callback_query: { data: `wt:${d.step_id}:${d.nonce}:c` } })).status, 200);
  assert.equal(step(s.db, d.step_id).status, 'cancelled');
  const e = (await ask(s.env, { run_id: id, kind: 'approve', prompt: 'Approve on your phone' })).body;
  assert.equal((await answer(s.env, { run_id: id, step_id: e.step_id, nonce: e.nonce, action: 'done', via: 'board' })).status, 200);
  assert.equal(step(s.db, e.step_id).answer_via, 'board');
});

test('N2 answer refuses a wrong nonce, another step, another run, an old nonce, an expired nonce and a second answer', async (t) => {
  const o = await opened(t); if (!o) return;
  const { s, id, a } = o;
  const other = run(s.db, { project: 'p2' });   // one live run per (lane, project)
  const flip = a.nonce.slice(0, -1) + (a.nonce.endsWith('A') ? 'B' : 'A');
  const ok = { run_id: id, step_id: a.step_id, nonce: a.nonce, action: 'code', code: CODE };
  const before = step(s.db, a.step_id);
  for (const [b, status, why] of [
    [{ ...ok, nonce: flip }, 403, 'bad_nonce'],
    [{ ...ok, step_id: a.step_id + 1 }, 403, 'bad_nonce'],
    [{ ...ok, run_id: other }, 403, 'other_run'],
    [{ callback_query: { data: `wt:${a.step_id}:${flip}:d` } }, 403, 'bad_nonce'],
  ]) {
    const r = await answer(s.env, b);
    assert.equal(r.status, status, JSON.stringify(b));
    assert.equal(r.body.refused, why, JSON.stringify(b));
    assert.deepEqual(step(s.db, a.step_id), before, 'a refusal leaves the row unchanged');
  }
  // An old nonce: a second ask supersedes the first step.
  const b2 = (await ask(s.env, { run_id: id })).body;
  const old = await answer(s.env, ok);
  assert.deepEqual([old.status, old.body.refused], [409, 'old_nonce']);
  assert.equal(step(s.db, a.step_id).code_ct, null);
  // A second answer.
  const ok2 = { ...ok, step_id: b2.step_id, nonce: b2.nonce };
  assert.equal((await answer(s.env, ok2)).status, 200);
  const snap = step(s.db, b2.step_id);
  const again = await answer(s.env, { ...ok2, code: '999999' });
  assert.deepEqual([again.status, again.body.refused], [409, 'already_answered']);
  assert.deepEqual(step(s.db, b2.step_id), snap);
  // Expired: at expires_at exactly the nonce is refused.
  const c = (await ask(s.env, { run_id: id })).body;
  t.mock.timers.setTime(Date.parse(c.expires_at));
  const ex = await answer(s.env, { ...ok, step_id: c.step_id, nonce: c.nonce });
  assert.deepEqual([ex.status, ex.body.refused], [410, 'expired']);
  assert.equal(step(s.db, c.step_id).status, 'open');
});

test('N3 answer refuses malformed Telegram updates and bad codes with 400 and writes nothing', async (t) => {
  const o = await opened(t); if (!o) return;
  const { s, id, a } = o;
  const ap = (await ask(s.env, { run_id: id, kind: 'approve', prompt: 'Approve on your phone' })).body;
  const cd = (await ask(s.env, { run_id: id })).body;   // supersedes ap: the 400s below come before any row check
  const ref = `ref: wt:${cd.step_id}:${cd.nonce}`;
  const before = steps(s.db);
  for (const b of [
    {},
    { callback_query: { data: `wt:${cd.step_id}:${cd.nonce}:x` } },
    { callback_query: { data: `wt:${cd.step_id}:${cd.nonce}` } },
    { callback_query: { data: `archie:approve:${cd.step_id}` } },
    { message: { text: CODE, reply_to_message: { text: `> ${ref}` } } },
    { message: { text: CODE, reply_to_message: { text: `see ${ref} here` } } },
    { message: { text: CODE, reply_to_message: { text: 'an unrelated message' } } },
    { message: { text: CODE } },
    { message: { text: '', reply_to_message: { text: ref } } },
    { message: { text: '12 34', reply_to_message: { text: ref } } },
    { message: { text: '1'.repeat(40), reply_to_message: { text: ref } } },
    { run_id: id, step_id: cd.step_id, nonce: cd.nonce, action: 'maybe' },
    { run_id: id, step_id: cd.step_id, nonce: cd.nonce, action: 'code' },
    { run_id: id, step_id: cd.step_id, nonce: cd.nonce, action: 'code', code: 'a b' },
    { run_id: id, step_id: cd.step_id, nonce: cd.nonce, action: 'code', code: CODE, via: 'carrier-pigeon' },
  ]) {
    const r = await answer(s.env, b);
    assert.equal(r.status, 400, JSON.stringify(b));
  }
  assert.deepEqual(steps(s.db), before);
  // Kind mismatches: refused 400 after the nonce matched, nothing written.
  const ap2 = (await ask(s.env, { run_id: id, kind: 'approve', prompt: 'Approve on your phone' })).body;
  const r1 = await answer(s.env, { run_id: id, step_id: ap2.step_id, nonce: ap2.nonce, action: 'code', code: CODE });
  assert.equal(r1.status, 400, 'a code on an approve step');
  const cd2 = (await ask(s.env, { run_id: id })).body;
  const r2 = await answer(s.env, { callback_query: { data: `wt:${cd2.step_id}:${cd2.nonce}:d` } });
  assert.equal(r2.status, 400, 'done on a code step');
  assert.equal(step(s.db, cd2.step_id).status, 'open');
  assert.equal((await call(s.env, '/api/web-task/answer', { callback_query: { data: `wt:${cd2.step_id}:${cd2.nonce}:c` } }, { bearer: null })).status, 401, 'bearer-gated');
  void a; void ap;
});

test('N4 answer: the code at rest is ciphertext with an iv', async (t) => {
  const o = await opened(t); if (!o) return;
  const { s, id, a } = o;
  assert.equal((await answer(s.env, { run_id: id, step_id: a.step_id, nonce: a.nonce, action: 'code', code: CODE })).status, 200);
  const row = step(s.db, a.step_id);
  assert.ok(row.code_ct && row.code_iv, 'ciphertext and iv set');
  assert.equal(row.key_id, 1);
  assert.equal(JSON.stringify(steps(s.db)).includes(CODE), false, 'no cell holds the code');
});

test('N5 answer: key missing is 503 and nothing is written', async (t) => {
  const o = await opened(t, {}, { WEB_VAULT_KEY_1: '' }); if (!o) return;
  const { s, id, a } = o;
  const r = await answer(s.env, { run_id: id, step_id: a.step_id, nonce: a.nonce, action: 'code', code: CODE });
  assert.equal(r.status, 503);
  assert.equal(step(s.db, a.step_id).status, 'open');
});

test('L1 an answer after wait_until but before expires_at is stored for the resume', async (t) => {
  const o = await opened(t); if (!o) return;
  const { s, id, a } = o;
  t.mock.timers.setTime(Date.parse(a.wait_until) + 3600e3);
  assert.equal((await answer(s.env, { run_id: id, step_id: a.step_id, nonce: a.nonce, action: 'code', code: CODE })).status, 200);
  assert.equal(step(s.db, a.step_id).status, 'answered');
});

// ── P1-P4: poll ────────────────────────────────────────────────────────────
test('P1 poll: pending, then the code once; the second poll is consumed with no code and no ciphertext', async (t) => {
  const o = await opened(t); if (!o) return;
  const { s, id, a } = o;
  const p0 = await poll(s.env, { run_id: id, step_id: a.step_id });
  assert.deepEqual([p0.status, p0.body.state, p0.body.wait_until], [200, 'pending', a.wait_until]);
  await answer(s.env, { run_id: id, step_id: a.step_id, nonce: a.nonce, action: 'code', code: CODE });
  const p1 = await poll(s.env, { run_id: id, step_id: a.step_id });
  assert.deepEqual([p1.status, p1.body.state, p1.body.action, p1.body.code], [200, 'answered', 'code', CODE]);
  const row = step(s.db, a.step_id);
  assert.deepEqual([row.status, row.code_ct, row.code_iv, row.consumed_at], ['consumed', null, null, NOW]);
  const p2 = await poll(s.env, { run_id: id, step_id: a.step_id });
  assert.equal(p2.body.state, 'consumed');
  assert.equal('code' in p2.body, false);
});

test('P2 poll: another run\'s step is other_run; a bad token is bad_token; no step is 404', async (t) => {
  const o = await opened(t); if (!o) return;
  const { s, id, a } = o;
  const other = run(s.db, { project: 'p2' });   // one live run per (lane, project)
  await answer(s.env, { run_id: id, step_id: a.step_id, nonce: a.nonce, action: 'code', code: CODE });
  const r = await poll(s.env, { run_id: other, step_id: a.step_id });
  assert.deepEqual([r.status, r.body.refused, 'code' in r.body], [403, 'other_run', false]);
  const b = await poll(s.env, { run_id: id, step_id: a.step_id }, 'fixture-run-token-guess');
  assert.deepEqual([b.status, b.body.refused, 'code' in b.body], [403, 'bad_token', false]);
  assert.equal((await poll(s.env, { run_id: id, step_id: a.step_id + 50 })).status, 404);
  assert.equal(step(s.db, a.step_id).status, 'answered', 'a refused poll consumes nothing');
});

test('P3 poll: approve done, cancel and superseded', async (t) => {
  const o = await opened(t, { kind: 'approve', prompt: 'Approve on your phone' }); if (!o) return;
  const { s, id, a } = o;
  await answer(s.env, { callback_query: { data: `wt:${a.step_id}:${a.nonce}:d` } });
  const p = await poll(s.env, { run_id: id, step_id: a.step_id });
  assert.deepEqual([p.body.state, p.body.action], ['answered', 'done']);
  assert.equal(step(s.db, a.step_id).status, 'consumed');
  const b = (await ask(s.env, { run_id: id, kind: 'approve', prompt: 'Approve on your phone' })).body;
  await answer(s.env, { callback_query: { data: `wt:${b.step_id}:${b.nonce}:c` } });
  assert.equal((await poll(s.env, { run_id: id, step_id: b.step_id })).body.state, 'cancelled');
  const c = (await ask(s.env, { run_id: id })).body;
  await ask(s.env, { run_id: id });
  const sp = await poll(s.env, { run_id: id, step_id: c.step_id });
  assert.deepEqual([sp.status, sp.body.refused], [409, 'old_nonce']);
});

test('P4 poll: the channel outcomes are written once, as given', async (t) => {
  const o = await opened(t); if (!o) return;
  const { s, id, a } = o;
  await poll(s.env, { run_id: id, step_id: a.step_id, tg_outcome: 'sent 77', board_outcome: 'not-configured: issue' });
  await poll(s.env, { run_id: id, step_id: a.step_id, tg_outcome: 'sent 78' });
  const row = step(s.db, a.step_id);
  assert.deepEqual([row.tg_outcome, row.board_outcome], ['sent 77', 'not-configured: issue']);
});

test('P5 a lost race between the read and the conditional UPDATE: 409, and the poll gives no code', async (t) => {
  // beforeRun fires just before each write: another answer or poll wins there.
  let db = null, race = null;
  const s = await store(t, {}, { beforeRun: (sql, binds) => { if (race && race.test(sql)) { race = null; db.prepare("UPDATE web_task_human_step SET status='consumed', code_ct=NULL, code_iv=NULL WHERE id=?").run(binds[0]); } } });
  if (!s) return;
  db = s.db;
  allow(s.db);
  const id = run(s.db);
  const a = (await ask(s.env, { run_id: id })).body;
  race = /SET status=\?2, answered_at/;
  const r = await answer(s.env, { run_id: id, step_id: a.step_id, nonce: a.nonce, action: 'code', code: CODE });
  assert.deepEqual([r.status, r.body.refused], [409, 'already_answered'], 'the answer lost the race');
  const b = (await ask(s.env, { run_id: id })).body;
  assert.equal((await answer(s.env, { run_id: id, step_id: b.step_id, nonce: b.nonce, action: 'code', code: CODE })).status, 200);
  race = /SET status='consumed'/;
  const p = await poll(s.env, { run_id: id, step_id: b.step_id });
  assert.deepEqual([p.status, p.body.refused, 'code' in p.body], [409, 'already_consumed', false], 'a poll that lost the race gives no code');
});

// ── R1 ──────────────────────────────────────────────────────────────────────
test('R1 retention: the seeded dry run deletes nothing; dry_run 0 deletes a 31-day-old step and keeps a 1-day-old one', async (t) => {
  const s = await store(t); if (!s) return;
  const ins = s.db.prepare(`INSERT INTO web_task_human_step (run_id, project, site, kind, prompt, nonce_hash, status, created_at, wait_until, expires_at)
                            VALUES (1, 'p1', 'a.example.com', 'code', 'x', ?, 'open', ?, ?, ?)`);
  ins.run('h-old', ago(31), ago(31), ago(30));
  ins.run('h-new', ago(1), ago(1), NOW);
  const rule = RULES.find((r) => r.rule === 'web_task_human_step.age');
  assert.ok(rule, 'the retention rule exists');
  assert.equal(rule.key, 'retention.web_task_human_step.days');
  const ruleOf = (body) => (body.rules || []).find((x) => x.rule === 'web_task_human_step.age');
  const dry = await call(s.env, '/api/retention/run', {});
  assert.equal(dry.body.dry_run, true);
  assert.deepEqual({ counted: ruleOf(dry.body).counted, removed: ruleOf(dry.body).removed }, { counted: 1, removed: 0 });
  assert.equal(n(s.db), 2);
  setting(s.db, 'retention.dry_run', '0');
  const wet = ruleOf((await call(s.env, '/api/retention/run', {})).body);
  assert.deepEqual({ removed: wet.removed, error: wet.error }, { removed: 1, error: null });
  assert.deepEqual(steps(s.db).map((r) => r.nonce_hash), ['h-new']);
});

// ── E1 ──────────────────────────────────────────────────────────────────────
test('E1 at 5,000 steps every hot read uses an index; the ask makes 3 reads', async (t) => {
  const s = await store(t); if (!s) return;
  s.db.exec('BEGIN');
  const ins = s.db.prepare(`INSERT INTO web_task_human_step (run_id, project, site, kind, prompt, nonce_hash, status, created_at, wait_until, expires_at)
                            VALUES (?, 'p9', 'a.example.com', 'code', 'x', ?, ?, ?, ?, ?)`);
  for (let i = 0; i < 5000; i++) ins.run(500000 + Math.floor(i / 3), `h${i}`, ['consumed', 'superseded', 'cancelled'][i % 3], ago(i % 40), ago(i % 40), ago(i % 40));
  s.db.exec('COMMIT');
  s.db.exec('ANALYZE');
  allow(s.db);
  const id = run(s.db);
  const log = [];
  const env = { ...s.env, DB: capturingD1(s.db, log) };
  const a = await ask(env, { run_id: id });
  assert.equal(a.status, 200);
  assert.equal(log.length, 3, `the ask reads: ${log.map((x) => x.sql).join(' | ')}`);
  await answer(env, { run_id: id, step_id: a.body.step_id, nonce: a.body.nonce, action: 'code', code: CODE });
  await poll(env, { run_id: id, step_id: a.body.step_id });
  assert.ok(HUMAN, 'src/routes/web-task-human.js exists');
  const hot = log.filter((x) => /\bweb_task_human_step\b/.test(x.sql));
  assert.ok(hot.length >= 2, `captured ${hot.length} step reads`);
  hot.push({ sql: HUMAN.SUPERSEDE_SQL, binds: [id] });
  hot.push({ sql: HUMAN.ANSWER_SQL, binds: [a.body.step_id, 'answered', NOW, 'api', null, null, null] });
  hot.push({ sql: RULES.find((r) => r.rule === 'web_task_human_step.age').ids, binds: [ago(30), 500] });
  for (const { sql, binds } of hot) {
    const lines = plan(s.db, sql, ...binds.map((b) => (b === undefined ? null : b)));
    assert.deepEqual(fullScans(lines, ['web_task_human_step']), [], `${sql}\n${lines.join('\n')}`);
    assert.ok(lines.some((l) => /USING (COVERING )?INDEX (uq_web_task_human_nonce|idx_web_task_human_\w+)|USING INTEGER PRIMARY KEY/.test(l)), `${sql}\n${lines.join('\n')}`);
  }
  const named = (sql, binds, idx) => assert.ok(plan(s.db, sql, ...binds).some((l) => l.includes(idx)), `${sql} uses ${idx}`);
  named(HUMAN.STEP_BY_NONCE_SQL, ['h1'], 'uq_web_task_human_nonce');
  named(HUMAN.SUPERSEDE_SQL, [id], 'idx_web_task_human_run');
  named(RULES.find((r) => r.rule === 'web_task_human_step.age').ids, [ago(30), 500], 'idx_web_task_human_created');
});
