import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import worker from '../src/index.js';
import { jobsSchemaSql } from './lib/jobs-schema.js';

// BH-4059 (slice BH-4169): a fly build landing in `build_queue` rings the
// doorbell.
//
// POST /api/queue writes one `queue` wake (repo 'harness/build-queue', key
// '<project>:<KEY>') after a `queued` + `fly` row lands. The wake is
// best effort: a failed wake insert must not change the enqueue's status or
// body, and the build row must still be committed. Driven through
// `worker.fetch` (D2) over a node:sqlite database with schema.sql applied, so
// the assertions are on rows LEFT, not on statements issued.

const SCHEMA = jobsSchemaSql();
const SECRET = 'test-secret';

// The D1-shaped adapter from wakes-nudge.bh-2754. `failWakes` makes every
// statement that writes the wakes table throw, the way a D1 hiccup would.
function d1(db, calls, opts) {
  const exec = (sql) => {
    const flat = sql.replace(/\s+/g, ' ').trim();
    calls.push(flat);
    if (opts.failWakes && /INTO wakes/i.test(flat)) throw new Error('D1_ERROR: wakes unavailable');
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

async function fixture(t, opts = {}) {
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
  return { db, calls, DB: d1(db, calls, opts) };
}

const call = (fx, method, path, body) => {
  const req = new Request(`https://jobs.test${path}`, {
    method,
    headers: { 'content-type': 'application/json', authorization: `Bearer ${SECRET}` },
    body: JSON.stringify(body),
  });
  return worker.fetch(req, { DB: fx.DB, HARNESS_SECRET: SECRET })
    .then(async (res) => ({ status: res.status, body: await res.json().catch(() => null) }));
};

const wakes = (fx) => fx.db.prepare(
  'SELECT repo, kind, key, event, minute, at, acked_at FROM wakes ORDER BY id ASC').all()
  .map((r) => ({ ...r }));
const queueRows = (fx) => fx.db.prepare(
  'SELECT project, ticket_key, status, target FROM build_queue ORDER BY project, ticket_key').all()
  .map((r) => ({ ...r }));

const FLY = { project: 'project-3', key: 'TK-1', target: 'fly' };

test('AT-W1: a queued fly enqueue writes exactly one queue wake for <project>:<KEY>', async (t) => {
  const fx = await fixture(t);
  if (!fx) return;
  const r = await call(fx, 'POST', '/api/queue', FLY);
  assert.equal(r.status, 201);
  assert.equal(r.body.duplicate, false);
  assert.deepEqual(queueRows(fx), [{ project: 'project-3', ticket_key: 'TK-1', status: 'queued', target: 'fly' }]);
  const w = wakes(fx);
  assert.equal(w.length, 1);
  assert.equal(w[0].repo, 'harness/build-queue');
  assert.equal(w[0].kind, 'queue');
  assert.equal(w[0].key, 'project-3:TK-1');
  assert.equal(w[0].event, 'build_queue.insert');
  assert.equal(w[0].acked_at, null);
  // The webhook's minute bucket, so the UNIQUE index dedupes the same way.
  assert.equal(w[0].minute, w[0].at.slice(0, 16) + ':00Z');
});

test('AT-W2: a wake insert that throws still answers 201 with the same body and commits the build row', async (t) => {
  const ok = await fixture(t);
  if (!ok) return;
  const good = await call(ok, 'POST', '/api/queue', FLY);
  const fx = await fixture(t, { failWakes: true });
  const r = await call(fx, 'POST', '/api/queue', FLY);
  assert.equal(r.status, 201);
  assert.deepEqual(Object.keys(r.body).sort(), Object.keys(good.body).sort());
  assert.deepEqual(Object.keys(r.body.queued).sort(), Object.keys(good.body.queued).sort());
  assert.equal(r.body.queued.status, 'queued');
  assert.deepEqual(queueRows(fx), [{ project: 'project-3', ticket_key: 'TK-1', status: 'queued', target: 'fly' }]);
  assert.equal(wakes(fx).length, 0);
  // And the wake really was attempted: the failure is the thing under test.
  assert.ok(fx.calls.some((s) => /INTO wakes/i.test(s)), 'the enqueue must attempt the wake insert');
});

test('AT-W3: a re-queue in the same minute leaves one wake row and logs no failure', async (t) => {
  // A terminal row re-queued as a build runs the upsert and the wake again, so
  // the second wake INSERT meets idx_wakes_dedupe. ON CONFLICT DO NOTHING is
  // what keeps that quiet; without it the insert throws and the catch logs.
  for (let attempt = 0; attempt < 3; attempt++) {
    const fx = await fixture(t);
    if (!fx) return;
    const errors = [];
    t.mock.method(console, 'error', (...a) => { errors.push(a.join(' ')); });
    const first = await call(fx, 'POST', '/api/queue', FLY);
    fx.db.prepare("UPDATE build_queue SET status='failed' WHERE project='project-3' AND ticket_key='TK-1'").run();
    const again = await call(fx, 'POST', '/api/queue', FLY);
    console.error.mock.restore();
    // Straddled a minute boundary: two buckets are two legitimate wakes.
    if (first.body.as_of.slice(0, 16) !== again.body.as_of.slice(0, 16)) continue;
    assert.equal(first.status, 201);
    assert.equal(again.status, 201);
    assert.equal(again.body.duplicate, false);
    assert.equal(wakes(fx).length, 1);
    assert.deepEqual(errors, []);
    return;
  }
  assert.fail('three attempts straddled a minute boundary');
});

test('AT-W3b: a duplicate enqueue of a queued row writes no second wake', async (t) => {
  const fx = await fixture(t);
  if (!fx) return;
  assert.equal((await call(fx, 'POST', '/api/queue', FLY)).status, 201);
  const r = await call(fx, 'POST', '/api/queue', FLY);
  assert.equal(r.status, 200);
  assert.equal(r.body.duplicate, true);
  assert.equal(wakes(fx).length, 1);
});

test('AT-W4: a local enqueue and a ready put write no wake', async (t) => {
  const fx = await fixture(t);
  if (!fx) return;
  const loc = await call(fx, 'POST', '/api/queue', { project: 'project-3', key: 'TK-2', target: 'local' });
  assert.equal(loc.status, 201);
  const ready = await call(fx, 'POST', '/api/queue', { project: 'project-3', key: 'TK-3', target: 'fly', status: 'ready' });
  assert.equal(ready.status, 201);
  assert.equal(ready.body.queued.status, 'ready');
  assert.equal(queueRows(fx).length, 2);
  assert.equal(wakes(fx).length, 0);
});
