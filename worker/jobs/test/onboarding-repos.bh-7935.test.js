import test, { mock } from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import { reposAnswer, reposMax } from '../src/routes/onboarding-repo.js';

// BH-7998 (BH-7935.1): GET /api/onboarding/repos answers at most
// onboarding.repos_list_max names (settings row, code fallback 200). Driven
// through the worker's REAL fetch handler against node:sqlite running the
// composed schema; every prepared statement is counted, Date is mocked.
//   Q1  two GETs 9 minutes apart in one 600 s bucket file one row
//   Q2  250 names answer the first 200, in order, and incomplete:true
//   Q3  the settings row sets the cap; a bad row reads the fallback
//   Q4  150 names and no row: all 150, incomplete as the probe said
//   Q5  a settings read that throws still answers with the fallback cap
//   Q6  the route adds at most one D1 statement (the settings read)
const SECRET = 'test-secret';
const T0 = Date.parse('2026-10-22T09:00:10Z');
const START = Math.floor(T0 / 600000) * 600000;

async function db(t) {
  const o = await openDb();
  if (!o) { t.skip('node:sqlite unavailable'); return null; }
  o.sql = [];
  const inner = o.DB;
  o.DB = { ...inner, prepare: (sql) => { o.sql.push(sql); return inner.prepare(sql); } };
  return o;
}

function at(t, ms) {
  mock.timers.reset();
  mock.timers.enable({ apis: ['Date'], now: ms });
  t.after(() => mock.timers.reset());
}

const get = (o, env = {}) => {
  const req = new Request('https://jobs.test/api/onboarding/repos', { headers: { authorization: `Bearer ${SECRET}` } });
  return worker.fetch(req, { DB: o.DB, HARNESS_SECRET: SECRET, ...env })
    .then(async (res) => ({ status: res.status, body: await res.json().catch(() => null) }));
};
const rows = (o) => o.db.prepare('SELECT * FROM hub_probe_requests ORDER BY id').all();
const names = (n) => Array.from({ length: n }, (_, i) => `example-org/repo-${String(i).padStart(3, '0')}`);
const setting = (o, value) => {
  o.db.prepare('DELETE FROM settings WHERE key = ?').run('onboarding.repos_list_max');
  if (value !== null) {
    o.db.prepare("INSERT INTO settings (key, value, note, actor, updated_at) VALUES ('onboarding.repos_list_max', ?, 'test', 'test', '2026-10-22T00:00:00Z')").run(value);
  }
};

// One filed row moved to pass with <list> and <tail>, then read back.
async function reposWith(t, list, tail, value = null) {
  const o = await db(t); if (!o) return null;
  setting(o, value);
  at(t, START);
  await get(o);
  const out = `${list.join('\n')}\n${tail}`;
  o.db.prepare("UPDATE hub_probe_requests SET status='pass', output=? WHERE id=?").run(out, rows(o)[0].id);
  o.sql = [];
  const r = await get(o);
  return { o, ...r };
}

test('(Q1) two GETs 9 minutes apart in one 600 s bucket file one row', async (t) => {
  const o = await db(t); if (!o) return;
  at(t, START);
  await get(o);
  mock.timers.setTime(START + 9 * 60_000);
  const b = await get(o);
  assert.equal(b.status, 200);
  assert.equal(rows(o).length, 1);
  assert.equal(rows(o)[0].ticket_key, `onb-repos-${START / 600000}`);
});

test('(Q2) 250 names answer the first 200, in order, and incomplete:true', async (t) => {
  const r = await reposWith(t, names(250), 'total_count=250\n');
  if (!r) return;
  assert.equal(r.status, 200);
  assert.equal(r.body.state, 'ok');
  assert.equal(r.body.repos.length, 200);
  assert.deepEqual(r.body.repos, names(250).slice(0, 200));
  assert.equal(r.body.total_count, 250);
  assert.equal(r.body.incomplete, true);
});

test('(Q3) the settings row sets the cap; a padded value is trimmed; bad rows read 200', async (t) => {
  for (const [value, want] of [['5', 5], [' 7 ', 7], ['1000', 210], ['0', 200], ['abc', 200], ['1001', 200], ['-3', 200], ['12.5', 200], ['', 200]]) {
    await t.test(`row ${JSON.stringify(value)} -> ${want}`, async (t) => {
      const r = await reposWith(t, names(210), 'total_count=210\n', value);
      if (!r) return;
      assert.equal(r.body.repos.length, want);
      assert.deepEqual(r.body.repos, names(210).slice(0, want));
      assert.equal(r.body.incomplete, want < 210);
    });
  }
});

test('(Q4) 150 names and no settings row: all 150, incomplete as the probe said', async (t) => {
  const r = await reposWith(t, names(150), 'total_count=150\n');
  if (!r) return;
  assert.equal(r.body.repos.length, 150);
  assert.equal(r.body.incomplete, false);
  const s = await reposWith(t, names(150), 'total_count=180\nincomplete: 30 of 180\n');
  assert.equal(s.body.repos.length, 150);
  assert.equal(s.body.incomplete, true);
});

test('(Q5) a settings read that throws still answers with the fallback cap', async (t) => {
  assert.equal(await reposMax({ DB: { prepare() { throw new Error('D1 overloaded'); } } }), 200);
  const o = await db(t); if (!o) return;
  at(t, START);
  await get(o);
  o.db.prepare("UPDATE hub_probe_requests SET status='pass', output=? WHERE id=?")
    .run(`${names(230).join('\n')}\ntotal_count=230\n`, rows(o)[0].id);
  const inner = o.DB;
  const DB = { ...inner, prepare: (sql) => { if (/FROM settings/i.test(sql)) throw new Error('D1 overloaded'); return inner.prepare(sql); } };
  const res = await worker.fetch(new Request('https://jobs.test/api/onboarding/repos', { headers: { authorization: `Bearer ${SECRET}` } }),
    { DB, HARNESS_SECRET: SECRET });
  const body = await res.json();
  assert.equal(res.status, 200);
  assert.equal(body.repos.length, 200);
  assert.equal(body.incomplete, true);
});

test('(Q6) the route adds at most one D1 statement: the settings read', async (t) => {
  const r = await reposWith(t, names(3), 'total_count=3\n');
  if (!r) return;
  // fileScreenProbe: the INSERT and the SELECT. reposMax: one settings SELECT.
  assert.ok(r.o.sql.length <= 3, `statements: ${r.o.sql.length}`);
  assert.equal(r.o.sql.filter((s) => /FROM settings/i.test(s)).length, 1);
});

test('(Q7) reposAnswer: the default cap is 200 and a cut sets incomplete', () => {
  const row = { status: 'pass', output: `${names(201).join('\n')}\ntotal_count=201\n` };
  assert.equal(reposAnswer(row).repos.length, 200);
  assert.equal(reposAnswer(row).incomplete, true);
  assert.equal(reposAnswer(row, 201).incomplete, false);
  assert.equal(reposAnswer({ status: 'claimed' }, 5).state, 'pending');
});
