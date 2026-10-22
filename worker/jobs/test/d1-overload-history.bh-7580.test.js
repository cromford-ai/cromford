// BH-7580 (Sentry CROMFORD-HARNESS-1E): a D1 overload that outlasts
// withD1Retry on a history route answered a thrown 500 and a Sentry event, and
// readHistory sent its D1 reads with no bound on how many ran at once.
//
//   P1-P2  the retry contract, pinned through readHistory over retryingDb.
//   C1-C7  historyReadGate: at most HISTORY_READ_CONCURRENCY reads in flight
//          per binding in one request (raw binding and its retryingDb proxy
//          share one gate; env.DB and env.ARCHIVE have separate gates; a
//          request whose reads never settle does not block a later request).
//   R1-R5  the REAL worker.fetch: an overload give-up on the 6 history routes
//          answers a retryable 503, not a throw.
//   N1     every other error still throws the same object (withSentry sees it).
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import * as archiveRead from '../src/lib/archive-read.js';
import { retryingDb } from '../src/lib/d1-retry.js';
import { openDb, d1 } from './lib/d1-sqlite.bh-1030.js';

// A namespace import, so the file loads on a tree without the gate and each
// case fails on its own assertion.
const { readHistory } = archiveRead;
const HISTORY_READ_CONCURRENCY = archiveRead.HISTORY_READ_CONCURRENCY;

const SECRET = 'test-secret-fixture';
const OVERLOAD = 'D1_ERROR: D1 DB is overloaded. Requests queued for too long.';
const OVERLOAD_QUEUED = 'D1_ERROR: D1 DB is overloaded. Too many requests queued.';
const NOW = '2026-10-19T16:45:00Z';
const DAYS_AGO_30 = '2026-09-19T16:45:00Z';

const delay = (ms) => new Promise((r) => setTimeout(r, ms));

// A D1-shaped binding. `fail(sql, n)` returns an error to throw for the n-th
// call of that statement (or null); `answer(sql, method)` the result. Each
// call is counted and its time in flight tracked; `shared` is a counter object
// that more than one stub can update (C2).
function stubDb({ fail = () => null, answer = () => ({ results: [] }), hold = 0, shared = null } = {}) {
  const s = { calls: 0, inFlight: 0, max: 0 };
  const exec = async (sql, method) => {
    const n = (s.calls += 1);
    s.inFlight += 1; s.max = Math.max(s.max, s.inFlight);
    if (shared) { shared.inFlight += 1; shared.max = Math.max(shared.max, shared.inFlight); }
    try {
      if (hold) await delay(hold);
      const e = fail(sql, n);
      if (e) throw e;
      return answer(sql, method);
    } finally {
      s.inFlight -= 1;
      if (shared) shared.inFlight -= 1;
    }
  };
  s.binding = {
    prepare(sql) {
      const st = {
        bind: () => st,
        all: () => exec(sql, 'all'),
        first: () => exec(sql, 'first'),
        run: () => exec(sql, 'run'),
        raw: () => exec(sql, 'raw'),
      };
      return st;
    },
    batch: (stmts) => Promise.all(stmts.map((x) => x.run())),
    exec: (sql) => exec(sql, 'exec'),
  };
  return s;
}

const hot = (n = 0) => ({ sql: `SELECT * FROM cost_rows WHERE n=?1`, binds: [n] });
const hist = (env, n, extra = {}) =>
  readHistory(env, { table: 'cost_rows', since: DAYS_AGO_30, now: NOW, hot: hot(n), ...extra });

// ═══════════════════ P: the retry contract through readHistory ═════════════
test('P1: overload twice, then rows: readHistory resolves the rows after 3 calls', async () => {
  const rows = { results: [{ id: 1 }] };
  const s = stubDb({ fail: (_q, n) => (n <= 2 ? new Error('D1 DB is overloaded') : null), answer: () => rows });
  const r = await hist({ DB: retryingDb(s.binding) }, 1);
  assert.deepStrictEqual(r.hot, rows);
  assert.strictEqual(r.archive, null);
  assert.strictEqual(r.state, 'unbound');
  assert.equal(s.calls, 3);
});

test('P2: a syntax error is not retried: the same error, 1 call, no d1Attempts', async () => {
  const err = new Error('D1_ERROR: near "SELEC": syntax error');
  const s = stubDb({ fail: () => err });
  await assert.rejects(hist({ DB: retryingDb(s.binding) }, 1), (e) => e === err);
  assert.equal(s.calls, 1);
  assert.equal(err.d1Attempts, undefined);
});

// ═══════════════════ C: the concurrency gate ═══════════════════════════════
test('C1: 10 parallel readHistory calls: at most HISTORY_READ_CONCURRENCY (4) in flight, all resolve', async () => {
  assert.equal(HISTORY_READ_CONCURRENCY, 4);
  const s = stubDb({ hold: 15, answer: (_q, m) => ({ results: [{ m }] }) });
  const env = { DB: retryingDb(s.binding) };
  const out = await Promise.all(Array.from({ length: 10 }, (_, i) => hist(env, i)));
  assert.equal(out.length, 10);
  for (const r of out) assert.deepEqual(r.hot, { results: [{ m: 'all' }] });
  assert.equal(s.calls, 10);
  assert.equal(s.max, HISTORY_READ_CONCURRENCY);
});

test('C2: hot and archive have separate gates: each holds at most 4, together 8', async () => {
  const shared = { inFlight: 0, max: 0 };
  const h = stubDb({ hold: 15, shared });
  const a = stubDb({ hold: 15, shared });
  const env = { DB: retryingDb(h.binding), ARCHIVE: a.binding };
  const out = await Promise.all(Array.from({ length: 6 }, (_, i) => hist(env, i, { reach: 'reach' })));
  for (const r of out) assert.equal(r.state, 'read');
  assert.equal(h.calls, 6);
  assert.equal(a.calls, 6);
  assert.equal(h.max, 4, 'hot binding in flight');
  assert.equal(a.max, 4, 'archive binding in flight');
  assert.equal(shared.max, 8, 'the two bindings do not share one gate');
});

test('C3: a rejected read frees its slot: 5 reads, the 1st rejects, the 5th still runs', async () => {
  const boom = new Error('boom');
  const s = stubDb({ hold: 15, fail: (_q, n) => (n === 1 ? boom : null) });
  const env = { DB: s.binding };
  const res = await Promise.allSettled(Array.from({ length: 5 }, (_, i) => hist(env, i)));
  assert.equal(res[0].status, 'rejected');
  assert.equal(res[0].reason, boom);
  for (const r of res.slice(1)) assert.equal(r.status, 'fulfilled');
  assert.equal(s.calls, 5);
  assert.equal(s.max, 4);
  // The slots are all free again: 4 more reads run together at once.
  await Promise.all(Array.from({ length: 4 }, (_, i) => hist(env, i)));
  assert.equal(s.calls, 9);
});

test('C4: in one request the raw binding and its retryingDb proxy share one gate', async () => {
  const s = stubDb({ hold: 15 });
  const env = { DB: retryingDb(s.binding) };
  const read = (db) => archiveRead.historyReadGate(env, db, () => db.prepare('SELECT 1').all());
  await Promise.all([
    ...Array.from({ length: 3 }, () => read(env.DB)),
    ...Array.from({ length: 3 }, () => read(s.binding)),
  ]);
  assert.equal(s.calls, 6);
  assert.equal(s.max, 4);
});

test('C6: the gate is per request: holders that never settle do not block a later request', async () => {
  // Request A: 4 reads that never settle (a cancelled request never reaches
  // its finally) and 2 waiters behind them. Same raw binding as request B.
  let calls = 0;
  const raw = {
    prepare: (sql) => {
      const st = { bind: () => st, all: () => { calls += 1; return /hang/.test(sql) ? new Promise(() => {}) : Promise.resolve({ results: [{ ok: 1 }] }); } };
      st.first = st.all;
      return st;
    },
  };
  const envA = { DB: retryingDb(raw) };
  for (let i = 0; i < 6; i++) readHistory(envA, { table: 'cost_rows', since: NOW, now: NOW, hot: { sql: 'SELECT hang' } });
  await delay(5);
  assert.equal(calls, 4, 'request A: 4 in flight, 2 waiting');
  // Request B (a new env, as index.js builds per request) completes at once.
  const envB = { DB: retryingDb(raw) };
  const out = await Promise.race([
    Promise.all(Array.from({ length: 5 }, () => readHistory(envB, { table: 'cost_rows', since: NOW, now: NOW, hot: { sql: 'SELECT ok' } }))),
    delay(500).then(() => 'blocked'),
  ]);
  assert.notEqual(out, 'blocked', 'request B waited on request A\'s slots');
  for (const r of out) assert.deepEqual(r.hot, { results: [{ ok: 1 }] });
});

test('C7: through worker.fetch, a request whose reads never settle does not block the next request', async (t) => {
  t.mock.timers.enable({ apis: ['Date'], now: Date.parse(NOW) });
  let hang = true;
  const raw = {
    prepare: (sql) => {
      const st = { bind: () => st, run: () => Promise.resolve({ success: true }) };
      // Only the history reads hang: the ensureColumns probe is memoized per
      // binding, and a hang there is not what this case is about.
      const history = /FROM cost_rows WHERE/.test(sql);
      st.all = st.first = st.raw = () => (hang && history ? new Promise(() => {}) : Promise.resolve({ results: [] }));
      return st;
    },
    batch: (stmts) => Promise.all(stmts.map((x) => x.run())),
    exec: () => Promise.resolve({}),
  };
  const req = () => new Request('https://jobs.test/api/metrics/cost-breakdown', { headers: { authorization: `Bearer ${SECRET}` } });
  // 6 requests hang (their clients would disconnect and the requests be cancelled).
  for (let i = 0; i < 6; i++) worker.fetch(req(), { HARNESS_SECRET: SECRET, DB: raw });
  await delay(5);
  hang = false;
  const res = await Promise.race([worker.fetch(req(), { HARNESS_SECRET: SECRET, DB: raw }), delay(1000).then(() => 'blocked')]);
  assert.notEqual(res, 'blocked', 'a later request waited on the slots of hung requests');
  assert.equal(res.status, 200);
});

test('C5: a slot handed to a waiter stays counted: a late wave still sees at most 4', async () => {
  const s = stubDb({ hold: 40 });
  const env = { DB: s.binding };
  // 6 reads: 4 run, 2 wait. At ~40 ms the 4 end and hand their slots to the
  // 2 waiters. At 50 ms, while those 2 run, a second wave of 4 arrives.
  const first = Array.from({ length: 6 }, (_, i) => hist(env, i));
  await delay(50);
  const second = Array.from({ length: 4 }, (_, i) => hist(env, i));
  await Promise.all([...first, ...second]);
  assert.equal(s.calls, 10);
  assert.equal(s.max, 4);
});

// ═══════════════════ R: the real worker.fetch ══════════════════════════════
// The worker's clock is pinned to NOW (the server takes it once per request).
const pinned = new WeakSet();
async function call(t, env, path) {
  if (!pinned.has(t)) { t.mock.timers.enable({ apis: ['Date'], now: Date.parse(NOW) }); pinned.add(t); }
  return worker.fetch(new Request(`https://jobs.test${path}`, {
    headers: { authorization: `Bearer ${SECRET}` },
  }), { HARNESS_SECRET: SECRET, ...env });
}

async function expect503(t, env, path, table) {
  const warn = t.mock.method(console, 'warn', () => {});
  const res = await call(t, env, path);
  const body = await res.json().catch(() => null);
  assert.equal(res.status, 503, `${path}: ${JSON.stringify(body)}`);
  assert.equal(body.retryable, true);
  assert.equal(body.d1_attempts, 5);
  assert.match(body.detail, /overloaded/);
  assert.equal(body.error, `${table} unavailable`);
  const lines = warn.mock.calls.map((c) => String(c.arguments[0])).filter((l) => l.startsWith('d1-overload:'));
  assert.equal(lines.length, 1, `one d1-overload warn line, got ${JSON.stringify(lines)}`);
  assert.match(lines[0], new RegExp(`^d1-overload: ${table} answered 503 after 5 attempt\\(s\\)$`));
  warn.mock.restore();
}

const always = (msg) => () => new Error(msg);

test('R1: GET /api/metrics/cost-rows, every statement overloaded: 503 retryable, not a throw', async (t) => {
  const s = stubDb({ fail: always(OVERLOAD) });
  await expect503(t, { DB: s.binding }, '/api/metrics/cost-rows', 'cost_rows');
});

test('R2: the "Too many requests queued." overload text is a 503 too', async (t) => {
  const s = stubDb({ fail: always(OVERLOAD_QUEUED) });
  await expect503(t, { DB: s.binding }, '/api/metrics/cost-rows?limit=5', 'cost_rows');
});

test('R3: GET /api/jobs/:id, the job row reads and the stage_events history read gives up: 503', async (t) => {
  const s = stubDb({
    fail: (sql) => (/stage_events/.test(sql) ? new Error(OVERLOAD) : null),
    answer: (sql, m) => (m === 'first' ? { id: 'job-1', created_at: NOW, status: 'running' } : { results: [] }),
  });
  await expect503(t, { DB: s.binding }, '/api/jobs/job-1', 'stage_events');
});

test('R4: the archive alone overloaded: 200 with archive "unreadable", no 503', async (t) => {
  const o = await openDb();
  assert.ok(o, 'node:sqlite is required');
  const arch = stubDb({ fail: always(OVERLOAD) });
  t.mock.method(console, 'log', () => {});
  const path = `/api/metrics/cost-rows?since=${DAYS_AGO_30}`; // determinism: ok call() pins the worker's Date to NOW; DAYS_AGO_30 is NOW - 30 days
  const res = await call(t, { DB: d1(o.db), ARCHIVE: arch.binding }, path);
  const body = await res.json();
  assert.equal(res.status, 200, JSON.stringify(body));
  assert.equal(body.archive, 'unreadable');
  assert.deepEqual(body.cost_rows, []);
});

const OTHER_ROUTES = [
  '/api/metrics/llm-spend?lane=x',
  '/api/metrics/cost-breakdown',
  // The route answers 400 without stages or a real day (not after NOW's day).
  `/api/metrics/outcome-gap?stages=build&day=${NOW.slice(0, 10)}`,
  `/api/metrics/cost-anchored?day=${NOW.slice(0, 10)}`,
];

for (const path of OTHER_ROUTES) {
  test(`R5: ${path}, every statement overloaded: 503 retryable`, async (t) => {
    const s = stubDb({ fail: always(OVERLOAD) });
    await expect503(t, { DB: s.binding }, path, 'cost_rows');
  });
}

// ═══════════════════ N: every other error still throws ═════════════════════
const NOT_OVERLOAD = [
  'D1_ERROR: near "SELEC": syntax error',
  'D1_ERROR: no such table: cost_rows',
  'DB is overloaded',
];

for (const msg of NOT_OVERLOAD) {
  for (const path of ['/api/metrics/cost-rows', '/api/jobs/job-1', ...OTHER_ROUTES]) {
    test(`N1: ${path} with "${msg}": worker.fetch rejects with the same error`, async (t) => {
      const err = new Error(msg);
      const s = stubDb({ fail: () => err });
      t.mock.method(console, 'warn', () => {});
      t.mock.method(console, 'log', () => {});
      await assert.rejects(call(t, { DB: s.binding }, path), (e) => e === err);
    });
  }
}
