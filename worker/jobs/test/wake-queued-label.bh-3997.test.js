import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { createHmac } from 'node:crypto';

const WH_SECRET = 'wh-test-secret';
const SECRET = 'test-secret';

// Minimal fake D1 that proves the INSERT binds and the ON CONFLICT path.
function fakeDB(state) {
  const calls = [];
  const stmt = (sql) => ({
    bind: (...binds) => ({
      first: async () => null,
      all: async () => ({ results: [] }),
      run: async () => {
        calls.push({ sql: sql.replace(/\s+/g, ' ').trim(), binds });
        const noop = state.wakesInsertNoop && /INSERT INTO wakes/.test(sql);
        return { meta: { changes: noop ? 0 : 1, last_row_id: 1 } };
      },
    }),
    first: async () => null,
    all: async () => ({ results: [] }),
    run: async () => ({ meta: { changes: 1 } }),
  });
  return { prepare: stmt, _calls: calls };
}

const deliver = (event, payload, { sign = true, state = {}, envSecret = WH_SECRET, tamper = null } = {}) => {
  const raw = typeof payload === 'string' ? payload : JSON.stringify(payload);
  const headers = { 'content-type': 'application/json', 'x-github-event': event };
  if (sign) {
    headers['x-hub-signature-256'] = 'sha256=' + createHmac('sha256', WH_SECRET).update(raw).digest('hex');
  }
  const db = fakeDB(state);
  const req = new Request('https://jobs.test/webhooks/github', {
    method: 'POST', headers, body: tamper === null ? raw : tamper,
  });
  const env = { DB: db, HARNESS_SECRET: SECRET };
  if (envSecret !== null) env.GITHUB_WEBHOOK_SECRET = envSecret;
  return worker.fetch(req, env).then(async (res) => ({
    status: res.status, body: await res.json().catch(() => null), db,
  }));
};

// BH-3997: Mergify's `queued` label is the moment a "not in the merge queue"
// alert becomes false, so that ONE label wakes the fleet. Every other label
// change still moves nothing the fleet watches and stays dropped.
const repository = { full_name: 'example-org/cromford' };
const inserts = (r) => r.db._calls.filter((c) => /INSERT INTO wakes/.test(c.sql));

test('webhook: pull_request.labeled with label queued is stored as a pr wake', async () => {
  const r = await deliver('pull_request', {
    action: 'labeled', number: 3928, label: { name: 'queued' }, repository,
    pull_request: { number: 3928 },
  });
  assert.equal(r.status, 200);
  assert.equal(r.body.wake.kind, 'pr');
  assert.equal(r.body.wake.key, '3928');
  assert.equal(r.body.wake.event, 'pull_request.labeled');
  assert.equal(inserts(r).length, 1);
  assert.equal(inserts(r)[0].binds[3], 'pull_request.labeled');
});

// BH-9934: `merge-queue` left this list. It is one of WAKE_PR_LABELS now and
// wakes as pull_request.labeled.merge-queue (test/webhook-receiver.bh-9934 L1).
test('webhook: any other label, or a label-less labeled, is still dropped', async () => {
  for (const label of [{ name: 'checking' }, { name: 'Queued' }, undefined]) {
    const payload = { action: 'labeled', number: 3928, repository, pull_request: { number: 3928 } };
    if (label) payload.label = label;
    const r = await deliver('pull_request', payload);
    assert.equal(r.status, 202, `label ${JSON.stringify(label)} must be accepted-and-dropped`);
    assert.equal(r.body.ignored, 'pull_request');
    assert.equal(inserts(r).length, 0, `label ${JSON.stringify(label)} wrote a row`);
  }
});

test('webhook: unlabeled queued is dropped', async () => {
  const r = await deliver('pull_request', {
    action: 'unlabeled', number: 3928, label: { name: 'queued' }, repository,
    pull_request: { number: 3928 },
  });
  assert.equal(r.status, 202);
  assert.equal(inserts(r).length, 0);
});

test('webhook: pull_request.closed is unchanged', async () => {
  const r = await deliver('pull_request', {
    action: 'closed', number: 3917, repository, pull_request: { number: 3917, merged: true },
  });
  assert.equal(r.status, 200);
  assert.equal(r.body.wake.event, 'pull_request.closed');
  assert.equal(r.body.wake.key, '3917');
  assert.equal(inserts(r).length, 1);
});
