// BH-9190: the D1 overload retry's attempt count and base delay are the
// settings rows d1_retry.attempts and d1_retry.base_ms. The worker reads them
// ONLY from the settings snapshot already in memory (settings-cache.js), never
// by a D1 query, because they bound a retry against an overloaded D1. With no
// snapshot, or a bad value, the code constants apply.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { openDb } from './lib/d1-sqlite.bh-1030.js';

const lib = () => import('../src/lib/d1-retry.js');
const cache = () => import('../src/lib/settings-cache.js');

const OVERLOAD = 'D1_ERROR: D1 DB is overloaded. Too many resources consumed within a 10 second window.';
const SCHEMA_D = fileURLToPath(new URL('../schema.d/', import.meta.url));
const FRAGMENT = readdirSync(SCHEMA_D).find((f) => /-bh-9190-d1-retry-knobs\.sql$/.test(f));

function seq(n, value = 'ok') {
  const f = async () => { f.calls += 1; if (f.calls <= n) throw new Error(OVERLOAD); return value; };
  f.calls = 0;
  return f;
}
const clock = (r = 0.5) => {
  const waits = [];
  return { waits, sleep: async (ms) => { waits.push(ms); }, random: () => r };
};

// A settings-table fake that counts prepare calls: rows is { key: value }.
function settingsDb(rows) {
  const db = {
    prepares: 0,
    prepare() {
      db.prepares += 1;
      return { all: async () => ({ results: Object.entries(rows).map(([key, value]) => ({ key, value })) }) };
    },
  };
  return db;
}

test('BH-9190 K1: overloaded twice then success returns the result after 3 calls, 2 sleeps', async () => {
  const { withD1Retry } = await lib();
  const f = seq(2);
  const c = clock();
  assert.equal(await withD1Retry(f, { sleep: c.sleep, random: c.random }), 'ok');
  assert.equal(f.calls, 3);
  assert.equal(c.waits.length, 2);
});

test('BH-9190 K2: opts.attempts=2 gives up after 2 calls with d1Attempts=2', async () => {
  const { withD1Retry } = await lib();
  const f = seq(99);
  const c = clock();
  await assert.rejects(withD1Retry(f, { attempts: 2, sleep: c.sleep, random: c.random }), (e) => e.d1Attempts === 2);
  assert.equal(f.calls, 2);
});

test('BH-9190 K3: opts.baseMs sets the first wait', async () => {
  const { withD1Retry } = await lib();
  for (const [r, want] of [[1, 20], [0, 10]]) {
    const c = clock(r);
    await withD1Retry(seq(1), { baseMs: 20, sleep: c.sleep, random: c.random });
    assert.deepEqual(c.waits, [want]);
  }
  // A bad opts value falls back to the constants.
  const c = clock(1);
  const f = seq(99);
  await assert.rejects(withD1Retry(f, { attempts: 'x', baseMs: -3, sleep: c.sleep, random: c.random }));
  assert.equal(f.calls, 5);
  assert.equal(c.waits[0], 100);
});

test('BH-9190 K4: knob parse table through retryKnobs on a seeded snapshot', async () => {
  const { retryKnobs, D1_RETRY_ATTEMPTS: A, D1_RETRY_BASE_MS: B } = await lib();
  const { settingsRows } = await cache();
  const cases = [
    [{ 'd1_retry.attempts': '5' }, 5, B], [{ 'd1_retry.attempts': '1' }, 1, B], [{ 'd1_retry.attempts': '8' }, 8, B],
    [{ 'd1_retry.base_ms': '10' }, A, 10], [{ 'd1_retry.base_ms': '500' }, A, 500],
    [{ 'd1_retry.attempts': '0' }, A, B], [{ 'd1_retry.attempts': '9' }, A, B], [{ 'd1_retry.attempts': '50' }, A, B],
    [{ 'd1_retry.attempts': '-1' }, A, B], [{ 'd1_retry.attempts': '2.5' }, A, B], [{ 'd1_retry.attempts': ' 3x' }, A, B],
    [{ 'd1_retry.base_ms': 'abc' }, A, B], [{ 'd1_retry.base_ms': '' }, A, B], [{ 'd1_retry.base_ms': '9' }, A, B],
    [{ 'd1_retry.base_ms': '501' }, A, B], [{}, A, B],
  ];
  for (const [rows, attempts, baseMs] of cases) {
    const DB = settingsDb(rows);
    await settingsRows({ DB, SETTINGS_CACHE_TTL_S: '30' });
    assert.deepEqual(retryKnobs(DB), { attempts, baseMs }, JSON.stringify(rows));
  }
  // TTL 0: no snapshot is stored, so the constants apply.
  const DB = settingsDb({ 'd1_retry.attempts': '2' });
  await settingsRows({ DB, SETTINGS_CACHE_TTL_S: '0' });
  assert.deepEqual(retryKnobs(DB), { attempts: A, baseMs: B });
});

test('BH-9190 K5: peekSetting never queries D1; null with no snapshot or after invalidate', async () => {
  const { peekSetting, settingsRows, invalidateSettings } = await cache();
  const { retryKnobs } = await lib();
  const DB = settingsDb({ 'd1_retry.attempts': '3' });
  const env = { DB, SETTINGS_CACHE_TTL_S: '30' };
  assert.equal(peekSetting(DB, 'd1_retry.attempts'), null);
  assert.deepEqual(retryKnobs(DB), { attempts: 5, baseMs: 100 });
  assert.equal(DB.prepares, 0, 'peekSetting and retryKnobs send no query');
  await settingsRows(env);
  assert.equal(DB.prepares, 1);
  assert.equal(peekSetting(DB, 'd1_retry.attempts'), '3');
  assert.equal(peekSetting(DB, 'nope'), null);
  assert.deepEqual(retryKnobs(DB), { attempts: 3, baseMs: 100 });
  assert.equal(DB.prepares, 1, 'still one query');
  // A snapshot older than its TTL (30 s) is not used.
  const realNow = Date.now;
  const t0 = realNow();
  Date.now = () => t0 + 31_000;
  try {
    assert.equal(peekSetting(DB, 'd1_retry.attempts'), null, 'stale snapshot');
    assert.deepEqual(retryKnobs(DB), { attempts: 5, baseMs: 100 });
  } finally { Date.now = realNow; }
  assert.equal(DB.prepares, 1);
  invalidateSettings(env);
  assert.equal(peekSetting(DB, 'd1_retry.attempts'), null);
});

test('BH-9190 K6: round trip on node:sqlite with the seed fragment, then through retryingDb', async (t) => {
  const opened = await openDb();
  if (opened === null) { t.skip('node:sqlite unavailable in this runtime'); return; }
  const { retryingDb, retryKnobs } = await lib();
  const { settingsRows, invalidateSettings } = await cache();
  const { db, DB: raw } = opened;
  // An always-overloaded statement for one marker SQL; the rest is real.
  let overloadCalls = 0;
  const base = {
    prepare(sql) {
      if (sql === 'SELECT 9190') {
        const st = { bind() { return st; }, async first() { overloadCalls += 1; throw new Error(OVERLOAD); } };
        return st;
      }
      return raw.prepare(sql);
    },
  };
  const DB = retryingDb(base);
  const env = { DB, SETTINGS_CACHE_TTL_S: '30' };
  await settingsRows(env);
  assert.deepEqual(retryKnobs(DB), { attempts: 5, baseMs: 100 }, 'the seeded rows');
  db.prepare("UPDATE settings SET value='2' WHERE key='d1_retry.attempts'").run();
  db.prepare("UPDATE settings SET value='10' WHERE key='d1_retry.base_ms'").run();
  invalidateSettings(env);
  await settingsRows(env);
  assert.deepEqual(retryKnobs(DB), { attempts: 2, baseMs: 10 });
  await assert.rejects(DB.prepare('SELECT 9190').first(), (e) => e.d1Attempts === 2);
  assert.equal(overloadCalls, 2, 'retryingDb used the row value');
  invalidateSettings(env);
});

test('BH-9190 K7: the seed values equal the code constants', async () => {
  const { D1_RETRY_ATTEMPTS, D1_RETRY_BASE_MS } = await lib();
  assert.ok(FRAGMENT, 'schema.d carries the bh-9190 d1-retry-knobs fragment');
  const sql = readFileSync(SCHEMA_D + FRAGMENT, 'utf8');
  const val = (key) => {
    const m = new RegExp(`VALUES \\('${key.replace('.', '\\.')}','([^']*)'`).exec(sql);
    assert.ok(m, `seed row ${key}`);
    return Number(m[1]);
  };
  assert.equal(val('d1_retry.attempts'), D1_RETRY_ATTEMPTS);
  assert.equal(val('d1_retry.base_ms'), D1_RETRY_BASE_MS);
});
