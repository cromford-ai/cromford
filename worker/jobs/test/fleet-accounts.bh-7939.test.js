// BH-7976 (BH-7939.2, slice C0): POST /api/fleet/accounts/telegram and the
// `fleet:` envelope scope grammar. Driven through the REAL worker.fetch on
// node:sqlite with the composed jobs schema. Each case opens its own database.
//   A1 401 without the bearer, no row
//   A2 every refused body is 400, stores nothing, never echoes the token
//   A3 a fleet:telegram envelope is 200, two settings rows, idempotent
//   A4 unknown, wrong-scope and dead envelopes are 400, no row
//   A5 the shared scope table: checkEnvelopeScope and POST /api/secrets/envelope agree
//   A6 EXPLAIN QUERY PLAN of the two reads at 20,000 events: index, no full scan
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import { plan, fullScans } from './lib/d1-volume.bh-6727.js';

const SECRET = 'tok-fixture-bh7976-main';
const PATH = '/api/fleet/accounts/telegram';
const ENV_MOD = await import('../src/routes/secret-envelopes.js');
const MOD = await import('../src/routes/fleet-accounts.js').catch(() => ({}));
const bytes = (n, k) => Buffer.from(Array.from({ length: n }, (_, i) => (i * 37 + k) & 255));
const CT = bytes(256, 11).toString('base64');
const iso = (ms) => new Date(ms).toISOString().replace(/\.\d{3}Z$/, 'Z');
const NOW_MS = Date.parse('2026-10-24T12:00:00Z');
const TOKEN = '123456:tok-fixture-bh7976-telegram';

// The one scope table both parsers read (tests/fixtures/fleet-scopes.bh-7939.tsv).
const SCOPES = readFileSync(new URL('../../../tests/fixtures/fleet-scopes.bh-7939.tsv', import.meta.url), 'utf8')
  .split('\n').filter((l) => l !== '' && !l.startsWith('#')).map((l) => l.split('\t'));

async function fresh(t) {
  const o = await openDb();
  if (!o) { t.skip('node:sqlite unavailable'); return null; }
  t.mock.timers.enable({ apis: ['Date'], now: NOW_MS });
  return o;
}
function call(DB, method, path, { auth = `Bearer ${SECRET}`, body, raw } = {}) {
  const headers = { 'content-type': 'application/json' };
  if (auth) headers.authorization = auth;
  const init = { method, headers };
  if (method !== 'GET') init.body = raw !== undefined ? raw : JSON.stringify(body ?? {});
  return worker.fetch(new Request(`https://jobs.test${path}`, init), { DB, HARNESS_SECRET: SECRET })
    .then(async (res) => {
      const text = await res.text();
      let json = null; try { json = JSON.parse(text); } catch { /* not json */ }
      return { status: res.status, headers: res.headers, text, body: json };
    });
}
const store = (DB, scope) => call(DB, 'POST', '/api/secrets/envelope', { body: { scope, ciphertext: CT } });
const tgRows = (db) => db.prepare("SELECT key, value, actor FROM settings WHERE key LIKE 'telegram.%' ORDER BY key").all();
const envelopes = (db) => db.prepare('SELECT COUNT(*) AS n FROM secret_envelopes').get().n;
const addEvent = (db, id, event, scope = 'fleet:telegram') => db.prepare(
  'INSERT INTO secret_envelope_events (envelope_id, scope, event, detail, at) VALUES (?,?,?,NULL,?)',
).run(id, scope, event, iso(NOW_MS));

test('A1 the route is bearer-gated: no bearer and a wrong bearer are 401, nothing stored', async (t) => {
  const o = await fresh(t); if (!o) return;
  const id = (await store(o.DB, 'fleet:telegram')).body.id;
  for (const auth of [null, 'Bearer tok-fixture-wrong']) {
    const r = await call(o.DB, 'POST', PATH, { auth, body: { envelope_id: id } });
    assert.equal(r.status, 401, `auth ${auth}`);
  }
  assert.deepEqual(tgRows(o.db), []);
  // The same id with the bearer is 200: the 401 above was the gate, not the body.
  assert.equal((await call(o.DB, 'POST', PATH, { body: { envelope_id: id } })).status, 200);
});

test('A2 a refused body is 400, stores nothing and never repeats the token', async (t) => {
  const o = await fresh(t); if (!o) return;
  const id = (await store(o.DB, 'fleet:telegram')).body.id;
  const before = envelopes(o.db);
  const refuse = [
    ['{}', {}],
    ['[]', []],
    ['a string', 'x'],
    ['null', null],
    ['token empty', { envelope_id: id, token: '' }],
    ['bot_token null', { envelope_id: id, bot_token: null }],
    ['bot_token only', { bot_token: TOKEN }],
    ['token with id', { envelope_id: id, token: TOKEN }],
    ['bot_token with id', { envelope_id: id, bot_token: TOKEN }],
    ['extra key', { envelope_id: id, note: 'x' }],
    ['upper-case uuid', { envelope_id: id.toUpperCase() }],
    ['uuid with a space', { envelope_id: `${id} ` }],
    ['uuid a number', { envelope_id: 42 }],
  ];
  for (const [name, body] of refuse) {
    const r = await call(o.DB, 'POST', PATH, { body });
    assert.equal(r.status, 400, `${name}: ${r.text}`);
    assert.equal(r.text.includes(TOKEN), false, `${name} echoes the token`);
    assert.equal(r.text.includes('tok-fixture'), false, `${name} echoes a body value`);
  }
  for (const key of ['token', 'bot_token']) {
    const r = await call(o.DB, 'POST', PATH, { body: { [key]: TOKEN } });
    assert.match(r.body.error, /sealed in an envelope/, `${key}: the answer says to seal it`);
  }
  const bad = await call(o.DB, 'POST', PATH, { raw: '{not json' });
  assert.equal(bad.status, 400);
  assert.deepEqual(tgRows(o.db), []);
  assert.equal(envelopes(o.db), before);
});

test('A3 a fleet:telegram envelope is 200 and writes telegram.envelope_id and telegram.state', async (t) => {
  const o = await fresh(t); if (!o) return;
  const id = (await store(o.DB, 'fleet:telegram')).body.id;
  const r = await call(o.DB, 'POST', PATH, { body: { envelope_id: id } });
  assert.equal(r.status, 200, r.text);
  assert.equal(r.body.envelope_id, id);
  assert.equal(r.body.state, 'pending');
  assert.equal(r.headers.get('cache-control'), 'no-store');
  const get = async (k) => (await call(o.DB, 'GET', `/api/settings/${k}`)).body?.setting?.value;
  assert.equal(await get('telegram.state'), 'pending');
  assert.equal(await get('telegram.envelope_id'), id);
  assert.equal((await call(o.DB, 'POST', PATH, { body: { envelope_id: id } })).status, 200, 'a repeat is 200');
  const rows = tgRows(o.db);
  assert.deepEqual(rows.map((x) => x.key), ['telegram.envelope_id', 'telegram.state']);
  assert.ok(rows.every((x) => x.actor === 'fleet-accounts'), JSON.stringify(rows));
  // The route never writes the rows the hub verb owns.
  assert.equal(rows.some((x) => x.key === 'telegram.chat_id' || x.key === 'telegram.bot_present'), false);
  // A hub read between the store and this POST leaves `consumed`, then `applied`: still 200.
  for (const ev of ['consumed', 'applied']) {
    const id2 = (await store(o.DB, 'fleet:telegram')).body.id;
    addEvent(o.db, id2, ev);
    const r2 = await call(o.DB, 'POST', PATH, { body: { envelope_id: id2 } });
    assert.equal(r2.status, 200, `${ev}: ${r2.text}`);
    assert.equal(await get('telegram.envelope_id'), id2);
  }
});

test('A4 an unknown, wrong-scope, expired or failed envelope is 400 and writes no row', async (t) => {
  const o = await fresh(t); if (!o) return;
  const cases = [];
  cases.push(['unknown uuid', crypto.randomUUID()]);
  for (const scope of ['fleet:fly:acme', 'ai-account:claude:a:pool', 'fleet:tailscale']) {
    cases.push([`scope ${scope}`, (await store(o.DB, scope)).body.id]);
  }
  for (const ev of ['expired', 'apply_failed']) {
    const id = (await store(o.DB, 'fleet:telegram')).body.id;
    addEvent(o.db, id, ev);
    cases.push([`newest ${ev}`, id]);
  }
  const stale = (await store(o.DB, 'fleet:telegram')).body.id;
  o.db.prepare('UPDATE secret_envelopes SET expires_at=? WHERE id=?').run(iso(NOW_MS), stale);
  cases.push(['live row at its expiry', stale]);
  for (const [name, id] of cases) {
    const r = await call(o.DB, 'POST', PATH, { body: { envelope_id: id } });
    assert.equal(r.status, 400, `${name}: ${r.text}`);
  }
  assert.deepEqual(tgRows(o.db), []);
});

test('A5 the fleet scope table: checkEnvelopeScope and POST /api/secrets/envelope agree with every row', async (t) => {
  const o = await fresh(t); if (!o) return;
  assert.ok(SCOPES.length >= 30, `the fixture has ${SCOPES.length} rows`);
  let accepted = 0;
  for (const [scope, want] of SCOPES) {
    assert.ok(want === 'accept' || want === 'refuse', `bad fixture row ${JSON.stringify(scope)}`);
    assert.equal(ENV_MOD.checkEnvelopeScope(scope), want === 'accept', `helper on ${JSON.stringify(scope)}`);
    const r = await store(o.DB, scope);
    assert.equal(r.status, want === 'accept' ? 200 : 400, `POST on ${JSON.stringify(scope)}: ${r.text}`);
    if (want === 'accept') accepted++;
  }
  assert.equal(envelopes(o.db), accepted);
  assert.ok(ENV_MOD.FLEET_SCOPE_RE instanceof RegExp);
  // The two older grammars keep their answers.
  assert.equal(ENV_MOD.checkEnvelopeScope('ai-account:openai.default'), true);
  assert.equal(ENV_MOD.checkEnvelopeScope('tracker:linear:acme@x'), true);
  assert.equal(ENV_MOD.checkEnvelopeScope('ai-account:a..b'), false);
});

test('A6 the two reads use ix_secret_envelope_events_env and the secret_envelopes PK at 20,000 events', async (t) => {
  const o = await fresh(t); if (!o) return;
  assert.equal(typeof MOD.STORED_SCOPE_SQL, 'string');
  assert.equal(typeof MOD.STATE_SQL, 'string');
  const insE = o.db.prepare('INSERT INTO secret_envelope_events (envelope_id, scope, event, detail, at) VALUES (?,?,?,NULL,?)');
  const insR = o.db.prepare('INSERT INTO secret_envelopes (id, scope, ciphertext, created_at, expires_at) VALUES (?,?,?,?,?)');
  o.db.exec('BEGIN');
  for (let i = 0; i < 20000; i++) insE.run(`vol-fixture-${i % 5000}`, 'fleet:telegram', i < 5000 ? 'stored' : 'consumed', iso(NOW_MS));
  for (let i = 0; i < 5000; i++) insR.run(`vol-fixture-${i}`, 'fleet:telegram', CT, iso(NOW_MS), iso(NOW_MS + 60e3));
  o.db.exec('COMMIT');
  o.db.exec('ANALYZE');
  const scopeLines = plan(o.db, MOD.STORED_SCOPE_SQL, 'vol-fixture-7');
  assert.ok(scopeLines.some((l) => l.includes('ix_secret_envelope_events_env')), scopeLines.join(' | '));
  const stateLines = plan(o.db, MOD.STATE_SQL, 'vol-fixture-7');
  assert.ok(stateLines.some((l) => l.includes('ix_secret_envelope_events_env')), stateLines.join(' | '));
  assert.ok(stateLines.some((l) => /secret_envelopes USING (INDEX sqlite_autoindex_secret_envelopes|PRIMARY KEY)/.test(l)), stateLines.join(' | '));
  assert.deepEqual(fullScans([...scopeLines, ...stateLines], ['secret_envelopes', 'secret_envelope_events']), []);
  // The SQL reads what the store wrote.
  assert.equal(o.db.prepare(MOD.STORED_SCOPE_SQL).get('vol-fixture-7').scope, 'fleet:telegram');
  const s = o.db.prepare(MOD.STATE_SQL).get('vol-fixture-7');
  assert.equal(s.event, 'consumed');
  assert.equal(s.expires_at, iso(NOW_MS + 60e3));
});
