// BH-6799: POST /api/wakes/claim answers scanned_top = MAX(id) on an uncapped
// scan, and reads `wakes` through idx_wakes_repo_lc_id / idx_wakes_kind_id.
//
// Live on 2026-10-14: the claim answered scanned_top = the last MATCHING id, so
// a box whose repos rang rarely kept its cursor below every other repo's rows
// and re-read them on every poll (project-6: 67,159 rows behind, 4,557 rows a
// call). Every case runs the real route through `worker.fetch` (D2) over
// node:sqlite with the composed schema, and records each statement it ran.
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { jobsSchemaSql } from './lib/jobs-schema.js';
import { openVolumeDb, capturingD1, plan, fullScans } from './lib/d1-volume.bh-6727.js';

const SECRET = 'test-secret';
const NOW = '2026-10-15T08:00:00Z';

// A D1-shaped adapter that records {sql, binds} of every statement and runs
// `hooks.afterRead(sql)` after each read, so a test can write a row BETWEEN
// two reads of one route call (the race a single thread cannot otherwise make).
function d1(db, calls, hooks) {
  const shape = (sql, binds) => {
    const exec = () => {
      calls.push({ sql: sql.replace(/\s+/g, ' ').trim(), binds });
      return db.prepare(sql);
    };
    const after = (v) => { if (hooks.afterRead) hooks.afterRead(sql); return v; };
    return {
      all: async () => after({ results: exec().all(...binds) }),
      first: async () => after(exec().get(...binds) ?? null),
      run: async () => {
        const r = exec().run(...binds);
        return { meta: { changes: Number(r.changes), last_row_id: Number(r.lastInsertRowid) } };
      },
    };
  };
  return { prepare: (sql) => ({ bind: (...b) => shape(sql, b), ...shape(sql, []) }) };
}

async function fixture(t) {
  let DatabaseSync;
  try {
    ({ DatabaseSync } = await import('node:sqlite'));
  } catch {
    t.skip('node:sqlite unavailable on this runtime');
    return null;
  }
  const db = new DatabaseSync(':memory:');
  db.exec(jobsSchemaSql());
  const calls = [];
  const hooks = {};
  const ins = db.prepare(
    'INSERT INTO wakes (repo, kind, key, event, minute, at) VALUES (?,?,?,?,?,?) RETURNING id');
  let n = 0;
  const add = (repo, kind = 'push') => {
    n += 1;
    return Number(ins.get(repo, kind, `k${n}`, kind, NOW.slice(0, 16), NOW).id);
  };
  return { db, calls, hooks, DB: d1(db, calls, hooks), add };
}

const call = (fx, method, path, body) => {
  const init = { method, headers: { authorization: `Bearer ${SECRET}`, 'content-type': 'application/json' } };
  if (body !== undefined) init.body = JSON.stringify(body);
  return worker.fetch(new Request(`https://jobs.test${path}`, init), { DB: fx.DB, HARNESS_SECRET: SECRET })
    .then(async (res) => ({ status: res.status, body: await res.json().catch(() => null) }));
};
const claim = (fx, body) => call(fx, 'POST', '/api/wakes/claim', body);
const put = (fx, box, cursor) => call(fx, 'PUT', '/api/wakes/cursor', { box, cursor });
const ids = (r) => r.body.wakes.map((w) => w.id);
const maxId = (fx) => Number(fx.db.prepare('SELECT MAX(id) m FROM wakes').get().m);
const scans = (fx) => fx.calls.filter((c) => /^SELECT \* FROM wakes WHERE id > \?1/.test(c.sql));

test('C1: an uncapped claim answers scanned_top = MAX(id), so the next claim reads none of the other repo', async (t) => {
  const fx = await fixture(t);
  if (!fx) return;
  for (let i = 0; i < 1000; i++) fx.add('o/a');
  const b1 = fx.add('o/b');
  const first = await claim(fx, { box: 'boxb', repos: ['o/b'], limit: 50 });
  assert.equal(first.status, 200, JSON.stringify(first.body));
  assert.deepEqual(ids(first), [b1]);
  assert.equal(first.body.scanned_top, maxId(fx), 'scanned_top is MAX(id)');
  assert.equal((await put(fx, 'boxb', first.body.scanned_top)).status, 200);

  for (let i = 0; i < 1000; i++) fx.add('o/a');
  const second = await claim(fx, { box: 'boxb', repos: ['o/b'], limit: 50 });
  assert.equal(second.status, 200);
  assert.deepEqual(second.body.wakes, []);
  assert.equal(second.body.cursor, b1);
  assert.equal(second.body.scanned_top, maxId(fx),
    'an uncapped scan examined every row up to MAX, so it reports MAX, not its old cursor');
  assert.equal((await put(fx, 'boxb', second.body.scanned_top)).status, 200);

  fx.calls.length = 0;
  const third = await claim(fx, { box: 'boxb', repos: ['o/b'], limit: 50 });
  assert.deepEqual(third.body.wakes, []);
  assert.equal(third.body.scanned_top, maxId(fx), 'a cursor already at MAX stays at MAX');
  const s = scans(fx);
  assert.equal(s.length, 1, 'one scan statement');
  assert.equal(s[0].binds[0], maxId(fx), 'the scan starts above MAX: it reads 0 rows of o/a');
  fx.db.close();
});

test('C2: a capped claim reports its last returned id, never above it', async (t) => {
  const fx = await fixture(t);
  if (!fx) return;
  const bs = [];
  for (let i = 0; i < 30; i++) { fx.add('o/a'); bs.push(fx.add('o/b')); fx.add('o/a'); }
  const r = await claim(fx, { box: 'boxb', repos: ['o/b'], limit: 10 });
  assert.equal(r.status, 200);
  assert.deepEqual(ids(r), bs.slice(0, 10));
  assert.equal(r.body.scanned_top, bs[9], 'capped: the 10th returned id');
  assert.ok(r.body.scanned_top < maxId(fx));
  await put(fx, 'boxb', r.body.scanned_top);
  const next = await claim(fx, { box: 'boxb', repos: ['o/b'], limit: 10 });
  assert.deepEqual(ids(next), bs.slice(10, 20), 'the next claim drains the rest, nothing skipped');
  fx.db.close();
});

test('C3: a row written after the MAX read is not skipped', async (t) => {
  const fx = await fixture(t);
  if (!fx) return;
  fx.add('o/a');
  const b1 = fx.add('o/b');
  const hi = maxId(fx);
  let late = null;
  fx.hooks.afterRead = (sql) => {
    if (late === null && /MAX\(id\)/.test(sql) && /FROM wakes/.test(sql)) late = fx.add('o/b');
  };
  const r = await claim(fx, { box: 'boxb', repos: ['o/b'], limit: 50 });
  fx.hooks.afterRead = null;
  assert.ok(late !== null, 'the claim read MAX(id) before its scan');
  assert.equal(r.status, 200);
  assert.equal(r.body.scanned_top, hi, 'scanned_top is the pre-scan MAX, not a row the scan never examined');
  assert.deepEqual(ids(r), [b1], 'the scan stops at the MAX it read: never a row above scanned_top');
  await put(fx, 'boxb', r.body.scanned_top);
  const next = await claim(fx, { box: 'boxb', repos: ['o/b'], limit: 50 });
  assert.deepEqual(ids(next), [late], 'the late row is claimed on the next poll');
  fx.db.close();
});

test('C4: an empty wakes table answers scanned_top = the cursor', async (t) => {
  const fx = await fixture(t);
  if (!fx) return;
  const r = await claim(fx, { box: 'boxb', repos: ['o/b'], limit: 50 });
  assert.equal(r.status, 200);
  assert.deepEqual(r.body.wakes, []);
  assert.equal(r.body.scanned_top, 0);
  fx.db.close();
});

test('C5: the two claim indexes exist and the claim plan SEARCHes them on the 206k-row volume DB', async (t) => {
  const vol = await openVolumeDb();
  if (!vol) return t.skip('node:sqlite unavailable');
  const names = vol.db.prepare("SELECT name FROM pragma_index_list('wakes')").all().map((r) => r.name);
  assert.ok(names.includes('idx_wakes_repo_lc_id'), names.join(','));
  assert.ok(names.includes('idx_wakes_kind_id'), names.join(','));
  const log = [];
  const res = await worker.fetch(new Request('https://jobs.test/api/wakes/claim', {
    method: 'POST',
    headers: { authorization: `Bearer ${SECRET}`, 'content-type': 'application/json' },
    body: JSON.stringify({ box: 'boxv', repos: ['O/Alpha'], kinds_all_repos: ['lead-land'], limit: 50 }),
  }), { DB: capturingD1(vol.db, log), HARNESS_SECRET: SECRET });
  assert.equal(res.status, 200);
  const hit = log.filter((r) => /SELECT \* FROM wakes WHERE id >/.test(r.sql));
  assert.equal(hit.length, 1, 'the route ran its scan');
  const lines = plan(vol.db, hit[0].sql, ...hit[0].binds);
  assert.ok(lines.some((l) => /idx_wakes_repo_lc_id/.test(l)), lines.join(' | '));
  assert.ok(lines.some((l) => /idx_wakes_kind_id/.test(l)), lines.join(' | '));
  assert.deepEqual(fullScans(lines, ['wakes']), [], lines.join(' | '));
  assert.ok(!lines.some((l) => /^SCAN wakes/.test(l)), lines.join(' | '));
  vol.db.close();
});
