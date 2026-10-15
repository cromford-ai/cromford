import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import worker from '../src/index.js';
import { CREATED_TABLES, ensureTable } from '../src/lib/core.js';
import { jobsSchemaSql } from './lib/jobs-schema.js';

// POST /api/wakes/prune + the index the summary reads (BH-1267 item 2).
//
// `wakes` had indexes on (repo,kind,key,minute) and (acked_at,id) and nothing
// ever deleted a row, while GET /api/wakes/summary filters `WHERE at >= ?1`
// every day for every fleet repo. So the daily read got slower for ever over a
// table that only grows. This ticket adds `idx_wakes_at` and a BOUNDED
// retention prune the doorbell lane calls once a day.
//
// THE DELETE IS IRREVERSIBLE, so the negatives are the point: a missing, zero,
// fractional, string or out-of-range `days` must answer 400 and run no
// statement at all — never a default, never a clamp (D11). Every assertion
// below is on rows LEFT in a node:sqlite database that had schema.sql applied
// and on the list of statements the route actually executed, driven through
// `worker.fetch` — the production entry (D2/D3).

const SCHEMA = jobsSchemaSql();
const SECRET = 'test-secret';
const now = Date.now();  // determinism: ok the single anchor; every fixture below is iso(msAgo) off it
const H = 3600e3;
const D = 24 * H;
const iso = (msAgo) => new Date(now - msAgo).toISOString().replace(/\.\d{3}Z$/, 'Z');

// The same D1-shaped adapter tests/wakes-summary.bh-1034 uses: `all` answers
// {results}, `run` answers {meta:{changes}}, and every statement is recorded so
// "a 400 ran nothing" is an assertion and not a hope.
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

async function sqlite(t) {
  try {
    const { DatabaseSync } = await import('node:sqlite');
    return DatabaseSync;
  } catch {
    t.skip('node:sqlite unavailable on this runtime');
    return null;
  }
}

// rows: [{repo,kind,key,at}] — inserted through schema.sql's own columns.
async function fixture(t, rows, { schema = true } = {}) {
  const DatabaseSync = await sqlite(t);
  if (!DatabaseSync) return null;
  const db = new DatabaseSync(':memory:');
  if (schema) {
    db.exec(SCHEMA);
    const ins = db.prepare('INSERT INTO wakes (repo, kind, key, event, minute, at) VALUES (?,?,?,?,?,?)');
    for (const r of rows) ins.run(r.repo, r.kind, r.key, r.kind, r.at.slice(0, 16) + ':00Z', r.at);
  }
  const calls = [];
  return { db, calls, DB: d1(db, calls) };
}

const prune = (fx, body, { secret = SECRET } = {}) => {
  const headers = { 'content-type': 'application/json' };
  if (secret !== null) headers.authorization = `Bearer ${secret}`;
  const req = new Request('https://jobs.test/api/wakes/prune', {
    method: 'POST', headers, body: JSON.stringify(body),
  });
  return worker.fetch(req, { DB: fx.DB, HARNESS_SECRET: SECRET })
    .then(async (res) => ({ status: res.status, body: await res.json().catch(() => null) }));
};

const summary = (fx) => worker.fetch(
  new Request('https://jobs.test/api/wakes/summary', {
    method: 'GET', headers: { authorization: `Bearer ${SECRET}` },
  }),
  { DB: fx.DB, HARNESS_SECRET: SECRET },
);

const left = (fx) => fx.db.prepare('SELECT id, key, at FROM wakes ORDER BY id ASC').all();
const indexNames = (db) =>
  db.prepare('PRAGMA index_list(wakes)').all().map((r) => r.name).sort();
const deletes = (fx) => fx.calls.filter((s) => /^DELETE/i.test(s));

const ROWS = [
  { repo: 'example-org/project-3', kind: 'pr',   key: 'fresh',  at: iso(1 * H) },
  { repo: 'example-org/project-3', kind: 'push', key: 'nearly', at: iso(30 * D - H) },
  { repo: 'example-org/project-4',    kind: 'pr',   key: 'old',    at: iso(30 * D + 1000) },
  { repo: 'example-org/project-4',    kind: 'deploy', key: 'older', at: iso(45 * D) },
];

// ── 1. the index is in schema.sql, and schema.sql is re-runnable ────────────
test('prune: schema.sql creates idx_wakes_at and applies twice without error', async (t) => {
  const DatabaseSync = await sqlite(t);
  if (!DatabaseSync) return;
  const db = new DatabaseSync(':memory:');
  db.exec(SCHEMA);
  db.exec(SCHEMA);
  const names = indexNames(db);
  assert.ok(names.includes('idx_wakes_at'),
    `schema.sql must create idx_wakes_at; got ${names.join(', ')}`);
  const cols = db.prepare('PRAGMA index_info(idx_wakes_at)').all().map((r) => r.name);
  assert.deepEqual(cols, ['at'], 'idx_wakes_at must be on (at) — the column the summary filters');
  db.close();
});

// ── 2. the self-create path carries the SAME table and the SAME indexes ─────
test('prune: CREATED_TABLES.wakes matches schema.sql, and is idempotent over an existing database', async (t) => {
  const DatabaseSync = await sqlite(t);
  if (!DatabaseSync) return;
  assert.ok(Array.isArray(CREATED_TABLES.wakes) && CREATED_TABLES.wakes.length,
    'wakes must have a CREATED_TABLES entry — BH-658: a deploy cannot wait on a hand-run d1 execute');

  const fromSchema = new DatabaseSync(':memory:');
  fromSchema.exec(SCHEMA);
  const wantCols = fromSchema.prepare('PRAGMA table_info(wakes)').all()
    .map((r) => `${r.name} ${r.type}${r.notnull ? ' NOT NULL' : ''}${r.pk ? ' PK' : ''}`);
  const wantIdx = indexNames(fromSchema);

  const fresh = new DatabaseSync(':memory:');
  const calls = [];
  await ensureTable({ DB: d1(fresh, calls) }, 'wakes');
  const gotCols = fresh.prepare('PRAGMA table_info(wakes)').all()
    .map((r) => `${r.name} ${r.type}${r.notnull ? ' NOT NULL' : ''}${r.pk ? ' PK' : ''}`);
  assert.deepEqual(gotCols, wantCols, 'the self-created table must have schema.sql\'s columns');
  assert.deepEqual(indexNames(fresh), wantIdx, 'the self-created table must have schema.sql\'s indexes');
  assert.ok(wantIdx.includes('idx_wakes_at'), 'and idx_wakes_at must be one of them');

  // …and running it again over a database schema.sql already built changes nothing.
  await ensureTable({ DB: d1(fromSchema, []) }, 'wakes');
  assert.deepEqual(indexNames(fromSchema), wantIdx, 'a second create must not add or drop an index');
  assert.ok(CREATED_TABLES.wakes.every((s) => /IF NOT EXISTS/i.test(s)),
    'every self-create statement is IF NOT EXISTS');
  assert.ok(!CREATED_TABLES.wakes.some((s) => /\bDROP\b/i.test(s)),
    'additive only — never a DROP');
  fromSchema.close(); fresh.close();
});

// ── 3. the prune's OWN statement, explained, reaches for the new index ──────
// The index has to EARN its write cost, so this explains the statement the
// route actually executed, not one retyped here.
//
// MEASURED, and worth writing down because the plan file guessed otherwise: the
// SUMMARY's `at >= ?1 GROUP BY repo ORDER BY repo` keeps choosing
// idx_wakes_dedupe with or without ANALYZE, because that index already delivers
// repo order and saves the sort. Ordering the prune by `id` was also a plain
// SCAN. `ORDER BY at` is what makes idx_wakes_at a covering search, and age is
// the ordering retention means anyway.
test('prune: the DELETE the route runs is a covering index search on idx_wakes_at', async (t) => {
  const fx = await fixture(t, ROWS);
  if (!fx) return;
  await prune(fx, { days: 30 });
  const sub = fx.calls.find((s) => /SELECT id FROM wakes WHERE at < /.test(s));
  assert.ok(sub, `the prune must filter on at; statements were: ${fx.calls.join(' | ')}`);
  const plan = fx.db.prepare(`EXPLAIN QUERY PLAN ${sub}`).all(iso(30 * D), 5)
    .map((r) => r.detail).join(' | ');
  assert.match(plan, /idx_wakes_at/,
    `the prune must be able to use idx_wakes_at, or the index is write cost for nothing; plan was: ${plan}`);
  fx.db.close();
});

// ── 4. the prune itself: old rows go, newer rows stay ───────────────────────
test('prune: days=30 deletes only rows older than 30 days', async (t) => {
  const fx = await fixture(t, ROWS);
  if (!fx) return;
  const r = await prune(fx, { days: 30 });
  assert.equal(r.status, 200);
  assert.equal(r.body.deleted, 2, 'the 30d+1s and 45d rows are the only ones past retention');
  assert.equal(r.body.capped, false);
  assert.equal(r.body.days, 30);
  assert.equal(Date.parse(r.body.as_of) - Date.parse(r.body.before), 30 * D,
    '`before` must be as_of minus the retention window');
  assert.deepEqual(left(fx).map((x) => x.key), ['fresh', 'nearly'],
    'a prune must never reach a row inside the window');
  fx.db.close();
});

// ── 5. the boundary is `<`, not `<=` ────────────────────────────────────────
test('prune: a row exactly at the cutoff is KEPT', async (t) => {
  const fx = await fixture(t, []);
  if (!fx) return;
  // Ask first with an empty table so `before` is known, then plant a row on it.
  const probe = await prune(fx, { days: 30 });
  const edge = probe.body.before;
  fx.db.prepare('INSERT INTO wakes (repo, kind, key, event, minute, at) VALUES (?,?,?,?,?,?)')
    .run('example-org/project-3', 'pr', 'edge', 'pr', edge.slice(0, 16) + ':00Z', edge);
  const r = await prune(fx, { days: 30 });
  assert.equal(r.body.deleted, 0, `a row at exactly ${edge} is inside retention and must survive`);
  assert.deepEqual(left(fx).map((x) => x.key), ['edge']);
  fx.db.close();
});

// ── 6. the cap is a BOUND, and it says so (D12) ─────────────────────────────
test('prune: limit caps the sweep, reports capped, and takes the OLDEST rows first', async (t) => {
  // Inserted youngest-first on purpose, so id order and age order disagree: a
  // cap that took "the first rows inserted" would leave the oldest rows behind
  // for ever, which is the one shape a bounded retention sweep must not have.
  const rows = [];
  for (let i = 0; i < 7; i++) rows.push({ repo: 'example-org/project-4', kind: 'pr', key: `age${40 + i}d`, at: iso((40 + i) * D) });
  const fx = await fixture(t, rows);
  if (!fx) return;
  const a = await prune(fx, { days: 30, limit: 3 });
  assert.equal(a.body.deleted, 3);
  assert.equal(a.body.capped, true, 'a sweep that hit its cap must say so — the backlog is not drained');
  assert.equal(a.body.limit, 3);
  assert.deepEqual(left(fx).map((x) => x.key), ['age40d', 'age41d', 'age42d', 'age43d'],
    'the three OLDEST rows go first, not the three lowest ids');
  const b = await prune(fx, { days: 30, limit: 3 });
  assert.equal(b.body.deleted, 3);
  assert.equal(b.body.capped, true);
  const c = await prune(fx, { days: 30, limit: 3 });
  assert.equal(c.body.deleted, 1);
  assert.equal(c.body.capped, false, 'the run that drains the backlog is not capped');
  assert.deepEqual(left(fx), []);
  fx.db.close();
});

// ── 7. every bad `days` and `limit` is a 400 that ran NO statement ──────────
test('prune: a missing, zero, negative, fractional, string or oversized days deletes nothing', async (t) => {
  const BAD = [
    [{}, 'days'],
    [{ days: null }, 'days'],
    [{ days: 0 }, 'days'],
    [{ days: -1 }, 'days'],
    [{ days: 1.5 }, 'days'],
    [{ days: '30' }, 'days'],
    [{ days: '30 ' }, 'days'],
    [{ days: '1e2' }, 'days'],
    [{ days: {} }, 'days'],
    [{ days: 3651 }, 'days'],
    [{ days: 30, limit: 0 }, 'limit'],
    [{ days: 30, limit: 5001 }, 'limit'],
    [{ days: 30, limit: 'x' }, 'limit'],
    [{ days: 30, limit: 2.5 }, 'limit'],
  ];
  for (const [body, field] of BAD) {
    const fx = await fixture(t, ROWS);
    if (!fx) return;
    const r = await prune(fx, body);
    assert.equal(r.status, 400, `${JSON.stringify(body)} must be refused, not defaulted`);
    assert.match(String(r.body.error), new RegExp(field), `the 400 must name the field: ${JSON.stringify(r.body)}`);
    assert.deepEqual(deletes(fx), [], `${JSON.stringify(body)} ran a DELETE: ${fx.calls.join(' | ')}`);
    assert.equal(left(fx).length, ROWS.length, `${JSON.stringify(body)} changed the table`);
    fx.db.close();
  }
});

// ── 8. no bearer and a wrong bearer are 401, and neither touches the DB ─────
test('prune: 401 before any statement', async (t) => {
  const fx = await fixture(t, ROWS);
  if (!fx) return;
  assert.equal((await prune(fx, { days: 30 }, { secret: null })).status, 401);
  assert.equal((await prune(fx, { days: 30 }, { secret: 'nope' })).status, 401);
  assert.equal(fx.calls.length, 0, 'an unauthenticated request must not run a statement');
  assert.equal(left(fx).length, ROWS.length);
  fx.db.close();
});

// ── 9. nothing to prune is an ANSWER ────────────────────────────────────────
test('prune: an empty table is 200 deleted:0, never a 404 or a throw', async (t) => {
  const fx = await fixture(t, []);
  if (!fx) return;
  const r = await prune(fx, { days: 30 });
  assert.equal(r.status, 200);
  assert.equal(r.body.deleted, 0);
  assert.equal(r.body.capped, false);
  fx.db.close();
});

// ── 10. a database that never got schema.sql self-creates (BH-658) ──────────
test('prune: a database with no wakes table self-creates it and answers 200', async (t) => {
  const fx = await fixture(t, [], { schema: false });
  if (!fx) return;
  const r = await prune(fx, { days: 30 });
  assert.equal(r.status, 200, `a missing table must not 500: ${JSON.stringify(r.body)}`);
  assert.equal(r.body.deleted, 0);
  const names = indexNames(fx.db);
  // BH-6727 added idx_wakes_repo_id (schema.d/202610141900) and BH-6799 added
  // idx_wakes_kind_id and idx_wakes_repo_lc_id (schema.d/202610150809): the
  // self-create carries them too.
  assert.deepEqual(names, ['idx_wakes_at', 'idx_wakes_dedupe', 'idx_wakes_kind_id', 'idx_wakes_repo_id',
    'idx_wakes_repo_lc_id', 'idx_wakes_unacked'],
    `the self-create must bring every index with it; got ${names.join(', ')}`);
  fx.db.close();
});

// ── 11. the dedupe index is a dedupe of LIVE rows, not a tombstone ──────────
test('prune: a pruned (repo,kind,key,minute) can be inserted again', async (t) => {
  const fx = await fixture(t, ROWS);
  if (!fx) return;
  await prune(fx, { days: 30 });
  const at = iso(1000);
  const old = ROWS[3];
  fx.db.prepare('INSERT INTO wakes (repo, kind, key, event, minute, at) VALUES (?,?,?,?,?,?)')
    .run(old.repo, old.kind, old.key, old.kind, at.slice(0, 16) + ':00Z', at);
  assert.equal(left(fx).filter((x) => x.key === 'older').length, 1,
    'a redelivery 30 days later is a new delivery and must be recordable');
  fx.db.close();
});
