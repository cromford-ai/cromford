// BH-9325 (Sentry CROMFORD-HARNESS-23): `DELETE /api/pr-attempts` (bundle
// `routes38`, line 69150) gave up on "D1 DB is overloaded. Too many resources
// consumed within a 10 second window." after withD1Retry's attempts, and the
// throw became a 500 and a Sentry event. req.sh never retries a 500. The five
// sibling handlers of worker/jobs/src/routes/pr-state.js had the same path.
//
//   P1      overloaded twice, then the DELETE succeeds: 200, 3 DELETE calls,
//           no warn line, no Sentry envelope.
//   F1.1-6  every statement overloaded, on each of the six routes: 503
//           retryable, "overloaded" in the body, one warn line, d1_attempts 5,
//           no Sentry envelope.
//   K1      the attempt count is the settings row d1_retry.attempts (3).
//   F2      a syntax error is not retried and still reaches Sentry (D10).
//   X1      EXPLAIN QUERY PLAN of the real pr_attempts statements at 20,000
//           rows: a SEARCH on the primary key, no SCAN.
//   W1      one DELETE removes at most 1 row; a short key deletes nothing.
//   B1      no fetch to any host but the fixture Sentry DSN.
//
// Each case its own repo name (o/bh9325-<case>) and its own stub or database.
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { retryingDb } from '../src/lib/d1-retry.js';
import { settingsRows, invalidateSettings } from '../src/lib/settings-cache.js';
import { openDb, d1 } from './lib/d1-sqlite.bh-1030.js';
import { plan, fullScans } from './lib/d1-volume.bh-6727.js';

const SECRET = 'test-secret-fixture';
const DSN = 'https://fixturepubkey@sentry.test/9325';
const OVERLOAD = 'D1_ERROR: D1 DB is overloaded. Too many resources consumed within a 10 second window.';
const SYNTAX = 'D1_ERROR: near "DELET": syntax error';
const IS_DELETE = (sql) => /^DELETE FROM pr_attempts/.test(sql);

// B1: one fetch spy for the whole file.
const realFetch = globalThis.fetch;
const sent = { sentry: [], other: [] };
globalThis.fetch = async (url) => {
  (String(url).includes('sentry.test') ? sent.sentry : sent.other).push(String(url));
  return new Response('{}', { status: 200 });
};
test.after(() => { globalThis.fetch = realFetch; });

// A D1-shaped stub. `fail(sql, n)` returns the error for the n-th call of that
// SQL text (or null). `settings` answers `SELECT * FROM settings`. The
// stmt-stats knob read always answers sample pct 0, so no request is sampled
// and env.DB stays the one retryingDb proxy (K1 depends on that).
function stubDb(fail, { settings = [], changes = 1 } = {}) {
  const s = { calls: new Map(), deletes: 0 };
  const exec = async (sql, kind) => {
    const n = (s.calls.get(sql) || 0) + 1;
    s.calls.set(sql, n);
    if (/FROM settings WHERE key IN/.test(sql)) return { results: [{ key: 'd1.stmt_stats_sample_pct', value: '0' }], meta: {} };
    if (IS_DELETE(sql)) s.deletes += 1;
    const e = fail(sql, n);
    if (e) throw e;
    if (/^SELECT \* FROM settings/.test(sql)) return { results: settings, meta: {} };
    return { results: [], meta: { changes: kind === 'run' ? changes : 0 } };
  };
  s.binding = {
    prepare(sql) {
      const st = {
        bind: () => st,
        all: () => exec(sql, 'all'),
        first: () => exec(sql, 'first').then(() => null),
        run: () => exec(sql, 'run'),
        raw: () => exec(sql, 'raw').then(() => []),
      };
      return st;
    },
    batch: (stmts) => Promise.all(stmts.map((x) => x.run())),
    exec: (sql) => exec(sql, 'exec'),
  };
  return s;
}

class Ctx {
  constructor() { this.waits = []; }
  waitUntil(p) { this.waits.push(Promise.resolve(p).catch(() => {})); }
  passThroughOnException() {}
}
const settle = () => new Promise((r) => setTimeout(r, 300));

async function call(DB, method, path, body) {
  const ctx = new Ctx();
  try {
    const init = { method, headers: { authorization: `Bearer ${SECRET}` } };
    if (body) { init.body = JSON.stringify(body); init.headers['content-type'] = 'application/json'; }
    const res = await worker.fetch(new Request(`https://jobs.test${path}`, init),
      { DB, HARNESS_SECRET: SECRET, HARNESS_SENTRY_DSN: DSN, HARNESS_SENTRY_MAX_PER_FP_HOUR: '1000' }, ctx);
    return { status: res.status, body: await res.json().catch(() => null) };
  } catch (e) {
    return { status: 'thrown', error: e };
  } finally {
    await Promise.all(ctx.waits);
  }
}

const d1Lines = (warn) => warn.mock.calls.map((c) => String(c.arguments[0])).filter((l) => l.startsWith('d1-overload:'));

// ═══════════════════ P: overloaded twice, then success ═════════════════════
test('P1: DELETE /api/pr-attempts overloaded twice, then a row goes: 200 after 3 DELETE calls, no warn, no Sentry', async (t) => {
  const warn = t.mock.method(console, 'warn', () => {});
  const before = sent.sentry.length;
  const s = stubDb((sql, n) => (IS_DELETE(sql) && n <= 2 ? new Error(`${OVERLOAD} [bh9325 p1]`) : null));
  const r = await call(s.binding, 'DELETE', '/api/pr-attempts?repo=o/bh9325-p1&number=1&kind=k&sha=abc1234');
  await settle();
  assert.equal(r.status, 200, JSON.stringify(r.body ?? String(r.error)));
  assert.equal(r.body.deleted, true);
  assert.equal(s.deletes, 3);
  assert.deepEqual(d1Lines(warn), []);
  assert.equal(sent.sentry.length - before, 0);
});

// ═══════════════════ F1: every statement overloaded, six routes ════════════
const ROUTES = (repo) => [
  ['pr_state_events', 'POST', '/api/pr-state-events', { repo, number: 1, state: 'open', since: 's1' }],
  ['pr_state_events', 'GET', `/api/pr-state-events?repo=${repo}`],
  ['pr_state_events', 'GET', `/api/pr-state?repo=${repo}`],
  ['pr_attempts', 'PUT', '/api/pr-attempts', { repo, number: 1, kind: 'k', sha: 'abc1234' }],
  ['pr_attempts', 'GET', `/api/pr-attempts?repo=${repo}&number=1`],
  ['pr_attempts', 'DELETE', `/api/pr-attempts?repo=${repo}&number=1&kind=k&sha=abc1234`],
];

for (const [i, [table, method, path, body]] of ROUTES('o/bh9325-f1').entries()) {
  test(`F1.${i + 1}: ${method} ${path.split('?')[0]}, every statement overloaded: 503 retryable, one warn line, no Sentry`, async (t) => {
    const warn = t.mock.method(console, 'warn', () => {});
    const before = sent.sentry.length;
    const s = stubDb(() => new Error(`${OVERLOAD} [bh9325 f1.${i}]`));
    const r = await call(s.binding, method, path, body);
    await settle();
    assert.equal(r.status, 503, JSON.stringify(r.body ?? String(r.error)));
    assert.equal(r.body.retryable, true);
    assert.equal(r.body.error, `${table} unavailable`);
    assert.equal(r.body.d1_attempts, 5);
    // req.sh retries a 503 once when the body says "overloaded".
    assert.match(JSON.stringify(r.body), /overloaded/);
    assert.deepEqual(d1Lines(warn), [`d1-overload: ${table} answered 503 after 5 attempt(s)`]);
    assert.equal(sent.sentry.length - before, 0, 'an overload give-up sends no Sentry envelope');
  });
}

// ═══════════════════ K1: the attempt count is the settings row ═════════════
test('K1: with d1_retry.attempts=3 in the settings snapshot, the DELETE gives up after 3 calls: 503, d1_attempts 3', async (t) => {
  const warn = t.mock.method(console, 'warn', () => {});
  const before = sent.sentry.length;
  const s = stubDb((sql) => (IS_DELETE(sql) ? new Error(`${OVERLOAD} [bh9325 k1]`) : null), {
    settings: [{ key: 'd1_retry.attempts', value: '3' }, { key: 'd1_retry.base_ms', value: '10' }],
  });
  const env = { DB: retryingDb(s.binding), SETTINGS_CACHE_TTL_S: '30' };
  await settingsRows(env);
  try {
    const r = await call(s.binding, 'DELETE', '/api/pr-attempts?repo=o/bh9325-k1&number=1&kind=k&sha=abc1234');
    await settle();
    assert.equal(r.status, 503, JSON.stringify(r.body ?? String(r.error)));
    assert.equal(r.body.retryable, true);
    assert.equal(r.body.d1_attempts, 3);
    assert.equal(s.deletes, 3);
    assert.deepEqual(d1Lines(warn), ['d1-overload: pr_attempts answered 503 after 3 attempt(s)']);
    assert.equal(sent.sentry.length - before, 0);
  } finally {
    invalidateSettings(env);
  }
});

// ═══════════════════ F2: a real error still throws ═════════════════════════
test('F2: DELETE with a syntax error is not a 503: 1 call, it reaches withSentry', async (t) => {
  t.mock.method(console, 'error', () => {});
  t.mock.method(console, 'warn', () => {});
  const before = sent.sentry.length;
  const s = stubDb((sql) => (IS_DELETE(sql) ? new Error(`${SYNTAX} [bh9325 f2]`) : null));
  const r = await call(s.binding, 'DELETE', '/api/pr-attempts?repo=o/bh9325-f2&number=1&kind=k&sha=abc1234');
  await settle();
  assert.ok(r.status === 'thrown' || r.status === 500, `got ${r.status} ${JSON.stringify(r.body)}`);
  if (r.status === 'thrown') assert.match(String(r.error.message), /syntax error/);
  assert.equal(s.deletes, 1, 'not retried');
  assert.ok(sent.sentry.length - before >= 1, 'the real error is reported to Sentry');
});

// ═══════════════════ X1 / W1: real SQLite at volume ═════════════════════════
const SEED_ROWS = 20000;
async function seeded(t) {
  const o = await openDb();
  if (!o) { t.skip('node:sqlite is absent'); return null; }
  const { db } = o;
  db.exec('BEGIN');
  const ins = db.prepare('INSERT INTO pr_attempts (repo, number, kind, sha, at, actor) VALUES (?,?,?,?,?,?)');
  for (let r = 0; r < 400; r++) {
    for (let n = 1; n <= 10; n++) {
      for (let k = 0; k < 5; k++) ins.run(`o/bh9325-seed-${r}`, n, `kind${k}`, `sha${r}-${n}-${k}`, '2026-11-09T00:00:00Z', 'seed');
    }
  }
  db.exec('COMMIT');
  db.exec('ANALYZE');
  assert.equal(count(db), SEED_ROWS);
  return o;
}
const count = (db, repo) => (repo
  ? db.prepare('SELECT COUNT(*) AS c FROM pr_attempts WHERE repo=?').get(repo).c
  : db.prepare('SELECT COUNT(*) AS c FROM pr_attempts').get().c);

test('X1: EXPLAIN QUERY PLAN of every pr_attempts statement the routes run, at 20,000 rows: PK SEARCH, no SCAN', async (t) => {
  const o = await seeded(t);
  if (!o) return;
  const { db } = o;
  // Log the exact SQL text and binds of every pr_attempts statement the REAL
  // routes prepare, so the plan is of the deployed text, not a copy.
  const log = [];
  const inner = d1(db);
  const DB = {
    prepare(sql) {
      const st = inner.prepare(sql);
      const api = {
        bind(...v) { st.bind(...v); if (/(FROM|INTO) pr_attempts/.test(sql)) log.push({ sql, binds: v }); return api; },
        first: (c) => st.first(c), all: () => st.all(), run: () => st.run(), raw: () => st.raw(),
      };
      return api;
    },
    batch: (x) => inner.batch(x),
    exec: (x) => inner.exec(x),
  };
  const R = 'o/bh9325-seed-200';
  assert.equal((await call(DB, 'GET', `/api/pr-attempts?repo=${R}&number=3&kind=kind1&sha=sha200-3-1`)).status, 200);
  assert.equal((await call(DB, 'GET', `/api/pr-attempts?repo=${R}&number=3`)).body.count, 5);
  assert.equal((await call(DB, 'GET', `/api/pr-attempts?repo=${R}&number=3&kind=kind2`)).body.count, 1);
  assert.equal((await call(DB, 'DELETE', `/api/pr-attempts?repo=${R}&number=3&kind=kind1&sha=sha200-3-1`)).status, 200);
  const kinds = log.map((l) => l.sql.split(/\s/)[0] + (/COUNT/.test(l.sql) ? '-count' : ''));
  assert.deepEqual(kinds, ['SELECT', 'SELECT-count', 'SELECT', 'SELECT-count', 'SELECT', 'DELETE']);
  for (const { sql, binds } of log) {
    const lines = plan(db, sql, ...binds);
    const all = lines.join('\n');
    assert.ok(lines.some((l) => /^SEARCH pr_attempts USING (COVERING )?INDEX sqlite_autoindex_pr_attempts_1 \(repo=\? AND number=\?/.test(l)), `${sql}\n${all}`);
    assert.deepEqual(fullScans(lines, ['pr_attempts']), [], `${sql}\n${all}`);
  }
});

test('W1: one DELETE removes at most 1 row; a repeat is 404; a short key is 400 and deletes nothing; a duplicate PUT adds nothing', async (t) => {
  const o = await seeded(t);
  if (!o) return;
  const { db, DB } = o;
  const R = 'o/bh9325-w1';
  const ins = db.prepare("INSERT INTO pr_attempts (repo, number, kind, sha, at, actor) VALUES (?, 7, 'k', ?, '2026-11-09T00:00:00Z', 'w1')");
  for (let i = 0; i < 5; i++) ins.run(R, `s${i}`);
  assert.equal(count(db, R), 5);

  const del = await call(DB, 'DELETE', `/api/pr-attempts?repo=${R}&number=7&kind=k&sha=s2`);
  assert.equal(del.status, 200, JSON.stringify(del.body));
  assert.equal(del.body.deleted, true);
  assert.equal(count(db, R), 4);
  assert.equal(count(db), SEED_ROWS + 4);

  assert.equal((await call(DB, 'DELETE', `/api/pr-attempts?repo=${R}&number=7&kind=k&sha=s2`)).status, 404);
  assert.equal(count(db, R), 4);

  assert.equal((await call(DB, 'DELETE', `/api/pr-attempts?repo=${R}&number=7&kind=k`)).status, 400);
  assert.equal(count(db, R), 4);

  const put = await call(DB, 'PUT', '/api/pr-attempts', { repo: R, number: 7, kind: 'k', sha: 's1', actor: 'again' });
  assert.equal(put.status, 200, JSON.stringify(put.body));
  assert.equal(put.body.duplicate, true);
  assert.equal(count(db, R), 4);
  assert.equal(db.prepare("SELECT actor FROM pr_attempts WHERE repo=? AND sha='s1'").get(R).actor, 'w1');
});

test('B1: no fetch to any host other than the fixture Sentry DSN', () => {
  assert.deepEqual(sent.other, []);
});
