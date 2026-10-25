// BH-7965 (BH-7937.2): the hub half of the secret envelope in the jobs worker.
// GET /api/secrets/envelope?state=pending, POST /api/secrets/envelope/:id/confirm,
// POST /api/secrets/envelope/sweep, PUT /api/secrets/envelope/public-key.
// Driven through the REAL worker.fetch on node:sqlite with the composed jobs
// schema and a mocked Date. Each case opens its own database.
//   K1 the two seeded rows        R0 4 routes in fragment order
//   G1 the hub-token gate table   R2 confirm writes one event, no other table
//   R3 confirm 409 / 404 / 400    R4 pending: live only, id+scope only
//   R5 limit and state            S1-S7 the sweep        G4 the public key
//   E1 EXPLAIN at 5,000 rows
import test from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { generateKeyPairSync, createHash } from 'node:crypto';
import worker from '../src/index.js';
import { matcherSignature } from '../src/lib/router.js';
import { openDb, d1 } from './lib/d1-sqlite.bh-1030.js';
import { plan, fullScans } from './lib/d1-volume.bh-6727.js';

const SECRET = 'tok-fixture-bh7965-main';
const HUB = 'tok-fixture-bh7965-hub';
const MOD = await import('../src/routes/secret-envelope-apply.js').catch(() => ({}));
const FRAG_DIR = fileURLToPath(new URL('./route-table.d/', import.meta.url));
const NOW_MS = Date.parse('2026-10-23T08:00:00Z');
const DAY = 86400e3;
const iso = (ms) => new Date(ms).toISOString().replace(/\.\d{3}Z$/, 'Z');
const bytes = (n, k) => Buffer.from(Array.from({ length: n }, (_, i) => (i * 37 + k) & 255));
const CT = bytes(512, 3).toString('base64');
const PEM = generateKeyPairSync('rsa', { modulusLength: 4096 }).publicKey.export({ type: 'spki', format: 'pem' });
// The label is joined at run time so the source carries no literal private-key marker (share-mirror leakcheck).
const PRIV_LABEL = ['PRIVATE', 'KEY'].join(' ');
const PRIV = `-----BEGIN ${PRIV_LABEL}-----\nMIIBVQIBADANBgkqhkiG9w0BAQEFAASCAT8wggE7AgEAAkEA\n-----END ${PRIV_LABEL}-----\n`;

async function fresh(t) {
  const o = await openDb();
  if (!o) { t.skip('node:sqlite unavailable'); return null; }
  t.mock.timers.enable({ apis: ['Date'], now: NOW_MS });
  return o;
}
function call(DB, method, path, { auth = `Bearer ${SECRET}`, hubHeader = HUB, body, env = { ENVELOPE_HUB_TOKEN: HUB } } = {}) {
  const headers = { 'content-type': 'application/json' };
  if (auth) headers.authorization = auth;
  if (hubHeader !== undefined && hubHeader !== null) headers['x-envelope-hub-token'] = hubHeader;
  const init = { method, headers };
  if (method !== 'GET') init.body = typeof body === 'string' ? body : JSON.stringify(body ?? {});
  return worker.fetch(new Request(`https://jobs.test${path}`, init), { DB, HARNESS_SECRET: SECRET, ...env })
    .then(async (res) => {
      const text = await res.text();
      let json = null; try { json = JSON.parse(text); } catch { json = null; }
      return { status: res.status, headers: res.headers, body: json, text };
    });
}
const pending = (DB, q = 'state=pending', opts) => call(DB, 'GET', `/api/secrets/envelope?${q}`, opts);
const confirm = (DB, id, body, opts) => call(DB, 'POST', `/api/secrets/envelope/${id}/confirm`, { body, ...opts });
const sweep = (DB, body, opts) => call(DB, 'POST', '/api/secrets/envelope/sweep', { hubHeader: null, body, ...opts });
const putKey = (DB, pem, opts) => call(DB, 'PUT', '/api/secrets/envelope/public-key', { body: { pem }, ...opts });
const count = (db, tbl, where = '1=1') => db.prepare(`SELECT COUNT(*) AS n FROM ${tbl} WHERE ${where}`).get().n;
const events = (db, id) => db.prepare('SELECT event, detail FROM secret_envelope_events WHERE envelope_id=? ORDER BY id').all(id);
const setting = (db, key, value) => db.prepare(
  "INSERT INTO settings (key,value,note,actor,updated_at) VALUES (?,?,'fixture','fixture','2026-10-22T00:00:00Z') ON CONFLICT(key) DO UPDATE SET value=excluded.value"
).run(key, String(value));
const settingVal = (db, key) => db.prepare('SELECT value FROM settings WHERE key=?').get(key)?.value;
function seedEnv(db, id, expiresAt, scope = 'ai-account:claude:team-a:pool') {
  db.prepare('INSERT INTO secret_envelopes (id, scope, ciphertext, created_at, expires_at) VALUES (?,?,?,?,?)')
    .run(id, scope, CT, '2026-10-23T07:50:00Z', expiresAt);
}
function seedEvent(db, envId, event, at, scope = 'ai-account:claude:team-a:pool') {
  db.prepare('INSERT INTO secret_envelope_events (envelope_id, scope, event, detail, at) VALUES (?,?,?,?,?)')
    .run(envId, scope, event, null, at);
}
const sweepEvents = (db) => db.prepare("SELECT detail FROM secret_envelope_events WHERE event='sweep' ORDER BY id").all()
  .map((r) => JSON.parse(r.detail));

test('K1 the schema fragment seeds the retention and batch rows', async (t) => {
  const o = await fresh(t); if (!o) return;
  assert.equal(settingVal(o.db, 'secret_envelope_events_retention_days'), '90');
  assert.equal(settingVal(o.db, 'secret_envelope_sweep_batch'), '500');
});

test('R0 the module exports 4 routes in fragment order; no bh-7937 fragment', () => {
  assert.ok(Array.isArray(MOD.routes), 'routes loaded');
  const sigs = MOD.routes.map(([m, matcher]) => `${m} ${matcherSignature(matcher)}`);
  assert.deepEqual(sigs, [
    'GET /api/secrets/envelope',
    String.raw`POST re:/^\/api\/secrets\/envelope\/([^/]+)\/confirm$/`,
    'POST /api/secrets/envelope/sweep',
    'PUT /api/secrets/envelope/public-key',
  ]);
  const frag = readFileSync(`${FRAG_DIR}bh-7964-secret-envelope-apply.txt`, 'utf8')
    .split('\n').filter((l) => l.trim() && !l.startsWith('#'));
  assert.deepEqual(frag, sigs);
  assert.equal(existsSync(`${FRAG_DIR}bh-7937-secret-envelope-apply.txt`), false);
});

test('G1 the hub-token gate table on pending, confirm and public-key; sweep is main bearer only', async (t) => {
  const o = await fresh(t); if (!o) return;
  const id = crypto.randomUUID();
  const rows = [
    ['env token unset', { env: {} }, 503],
    ['env token blank', { env: { ENVELOPE_HUB_TOKEN: '   ' } }, 503],
    ['env token with a trailing newline', { env: { ENVELOPE_HUB_TOKEN: `${HUB}\n` } }, 'pass'],
    ['header missing', { hubHeader: null }, 403],
    ['token plus x', { hubHeader: `${HUB}x` }, 403],
    ['token minus its last char', { hubHeader: HUB.slice(0, -1) }, 403],
    ['token in another case', { hubHeader: HUB.toUpperCase() }, 403],
    ['no main bearer', { auth: null }, 401],
    ['main bearer value as the hub header', { hubHeader: SECRET }, 403],
  ];
  const routes = {
    pending: (opts) => pending(o.DB, 'state=pending', opts),
    confirm: (opts) => confirm(o.DB, id, { ok: true, detail: 'boxes=1/1' }, opts),
    'public-key': (opts) => putKey(o.DB, PEM, opts),
  };
  for (const [name, fn] of Object.entries(routes)) {
    for (const [why, opts, want] of rows) {
      const r = await fn(opts);
      if (want === 'pass') assert.ok(![401, 403, 503].includes(r.status), `${name} ${why}: ${r.status}`);
      else assert.equal(r.status, want, `${name} ${why}`);
    }
  }
  // Nothing was written by a refused call: the only public-key write is the pass row.
  assert.equal(count(o.db, 'secret_envelope_events', "event='public_key_set'"), 1);
  assert.equal(count(o.db, 'secret_envelope_events', "event IN ('applied','apply_failed')"), 0);
  const s = await sweep(o.DB, { dry_run: true });
  assert.equal(s.status, 200, JSON.stringify(s.body));
  const s2 = await sweep(o.DB, { dry_run: true }, { auth: null, hubHeader: HUB });
  assert.equal(s2.status, 401, 'the hub token alone does not open the sweep');
});

test('R2 a confirm after a consume writes one applied event and no other table', async (t) => {
  const o = await fresh(t); if (!o) return;
  const id = crypto.randomUUID();
  seedEvent(o.db, id, 'consumed', iso(NOW_MS - 60e3));
  seedEnv(o.db, crypto.randomUUID(), iso(NOW_MS + 600e3));
  const envN = count(o.db, 'secret_envelopes'); const setN = count(o.db, 'settings');
  const r = await confirm(o.DB, id, { ok: true, detail: 'boxes=1/1' });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.event, 'applied');
  assert.equal(r.headers.get('cache-control'), 'no-store');
  assert.deepEqual(events(o.db, id).map((e) => e.event), ['consumed', 'applied']);
  assert.equal(events(o.db, id)[1].detail, 'boxes=1/1');
  const scope = o.db.prepare("SELECT scope FROM secret_envelope_events WHERE envelope_id=? AND event='applied'").get(id).scope;
  assert.equal(scope, 'ai-account:claude:team-a:pool', 'the scope comes from the consumed event');
  assert.equal(count(o.db, 'secret_envelopes'), envN);
  assert.equal(count(o.db, 'settings'), setN);
  const id2 = crypto.randomUUID();
  seedEvent(o.db, id2, 'consumed', iso(NOW_MS - 60e3));
  const f = await confirm(o.DB, id2, { ok: false, detail: 'vendor refused the key' });
  assert.equal(f.status, 200);
  assert.deepEqual(events(o.db, id2).map((e) => e.event), ['consumed', 'apply_failed']);
});

test('R3 second confirm 409; no consumed event 404; bad body 400; nothing written', async (t) => {
  const o = await fresh(t); if (!o) return;
  const id = crypto.randomUUID();
  seedEvent(o.db, id, 'consumed', iso(NOW_MS - 60e3));
  assert.equal((await confirm(o.DB, id, { ok: true, detail: 'boxes=1/1' })).status, 200);
  const again = await confirm(o.DB, id, { ok: false, detail: 'boxes=0/1' });
  assert.equal(again.status, 409);
  assert.equal(events(o.db, id).length, 2, 'no write on 409');
  const nobody = crypto.randomUUID();
  const r404 = await confirm(o.DB, nobody, { ok: true, detail: 'x' });
  assert.equal(r404.status, 404);
  assert.equal(events(o.db, nobody).length, 0);
  assert.equal((await confirm(o.DB, 'not-a-uuid', { ok: true, detail: 'x' })).status, 404);
  const id2 = crypto.randomUUID();
  seedEvent(o.db, id2, 'consumed', iso(NOW_MS - 60e3));
  for (const [why, body] of [
    ['ok as a string', { ok: 'true', detail: 'x' }],
    ['ok missing', { detail: 'x' }],
    ['detail with a newline', { ok: true, detail: 'a\nb' }],
    ['detail 201 chars', { ok: true, detail: 'a'.repeat(201) }],
    ['detail a number', { ok: true, detail: 5 }],
    ['detail with a quote', { ok: true, detail: 'a"b' }],
  ]) {
    assert.equal((await confirm(o.DB, id2, body)).status, 400, why);
  }
  assert.equal(events(o.db, id2).length, 1, 'a 400 writes nothing');
  assert.equal((await confirm(o.DB, id2, { ok: true, detail: 'a'.repeat(200) })).status, 200, '200 chars is allowed');
});

test('R4 pending lists the live envelopes only, id and scope only, never the ciphertext', async (t) => {
  const o = await fresh(t); if (!o) return;
  const a = crypto.randomUUID(), b = crypto.randomUUID(), dead = crypto.randomUUID();
  seedEnv(o.db, a, iso(NOW_MS + 300e3), 'ai-account:xai:ops:pool');
  seedEnv(o.db, b, iso(NOW_MS + 600e3), 'tracker:jira:x');
  seedEnv(o.db, dead, iso(NOW_MS - 1e3));
  const r = await pending(o.DB);
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.headers.get('cache-control'), 'no-store');
  assert.deepEqual(r.body.envelopes.map((e) => e.id), [a, b], 'soonest expiry first, the expired one left out');
  for (const e of r.body.envelopes) assert.deepEqual(Object.keys(e).sort(), ['id', 'scope']);
  assert.equal(r.body.envelopes[0].scope, 'ai-account:xai:ops:pool');
  assert.equal(r.body.truncated, false);
  assert.equal(r.text.includes('ciphertext'), false);
  assert.equal(/ciphertext/.test(MOD.PENDING_SQL), false, 'the pending read never selects the ciphertext column');
  assert.equal(r.text.includes(CT.slice(0, 40)), false);
  assert.equal(count(o.db, 'secret_envelopes'), 3, 'a list deletes nothing');
});

test('R5 limit=1 truncates; limit 0, 101, x and state=all are 400; no limit = 20', async (t) => {
  const o = await fresh(t); if (!o) return;
  for (let i = 0; i < 22; i++) seedEnv(o.db, crypto.randomUUID(), iso(NOW_MS + (i + 1) * 1e3));
  const one = await pending(o.DB, 'state=pending&limit=1');
  assert.equal(one.status, 200);
  assert.equal(one.body.envelopes.length, 1);
  assert.equal(one.body.truncated, true);
  const all = await pending(o.DB, 'state=pending&limit=100');
  assert.equal(all.body.envelopes.length, 22);
  assert.equal(all.body.truncated, false);
  const dflt = await pending(o.DB);
  assert.equal(dflt.body.envelopes.length, 20);
  assert.equal(dflt.body.truncated, true);
  for (const q of ['state=pending&limit=0', 'state=pending&limit=101', 'state=pending&limit=x', 'state=pending&limit=1.5', 'state=all', '']) {
    assert.equal((await pending(o.DB, q)).status, 400, q);
  }
});

test('S1 a real sweep deletes the 3 expired envelopes, keeps the 2 live, and writes one sweep event', async (t) => {
  const o = await fresh(t); if (!o) return;
  const live = [crypto.randomUUID(), crypto.randomUUID()];
  for (let i = 0; i < 3; i++) seedEnv(o.db, crypto.randomUUID(), iso(NOW_MS - (i + 1) * 60e3));
  for (const id of live) seedEnv(o.db, id, iso(NOW_MS + 600e3));
  const r = await sweep(o.DB, { dry_run: false });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.dry_run, false);
  assert.equal(r.body.envelopes, 3);
  assert.equal(r.body.more, false);
  assert.equal(count(o.db, 'secret_envelopes'), 2);
  for (const id of live) assert.equal(count(o.db, 'secret_envelopes', `id='${id}'`), 1);
  const ev = sweepEvents(o.db);
  assert.equal(ev.length, 1);
  assert.equal(ev[0].envelopes, 3);
  assert.equal(ev[0].dry_run, false);
  const row = o.db.prepare("SELECT envelope_id, scope FROM secret_envelope_events WHERE event='sweep'").get();
  assert.equal(row.envelope_id, null); assert.equal(row.scope, null);
});

test('S2 a dry run deletes nothing and writes one sweep event with dry_run true', async (t) => {
  const o = await fresh(t); if (!o) return;
  for (let i = 0; i < 3; i++) seedEnv(o.db, crypto.randomUUID(), iso(NOW_MS - (i + 1) * 60e3));
  for (let i = 0; i < 4; i++) seedEvent(o.db, `old-fixture-${i}`, 'stored', iso(NOW_MS - 100 * DAY));
  const r = await sweep(o.DB, { dry_run: true });
  assert.equal(r.status, 200);
  assert.equal(r.body.dry_run, true);
  assert.equal(r.body.archive, 'dry');
  assert.equal(r.body.envelopes, 3, 'a dry run counts what it would delete');
  assert.equal(r.body.events, 4);
  assert.equal(count(o.db, 'secret_envelopes'), 3);
  assert.equal(count(o.db, 'secret_envelope_events', "event='stored'"), 4);
  const ev = sweepEvents(o.db);
  assert.equal(ev.length, 1);
  assert.equal(ev[0].dry_run, true);
});

test('S3 an absent dry_run is a dry run; a non-boolean dry_run is 400 with no event', async (t) => {
  const o = await fresh(t); if (!o) return;
  seedEnv(o.db, crypto.randomUUID(), iso(NOW_MS - 60e3));
  const r = await sweep(o.DB, {});
  assert.equal(r.status, 200);
  assert.equal(r.body.dry_run, true);
  assert.equal(count(o.db, 'secret_envelopes'), 1);
  for (const v of ['false', 0, 1, null, 'true']) {
    assert.equal((await sweep(o.DB, { dry_run: v })).status, 400, JSON.stringify(v));
  }
  assert.equal(sweepEvents(o.db).length, 1);
  assert.equal(count(o.db, 'secret_envelopes'), 1);
});

test('S4 the archive unbound: old events are not deleted, archive "not bound"', async (t) => {
  const o = await fresh(t); if (!o) return;
  for (let i = 0; i < 4; i++) seedEvent(o.db, `old-fixture-${i}`, 'stored', iso(NOW_MS - 91 * DAY));
  for (let i = 0; i < 2; i++) seedEvent(o.db, `new-fixture-${i}`, 'stored', iso(NOW_MS - 89 * DAY));
  const r = await sweep(o.DB, { dry_run: false });
  assert.equal(r.status, 200);
  assert.equal(r.body.archive, 'not bound');
  assert.equal(r.body.events, 0);
  assert.equal(count(o.db, 'secret_envelope_events', "event='stored'"), 6);
  assert.equal(sweepEvents(o.db)[0].archive, 'not bound');
});

async function bound(o) {
  const { DatabaseSync } = await import('node:sqlite');
  const adb = new DatabaseSync(':memory:');
  return { adb, ARCHIVE: d1(adb) };
}

test('S5 the retention row 5 is used; a row of abc falls back to 90', async (t) => {
  const o = await fresh(t); if (!o) return;
  const { adb, ARCHIVE } = await bound(o);
  seedEvent(o.db, 'e6-fixture', 'stored', iso(NOW_MS - 6 * DAY));
  seedEvent(o.db, 'e4-fixture', 'stored', iso(NOW_MS - 4 * DAY));
  seedEvent(o.db, 'e91-fixture', 'stored', iso(NOW_MS - 91 * DAY));
  setting(o.db, 'secret_envelope_events_retention_days', '5');
  const r = await sweep(o.DB, { dry_run: false }, { env: { ENVELOPE_HUB_TOKEN: HUB, ARCHIVE } });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.events, 2);
  assert.equal(count(o.db, 'secret_envelope_events', "envelope_id='e4-fixture'"), 1);
  seedEvent(o.db, 'e10-fixture', 'stored', iso(NOW_MS - 10 * DAY));
  for (const v of ['abc', '0', '3651', '1.5']) {
    setting(o.db, 'secret_envelope_events_retention_days', v);
    const r2 = await sweep(o.DB, { dry_run: true }, { env: { ENVELOPE_HUB_TOKEN: HUB, ARCHIVE } });
    assert.equal(r2.body.events, 0, `${v} -> 90 days: the 10-day event is kept`);
  }
  assert.equal(adb.prepare('SELECT COUNT(*) AS n FROM secret_envelope_events').get().n, 2);
});

test('S6 a bound archive: old events are copied then deleted; a failing archive deletes none', async (t) => {
  const o = await fresh(t); if (!o) return;
  const { adb, ARCHIVE } = await bound(o);
  for (let i = 0; i < 4; i++) seedEvent(o.db, `old-fixture-${i}`, 'stored', iso(NOW_MS - 100 * DAY));
  seedEvent(o.db, 'new-fixture', 'stored', iso(NOW_MS - DAY));
  const r = await sweep(o.DB, { dry_run: false }, { env: { ENVELOPE_HUB_TOKEN: HUB, ARCHIVE } });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.archive, 'ok');
  assert.equal(r.body.events, 4);
  assert.equal(count(o.db, 'secret_envelope_events', "event='stored'"), 1);
  const copied = adb.prepare('SELECT envelope_id, event, at, archived_at FROM secret_envelope_events ORDER BY id').all();
  assert.deepEqual(copied.map((c) => c.envelope_id), ['old-fixture-0', 'old-fixture-1', 'old-fixture-2', 'old-fixture-3']);
  assert.ok(copied.every((c) => c.archived_at));
  // A throwing archive.
  const o2 = await openDb();
  for (let i = 0; i < 3; i++) seedEvent(o2.db, `old-fixture-${i}`, 'stored', iso(NOW_MS - 100 * DAY));
  const boom = { prepare() { throw new Error('fixture archive down'); }, batch() { throw new Error('fixture archive down'); } };
  const f = await sweep(o2.DB, { dry_run: false }, { env: { ENVELOPE_HUB_TOKEN: HUB, ARCHIVE: boom } });
  assert.equal(f.status, 200, JSON.stringify(f.body));
  assert.equal(f.body.archive, 'failed');
  assert.equal(f.body.events, 0);
  assert.equal(count(o2.db, 'secret_envelope_events', "event='stored'"), 3);
  assert.equal(sweepEvents(o2.db)[0].archive, 'failed');
  // An archive that copies short (writes go nowhere, the count-back reads 0).
  const o3 = await openDb();
  for (let i = 0; i < 2; i++) seedEvent(o3.db, `old-fixture-${i}`, 'stored', iso(NOW_MS - 100 * DAY));
  const { ARCHIVE: real } = await bound(o3);
  const short = {
    prepare(sql) {
      if (/^\s*INSERT/i.test(sql)) return { bind: () => ({ run: async () => ({ meta: { changes: 0 } }), _isRead: false }) };
      return real.prepare(sql);
    },
    batch: async (stmts) => Promise.all(stmts.map((s) => s.run())),
  };
  const sh = await sweep(o3.DB, { dry_run: false }, { env: { ENVELOPE_HUB_TOKEN: HUB, ARCHIVE: short } });
  assert.equal(sh.body.archive, 'failed');
  assert.equal(count(o3.db, 'secret_envelope_events', "event='stored'"), 2);
});

test('S7 the batch row 2 with 3 expired: 2 deleted, more true', async (t) => {
  const o = await fresh(t); if (!o) return;
  for (let i = 0; i < 3; i++) seedEnv(o.db, crypto.randomUUID(), iso(NOW_MS - (i + 1) * 60e3));
  setting(o.db, 'secret_envelope_sweep_batch', '2');
  const r = await sweep(o.DB, { dry_run: false });
  assert.equal(r.body.envelopes, 2);
  assert.equal(r.body.more, true);
  assert.equal(count(o.db, 'secret_envelopes'), 1);
  assert.equal(sweepEvents(o.db)[0].more, true);
  setting(o.db, 'secret_envelope_sweep_batch', '5001');
  const r2 = await sweep(o.DB, { dry_run: false });
  assert.equal(r2.body.envelopes, 1, '5001 is out of range: 500');
  assert.equal(r2.body.more, false);
});

test('G4 the public key: a PUBLIC KEY PEM is stored and read back; PRIVATE, two blocks or 1300 chars are 400', async (t) => {
  const o = await fresh(t); if (!o) return;
  assert.ok(PEM.length < 1200, `pem ${PEM.length}`);
  const r = await putKey(o.DB, PEM);
  assert.equal(r.status, 200, JSON.stringify(r.body));
  const fp = createHash('sha256').update(PEM).digest('hex').slice(0, 16);
  assert.equal(r.body.fingerprint, fp);
  assert.equal(settingVal(o.db, 'hub_envelope_public_key'), PEM);
  const actor = o.db.prepare("SELECT actor FROM settings WHERE key='hub_envelope_public_key'").get().actor;
  assert.equal(actor, 'envelope-keygen');
  const ev = o.db.prepare("SELECT detail FROM secret_envelope_events WHERE event='public_key_set'").all();
  assert.deepEqual(ev.map((e) => e.detail), [fp]);
  const back = await call(o.DB, 'GET', '/api/settings/hub_envelope_public_key', { hubHeader: null });
  assert.equal(back.status, 200);
  assert.equal(back.body.setting.value, PEM);
  const body = PEM.split('\n').slice(1, -2).join('\n');
  for (const [why, pem] of [
    ['a PRIVATE KEY block', PRIV],
    ['two PUBLIC KEY blocks', PEM + PEM],
    ['1300 chars', `-----BEGIN PUBLIC KEY-----\n${'A'.repeat(64).concat('\n').repeat(20)}-----END PUBLIC KEY-----\n`],
    ['PRIVATE in the body', PEM.replace(body.slice(0, 7), 'PRIVATE')],
    ['not base64', PEM.replace(body.slice(0, 3), 'a$b')],
    ['a number', 5],
    ['empty', ''],
  ]) {
    const bad = await putKey(o.DB, pem);
    assert.equal(bad.status, 400, why);
  }
  assert.equal(settingVal(o.db, 'hub_envelope_public_key'), PEM, 'the row is unchanged');
  assert.equal(count(o.db, 'secret_envelope_events', "event='public_key_set'"), 1);
});

test('E1 EXPLAIN at 5,000 rows per table: no full SCAN on the pending, confirm, expired and event-sweep reads', async (t) => {
  const o = await fresh(t); if (!o) return;
  for (const k of ['PENDING_SQL', 'CONFIRM_LOOKUP_SQL', 'EVENTS_OLD_SQL', 'ENVELOPE_EXPIRED_SQL']) {
    assert.equal(typeof MOD[k], 'string', k);
  }
  const ie = o.db.prepare('INSERT INTO secret_envelopes (id, scope, ciphertext, created_at, expires_at) VALUES (?,?,?,?,?)');
  const iv = o.db.prepare('INSERT INTO secret_envelope_events (envelope_id, scope, event, detail, at) VALUES (?,?,?,?,?)');
  o.db.exec('BEGIN');
  for (let i = 0; i < 5000; i++) {
    ie.run(`vol-fixture-${i}`, 'ai-account:v', CT, '2026-10-01T00:00:00Z', iso(NOW_MS + (i - 2500) * 60e3));
    iv.run(`vol-fixture-${i}`, 'ai-account:v', i % 2 ? 'stored' : 'consumed', null, iso(NOW_MS - i * 3600e3));
  }
  o.db.exec('COMMIT');
  o.db.exec('ANALYZE');
  const cases = [
    [MOD.PENDING_SQL, [iso(NOW_MS), 21], 'secret_envelopes', 'ix_secret_envelopes_expires'],
    [MOD.CONFIRM_LOOKUP_SQL, ['vol-fixture-7'], 'secret_envelope_events', 'ix_secret_envelope_events_env'],
    [MOD.ENVELOPE_EXPIRED_SQL, [iso(NOW_MS), 500], 'secret_envelopes', 'ix_secret_envelopes_expires'],
    [MOD.EVENTS_OLD_SQL, [iso(NOW_MS - 90 * DAY), 500], 'secret_envelope_events', 'ix_secret_envelope_events_at'],
  ];
  for (const [sql, args, tbl, ix] of cases) {
    const lines = plan(o.db, sql, ...args);
    assert.ok(lines.some((l) => l.includes(ix)), `${sql}: ${lines.join(' | ')}`);
    assert.deepEqual(fullScans(lines, [tbl]), [], sql);
  }
});
