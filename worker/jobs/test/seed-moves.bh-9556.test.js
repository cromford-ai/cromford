// BH-9556 (slice C0): the two untouched seed rows move to their acting values
// on the first settings read of a DB binding (src/lib/seed-moves.js), and
// only while each row is still the untouched seed (old value AND actor seed).
//
//   M1 a fresh DB: both seed rows move once (changes [1,1]), actor seed:BH-9556
//   M2 a second call on the same binding is memoised (null); a fresh binding
//      (a new isolate) runs again and changes [0,0]
//   M3 an operator row (scheduler.mode=shadow, actor operator) is never moved
//   M4 a failing batch does not throw, the GET still answers 200 with the
//      row D1 holds, and the next read retries and moves it
//   M5 GET /api/settings/scheduler.mode answers enforce on the first read
//      after a cached read (the snapshot is invalidated by the move);
//      GET /api/settings lists both moved values
//   M6 PUT /api/settings with actor seed -> 400; nothing written
//   M7 PUT with actor operator value shadow, then a new isolate -> still shadow
//   N  the negative table (c)-(h): rows the move must never touch
//   S  the schema stays additive and still seeds the old values
import test from 'node:test';
import assert from 'node:assert/strict';
import { readdirSync, readFileSync } from 'node:fs';
import worker from '../src/index.js';
import { openDb, d1 } from './lib/d1-sqlite.bh-1030.js';
import { applySeedMoves, SEED_MOVES, SEED_MOVE_SQL } from '../src/lib/seed-moves.js';

const SECRET = 'SECRET-fixture';
const KEYS = ['console.needs.sweep_dry_run', 'scheduler.mode'];
const rowOf = (db, k) => db.prepare('SELECT value, actor FROM settings WHERE key = ?').get(k);
const pair = (db, k) => { const r = rowOf(db, k); return r ? [r.value, r.actor] : null; };
const call = async (DB, method, path, body) => {
  const res = await worker.fetch(new Request(`https://jobs.test${path}`, {
    method,
    headers: { 'content-type': 'application/json', authorization: `Bearer ${SECRET}` },
    body: body === undefined ? undefined : JSON.stringify(body),
  }), { DB, HARNESS_SECRET: SECRET });
  return { status: res.status, body: await res.json() };
};

test('M1 the untouched seed rows move once', async (t) => {
  const o = await openDb(); if (!o) return t.skip('node:sqlite unavailable');
  assert.deepEqual(pair(o.db, KEYS[0]), ['1', 'seed']);
  assert.deepEqual(pair(o.db, KEYS[1]), ['shadow', 'seed']);
  assert.deepEqual(await applySeedMoves(o.DB), [1, 1]);
  assert.deepEqual(pair(o.db, KEYS[0]), ['0', 'seed:BH-9556']);
  assert.deepEqual(pair(o.db, KEYS[1]), ['enforce', 'seed:BH-9556']);
  assert.match(o.db.prepare('SELECT note FROM settings WHERE key=?').get(KEYS[1]).note, /BH-9556/);
});

test('M2 memoised per binding; a new isolate changes nothing', async (t) => {
  const o = await openDb(); if (!o) return t.skip('node:sqlite unavailable');
  let moved = 0;
  assert.deepEqual(await applySeedMoves(o.DB, () => { moved++; }), [1, 1]);
  assert.equal(moved, 1, 'onMoved runs when a row changed');
  assert.equal(await applySeedMoves(o.DB, () => { moved++; }), null, 'memoised on the same binding');
  assert.deepEqual(await applySeedMoves(d1(o.db), () => { moved++; }), [0, 0], 'a fresh binding runs, the guard holds');
  assert.equal(moved, 1, 'onMoved does not run when nothing changed');
});

test("M3 an operator's shadow row is never moved", async (t) => {
  const o = await openDb(); if (!o) return t.skip('node:sqlite unavailable');
  o.db.prepare("UPDATE settings SET actor='operator' WHERE key='scheduler.mode'").run();
  assert.deepEqual(await applySeedMoves(o.DB), [1, 0]);
  assert.deepEqual(pair(o.db, KEYS[1]), ['shadow', 'operator']);
  const r = await call(d1(o.db), 'GET', '/api/settings/scheduler.mode');
  assert.equal(r.body.setting.value, 'shadow');
});

test('M4 a failing batch never throws; the read answers and the next read retries', async (t) => {
  let fail = true;
  const o = await openDb({ beforeRun(sql) { if (fail && sql === SEED_MOVE_SQL) throw new Error('fixture D1 failure'); } });
  if (!o) return t.skip('node:sqlite unavailable');
  const warn = console.warn; const warned = []; console.warn = (m) => warned.push(String(m));
  try {
    assert.equal(await applySeedMoves(o.DB), null);
    const r = await call(o.DB, 'GET', '/api/settings/scheduler.mode');
    assert.equal(r.status, 200);
    assert.equal(r.body.setting.value, 'shadow', 'the read answers what D1 holds');
    const all = await call(o.DB, 'GET', '/api/settings');
    assert.equal(all.status, 200);
  } finally { console.warn = warn; }
  assert.ok(warned.some((m) => /seed-moves/.test(m)), 'one warn line per failure');
  assert.deepEqual(pair(o.db, KEYS[1]), ['shadow', 'seed'], 'the batch rolled back');
  fail = false;
  const r2 = await call(o.DB, 'GET', '/api/settings/scheduler.mode');
  assert.equal(r2.body.setting.value, 'enforce', 'not memoised: the next read moves it');
});

test('M5 the first GET answers the moved values, past a cached snapshot', async (t) => {
  const o = await openDb(); if (!o) return t.skip('node:sqlite unavailable');
  o.db.prepare("INSERT OR REPLACE INTO settings (key,value,note,actor,updated_at) VALUES ('settings_cache_ttl_s','60','t','test','2026-11-24T00:00:00Z')").run();
  // A snapshot read by a route that does not run the move (it is still shadow there).
  const { settingsRows } = await import('../src/lib/settings-cache.js');
  assert.equal((await settingsRows({ DB: o.DB })).byKey.get('scheduler.mode').value, 'shadow');
  const r = await call(o.DB, 'GET', '/api/settings/scheduler.mode');
  assert.equal(r.status, 200);
  assert.equal(r.body.setting.value, 'enforce');
  const all = await call(o.DB, 'GET', '/api/settings');
  const by = Object.fromEntries(all.body.settings.map((s) => [s.key, s.value]));
  assert.equal(by['scheduler.mode'], 'enforce');
  assert.equal(by['console.needs.sweep_dry_run'], '0');
});

test("M6 PUT /api/settings refuses actor 'seed'", async (t) => {
  const o = await openDb(); if (!o) return t.skip('node:sqlite unavailable');
  await applySeedMoves(o.DB);
  const r = await call(o.DB, 'PUT', '/api/settings', { key: 'scheduler.mode', value: 'shadow', actor: 'seed' });
  assert.equal(r.status, 400);
  assert.match(r.body.error, /reserved/);
  assert.deepEqual(pair(o.db, KEYS[1]), ['enforce', 'seed:BH-9556'], 'nothing written');
});

test('M7 an operator shadow survives a new isolate', async (t) => {
  const o = await openDb(); if (!o) return t.skip('node:sqlite unavailable');
  const p = await call(o.DB, 'PUT', '/api/settings', { key: 'scheduler.mode', value: 'shadow', actor: 'operator' });
  assert.equal(p.status, 200, JSON.stringify(p.body));
  const fresh = d1(o.db);
  const r = await call(fresh, 'GET', '/api/settings/scheduler.mode');
  assert.equal(r.body.setting.value, 'shadow');
  assert.deepEqual(pair(o.db, KEYS[1]), ['shadow', 'operator']);
});

test('N the move never touches a row that is not the untouched seed', async (t) => {
  const cases = [
    ['(c) value 1, actor operator', KEYS[0], '1', 'operator'],
    ['(d) value shadow, actor registry-seed', KEYS[1], 'shadow', 'registry-seed'],
    ['(e) value enforce, actor seed', KEYS[1], 'enforce', 'seed'],
    ['(f) value off, actor seed', KEYS[1], 'off', 'seed'],
    ['(g) moved row set back to shadow by hand', KEYS[1], 'shadow', 'seed:BH-9556'],
    ['(e2) value 0, actor seed', KEYS[0], '0', 'seed'],
  ];
  for (const [name, key, value, actor] of cases) {
    const o = await openDb(); if (!o) return t.skip('node:sqlite unavailable');
    o.db.prepare('UPDATE settings SET value=?, actor=? WHERE key=?').run(value, actor, key);
    await applySeedMoves(o.DB);
    assert.deepEqual(pair(o.db, key), [value, actor], name);
  }
  // (h) no row: the UPDATE changes 0 and inserts nothing.
  const o = await openDb(); if (!o) return t.skip('node:sqlite unavailable');
  o.db.prepare('DELETE FROM settings WHERE key IN (?, ?)').run(...KEYS);
  assert.deepEqual(await applySeedMoves(o.DB), [0, 0]);
  assert.equal(pair(o.db, KEYS[0]), null, '(h) no row is inserted');
  assert.equal(pair(o.db, KEYS[1]), null, '(h) no row is inserted');
});

test('S the schema stays additive and the move table is the two keys', () => {
  assert.deepEqual(SEED_MOVES.map((m) => [m.key, m.from, m.to]),
    [['console.needs.sweep_dry_run', '1', '0'], ['scheduler.mode', 'shadow', 'enforce']]);
  const dir = new URL('../schema.d/', import.meta.url);
  for (const f of readdirSync(dir)) {
    const sql = readFileSync(new URL(f, dir), 'utf8');
    assert.ok(!/seed:BH-9556/.test(sql), `${f} must not carry the move`);
  }
});
