// BH-7597 (slice C0): saved browser sessions of the web-task lane.
//
// Driven through the REAL worker.fetch over a node:sqlite D1 with the composed
// jobs schema. The clock is pinned (D60). Every session value is a
// `fixture-session-*` string and the AES key is built from a `fixture-key-*`
// string (D47). Each case opens its own database and seeds its own runs.
//
// K1       the settings row lane.web-task.session_max_days = 14
// K2       the settings row lane.web-task.session_max_bytes = 262144
// SV1-SV4  save: round trip of a 20 KB storageState; replace; the field is
//          fixed to session_state; size (from the row), empty and NUL bounds
// SZ1-SZ5  the size cap is DB-driven: row 1024; the run checks come before
//          the size check; bad rows fall back to 262144; a spaced row is
//          trimmed; no bare literal cap in the source
// D1-D12   the refusal table, on save AND load; each writes one audit row
// OK1-OK3  the pass cases: lease 1 s ahead; site in mixed case; a re-claim
// LD1-LD6  load: no_entry; the audit row and last_used_at; the age edges;
//          DB-driven age; a bad setting falls back to 14; key missing
// VR1      /api/web-vault/read refuses field session_state
// VR2      that refusal comes after the run checks (bad token is bad_token)
// P1       no stored cell and no console line holds a session value
// E1       EXPLAIN QUERY PLAN of the routes' reads at 20,000 web_vault rows
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import { plan, fullScans, capturingD1 } from './lib/d1-volume.bh-6727.js';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { UPSERT_SQL, TOUCH_SQL } from '../src/routes/web-vault.js';

const SECRET = 'fixture-harness-secret';
const ADMIN = 'fixture-admin-token-7597';
const KEY1 = Buffer.from('fixture-key-web-session-bh7597-1').toString('base64');
const NOW_MS = Date.parse('2026-10-22T12:00:00Z');
const DAY = 86400e3;
const iso = (ms) => new Date(ms).toISOString().replace(/\.\d{3}Z$/, 'Z');
const NOW = iso(NOW_MS);
const SITE = 'app.example.com';
const RUN_TOKEN = 'fixture-run-token-7597';
const sha = (x) => createHash('sha256').update(x).digest('hex');
// A storageState-shaped fixture of about `kb` KB.
const state = (tag, kb = 2) => JSON.stringify({
  cookies: [{ name: 'sid', value: `fixture-session-${tag}`, domain: SITE, path: '/', expires: -1, httpOnly: true, secure: true, sameSite: 'Lax' }],
  origins: [{ origin: `https://${SITE}`, localStorage: [{ name: 'pad', value: `fixture-session-${tag}-` + 'x'.repeat(kb * 1024) }] }],
});

async function store(t, extra = {}) {
  t.mock.timers.enable({ apis: ['Date'], now: NOW_MS });
  const o = await openDb();
  if (!o) { t.skip('node:sqlite unavailable'); return null; }
  const env = { DB: o.DB, HARNESS_SECRET: SECRET, WEB_VAULT_ADMIN_TOKEN: ADMIN, WEB_VAULT_KEY_1: KEY1, ...extra };
  return { db: o.db, env };
}

async function call(env, method, path, body, { runToken = RUN_TOKEN, admin = null } = {}) {
  const headers = { 'content-type': 'application/json', authorization: `Bearer ${SECRET}` };
  if (runToken !== null) headers['x-web-vault-run-token'] = runToken;
  if (admin !== null) headers['x-web-vault-admin-token'] = admin;
  const res = await worker.fetch(new Request(`https://jobs.test${path}`, {
    method, headers, body: body === undefined ? undefined : JSON.stringify(body),
  }), env);
  const text = await res.text();
  let parsed = null;
  try { parsed = JSON.parse(text); } catch { parsed = { raw: text }; }
  return { status: res.status, body: parsed, text };
}
const save = (env, b, token) => call(env, 'POST', '/api/web-session/save', { project: 'p1', site: SITE, machine: 'm1', ...b }, { runToken: token === undefined ? RUN_TOKEN : token });
const load = (env, b, token) => call(env, 'POST', '/api/web-session/load', { project: 'p1', site: SITE, machine: 'm1', ...b }, { runToken: token === undefined ? RUN_TOKEN : token });

function setting(db, key, value) {
  db.prepare(`INSERT INTO settings (key,value,note,actor,updated_at) VALUES (?,?,'',?,?)
              ON CONFLICT(key) DO UPDATE SET value=excluded.value`).run(key, String(value), 'test', NOW);
}
function run(db, { lane = 'web-task', project = 'p1', status = 'claimed', claimed_by = 'm1', lease_until = iso(NOW_MS + 600e3),
  token = RUN_TOKEN, token_machine = claimed_by || 'm1' } = {}) {
  const id = Number(db.prepare(`INSERT INTO lane_runs (lane, project, args_json, enqueued_at, claimed_at, claimed_by, lease_until, attempts, status)
                            VALUES (?, ?, '[]', ?, ?, ?, ?, 1, ?)`)
    .run(lane, project, NOW, NOW, claimed_by, lease_until, status).lastInsertRowid);
  if (token !== null) {
    db.prepare('INSERT INTO web_vault_run_token (run_id, machine, token_hash, created_at) VALUES (?, ?, ?, ?)').run(id, token_machine, sha(token), NOW);
  }
  return id;
}
const audits = (db) => db.prepare('SELECT * FROM web_vault_audit ORDER BY id').all();
const vaultRows = (db) => db.prepare('SELECT * FROM web_vault ORDER BY id').all();
const n = (db, table) => Number(db.prepare(`SELECT COUNT(*) AS n FROM ${table}`).get().n);
const allow = (db, project = 'p1', list = 'app.example.com,other.org') => setting(db, `lane.web-task.${project}.allowed_domains`, list);
const age = (db, ms) => db.prepare("UPDATE web_vault SET updated_at=? WHERE field='session_state'").run(iso(NOW_MS - ms));

// ── K1 ──────────────────────────────────────────────────────────────────────
test('K1 the composed schema seeds lane.web-task.session_max_days = 14', async (t) => {
  const s = await store(t); if (!s) return;
  const row = s.db.prepare("SELECT value, note FROM settings WHERE key='lane.web-task.session_max_days'").get();
  assert.ok(row, 'the settings row exists');
  assert.equal(row.value, '14');
  assert.match(row.note, /1\.\.365/);
});

test('K2 the composed schema seeds lane.web-task.session_max_bytes = 262144', async (t) => {
  const s = await store(t); if (!s) return;
  const row = s.db.prepare("SELECT value, note FROM settings WHERE key='lane.web-task.session_max_bytes'").get();
  assert.ok(row, 'the settings row exists');
  assert.equal(row.value, '262144');
  assert.match(row.note, /1024\.\.1048576/);
});

// ── SV1-SV4 ─────────────────────────────────────────────────────────────────
test('SV1 a claimed run saves a 20 KB storageState; the row is session_state, encrypted; load returns the same bytes', async (t) => {
  const s = await store(t); if (!s) return;
  allow(s.db);
  const id = run(s.db);
  const v = state('sv1', 20);
  assert.ok(Buffer.byteLength(v) > 20 * 1024);
  const w = await save(s.env, { run_id: id, value: v });
  assert.equal(w.status, 200, w.text);
  assert.equal(w.body.stored, true);
  assert.equal(w.body.saved_at, NOW);
  assert.equal(w.text.includes('fixture-session'), false, 'the save answer never echoes the value');
  const rows = vaultRows(s.db);
  assert.equal(rows.length, 1);
  assert.equal(rows[0].field, 'session_state');
  assert.equal(rows[0].project, 'p1');
  assert.equal(rows[0].site, SITE);
  assert.equal(rows[0].ciphertext.includes('fixture-session'), false);
  const r = await load(s.env, { run_id: id });
  assert.equal(r.status, 200, r.text);
  assert.equal(r.body.value, v);
  assert.equal(r.body.saved_at, NOW);
  const a = audits(s.db).map((x) => [x.action, x.outcome, x.field, x.actor, x.run_id]);
  assert.deepEqual(a, [['set', 'ok', 'session_state', 'm1', id], ['read', 'ok', 'session_state', 'm1', id]]);
});

test('SV2 a second save replaces the session: one row, updated_at moves, load returns the new value', async (t) => {
  const s = await store(t); if (!s) return;
  allow(s.db);
  const id = run(s.db);
  assert.equal((await save(s.env, { run_id: id, value: state('old') })).status, 200);
  age(s.db, 3 * DAY);
  const w = await save(s.env, { run_id: id, value: state('new') });
  assert.equal(w.status, 200, w.text);
  const rows = vaultRows(s.db);
  assert.equal(rows.length, 1);
  assert.equal(rows[0].updated_at, NOW);
  const r = await load(s.env, { run_id: id });
  assert.equal(r.body.value, state('new'));
});

test('SV3 a body with field "password" still writes only session_state', async (t) => {
  const s = await store(t); if (!s) return;
  allow(s.db);
  const id = run(s.db);
  const w = await save(s.env, { run_id: id, field: 'password', value: state('sv3') });
  assert.equal(w.status, 200, w.text);
  assert.deepEqual(vaultRows(s.db).map((r) => r.field), ['session_state']);
  assert.equal(audits(s.db).some((a) => a.field !== 'session_state'), false);
});

test('SV4 a value of 0 bytes, 262145 bytes (seeded row), with a NUL, or not a string: 400, no row, no audit row', async (t) => {
  const s = await store(t); if (!s) return;
  allow(s.db);
  const id = run(s.db);
  const max = 'fixture-session-' + 'y'.repeat(262144 - 16);
  assert.equal(Buffer.byteLength(max), 262144);
  for (const value of ['', max + 'z', 'fixture-session-\u0000-nul', 42, undefined]) {
    const w = await save(s.env, { run_id: id, value });
    assert.equal(w.status, 400, `${String(value).slice(0, 20)}: ${w.text}`);
  }
  assert.equal((await save(s.env, { run_id: id, value: max + 'z' })).body.error, 'value must be 1..262144 bytes');
  for (const b of [{ run_id: 'x', value: 'fixture-session-a' }, { run_id: id, machine: '', value: 'fixture-session-a' },
    { run_id: id, site: 'https://a.b/c', value: 'fixture-session-a' }, { run_id: id, project: '', value: 'fixture-session-a' }]) {
    assert.equal((await save(s.env, b)).status, 400, JSON.stringify(b));
  }
  assert.equal(n(s.db, 'web_vault'), 0);
  assert.equal(n(s.db, 'web_vault_audit'), 0);
  const ok = await save(s.env, { run_id: id, value: max });
  assert.equal(ok.status, 200, 'exactly 262144 bytes is taken');
  assert.equal((await load(s.env, { run_id: id })).body.value, max);
});

// ── SZ1-SZ5: the size cap is the settings row lane.web-task.session_max_bytes ─
const sized = (bytes, tag = 'sz') => {
  const head = `fixture-session-${tag}-`;
  return head + 'z'.repeat(bytes - head.length);
};

test('SZ1 row 1024: a 1024-byte value is stored, a 1025-byte value is 400 1..1024 with no audit row', async (t) => {
  const s = await store(t); if (!s) return;
  allow(s.db);
  setting(s.db, 'lane.web-task.session_max_bytes', '1024');
  const id = run(s.db);
  const over = await save(s.env, { run_id: id, value: sized(1025) });
  assert.equal(over.status, 400, over.text);
  assert.equal(over.body.error, 'value must be 1..1024 bytes');
  assert.equal(n(s.db, 'web_vault'), 0);
  assert.equal(n(s.db, 'web_vault_audit'), 0);
  const ok = await save(s.env, { run_id: id, value: sized(1024) });
  assert.equal(ok.status, 200, ok.text);
  assert.equal((await load(s.env, { run_id: id })).body.value, sized(1024));
});

test('SZ2 row 1024 and an over-cap value from a wrong token: 403 bad_token and one audit row (run checks before size)', async (t) => {
  const s = await store(t); if (!s) return;
  allow(s.db);
  setting(s.db, 'lane.web-task.session_max_bytes', '1024');
  const id = run(s.db);
  const w = await save(s.env, { run_id: id, value: sized(5000) }, 'fixture-run-token-wrong');
  assert.equal(w.status, 403, w.text);
  assert.equal(w.body.why, 'bad_token');
  assert.deepEqual(audits(s.db).map((a) => [a.action, a.outcome]), [['set', 'refused:bad_token']]);
  assert.equal(n(s.db, 'web_vault'), 0);
});

test('SZ3 a bad row (abc, 0, 1023, 1048577, -5) or no row uses 262144', async (t) => {
  const s = await store(t); if (!s) return;
  allow(s.db);
  const id = run(s.db);
  for (const v of ['abc', '0', '1023', '1048577', '-5', null]) {
    if (v === null) s.db.prepare("DELETE FROM settings WHERE key='lane.web-task.session_max_bytes'").run();
    else setting(s.db, 'lane.web-task.session_max_bytes', v);
    const ok = await save(s.env, { run_id: id, value: sized(262144, `sz3${v}`) });
    assert.equal(ok.status, 200, `${v}: ${ok.text}`);
    const over = await save(s.env, { run_id: id, value: sized(262145, `sz3${v}`) });
    assert.equal(over.body.error, 'value must be 1..262144 bytes', `${v}`);
  }
});

test('SZ4 a row " 2048 " is trimmed and used', async (t) => {
  const s = await store(t); if (!s) return;
  allow(s.db);
  setting(s.db, 'lane.web-task.session_max_bytes', ' 2048 ');
  const id = run(s.db);
  assert.equal((await save(s.env, { run_id: id, value: sized(2048) })).status, 200);
  assert.equal((await save(s.env, { run_id: id, value: sized(2049) })).body.error, 'value must be 1..2048 bytes');
});

test('SZ5 web-session.js has no bare literal size cap; the fallback names its settings row', () => {
  const src = readFileSync(new URL('../src/routes/web-session.js', import.meta.url), 'utf8').split('\n');
  const lits = src.filter((l) => /SESSION_MAX_BYTES\w* *= *\d/.test(l));
  assert.equal(lits.length, 1, lits.join('\n'));
  assert.match(lits[0], /SESSION_MAX_BYTES_DEFAULT = 262144;/);
  const i = src.indexOf(lits[0]);
  assert.match(src.slice(Math.max(0, i - 3), i + 1).join('\n'), /lane\.web-task\.session_max_bytes/);
});

// ── D1-D12: the refusal table ───────────────────────────────────────────────
// Each case: [name, setup(db) -> {run_id, ...body}, token, why]
const REFUSALS = [
  ['D1 no run', () => ({ run_id: 999999 }), RUN_TOKEN, 'no_run'],
  ['D2 lane docs', (db) => ({ run_id: run(db, { lane: 'docs' }) }), RUN_TOKEN, 'wrong_lane'],
  ['D3 status queued', (db) => ({ run_id: run(db, { status: 'queued' }) }), RUN_TOKEN, 'not_claimed'],
  ['D4 status done', (db) => ({ run_id: run(db, { status: 'done' }) }), RUN_TOKEN, 'not_claimed'],
  ['D5 claimed by another machine', (db) => ({ run_id: run(db, { claimed_by: 'm2' }) }), RUN_TOKEN, 'not_claimer'],
  ['D6 run token missing', (db) => ({ run_id: run(db) }), null, 'bad_token'],
  ['D7 token of an older claim', (db) => {
    const id = run(db);
    db.prepare('UPDATE web_vault_run_token SET token_hash=? WHERE run_id=?').run(sha('fixture-run-token-newer'), id);
    return { run_id: id };
  }, RUN_TOKEN, 'bad_token'],
  ['D8 lease_until equal to now', (db) => ({ run_id: run(db, { lease_until: NOW }) }), RUN_TOKEN, 'lease_expired'],
  ['D9 lease past', (db) => ({ run_id: run(db, { lease_until: iso(NOW_MS - 60e3) }) }), RUN_TOKEN, 'lease_expired'],
  ['D10 project B run for project A session', (db) => { allow(db, 'p2'); return { run_id: run(db, { project: 'p2' }) }; }, RUN_TOKEN, 'wrong_project'],
  ['D11 site not on the list', (db) => ({ run_id: run(db), site: 'APP.example.com.evil.test' }), RUN_TOKEN, 'site_not_allowed'],
  ['D12 site on another project list only', (db) => { allow(db, 'p2', 'p2only.example.com'); return { run_id: run(db), site: 'p2only.example.com' }; }, RUN_TOKEN, 'site_not_allowed'],
];

for (const [name, setup, token, why] of REFUSALS) {
  test(`${name}: save and load are refused ${why}, one audit row each, no value`, async (t) => {
    const s = await store(t); if (!s) return;
    allow(s.db);
    // Project A's session exists, saved by a good run, so a refused load has a value to leak.
    const good = run(s.db);
    assert.equal((await save(s.env, { run_id: good, value: state('victim') })).status, 200);
    // lane_runs_live allows one live run per (lane, project): the seeding run ends.
    s.db.prepare("UPDATE lane_runs SET status='done' WHERE id=?").run(good);
    const before = n(s.db, 'web_vault_audit');
    const rowBefore = JSON.stringify(vaultRows(s.db));
    const b = setup(s.db);
    const w = await save(s.env, { ...b, value: state('attacker') }, token);
    assert.equal(w.status, 403, `save ${w.text}`);
    assert.equal(w.body.why, why);
    assert.equal(JSON.stringify(vaultRows(s.db)), rowBefore, 'a refused save changes no row');
    const r = await load(s.env, b, token);
    assert.equal(r.status, 403, `load ${r.text}`);
    assert.equal(r.body.why, why);
    assert.equal('value' in r.body, false);
    assert.equal(r.text.includes('fixture-session'), false, 'a refused load holds no session byte');
    const a = audits(s.db).slice(before).map((x) => [x.action, x.outcome, x.field]);
    assert.deepEqual(a, [['set', `refused:${why}`, 'session_state'], ['read', `refused:${why}`, 'session_state']]);
  });
}

// ── OK1-OK3: the pass cases ─────────────────────────────────────────────────
test('OK1 a lease 1 s ahead passes; OK2 a site given as App.Example.com is normalised; OK3 a re-claim works with the new token only', async (t) => {
  const s = await store(t); if (!s) return;
  allow(s.db);
  const id = run(s.db, { lease_until: iso(NOW_MS + 1000) });
  assert.equal((await save(s.env, { run_id: id, value: state('ok1') })).status, 200);
  const r = await load(s.env, { run_id: id, site: 'App.Example.com' });
  assert.equal(r.status, 200, r.text);
  assert.equal(r.body.value, state('ok1'));
  s.db.prepare('UPDATE web_vault_run_token SET token_hash=? WHERE run_id=?').run(sha('fixture-run-token-reclaim'), id);
  assert.equal((await load(s.env, { run_id: id }, 'fixture-run-token-reclaim')).status, 200);
  assert.equal((await load(s.env, { run_id: id })).body.why, 'bad_token');
});

// ── LD1-LD6 ─────────────────────────────────────────────────────────────────
test('LD1 no saved session: 404 no_entry, one audit row', async (t) => {
  const s = await store(t); if (!s) return;
  allow(s.db);
  const id = run(s.db);
  const r = await load(s.env, { run_id: id });
  assert.equal(r.status, 404, r.text);
  assert.equal(r.body.why, 'no_entry');
  assert.deepEqual(audits(s.db).map((a) => a.outcome), ['refused:no_entry']);
});

test('LD2 an ok load writes one audit row read ok and sets last_used_at', async (t) => {
  const s = await store(t); if (!s) return;
  allow(s.db);
  const id = run(s.db);
  await save(s.env, { run_id: id, value: state('ld2') });
  s.db.prepare("UPDATE web_vault SET last_used_at='2026-10-20T00:00:00Z'").run();
  const before = n(s.db, 'web_vault_audit');
  assert.equal((await load(s.env, { run_id: id })).status, 200);
  const a = audits(s.db).slice(before);
  assert.equal(a.length, 1);
  assert.deepEqual([a[0].action, a[0].outcome, a[0].key_id], ['read', 'ok', 1]);
  assert.equal(vaultRows(s.db)[0].last_used_at, NOW);
});

test('LD3 age edges: 14 d less 1 s is used; exactly 14 d and 15 d are expired; the row stays', async (t) => {
  const s = await store(t); if (!s) return;
  allow(s.db);
  const id = run(s.db);
  await save(s.env, { run_id: id, value: state('ld3') });
  age(s.db, 14 * DAY - 1000);
  const ok = await load(s.env, { run_id: id });
  assert.equal(ok.status, 200, ok.text);
  assert.equal(ok.body.saved_at, iso(NOW_MS - 14 * DAY + 1000));
  for (const ms of [14 * DAY, 15 * DAY]) {
    age(s.db, ms);
    const r = await load(s.env, { run_id: id });
    assert.equal(r.status, 404, `${ms}: ${r.text}`);
    assert.equal(r.body.why, 'expired');
    assert.equal('value' in r.body, false);
  }
  assert.equal(n(s.db, 'web_vault'), 1, 'an expired session is not deleted');
  assert.deepEqual(audits(s.db).slice(-2).map((a) => a.outcome), ['refused:expired', 'refused:expired']);
});

test('LD4 the age limit is DB-driven: setting 3 makes a 4-day-old session expired', async (t) => {
  const s = await store(t); if (!s) return;
  allow(s.db);
  const id = run(s.db);
  await save(s.env, { run_id: id, value: state('ld4') });
  age(s.db, 4 * DAY);
  assert.equal((await load(s.env, { run_id: id })).status, 200, 'under the default 14 it is used');
  setting(s.db, 'lane.web-task.session_max_days', '3');
  assert.equal((await load(s.env, { run_id: id })).body.why, 'expired');
});

test('LD5 a bad setting (abc, 0, 366, absent) falls back to 14', async (t) => {
  const s = await store(t); if (!s) return;
  allow(s.db);
  const id = run(s.db);
  await save(s.env, { run_id: id, value: state('ld5') });
  for (const v of ['abc', '0', '366', null]) {
    if (v === null) s.db.prepare("DELETE FROM settings WHERE key='lane.web-task.session_max_days'").run();
    else setting(s.db, 'lane.web-task.session_max_days', v);
    age(s.db, 13 * DAY);
    assert.equal((await load(s.env, { run_id: id })).status, 200, `${v}: 13 d is used`);
    age(s.db, 14 * DAY);
    assert.equal((await load(s.env, { run_id: id })).body.why, 'expired', `${v}: 14 d is expired`);
  }
});

test('LD6 key missing: save and load answer 503 with one audit row each and no value', async (t) => {
  const s = await store(t); if (!s) return;
  allow(s.db);
  const id = run(s.db);
  await save(s.env, { run_id: id, value: state('ld6') });
  const env = { ...s.env, WEB_VAULT_KEY_1: undefined };
  const before = n(s.db, 'web_vault_audit');
  const rowBefore = JSON.stringify(vaultRows(s.db));
  const w = await save(env, { run_id: id, value: state('ld6b') });
  assert.equal(w.status, 503, w.text);
  assert.equal(JSON.stringify(vaultRows(s.db)), rowBefore);
  const r = await load(env, { run_id: id });
  assert.equal(r.status, 503, r.text);
  assert.equal(r.body.why, 'key_missing');
  assert.equal(r.text.includes('fixture-session'), false);
  assert.deepEqual(audits(s.db).slice(before).map((a) => [a.action, a.outcome]), [['set', 'refused:key_missing'], ['read', 'refused:key_missing']]);
});

// ── VR1 ─────────────────────────────────────────────────────────────────────
test('VR1 /api/web-vault/read refuses field session_state (use_session_load); password still reads', async (t) => {
  const s = await store(t); if (!s) return;
  allow(s.db);
  const id = run(s.db);
  await save(s.env, { run_id: id, value: state('vr1') });
  age(s.db, 30 * DAY);
  const pw = await call(s.env, 'POST', '/api/web-vault/set', { project: 'p1', site: SITE, field: 'password', value: 'fixture-pass-vr1' }, { runToken: null, admin: ADMIN });
  assert.equal(pw.status, 200, pw.text);
  const before = n(s.db, 'web_vault_audit');
  const vr = (field) => call(s.env, 'POST', '/api/web-vault/read', { project: 'p1', site: SITE, field, machine: 'm1', run_id: id });
  const r = await vr('session_state');
  assert.equal(r.status, 403, r.text);
  assert.equal(r.body.why, 'use_session_load');
  assert.equal(r.text.includes('fixture-session'), false);
  const a = audits(s.db).slice(before);
  assert.deepEqual(a.map((x) => [x.action, x.outcome, x.field, x.actor, x.run_id]), [['read', 'refused:use_session_load', 'session_state', 'm1', id]]);
  const p = await vr('password');
  assert.equal(p.status, 200, p.text);
  assert.equal(p.body.value, 'fixture-pass-vr1');
});

test('VR2 /api/web-vault/read session_state with a wrong token is bad_token, not use_session_load; a good token is use_session_load', async (t) => {
  const s = await store(t); if (!s) return;
  allow(s.db);
  const id = run(s.db);
  const vr = (token) => call(s.env, 'POST', '/api/web-vault/read', { project: 'p1', site: SITE, field: 'session_state', machine: 'm1', run_id: id }, { runToken: token });
  const bad = await vr('fixture-run-token-wrong');
  assert.equal(bad.status, 403, bad.text);
  assert.equal(bad.body.why, 'bad_token');
  const good = await vr(RUN_TOKEN);
  assert.equal(good.status, 403, good.text);
  assert.equal(good.body.why, 'use_session_load', 'no saved row: still use_session_load, not no_entry');
  assert.deepEqual(audits(s.db).map((a) => a.outcome), ['refused:bad_token', 'refused:use_session_load']);
});

// ── P1 ──────────────────────────────────────────────────────────────────────
test('P1 no stored cell and no console line holds a session value or the run token', async (t) => {
  const s = await store(t); if (!s) return;
  const lines = [];
  for (const k of ['log', 'info', 'warn', 'error', 'debug']) t.mock.method(console, k, (...a) => { lines.push(a.map(String).join(' ')); });
  allow(s.db);
  const id = run(s.db);
  assert.equal((await save(s.env, { run_id: id, value: state('p1') })).status, 200);
  assert.equal((await load(s.env, { run_id: id })).body.value, state('p1'));
  assert.equal(n(s.db, 'web_vault'), 1, 'the session row exists, so the scan below has a cell to check');
  await save(s.env, { run_id: id, value: state('p1-refused') }, 'fixture-run-token-wrong');
  await save(s.env, { run_id: id, value: 'fixture-session-p1-nul\u0000' });
  age(s.db, 20 * DAY);
  await load(s.env, { run_id: id });
  await call(s.env, 'POST', '/api/web-vault/read', { project: 'p1', site: SITE, field: 'session_state', machine: 'm1', run_id: id });
  for (const table of ['web_vault', 'web_vault_audit', 'settings', 'web_vault_run_token', 'lane_runs']) {
    for (const row of s.db.prepare(`SELECT * FROM ${table}`).all()) for (const [k, v] of Object.entries(row)) {
      assert.equal(String(v).includes('fixture-session'), false, `${table}.${k}`);
      assert.equal(String(v).includes(RUN_TOKEN), false, `${table}.${k} holds the run token`);
    }
  }
  for (const l of lines) {
    assert.equal(l.includes('fixture-session'), false, `console: ${l.slice(0, 200)}`);
    assert.equal(l.includes(RUN_TOKEN), false, 'console holds the run token');
  }
});

// ── E1 ──────────────────────────────────────────────────────────────────────
test('E1 at 20,000 web_vault rows the save and load reads use uq_web_vault_entry or a primary key, no full SCAN', async (t) => {
  const s = await store(t); if (!s) return;
  s.db.exec('BEGIN');
  const v = s.db.prepare(`INSERT INTO web_vault (project, site, field, ciphertext, iv, key_id, created_at, updated_at, last_used_at)
                          VALUES (?, ?, ?, 'Y3Q=', 'aXY=', 1, ?, ?, ?)`);
  for (let i = 0; i < 20000; i++) {
    const at = iso(NOW_MS - (i % 400) * DAY);
    v.run(`p${i % 40}`, `s${Math.floor(i / 40) % 50}.example.com`, i < 2000 && i % 5 === 0 ? 'session_state' : `f${i}`, at, at, at);
  }
  s.db.exec('COMMIT');
  s.db.exec('ANALYZE');
  const log = [];
  const env = { ...s.env, DB: capturingD1(s.db, log) };
  allow(s.db);
  const id = run(s.db);
  assert.equal((await save(env, { run_id: id, value: state('e1') })).status, 200);
  assert.equal((await load(env, { run_id: id })).status, 200);
  const hot = log.filter((x) => /\b(web_vault|web_vault_run_token|lane_runs)\b/.test(x.sql) && !/^\s*INSERT INTO web_vault_audit/.test(x.sql));
  assert.ok(hot.some((x) => /FROM web_vault WHERE project=\?1 AND site=\?2 AND field='session_state'/.test(x.sql)), 'the load reads the session row');
  // capturingD1 logs reads; the two writes of the routes are planned with real binds.
  const sessionId = s.db.prepare("SELECT id FROM web_vault WHERE project='p1' AND site=? AND field='session_state'").get(SITE).id;
  hot.push({ sql: UPSERT_SQL, binds: ['p1', SITE, 'session_state', 'Y3Q=', 'aXY=', 1, NOW] });
  hot.push({ sql: TOUCH_SQL, binds: [sessionId, NOW] });
  for (const { sql, binds } of hot) {
    const lines = plan(s.db, sql, ...binds.map((b) => (b === undefined ? null : b)));
    assert.deepEqual(fullScans(lines, ['web_vault', 'web_vault_run_token', 'lane_runs']), [], `${sql}\n${lines.join('\n')}`);
    // An INSERT ... ON CONFLICT has no plan line; its target must be uq_web_vault_entry's columns or SQLite refuses it.
    if (/^\s*(SELECT|UPDATE)/.test(sql)) {
      assert.ok(lines.some((l) => /USING (COVERING )?INDEX uq_web_vault_entry|USING INTEGER PRIMARY KEY|USING PRIMARY KEY/.test(l)), `${sql}\n${lines.join('\n')}`);
    }
  }
});
