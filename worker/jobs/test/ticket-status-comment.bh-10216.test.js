// BH-10216: the ticket_status_comments row keeps the comment id and the body
// hash, so the hub lane makes no GitHub read before an edit. Two changes to the
// BH-9503 family, driven through the REAL worker.fetch over the REAL composed
// schema (the node:sqlite D1 shim):
//   DELETE /api/ticket-status-comments?project=&key=&comment_id=   compare-and-delete
//          on the comment id: the lane forgets a row whose comment answered 404.
//   POST   /api/ticket-status-comments with fingerprint null: the lane stores the
//          id it found by a list read BEFORE its PATCH. Stored as '', final 0.
//
//   W1 DELETE with the matching comment_id deletes the row; a second answers deleted 0
//   W2 DELETE with another comment_id deletes nothing (a newer comment is kept)
//   W3 DELETE for another project with the same key deletes nothing (wrong tenant: 0 rows)
//   W4 DELETE 400s name the field: project, key, comment_id
//   W5 POST fingerprint null stores '' and final 0; the due answer lists it WITH its id
//   W6 POST fingerprint 'xyz' is still 400 fingerprint
//   W7 EXPLAIN QUERY PLAN of SQL.forget uses the primary key at volume
import test, { mock } from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { openDb, d1 } from './lib/d1-sqlite.bh-1030.js';
import { ensureColumns } from '../src/lib/core.js';

const SECRET = 'test-secret-fixture';
const NOW = '2026-11-26T12:00:00Z';
const NOW_MS = Date.parse(NOW);
const M = () => import('../src/routes/ticket-status-comment.js');
const iso = (ms) => new Date(ms).toISOString().replace(/\.\d{3}Z$/, 'Z');
const ago = (min) => iso(NOW_MS - min * 60000);

mock.timers.enable({ apis: ['Date'], now: NOW_MS });

const call = (DB, path, { method = 'GET', body } = {}) => {
  const req = new Request(`https://jobs.test${path}`, {
    method,
    headers: { authorization: `Bearer ${SECRET}`, 'content-type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  return worker.fetch(req, { DB, HARNESS_SECRET: SECRET }).then(async (res) => ({
    status: res.status, body: await res.json().catch(() => null),
  }));
};
async function fresh() {
  const o = await openDb();
  await ensureColumns({ DB: d1(o.db) }, 'build_queue');
  await ensureColumns({ DB: d1(o.db) }, 'pr_records');
  o.db.prepare(`INSERT INTO settings (key,value,note,actor,updated_at) VALUES ('ticket_status_comment.not_before','2026-01-01T00:00:00Z','t','test','2026-11-02T00:00:00Z')
    ON CONFLICT(key) DO UPDATE SET value=excluded.value`).run();
  return o;
}
function project(db, name) {
  db.prepare(`INSERT INTO projects (project, repo, cron_offset, created_at, updated_at)
    VALUES (?, ?, 0, '2026-10-01T00:00:00Z', '2026-10-01T00:00:00Z')`).run(name, `example-org/${name}`);
}
function queue(db, p, key, ticketId) {
  db.prepare(`INSERT INTO build_queue (project, ticket_key, ticket_id, status, attempt, enqueued_at, updated_at)
    VALUES (?, ?, ?, 'queued', 0, ?, ?)`).run(p, key, ticketId, ago(300), ago(60));
}
const rec = (p, key, issue, commentId, fingerprint, extra = {}) => ({
  project: p, ticket_key: key, issue, comment_id: commentId, fingerprint, state: 'queued', final: false, ...extra,
});
const post = (DB, b) => call(DB, '/api/ticket-status-comments', { method: 'POST', body: b });
const del = (DB, q) => call(DB, `/api/ticket-status-comments?${q}`, { method: 'DELETE' });
const row = (db, p, key) => db.prepare('SELECT * FROM ticket_status_comments WHERE project = ? AND ticket_key = ?').get(p, key);

const SKIP = (await openDb()) === null && 'node:sqlite unavailable in this runtime';

test('W1 DELETE with the matching comment_id deletes the row; a second DELETE answers deleted 0', { skip: SKIP }, async () => {
  const { db, DB } = await fresh();
  assert.equal((await post(DB, rec('w1', 'BH-1001', 1001, 9100001, '0123456789abcdef'))).status, 200);
  let r = await del(DB, 'project=w1&key=BH-1001&comment_id=9100001');
  assert.deepEqual([r.status, r.body.ok, r.body.deleted], [200, true, 1]);
  assert.equal(row(db, 'w1', 'BH-1001'), undefined);
  r = await del(DB, 'project=w1&key=BH-1001&comment_id=9100001');
  assert.deepEqual([r.status, r.body.deleted], [200, 0], 'idempotent');
});

test('W2 DELETE with another comment_id deletes nothing: a newer comment is never forgotten', { skip: SKIP }, async () => {
  const { db, DB } = await fresh();
  await post(DB, rec('w2', 'BH-1002', 1002, 9100003, '0123456789abcdef'));
  const r = await del(DB, 'project=w2&key=BH-1002&comment_id=9100002');
  assert.deepEqual([r.status, r.body.deleted], [200, 0]);
  assert.equal(row(db, 'w2', 'BH-1002').comment_id, 9100003);
});

test('W3 DELETE for another project with the same key deletes nothing (wrong tenant: 0 rows)', { skip: SKIP }, async () => {
  const { db, DB } = await fresh();
  await post(DB, rec('w3-a', 'BH-1003', 1003, 9100004, '0123456789abcdef'));
  const r = await del(DB, 'project=w3-b&key=BH-1003&comment_id=9100004');
  assert.deepEqual([r.status, r.body.deleted], [200, 0]);
  assert.equal(row(db, 'w3-a', 'BH-1003').comment_id, 9100004);
});

test('W4 DELETE 400s name the field', { skip: SKIP }, async () => {
  const { db, DB } = await fresh();
  await post(DB, rec('w4', 'BH-1004', 1004, 9100005, '0123456789abcdef'));
  for (const [q, field] of [
    ['key=BH-1004&comment_id=9100005', 'project'],
    ['project=W4!&key=BH-1004&comment_id=9100005', 'project'],
    ['project=w4&comment_id=9100005', 'key'],
    ['project=w4&key=bh%201004&comment_id=9100005', 'key'],
    ['project=w4&key=BH-1004', 'comment_id'],
    ['project=w4&key=BH-1004&comment_id=0', 'comment_id'],
    ['project=w4&key=BH-1004&comment_id=1.5', 'comment_id'],
    ['project=w4&key=BH-1004&comment_id=12abc', 'comment_id'],
  ]) {
    const r = await del(DB, q);
    assert.deepEqual([r.status, r.body && r.body.error], [400, field], q);
  }
  assert.equal(row(db, 'w4', 'BH-1004').comment_id, 9100005, 'a refused DELETE deletes nothing');
});

test('W5 POST fingerprint null stores an empty hash, final 0; the due answer lists it with its id', { skip: SKIP }, async () => {
  const { db, DB } = await fresh();
  project(db, 'w5');
  queue(db, 'w5', 'BH-1005', '1005');
  const r = await post(DB, rec('w5', 'BH-1005', 1005, 9100006, null, { final: true }));
  assert.deepEqual([r.status, r.body.ok], [200, true], JSON.stringify(r.body));
  const got = row(db, 'w5', 'BH-1005');
  assert.deepEqual([got.comment_id, got.fingerprint, got.final], [9100006, '', 0]);
  const due = await call(DB, '/api/ticket-status-comments/due?project=w5');
  assert.equal(due.status, 200);
  assert.deepEqual(due.body.due.map((d) => [d.key, d.comment_id]), [['BH-1005', 9100006]],
    'an empty hash never equals a rendered one: due, and the lane edits the stored id');
  // The real hash then makes it not due.
  await post(DB, rec('w5', 'BH-1005', 1005, 9100006, due.body.due[0].fingerprint));
  assert.deepEqual((await call(DB, '/api/ticket-status-comments/due?project=w5')).body.due, []);
});

test('W6 POST fingerprint other than 16 hex or null is still 400', { skip: SKIP }, async () => {
  const { db, DB } = await fresh();
  for (const fp of ['xyz', '', undefined, 12]) {
    const r = await post(DB, rec('w6', 'BH-1006', 1006, 9100007, fp));
    assert.deepEqual([r.status, r.body && r.body.error], [400, 'fingerprint'], JSON.stringify(fp));
  }
  assert.equal(row(db, 'w6', 'BH-1006'), undefined);
});

test('W7 EXPLAIN QUERY PLAN: SQL.forget uses the primary key at volume', { skip: SKIP }, async () => {
  const { db } = await fresh();
  const { SQL } = await M();
  db.exec('BEGIN');
  const c = db.prepare(`INSERT INTO ticket_status_comments (project, ticket_key, issue, comment_id, fingerprint, state, final, created_at, updated_at)
    VALUES (?, ?, ?, ?, '0123456789abcdef', 'queued', 0, ?, ?)`);
  for (let i = 0; i < 20000; i++) c.run(['a', 'b', 'c', 'd', 'e'][i % 5], `T-${i}`, i + 1, 900000 + i, ago(i), ago(i));
  db.exec('COMMIT');
  db.exec('ANALYZE');
  const plan = db.prepare(`EXPLAIN QUERY PLAN ${SQL.forget}`).all('a', 'T-5', 900005).map((r) => r.detail).join(' | ');
  assert.match(plan, /USING (PRIMARY KEY|INDEX sqlite_autoindex_ticket_status_comments_1)/, plan);
  assert.doesNotMatch(plan, /SCAN/, plan);
});
