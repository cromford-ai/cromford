// BH-7964 (BH-7937.0): the one-time secret envelope. POST stores a ciphertext,
// GET (main bearer AND the hub token) reads it once and deletes the row.
// Driven through the REAL worker.fetch on node:sqlite with the composed jobs
// schema. Each case opens its own database.
//   K1 tables, indexes, seeds     E1 POST stores, no key in the module
//   E2 one stored event, none on a 400      E3 scope table   E4 ciphertext table
//   E5 hub-token gate refuses     E6 hub token unset / blank / trailing newline
//   E7 read once, then 404        E8 /status and /confirm do not match
//   E9 expiry                     E10 event detail cap      E11 EXPLAIN at 5,000 rows
//   E12 TTL settings row          E13 the sibling seams are empty
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import { plan, fullScans } from './lib/d1-volume.bh-6727.js';

const SECRET = 'tok-fixture-bh7964-main';
const HUB = 'tok-fixture-bh7964-hub';
const MOD_PATH = fileURLToPath(new URL('../src/routes/secret-envelopes.js', import.meta.url));
const MOD = await import('../src/routes/secret-envelopes.js').catch(() => ({}));
// 256 fixed bytes, the size an RSA-OAEP-2048 seal makes: 344 base64 chars.
const bytes = (n, k) => Buffer.from(Array.from({ length: n }, (_, i) => (i * 37 + k) & 255));
const CT = bytes(256, 11).toString('base64');
const CT_1024 = bytes(768, 5).toString('base64');
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const iso = (ms) => new Date(ms).toISOString().replace(/\.\d{3}Z$/, 'Z');
// The clock is pinned (D60): fresh() mocks Date at NOW_MS, so the worker's
// request time and every expires_at below are exact.
const NOW_MS = Date.parse('2026-10-22T04:00:00Z');

async function fresh(t) {
  const o = await openDb();
  if (!o) { t.skip('node:sqlite unavailable'); return null; }
  t.mock.timers.enable({ apis: ['Date'], now: NOW_MS });
  return o;
}
// env: what the worker sees; `hub` undefined leaves ENVELOPE_HUB_TOKEN unset.
function call(DB, method, path, { auth = `Bearer ${SECRET}`, hubHeader, body, env = { ENVELOPE_HUB_TOKEN: HUB } } = {}) {
  const headers = { 'content-type': 'application/json' };
  if (auth) headers.authorization = auth;
  if (hubHeader !== undefined) headers['x-envelope-hub-token'] = hubHeader;
  const init = { method, headers };
  if (method !== 'GET') init.body = JSON.stringify(body ?? {});
  return worker.fetch(new Request(`https://jobs.test${path}`, init), { DB, HARNESS_SECRET: SECRET, ...env })
    .then(async (res) => ({ status: res.status, headers: res.headers, body: await res.json().catch(() => null) }));
}
const post = (DB, body, opts) => call(DB, 'POST', '/api/secrets/envelope', { body, ...opts });
const read = (DB, id, opts) => call(DB, 'GET', `/api/secrets/envelope/${id}`, { hubHeader: HUB, ...opts });
const rows = (db, id) => db.prepare('SELECT COUNT(*) AS n FROM secret_envelopes WHERE id=?').get(id).n;
const events = (db, id) => db.prepare('SELECT event FROM secret_envelope_events WHERE envelope_id=? ORDER BY id').all(id).map((r) => r.event);
const allEvents = (db) => db.prepare('SELECT COUNT(*) AS n FROM secret_envelope_events').get().n;
const setting = (db, key, value) => db.prepare(
  "INSERT INTO settings (key,value,note,actor,updated_at) VALUES (?,?,'fixture','fixture','2026-10-22T00:00:00Z') ON CONFLICT(key) DO UPDATE SET value=excluded.value"
).run(key, String(value));
function seedRow(db, id, expiresAt, scope = 'ai-account:openai.default') {
  db.prepare('INSERT INTO secret_envelopes (id, scope, ciphertext, created_at, expires_at) VALUES (?,?,?,?,?)')
    .run(id, scope, CT, '2026-10-22T00:00:00Z', expiresAt);
}
async function capture(fn) {
  const lines = []; const keep = {};
  for (const k of ['log', 'info', 'warn', 'error', 'debug']) { keep[k] = console[k]; console[k] = (...a) => lines.push(a.map(String).join(' ')); }
  try { await fn(); } finally { Object.assign(console, keep); }
  return lines;
}

test('K1 the schema has both tables, the three indexes and the two settings rows', async (t) => {
  const o = await fresh(t); if (!o) return;
  const ix = (tbl) => o.db.prepare(`SELECT name FROM pragma_index_list('${tbl}')`).all().map((r) => r.name);
  const cols = (n) => o.db.prepare(`SELECT name FROM pragma_index_info('${n}') ORDER BY seqno`).all().map((r) => r.name);
  assert.ok(ix('secret_envelopes').includes('ix_secret_envelopes_expires'));
  assert.deepEqual(cols('ix_secret_envelopes_expires'), ['expires_at']);
  assert.ok(ix('secret_envelope_events').includes('ix_secret_envelope_events_env'));
  assert.deepEqual(cols('ix_secret_envelope_events_env'), ['envelope_id']);
  assert.ok(ix('secret_envelope_events').includes('ix_secret_envelope_events_at'));
  assert.deepEqual(cols('ix_secret_envelope_events_at'), ['at']);
  const s = (k) => o.db.prepare('SELECT value FROM settings WHERE key=?').get(k)?.value;
  assert.equal(s('secret_envelope_ttl_s'), '900');
  assert.equal(s('hub_envelope_public_key'), '');
});

test('E1 POST stores the posted ciphertext; expires_at = request time + 900 s; the module holds no key', async (t) => {
  const o = await fresh(t); if (!o) return;
  const r = await post(o.DB, { scope: 'ai-account:openai.default', ciphertext: CT });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.match(r.body.id, UUID_RE);
  assert.equal(r.headers.get('cache-control'), 'no-store');
  const row = o.db.prepare('SELECT scope, ciphertext, created_at, expires_at FROM secret_envelopes WHERE id=?').get(r.body.id);
  assert.equal(row.ciphertext, CT);
  assert.equal(row.scope, 'ai-account:openai.default');
  assert.equal(row.expires_at, r.body.expires_at);
  assert.equal(row.created_at, iso(NOW_MS));
  assert.equal(r.body.expires_at, iso(NOW_MS + 900e3));
  assert.equal(JSON.stringify(r.body).includes(CT), false, 'POST never echoes the ciphertext');
  // No export is key material, and the source names no decrypt or private key.
  assert.ok(Object.keys(MOD).length > 0, 'secret-envelopes.js did not load');
  for (const [k, v] of Object.entries(MOD)) {
    assert.equal(typeof v === 'string' && /PRIVATE KEY/.test(v), false, `export ${k}`);
    assert.equal(typeof CryptoKey !== 'undefined' && v instanceof CryptoKey, false, `export ${k}`);
  }
  const src = readFileSync(MOD_PATH, 'utf8');
  assert.ok(src.includes('export const routes'), 'the source scan read the real module');
  for (const bad of ['decrypt(', 'importKey(', 'PRIVATE KEY']) assert.equal(src.includes(bad), false, bad);
});

test('E2 a 200 writes one stored event; a 400 writes no row and no event', async (t) => {
  const o = await fresh(t); if (!o) return;
  const bad = await post(o.DB, { scope: 'AI-ACCOUNT:x', ciphertext: CT });
  assert.equal(bad.status, 400);
  assert.equal(o.db.prepare('SELECT COUNT(*) AS n FROM secret_envelopes').get().n, 0);
  assert.equal(allEvents(o.db), 0);
  const r = await post(o.DB, { scope: 'tracker:linear:acme@x', ciphertext: CT });
  assert.equal(r.status, 200);
  assert.deepEqual(events(o.db, r.body.id), ['stored']);
  const ev = o.db.prepare('SELECT scope, detail FROM secret_envelope_events WHERE envelope_id=?').get(r.body.id);
  assert.equal(ev.scope, 'tracker:linear:acme@x');
  assert.equal(String(ev.detail ?? '').includes(CT), false);
  assert.equal(allEvents(o.db), 1);
});

test('E3 the scope decision table', async (t) => {
  const o = await fresh(t); if (!o) return;
  const ok = ['ai-account:openai.default', 'tracker:linear:acme@x', 'ai-account:a', 'ai-account:' + 'a'.repeat(96)];
  const refuse = ['ai-account:', 'AI-ACCOUNT:x', 'ai-account:x/../y', 'ai-account:a..b', 'ai-accounts:x',
    'ai-account:' + 'a'.repeat(97), 'a'.repeat(200), 42, null, undefined, ' ai-account:x', 'ai-account:x '];
  for (const scope of ok) {
    assert.equal(MOD.checkEnvelopeScope?.(scope), true, `helper accepts ${scope}`);
    assert.equal((await post(o.DB, { scope, ciphertext: CT })).status, 200, `POST accepts ${scope}`);
  }
  for (const scope of refuse) {
    assert.equal(MOD.checkEnvelopeScope?.(scope), false, `helper refuses ${JSON.stringify(scope)}`);
    const r = await post(o.DB, { scope, ciphertext: CT });
    assert.equal(r.status, 400, `POST refuses ${JSON.stringify(scope)}`);
  }
  assert.equal(o.db.prepare('SELECT COUNT(*) AS n FROM secret_envelopes').get().n, ok.length);
});

test('E4 the ciphertext decision table', async (t) => {
  const o = await fresh(t); if (!o) return;
  assert.equal(CT.length, 344); assert.equal(CT_1024.length, 1024);
  const scope = 'ai-account:openai.default';
  for (const ct of [CT, CT_1024]) assert.equal((await post(o.DB, { scope, ciphertext: ct })).status, 200, `len ${ct.length}`);
  const urlish = CT.slice(0, 10) + '-' + CT.slice(11, 20) + '_' + CT.slice(21);
  const refuse = {
    '343 chars': CT.slice(0, 343),
    '340 chars (a multiple of 4)': CT.slice(0, 340),
    '1025 chars': CT_1024 + 'A',
    '1028 chars (a multiple of 4)': CT_1024 + 'AAAA',
    'base64url': urlish,
    'a space': CT.slice(0, 10) + ' ' + CT.slice(11),
    'a newline': CT.slice(0, 10) + '\n' + CT.slice(11),
    'length not a multiple of 4': CT.slice(0, 342) + 'AAA',
    '=== padding': CT.slice(0, 341) + '===',
    'a number': 42, 'null': null, 'an array': [CT],
  };
  for (const [why, ct] of Object.entries(refuse)) {
    assert.equal((await post(o.DB, { scope, ciphertext: ct })).status, 400, why);
  }
  assert.equal(o.db.prepare('SELECT COUNT(*) AS n FROM secret_envelopes').get().n, 2);
});

test('E5 the hub-token gate refuses; the row stays', async (t) => {
  const o = await fresh(t); if (!o) return;
  const { body: { id } } = await post(o.DB, { scope: 'ai-account:openai.default', ciphertext: CT });
  const cases = {
    'main bearer only': { hubHeader: undefined },
    'one char changed': { hubHeader: HUB.slice(0, -1) + 'X' },
    'a prefix of the token': { hubHeader: HUB.slice(0, 8) },
    'the token plus a char': { hubHeader: HUB + 'x' },
    'an empty header': { hubHeader: '' },
    'token in Authorization': { hubHeader: undefined, auth: `Bearer ${HUB}` },
  };
  for (const [why, opts] of Object.entries(cases)) {
    const r = await read(o.DB, id, opts);
    const want = why === 'token in Authorization' ? 401 : 403;
    assert.equal(r.status, want, why);
    assert.equal(JSON.stringify(r.body).includes(CT), false, why);
    assert.equal(rows(o.db, id), 1, `${why}: the row stays`);
  }
  const noBearer = await read(o.DB, id, { auth: null });
  assert.equal(noBearer.status, 401);
  assert.equal(rows(o.db, id), 1);
  assert.equal(MOD.hubTokenOk?.(new Request('https://x', { headers: { 'x-envelope-hub-token': HUB } }), { ENVELOPE_HUB_TOKEN: HUB }), true);
  assert.equal(MOD.hubTokenOk?.(new Request('https://x', { headers: { 'x-envelope-hub-token': HUB.slice(0, -1) + 'X' } }), { ENVELOPE_HUB_TOKEN: HUB }), false);
  // A NUL suffix pads to the same bytes without the length fold; a real
  // Request refuses NUL in a header, so a stub request drives the helper.
  const stub = (v) => ({ headers: { get: (k) => (k === 'x-envelope-hub-token' ? v : null) } });
  assert.equal(MOD.hubTokenOk?.(stub(`${HUB}\u0000`), { ENVELOPE_HUB_TOKEN: HUB }), false, 'a NUL suffix');
  assert.equal(MOD.hubTokenOk?.(stub(HUB), { ENVELOPE_HUB_TOKEN: `${HUB}\u0000` }), false, 'a NUL suffix in env');
  assert.deepEqual(events(o.db, id), ['stored']);
});

test('E6 hub token unset or blank: 503; a trailing newline in env and a trailing space in the header are accepted', async (t) => {
  const o = await fresh(t); if (!o) return;
  const { body: { id } } = await post(o.DB, { scope: 'ai-account:openai.default', ciphertext: CT });
  for (const env of [{}, { ENVELOPE_HUB_TOKEN: '' }, { ENVELOPE_HUB_TOKEN: '   ' }, { ENVELOPE_HUB_TOKEN: '\n' }]) {
    for (const hubHeader of [HUB, '', '   ']) {
      const r = await read(o.DB, id, { env, hubHeader });
      assert.equal(r.status, 503, `${JSON.stringify(env)} header ${JSON.stringify(hubHeader)}`);
      assert.equal(r.body.error, 'envelope read not configured');
    }
  }
  assert.equal(MOD.hubTokenOk?.(new Request('https://x', { headers: { 'x-envelope-hub-token': '' } }), {}), false);
  assert.equal(rows(o.db, id), 1);
  const r = await read(o.DB, id, { env: { ENVELOPE_HUB_TOKEN: `${HUB}\n` }, hubHeader: `${HUB} ` });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.ciphertext, CT);
});

test('E7 observable outcome: read once returns the ciphertext and deletes it; a second read is 404', async (t) => {
  const o = await fresh(t); if (!o) return;
  let p, a, b;
  const lines = await capture(async () => {
    p = await post(o.DB, { scope: 'ai-account:openai.default', ciphertext: CT });
    a = await read(o.DB, p.body.id);
    b = await read(o.DB, p.body.id);
  });
  assert.equal(p.status, 200);
  assert.equal(a.status, 200, JSON.stringify(a.body));
  assert.equal(a.body.ciphertext, CT);
  assert.equal(a.body.id, p.body.id);
  assert.equal(a.body.scope, 'ai-account:openai.default');
  assert.equal(a.headers.get('cache-control'), 'no-store');
  assert.equal(rows(o.db, p.body.id), 0);
  assert.equal(b.status, 404);
  assert.equal(b.body.error, 'no envelope');
  assert.deepEqual(events(o.db, p.body.id), ['stored', 'consumed']);
  for (const l of lines) {
    assert.equal(l.includes(CT.slice(0, 40)), false, 'a log line holds the ciphertext');
    assert.equal(l.includes(HUB), false, 'a log line holds the hub token');
  }
});

test('E8 /:id/status and /:id/confirm do not reach the read; a bad id is 404 with no write', async (t) => {
  const o = await fresh(t); if (!o) return;
  const { body: { id } } = await post(o.DB, { scope: 'ai-account:openai.default', ciphertext: CT });
  // TEST-CHANGE (BH-7966): GET /:id/status is now the BH-7966 status route
  // (src/routes/ai-accounts.js), the owner this seam named. The premise kept:
  // neither path reaches the read, so the row stays and no event is written.
  const st = await call(o.DB, 'GET', `/api/secrets/envelope/${id}/status`, { hubHeader: HUB });
  assert.equal(st.status, 200, 'status');
  assert.deepEqual(Object.keys(st.body), ['state'], 'status: no ciphertext, no scope');
  assert.equal(rows(o.db, id), 1, 'status: the row stays');
  const cf = await call(o.DB, 'GET', `/api/secrets/envelope/${id}/confirm`, { hubHeader: HUB });
  assert.equal(cf.status, 404, 'confirm');
  assert.equal(cf.body.error, 'unknown endpoint', 'confirm');
  assert.equal(rows(o.db, id), 1, 'confirm: the row stays');
  for (const bad of ['not-a-uuid', id.toUpperCase() + 'x', "x'%20OR%201=1"]) {
    const r = await read(o.DB, bad);
    assert.equal(r.status, 404, bad); assert.equal(r.body.error, 'no envelope', bad);
  }
  assert.equal(rows(o.db, id), 1);
  assert.deepEqual(events(o.db, id), ['stored']);
  assert.equal(allEvents(o.db), 1);
});

test('E9 an expired row is 404 and deleted with one expired event; an unexpired row is 200', async (t) => {
  const o = await fresh(t); if (!o) return;
  const past = crypto.randomUUID();
  const edge = crypto.randomUUID();
  const future = crypto.randomUUID();
  seedRow(o.db, past, iso(NOW_MS - 5e3));
  seedRow(o.db, future, iso(NOW_MS + 60e3));
  seedRow(o.db, edge, iso(NOW_MS));
  for (const id of [past, edge]) {
    const r = await read(o.DB, id);
    assert.equal(r.status, 404, id);
    assert.equal(r.body.error, 'no envelope');
    assert.equal(JSON.stringify(r.body).includes(CT), false);
    assert.equal(rows(o.db, id), 0, `${id} is deleted`);
    assert.deepEqual(events(o.db, id), ['expired']);
  }
  const r = await read(o.DB, future);
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.ciphertext, CT);
  assert.deepEqual(events(o.db, future), ['consumed']);
});

test('E10 envelopeEvent caps detail at 200 chars and keeps a null detail null', async (t) => {
  const o = await fresh(t); if (!o) return;
  assert.equal(typeof MOD.envelopeEvent, 'function');
  await MOD.envelopeEvent(o.DB, 'env-fixture-1', 'ai-account:a', 'stored', 'x'.repeat(500));
  await MOD.envelopeEvent(o.DB, 'env-fixture-2', 'ai-account:a', 'stored', null);
  const got = o.db.prepare('SELECT envelope_id, scope, event, detail, at FROM secret_envelope_events ORDER BY id').all();
  assert.equal(got.length, 2);
  assert.equal(got[0].detail.length, 200);
  assert.equal(got[0].event, 'stored');
  assert.equal(got[0].scope, 'ai-account:a');
  assert.match(got[0].at, /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$/);
  assert.equal(got[1].detail, null);
});

test('E11 ENVELOPE_EXPIRED_SQL uses ix_secret_envelopes_expires at 5,000 rows and reads what POST wrote', async (t) => {
  const o = await fresh(t); if (!o) return;
  assert.equal(typeof MOD.ENVELOPE_EXPIRED_SQL, 'string');
  const posted = [];
  for (let i = 0; i < 3; i++) posted.push((await post(o.DB, { scope: `ai-account:a${i}`, ciphertext: CT })).body.id);
  const ins = o.db.prepare('INSERT INTO secret_envelopes (id, scope, ciphertext, created_at, expires_at) VALUES (?,?,?,?,?)');
  o.db.exec('BEGIN');
  for (let i = 0; i < 5000; i++) ins.run(`vol-fixture-${i}`, 'ai-account:v', CT, '2026-10-01T00:00:00Z', iso(Date.parse('2026-10-01T00:00:00Z') + i * 60e3));
  o.db.exec('COMMIT');
  const lines = plan(o.db, MOD.ENVELOPE_EXPIRED_SQL, '2026-10-02T00:00:00Z', 100);
  assert.ok(lines.some((l) => l.includes('ix_secret_envelopes_expires')), lines.join(' | '));
  assert.deepEqual(fullScans(lines, ['secret_envelopes']), []);
  assert.equal(lines.some((l) => /TEMP B-TREE/.test(l)), false, lines.join(' | '));
  // A bound far in the future returns the rows POST wrote: the ISO format sorts.
  const ids = o.db.prepare(MOD.ENVELOPE_EXPIRED_SQL).all('2099-01-01T00:00:00Z', 6000).map((r) => r.id);
  for (const id of posted) assert.ok(ids.includes(id), id);
  assert.equal(o.db.prepare(MOD.ENVELOPE_EXPIRED_SQL).all('2026-10-01T00:10:00Z', 100).length, 10);
});

test('E12 the TTL settings row: a bad value uses 900, 120 is used', async (t) => {
  const o = await fresh(t); if (!o) return;
  for (const [value, want] of [['abc', 900], ['0', 900], ['-5', 900], ['59', 900], ['86401', 900], ['1.5', 900], ['', 900], ['120', 120], ['86400', 86400]]) {
    setting(o.db, 'secret_envelope_ttl_s', value);
    const r = await post(o.DB, { scope: 'ai-account:a', ciphertext: CT });
    assert.equal(r.status, 200, `${value}: ${JSON.stringify(r.body)}`);
    assert.equal(r.body.expires_at, iso(NOW_MS + want * 1e3), `ttl ${JSON.stringify(value)}`);
  }
  o.db.prepare("DELETE FROM settings WHERE key='secret_envelope_ttl_s'").run();
  const r = await post(o.DB, { scope: 'ai-account:a', ciphertext: CT });
  assert.equal(r.body.expires_at, iso(NOW_MS + 900e3), 'no row: 900');
});

test('E13 the sibling seams load and are empty', async () => {
  const apply = await import('../src/routes/secret-envelope-apply.js');
  const ai = await import('../src/routes/ai-accounts.js');
  assert.deepEqual(apply.routes, []);
  // TEST-CHANGE (BH-7966): the seam's named owner filled ai-accounts.js; its
  // routes are pinned by test/ai-accounts.bh-7966.test.js and route-table.d.
  assert.ok(Array.isArray(ai.routes));
});
