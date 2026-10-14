import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import worker, { OPEN_ROUTES } from '../src/index.js';
import { jobsSchemaSql } from './lib/jobs-schema.js';

// POST /api/wakes/lane (BH-4092, part 1 of BH-4057): the lead-chain doorbell.
//
// bin/lead-review-enqueue.sh rings `lead-review` for the box that owns the
// repo, and later stages ring `lead-land` for the hub, through the same D1
// `wakes` table every other wake uses. The once-only key is the existing
// UNIQUE idx_wakes_dedupe(repo,kind,key,minute) with minute 'lane:<dedupe>',
// so the assertions are on rows LEFT in a node:sqlite database that had
// schema.sql applied, driven through `worker.fetch` (D2). A bad body must run
// no INSERT at all (D11), so every statement is recorded.

const SCHEMA = jobsSchemaSql();
const SECRET = 'test-secret';

// Same D1-shaped adapter as wakes-nudge.bh-2754.
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
  return { db, calls, DB: d1(db, calls) };
}

const lane = (fx, body, { secret = SECRET } = {}) => {
  const headers = { 'content-type': 'application/json' };
  if (secret !== null) headers.authorization = `Bearer ${secret}`;
  const req = new Request('https://jobs.test/api/wakes/lane', {
    method: 'POST', headers, body: JSON.stringify(body),
  });
  return worker.fetch(req, { DB: fx.DB, HARNESS_SECRET: SECRET })
    .then(async (res) => ({ status: res.status, body: await res.json().catch(() => null) }));
};

const rows = (fx) => fx.db.prepare(
  'SELECT repo, kind, key, typeof(key) kt, event, minute FROM wakes ORDER BY id ASC').all()
  .map((r) => ({ ...r }));
const inserts = (fx) => fx.calls.filter((s) => /^INSERT/i.test(s));

const OK = { repo: 'example-org/demo-os', kind: 'lead-review', key: 42, dedupe: 'lead-review:42@aaaaaaaaaaaa' };

for (const kind of ['lead-review', 'lead-land']) {
  test(`W1 lane: ${kind} inserts one row with a TEXT key, event lane:<kind>, minute lane:<dedupe>`, async (t) => {
    const fx = await fixture(t);
    if (!fx) return;
    const dedupe = `${kind}:42@aaaaaaaaaaaa`;
    const r = await lane(fx, { ...OK, kind, dedupe });
    assert.equal(r.status, 200, JSON.stringify(r.body));
    assert.equal(r.body.inserted, 1);
    assert.equal(typeof r.body.as_of, 'string');
    assert.deepEqual(rows(fx), [{
      repo: 'example-org/demo-os', kind, key: '42', kt: 'text',
      event: `lane:${kind}`, minute: `lane:${dedupe}`,
    }]);
    assert.equal(fx.db.prepare("SELECT COUNT(*) n FROM wakes WHERE key = '42'").get().n, 1);
  });
}

test('W2 lane: a replay inserts nothing; a new head (dedupe) is a second row', async (t) => {
  const fx = await fixture(t);
  if (!fx) return;
  assert.equal((await lane(fx, OK)).body.inserted, 1);
  const again = await lane(fx, OK);
  assert.equal(again.status, 200);
  assert.equal(again.body.inserted, 0);
  assert.equal(rows(fx).length, 1);
  const next = await lane(fx, { ...OK, dedupe: 'lead-review:42@bbbbbbbbbbbb' });
  assert.equal(next.body.inserted, 1);
  assert.equal(rows(fx).length, 2);
});

const BAD = [
  ['W3 kind pr', { ...OK, kind: 'pr' }],
  ['W3 kind issue', { ...OK, kind: 'issue' }],
  ['W3 kind LEAD-REVIEW', { ...OK, kind: 'LEAD-REVIEW' }],
  ['W3 kind missing', { repo: OK.repo, key: OK.key, dedupe: OK.dedupe }],
  ['W4 repo nope', { ...OK, repo: 'nope' }],
  ['W4 key as a string', { ...OK, key: '42' }],
  ['W4 key zero', { ...OK, key: 0 }],
  ['W4 key fractional', { ...OK, key: 1.5 }],
  ['W4 key past 1e9', { ...OK, key: 1000000001 }],
  ['W4 dedupe uppercase', { ...OK, dedupe: 'UPPER' }],
  ['W4 dedupe 65 chars', { ...OK, dedupe: 'a'.repeat(65) }],
  ['W4 dedupe with a space', { ...OK, dedupe: 'a b' }],
  ['W4 dedupe with a slash', { ...OK, dedupe: 'a/b' }],
  ['W4 dedupe missing', { repo: OK.repo, kind: OK.kind, key: OK.key }],
  ['W4 body is JSON null', null],
];

for (const [name, body] of BAD) {
  test(`${name} is a 400 and runs no INSERT`, async (t) => {
    const fx = await fixture(t);
    if (!fx) return;
    const r = await lane(fx, body);
    assert.equal(r.status, 400, JSON.stringify(r.body));
    assert.deepEqual(inserts(fx), []);
    assert.equal(rows(fx).length, 0);
  });
}

test('W5 lane: no Authorization header is a 401 and writes nothing; the route is not open', async (t) => {
  const fx = await fixture(t);
  if (!fx) return;
  const r = await lane(fx, OK, { secret: null });
  assert.equal(r.status, 401);
  assert.deepEqual(inserts(fx), []);
  assert.equal(rows(fx).length, 0);
  assert.ok(!OPEN_ROUTES.some(([m, p]) => m === 'POST' && p === '/api/wakes/lane'));
});
