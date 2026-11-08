// BH-9190 (Sentry CROMFORD-HARNESS-1R): a steer settings read that D1 rejects
// as overloaded on every retry must not fail the request. setting() in
// routes/steer.js returns the documented code fallback and writes one warn
// line; every other error still throws. One key is read once per request.
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';

const steer = () => import('../src/routes/steer.js');

const OVERLOAD = 'D1_ERROR: D1 DB is overloaded. Too many resources consumed within a 10 second window.';
const OVERLOAD_2 = 'D1_ERROR: D1 DB is overloaded. Requests queued for too long.';
const SETTINGS_SQL = /FROM settings WHERE key/;

// A D1 fake: the settings read calls `answer(key)` (a value, or a throw).
// `reads` counts settings prepares.
function fakeDb(answer) {
  const db = {
    reads: 0,
    prepare(sql) {
      if (SETTINGS_SQL.test(sql)) db.reads += 1;
      let key;
      const st = {
        bind(...v) { key = v[0]; return st; },
        async first() {
          if (!SETTINGS_SQL.test(sql)) return null;
          const x = answer(key);
          if (x instanceof Error || (x && x.__throw)) throw x.__throw ?? x;
          return x;
        },
      };
      return st;
    },
  };
  return db;
}

function spyWarn() {
  const lines = [];
  const orig = console.warn;
  console.warn = (...a) => { lines.push(a.join(' ')); };
  return { lines, restore: () => { console.warn = orig; } };
}

// The error withD1Retry rethrows on give-up.
const giveUp = (msg) => Object.assign(new Error(msg), { d1Attempts: 5 });

test('BH-9190 U1: always overloaded -> setting() resolves the fallback, one warn line', async () => {
  const { setting, STEER_TAKE_LEASE_S } = await steer();
  assert.equal(typeof setting, 'function', 'setting is exported');
  const DB = fakeDb(() => giveUp(OVERLOAD));
  const w = spyWarn();
  let v;
  try {
    v = await setting({ DB }, 'steer.take_lease_s', 60, 86400, STEER_TAKE_LEASE_S);
  } finally { w.restore(); }
  assert.equal(v, 7200);
  assert.equal(w.lines.length, 1, w.lines.join('\n'));
  assert.match(w.lines[0], /steer setting steer\.take_lease_s: D1 overloaded after 5 attempts; using fallback 7200/);
});

test('BH-9190 U2: 5 calls in one request read D1 once; a second request reads again', async () => {
  const { setting } = await steer();
  const DB = fakeDb(() => '25');
  const env = { DB };
  for (let i = 0; i < 5; i++) assert.equal(await setting(env, 'steer.outbox_limit', 1, 100, 10), 25);
  assert.equal(DB.reads, 1, 'one D1 read in one request');
  // A different range on the same key still parses the raw value.
  assert.equal(await setting(env, 'steer.outbox_limit', 1, 20, 10), 10);
  assert.equal(DB.reads, 1);
  // index.js builds a new env object per request.
  assert.equal(await setting({ ...env }, 'steer.outbox_limit', 1, 100, 10), 25);
  assert.equal(DB.reads, 2, 'a second request reads D1 again');
  // The fallback after an overload is memoised for the request too.
  const DB2 = fakeDb(() => giveUp(OVERLOAD));
  const env2 = { DB: DB2 };
  const w = spyWarn();
  try {
    for (let i = 0; i < 5; i++) assert.equal(await setting(env2, 'steer.attempts_max', 1, 10, 3), 3);
  } finally { w.restore(); }
  assert.equal(DB2.reads, 1);
  assert.equal(w.lines.length, 1);
});

test('BH-9190 U3: classify — only the overload message falls back', async () => {
  const { setting } = await steer();
  for (const msg of [OVERLOAD, OVERLOAD_2]) {
    const w = spyWarn();
    try {
      assert.equal(await setting({ DB: fakeDb(() => giveUp(msg)) }, 'steer.deliver_lease_s', 60, 3600, 300), 300, msg);
    } finally { w.restore(); }
  }
  const others = [
    new Error('D1_ERROR: no such table: settings'),
    new Error('D1_ERROR: database is locked'),
    new TypeError('x is not a function'),
    { __throw: 'D1 DB is overloaded' }, // a plain string: no .message
  ];
  for (const e of others) {
    const DB = fakeDb(() => e);
    const env = { DB };
    await assert.rejects(setting(env, 'steer.deliver_lease_s', 60, 3600, 300), (x) => x === (e.__throw ?? e), String(e.message ?? e.__throw));
    // Nothing memoised: a second call in the same request reads D1 again.
    await assert.rejects(setting(env, 'steer.deliver_lease_s', 60, 3600, 300));
    assert.equal(DB.reads, 2, 'a rejected read is not memoised');
  }
});

test('BH-9190 R1: POST /api/steer/take answers 200 with the fallback lease when the settings read is always overloaded', async (t) => {
  const opened = await openDb();
  if (opened === null) { t.skip('node:sqlite unavailable in this runtime'); return; }
  const { db, DB: raw } = opened;
  db.prepare("INSERT INTO jobs (id, project, ticket_id, kind, box, stage, status, created_at, updated_at) VALUES ('b-9190','cromford','BH-9190','build','pool-1','execute','running','2026-11-06T21:00:00Z','2026-11-06T21:00:00Z')").run();
  db.prepare("INSERT INTO steer_notes (project, ticket, job_id, mode, text, actor, status, created_at, updated_at) VALUES ('cromford','BH-9190','b-9190','now','check it','operator@example.com','pending','2026-11-06T21:00:00Z','2026-11-06T21:00:00Z')").run();
  let settingsReads = 0;
  const DB = {
    prepare(sql) {
      if (SETTINGS_SQL.test(sql)) {
        const st = { bind() { return st; }, async first() { settingsReads += 1; throw new Error(OVERLOAD); } };
        return st;
      }
      return raw.prepare(sql);
    },
    batch: (s) => raw.batch(s),
  };
  const w = spyWarn();
  let res;
  try {
    res = await worker.fetch(new Request('https://jobs.test/api/steer/take', {
      method: 'POST',
      headers: { authorization: 'Bearer s', 'content-type': 'application/json' },
      body: JSON.stringify({ job_id: 'b-9190' }),
    }), { DB, HARNESS_SECRET: 's' });
  } finally { w.restore(); }
  const body = await res.json().catch(() => null);
  assert.equal(res.status, 200, JSON.stringify(body));
  assert.ok(Array.isArray(body.notes), 'notes array present');
  assert.equal(body.notes.length, 1);
  assert.equal(body.notes[0].status, 'taken');
  assert.equal(settingsReads, 5, 'withD1Retry tried 5 times before the fallback');
  assert.equal(w.lines.filter((l) => /steer setting/.test(l)).length, 1);
});
