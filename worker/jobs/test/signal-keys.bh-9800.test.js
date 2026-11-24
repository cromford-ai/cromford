// BH-9800 (slice C0): the signal key store, per-project Sentry and PostHog keys.
//
// Driven through the REAL worker.fetch over a node:sqlite D1 with the composed
// jobs schema. The clock is pinned. Every secret is a `fixture` string and the
// AES key is built from a `fixture-key-*` string. globalThis.fetch is a stub in
// EVERY case: it records each call and throws on a URL the case did not expect,
// so no case reaches a real vendor.
//
// K1      tables, indexes, kind seeds, settings seeds; no plain-secret column
// S1-S6   set: ciphertext + one audit row; trim; prefix; host allow; key missing; size
// A1-A7   the operator gate; every refusal writes nothing
// L1-L4   list: metadata only; rotate_by; more; ?project=
// X1-X9   test: ok; 401; exact URLs and header; timeout; network; redirect;
//         batch throw; no row; a set resets last_test_*
// CL1-CL2 clear
// R1-R12  lane read: the refusal table, one audit row per outcome, the ok case
// R13-R14 a malformed read body; a failed audit batch sends no value
// H1-H4   hub read
// M1-M3   token mask
// RT1-RT2 retention of signal_key_audit
// RT-1    one stored row through set, list, read, hub-read and test
// E1      EXPLAIN QUERY PLAN at 2,000 / 50,000 rows
// P1-P10  the secret prefix check
// U1-U9   the probe host allow
// B1      a whole flow makes no vendor call outside the expected URLs
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { openDb, d1 } from './lib/d1-sqlite.bh-1030.js';
import { plan, fullScans, capturingD1 } from './lib/d1-volume.bh-6727.js';
import { RULES } from '../src/routes/retention.js';
import { createHash } from 'node:crypto';

// Loaded by dynamic import, so each case fails on its own while a module is absent.
const MASK = await import('../src/lib/token-mask.js').catch(() => null);
const PROBE = await import('../src/lib/signal-probe.js').catch(() => null);
const ROUTE = await import('../src/routes/signal-keys.js').catch(() => null);

const SECRET = 'fixture-harness-secret';
const ADMIN = 'fixture-admin-token-9800';
const HUB = 'fixture-hub-token-9800';
const BOX_OPS = 'fixture-box-ops-token-9800';
const HUMAN = 'fixture-human-token-9800';
const OWNER = 'owner@example.com';
const KEY1 = Buffer.from('fixture-key-signal-keys-bh9800-1').toString('base64');
const NOW_MS = Date.parse('2026-11-17T12:00:00Z');
const DAY = 86400e3;
const iso = (ms) => new Date(ms).toISOString().replace(/\.\d{3}Z$/, 'Z');
const ago = (days) => iso(NOW_MS - days * DAY);
const NOW = iso(NOW_MS);
const RUN_TOKEN = 'fixture-run-token-9800';
const sha = (x) => createHash('sha256').update(x).digest('hex');

const S_TOKEN = 'sntryu_fixture0sentry0token0bh9800';
const P_KEY = 'phx_fixture0posthog0key0bh9800';
const SENTRY = { org: 'fixture-org', project: 'fixture-proj', token: S_TOKEN };
const POSTHOG = { host: 'https://us.posthog.com', project_id: '598179', key: P_KEY };
const S_URL = 'https://sentry.io/api/0/organizations/fixture-org/projects/';
const P_URL = 'https://us.posthog.com/api/projects/598179/';

// The fetch stub. handlers: { url: (url, init) => Response | Promise }. Any
// other URL is recorded in `unexpected` and throws.
function stubFetch(t, handlers = {}) {
  const real = globalThis.fetch;
  const calls = [], unexpected = [];
  globalThis.fetch = async (input, init = {}) => {
    const url = typeof input === 'string' ? input : input.url;
    calls.push({ url, init });
    const h = handlers[url];
    if (!h) { unexpected.push(url); throw new Error(`unexpected fetch ${url}`); }
    return h(url, init);
  };
  t.after(() => { globalThis.fetch = real; });
  return { calls, unexpected };
}

async function store(t, extra = {}, handlers = {}) {
  t.mock.timers.enable({ apis: ['Date'], now: NOW_MS });
  const o = await openDb();
  if (!o) { t.skip('node:sqlite unavailable'); return null; }
  const stub = stubFetch(t, handlers);
  const env = {
    DB: o.DB, HARNESS_SECRET: SECRET, WEB_VAULT_ADMIN_TOKEN: ADMIN, WEB_VAULT_KEY_1: KEY1,
    ENVELOPE_HUB_TOKEN: HUB, BOX_OPS_TOKEN: BOX_OPS, BOX_OPS_OWNERS: OWNER, HUMAN_VERDICT_TOKEN: HUMAN, ...extra,
  };
  return { db: o.db, env, stub };
}

async function call(env, method, path, body, { admin = ADMIN, bearer = SECRET, runToken = null, hub = null, headers: extra = {} } = {}) {
  const headers = { 'content-type': 'application/json', ...extra };
  if (bearer !== null) headers.authorization = `Bearer ${bearer}`;
  if (admin !== null) headers['x-web-vault-admin-token'] = admin;
  if (runToken !== null) headers['x-web-vault-run-token'] = runToken;
  if (hub !== null) headers['x-envelope-hub-token'] = hub;
  const res = await worker.fetch(new Request(`https://jobs.test${path}`, {
    method, headers, body: body === undefined ? undefined : JSON.stringify(body),
  }), env);
  const text = await res.text();
  let parsed = null;
  try { parsed = JSON.parse(text); } catch { parsed = { raw: text }; }
  return { status: res.status, body: parsed, text };
}
const setKey = (env, project, kind, fields, opts) => call(env, 'POST', '/api/signal-keys/set', { project, kind, fields }, opts);
const clearKey = (env, project, kind, opts) => call(env, 'POST', '/api/signal-keys/clear', { project, kind }, opts);
const testKey = (env, project, kind, opts) => call(env, 'POST', '/api/signal-keys/test', { project, kind }, opts);
const list = (env, q = '', opts = {}) => call(env, 'GET', `/api/signal-keys${q}`, undefined, { admin: null, ...opts });
const laneRead = (env, b, token = RUN_TOKEN) => call(env, 'POST', '/api/signal-keys/read',
  { project: 'p1', kind: 'sentry', machine: 'm1', ...b }, { admin: null, runToken: token });
const hubRead = (env, project, kind, hub = HUB, opts = {}) => call(env, 'POST', '/api/signal-keys/hub-read', { project, kind }, { admin: null, hub, ...opts });

function setting(db, key, value) {
  db.prepare(`INSERT INTO settings (key,value,note,actor,updated_at) VALUES (?,?,'',?,?)
              ON CONFLICT(key) DO UPDATE SET value=excluded.value`).run(key, String(value), 'test', NOW);
}
function run(db, { lane = 'sentry-triage', project = 'p1', status = 'claimed', claimed_by = 'm1', lease_until = iso(NOW_MS + 600e3),
  token = RUN_TOKEN, token_machine = claimed_by || 'm1' } = {}) {
  const id = Number(db.prepare(`INSERT INTO lane_runs (lane, project, args_json, enqueued_at, claimed_at, claimed_by, lease_until, attempts, status)
                            VALUES (?, ?, '[]', ?, ?, ?, ?, 1, ?)`)
    .run(lane, project, NOW, NOW, claimed_by, lease_until, status).lastInsertRowid);
  if (token !== null) {
    db.prepare('INSERT INTO web_vault_run_token (run_id, machine, token_hash, created_at) VALUES (?, ?, ?, ?)').run(id, token_machine, sha(token), NOW);
  }
  return id;
}
const audits = (db) => db.prepare('SELECT * FROM signal_key_audit ORDER BY id').all();
const keyRows = (db) => db.prepare('SELECT * FROM signal_keys ORDER BY id').all();
const n = (db, table) => Number(db.prepare(`SELECT COUNT(*) AS n FROM ${table}`).get().n);
const noSecret = (text) => !text.includes(S_TOKEN) && !text.includes(P_KEY) && !/fixture0(sentry|posthog)0/.test(text);
const ok = (status = 200) => async () => new Response('{"vendor":"body phx_vendor0leak"}', { status });

// ── K1 ──────────────────────────────────────────────────────────────────────
test('K1 the schema has the 3 tables, their indexes, the 2 kind seeds and the 6 settings seeds', async (t) => {
  const s = await store(t); if (!s) return;
  const idx = Object.fromEntries(s.db.prepare("SELECT name, sql FROM sqlite_master WHERE type='index' AND tbl_name IN ('signal_keys','signal_key_audit')").all().map((r) => [r.name, r.sql]));
  assert.match(idx.uq_signal_keys_entry || '', /UNIQUE INDEX[^(]*\(project, kind\)/);
  assert.match(idx.idx_signal_key_audit_at || '', /\(at\)/);
  assert.match(idx.idx_signal_key_audit_entry || '', /\(project, kind, at\)/);
  const kinds = s.db.prepare('SELECT * FROM signal_key_kinds ORDER BY sort').all();
  assert.deepEqual(kinds.map((k) => k.kind), ['sentry', 'posthog']);
  const f = Object.fromEntries(kinds.map((k) => [k.kind, JSON.parse(k.fields_json)]));
  assert.deepEqual(f.sentry.map((x) => [x.name, x.label, x.secret]), [['org', 'Organization slug', 0], ['project', 'Project slug', 0], ['token', 'API token', 1]]);
  assert.deepEqual(f.posthog.map((x) => [x.name, x.label, x.secret]), [['host', 'Host', 0], ['project_id', 'Project id', 0], ['key', 'Personal API key', 1]]);
  assert.deepEqual(f.sentry[2].prefixes, ['sntryu_', 'sntrys_']);
  assert.deepEqual(f.posthog[2].prefixes, ['phx_']);
  for (const k of kinds) assert.ok(k.scope_note && k.test_template && k.host_allow, k.kind);
  const seeds = Object.fromEntries(s.db.prepare("SELECT key, value FROM settings WHERE key LIKE 'signal_keys.%' OR key = 'retention.signal_key_audit.days'").all().map((r) => [r.key, r.value]));
  const wantSeeds = [
    ['signal_keys.read_lanes', ''], ['signal_keys.test_timeout_ms', '10000'], ['signal_keys.rotate_days', '90'],
    ['signal_keys.list_limit', '500'], ['signal_keys.value_max_bytes', '4096'], ['retention.signal_key_audit.days', '90'],
  ];
  for (const [k, v] of wantSeeds) assert.equal(seeds[k], v, k);
  assert.deepEqual(Object.keys(seeds).sort(), wantSeeds.map(([k]) => k).sort(), 'no other seeded key');
  const cols = s.db.prepare('PRAGMA table_info(signal_keys)').all().map((c) => c.name);
  for (const c of ['project', 'kind', 'fields_json', 'ciphertext', 'iv', 'key_id', 'updated_by', 'last_used_at', 'last_test_at', 'last_test_status', 'last_test_result']) assert.ok(cols.includes(c), c);
  assert.equal(cols.some((c) => /value|plain|secret|token/.test(c)), false, 'no plain-secret column');
});

// ── S1-S6 ───────────────────────────────────────────────────────────────────
test('S1 set stores ciphertext, not the value, the fields in clear, and exactly one set ok audit row', async (t) => {
  const s = await store(t); if (!s) return;
  const r = await setKey(s.env, 'p-s1', 'sentry', SENTRY);
  assert.equal(r.status, 200, r.text);
  assert.equal(r.body.stored, true);
  assert.deepEqual(r.body.fields, { org: 'fixture-org', project: 'fixture-proj' });
  assert.equal(r.body.updated_by, 'operator');
  assert.ok(noSecret(r.text), 'the answer holds no secret');
  const rows = keyRows(s.db);
  assert.equal(rows.length, 1);
  const fj = JSON.parse(rows[0].fields_json);
  assert.equal(fj.org, 'fixture-org');
  assert.equal(fj.project, 'fixture-proj');
  assert.deepEqual(Object.keys(fj).sort(), ['org', 'project'], 'the fields in clear, no other field');
  assert.ok(rows[0].ciphertext && rows[0].iv);
  assert.ok(noSecret(JSON.stringify(rows)), 'no stored cell holds the secret');
  const a = audits(s.db);
  assert.deepEqual(a.map((x) => [x.action, x.outcome, x.project, x.kind, x.actor]), [['set', 'ok', 'p-s1', 'sentry', 'operator']]);
});

test('S2 a pasted key with leading spaces and a trailing \\r\\n is stored trimmed', async (t) => {
  const s = await store(t); if (!s) return;
  const r = await setKey(s.env, 'p1', 'sentry', { org: ' fixture-org\t', project: 'fixture-proj\n', token: `   ${S_TOKEN}\r\n` });
  assert.equal(r.status, 200, r.text);
  const id = run(s.db, { project: 'p1' });
  setting(s.db, 'signal_keys.read_lanes', 'sentry-triage');
  const rd = await laneRead(s.env, { run_id: id });
  assert.equal(rd.status, 200, rd.text);
  assert.equal(rd.body.value, S_TOKEN);
  assert.deepEqual(rd.body.fields, { org: 'fixture-org', project: 'fixture-proj' });
});

test('S3 a wrong prefix is 400, names the field and the right prefix, and writes nothing', async (t) => {
  const s = await store(t); if (!s) return;
  const r = await setKey(s.env, 'p1', 'posthog', { ...POSTHOG, key: 'phc_fixture0project0key' });
  assert.equal(r.status, 400, r.text);
  assert.match(r.body.error, /key/);
  assert.match(r.body.error, /phx_/);
  assert.equal(r.body.field, 'key');
  assert.equal(n(s.db, 'signal_keys'), 0);
  assert.equal(n(s.db, 'signal_key_audit'), 0);
});

test('S4 a host outside host_allow is 400 and writes nothing', async (t) => {
  const s = await store(t); if (!s) return;
  const r = await setKey(s.env, 'p1', 'posthog', { ...POSTHOG, host: 'https://us.posthog.com.evil.test' });
  assert.equal(r.status, 400, r.text);
  assert.equal(r.body.field, 'host');
  assert.equal(n(s.db, 'signal_keys') + n(s.db, 'signal_key_audit'), 0);
});

test('S5 key missing on the worker is 503 with one refused:key_missing row and no entry row', async (t) => {
  const s = await store(t, { WEB_VAULT_KEY_1: undefined }); if (!s) return;
  const r = await setKey(s.env, 'p1', 'sentry', SENTRY);
  assert.equal(r.status, 503, r.text);
  assert.equal(n(s.db, 'signal_keys'), 0);
  assert.deepEqual(audits(s.db).map((x) => [x.action, x.outcome]), [['set', 'refused:key_missing']]);
  assert.ok(noSecret(r.text));
});

test('S6 a secret over signal_keys.value_max_bytes is 400 and writes nothing; the knob moves the bound', async (t) => {
  const s = await store(t); if (!s) return;
  const long = `phx_${'a'.repeat(4100)}`;
  assert.equal((await setKey(s.env, 'p1', 'posthog', { ...POSTHOG, key: long })).status, 400);
  setting(s.db, 'signal_keys.value_max_bytes', '64');
  const mid = `phx_${'a'.repeat(70)}`;
  const r = await setKey(s.env, 'p1', 'posthog', { ...POSTHOG, key: mid });
  assert.equal(r.status, 400, r.text);
  assert.match(r.body.error, /64/);
  assert.equal(n(s.db, 'signal_keys') + n(s.db, 'signal_key_audit'), 0);
});

// ── A1-A7 ───────────────────────────────────────────────────────────────────
test('A1-A7 the operator gate on set, clear and test; every refusal writes nothing', async (t) => {
  const s = await store(t); if (!s) return;
  const boxOps = (identity) => ({ 'x-box-ops-token': BOX_OPS, ...(identity === null ? {} : { 'x-box-ops-identity': identity }) });
  const refusals = [
    ['A1 the bearer alone', s.env, { admin: null }],
    ['A2 admin token with one trailing byte', s.env, { admin: ADMIN + 'x' }],
    ['A3 worker admin token blank', { ...s.env, WEB_VAULT_ADMIN_TOKEN: ' ' }, { admin: '' }],
    ['A4 box-ops token, identity not an owner', s.env, { admin: null, headers: boxOps('someone@example.com') }],
    ['A5 box-ops token, identity missing', s.env, { admin: null, headers: boxOps(null) }],
    ['A6 BOX_OPS_TOKEN equal to HARNESS_SECRET', { ...s.env, BOX_OPS_TOKEN: SECRET }, { admin: null, headers: { 'x-box-ops-token': SECRET, 'x-box-ops-identity': OWNER } }],
    ['A7 wrong box-ops token', s.env, { admin: null, headers: { 'x-box-ops-token': 'fixture-wrong', 'x-box-ops-identity': OWNER } }],
  ];
  for (const [name, env, opts] of refusals) {
    assert.equal((await setKey(env, 'p1', 'sentry', SENTRY, opts)).status, 403, `${name} set`);
    assert.equal((await clearKey(env, 'p1', 'sentry', opts)).status, 403, `${name} clear`);
    assert.equal((await testKey(env, 'p1', 'sentry', opts)).status, 403, `${name} test`);
  }
  assert.equal(n(s.db, 'signal_keys'), 0, 'no entry written');
  assert.equal(n(s.db, 'signal_key_audit'), 0, 'no audit written');
  assert.equal(s.stub.calls.length, 0, 'no vendor call');
  // The passes: an owner email (upper case is normalized), the human token, the admin token.
  const viaOwner = await setKey(s.env, 'p1', 'sentry', SENTRY, { admin: null, headers: boxOps('Owner@Example.com') });
  assert.equal(viaOwner.status, 200, viaOwner.text);
  assert.equal(viaOwner.body.updated_by, OWNER);
  assert.equal(keyRows(s.db)[0].updated_by, OWNER);
  assert.equal(audits(s.db)[0].actor, OWNER);
  const viaHuman = await setKey(s.env, 'p2', 'sentry', SENTRY, { admin: null, headers: { 'x-human-verdict-token': HUMAN } });
  assert.equal(viaHuman.status, 200, viaHuman.text);
  assert.equal(viaHuman.body.updated_by, 'human-token');
  // The owner_proof_mode row is not read: shadow mode does not open the routes.
  setting(s.db, 'owner_proof_mode', 'shadow');
  assert.equal((await setKey(s.env, 'p3', 'sentry', SENTRY, { admin: null })).status, 403, 'no shadow mode');
});

// ── L1-L4 ───────────────────────────────────────────────────────────────────
test('L1 list answers the kinds and the metadata; no ciphertext, iv or secret in the JSON text', async (t) => {
  const s = await store(t); if (!s) return;
  await setKey(s.env, 'p1', 'sentry', SENTRY);
  await setKey(s.env, 'p1', 'posthog', POSTHOG);
  const r = await list(s.env);
  assert.equal(r.status, 200, r.text);
  assert.deepEqual(r.body.kinds.map((k) => k.kind), ['sentry', 'posthog']);
  assert.ok(r.body.kinds[0].fields.every((f) => f.name && f.label), 'field defs with labels');
  assert.match(r.body.kinds[0].scope_note, /event:write/);
  assert.equal(r.body.rows.length, 2);
  const row = r.body.rows.find((x) => x.kind === 'posthog');
  assert.equal(row.secret_set, true);
  assert.deepEqual(row.fields, { host: 'https://us.posthog.com', project_id: '598179' });
  assert.equal(row.updated_by, 'operator');
  assert.equal(row.updated_at, NOW);
  for (const k of ['last_used_at', 'last_test_at', 'last_test_status', 'last_test_result']) assert.ok(k in row, k);
  assert.equal(row.rotate_by, iso(NOW_MS + 90 * DAY));
  assert.ok(noSecret(r.text), 'no secret');
  assert.equal(/ciphertext|"iv"/.test(r.text), false, 'no ciphertext and no iv');
  const ct = keyRows(s.db).map((x) => x.ciphertext);
  assert.equal(ct.some((c) => r.text.includes(c)), false);
});

test('L2 a row set 91 days ago is rotate_overdue with the 90 seed, and not with rotate_days 120', async (t) => {
  const s = await store(t); if (!s) return;
  await setKey(s.env, 'p1', 'sentry', SENTRY);
  s.db.prepare('UPDATE signal_keys SET updated_at=?').run(ago(91));
  let r = await list(s.env);
  assert.equal(r.body.rows[0].rotate_overdue, true);
  assert.equal(r.body.rotate_days, 90);
  setting(s.db, 'signal_keys.rotate_days', '120');
  r = await list(s.env);
  assert.equal(r.body.rows[0].rotate_overdue, false);
  assert.equal(r.body.rows[0].rotate_by, iso(NOW_MS - 91 * DAY + 120 * DAY));
});

test('L3 list_limit+1 rows answer more:true and list_limit rows', async (t) => {
  const s = await store(t); if (!s) return;
  setting(s.db, 'signal_keys.list_limit', '2');
  for (const p of ['p1', 'p2', 'p3']) await setKey(s.env, p, 'sentry', SENTRY);
  const r = await list(s.env);
  assert.equal(r.body.rows.length, 2);
  assert.equal(r.body.more, true);
  setting(s.db, 'signal_keys.list_limit', '3');
  assert.equal((await list(s.env)).body.more, false);
});

test('L4 ?project= lists that project only; a bad project is 400; no bearer is 401', async (t) => {
  const s = await store(t); if (!s) return;
  await setKey(s.env, 'p1', 'sentry', SENTRY);
  await setKey(s.env, 'p2', 'posthog', POSTHOG);
  const r = await list(s.env, '?project=p2');
  assert.deepEqual(r.body.rows.map((x) => [x.project, x.kind]), [['p2', 'posthog']]);
  assert.equal((await list(s.env, '?project=a%20b')).status, 400);
  assert.equal((await list(s.env, '', { bearer: null })).status, 401);
});

// ── X1-X9 ───────────────────────────────────────────────────────────────────
test('X1 a 200 from the vendor stores ok, status 200 and one test audit row', async (t) => {
  const s = await store(t, {}, { [S_URL]: ok(200) }); if (!s) return;
  await setKey(s.env, 'p1', 'sentry', SENTRY);
  const r = await testKey(s.env, 'p1', 'sentry');
  assert.equal(r.status, 200, r.text);
  assert.deepEqual([r.body.ok, r.body.result, r.body.status, r.body.tested_at], [true, 'ok', 200, NOW]);
  const row = keyRows(s.db)[0];
  assert.deepEqual([row.last_test_result, row.last_test_status, row.last_test_at], ['ok', 200, NOW]);
  assert.deepEqual(audits(s.db).map((x) => [x.action, x.outcome]), [['set', 'ok'], ['test', 'ok']]);
  assert.ok(noSecret(r.text));
  assert.equal(r.text.includes('phx_vendor0leak'), false, 'no vendor body text');
});

test('X2 a 401 stores http_401 with the reason "the key was refused"', async (t) => {
  const s = await store(t, {}, { [S_URL]: ok(401) }); if (!s) return;
  await setKey(s.env, 'p1', 'sentry', SENTRY);
  const r = await testKey(s.env, 'p1', 'sentry');
  assert.equal(r.status, 200, r.text);
  assert.deepEqual([r.body.ok, r.body.result, r.body.status, r.body.reason], [false, 'http_401', 401, 'the key was refused']);
  assert.equal(keyRows(s.db)[0].last_test_result, 'http_401');
  assert.equal(audits(s.db).at(-1).outcome, 'http_401');
});

test('X3 the stub sees the exact vendor URL and Authorization: Bearer <key> for each kind', async (t) => {
  const s = await store(t, {}, { [S_URL]: ok(200), [P_URL]: ok(200) }); if (!s) return;
  await setKey(s.env, 'p1', 'sentry', SENTRY);
  await setKey(s.env, 'p1', 'posthog', { ...POSTHOG, host: 'https://US.PostHog.com/' });
  assert.equal((await testKey(s.env, 'p1', 'sentry')).body.result, 'ok');
  assert.equal((await testKey(s.env, 'p1', 'posthog')).body.result, 'ok');
  assert.deepEqual(s.stub.calls.map((c) => c.url), [S_URL, P_URL]);
  const auth = (c) => new Headers(c.init.headers).get('authorization');
  assert.deepEqual(s.stub.calls.map(auth), [`Bearer ${S_TOKEN}`, `Bearer ${P_KEY}`]);
  assert.ok(s.stub.calls.every((c) => c.init.redirect === 'manual'), 'redirects are never followed');
  assert.deepEqual(s.stub.unexpected, []);
});

test('X4 a vendor that never answers is timeout after signal_keys.test_timeout_ms', async (t) => {
  const hang = (url, init) => new Promise((_, reject) => {
    init.signal.addEventListener('abort', () => reject(Object.assign(new Error('aborted'), { name: 'AbortError' })));
  });
  const s = await store(t, {}, { [S_URL]: hang }); if (!s) return;
  setting(s.db, 'signal_keys.test_timeout_ms', '1000');
  await setKey(s.env, 'p1', 'sentry', SENTRY);
  const t0 = performance.now();
  const r = await testKey(s.env, 'p1', 'sentry');
  const took = performance.now() - t0;
  assert.equal(r.body.result, 'timeout', r.text);
  assert.ok(took >= 900 && took < 5000, `took ${took} ms`);
  assert.equal(keyRows(s.db)[0].last_test_result, 'timeout');
  assert.equal(keyRows(s.db)[0].last_test_status, null);
});

test('X5 a fetch throw is network', async (t) => {
  const s = await store(t, {}, { [S_URL]: async () => { throw new TypeError('fetch failed'); } }); if (!s) return;
  await setKey(s.env, 'p1', 'sentry', SENTRY);
  t.mock.method(console, 'warn', () => {});
  const r = await testKey(s.env, 'p1', 'sentry');
  assert.deepEqual([r.body.ok, r.body.result], [false, 'network']);
  assert.equal(keyRows(s.db)[0].last_test_result, 'network');
});

test('X6 a redirect is http_302 and is not followed', async (t) => {
  const s = await store(t, {}, { [S_URL]: async () => new Response(null, { status: 302, headers: { location: 'https://other.example.com/' } }) }); if (!s) return;
  await setKey(s.env, 'p1', 'sentry', SENTRY);
  const r = await testKey(s.env, 'p1', 'sentry');
  assert.equal(r.body.result, 'http_302');
  assert.equal(s.stub.calls.length, 1);
  assert.deepEqual(s.stub.unexpected, []);
});

test('X7 a batch throw after the vendor call is 503 with no ok, and last_test_* keeps its old value', async (t) => {
  const s = await store(t, {}, { [S_URL]: ok(200) }); if (!s) return;
  await setKey(s.env, 'p1', 'sentry', SENTRY);
  const DB = { prepare: (q) => s.env.DB.prepare(q), batch: async () => { throw new Error('D1 fixture batch failure sntryu_fixture0leak'); } };
  const errs = [];
  t.mock.method(console, 'error', (...a) => errs.push(a.join(' ')));
  const r = await testKey({ ...s.env, DB }, 'p1', 'sentry');
  assert.equal(r.status, 503, r.text);
  assert.equal('ok' in r.body, false);
  assert.equal(keyRows(s.db)[0].last_test_result, null);
  assert.ok(errs.length >= 1, 'the batch failure is logged');
  assert.ok(errs.every((e) => !e.includes('sntryu_fixture0leak') && !e.includes(S_TOKEN)), errs.join('\n'));
});

test('X8 test of a missing row is 404 with one refused:no_entry row and no vendor call', async (t) => {
  const s = await store(t); if (!s) return;
  const r = await testKey(s.env, 'p1', 'sentry');
  assert.equal(r.status, 404, r.text);
  assert.deepEqual(audits(s.db).map((x) => [x.action, x.outcome]), [['test', 'refused:no_entry']]);
  assert.equal(s.stub.calls.length, 0);
});

test('X9 a set after a test resets last_test_* to NULL', async (t) => {
  const s = await store(t, {}, { [S_URL]: ok(200) }); if (!s) return;
  await setKey(s.env, 'p1', 'sentry', SENTRY);
  await testKey(s.env, 'p1', 'sentry');
  assert.equal(keyRows(s.db)[0].last_test_result, 'ok');
  await setKey(s.env, 'p1', 'sentry', { ...SENTRY, token: 'sntrys_fixture0org0token' });
  const row = keyRows(s.db)[0];
  assert.deepEqual([row.last_test_at, row.last_test_status, row.last_test_result], [null, null, null]);
  assert.equal(n(s.db, 'signal_keys'), 1, 'the upsert replaces, never duplicates');
});

// ── CL1-CL2 ─────────────────────────────────────────────────────────────────
test('CL1 clear removes the row and writes exactly one clear ok audit row', async (t) => {
  const s = await store(t); if (!s) return;
  await setKey(s.env, 'p1', 'sentry', SENTRY);
  await setKey(s.env, 'p1', 'posthog', POSTHOG);
  const before = n(s.db, 'signal_key_audit');
  const r = await clearKey(s.env, 'p1', 'sentry');
  assert.equal(r.status, 200, r.text);
  assert.equal(r.body.cleared, true);
  assert.deepEqual(keyRows(s.db).map((x) => x.kind), ['posthog']);
  const a = audits(s.db).slice(before);
  assert.deepEqual(a.map((x) => [x.action, x.outcome, x.kind]), [['clear', 'ok', 'sentry']]);
});

test('CL2 clear of a missing row is 404 with one refused:no_entry row', async (t) => {
  const s = await store(t); if (!s) return;
  const r = await clearKey(s.env, 'p1', 'sentry');
  assert.equal(r.status, 404, r.text);
  assert.deepEqual(audits(s.db).map((x) => [x.action, x.outcome]), [['clear', 'refused:no_entry']]);
});

// ── R1-R12 ──────────────────────────────────────────────────────────────────
// [name, setup(s) -> body overrides (and token), status, why]
const R = [
  ['R1 no run row', () => ({ run_id: 999999 }), 403, 'no_run'],
  ['R2 a web-task run (not listed)', (s) => ({ run_id: run(s.db, { lane: 'web-task' }) }), 403, 'wrong_lane'],
  ['R3 a run released after its lease (queued)', (s) => ({ run_id: run(s.db, { status: 'queued' }) }), 403, 'not_claimed'],
  ['R4 claimed by another machine', (s) => ({ run_id: run(s.db, { claimed_by: 'm2' }) }), 403, 'not_claimer'],
  ['R5 an old token after a re-claim', (s) => { const id = run(s.db); s.db.prepare('UPDATE web_vault_run_token SET token_hash=? WHERE run_id=?').run(sha('fixture-new-token'), id); return { run_id: id }; }, 403, 'bad_token'],
  ['R6 lease expired', (s) => ({ run_id: run(s.db, { lease_until: iso(NOW_MS - 1000) }) }), 403, 'lease_expired'],
  ['R7 a run of p2 asks for p1', (s) => ({ run_id: run(s.db, { project: 'p2' }) }), 403, 'wrong_project'],
  ['R8 no entry for the kind', (s) => ({ run_id: run(s.db), kind: 'posthog' }), 404, 'no_entry'],
  ['R9 key missing on the worker', (s) => { s.env.WEB_VAULT_KEY_1 = undefined; return { run_id: run(s.db) }; }, 503, 'key_missing'],
  ['R10 a ciphertext copied from another project', (s) => {
    const p9 = s.db.prepare("SELECT ciphertext, iv FROM signal_keys WHERE project='p9'").get();
    s.db.prepare("UPDATE signal_keys SET ciphertext=?, iv=? WHERE project='p1' AND kind='sentry'").run(p9.ciphertext, p9.iv);
    return { run_id: run(s.db) };
  }, 503, 'decrypt_failed'],
  ['R11 no token header at all', (s) => ({ run_id: run(s.db), token: null }), 403, 'bad_token'],
  ['R12 ok: the claimer of a run of p1', (s) => ({ run_id: run(s.db) }), 200, 'ok'],
];
test('R1-R12 the lane read: first failing check wins, one audit row per outcome, the value only to the claimer', async (t) => {
  for (const [name, setup, status, why] of R) {
    await t.test(name, async (tt) => {
      const s = await store(tt); if (!s) return;
      setting(s.db, 'signal_keys.read_lanes', ' Sentry-Triage , bad lane!');
      await setKey(s.env, 'p1', 'sentry', SENTRY);
      await setKey(s.env, 'p9', 'sentry', { ...SENTRY, token: 'sntryu_fixture0other0project' });
      const before = n(s.db, 'signal_key_audit');
      const b = setup(s);
      const token = 'token' in b ? b.token : RUN_TOKEN;
      delete b.token;
      const r = await laneRead(s.env, b, token === null ? null : token);
      assert.equal(r.status, status, `${name}: ${r.text}`);
      const a = audits(s.db).slice(before);
      assert.equal(a.length, 1, `${name}: exactly one audit row`);
      assert.equal(a[0].action, 'read');
      assert.equal(a[0].actor, 'm1');
      if (why === 'ok') {
        assert.equal(a[0].outcome, 'ok');
        assert.equal(r.body.value, S_TOKEN);
        assert.deepEqual(r.body.fields, { org: 'fixture-org', project: 'fixture-proj' });
        assert.equal(r.body.kind, 'sentry');
        assert.equal(s.db.prepare("SELECT last_used_at FROM signal_keys WHERE project='p1' AND kind='sentry'").get().last_used_at, NOW);
      } else {
        assert.equal(r.body.why, why, name);
        assert.equal(a[0].outcome, `refused:${why}`);
        assert.equal('value' in r.body, false);
        assert.ok(noSecret(r.text), name);
        assert.equal(s.db.prepare("SELECT last_used_at FROM signal_keys WHERE project='p1' AND kind='sentry'").get().last_used_at, null, `${name}: not touched`);
      }
    });
  }
});

test('R13 a malformed read body is 400 and writes no audit row', async (t) => {
  const s = await store(t); if (!s) return;
  for (const b of [{ run_id: 'x' }, { run_id: 1, machine: '' }, { run_id: 1, kind: 'Bad Kind' }]) {
    assert.equal((await laneRead(s.env, b)).status, 400, JSON.stringify(b));
  }
  assert.equal(n(s.db, 'signal_key_audit'), 0);
});

test('R14 a read whose audit batch fails is 503 and sends no value (lane read and hub read)', async (t) => {
  const s = await store(t); if (!s) return;
  setting(s.db, 'signal_keys.read_lanes', 'sentry-triage');
  await setKey(s.env, 'p1', 'sentry', SENTRY);
  const DB = { prepare: (q) => s.env.DB.prepare(q), batch: async () => { throw new Error('D1 fixture batch failure'); } };
  t.mock.method(console, 'error', () => {});
  const env = { ...s.env, DB };
  const rd = await laneRead(env, { run_id: run(s.db) });
  assert.equal(rd.status, 503, rd.text);
  assert.equal('value' in rd.body, false);
  assert.ok(noSecret(rd.text));
  const hr = await hubRead(env, 'p1', 'sentry');
  assert.equal(hr.status, 503, hr.text);
  assert.ok(noSecret(hr.text));
  assert.equal(keyRows(s.db)[0].last_used_at, null);
});

// ── H1-H4 ───────────────────────────────────────────────────────────────────
test('H1 the hub read with the hub token answers {kind, fields, value}, one hub_read ok row, last_used_at set', async (t) => {
  const s = await store(t); if (!s) return;
  await setKey(s.env, 'p1', 'posthog', POSTHOG);
  const before = n(s.db, 'signal_key_audit');
  const r = await hubRead(s.env, 'p1', 'posthog');
  assert.equal(r.status, 200, r.text);
  assert.deepEqual([r.body.kind, r.body.value], ['posthog', P_KEY]);
  assert.deepEqual(r.body.fields, { host: 'https://us.posthog.com', project_id: '598179' });
  assert.deepEqual(audits(s.db).slice(before).map((x) => [x.action, x.outcome, x.actor]), [['hub_read', 'ok', 'hub']]);
  assert.equal(keyRows(s.db)[0].last_used_at, NOW);
});

test('H2 a wrong hub token is 403 with one refused:bad_hub_token row', async (t) => {
  const s = await store(t); if (!s) return;
  await setKey(s.env, 'p1', 'posthog', POSTHOG);
  const before = n(s.db, 'signal_key_audit');
  const r = await hubRead(s.env, 'p1', 'posthog', HUB + 'x');
  assert.equal(r.status, 403, r.text);
  assert.equal('value' in r.body, false);
  assert.deepEqual(audits(s.db).slice(before).map((x) => [x.action, x.outcome]), [['hub_read', 'refused:bad_hub_token']]);
  assert.equal(keyRows(s.db)[0].last_used_at, null);
});

test('H3 an unset worker hub token is 503 with one refused:hub_token_unset row', async (t) => {
  const s = await store(t, { ENVELOPE_HUB_TOKEN: '  ' }); if (!s) return;
  await setKey(s.env, 'p1', 'posthog', POSTHOG);
  const before = n(s.db, 'signal_key_audit');
  const r = await hubRead(s.env, 'p1', 'posthog', '');
  assert.equal(r.status, 503, r.text);
  assert.deepEqual(audits(s.db).slice(before).map((x) => x.outcome), ['refused:hub_token_unset']);
});

test('H4 the admin token alone does not read a value; no entry is 404', async (t) => {
  const s = await store(t); if (!s) return;
  await setKey(s.env, 'p1', 'posthog', POSTHOG);
  const r = await hubRead(s.env, 'p1', 'posthog', null, { admin: ADMIN });
  assert.equal(r.status, 403, r.text);
  assert.ok(noSecret(r.text));
  const none = await hubRead(s.env, 'p1', 'sentry');
  assert.equal(none.status, 404, none.text);
  assert.equal(audits(s.db).at(-1).outcome, 'refused:no_entry');
});

// ── M1-M3 ───────────────────────────────────────────────────────────────────
test('M1 maskTokens masks sntry?_ and ph?_ tokens', () => {
  assert.ok(MASK, 'src/lib/token-mask.js exists');
  assert.equal(MASK.maskTokens('x sntryu_abc123 y phx_DEF-456 z'), 'x sntryu_*** y phx_*** z');
  assert.equal(MASK.maskTokens('Bearer sntrys_eyJ0==/x+ and phc_abc'), 'Bearer sntrys_*** and phc_***');
});

test('M2 text with sntry and no underscore, or no token, is unchanged', () => {
  assert.ok(MASK, 'src/lib/token-mask.js exists');
  for (const s of ['the sntry word', 'sntryu without underscore', 'graph_x', 'php_ is not', 'ok']) {
    assert.equal(MASK.maskTokens(s), s);
  }
  assert.equal(MASK.maskTokens(undefined), '');
});

test('M3 through the worker, a probe error that carries a phx_ string logs only phx_***', async (t) => {
  const s = await store(t, {}, { [P_URL]: async () => { throw new Error(`connect failed for ${P_KEY}`); } }); if (!s) return;
  await setKey(s.env, 'p1', 'posthog', POSTHOG);
  const warns = [];
  t.mock.method(console, 'warn', (...a) => warns.push(a.join(' ')));
  const r = await testKey(s.env, 'p1', 'posthog');
  assert.equal(r.body.result, 'network');
  assert.ok(warns.length >= 1, 'the network error is logged');
  assert.ok(warns.some((w) => w.includes('phx_***')), warns.join('\n'));
  assert.ok(warns.every((w) => !w.includes(P_KEY)), warns.join('\n'));
});

// ── RT1-RT2 retention ───────────────────────────────────────────────────────
function oldAudits(db, k, days) {
  const ins = db.prepare("INSERT INTO signal_key_audit (at, action, outcome, project, kind, actor) VALUES (?, 'read', 'ok', 'p1', 'sentry', 'm1')");
  for (let i = 0; i < k; i++) ins.run(ago(days));
}
const ruleOf = (body) => (body.rules || []).find((x) => x.rule === 'signal_key_audit.age');

test('RT1 the rule exists; the seeded dry run counts 3 old rows and deletes none', async (t) => {
  const s = await store(t); if (!s) return;
  const rule = RULES.find((r) => r.rule === 'signal_key_audit.age');
  assert.ok(rule, 'rule signal_key_audit.age');
  assert.deepEqual([rule.table, rule.key, rule.def, rule.archive], ['signal_key_audit', 'retention.signal_key_audit.days', 90, 'signal_key_audit']);
  assert.equal(RULES.some((r) => r.table === 'signal_keys' || r.table === 'signal_key_kinds'), false);
  oldAudits(s.db, 3, 91);
  oldAudits(s.db, 2, 89);
  const r = await call(s.env, 'POST', '/api/retention/run', {});
  assert.equal(r.body.dry_run, true);
  const rr = ruleOf(r.body);
  assert.deepEqual({ counted: rr.counted, removed: rr.removed }, { counted: 3, removed: 0 });
  assert.equal(n(s.db, 'signal_key_audit'), 5);
});

test('RT2 dry_run 0 with the archive bound copies the 3 old rows, then deletes them', async (t) => {
  const s = await store(t); if (!s) return;
  const { DatabaseSync } = await import('node:sqlite');
  const adb = new DatabaseSync(':memory:');
  setting(s.db, 'retention.dry_run', '0');
  oldAudits(s.db, 3, 91);
  oldAudits(s.db, 2, 89);
  const rr = ruleOf((await call({ ...s.env, ARCHIVE: d1(adb) }, 'POST', '/api/retention/run', {})).body);
  assert.deepEqual({ removed: rr.removed, error: rr.error }, { removed: 3, error: null });
  assert.equal(n(s.db, 'signal_key_audit'), 2);
  assert.equal(Number(adb.prepare('SELECT COUNT(*) AS n FROM signal_key_audit').get().n), 3);
});

// ── RT-1 ────────────────────────────────────────────────────────────────────
test('RT-1 one stored row reads back the same through list, lane read, hub read and test', async (t) => {
  const s = await store(t, {}, { [P_URL]: ok(200) }); if (!s) return;
  setting(s.db, 'signal_keys.read_lanes', 'sentry-triage');
  assert.equal((await setKey(s.env, 'p1', 'posthog', POSTHOG)).status, 200);
  const want = { host: 'https://us.posthog.com', project_id: '598179' };
  assert.deepEqual((await list(s.env, '?project=p1')).body.rows[0].fields, want);
  const rd = await laneRead(s.env, { run_id: run(s.db), kind: 'posthog' });
  assert.deepEqual([rd.body.fields, rd.body.value], [want, P_KEY]);
  const hr = await hubRead(s.env, 'p1', 'posthog');
  assert.deepEqual([hr.body.fields, hr.body.value], [want, P_KEY]);
  assert.equal((await testKey(s.env, 'p1', 'posthog')).body.result, 'ok');
  assert.equal(new Headers(s.stub.calls[0].init.headers).get('authorization'), `Bearer ${P_KEY}`);
  assert.equal((await list(s.env, '?project=p1')).body.rows[0].last_test_result, 'ok');
});

// ── E1 ──────────────────────────────────────────────────────────────────────
test('E1 at 2,000 key rows and 50,000 audit rows the hot reads plan on an index', async (t) => {
  const s = await store(t, {}, { [S_URL]: ok(200) }); if (!s) return;
  s.db.exec('BEGIN');
  const k = s.db.prepare(`INSERT INTO signal_keys (project, kind, fields_json, ciphertext, iv, key_id, created_at, updated_at, updated_by)
                          VALUES (?, ?, '{}', 'Y3Q=', 'aXY=', 1, ?, ?, 'operator')`);
  for (let i = 0; i < 2000; i++) k.run(`vol${i}`, i % 2 ? 'sentry' : 'posthog', ago(i % 200), ago(i % 200));
  const a = s.db.prepare("INSERT INTO signal_key_audit (at, action, outcome, project, kind, actor) VALUES (?, 'read', 'ok', ?, 'sentry', 'm1')");
  for (let i = 0; i < 50000; i++) a.run(ago(i % 200), `vol${i % 2000}`);
  s.db.exec('COMMIT');
  s.db.exec('ANALYZE');
  const log = [];
  const env = { ...s.env, DB: capturingD1(s.db, log) };
  setting(s.db, 'signal_keys.read_lanes', 'sentry-triage');
  assert.equal((await setKey(env, 'p1', 'sentry', SENTRY)).status, 200);
  assert.equal((await list(env, '?project=p1')).status, 200);
  assert.equal((await list(env)).status, 200);
  assert.equal((await laneRead(env, { run_id: run(s.db) })).status, 200);
  assert.equal((await hubRead(env, 'p1', 'sentry')).status, 200);
  assert.equal((await testKey(env, 'p1', 'sentry')).status, 200);
  assert.equal((await clearKey(env, 'p1', 'sentry')).status, 200);
  const hot = log.filter((x) => /\bsignal_key(s|_audit)\b/.test(x.sql));
  assert.ok(hot.length >= 6, `captured ${hot.length} reads`);
  assert.ok(hot.some((x) => /WHERE project=\?1 ORDER BY kind/.test(x.sql)), 'the project list');
  assert.ok(hot.some((x) => /ORDER BY project, kind/.test(x.sql)), 'the fleet list');
  const rule = RULES.find((r) => r.rule === 'signal_key_audit.age');
  assert.ok(rule, 'the retention rule exists');
  hot.push({ sql: rule.ids, binds: [ago(90), 500] });
  assert.ok(ROUTE && ROUTE.UPSERT_SQL, 'the route exports UPSERT_SQL');
  for (const { sql, binds } of hot) {
    const lines = plan(s.db, sql, ...binds.map((b) => (b === undefined ? null : b)));
    assert.deepEqual(fullScans(lines, ['signal_keys', 'signal_key_audit']), [], `${sql}\n${lines.join('\n')}`);
    assert.ok(lines.some((l) => /USING (COVERING )?INDEX (uq_signal_keys_entry|idx_signal_key_audit_\w+)|USING INTEGER PRIMARY KEY/.test(l)), `${sql}\n${lines.join('\n')}`);
  }
});

// ── P1-P10 ──────────────────────────────────────────────────────────────────
// The key-shaped values are built at run time, never spelled: a spelled one is
// a gitleaks generic-api-key hit that refuses the share mirror (BH-795).
const fx = (prefix, rest) => `${prefix}_${rest}`;
const P = [
  ['P1 sntryu_', 'sentry', { token: fx('sntryu', 'fixture0a1') }, 200],
  ['P2 sntrys_', 'sentry', { token: fx('sntrys', 'fixture0b2==') }, 200],
  ['P3 phx_ with a trailing \\r\\n and leading spaces', 'posthog', { key: `  ${fx('phx', 'fixture0c3')}\r\n` }, 200],
  ['P4 sntryU_ (case)', 'sentry', { token: fx('sntryU', 'fixture0d4') }, 400],
  ['P5 sntry_ (no letter)', 'sentry', { token: 'sntry_fixture0e5' }, 400],
  ['P6 phx with no underscore', 'posthog', { key: 'phxfixture0f6' }, 400],
  ['P7 phc_ (a project API key)', 'posthog', { key: fx('phc', 'fixture0g7') }, 400],
  ['P8 a pasted header', 'posthog', { key: 'Bearer phx_fixture0h8' }, 400],
  ['P9 empty after the trim', 'sentry', { token: ' \r\n\t ' }, 400],
  ['P10 a space inside the key', 'posthog', { key: 'phx_fixture 0j10' }, 400],
];
test('P1-P10 the secret prefix check', async (t) => {
  const s = await store(t); if (!s) return;
  for (const [name, kind, over, status] of P) {
    const base = kind === 'sentry' ? SENTRY : POSTHOG;
    const r = await setKey(s.env, `p-${name.split(' ')[0]}`, kind, { ...base, ...over });
    assert.equal(r.status, status, `${name}: ${r.text}`);
    if (status === 400) assert.equal(r.body.field, kind === 'sentry' ? 'token' : 'key', name);
  }
  assert.equal(n(s.db, 'signal_keys'), 3);
});

// ── U1-U9 ───────────────────────────────────────────────────────────────────
const PH_KIND = { test_template: '{host}/api/projects/{project_id}/', host_field: 'host', host_allow: 'us.posthog.com,eu.posthog.com,app.posthog.com' };
const U = [
  ['U1 us', 'https://us.posthog.com', 'https://us.posthog.com/api/projects/7/'],
  ['U2 eu', 'https://eu.posthog.com', 'https://eu.posthog.com/api/projects/7/'],
  ['U3 case and a trailing slash', 'https://US.PostHog.com/', 'https://us.posthog.com/api/projects/7/'],
  ['U4 http', 'http://us.posthog.com', null],
  ['U5 a suffix host', 'https://us.posthog.com.evil.test', null],
  ['U6 the host in the path', 'https://evil.test/us.posthog.com', null],
  ['U7 userinfo', 'https://user@us.posthog.com', null],
  ['U8 a port', 'https://us.posthog.com:8443', null],
  ['U9 an IP', 'https://192.0.2.1', null],
];
test('U1-U9 probeUrl fills the template and keeps the host on the allow list', () => {
  assert.ok(PROBE, 'src/lib/signal-probe.js exists');
  for (const [name, host, want] of U) {
    const r = PROBE.probeUrl(PH_KIND, { host, project_id: '7' });
    if (want) assert.deepEqual([r.ok, r.url], [true, want], name);
    else assert.equal(r.ok, false, name);
  }
  const sentry = PROBE.probeUrl({ test_template: 'https://sentry.io/api/0/organizations/{org}/projects/', host_field: null, host_allow: 'sentry.io' }, { org: 'a/b?c' });
  assert.equal(sentry.url, 'https://sentry.io/api/0/organizations/a%2Fb%3Fc/projects/', 'each field is URL-encoded');
});

test('U10 classify and reasonOf map each result class', () => {
  assert.ok(PROBE, 'src/lib/signal-probe.js exists');
  assert.equal(PROBE.classify(200), 'ok');
  assert.equal(PROBE.classify(204), 'ok');
  assert.equal(PROBE.classify(403), 'http_403');
  assert.equal(PROBE.classify(Object.assign(new Error('x'), { name: 'AbortError' })), 'timeout');
  assert.equal(PROBE.classify(new TypeError('x')), 'network');
  assert.equal(PROBE.reasonOf('http_403'), 'the key lacks a scope');
  assert.equal(PROBE.reasonOf('http_404'), 'check the organization or project');
  assert.equal(PROBE.reasonOf('http_429'), 'rate limited, try again later');
  assert.equal(PROBE.reasonOf('http_503'), 'the vendor failed');
});

// ── B1 ──────────────────────────────────────────────────────────────────────
test('B1 a whole flow calls only the two expected vendor URLs', async (t) => {
  const s = await store(t, {}, { [S_URL]: ok(200), [P_URL]: ok(401) }); if (!s) return;
  await setKey(s.env, 'p1', 'sentry', SENTRY);
  await setKey(s.env, 'p1', 'posthog', POSTHOG);
  await list(s.env);
  await testKey(s.env, 'p1', 'sentry');
  await testKey(s.env, 'p1', 'posthog');
  await hubRead(s.env, 'p1', 'sentry');
  await clearKey(s.env, 'p1', 'sentry');
  await testKey(s.env, 'p1', 'sentry');
  assert.deepEqual(s.stub.calls.map((c) => c.url), [S_URL, P_URL]);
  assert.deepEqual(s.stub.unexpected, []);
});
