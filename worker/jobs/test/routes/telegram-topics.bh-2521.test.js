import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../../src/index.js';
import { openDb } from '../lib/d1-sqlite.bh-1030.js';

// BH-2678 (BH-2521.3) — GET /api/telegram-topics also answers `rows`, the
// table the /hub CHAT BINDINGS panel renders, ordered by project. `topics`
// (what bin/lib/jobs/jobs.sh and bin/poll-commands.sh read) stays as it was.
//
// Driven through the real worker.fetch (D2) over the real schema.sql in
// node:sqlite, so the PUT really persists and ORDER BY really runs.

const SECRET = 'test-secret';
const T0 = Date.parse('2026-09-26T09:00:00Z');

async function open(t) {
  t.mock.timers.enable({ apis: ['Date'], now: T0 });
  const env = await openDb();
  if (!env) t.skip('node:sqlite unavailable on this runtime');
  return env;
}

async function call(DB, method, body) {
  const init = { method, headers: { authorization: `Bearer ${SECRET}` } };
  if (body !== undefined) {
    init.body = JSON.stringify(body);
    init.headers['content-type'] = 'application/json';
  }
  const res = await worker.fetch(new Request('https://jobs.test/api/telegram-topics', init), { DB, HARNESS_SECRET: SECRET });
  return { status: res.status, body: await res.json() };
}

test('W1: rows come back ordered by project, not by insert order', async (t) => {
  const env = await open(t); if (!env) return;
  const a = await call(env.DB, 'PUT', { project: 'project-5', thread_id: 42, actor: 'console:a@x' });
  assert.equal(a.status, 200, JSON.stringify(a.body));
  t.mock.timers.tick(60_000);
  const b = await call(env.DB, 'PUT', { project: 'cromford', thread_id: 6, actor: 'console:b@x' });
  assert.equal(b.status, 200, JSON.stringify(b.body));
  const r = await call(env.DB, 'GET');
  assert.equal(r.status, 200);
  assert.deepEqual(r.body.rows, [
    { project: 'cromford', thread_id: 6, actor: 'console:b@x', updated_at: '2026-09-26T09:01:00Z' },
    { project: 'project-5', thread_id: 42, actor: 'console:a@x', updated_at: '2026-09-26T09:00:00Z' },
  ]);
});

test('W2: topics is still the project -> thread map, and a move changes both shapes', async (t) => {
  const env = await open(t); if (!env) return;
  await call(env.DB, 'PUT', { project: 'project-5', thread_id: 42, actor: 'console:a@x' });
  await call(env.DB, 'PUT', { project: 'cromford', thread_id: 6, actor: 'console:b@x' });
  const r = await call(env.DB, 'GET');
  assert.deepEqual(r.body.topics, { 'cromford': 6, 'project-5': 42 });
  assert.equal(typeof r.body.as_of, 'string');
  assert.deepEqual(Object.keys(r.body).sort(), ['as_of', 'rows', 'topics']);

  t.mock.timers.tick(120_000);
  const m = await call(env.DB, 'PUT', { project: 'project-5', thread_id: 43, actor: 'console:c@x' });
  assert.deepEqual(m.body, { topic: { project: 'project-5', thread_id: 43 } });
  const after = await call(env.DB, 'GET');
  assert.deepEqual(after.body.topics, { 'cromford': 6, 'project-5': 43 });
  assert.deepEqual(after.body.rows[1], {
    project: 'project-5', thread_id: 43, actor: 'console:c@x', updated_at: '2026-09-26T09:02:00Z',
  });
});

test('W3: an empty table answers an empty map and an empty rows array', async (t) => {
  const env = await open(t); if (!env) return;
  const r = await call(env.DB, 'GET');
  assert.equal(r.status, 200);
  assert.deepEqual(r.body.topics, {});
  assert.deepEqual(r.body.rows, []);
});

test('W4: a row with no actor reads actor null', async (t) => {
  const env = await open(t); if (!env) return;
  await call(env.DB, 'PUT', { project: 'project-3', thread_id: 7 });
  const r = await call(env.DB, 'GET');
  assert.deepEqual(r.body.rows, [{ project: 'project-3', thread_id: 7, actor: null, updated_at: '2026-09-26T09:00:00Z' }]);
});
