// BH-6799: GET /api/wakes/summary folds new wakes into wake_repo_last and
// answers from that table alone.
//
// Live on 2026-10-14 the summary aggregated every wake in its window on every
// call. Each case runs the real route through `worker.fetch` (D2) over
// node:sqlite with the composed schema, and records every statement it ran.
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { jobsSchemaSql } from './lib/jobs-schema.js';
import { openVolumeDb, capturingD1, plan, fullScans } from './lib/d1-volume.bh-6727.js';

const SECRET = 'test-secret';
const now = Date.now();  // determinism: ok the single anchor; every fixture below is iso(msAgo) off it
const H = 3600e3;
const iso = (msAgo) => new Date(now - msAgo).toISOString().replace(/\.\d{3}Z$/, 'Z');

// A D1-shaped adapter that records {sql, binds, changes} of every statement and
// runs `hooks.beforeRun(sql)` before each write.
function d1(db, calls, hooks) {
  const shape = (sql, binds) => {
    const rec = { sql: sql.replace(/\s+/g, ' ').trim(), binds };
    const exec = () => { calls.push(rec); return db.prepare(sql); };
    return {
      all: async () => ({ results: exec().all(...binds) }),
      first: async () => exec().get(...binds) ?? null,
      run: async () => {
        if (hooks.beforeRun) hooks.beforeRun(sql);
        const r = exec().run(...binds);
        rec.changes = Number(r.changes);
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
  const add = (repo, kind, at) => {
    n += 1;
    return Number(ins.get(repo, kind, `k${n}`, kind, `m${n}`, at).id);
  };
  return { db, calls, hooks, DB: d1(db, calls, hooks), add };
}

const summary = (fx, query = '') => worker.fetch(new Request(`https://jobs.test/api/wakes/summary${query}`, {
  headers: { authorization: `Bearer ${SECRET}` },
}), { DB: fx.DB, HARNESS_SECRET: SECRET })
  .then(async (res) => ({ status: res.status, body: await res.json().catch(() => null) }));
const table = (fx) => fx.db.prepare('SELECT repo, last_id, last_at, kinds FROM wake_repo_last ORDER BY repo')
  .all().map((r) => ({ ...r, kinds: JSON.parse(r.kinds).sort().join(',') }));
const folds = (fx) => fx.calls.filter((c) => /INSERT INTO wake_repo_last/.test(c.sql));

test('S1: the summary folds every repo into wake_repo_last and answers last_id, last_at, sorted kinds, no n', async (t) => {
  const fx = await fixture(t);
  if (!fx) return;
  fx.add('o/a', 'push', iso(3 * H));
  const a2 = fx.add('o/a', 'pr', iso(2 * H));
  const b1 = fx.add('o/b', 'checks', iso(1 * H));
  const a3 = fx.add('o/a', 'push', iso(4 * H));
  const c1 = fx.add('o/c', 'pr', iso(5 * H));
  const r = await summary(fx);
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.deepEqual(table(fx), [
    { repo: 'o/a', last_id: a3, last_at: iso(2 * H), kinds: 'pr,push' },
    { repo: 'o/b', last_id: b1, last_at: iso(1 * H), kinds: 'checks' },
    { repo: 'o/c', last_id: c1, last_at: iso(5 * H), kinds: 'pr' },
  ], 'last_id is the newest id and last_at the newest time, each on its own');
  assert.ok(a2 < a3);
  assert.deepEqual(r.body.repos, [
    { repo: 'o/a', last_id: a3, last_at: iso(2 * H), kinds: 'pr,push' },
    { repo: 'o/b', last_id: b1, last_at: iso(1 * H), kinds: 'checks' },
    { repo: 'o/c', last_id: c1, last_at: iso(5 * H), kinds: 'pr' },
  ]);
  assert.ok(r.body.repos.every((x) => !('n' in x)), 'no per-window count');
  assert.equal(r.body.hours, 24);
  fx.db.close();
});

test('S2: a second call with no new wake changes nothing; a new wake moves only its repo', async (t) => {
  const fx = await fixture(t);
  if (!fx) return;
  fx.add('o/a', 'push', iso(3 * H));
  fx.add('o/b', 'pr', iso(2 * H));
  await summary(fx);
  const before = table(fx);
  fx.calls.length = 0;
  await summary(fx);
  assert.equal(folds(fx).length, 1);
  assert.equal(folds(fx)[0].changes, 0, 'no new wake: the fold changes 0 rows');
  assert.deepEqual(table(fx), before);

  const b2 = fx.add('o/b', 'checks', iso(0.5 * H));
  fx.calls.length = 0;
  const r = await summary(fx);
  assert.equal(folds(fx)[0].changes, 1, 'one repo moved');
  const after = table(fx);
  assert.deepEqual(after[0], before[0], 'o/a did not move');
  assert.deepEqual(after[1], { repo: 'o/b', last_id: b2, last_at: iso(0.5 * H), kinds: 'checks,pr' });
  assert.equal(r.body.repos.find((x) => x.repo === 'o/b').last_id, b2);
  fx.db.close();
});

test('S3: the answer reads only wake_repo_last; the fold reads wakes by rowid range on the volume DB', async (t) => {
  const fx = await fixture(t);
  if (!fx) return;
  fx.add('o/a', 'push', iso(3 * H));
  await summary(fx);
  const reads = fx.calls.filter((c) => /^SELECT/.test(c.sql));
  assert.equal(reads.length, 1, reads.map((c) => c.sql).join(' | '));
  assert.match(reads[0].sql, /FROM wake_repo_last/);
  assert.doesNotMatch(reads[0].sql, /\bwakes\b/, 'the answer never reads wakes');
  assert.ok(!fx.calls.some((c) => /GROUP BY repo/.test(c.sql) && !/WITH w AS MATERIALIZED/.test(c.sql)),
    'no GROUP BY over wakes outside the rowid-range CTE');
  fx.db.close();

  const vol = await openVolumeDb();
  if (!vol) return;
  const log = [];
  // capturingD1 logs reads only; the fold is a run(), so take its text from the fixture call above.
  const foldSql = folds(fx)[0].sql;
  const res = await worker.fetch(new Request('https://jobs.test/api/wakes/summary?hours=1', {
    headers: { authorization: `Bearer ${SECRET}` },
  }), { DB: capturingD1(vol.db, log), HARNESS_SECRET: SECRET });
  assert.equal(res.status, 200);
  assert.equal(Number(vol.db.prepare('SELECT COUNT(*) n FROM wake_repo_last').get().n), 13,
    'the first fold on the volume DB wrote one row per repo');
  const lines = plan(vol.db, foldSql);
  assert.ok(lines.some((l) => /SEARCH wakes USING INTEGER PRIMARY KEY \(rowid>\?\)/.test(l)), lines.join(' | '));
  assert.deepEqual(fullScans(lines, ['wakes']), [], lines.join(' | '));
  assert.ok(lines.some((l) => /idx_wake_repo_last_last_id/.test(l)), lines.join(' | '));
  const read = log.filter((r) => /FROM wake_repo_last WHERE last_at/.test(r.sql));
  assert.equal(read.length, 1);
  const rl = plan(vol.db, read[0].sql, ...read[0].binds);
  assert.ok(!rl.some((l) => /\bwakes\b/.test(l)), rl.join(' | '));
  vol.db.close();
});

test('S4: ?hours=1 hides a repo whose last_at is 30 h old; hours still clamps to 1..168', async (t) => {
  const fx = await fixture(t);
  if (!fx) return;
  fx.add('o/new', 'push', iso(0.5 * H));
  fx.add('o/old', 'push', iso(30 * H));
  const one = await summary(fx, '?hours=1');
  assert.deepEqual(one.body.repos.map((x) => x.repo), ['o/new']);
  const wide = await summary(fx, '?hours=48');
  assert.deepEqual(wide.body.repos.map((x) => x.repo), ['o/new', 'o/old']);
  assert.equal((await summary(fx, '?hours=999')).body.hours, 168);
  assert.equal((await summary(fx, '?hours=0')).body.hours, 1);
  fx.db.close();
});

// The worker does not catch a statement that throws: workerd answers the
// uncaught throw with a 500, so here the fetch rejects.
test('S5: a fold that throws fails the call and leaves wake_repo_last unchanged', async (t) => {
  const fx = await fixture(t);
  if (!fx) return;
  fx.add('o/a', 'push', iso(1 * H));
  await summary(fx);
  const before = table(fx);
  fx.add('o/a', 'pr', iso(0.5 * H));
  fx.hooks.beforeRun = (sql) => {
    if (/INSERT INTO wake_repo_last/.test(sql)) throw new Error('D1_ERROR: overloaded');
  };
  await assert.rejects(() => summary(fx), /D1_ERROR: overloaded/);
  fx.hooks.beforeRun = null;
  assert.deepEqual(table(fx), before);
  fx.db.close();
});
