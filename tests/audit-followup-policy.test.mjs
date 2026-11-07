import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../worker/jobs/src/index.js';
import { openDb } from '../worker/jobs/test/lib/d1-sqlite.bh-1030.js';

const FLEET = 'fixture-fleet-token';
const HUMAN = 'fixture-independent-human-token';
const call = async (DB, path, body, token, extra = {}) => {
  const req = new Request(`https://jobs.test${path}`, { method: path === '/api/settings' ? 'PUT' : 'POST',
    headers: { authorization: `Bearer ${FLEET}`, 'content-type': 'application/json',
      ...(token === undefined ? {} : { 'x-human-verdict-token': token }) }, body: JSON.stringify(body) });
  const res = await worker.fetch(req, { DB, HARNESS_SECRET: FLEET, HUMAN_VERDICT_TOKEN: HUMAN,
    HUMAN_VERDICT_SIG_KEY: 'fixture-signing-key', HUMAN_VERDICT_ENFORCE: '1', ...extra });
  return { status: res.status, body: await res.json() };
};

test('risk allowlist can only narrow without independent human authority', async () => {
  const { db, DB } = await openDb();
  const key = 'risk_tier.low_globs';
  assert.equal((await call(DB, '/api/settings', { key, value: 'docs/**' }, HUMAN)).status, 200);
  const before = db.prepare('SELECT COUNT(*) AS n FROM setting_sigs WHERE key=?').get(key).n;
  const refused = await call(DB, '/api/settings', { key, value: 'docs/** tests/**' });
  assert.equal(refused.status, 403);
  assert.deepEqual(refused.body.added, ['tests/**']);
  assert.equal(db.prepare('SELECT value FROM settings WHERE key=?').get(key).value, 'docs/**');
  assert.equal(db.prepare('SELECT COUNT(*) AS n FROM setting_sigs WHERE key=?').get(key).n, before);
  assert.equal((await call(DB, '/api/settings', { key, value: 'docs/** tests/**' }, HUMAN)).status, 200);
  assert.equal((await call(DB, '/api/settings', { key, value: 'tests/**' })).status, 200);
});

test('unknown risk policy and unknown default changes require a human', async () => {
  const { DB } = await openDb();
  for (const key of ['risk_tier.low_globs', 'risk_tier.high_globs', 'risk_tier.low_lines', 'risk_tier.future_gate']) {
    assert.equal((await call(DB, '/api/settings', { key, value: '1' })).status, 403, key);
    assert.equal((await call(DB, '/api/settings', { key, value: '1' }, HUMAN)).status, 200, key);
    assert.equal((await call(DB, '/api/settings', { key, value: '1' })).status, 200, `${key} no-op`);
  }
  assert.equal((await call(DB, '/api/settings', { key: 'risk_tier.high_globs', value: '1 docs/**' })).status, 200);
  assert.equal((await call(DB, '/api/settings', { key: 'risk_tier.high_globs', value: 'docs/**' })).status, 403);
  assert.equal((await call(DB, '/api/settings', { key: 'risk_tier.low_lines', value: '2' })).status, 403);
});

test('human credential must be configured independently of fleet and lead tokens', async () => {
  const { DB } = await openDb();
  const body = { agent: 'watchman', autonomy: 'augmentation', actor: 'fixture-operator' };
  for (const [token, extra] of [[HUMAN, { HUMAN_VERDICT_TOKEN: '' }],
    [FLEET, { HUMAN_VERDICT_TOKEN: FLEET }], [HUMAN, { LEAD_VERDICT_TOKEN: HUMAN }]]) {
    assert.equal((await call(DB, '/api/staff/agents/autonomy', body, token, extra)).status, 403);
  }
  assert.equal((await call(DB, '/api/staff/agents/autonomy', body, HUMAN)).status, 200);
});

test('human-only native decisions require independent authority, while demotions remain automatic', async () => {
  const { db, DB } = await openDb();
  db.prepare("UPDATE staff_agents SET cap='autonomy' WHERE name='watchman'").run();
  db.prepare("INSERT INTO staff_classes (agent,class,cap,streak,updated_at) VALUES ('watchman','fixture-review','autonomy',99,'fixture')").run();
  db.prepare("INSERT INTO archie_classes (class,state,streak,updated_at) VALUES ('fixture-review','ask_first',99,'fixture')").run();
  db.prepare("INSERT INTO staff_promotions (agent,from_level,to_level,agreements,status,created_at) VALUES ('watchman','automation','augmentation',5,'pending','fixture')").run();
  const id = db.prepare('SELECT id FROM staff_promotions').get().id;
  const cases = [
    ['/api/staff/agents/autonomy', { agent: 'watchman', autonomy: 'augmentation', actor: 'fixture-operator' }],
    ['/api/staff/classes/delegation', { agent: 'watchman', class: 'fixture-review', decision: 'delegate', actor: 'fixture-operator' }],
    ['/api/archie/classes/delegation', { class: 'fixture-review', decision: 'delegate', min_streak: 5, actor: 'fixture-operator' }],
    ['/api/staff/promotions/decide', { id, decision: 'void', reason: 'fixture reason', actor: 'fixture-operator' }],
    ['/api/staff/suppressions', { fingerprint: 'a'.repeat(64), reason: 'fixture reason', approver: 'fixture-operator', expiresAt: '2099-01-01T00:00:00Z' }],
  ];
  for (const [path, body] of cases) {
    for (const token of [undefined, 'fixture-wrong-token', FLEET]) {
      assert.equal((await call(DB, path, body, token)).status, 403, `${path} without human authority`);
    }
    assert.equal((await call(DB, path, body, HUMAN)).status, 200, path);
  }
  const suppressionId = db.prepare('SELECT id FROM staff_suppressions').get().id;
  db.prepare("UPDATE staff_suppressions SET status='pending' WHERE id=?").run(suppressionId);
  const body = { id: suppressionId, decision: 'approve', approver: 'fixture-operator' };
  assert.equal((await call(DB, '/api/staff/suppressions/decide', body)).status, 403);
  assert.equal(db.prepare('SELECT status FROM staff_suppressions WHERE id=?').get(suppressionId).status, 'pending');
  assert.equal((await call(DB, '/api/staff/suppressions/decide', body, HUMAN)).status, 200);
  assert.equal((await call(DB, '/api/staff/agents/autonomy', { agent: 'watchman', autonomy: 'automation', actor: 'archie' })).status, 200);
  assert.equal((await call(DB, '/api/staff/classes/delegation', { agent: 'watchman', class: 'fixture-review', decision: 'ask_first', actor: 'archie' })).status, 200);
  assert.equal((await call(DB, '/api/archie/classes/delegation', { class: 'fixture-review', decision: 'ask_first', actor: 'archie' })).status, 200);
});
