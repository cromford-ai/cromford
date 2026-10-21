// BH-7595 (slice C0): the web_vault credential store.
//
// Driven through the REAL worker.fetch over a node:sqlite D1 with the composed
// jobs schema. The clock is pinned (D60). Every value is a `fixture-pass-*`
// string and the AES key is built from a `fixture-key-*` string (D47).
//
// K1      the 4 indexes and 3 seed rows exist
// C1-C4   crypto: round trip; another AAD fails; key missing; rotation
// RT1     set then read returns the same value; size and NUL bounds
// RT2     the audit route returns the set and read rows, newest first, no value
// P1      no column of web_vault, web_vault_audit, settings, retention_runs holds a value
// A1-A6   the operator check on set, entries and audit
// D1-D26  the read decision table; each case writes exactly one audit row
//         (D22-D26: right run_id and machine, no or wrong run token)
// T1-T5   the run token: a forged web-task enqueue is 403; a real claim mints
//         a token and stores only its hash; a caller with run_id and machine
//         from GET /api/lane-runs but no token is refused; a re-claim voids
//         the old token; another lane's claim has no token
// K2      the run-token table, its index and seed; retention rule
// S1-S3   stale report; bad setting falls back to 180; no route deletes a vault row
// R1-R3   audit retention: dry run; archive unbound; archive bound
// E1      EXPLAIN QUERY PLAN of the routes' real reads at 2,000 / 20,000 / 5,000 rows
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { openDb, d1 } from './lib/d1-sqlite.bh-1030.js';
import { plan, fullScans, capturingD1 } from './lib/d1-volume.bh-6727.js';
import { RULES } from '../src/routes/retention.js';
import { createHash } from 'node:crypto';

// Loaded by dynamic import, so each case fails on its own while the module is absent.
const CRYPTO = await import('../src/lib/web-vault-crypto.js').catch(() => null);

const SECRET = 'fixture-harness-secret';
const ADMIN = 'fixture-admin-token-7595';
const KEY1 = Buffer.from('fixture-key-web-vault-bh7595-001').toString('base64');
const KEY2 = Buffer.from('fixture-key-web-vault-bh7595-002').toString('base64');
const NOW_MS = Date.parse('2026-10-19T12:00:00Z');
const DAY = 86400e3;
const iso = (ms) => new Date(ms).toISOString().replace(/\.\d{3}Z$/, 'Z');
const ago = (days) => iso(NOW_MS - days * DAY);
const NOW = iso(NOW_MS);
const SITE = 'app.example.com';
const RUN_TOKEN = 'fixture-run-token-7595';
const sha = (x) => createHash('sha256').update(x).digest('hex');

async function store(t, extra = {}) {
  t.mock.timers.enable({ apis: ['Date'], now: NOW_MS });
  const o = await openDb();
  if (!o) { t.skip('node:sqlite unavailable'); return null; }
  const env = { DB: o.DB, HARNESS_SECRET: SECRET, WEB_VAULT_ADMIN_TOKEN: ADMIN, WEB_VAULT_KEY_1: KEY1, ...extra };
  return { db: o.db, env };
}

async function call(env, method, path, body, { admin = ADMIN, bearer = SECRET, runToken = null } = {}) {
  const headers = { 'content-type': 'application/json' };
  if (bearer !== null) headers.authorization = `Bearer ${bearer}`;
  if (admin !== null) headers['x-web-vault-admin-token'] = admin;
  if (runToken !== null) headers['x-web-vault-run-token'] = runToken;
  const res = await worker.fetch(new Request(`https://jobs.test${path}`, {
    method, headers, body: body === undefined ? undefined : JSON.stringify(body),
  }), env);
  const text = await res.text();
  let parsed = null;
  try { parsed = JSON.parse(text); } catch { parsed = { raw: text }; }
  return { status: res.status, body: parsed };
}
const set = (env, project, site, field, value, opts) => call(env, 'POST', '/api/web-vault/set', { project, site, field, value }, opts);
const read = (env, b, token = RUN_TOKEN) => call(env, 'POST', '/api/web-vault/read', { project: 'p1', site: SITE, field: 'password', machine: 'm1', ...b }, { admin: null, runToken: token });

function setting(db, key, value) {
  db.prepare(`INSERT INTO settings (key,value,note,actor,updated_at) VALUES (?,?,'',?,?)
              ON CONFLICT(key) DO UPDATE SET value=excluded.value`).run(key, String(value), 'test', NOW);
}
function delSetting(db, key) { db.prepare('DELETE FROM settings WHERE key = ?').run(key); }
// A lane_runs row, plus the run-token row a claim of it minted (token null: none).
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

// ── K1 ──────────────────────────────────────────────────────────────────────
test('K1 the schema has the 4 indexes and the 3 seed rows', async (t) => {
  const s = await store(t); if (!s) return;
  const idx = s.db.prepare("SELECT name, tbl_name, sql FROM sqlite_master WHERE type='index' AND tbl_name IN ('web_vault','web_vault_audit')").all();
  const byName = Object.fromEntries(idx.map((r) => [r.name, r]));
  for (const name of ['uq_web_vault_entry', 'idx_web_vault_last_used', 'idx_web_vault_audit_at', 'idx_web_vault_audit_entry']) {
    assert.ok(byName[name], `index ${name}`);
  }
  assert.match(byName.uq_web_vault_entry.sql, /UNIQUE INDEX[^(]*\(project, site, field\)/);
  assert.match(byName.idx_web_vault_audit_entry.sql, /\(project, site, at\)/);
  const seeds = Object.fromEntries(s.db.prepare("SELECT key, value FROM settings WHERE key IN ('web_vault.key_id','web_vault.retain_days','retention.web_vault_audit.days')").all().map((r) => [r.key, r.value]));
  assert.equal(seeds['web_vault.key_id'], '1');
  assert.equal(seeds['web_vault.retain_days'], '180');
  assert.equal(seeds['retention.web_vault_audit.days'], '90');
  const cols = s.db.prepare('PRAGMA table_info(web_vault)').all().map((c) => c.name);
  for (const c of ['project', 'site', 'field', 'ciphertext', 'iv', 'key_id', 'created_at', 'updated_at', 'last_used_at']) assert.ok(cols.includes(c), c);
  assert.equal(cols.some((c) => /value|plain/.test(c)), false, 'no plain-value column');
});

// ── C1-C4 ───────────────────────────────────────────────────────────────────
test('C1 crypto: a value round-trips and the ciphertext is not the value', async () => {
  assert.ok(CRYPTO, 'src/lib/web-vault-crypto.js exists');
  const env = { WEB_VAULT_KEY_1: KEY1 };
  const aad = 'web_vault\np1\napp.example.com\npassword';
  const e = await CRYPTO.encryptValue(env, 1, aad, 'fixture-pass-c1');
  assert.equal(e.ok, true, JSON.stringify(e));
  assert.ok(!e.ciphertext.includes('fixture'), 'ciphertext is not plain');
  assert.equal(Buffer.from(e.iv, 'base64').length, 12);
  const d = await CRYPTO.decryptValue(env, 1, aad, e.iv, e.ciphertext);
  assert.equal(d.ok, true);
  assert.equal(d.value, 'fixture-pass-c1');
  const e2 = await CRYPTO.encryptValue(env, 1, aad, 'fixture-pass-c1');
  assert.notEqual(e2.iv, e.iv, 'a fresh iv per write');
});

test('C2 crypto: a ciphertext under another (project, site, field) fails to decrypt', async () => {
  assert.ok(CRYPTO, 'src/lib/web-vault-crypto.js exists');
  const env = { WEB_VAULT_KEY_1: KEY1 };
  const e = await CRYPTO.encryptValue(env, 1, 'web_vault\np1\napp.example.com\npassword', 'fixture-pass-c2');
  for (const other of ['web_vault\np2\napp.example.com\npassword', 'web_vault\np1\nother.org\npassword', 'web_vault\np1\napp.example.com\nusername']) {
    const d = await CRYPTO.decryptValue(env, 1, other, e.iv, e.ciphertext);
    assert.equal(d.ok, false, other);
    assert.equal(d.value, undefined);
  }
});

test('C3 key missing: crypto refuses, set answers 503 with one audit row and no vault row', async (t) => {
  assert.ok(CRYPTO, 'src/lib/web-vault-crypto.js exists');
  for (const env of [{}, { WEB_VAULT_KEY_1: Buffer.from('fixture-short-key').toString('base64') }, { WEB_VAULT_KEY_1: 'not base64 at all !!' }]) {
    const e = await CRYPTO.encryptValue(env, 1, 'a', 'fixture-pass-c3');
    assert.equal(e.ok, false);
    assert.equal(e.why, 'key missing');
  }
  const s = await store(t, { WEB_VAULT_KEY_1: undefined }); if (!s) return;
  const r = await set(s.env, 'p1', SITE, 'password', 'fixture-pass-c3');
  assert.equal(r.status, 503, JSON.stringify(r.body));
  assert.equal(r.body.error, 'vault key missing');
  assert.equal(r.body.key_id, 1);
  assert.equal(n(s.db, 'web_vault'), 0);
  const a = audits(s.db);
  assert.equal(a.length, 1);
  assert.deepEqual({ action: a[0].action, outcome: a[0].outcome, actor: a[0].actor, key_id: a[0].key_id },
    { action: 'set', outcome: 'refused:key_missing', actor: 'operator', key_id: 1 });
});

test('C4 rotation: an old row reads with its own key_id after web_vault.key_id=2; a new set uses key 2', async (t) => {
  const s = await store(t, { WEB_VAULT_KEY_2: KEY2 }); if (!s) return;
  allow(s.db);
  const id = run(s.db);
  assert.equal((await set(s.env, 'p1', SITE, 'password', 'fixture-pass-old')).status, 200);
  setting(s.db, 'web_vault.key_id', '2');
  const r1 = await read(s.env, { run_id: id });
  assert.equal(r1.status, 200, JSON.stringify(r1.body));
  assert.equal(r1.body.value, 'fixture-pass-old');
  const w = await set(s.env, 'p1', SITE, 'username', 'fixture-pass-user');
  assert.equal(w.body.key_id, 2);
  assert.equal(vaultRows(s.db).find((r) => r.field === 'username').key_id, 2);
  assert.equal(vaultRows(s.db).find((r) => r.field === 'password').key_id, 1);
  const r2 = await read(s.env, { run_id: id, field: 'username' });
  assert.equal(r2.body.value, 'fixture-pass-user');
  // Key 1 removed: the old row is key_missing, the new row still reads.
  const env3 = { ...s.env, WEB_VAULT_KEY_1: undefined };
  assert.equal((await read(env3, { run_id: id })).body.why, 'key_missing');
  assert.equal((await read(env3, { run_id: id, field: 'username' })).body.value, 'fixture-pass-user');
});

// ── RT1, RT2 ────────────────────────────────────────────────────────────────
test('RT1 set then read returns the same bytes (ascii, unicode, 4096 bytes); bad values are 400 with nothing written', async (t) => {
  const s = await store(t); if (!s) return;
  allow(s.db);
  const id = run(s.db);
  const big = 'fixture-pass-' + 'x'.repeat(4096 - 13);
  assert.equal(Buffer.byteLength(big), 4096);
  for (const [field, value] of [['password', 'fixture-pass-ascii'], ['username', 'fixture-pass-ünï-密码-🔑'], ['token', big]]) {
    const w = await set(s.env, 'p1', SITE, field, value);
    assert.equal(w.status, 200, JSON.stringify(w.body));
    assert.equal(w.body.stored, true);
    assert.equal(JSON.stringify(w.body).includes('fixture-pass'), false, 'the set answer never echoes the value');
    const r = await read(s.env, { run_id: id, field });
    assert.equal(r.status, 200, JSON.stringify(r.body));
    assert.equal(r.body.value, value, field);
  }
  // An overwrite keeps one row and reads the new value.
  await set(s.env, 'p1', SITE, 'password', 'fixture-pass-ascii-2');
  assert.equal(vaultRows(s.db).filter((r) => r.field === 'password').length, 1);
  assert.equal((await read(s.env, { run_id: id })).body.value, 'fixture-pass-ascii-2');
  const before = { v: n(s.db, 'web_vault'), a: n(s.db, 'web_vault_audit') };
  const bad = [
    ['p1', SITE, 'password', big + 'y'],                  // 4097 bytes
    ['p1', SITE, 'password', ''],
    ['p1', SITE, 'password', 'fixture-pass-\u0000-nul'],
    ['p1', SITE, 'password', 42],
    ['p 1', SITE, 'password', 'fixture-pass-x'],
    ['p1', 'https://app.example.com', 'password', 'fixture-pass-x'],
    ['p1', 'app.example.com:443', 'password', 'fixture-pass-x'],
    ['p1', 'app.example.com/login', 'password', 'fixture-pass-x'],
    ['p1', SITE, 'Pass Word', 'fixture-pass-x'],
  ];
  for (const b of bad) {
    const r = await set(s.env, ...b);
    assert.equal(r.status, 400, JSON.stringify(b));
  }
  assert.deepEqual({ v: n(s.db, 'web_vault'), a: n(s.db, 'web_vault_audit') }, before, 'a 400 writes nothing');
  // The site is lower-cased once, at write and at read (D17).
  assert.equal((await set(s.env, 'p1', 'APP.Example.COM', 'otp', 'fixture-pass-otp')).body.site, SITE);
  assert.equal((await read(s.env, { run_id: id, site: 'App.Example.Com', field: 'otp' })).body.value, 'fixture-pass-otp');
});

test('RT2 the audit route returns the rows set and read wrote, newest first, with no value field', async (t) => {
  const s = await store(t); if (!s) return;
  allow(s.db);
  const id = run(s.db);
  await set(s.env, 'p1', SITE, 'password', 'fixture-pass-rt2');
  t.mock.timers.tick(1000);
  await read(s.env, { run_id: id });
  t.mock.timers.tick(1000);
  await read(s.env, { run_id: id, machine: 'm2' });
  const r = await call(s.env, 'GET', '/api/web-vault/audit?project=p1');
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.deepEqual(r.body.rows.map((x) => [x.action, x.outcome, x.actor]), [
    ['read', 'refused:not_claimer', 'm2'], ['read', 'ok', 'm1'], ['set', 'ok', 'operator'],
  ]);
  assert.equal(r.body.rows[1].run_id, id);
  assert.equal(JSON.stringify(r.body).includes('fixture-pass'), false);
  for (const row of r.body.rows) assert.equal('value' in row, false);
  const bySite = await call(s.env, 'GET', '/api/web-vault/audit?project=p1&site=other.org');
  assert.deepEqual(bySite.body.rows, []);
  assert.equal((await call(s.env, 'GET', '/api/web-vault/audit')).status, 400, 'project is required');
});

// ── P1 ──────────────────────────────────────────────────────────────────────
test('P1 after 3 sets and 3 reads no stored cell holds a fixture-pass value', async (t) => {
  const s = await store(t); if (!s) return;
  allow(s.db);
  const id = run(s.db);
  for (const f of ['password', 'username', 'otp']) await set(s.env, 'p1', SITE, f, `fixture-pass-p1-${f}`);
  for (const f of ['password', 'username', 'otp']) assert.equal((await read(s.env, { run_id: id, field: f })).body.value, `fixture-pass-p1-${f}`);
  await call(s.env, 'POST', '/api/retention/run', {});
  for (const table of ['web_vault', 'web_vault_audit', 'settings', 'retention_runs']) {
    const rows = s.db.prepare(`SELECT * FROM ${table}`).all();
    assert.ok(table !== 'web_vault' || rows.length === 3);
    for (const row of rows) for (const [k, v] of Object.entries(row)) {
      assert.equal(String(v).includes('fixture-pass'), false, `${table}.${k}`);
      assert.equal(String(v).includes(ADMIN), false, `${table}.${k} holds the admin token`);
    }
  }
});

// ── A1-A6 ───────────────────────────────────────────────────────────────────
test('A1-A6 the operator check: only the exact admin token writes or lists; unset on the worker refuses all', async (t) => {
  const s = await store(t); if (!s) return;
  const cases = [
    ['A1 bearer only', s.env, null],
    ['A2 wrong by one char', s.env, ADMIN.slice(0, -1) + 'x'],
    ['A3 one extra char', s.env, ADMIN + 'x'],
    ['A3b a prefix', s.env, ADMIN.slice(0, -1)],
    ['A4 worker secret unset, empty header', { ...s.env, WEB_VAULT_ADMIN_TOKEN: undefined }, ''],
    ['A5 worker secret unset, a header', { ...s.env, WEB_VAULT_ADMIN_TOKEN: undefined }, ADMIN],
    ['A5b worker secret blank, empty header', { ...s.env, WEB_VAULT_ADMIN_TOKEN: '  ' }, ''],
  ];
  for (const [name, env, admin] of cases) {
    const w = await set(env, 'p1', SITE, 'password', 'fixture-pass-a', { admin });
    assert.equal(w.status, 403, name);
    assert.equal(JSON.stringify(w.body).includes('fixture-pass'), false);
    assert.equal((await call(env, 'GET', '/api/web-vault/entries?project=p1', undefined, { admin })).status, 403, `${name} entries`);
    assert.equal((await call(env, 'GET', '/api/web-vault/audit?project=p1', undefined, { admin })).status, 403, `${name} audit`);
  }
  assert.equal(n(s.db, 'web_vault'), 0);
  assert.equal(n(s.db, 'web_vault_audit'), 0);
  // No bearer at all is the index's 401, before any vault code runs.
  assert.equal((await set(s.env, 'p1', SITE, 'password', 'fixture-pass-a', { bearer: null })).status, 401);
  // A6: the exact token writes; a worker secret with a trailing newline is trimmed.
  assert.equal((await set(s.env, 'p1', SITE, 'password', 'fixture-pass-a')).status, 200);
  assert.equal((await set({ ...s.env, WEB_VAULT_ADMIN_TOKEN: ADMIN + '\n' }, 'p1', SITE, 'username', 'fixture-pass-b')).status, 200);
  assert.equal(n(s.db, 'web_vault'), 2);
});

// ── D1-D26 ──────────────────────────────────────────────────────────────────
// Each case: [name, setup(db) -> body overrides, status, why ('ok' = 200)].
const D = [
  ['D1 allow: claimed web-task run of p1 by m1, site on the list', (db) => ({ run_id: run(db) }), 200, 'ok'],
  ['D2 allow: list " APP.Example.com " (trim and case)', (db) => { allow(db, 'p1', ' APP.Example.com '); return { run_id: run(db) }; }, 200, 'ok'],
  ['D3 no run row', () => ({ run_id: 999999 }), 403, 'no_run'],
  ['D4 another lane', (db) => ({ run_id: run(db, { lane: 'merge-conductor-pr' }) }), 403, 'wrong_lane'],
  ['D5 status queued', (db) => ({ run_id: run(db, { status: 'queued' }) }), 403, 'not_claimed'],
  ['D6 status done', (db) => ({ run_id: run(db, { status: 'done' }) }), 403, 'not_claimed'],
  ['D7 claimed by m2', (db) => ({ run_id: run(db, { claimed_by: 'm2' }) }), 403, 'not_claimer'],
  ['D8 lease_until = t', (db) => ({ run_id: run(db, { lease_until: NOW }) }), 403, 'lease_expired'],
  ['D9 lease_until = t - 1s', (db) => ({ run_id: run(db, { lease_until: iso(NOW_MS - 1000) }) }), 403, 'lease_expired'],
  ['D10 another project\'s claimed run', (db) => ({ run_id: run(db, { project: 'p2' }) }), 403, 'wrong_project'],
  ['D11 prefix near miss p1x', (db) => ({ run_id: run(db, { project: 'p1x' }) }), 403, 'wrong_project'],
  ['D12 parent domain example.com', (db) => ({ run_id: run(db), site: 'example.com' }), 403, 'site_not_allowed'],
  ['D13 lookalike evil-app.example.com', (db) => ({ run_id: run(db), site: 'evil-app.example.com' }), 403, 'site_not_allowed'],
  ['D14 suffix app.example.com.evil.net', (db) => ({ run_id: run(db), site: 'app.example.com.evil.net' }), 403, 'site_not_allowed'],
  ['D15 allow-list row absent', (db) => { delSetting(db, 'lane.web-task.p1.allowed_domains'); return { run_id: run(db) }; }, 403, 'site_not_allowed'],
  ['D16 allow-list row empty', (db) => { allow(db, 'p1', ''); return { run_id: run(db) }; }, 403, 'site_not_allowed'],
  ['D17 allow-list row of p2 only', (db) => { delSetting(db, 'lane.web-task.p1.allowed_domains'); allow(db, 'p2'); return { run_id: run(db) }; }, 403, 'site_not_allowed'],
  ['D18 field absent', (db) => ({ run_id: run(db), field: 'otp' }), 404, 'no_entry'],
  ['D19 key missing at read', (db) => ({ run_id: run(db), __env: { WEB_VAULT_KEY_1: undefined } }), 503, 'key_missing'],
  ['D20 ciphertext tampered', (db) => { db.prepare("UPDATE web_vault SET ciphertext = 'AAAA' || substr(ciphertext, 5)").run(); return { run_id: run(db) }; }, 503, 'decrypt_failed'],
  ['D22 right run_id and machine, no run token header', (db) => ({ run_id: run(db), __token: null }), 403, 'bad_token'],
  ['D23 right run_id and machine, wrong run token', (db) => ({ run_id: run(db), __token: 'fixture-run-token-guess' }), 403, 'bad_token'],
  ['D24 the run has no token row', (db) => ({ run_id: run(db, { token: null }) }), 403, 'bad_token'],
  ['D25 the token of another run', (db) => { run(db, { project: 'p2', token: 'fixture-run-token-other' }); return { run_id: run(db, { token: 'fixture-run-token-mine' }), __token: 'fixture-run-token-other' }; }, 403, 'bad_token'],
  ['D26 the token row is of another machine', (db) => ({ run_id: run(db, { token_machine: 'm2' }) }), 403, 'bad_token'],
];
for (const [name, setup, status, why] of D) {
  test(name, async (t) => {
    const s = await store(t); if (!s) return;
    allow(s.db);
    assert.equal((await set(s.env, 'p1', SITE, 'password', 'fixture-pass-d')).status, 200);
    const vaultBefore = vaultRows(s.db)[0];
    const auditBefore = n(s.db, 'web_vault_audit');
    const { __env, __token, ...b } = setup(s.db);
    const r = await read({ ...s.env, ...(__env || {}) }, b, __token === undefined ? RUN_TOKEN : __token);
    assert.equal(r.status, status, JSON.stringify(r.body));
    const a = audits(s.db).slice(auditBefore);
    assert.equal(a.length, 1, 'exactly one audit row');
    assert.equal(a[0].action, 'read');
    assert.equal(a[0].actor, 'm1');
    assert.equal(a[0].run_id, b.run_id);
    if (why === 'ok') {
      assert.equal(r.body.value, 'fixture-pass-d');
      assert.equal(a[0].outcome, 'ok');
      assert.equal(vaultRows(s.db)[0].last_used_at, NOW, 'last_used_at moved');
    } else {
      assert.equal(r.body.why, why);
      assert.equal('value' in r.body, false, 'a refusal returns no value');
      assert.equal(JSON.stringify(r.body).includes('fixture-pass'), false);
      assert.equal(a[0].outcome, `refused:${why}`);
      const after = vaultRows(s.db)[0];
      assert.equal(after.last_used_at, vaultBefore.last_used_at, 'vault unchanged');
    }
  });
}

test('D21 a malformed read body is 400 and writes no audit row', async (t) => {
  const s = await store(t); if (!s) return;
  allow(s.db);
  const id = run(s.db);
  for (const b of [{ run_id: 'x' }, { run_id: id, machine: '' }, { run_id: id, site: 'a/b' }, { run_id: id, field: '' }, { run_id: id, project: '' }]) {
    assert.equal((await read(s.env, b)).status, 400, JSON.stringify(b));
  }
  assert.equal(n(s.db, 'web_vault_audit'), 0);
});

// ── T1-T5 ───────────────────────────────────────────────────────────────────
const enqueue = (env, lane, project, opts) => call(env, 'POST', '/api/lane-runs', { lane, project, args: ['bin/x.sh'] }, opts);
const claim = (env, machine) => call(env, 'POST', '/api/lane-runs/claim', { machine, lanes: ['web-task', 'demo'] }, { admin: null });

test('T1 a web-task enqueue without the operator token is 403 and writes no row (single and batch)', async (t) => {
  const s = await store(t); if (!s) return;
  for (const admin of [null, 'fixture-admin-token-wrong']) {
    const r = await enqueue(s.env, 'web-task', 'p1', { admin });
    assert.equal(r.status, 403, JSON.stringify(r.body));
    const b = await call(s.env, 'POST', '/api/lane-runs/batch', { lane: 'web-task', rows: [{ project: 'p1', args: ['bin/x.sh'] }] }, { admin });
    assert.equal(b.status, 403, JSON.stringify(b.body));
  }
  assert.equal(n(s.db, 'lane_runs'), 0);
  // Another lane needs only the bearer, as before.
  assert.equal((await enqueue(s.env, 'demo', 'p1', { admin: null })).status, 201);
  assert.equal((await enqueue({ ...s.env, WEB_VAULT_ADMIN_TOKEN: undefined }, 'web-task', 'p2')).status, 403, 'unset on the worker is denied');
  assert.equal((await enqueue(s.env, 'web-task', 'p1')).status, 201);
  assert.equal((await call(s.env, 'POST', '/api/lane-runs/batch', { lane: 'web-task', rows: [{ project: 'p3', args: ['bin/x.sh'] }] })).status, 200);
});

test('T2 a real web-task claim mints a run token; D1 keeps only its hash; the token reads', async (t) => {
  const s = await store(t); if (!s) return;
  allow(s.db);
  await set(s.env, 'p1', SITE, 'password', 'fixture-pass-t2');
  assert.equal((await enqueue(s.env, 'web-task', 'p1')).status, 201);
  const c = await claim(s.env, 'm1');
  assert.equal(c.status, 200, JSON.stringify(c.body));
  assert.equal(c.body.lane, 'web-task');
  assert.match(c.body.vault_token, /^[A-Za-z0-9_-]{43}$/);
  const rows = s.db.prepare('SELECT * FROM web_vault_run_token').all();
  assert.equal(rows.length, 1);
  assert.deepEqual({ run_id: rows[0].run_id, machine: rows[0].machine, token_hash: rows[0].token_hash },
    { run_id: c.body.id, machine: 'm1', token_hash: sha(c.body.vault_token) });
  assert.equal(JSON.stringify(rows).includes(c.body.vault_token), false, 'no plain token in D1');
  const r = await read(s.env, { run_id: c.body.id }, c.body.vault_token);
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.value, 'fixture-pass-t2');
});

test('T3 a bearer holder with run_id and machine from GET /api/lane-runs, and no token, is refused', async (t) => {
  const s = await store(t); if (!s) return;
  allow(s.db);
  await set(s.env, 'p1', SITE, 'password', 'fixture-pass-t3');
  await enqueue(s.env, 'web-task', 'p1');
  const c = await claim(s.env, 'fly-legit-machine');
  assert.equal(c.status, 200);
  const list = await call(s.env, 'GET', '/api/lane-runs?lane=web-task&status=claimed', undefined, { admin: null });
  assert.equal(list.status, 200, JSON.stringify(list.body));
  const live = JSON.stringify(list.body);
  assert.equal(live.includes(c.body.vault_token), false, 'the list never shows the token');
  const before = n(s.db, 'web_vault_audit');
  for (const token of [null, '', 'fixture-run-token-guess', sha(c.body.vault_token)]) {
    const r = await read(s.env, { run_id: c.body.id, machine: 'fly-legit-machine' }, token);
    assert.equal(r.status, 403, JSON.stringify(r.body));
    assert.equal(r.body.why, 'bad_token');
    assert.equal('value' in r.body, false);
  }
  const a = audits(s.db).slice(before);
  assert.equal(a.length, 4);
  assert.ok(a.every((x) => x.outcome === 'refused:bad_token' && x.actor === 'fly-legit-machine'));
});

test('T4 a re-claim after the lease ran out voids the old token', async (t) => {
  const s = await store(t); if (!s) return;
  allow(s.db);
  await set(s.env, 'p1', SITE, 'password', 'fixture-pass-t4');
  await enqueue(s.env, 'web-task', 'p1');
  const c1 = await claim(s.env, 'm1');
  s.db.prepare('UPDATE lane_runs SET lease_until=? WHERE id=?').run(iso(NOW_MS - 1000), c1.body.id);
  const c2 = await claim(s.env, 'm2');
  assert.equal(c2.status, 200, JSON.stringify(c2.body));
  assert.equal(c2.body.id, c1.body.id);
  assert.notEqual(c2.body.vault_token, c1.body.vault_token);
  assert.equal(n(s.db, 'web_vault_run_token'), 1);
  assert.equal((await read(s.env, { run_id: c1.body.id, machine: 'm2' }, c1.body.vault_token)).body.why, 'bad_token');
  assert.equal((await read(s.env, { run_id: c1.body.id, machine: 'm1' }, c1.body.vault_token)).body.why, 'not_claimer');
  assert.equal((await read(s.env, { run_id: c2.body.id, machine: 'm2' }, c2.body.vault_token)).body.value, 'fixture-pass-t4');
});

test('T5 a claim of another lane carries no vault_token and writes no token row', async (t) => {
  const s = await store(t); if (!s) return;
  await enqueue(s.env, 'demo', 'p1');
  const c = await claim(s.env, 'm1');
  assert.equal(c.status, 200);
  assert.equal(c.body.lane, 'demo');
  assert.equal('vault_token' in c.body, false);
  assert.equal(n(s.db, 'web_vault_run_token'), 0);
});

// ── K2 ──────────────────────────────────────────────────────────────────────
test('K2 the run-token table, its index, its seed and its retention rule', async (t) => {
  const s = await store(t); if (!s) return;
  const cols = s.db.prepare('PRAGMA table_info(web_vault_run_token)').all().map((c) => c.name);
  assert.deepEqual(cols.sort(), ['created_at', 'machine', 'run_id', 'token_hash']);
  const idx = s.db.prepare("SELECT sql FROM sqlite_master WHERE type='index' AND name='idx_web_vault_run_token_at'").get();
  assert.match(idx.sql, /\(created_at\)/);
  assert.equal(s.db.prepare("SELECT value FROM settings WHERE key='retention.web_vault_run_token.days'").get().value, '2');
  const rule = RULES.find((r) => r.rule === 'web_vault_run_token.age');
  assert.ok(rule && !rule.archive, 'a plain delete rule');
  s.db.prepare('INSERT INTO web_vault_run_token (run_id, machine, token_hash, created_at) VALUES (1, ?, ?, ?), (2, ?, ?, ?)')
    .run('m1', sha('a'), ago(3), 'm1', sha('b'), NOW);
  assert.deepEqual(s.db.prepare(rule.ids).all(ago(2), 10).map((r) => r.id), [1]);
  s.db.prepare(rule.del).run(JSON.stringify([1]));
  assert.deepEqual(s.db.prepare('SELECT run_id FROM web_vault_run_token').all().map((r) => r.run_id), [2]);
});

// ── S1-S3 ───────────────────────────────────────────────────────────────────
test('S1 entries stale=1 lists a row past retain_days and not a fresh one; entries hold no secret', async (t) => {
  const s = await store(t); if (!s) return;
  for (const f of ['old', 'fresh']) await set(s.env, 'p1', SITE, f, `fixture-pass-${f}`);
  s.db.prepare("UPDATE web_vault SET last_used_at = ? WHERE field = 'old'").run(ago(181));
  s.db.prepare("UPDATE web_vault SET last_used_at = ? WHERE field = 'fresh'").run(ago(179));
  const r = await call(s.env, 'GET', '/api/web-vault/entries?stale=1');
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.deepEqual(r.body.rows.map((x) => x.field), ['old']);
  assert.equal(r.body.retain_days, 180);
  const all = await call(s.env, 'GET', '/api/web-vault/entries?project=p1');
  assert.deepEqual(all.body.rows.map((x) => x.field), ['fresh', 'old']);
  for (const row of all.body.rows) {
    for (const k of ['project', 'site', 'field', 'key_id', 'created_at', 'updated_at', 'last_used_at']) assert.ok(k in row, k);
    for (const k of ['ciphertext', 'iv', 'value', 'id']) assert.equal(k in row, false, `entries never send ${k}`);
  }
  assert.equal(JSON.stringify(all.body).includes('fixture-pass'), false);
  assert.equal((await call(s.env, 'GET', '/api/web-vault/entries?project=p1&site=other.org')).body.rows.length, 0);
  assert.equal((await call(s.env, 'GET', '/api/web-vault/entries?limit=0')).status, 400);
  assert.equal((await call(s.env, 'GET', '/api/web-vault/entries?limit=501')).status, 400);
  const lim = await call(s.env, 'GET', '/api/web-vault/entries?limit=1');
  assert.deepEqual({ n: lim.body.rows.length, more: lim.body.more }, { n: 1, more: true });
});

test('S2 a retain_days setting that is not an integer in 1..3650 falls back to 180; a valid one is used', async (t) => {
  const s = await store(t); if (!s) return;
  for (const [f, d] of [['d31', 31], ['d179', 179], ['d181', 181]]) {
    await set(s.env, 'p1', SITE, f, `fixture-pass-${f}`);
    s.db.prepare('UPDATE web_vault SET last_used_at = ? WHERE field = ?').run(ago(d), f);
  }
  for (const bad of ['abc', '0', '4000', '', '-5']) {
    setting(s.db, 'web_vault.retain_days', bad);
    const r = await call(s.env, 'GET', '/api/web-vault/entries?stale=1');
    assert.deepEqual({ d: r.body.retain_days, f: r.body.rows.map((x) => x.field) }, { d: 180, f: ['d181'] }, `setting '${bad}'`);
  }
  setting(s.db, 'web_vault.retain_days', '30');
  const r = await call(s.env, 'GET', '/api/web-vault/entries?stale=1&project=p1');
  assert.deepEqual(r.body.rows.map((x) => x.field), ['d181', 'd179', 'd31']);
});

test('S3 no route and no retention run deletes a vault row, however stale', async (t) => {
  const s = await store(t); if (!s) return;
  setting(s.db, 'retention.dry_run', '0');
  await set(s.env, 'p1', SITE, 'password', 'fixture-pass-s3');
  s.db.prepare('UPDATE web_vault SET last_used_at = ?, created_at = ?, updated_at = ?').run(ago(4000), ago(4000), ago(4000));
  await call(s.env, 'GET', '/api/web-vault/entries?stale=1');
  const ret = await call(s.env, 'POST', '/api/retention/run', {});
  assert.equal(ret.status, 200);
  assert.equal(RULES.some((r) => r.table === 'web_vault'), false, 'no retention rule names web_vault');
  for (const m of ['DELETE', 'PUT']) assert.equal((await call(s.env, m, '/api/web-vault/set', {})).status, 404, m);
  assert.equal(n(s.db, 'web_vault'), 1);
});

// ── R1-R3 ───────────────────────────────────────────────────────────────────
function oldAudits(db, k, days) {
  const ins = db.prepare("INSERT INTO web_vault_audit (at, action, outcome, project, site, field, actor) VALUES (?, 'read', 'ok', 'p1', ?, 'password', 'm1')");
  for (let i = 0; i < k; i++) ins.run(ago(days), SITE);
}
const ruleOf = (body) => (body.rules || []).find((x) => x.rule === 'web_vault_audit.age');

test('R1 the seeded dry run counts audit rows past 90 days and deletes none', async (t) => {
  const s = await store(t); if (!s) return;
  oldAudits(s.db, 3, 91);
  oldAudits(s.db, 2, 89);
  const r = await call(s.env, 'POST', '/api/retention/run', {});
  assert.equal(r.body.dry_run, true, 'the seed is a dry run');
  const rr = ruleOf(r.body);
  assert.ok(rr, 'the rule runs');
  assert.deepEqual({ counted: rr.counted, removed: rr.removed }, { counted: 3, removed: 0 });
  assert.equal(n(s.db, 'web_vault_audit'), 5);
  const row = s.db.prepare("SELECT dry_run, counted FROM retention_runs WHERE rule = 'web_vault_audit.age'").get();
  assert.deepEqual({ ...row }, { dry_run: 1, counted: 3 });
});

test('R2 dry_run 0 with the archive unbound deletes nothing and says why', async (t) => {
  const s = await store(t); if (!s) return;
  setting(s.db, 'retention.dry_run', '0');
  oldAudits(s.db, 3, 91);
  const rr = ruleOf((await call(s.env, 'POST', '/api/retention/run', {})).body);
  assert.deepEqual({ removed: rr.removed, error: rr.error }, { removed: 0, error: 'archive not bound' });
  assert.equal(n(s.db, 'web_vault_audit'), 3);
});

test('R3 dry_run 0 with the archive bound moves old audit rows to the archive and keeps new ones', async (t) => {
  const s = await store(t); if (!s) return;
  const { DatabaseSync } = await import('node:sqlite');
  const adb = new DatabaseSync(':memory:');
  setting(s.db, 'retention.dry_run', '0');
  oldAudits(s.db, 3, 91);
  oldAudits(s.db, 2, 89);
  const rr = ruleOf((await call({ ...s.env, ARCHIVE: d1(adb) }, 'POST', '/api/retention/run', {})).body);
  assert.deepEqual({ removed: rr.removed, error: rr.error }, { removed: 3, error: null });
  assert.equal(n(s.db, 'web_vault_audit'), 2);
  assert.equal(Number(adb.prepare('SELECT COUNT(*) AS n FROM web_vault_audit').get().n), 3);
  assert.equal(Number(s.db.prepare('SELECT COUNT(*) AS n FROM web_vault_audit WHERE at < ?').get(ago(90)).n), 0);
});

// ── E1 ──────────────────────────────────────────────────────────────────────
test('E1 at 2,000 vault rows, 20,000 audit rows and 5,000 token rows every hot read uses an index and no full SCAN', async (t) => {
  const s = await store(t); if (!s) return;
  s.db.exec('BEGIN');
  const v = s.db.prepare(`INSERT INTO web_vault (project, site, field, ciphertext, iv, key_id, created_at, updated_at, last_used_at)
                          VALUES (?, ?, ?, 'Y3Q=', 'aXY=', 1, ?, ?, ?)`);
  for (let i = 0; i < 2000; i++) v.run(`p${i % 20}`, `s${Math.floor(i / 20) % 25}.example.com`, `f${i}`, ago(i % 400), ago(i % 400), ago(i % 400));
  const a = s.db.prepare("INSERT INTO web_vault_audit (at, action, outcome, project, site, field, actor) VALUES (?, 'read', 'ok', ?, ?, 'f', 'm1')");
  for (let i = 0; i < 20000; i++) a.run(ago(i % 200), `p${i % 20}`, `s${i % 25}.example.com`);
  const tk = s.db.prepare("INSERT INTO web_vault_run_token (run_id, machine, token_hash, created_at) VALUES (?, 'm9', 'h', ?)");
  for (let i = 0; i < 5000; i++) tk.run(1000000 + i, ago(i % 10));
  s.db.exec('COMMIT');
  s.db.exec('ANALYZE');
  const log = [];
  const env = { ...s.env, DB: capturingD1(s.db, log) };
  allow(s.db);
  const id = run(s.db);
  await set(env, 'p1', SITE, 'password', 'fixture-pass-e1');
  assert.equal((await read(env, { run_id: id })).status, 200);
  for (const q of ['?project=p1', '?project=p1&site=app.example.com', '', '?stale=1', '?stale=1&project=p1']) {
    assert.equal((await call(env, 'GET', `/api/web-vault/entries${q}`)).status, 200, q);
  }
  for (const q of ['?project=p1', '?project=p1&site=app.example.com']) {
    assert.equal((await call(env, 'GET', `/api/web-vault/audit${q}`)).status, 200, q);
  }
  const hot = log.filter((x) => /\bweb_vault(_audit|_run_token)?\b/.test(x.sql));
  assert.ok(hot.length >= 8, `captured ${hot.length} vault reads`);
  assert.ok(hot.some((x) => /FROM web_vault_run_token WHERE run_id/.test(x.sql)), 'the read checks the run token');
  const rule = RULES.find((r) => r.rule === 'web_vault_audit.age');
  assert.ok(rule, 'the retention rule exists');
  hot.push({ sql: rule.ids, binds: [ago(90), 500] });
  hot.push({ sql: RULES.find((r) => r.rule === 'web_vault_run_token.age').ids, binds: [ago(2), 500] });
  for (const { sql, binds } of hot) {
    const lines = plan(s.db, sql, ...binds.map((b) => (b === undefined ? null : b)));
    assert.deepEqual(fullScans(lines, ['web_vault', 'web_vault_audit', 'web_vault_run_token']), [], `${sql}\n${lines.join('\n')}`);
    assert.ok(lines.some((l) => /USING (COVERING )?INDEX (uq_web_vault_entry|idx_web_vault_\w+)|USING INTEGER PRIMARY KEY/.test(l)), `${sql}\n${lines.join('\n')}`);
  }
});
