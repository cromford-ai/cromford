// BH-7764 (Sentry CROMFORD-HARNESS-1P): gateFacts gave up on a D1 overload
// and the throw reached Sentry. The query ran 14 correlated subqueries per PR
// (one latest() per GATE_FIELDS column plus url, and the approved_at MIN), so
// every call read the repo's gate rows up to 14 times over.
//
//   E1     the new one-read fold equals the OLD SQL's output (values and key
//          order) on a seeded mix of every fold case.
//   X1     EXPLAIN QUERY PLAN of the SQL gateFacts prepares, at volume: one
//          SEARCH on idx_pr_state_events_gate, no SCAN, no correlated
//          subquery, no temp b-tree.
//   P1-P2  the retry contract on the gateFacts statement through retryingDb.
//   F1-F3  the REAL worker.fetch: an overload give-up on the two gate routes
//          answers 503 retryable with one warn line and no Sentry envelope;
//          any other error still throws to withSentry.
//   B1     no fetch to any host but the fixture Sentry DSN across the file.
//
// Each case seeds its own repo name (o/bh7764-<case>), so cases share no rows.
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { GATE_FIELDS, gateFacts } from '../src/lib/pr-gate.js';
import { retryingDb } from '../src/lib/d1-retry.js';
import { ensureColumns } from '../src/lib/core.js';
import { openDb, d1 } from './lib/d1-sqlite.bh-1030.js';
import { plan, fullScans } from './lib/d1-volume.bh-6727.js';

const SECRET = 'test-secret-fixture';
const DSN = 'https://fixturepubkey@sentry.test/7764';
const OVERLOAD = 'D1_ERROR: D1 DB is overloaded. Requests queued for too long.';
const SYNTAX = 'D1_ERROR: near "SELEC": syntax error';

// B1: one fetch spy for the whole file. Sentry envelopes and any other host
// are counted apart; nothing leaves the process.
const realFetch = globalThis.fetch;
const sent = { sentry: [], other: [] };
globalThis.fetch = async (url) => {
  (String(url).includes('sentry.test') ? sent.sentry : sent.other).push(String(url));
  return new Response('{}', { status: 200 });
};
test.after(() => { globalThis.fetch = realFetch; });

// The pre-BH-7764 query, verbatim, as the reference for E1.
const oldLatest = (f) =>
  `(SELECT e.${f} FROM pr_state_events e WHERE e.repo=p.repo AND e.number=p.number
     AND e.state='gate' AND e.${f} IS NOT NULL ORDER BY e.id DESC LIMIT 1) AS ${f}`;
const OLD_SQL =
  `SELECT f.*, (SELECT MIN(e.at) FROM pr_state_events e WHERE e.repo=f.repo AND e.number=f.number
                  AND e.state='gate' AND e.builder_approved_sha=f.builder_approved_sha) AS approved_at
     FROM (SELECT p.repo, p.number, ${[...GATE_FIELDS, 'url'].map(oldLatest).join(', ')}
             FROM (SELECT DISTINCT repo, number FROM pr_state_events WHERE state='gate' AND repo=?1) p) f
    ORDER BY f.number`;

let seq = 0;
function insert(db, repo, number, state, at, fields = {}) {
  seq += 1;
  const cols = ['repo', 'number', 'state', 'since', 'alerted', 'at', ...Object.keys(fields)];
  const vals = [repo, number, state, `src-${seq}`, '-', at, ...Object.values(fields)];
  db.prepare(`INSERT INTO pr_state_events (${cols.join(', ')}) VALUES (${cols.map(() => '?').join(',')})`).run(...vals);
}

async function sqlite(t) {
  const o = await openDb();
  if (!o) { t.skip('node:sqlite is absent'); return null; }
  // The gate columns are added by ensureColumns, as on the live table.
  await ensureColumns({ DB: o.DB }, 'pr_state_events');
  return o;
}

// ═══════════════════ E: the fold equals the old SQL ═════════════════════════
test('E1: gateFacts equals the old correlated-subquery SQL, values and key order', async (t) => {
  const o = await sqlite(t);
  if (!o) return;
  const { db } = o;
  const R = 'o/bh7764-e1';
  const T = (m) => `2026-10-20T10:${String(m).padStart(2, '0')}:00Z`;
  // PR 30 inserted first: the output order is by number, not insert order.
  insert(db, R, 30, 'gate', T(1), { head: 'h30', draft: 1 });
  // PR 10: set, then null (no news), then overwritten; re-sent approve sha
  // with a LATER at keeps the earliest at; a non-gate row is ignored.
  insert(db, R, 10, 'gate', T(5), { head: 'a1', builder_approved_sha: 'a1', ci_green_sha: 'a1', url: 'https://x/10' });
  insert(db, R, 10, 'gate', T(6), { held: 1 });
  insert(db, R, 10, 'open', T(7), { head: 'zzz', url: 'https://wrong' });
  insert(db, R, 10, 'gate', T(8), { held: 0, lead_verdict_word: 'APPROVE', lead_verdict_sha: 'a1' });
  insert(db, R, 10, 'gate', T(9), { builder_approved_sha: 'a1' });
  // PR 20: approve sha changes; approved_at is the earliest at of the NEW sha.
  insert(db, R, 20, 'gate', T(10), { head: 'b1', builder_approved_sha: 'b1' });
  insert(db, R, 20, 'gate', T(11), { head: 'b2' });
  insert(db, R, 20, 'gate', T(13), { builder_approved_sha: 'b2', hotfix: 1, nudged_sha: 'b2' });
  insert(db, R, 20, 'gate', T(12), { reviewing_sha: 'b2', review_failed_sha: 'b1', closed: 0 });
  // PR 40: no approve sha at all -> approved_at null; every other field null.
  insert(db, R, 40, 'gate', T(14), {});
  // PR 50: only non-gate rows -> absent.
  insert(db, R, 50, 'open', T(15), { head: 'c1' });
  // Another repo's gate rows -> absent.
  insert(db, 'o/bh7764-e1-other', 10, 'gate', T(2), { head: 'other', builder_approved_sha: 'other' });

  const want = db.prepare(OLD_SQL).all(R).map((r) => ({ ...r }));
  const got = await gateFacts({ DB: d1(db) }, { repo: R });
  assert.equal(want.length, 4, 'the seed has 4 PRs with gate rows');
  assert.deepEqual(got.map((r) => ({ ...r })), want);
  for (let i = 0; i < want.length; i++) assert.deepEqual(Object.keys(got[i]), Object.keys(want[i]));
  // Spot-check the cases the seed is built for, so a wrong reference fails too.
  const by = Object.fromEntries(got.map((r) => [r.number, r]));
  assert.deepEqual(got.map((r) => r.number), [10, 20, 30, 40]);
  assert.equal(by[10].held, 0);
  assert.equal(by[10].head, 'a1');
  assert.equal(by[10].url, 'https://x/10');
  assert.equal(by[10].approved_at, T(5));
  assert.equal(by[20].approved_at, T(13));
  assert.equal(by[20].head, 'b2');
  assert.equal(by[40].approved_at, null);
  assert.equal(by[40].head, null);
});

// ═══════════════════ X: the plan at volume ═════════════════════════════════
test('X1: EXPLAIN QUERY PLAN of gateFacts at 72,000 rows: one index SEARCH, no scan, no correlated subquery', async (t) => {
  const o = await sqlite(t);
  if (!o) return;
  const { db } = o;
  // 4 repos x 2,000 PRs x (6 gate + 3 conductor rows).
  db.exec('BEGIN');
  const ins = db.prepare(`INSERT INTO pr_state_events (repo, number, state, since, alerted, at, head)
                          VALUES (?,?,?,?,'-',?,?)`);
  let n = 0;
  for (let r = 0; r < 4; r++) {
    for (let p = 1; p <= 2000; p++) {
      for (let k = 0; k < 9; k++) {
        n += 1;
        ins.run(`o/bh7764-x1-${r}`, p, k < 6 ? 'gate' : 'open', `s${n}`, '2026-10-20T00:00:00Z', `h${p}-${k}`);
      }
    }
  }
  db.exec('COMMIT');
  db.exec('ANALYZE');
  assert.equal(db.prepare('SELECT COUNT(*) AS c FROM pr_state_events').get().c, 72000);

  const log = [];
  const inner = d1(db);
  const DB = {
    prepare(sql) {
      const s = inner.prepare(sql);
      const api = {
        bind(...v) { s.bind(...v); if (/FROM pr_state_events/.test(sql) && /state='gate'/.test(sql)) log.push({ sql, binds: v }); return api; },
        first: (c) => s.first(c), all: () => s.all(), run: () => s.run(),
      };
      return api;
    },
    batch: (x) => inner.batch(x),
    exec: (x) => inner.exec(x),
  };
  const rows = await gateFacts({ DB }, { repo: 'o/bh7764-x1-2' });
  assert.equal(rows.length, 2000);
  assert.equal(log.length, 1, 'gateFacts prepares exactly one gate read');
  const lines = plan(db, log[0].sql, ...log[0].binds);
  const all = lines.join('\n');
  assert.ok(lines.some((l) => /^SEARCH pr_state_events USING (COVERING )?INDEX idx_pr_state_events_gate \(repo=\? AND state=\?\)/.test(l)), all);
  assert.deepEqual(fullScans(lines, ['pr_state_events']), [], all);
  assert.doesNotMatch(all, /CORRELATED/, all);
  assert.doesNotMatch(all, /TEMP B-TREE/, all);
});

// ═══════════════════ P: the retry contract ═════════════════════════════════
// A D1-shaped stub that serves the gateFacts read; `fail(sql, n)` returns the
// error for the n-th call of any statement (or null).
function stubDb(fail) {
  const s = { calls: 0, gateCalls: 0 };
  const exec = async (sql) => {
    s.calls += 1;
    const gate = /state='gate'/.test(sql);
    if (gate) s.gateCalls += 1;
    const e = fail(sql, gate ? s.gateCalls : s.calls);
    if (e) throw e;
    return { results: [], meta: { changes: 0 } };
  };
  s.binding = {
    prepare(sql) {
      const st = { bind: () => st, all: () => exec(sql), first: () => exec(sql).then(() => null), run: () => exec(sql), raw: () => exec(sql).then(() => []) };
      return st;
    },
    batch: (stmts) => Promise.all(stmts.map((x) => x.run())),
    exec: (sql) => exec(sql),
  };
  return s;
}

test('P1: the gate read overloaded twice, then rows: gateFacts returns them after 3 gate calls', async () => {
  const s = stubDb((sql, n) => (/state='gate'/.test(sql) && n <= 2 ? new Error(OVERLOAD) : null));
  const rows = await gateFacts({ DB: retryingDb(s.binding) }, { repo: 'o/bh7764-p1' });
  assert.deepEqual(rows, []);
  assert.equal(s.gateCalls, 3);
});

test('P2: a syntax error on the gate read is not retried: the same error, 1 gate call', async () => {
  const err = new Error(SYNTAX);
  const s = stubDb((sql) => (/state='gate'/.test(sql) ? err : null));
  await assert.rejects(gateFacts({ DB: retryingDb(s.binding) }, { repo: 'o/bh7764-p2' }), (e) => e === err);
  assert.equal(s.gateCalls, 1);
});

// ═══════════════════ F: the real worker.fetch ══════════════════════════════
class Ctx {
  constructor() { this.waits = []; }
  waitUntil(p) { this.waits.push(Promise.resolve(p).catch(() => {})); }
  passThroughOnException() {}
}
const settle = () => new Promise((r) => setTimeout(r, 300));

async function call(DB, path) {
  const ctx = new Ctx();
  try {
    const res = await worker.fetch(new Request(`https://jobs.test${path}`, {
      headers: { authorization: `Bearer ${SECRET}` },
    }), { DB, HARNESS_SECRET: SECRET, HARNESS_SENTRY_DSN: DSN, HARNESS_SENTRY_MAX_PER_FP_HOUR: '1000' }, ctx);
    return { status: res.status, body: await res.json().catch(() => null) };
  } catch (e) {
    return { status: 'thrown', error: e };
  } finally {
    await Promise.all(ctx.waits);
  }
}

const ROUTES = (repo) => [`/api/pr-state/gate?repo=${repo}`, `/api/pr-state/needs-review?repo=${repo}`];

for (const [i, path] of ROUTES('o/bh7764-f1').entries()) {
  test(`F1.${i + 1}: ${path.split('?')[0]}, every statement overloaded: 503 retryable, one warn line, no Sentry envelope`, async (t) => {
    const warn = t.mock.method(console, 'warn', () => {});
    const before = sent.sentry.length;
    // Each case its own suffix: the SDK dedupes an event equal to the last one.
    const s = stubDb(() => new Error(`${OVERLOAD} [bh7764 f1.${i}]`));
    const r = await call(s.binding, path);
    await settle();
    assert.equal(r.status, 503, JSON.stringify(r.body ?? String(r.error)));
    assert.equal(r.body.retryable, true);
    assert.equal(r.body.d1_attempts, 5);
    assert.equal(r.body.error, 'pr_state_events unavailable');
    // F3: req.sh retries a 503 once when the body says "overloaded".
    assert.match(JSON.stringify(r.body), /overloaded/);
    const lines = warn.mock.calls.map((c) => String(c.arguments[0])).filter((l) => l.startsWith('d1-overload:'));
    assert.deepEqual(lines, ['d1-overload: pr_state_events answered 503 after 5 attempt(s)']);
    assert.equal(sent.sentry.length - before, 0, 'an overload give-up sends no Sentry envelope');
  });
}

for (const [i, path] of ROUTES('o/bh7764-f2').entries()) {
  test(`F2.${i + 1}: ${path.split('?')[0]}, a syntax error is not a 503: it reaches withSentry`, async (t) => {
    t.mock.method(console, 'error', () => {});
    const before = sent.sentry.length;
    const s = stubDb((sql) => (/state='gate'/.test(sql) ? new Error(`${SYNTAX} [bh7764 f2.${i}]`) : null));
    const r = await call(s.binding, path);
    await settle();
    assert.ok(r.status === 'thrown' || r.status === 500, `got ${r.status} ${JSON.stringify(r.body)}`);
    if (r.status === 'thrown') assert.match(String(r.error.message), /syntax error/);
    assert.equal(s.gateCalls, 1, 'not retried');
    assert.ok(sent.sentry.length - before >= 1, 'the real error is reported to Sentry');
  });
}

test('B1: no fetch to any host other than the fixture Sentry DSN', () => {
  assert.deepEqual(sent.other, []);
});
