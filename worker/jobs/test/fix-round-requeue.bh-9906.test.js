import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';

// BH-9906 — POST /api/fix-rounds/requeue (claimed → queued, by the claim
// holder only, attempt untouched) and the finish route's `verify-timeout`
// result word. Driven through worker.fetch against the SQL that ships
// (schema.sql in node:sqlite), the same harness as fix-rounds-routes.bh-2670.

const SECRET = 'test-secret';
const P = 'project-3';
const ARGS = ['project-3', '123', 'abc1234', 'fix', '/b', 'x'];
const sec = (ms) => new Date(ms).toISOString().replace(/\.\d{3}Z$/, 'Z');

async function fixture() {
  const opened = await openDb({});
  assert.ok(opened, 'node:sqlite is required for this suite — CI runs node 22');
  const { db, DB } = opened;
  const call = (path, body) => worker.fetch(new Request(`https://jobs.test${path}`, {
    method: 'POST',
    headers: { authorization: `Bearer ${SECRET}`, 'content-type': 'application/json' },
    body: JSON.stringify(body),
  }), { DB, HARNESS_SECRET: SECRET }).then(async (res) => ({ status: res.status, body: await res.json().catch(() => null) }));
  const row = (id) => db.prepare('SELECT * FROM fix_round_jobs WHERE id=?').get(id) ?? null;
  // Each seed takes its own cap_key: the open-row unique index is per (project, cap_key).
  let n = 0;
  const seed = (over = {}) => {
    const r = {
      cap_key: `${P}#9906-${++n}@abc`, box: 'box-a', record_in: '{"round":0}', status: 'claimed',
      attempt: 2, claimed_by: 'box-a', claimed_at: '2026-09-26T10:05:00Z',
      enqueued_at: '2026-09-26T10:00:00Z', updated_at: '2026-09-26T10:05:00Z', ...over,
    };
    const res = db.prepare(`INSERT INTO fix_round_jobs (project, cap_key, box, args, record_in, hotfix,
                  status, attempt, claimed_by, claimed_at, enqueued_at, updated_at)
                  VALUES (?,?,?,?,?,0,?,?,?,?,?,?)`)
      .run(P, r.cap_key, r.box, JSON.stringify(ARGS), r.record_in, r.status, r.attempt,
           r.claimed_by, r.claimed_at, r.enqueued_at, r.updated_at);
    return Number(res.lastInsertRowid);
  };
  return { db, call, row, seed };
}

test('requeue 1: the claim holder puts the row back as queued; attempt is untouched and the next claim adds 1', async (t) => {
  // The route stamps enqueued_at from the JS clock; pin it so the stamp is exact.
  const NOW_MS = Date.UTC(2026, 10, 23, 12, 0, 0);
  t.mock.timers.enable({ apis: ['Date'], now: NOW_MS });
  const f = await fixture();
  const id = f.seed();
  const recIn = '{"round":2,"note":"verify-timeout \\u00e9 ü"}';
  const r = await f.call('/api/fix-rounds/requeue', { id, box: 'box-a', record_in: recIn });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.job.id, id);
  assert.equal(r.body.job.status, 'queued');
  assert.equal(r.body.job.attempt, 2, 'requeue never touches attempt');
  assert.deepEqual(r.body.job.args, ARGS);
  const db = f.row(id);
  assert.equal(db.status, 'queued');
  assert.equal(db.record_in, recIn, 'record_in is stored byte for byte');
  assert.equal(db.attempt, 2);
  assert.equal(db.enqueued_at, db.updated_at);
  assert.equal(db.enqueued_at, r.body.as_of, 'enqueued_at is the request time');
  assert.equal(db.enqueued_at, sec(NOW_MS), 'enqueued_at is the pinned clock');

  const c = await f.call('/api/fix-rounds/claim', { box: 'box-a' });
  assert.equal(c.status, 200, JSON.stringify(c.body));
  assert.equal(c.body.job.id, id);
  assert.equal(c.body.job.attempt, 3, 'the next claim adds 1');
  assert.equal(c.body.job.claimed_by, 'box-a');

  // null record_in stores null, the same as the enqueue route.
  const n = await f.call('/api/fix-rounds/requeue', { id, box: 'box-a', record_in: null });
  assert.equal(n.status, 200, JSON.stringify(n.body));
  assert.equal(f.row(id).record_in, null);
  f.db.close();
});

test('requeue 2: another box, a queued row and a missing id are refused; the row is unchanged', async () => {
  const f = await fixture();
  const id = f.seed();
  const snap = f.row(id);
  const other = await f.call('/api/fix-rounds/requeue', { id, box: 'box-b', record_in: '{"x":1}' });
  assert.equal(other.status, 409, JSON.stringify(other.body));
  assert.equal(other.body.refused, true);
  assert.equal(other.body.scope, 'fix-rounds');
  assert.equal(other.body.job.id, id);
  assert.equal(other.body.job.claimed_by, 'box-a');
  assert.deepEqual(f.row(id), snap, 'a refused requeue writes nothing');

  const q = f.seed({ status: 'queued', claimed_by: null, claimed_at: null, attempt: 0 });
  const qr = await f.call('/api/fix-rounds/requeue', { id: q, box: 'box-a' });
  assert.equal(qr.status, 409, JSON.stringify(qr.body));
  assert.equal(qr.body.refused, true);
  assert.equal(qr.body.job.status, 'queued');

  const miss = await f.call('/api/fix-rounds/requeue', { id: 99999, box: 'box-a' });
  assert.equal(miss.status, 404, JSON.stringify(miss.body));
  assert.equal(miss.body.id, 99999);
  f.db.close();
});

test('requeue 3: bad id, bad box and an over-cap record_in are refused before the write', async () => {
  const f = await fixture();
  const id = f.seed();
  const snap = f.row(id);
  for (const bid of [1.5, '1', 0, -1, null]) {
    const r = await f.call('/api/fix-rounds/requeue', { id: bid, box: 'box-a' });
    assert.equal(r.status, 400, `id=${JSON.stringify(bid)}`);
  }
  for (const box of [undefined, '', 'bad box', 'x'.repeat(65)]) {
    const r = await f.call('/api/fix-rounds/requeue', { id, box });
    assert.equal(r.status, 400, `box=${JSON.stringify(box)}`);
  }
  const nonStr = await f.call('/api/fix-rounds/requeue', { id, box: 'box-a', record_in: {} });
  assert.equal(nonStr.status, 400);
  const big = await f.call('/api/fix-rounds/requeue', { id, box: 'box-a', record_in: 'x'.repeat(300 * 1024) });
  assert.equal(big.status, 413, JSON.stringify(big.body));
  assert.deepEqual(f.row(id), snap, 'every refusal above left the row untouched');
  f.db.close();
});

test('requeue 4: finish accepts verify-timeout and verify-timeout <token>, and refuses verify-timeoutx', async () => {
  const f = await fixture();
  const a = f.seed();
  const b = f.seed();
  const c = f.seed();
  const ra = await f.call('/api/fix-rounds/finish', { id: a, box: 'box-a', result: 'verify-timeout' });
  assert.equal(ra.status, 200, JSON.stringify(ra.body));
  assert.equal(ra.body.job.result, 'verify-timeout');
  const rb = await f.call('/api/fix-rounds/finish', { id: b, box: 'box-a', result: 'verify-timeout YWJj' });
  assert.equal(rb.status, 200, JSON.stringify(rb.body));
  assert.equal(rb.body.job.result, 'verify-timeout YWJj');
  for (const bad of ['verify-timeoutx', 'verify-timeout ', 'verify-timeout a b']) {
    const rc = await f.call('/api/fix-rounds/finish', { id: c, box: 'box-a', result: bad });
    assert.equal(rc.status, 400, `result=${JSON.stringify(bad)}`);
    assert.match(rc.body.error, /verify-timeout/);
  }
  assert.equal(f.row(c).status, 'claimed');
  f.db.close();
});
