import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import worker from '../src/index.js';
import { jobsSchemaSql } from './lib/jobs-schema.js';

// POST /api/wakes/claim, GET|PUT /api/wakes/cursor, POST /api/wakes/cooldown/take
// and the orphan-claim sweep on POST /api/wakes/prune (BH-2636, BH-2525.1).
//
// The tables came with the contract slice (BH-2635, schema.sql); the client is
// bin/lib/jobs/queue.sh (wakes_claim, wake_cursor_get, wake_cursor_put,
// wake_cooldown_take). Every case goes through `worker.fetch` with the bearer —
// the production entry (D2) — over a node:sqlite database with schema.sql
// applied, and every statement is recorded so "a 400 ran nothing" is an
// assertion (D11).

const SCHEMA = jobsSchemaSql();
const SECRET = 'test-secret';

// The D1-shaped adapter wakes-prune.bh-1267 uses, copied (that file exports nothing).
function d1(db, calls) {
  const exec = (sql) => {
    calls.push(sql.replace(/\s+/g, ' ').trim());
    return db.prepare(sql);
  };
  const shape = (sql, binds) => ({
    all: async () => ({ results: exec(sql).all(...binds) }),
    first: async () => exec(sql).get(...binds) ?? null,
    run: async () => {
      const r = exec(sql).run(...binds);
      return { meta: { changes: r.changes, last_row_id: Number(r.lastInsertRowid) } };
    },
  });
  return {
    prepare(sql) {
      return { bind: (...b) => shape(sql, b), ...shape(sql, []) };
    },
  };
}

// One fixed instant every fixture row is stamped at. A6, the only test whose
// route reads the clock, pins the worker's Date to this same anchor.
const NOW = '2026-09-26T12:00:00Z';

async function fixture(t) {
  let DatabaseSync;
  try {
    ({ DatabaseSync } = await import('node:sqlite'));
  } catch {
    t.skip('node:sqlite unavailable on this runtime');
    return null;
  }
  const db = new DatabaseSync(':memory:');
  db.exec(SCHEMA);
  const calls = [];
  const ins = db.prepare(
    'INSERT INTO wakes (repo, kind, key, event, minute, at) VALUES (?,?,?,?,?,?) RETURNING id');
  let n = 0;
  const add = (repo, kind, at = NOW) => {
    n += 1;
    return Number(ins.get(repo, kind, `k${n}`, kind, at.slice(0, 16) + ':00Z', at).id);
  };
  return { db, calls, DB: d1(db, calls), add };
}

const call = (fx, method, path, body) => {
  const init = { method, headers: { authorization: `Bearer ${SECRET}`, 'content-type': 'application/json' } };
  if (body !== undefined) init.body = JSON.stringify(body);
  return worker.fetch(new Request(`https://jobs.test${path}`, init), { DB: fx.DB, HARNESS_SECRET: SECRET })
    .then(async (res) => ({ status: res.status, body: await res.json().catch(() => null) }));
};
const claim = (fx, body) => call(fx, 'POST', '/api/wakes/claim', body);
const ids = (r) => r.body.wakes.map((w) => w.id);
const writes = (fx) => fx.calls.filter((s) => /^(INSERT|UPDATE|DELETE)/i.test(s));

// ── A1 a claim is per (wake, box): two boxes each get the row once ──────────
test('A1: two boxes both claim the same wake; a repeat claim by the same box gets []', async (t) => {
  const fx = await fixture(t);
  if (!fx) return;
  const id = fx.add('example-org/x', 'pr');
  const a = await claim(fx, { box: 'a', repos: ['example-org/x'], limit: 10 });
  assert.equal(a.status, 200, JSON.stringify(a.body));
  assert.deepEqual(ids(a), [id]);
  assert.equal(a.body.wakes[0].repo, 'example-org/x', 'the answer carries the whole wake row');
  const b = await claim(fx, { box: 'b', repos: ['example-org/x'], limit: 10 });
  assert.deepEqual(ids(b), [id], 'another box is not blocked by a claim: it is a dedupe, not a lock');
  const again = await claim(fx, { box: 'a', repos: ['example-org/x'], limit: 10 });
  assert.equal(again.status, 200);
  assert.deepEqual(again.body.wakes, [], 'a box never gets the same wake twice');
  assert.equal(again.body.scanned_top, id, 'the scan still saw it, so the caller can move its cursor');
  const rows = fx.db.prepare('SELECT wake_id, box FROM wake_claims ORDER BY box').all()
    .map((r) => `${r.wake_id}/${r.box}`);
  assert.deepEqual(rows, [`${id}/a`, `${id}/b`]);
  fx.db.close();
});

// ── A2 the filter: exact repo, all-repo kinds, case folded ──────────────────
test('A2: repos and kinds_all_repos select exactly, never a lookalike, case-insensitively', async (t) => {
  const fx = await fixture(t);
  if (!fx) return;
  const aPr = fx.add('example-org/a', 'pr');
  fx.add('example-org/b', 'issue');
  const bPr = fx.add('example-org/b', 'pr');
  const bChecks = fx.add('example-org/b', 'checks');
  const bh = fx.add('example-org/cromford', 'push');
  fx.add('example-org/cromford-x', 'push');
  const upper = fx.add('example-org/A', 'push');

  const a = await claim(fx, { box: 'boxa', repos: ['example-org/a'], limit: 50 });
  assert.deepEqual(ids(a), [aPr, upper], 'only example-org/a rows, stored in either case');

  const hub = await claim(fx, { box: 'hub', repos: [], kinds_all_repos: ['pr', 'checks'], limit: 50 });
  assert.deepEqual(ids(hub), [aPr, bPr, bChecks], 'every repo for the listed kinds, never b\'s issue');

  const lk = await claim(fx, { box: 'boxbh', repos: ['example-org/cromford'], limit: 50 });
  assert.deepEqual(ids(lk), [bh], 'example-org/cromford-x is not example-org/cromford');

  const mixed = await claim(fx, { box: 'boxm', repos: [' example-org/A '], limit: 50 });
  assert.deepEqual(ids(mixed), [aPr, upper], 'a mixed-case request matches both stored cases');
  fx.db.close();
});

// ── A3 the cap, scanned_top and the cursor the box PUTs ─────────────────────
test('A3: a capped claim reports scanned_top; the next claim after a PUT returns exactly the rest', async (t) => {
  const fx = await fixture(t);
  if (!fx) return;
  const all = [];
  for (let i = 0; i < 150; i++) all.push(fx.add('example-org/x', 'pr'));
  const first = await claim(fx, { box: 'a', repos: ['example-org/x'], limit: 100 });
  assert.equal(first.status, 200);
  assert.equal(first.body.cursor, 0, 'a box with no cursor row scans from 0');
  assert.deepEqual(ids(first), all.slice(0, 100));
  assert.equal(first.body.scanned_top, all[99], 'scanned_top is the last SCANNED id, not the table max');
  assert.equal(fx.calls.filter((s) => /^INSERT OR IGNORE INTO wake_claims/.test(s)).length, 2,
    '100 ids go in two slices under the 100-bind cap');

  const put = await call(fx, 'PUT', '/api/wakes/cursor', { box: 'a', cursor: first.body.scanned_top });
  assert.equal(put.status, 200);
  const second = await claim(fx, { box: 'a', repos: ['example-org/x'], limit: 150 });
  assert.equal(second.body.cursor, all[99], 'the claim echoes the cursor it scanned from');
  assert.deepEqual(ids(second), all.slice(100));
  assert.equal(second.body.scanned_top, all[149]);

  const empty = await claim(fx, { box: 'b', repos: ['example-org/none'], limit: 10 });
  assert.deepEqual(empty.body.wakes, []);
  // BH-6799: an uncapped scan examined every row up to MAX(id), matching or
  // not, so it reports MAX (it was the cursor it started from, 0).
  assert.equal(empty.body.scanned_top, all[149], 'an uncapped empty scan reports MAX(id)');

  // 150 fresh ids for a new box: two slices (99 + 51), every one returned.
  const c = await claim(fx, { box: 'c', repos: ['example-org/x'], limit: 150 });
  assert.equal(c.body.wakes.length, 150, 'every slice\'s inserted rows come back');
  fx.db.close();
});

// ── A4 the cursor is monotonic and validated ────────────────────────────────
test('A4: PUT cursor keeps the higher value; GET of an unknown box is null; junk is 400', async (t) => {
  const fx = await fixture(t);
  if (!fx) return;
  const unknown = await call(fx, 'GET', '/api/wakes/cursor?box=nobody');
  assert.equal(unknown.status, 200);
  assert.deepEqual([unknown.body.box, unknown.body.cursor], ['nobody', null], 'never an invented 0');

  assert.equal((await call(fx, 'PUT', '/api/wakes/cursor', { box: 'a', cursor: 10 })).body.cursor, 10);
  const lower = await call(fx, 'PUT', '/api/wakes/cursor', { box: 'a', cursor: 5 });
  assert.equal(lower.status, 200);
  assert.equal(lower.body.cursor, 10, 'a stale PUT answers the stored, higher cursor');
  const got = await call(fx, 'GET', '/api/wakes/cursor?box=a');
  assert.equal(got.body.cursor, 10);

  const before = writes(fx).length;
  for (const box of ['a b', '', '../x']) {
    assert.equal((await call(fx, 'PUT', '/api/wakes/cursor', { box, cursor: 1 })).status, 400, `box ${JSON.stringify(box)}`);
    assert.equal((await call(fx, 'GET', `/api/wakes/cursor?box=${encodeURIComponent(box)}`)).status, 400, `GET box ${JSON.stringify(box)}`);
  }
  for (const cursor of [-1, '5', 1.5, null, undefined, Number.MAX_SAFE_INTEGER + 2]) {
    const r = await call(fx, 'PUT', '/api/wakes/cursor', { box: 'a', cursor });
    assert.equal(r.status, 400, `cursor ${JSON.stringify(cursor)} must be refused`);
  }
  assert.equal(writes(fx).length, before, 'a refused PUT wrote nothing');
  assert.equal((await call(fx, 'GET', '/api/wakes/cursor?box=a')).body.cursor, 10);
  fx.db.close();
});

// ── A5 the fleet-wide cooldown is one conditional upsert ────────────────────
test('A5: cooldown take is taken once per window, fleet-wide, and junk windows are 400', async (t) => {
  const fx = await fixture(t);
  if (!fx) return;
  const t0 = Date.parse('2026-09-26T12:00:00Z');
  t.mock.timers.enable({ apis: ['Date'], now: t0 });
  const take = (body) => call(fx, 'POST', '/api/wakes/cooldown/take', body);
  const base = { kind: 'build', project: 'fleet', window_s: 120, box: 'a' };

  const r0 = await take(base);
  assert.equal(r0.status, 200, JSON.stringify(r0.body));
  assert.equal(r0.body.taken, true, 'the first take of a key is taken');
  t.mock.timers.setTime(t0 + 60e3);
  assert.equal((await take({ ...base, box: 'b' })).body.taken, false, 'inside the window, another box is refused');
  const row = fx.db.prepare('SELECT last_at, box FROM wake_cooldowns').get();
  assert.deepEqual([row.last_at, row.box], [t0 / 1000, 'a'], 'a refused take changes nothing');
  t.mock.timers.setTime(t0 + 120e3);
  assert.equal((await take({ ...base, box: 'b' })).body.taken, true, 'at the window edge it is taken again');
  assert.equal(fx.db.prepare('SELECT box FROM wake_cooldowns').get().box, 'b');
  assert.equal((await take({ ...base, project: 'project-3' })).body.taken, true, 'keys are (kind, project)');
  assert.equal((await take({ ...base, window_s: 0 })).body.taken, true, 'window 0 is always taken');

  const before = writes(fx).length;
  for (const bad of [
    { window_s: '120' }, { window_s: -1 }, { window_s: 1.5 }, { window_s: 604801 }, { window_s: undefined },
    { kind: 'a b' }, { kind: '' }, { project: '../x' }, { box: '' },
  ]) {
    const r = await take({ ...base, ...bad });
    assert.equal(r.status, 400, `${JSON.stringify(bad)} must be refused`);
  }
  assert.equal(writes(fx).length, before, 'a refused take ran no INSERT');
  fx.db.close();
});

// ── A6 prune sweeps claims whose wake is gone, bounded by the same limit ────
test('A6: prune deletes orphan claims up to limit and says claims_capped', async (t) => {
  const fx = await fixture(t);
  if (!fx) return;
  t.mock.timers.enable({ apis: ['Date'], now: Date.parse(NOW) });
  const old = new Date(Date.parse(NOW) - 40 * 86400e3).toISOString().replace(/\.\d{3}Z$/, 'Z');
  const o1 = fx.add('example-org/x', 'pr', old);
  const o2 = fx.add('example-org/x', 'pr', old);
  const live = fx.add('example-org/x', 'pr');
  assert.equal((await claim(fx, { box: 'a', repos: ['example-org/x'], limit: 10 })).body.wakes.length, 3);

  const p1 = await call(fx, 'POST', '/api/wakes/prune', { days: 30, limit: 1 });
  assert.equal(p1.status, 200);
  assert.equal(p1.body.deleted, 1);
  assert.equal(p1.body.claims_deleted, 1);
  assert.equal(p1.body.claims_capped, true, 'a sweep that hit its cap says so');
  const p2 = await call(fx, 'POST', '/api/wakes/prune', { days: 30, limit: 5 });
  assert.equal(p2.body.deleted, 1);
  assert.equal(p2.body.claims_deleted, 1);
  assert.equal(p2.body.claims_capped, false);
  const left = fx.db.prepare('SELECT wake_id FROM wake_claims').all().map((r) => r.wake_id);
  assert.deepEqual(left, [live], `the live wake's claim survives; ${o1} and ${o2} are gone`);

  const before = fx.calls.length;
  assert.equal((await call(fx, 'POST', '/api/wakes/prune', { days: 0 })).status, 400);
  assert.equal(fx.calls.length, before, 'a refused prune runs neither DELETE');
  fx.db.close();
});

// ── A7 junk claims are 400 before any statement ─────────────────────────────
test('A7: never all rows, and every bad field is a 400 that read nothing', async (t) => {
  const fx = await fixture(t);
  if (!fx) return;
  fx.add('example-org/x', 'pr');
  const good = { box: 'a', repos: ['example-org/x'], limit: 10 };
  for (const bad of [
    { repos: [], kinds_all_repos: [] },
    { repos: undefined, kinds_all_repos: undefined },
    { repos: null, kinds_all_repos: null },
    { repos: 'example-org/x' },
    { repos: ['example-org/x', 3] },
    { repos: [''] },
    { repos: ['x'.repeat(201)] },
    { repos: Array.from({ length: 501 }, (_, i) => `r${i}`) },
    { kinds_all_repos: 'pr' },
    { limit: 0 }, { limit: 501 }, { limit: '100' }, { limit: 1.5 }, { limit: undefined },
    { box: 'a b' }, { box: '' }, { box: '../x' }, { box: undefined },
  ]) {
    const before = fx.calls.length;
    const r = await claim(fx, { ...good, ...bad });
    assert.equal(r.status, 400, `${JSON.stringify(bad)} must be refused: ${JSON.stringify(r.body)}`);
    assert.equal(fx.calls.length, before, `${JSON.stringify(bad)} ran a statement: ${fx.calls.slice(before).join(' | ')}`);
  }
  assert.equal(fx.db.prepare('SELECT COUNT(*) n FROM wake_claims').get().n, 0);
  fx.db.close();
});

// ── A8 the prune's belt: wake_claims self-creates exactly as schema.sql has it
test('A8: a database without schema.sql self-creates wake_claims identical to schema.sql', async (t) => {
  const fx = await fixture(t);
  if (!fx) return;
  const cols = (db) => db.prepare('PRAGMA table_info(wake_claims)').all()
    .map((r) => `${r.name} ${r.type}${r.notnull ? ' NOT NULL' : ''} pk${r.pk}`);
  const idx = (db) => db.prepare('PRAGMA index_list(wake_claims)').all().map((r) => r.name).sort();
  const { DatabaseSync } = await import('node:sqlite');
  const bare = new DatabaseSync(':memory:');
  const r = await worker.fetch(new Request('https://jobs.test/api/wakes/prune', {
    method: 'POST', headers: { authorization: `Bearer ${SECRET}`, 'content-type': 'application/json' },
    body: JSON.stringify({ days: 30 }),
  }), { DB: d1(bare, []), HARNESS_SECRET: SECRET });
  const b = await r.json();
  assert.equal(r.status, 200, JSON.stringify(b));
  assert.equal(b.claims_deleted, 0);
  assert.deepEqual(cols(bare), cols(fx.db));
  assert.deepEqual(idx(bare), idx(fx.db));
  bare.close(); fx.db.close();
});
