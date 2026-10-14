import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { DatabaseSync } from 'node:sqlite';
import worker from '../src/index.js';
import { jobsSchemaSql } from './lib/jobs-schema.js';

// BH-5023 (BH-4973.2) — a build files the lead review request for its OWN
// medium-risk head with the bearer alone (bin/inbuild-lead-review.sh), because
// the lead token lives only on the hub and the operator's Mac. The allowance is narrow:
// requested_by must be `inbuild:<box>:<KEY>` and the row must not jump the
// queue (priority absent or 0). Every other bearer-only create is still the
// 403 it was. Driven through worker.fetch against the SQL that ships.
const SECRET = 'test-secret';
const LEAD = 'lead-test-token';
const SCHEMA = jobsSchemaSql();

function sqliteDB(db) {
  const bindAndRun = (sql, binds) => ({
    first: async () => db.prepare(sql).get(...binds) ?? null,
    all: async () => ({ results: db.prepare(sql).all(...binds) }),
    run: async () => {
      const r = db.prepare(sql).run(...binds);
      return { meta: { changes: Number(r.changes) || 0, last_row_id: Number(r.lastInsertRowid) || 0 } };
    },
  });
  return {
    prepare: (sql) => ({ ...bindAndRun(sql, []), bind: (...b) => bindAndRun(sql, b.map((v) => (v === undefined ? null : v))) }),
  };
}
const fresh = () => { const db = new DatabaseSync(':memory:'); db.exec(SCHEMA); return { db, DB: sqliteDB(db) }; };

const post = (DB, body, { lead = false } = {}) => {
  const req = new Request('https://jobs.test/api/lead-reviews', {
    method: 'POST',
    headers: {
      authorization: `Bearer ${SECRET}`,
      ...(lead ? { 'x-lead-verdict-token': LEAD } : {}),
      'content-type': 'application/json',
    },
    body: JSON.stringify(body),
  });
  return worker.fetch(req, { DB, HARNESS_SECRET: SECRET, LEAD_VERDICT_TOKEN: LEAD })
    .then(async (res) => ({ status: res.status, body: await res.json().catch(() => null) }));
};

const H1 = 'a'.repeat(40);
const BASE = { repo: 'example-org/cromford', pr: 5067, head_sha: H1, scope_notes: 'inbuild: builder APPROVE on aaaaaaaaaaaa, risk tier medium' };
const count = (db) => db.prepare('SELECT COUNT(*) AS n FROM lead_review_requests').get().n;

test('1. bearer only + requested_by inbuild:<box>:<KEY> → 201, a requested row', async () => {
  const { db, DB } = fresh();
  const res = await post(DB, { ...BASE, requested_by: 'inbuild:box-hub:BH-5023' });
  assert.equal(res.status, 201, JSON.stringify(res.body));
  assert.equal(res.body.request.status, 'requested');
  assert.equal(res.body.request.requested_by, 'inbuild:box-hub:BH-5023');
  assert.equal(res.body.request.priority ?? 0, 0);
  assert.equal(count(db), 1);
});

test('2. bearer only + the enqueue\'s own requested_by → 403 with the lead-token text, no row', async () => {
  const { db, DB } = fresh();
  const res = await post(DB, { ...BASE, requested_by: 'lead-review-enqueue:hub' });
  assert.equal(res.status, 403);
  assert.match(res.body.error, /lead verdict token/);
  assert.equal(count(db), 0);
});

test('3. bearer only + inbuild + priority 1 → 403, no row (a box never jumps the queue)', async () => {
  const { db, DB } = fresh();
  const res = await post(DB, { ...BASE, requested_by: 'inbuild:box-hub:BH-5023', priority: 1 });
  assert.equal(res.status, 403);
  assert.equal(count(db), 0);
});

test('4. bearer only + no requested_by, or a near-miss one (padding included: land keys on the stored prefix) → 403, no row', async () => {
  const { db, DB } = fresh();
  for (const by of [undefined, '', 'inbuild:', 'inbuild:box', 'inbuild::BH-1', 'inbuild:box:BH 1', 'xinbuild:box:BH-1', 'inbuild:box:BH-1:extra', ' inbuild:box:BH-1', 'inbuild:box:BH-1 ', 42]) {
    const body = { ...BASE };
    if (by !== undefined) body.requested_by = by;
    const res = await post(DB, body);
    assert.equal(res.status, 403, `requested_by=${JSON.stringify(by)}`);
  }
  assert.equal(count(db), 0);
});

test('5. a second inbuild POST for the same head → 200 existing:true, one row', async () => {
  const { db, DB } = fresh();
  const body = { ...BASE, requested_by: 'inbuild:box-hub:BH-5023' };
  const first = await post(DB, body);
  assert.equal(first.status, 201);
  const again = await post(DB, body);
  assert.equal(again.status, 200);
  assert.equal(again.body.existing, true);
  assert.equal(again.body.request.id, first.body.request.id);
  assert.equal(count(db), 1);
});

test('6. inbuild on a head the hub already requested with other notes → 409 carrying that row', async () => {
  const { db, DB } = fresh();
  const hub = await post(DB, { ...BASE, scope_notes: 'auto: builder APPROVE on aaaaaaaaaaaa', requested_by: 'lead-review-enqueue:hub' }, { lead: true });
  assert.equal(hub.status, 201);
  const res = await post(DB, { ...BASE, requested_by: 'inbuild:box-hub:BH-5023' });
  assert.equal(res.status, 409);
  assert.equal(res.body.request.id, hub.body.request.id);
  assert.equal(count(db), 1);
});

test('7. the lead token still creates anything it did before (priority 1 included)', async () => {
  const { DB } = fresh();
  const res = await post(DB, { ...BASE, requested_by: 'lead-review-enqueue:hub', priority: 1 }, { lead: true });
  assert.equal(res.status, 201);
  assert.equal(res.body.request.priority, 1);
});
