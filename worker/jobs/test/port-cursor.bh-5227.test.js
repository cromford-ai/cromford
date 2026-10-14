import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import worker from '../src/index.js';
import { jobsSchemaSql } from './lib/jobs-schema.js';

// GET|PUT /api/port/cursor (BH-5227): the watermark bin/port-to-cromford.sh
// keeps per public target, so a merged range is ported once and never skipped.
// The PUT is compare-and-set on the stored sha. Every case goes through
// `worker.fetch` with the bearer (D2), over node:sqlite with the real
// schema.sql applied, and every statement is recorded so "a 400 ran nothing"
// is an assertion (D11).

const SCHEMA = jobsSchemaSql();
const SECRET = 'test-secret';
const TARGET = 'cromford-ai/cromford';
const SHA_A = 'a'.repeat(40);
const SHA_B = 'b'.repeat(40);
const SHA_C = 'c'.repeat(40);
const PR1 = 'https://github.com/cromford-ai/cromford/pull/1';
const PR2 = 'https://github.com/cromford-ai/cromford/pull/2';

// The D1-shaped adapter wake-claims.bh-2636 uses, copied (that file exports nothing).
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

const call = (fx, method, path, body, auth = true) => {
  const headers = { 'content-type': 'application/json' };
  if (auth) headers.authorization = `Bearer ${SECRET}`;
  const init = { method, headers };
  if (body !== undefined) init.body = JSON.stringify(body);
  return worker.fetch(new Request(`https://jobs.test${path}`, init), { DB: fx.DB, HARNESS_SECRET: SECRET })
    .then(async (res) => ({ status: res.status, body: await res.json().catch(() => null) }));
};
const get = (fx, target = TARGET) => call(fx, 'GET', `/api/port/cursor?target=${encodeURIComponent(target)}`);
const put = (fx, body) => call(fx, 'PUT', '/api/port/cursor', body);
const row = (fx) => {
  const r = fx.db.prepare('SELECT upstream_sha, pr_url FROM port_cursor WHERE target=?').get(TARGET);
  return r ? { ...r } : null;
};

test('A1: GET for a target with no row answers 200 with upstream_sha null, never a sha', async (t) => {
  const fx = await fixture(t);
  if (!fx) return;
  const r = await get(fx);
  assert.equal(r.status, 200);
  assert.equal(r.body.target, TARGET);
  assert.equal(r.body.upstream_sha, null);
  assert.equal(r.body.pr_url, null);
  assert.equal(typeof r.body.as_of, 'string');
});

test('A2: PUT prev:null inserts the row and GET reads it back', async (t) => {
  const fx = await fixture(t);
  if (!fx) return;
  const r = await put(fx, { target: TARGET, sha: SHA_A, prev: null, pr_url: PR1 });
  assert.equal(r.status, 200);
  assert.equal(r.body.upstream_sha, SHA_A);
  assert.equal(r.body.pr_url, PR1);
  const g = await get(fx);
  assert.equal(g.body.upstream_sha, SHA_A);
  assert.equal(g.body.pr_url, PR1);
});

test('A3: a second prev:null is 409 with the STORED row, which is unchanged', async (t) => {
  const fx = await fixture(t);
  if (!fx) return;
  await put(fx, { target: TARGET, sha: SHA_A, prev: null, pr_url: PR1 });
  const r = await put(fx, { target: TARGET, sha: SHA_B, prev: null, pr_url: PR2 });
  assert.equal(r.status, 409);
  assert.equal(r.body.error, 'cursor moved');
  assert.equal(r.body.upstream_sha, SHA_A);
  assert.equal(r.body.pr_url, PR1);
  assert.deepEqual(row(fx), { upstream_sha: SHA_A, pr_url: PR1 });
});

test('A4: a stale prev is 409 and the row does not move', async (t) => {
  const fx = await fixture(t);
  if (!fx) return;
  await put(fx, { target: TARGET, sha: SHA_A, prev: null, pr_url: PR1 });
  const r = await put(fx, { target: TARGET, sha: SHA_C, prev: SHA_B, pr_url: PR2 });
  assert.equal(r.status, 409);
  assert.equal(r.body.upstream_sha, SHA_A);
  assert.deepEqual(row(fx), { upstream_sha: SHA_A, pr_url: PR1 });
});

test('A4b: a prev for a target with no row is 409 with a null stored sha, and inserts nothing', async (t) => {
  const fx = await fixture(t);
  if (!fx) return;
  const r = await put(fx, { target: TARGET, sha: SHA_B, prev: SHA_A, pr_url: PR1 });
  assert.equal(r.status, 409);
  assert.equal(r.body.upstream_sha, null);
  assert.equal(row(fx), null);
});

test('A5: the right prev moves the row', async (t) => {
  const fx = await fixture(t);
  if (!fx) return;
  await put(fx, { target: TARGET, sha: SHA_A, prev: null, pr_url: PR1 });
  const r = await put(fx, { target: TARGET, sha: SHA_B, prev: SHA_A, pr_url: PR2 });
  assert.equal(r.status, 200);
  assert.equal(r.body.upstream_sha, SHA_B);
  assert.equal(r.body.pr_url, PR2);
  assert.deepEqual(row(fx), { upstream_sha: SHA_B, pr_url: PR2 });
});

test('A6: bad sha, prev, target or pr_url is 400 and runs no SQL', async (t) => {
  const fx = await fixture(t);
  if (!fx) return;
  const ok = { target: TARGET, sha: SHA_A, prev: null, pr_url: PR1 };
  const bads = [
    { ...ok, sha: 'a'.repeat(39) },
    { ...ok, sha: 'g'.repeat(40) },
    { ...ok, sha: 'A'.repeat(40) },
    { ...ok, sha: undefined },
    { ...ok, prev: 'z'.repeat(40) },
    { ...ok, prev: 'a'.repeat(41) },
    { ...ok, target: 'noslash' },
    { ...ok, target: 'a/b/c' },
    { ...ok, target: '' },
    { ...ok, pr_url: 7 },
    { ...ok, pr_url: undefined },
  ];
  for (const b of bads) {
    const r = await put(fx, b);
    assert.equal(r.status, 400, `expected 400 for ${JSON.stringify(b)}`);
  }
  for (const target of ['noslash', 'a/b/c', '']) {
    const r = await get(fx, target);
    assert.equal(r.status, 400, `expected 400 for GET target=${target}`);
  }
  assert.deepEqual(fx.calls, []);
});

test('A6b: pr_url null is accepted', async (t) => {
  const fx = await fixture(t);
  if (!fx) return;
  const r = await put(fx, { target: TARGET, sha: SHA_A, prev: null, pr_url: null });
  assert.equal(r.status, 200);
  assert.equal(r.body.pr_url, null);
});

test('A7: no bearer is 401 on both verbs', async (t) => {
  const fx = await fixture(t);
  if (!fx) return;
  assert.equal((await call(fx, 'GET', `/api/port/cursor?target=${TARGET}`, undefined, false)).status, 401);
  assert.equal((await call(fx, 'PUT', '/api/port/cursor', { target: TARGET, sha: SHA_A, prev: null, pr_url: null }, false)).status, 401);
  assert.deepEqual(fx.calls, []);
});
