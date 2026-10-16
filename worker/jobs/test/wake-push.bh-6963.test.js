// BH-6963: a push to the repo's DEFAULT branch wakes kind `push`, keyed on the
// after sha, and the row carries the compare range in `event` so
// bin/repair-on-push.sh can read the changed paths once. Every case goes
// through the REAL worker.fetch onto the REAL schema in node:sqlite, so the
// assertions are on rows, not on SQL text.
import test from 'node:test';
import assert from 'node:assert/strict';
import { createHmac } from 'node:crypto';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';

const SECRET = 'gh-secret-fixture';
const REPO = 'Example-Org/example-repo';
const B = 'b'.repeat(40);
const A = 'a'.repeat(40);
const ZERO = '0'.repeat(40);

async function setup(t) {
  const o = await openDb();
  if (!o) { t.skip('node:sqlite unavailable'); return null; }
  const env = { DB: o.DB, HARNESS_SECRET: 'bearer-fixture', GITHUB_WEBHOOK_SECRET: SECRET };
  const wakes = () => o.db.prepare('SELECT repo, kind, key, event FROM wakes ORDER BY id').all()
    .map((r) => ({ ...r }));
  return { ...o, env, wakes };
}

async function push(ctx, payload, delivery) {
  const raw = JSON.stringify(payload);
  const headers = {
    'content-type': 'application/json', 'x-github-event': 'push',
    'x-hub-signature-256': 'sha256=' + createHmac('sha256', SECRET).update(raw).digest('hex'),
  };
  if (delivery) headers['x-github-delivery'] = delivery;
  const res = await worker.fetch(new Request('https://jobs.test/webhooks/github',
    { method: 'POST', headers, body: raw }), ctx.env);
  return { status: res.status, body: await res.json().catch(() => null) };
}

const body = (over = {}) => ({
  ref: 'refs/heads/main', before: B, after: A,
  repository: { full_name: REPO, default_branch: 'main' }, ...over,
});

test('W1: a main push stores kind push, key after, event push.<before>..<after>', async (t) => {
  const c = await setup(t); if (!c) return;
  const r = await push(c, body(), 'd-w1');
  assert.equal(r.status, 200);
  assert.equal(r.body.wake.kind, 'push');
  assert.equal(r.body.wake.key, A);
  assert.equal(r.body.wake.event, `push.${B}..${A}`);
  assert.deepEqual(c.wakes(), [{ repo: REPO, kind: 'push', key: A, event: `push.${B}..${A}` }]);
});

test('W2: a push to a feature branch is ignored and writes no wake', async (t) => {
  const c = await setup(t); if (!c) return;
  const r = await push(c, body({ ref: 'refs/heads/feature/x' }), 'd-w2');
  assert.equal(r.status, 202);
  assert.equal(r.body.ignored, 'push');
  assert.equal(c.wakes().length, 0);
});

test('W3: the same delivery id twice is one row, the second says duplicate', async (t) => {
  const c = await setup(t); if (!c) return;
  const one = await push(c, body(), 'd-w3');
  const two = await push(c, body(), 'd-w3');
  assert.equal(one.body.duplicate, false);
  assert.equal(two.body.duplicate, true);
  assert.equal(c.wakes().length, 1);
});

test('W4: default_branch master wakes on refs/heads/master', async (t) => {
  const c = await setup(t); if (!c) return;
  const r = await push(c, body({ ref: 'refs/heads/master',
    repository: { full_name: REPO, default_branch: 'master' } }), 'd-w4');
  assert.equal(r.status, 200);
  assert.equal(r.body.wake.kind, 'push');
  assert.equal(r.body.wake.event, `push.${B}..${A}`);
});

test('W5: default_branch master drops a push to refs/heads/main', async (t) => {
  const c = await setup(t); if (!c) return;
  const r = await push(c, body({ repository: { full_name: REPO, default_branch: 'master' } }), 'd-w5');
  assert.equal(r.status, 202);
  assert.equal(c.wakes().length, 0);
});

test('W6: an all-zero or absent before stores the bare push event', async (t) => {
  const c = await setup(t); if (!c) return;
  const z = await push(c, body({ before: ZERO }), 'd-w6a');
  assert.equal(z.status, 200);
  assert.equal(z.body.wake.event, 'push');
  const { before, ...noBefore } = body({ after: 'c'.repeat(40) });
  assert.equal(before, B);
  const n = await push(c, noBefore, 'd-w6b');
  assert.equal(n.status, 200);
  assert.equal(n.body.wake.event, 'push');
  // A short sha is a valid key but no compare range.
  const s = await push(c, body({ before: 'abc1234', after: 'd'.repeat(40) }), 'd-w6c');
  assert.equal(s.body.wake.event, 'push');
});

test('W7: an invalid or absent default_branch is treated as main', async (t) => {
  const c = await setup(t); if (!c) return;
  const bad = { full_name: REPO, default_branch: '../x y' };
  const drop = await push(c, body({ ref: 'refs/heads/../x y', repository: bad }), 'd-w7a');
  assert.equal(drop.status, 202);
  const wake = await push(c, body({ repository: bad }), 'd-w7b');
  assert.equal(wake.status, 200);
  assert.equal(wake.body.wake.kind, 'push');
  // A name the charset allows but a ref never holds: `..` is refused too.
  const dots = { full_name: REPO, default_branch: '../x' };
  assert.equal((await push(c, body({ ref: 'refs/heads/../x', repository: dots }), 'd-w7d')).status, 202);
  const none = await push(c, body({ after: 'e'.repeat(40), repository: { full_name: REPO } }), 'd-w7c');
  assert.equal(none.status, 200);
  assert.equal(none.body.wake.event, `push.${B}..${'e'.repeat(40)}`);
});
