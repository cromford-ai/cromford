// BH-10218 W2 — a `repository` delivery that changes what a repo-metadata
// memo holds (the default branch, the name, the owner) lands as a wake row of
// kind `repo`, keyed on the numeric repository id. bin/lib/repo-change-mark.sh
// reads it from the wake mirror as the change signal of bin/lib/repo-meta.sh.
// Every other `repository` action, and an `edited` that did not touch the
// default branch, is dropped. The existing `push` mapping is unchanged.
//
// R1-R4 call githubWakeOf (the receiver's mapping: wakeOf, then
// src/lib/wake-of-repository.js) directly; R5-R6 drive the real worker.fetch with a SIGNED
// delivery (the deliver()/fakeDB shape of wakeof-new-events.bh-4058.test.js),
// so the route, the signature check and wakeOf are all on the path.
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { githubWakeOf as wakeOf } from '../src/lib/wake-of-repository.js';
import { createHmac } from 'node:crypto';

const WH_SECRET = 'wh-test-secret';
const SECRET = 'test-secret';
const repository = { id: 123456789, full_name: 'example-org/cromford', default_branch: 'main' };

function fakeDB() {
  const calls = [];
  const stmt = (sql) => ({
    bind: (...binds) => ({
      first: async () => null,
      all: async () => ({ results: [] }),
      run: async () => {
        calls.push({ sql: sql.replace(/\s+/g, ' ').trim(), binds });
        return { meta: { changes: 1, last_row_id: 1 } };
      },
    }),
    first: async () => null,
    all: async () => ({ results: [] }),
    run: async () => ({ meta: { changes: 1 } }),
  });
  return { prepare: stmt, _calls: calls };
}
const deliver = (event, payload) => {
  const raw = JSON.stringify(payload);
  const headers = {
    'content-type': 'application/json', 'x-github-event': event,
    'x-hub-signature-256': 'sha256=' + createHmac('sha256', WH_SECRET).update(raw).digest('hex'),
  };
  const db = fakeDB();
  const req = new Request('https://jobs.test/webhooks/github', { method: 'POST', headers, body: raw });
  const env = { DB: db, HARNESS_SECRET: SECRET, GITHUB_WEBHOOK_SECRET: WH_SECRET };
  return worker.fetch(req, env).then(async (res) => ({
    status: res.status, body: await res.json().catch(() => null), db,
  }));
};
const inserts = (r) => r.db._calls.filter((c) => /INSERT INTO wakes/.test(c.sql));

test('R1: repository.edited with changes.default_branch -> {kind: repo, key: <id>}', () => {
  const w = wakeOf('repository', { action: 'edited', repository, changes: { default_branch: { from: 'master' } } });
  assert.deepEqual(w, { kind: 'repo', key: '123456789' });
});

test('R2: renamed and transferred -> kind repo', () => {
  assert.deepEqual(wakeOf('repository', { action: 'renamed', repository, changes: { repository: { name: { from: 'old' } } } }),
    { kind: 'repo', key: '123456789' });
  assert.deepEqual(wakeOf('repository', { action: 'transferred', repository }), { kind: 'repo', key: '123456789' });
});

test('R3: edited without default_branch, archived, publicized, privatized, deleted -> null', () => {
  assert.equal(wakeOf('repository', { action: 'edited', repository, changes: { description: { from: 'x' } } }), null);
  assert.equal(wakeOf('repository', { action: 'edited', repository }), null);
  for (const action of ['archived', 'unarchived', 'publicized', 'privatized', 'deleted', 'created']) {
    assert.equal(wakeOf('repository', { action, repository }), null, action);
  }
  // A non-numeric or missing id names no repo: no key, so no row.
  const bad = wakeOf('repository', { action: 'renamed', repository: { full_name: 'example-org/cromford', id: 'x1' } });
  assert.ok(bad === null || bad.key === '', 'a non-numeric id must not become a key');
});

test('R4: the push mapping is unchanged (default branch only)', () => {
  const a = 'a'.repeat(40), b = 'b'.repeat(40);
  assert.deepEqual(wakeOf('push', { ref: 'refs/heads/main', before: b, after: a, repository }),
    { kind: 'push', key: a, event: `push.${b}..${a}` });
  assert.equal(wakeOf('push', { ref: 'refs/heads/feature', before: b, after: a, repository }), null);
});

test('R5: a signed repository.edited (default branch) lands one wake row of kind repo', async () => {
  const r = await deliver('repository', { action: 'edited', repository, changes: { default_branch: { from: 'master' } } });
  assert.equal(r.status, 200);
  assert.equal(r.body.wake.kind, 'repo');
  assert.equal(r.body.wake.key, '123456789');
  const ins = inserts(r);
  assert.equal(ins.length, 1);
  assert.equal(ins[0].binds[1], 'repo');
  assert.equal(ins[0].binds[2], '123456789');
  assert.equal(ins[0].binds[3], 'repository.edited');
});

test('R6: a signed repository.edited of the description is accepted and dropped', async () => {
  const r = await deliver('repository', { action: 'edited', repository, changes: { description: { from: 'x' } } });
  assert.equal(r.status, 202);
  assert.equal(inserts(r).length, 0);
});
