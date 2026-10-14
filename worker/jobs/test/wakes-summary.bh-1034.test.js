import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import worker from '../src/index.js';
import { jobsSchemaSql } from './lib/jobs-schema.js';

// GET /api/wakes/summary — who has RUNG lately (BH-1034.4, audit #35).
//
// THE QUERY IS THE FEATURE, so it runs for real. bin/doorbell-coverage-check.sh
// suppresses a client-visible alert on the strength of this answer, and a fake
// D1 that returns whatever the test handed it would prove only that the route
// calls prepare(). schema.sql is APPLIED into node:sqlite and the route's own
// SQL is the thing executed: GROUP BY, MAX(at), GROUP_CONCAT(DISTINCT kind) and
// the `at >= ?1` window all have to be right in the engine, not in a regex.

const SCHEMA = jobsSchemaSql();
const SECRET = 'test-secret';
const now = Date.now();  // determinism: ok the single anchor; every fixture below is iso(msAgo) off it
const H = 3600e3;
const iso = (msAgo) => new Date(now - msAgo).toISOString().replace(/\.\d{3}Z$/, 'Z');

// A D1-shaped adapter over node:sqlite. `all` answers {results}, which is what
// the route reads; every executed statement is recorded so "one statement, not
// an N+1 over repos" is an assertion and not a hope.
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

async function fixture(t, rows) {
  let DatabaseSync;
  try {
    ({ DatabaseSync } = await import('node:sqlite'));
  } catch {
    t.skip('node:sqlite unavailable on this runtime');
    return null;
  }
  const db = new DatabaseSync(':memory:');
  db.exec(SCHEMA);
  const ins = db.prepare('INSERT INTO wakes (repo, kind, key, event, minute, at) VALUES (?,?,?,?,?,?)');
  for (const r of rows) ins.run(r.repo, r.kind, r.key, r.kind, r.at.slice(0, 16) + ':00Z', r.at);
  const calls = [];
  return { db, calls, DB: d1(db, calls) };
}

const call = (fx, query, { secret = SECRET } = {}) => {
  const headers = secret === null ? {} : { authorization: `Bearer ${secret}` };
  const req = new Request(`https://jobs.test/api/wakes/summary${query}`, { method: 'GET', headers });
  return worker.fetch(req, { DB: fx ? fx.DB : null, HARNESS_SECRET: SECRET })
    .then(async (res) => ({ status: res.status, body: await res.json().catch(() => null) }));
};

const ROWS = [
  { repo: 'example-org/project-3', kind: 'pr', key: '10', at: iso(1 * H) },
  { repo: 'example-org/project-3', kind: 'push', key: 'abc1234', at: iso(2 * H) },
  { repo: 'example-org/project-5', kind: 'pr', key: '77', at: iso(3 * H) },
];
const OLD = { repo: 'example-org/project-4', kind: 'deploy', key: 'def5678', at: iso(30 * H) };

test('summary: one row per repo, with the count, the newest at, and every kind', async (t) => {
  const fx = await fixture(t, ROWS);
  if (!fx) return;
  const r = await call(fx, '');
  assert.equal(r.status, 200);
  assert.equal(r.body.repos.length, 2, 'two repos rang, so two rows');
  const project-3 = r.body.repos.find((x) => x.repo === 'example-org/project-3');
  assert.ok(project-3, 'the repo that rang twice is missing from the summary');
  assert.equal(project-3.n, 2);
  assert.equal(project-3.last_at, iso(1 * H), 'last_at must be the NEWEST wake, not the oldest');
  assert.deepEqual(String(project-3.kinds).split(',').sort(), ['pr', 'push']);
  const ts = r.body.repos.find((x) => x.repo === 'example-org/project-5');
  assert.equal(ts.n, 1);
  assert.equal(ts.kinds, 'pr');
  assert.equal(r.body.hours, 24, 'no ?hours means 24');
  assert.equal(Date.parse(r.body.as_of) - Date.parse(r.body.since), 24 * H);
  fx.db.close();
});

test('summary: a repo whose only wake is outside the window is ABSENT, and hours= brings it back', async (t) => {
  const fx = await fixture(t, [...ROWS, OLD]);
  if (!fx) return;
  const def = await call(fx, '');
  assert.equal(def.body.repos.find((x) => x.repo === 'example-org/project-4'), undefined,
    'a 30h-old wake must not count as ringing in a 24h window');
  const wide = await call(fx, '?hours=48');
  assert.equal(wide.body.hours, 48);
  assert.ok(wide.body.repos.find((x) => x.repo === 'example-org/project-4'), 'hours=48 must reach a 30h-old wake');
  fx.db.close();
});

test('summary: hours clamps to 1..168', async (t) => {
  const fx = await fixture(t, [...ROWS, OLD]);
  if (!fx) return;
  const big = await call(fx, '?hours=999');
  assert.equal(big.body.hours, 168);
  assert.equal(Date.parse(big.body.as_of) - Date.parse(big.body.since), 168 * H);
  assert.ok(big.body.repos.find((x) => x.repo === 'example-org/project-4'), 'the 168h window must include the 30h row');
  const zero = await call(fx, '?hours=0');
  assert.equal(zero.body.hours, 1);
  assert.equal(Date.parse(zero.body.as_of) - Date.parse(zero.body.since), 1 * H);
  assert.equal(zero.body.repos.find((x) => x.repo === 'example-org/project-5'), undefined,
    'a 1h window must not reach the 3h-old wake');
  const junk = await call(fx, '?hours=lots');
  assert.equal(junk.body.hours, 24, 'garbage hours falls back to the default, never to 0');
  fx.db.close();
});

test('summary: no bearer and a wrong bearer are both 401, and neither touches the DB', async (t) => {
  const fx = await fixture(t, ROWS);
  if (!fx) return;
  const none = await call(fx, '', { secret: null });
  assert.equal(none.status, 401);
  const wrong = await call(fx, '', { secret: 'not-the-secret' });
  assert.equal(wrong.status, 401);
  assert.equal(fx.calls.length, 0, 'an unauthenticated request must not run a query');
  fx.db.close();
});

test('summary: nobody rang is an ANSWER — 200 with an empty list, never a 404', async (t) => {
  const fx = await fixture(t, []);
  if (!fx) return;
  const r = await call(fx, '');
  assert.equal(r.status, 200);
  assert.deepEqual(r.body.repos, []);
  fx.db.close();
});

test('summary: the whole report is ONE statement — no per-repo N+1', async (t) => {
  const fx = await fixture(t, [...ROWS, OLD]);
  if (!fx) return;
  await call(fx, '');
  assert.equal(fx.calls.length, 1, `expected 1 statement, got ${fx.calls.length}: ${fx.calls.join(' | ')}`);
  assert.match(fx.calls[0], /GROUP BY repo/);
  fx.db.close();
});
