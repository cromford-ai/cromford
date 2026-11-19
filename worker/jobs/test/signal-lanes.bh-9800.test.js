// BH-9800 (slice C0): the lane gate of the signal key lane read. A lane listed
// in the settings row signal_keys.read_lanes gets the web-task rules: its claim
// mints a run token, and its enqueue needs the operator token. Driven through
// the REAL worker.fetch over a node:sqlite D1 with the composed jobs schema.
//
// G1  a listed lane's claim answers vault_token and D1 keeps only its hash
// G2  with the row empty the same lane's claim has no token (web-vault T5 holds)
// G3  an enqueue of a listed lane without the admin token is 403 (single and batch)
// G4  with the admin token it is 201 / 200
// G5  an unlisted lane enqueues and claims exactly as before
// G6  signalReadLanes parses the row: trim, lower case, lane names only
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import { createHash } from 'node:crypto';

const LANES = await import('../src/lib/signal-lanes.js').catch(() => null);

const SECRET = 'fixture-harness-secret';
const ADMIN = 'fixture-admin-token-9800';
const sha = (x) => createHash('sha256').update(x).digest('hex');

async function fresh(t) {
  const o = await openDb();
  if (!o) { t.skip('node:sqlite unavailable'); return null; }
  return { db: o.db, env: { DB: o.DB, HARNESS_SECRET: SECRET, WEB_VAULT_ADMIN_TOKEN: ADMIN } };
}
async function call(env, method, path, body, { admin = null } = {}) {
  const headers = { 'content-type': 'application/json', authorization: `Bearer ${SECRET}` };
  if (admin !== null) headers['x-web-vault-admin-token'] = admin;
  const res = await worker.fetch(new Request(`https://jobs.test${path}`, { method, headers, body: JSON.stringify(body) }), env);
  return { status: res.status, body: await res.json().catch(() => null) };
}
const enqueue = (env, lane, project, opts) => call(env, 'POST', '/api/lane-runs', { lane, project, args: ['bin/x.sh'] }, opts);
const batch = (env, lane, project, opts) => call(env, 'POST', '/api/lane-runs/batch', { lane, rows: [{ project, args: ['bin/x.sh'] }] }, opts);
const claim = (env, machine, lanes) => call(env, 'POST', '/api/lane-runs/claim', { machine, lanes });
const setting = (db, key, value) => db.prepare(`INSERT INTO settings (key,value,note,actor,updated_at) VALUES (?,?,'','test','2026-11-17T00:00:00Z')
  ON CONFLICT(key) DO UPDATE SET value=excluded.value`).run(key, value);
const n = (db, table) => Number(db.prepare(`SELECT COUNT(*) AS n FROM ${table}`).get().n);

test('G1 a claim of a lane listed in signal_keys.read_lanes answers vault_token and stores only its hash', async (t) => {
  const s = await fresh(t); if (!s) return;
  setting(s.db, 'signal_keys.read_lanes', 'Sentry-Triage, posthog-pull');
  assert.equal((await enqueue(s.env, 'sentry-triage', 'p-g1', { admin: ADMIN })).status, 201);
  const c = await claim(s.env, 'm-g1', ['sentry-triage']);
  assert.equal(c.status, 200, JSON.stringify(c.body));
  assert.equal(c.body.lane, 'sentry-triage');
  assert.match(c.body.vault_token || '', /^[A-Za-z0-9_-]{43}$/);
  const rows = s.db.prepare('SELECT run_id, machine, token_hash FROM web_vault_run_token').all();
  assert.deepEqual(rows.map((r) => ({ ...r })), [{ run_id: c.body.id, machine: 'm-g1', token_hash: sha(c.body.vault_token) }]);
});

test('G2 with signal_keys.read_lanes empty the same claim has no token and writes no token row', async (t) => {
  const s = await fresh(t); if (!s) return;
  assert.equal((await enqueue(s.env, 'sentry-triage', 'p-g2')).status, 201);
  const c = await claim(s.env, 'm-g2', ['sentry-triage']);
  assert.equal(c.status, 200);
  assert.equal('vault_token' in c.body, false);
  assert.equal(n(s.db, 'web_vault_run_token'), 0);
});

test('G3 an enqueue of a listed lane without the admin token is 403 on /api/lane-runs and /api/lane-runs/batch', async (t) => {
  const s = await fresh(t); if (!s) return;
  setting(s.db, 'signal_keys.read_lanes', 'sentry-triage');
  for (const admin of [null, ADMIN + 'x']) {
    const a = await enqueue(s.env, 'sentry-triage', 'p-g3', { admin });
    assert.equal(a.status, 403, JSON.stringify(a.body));
    assert.match(a.body.error, /operator token/);
    const b = await batch(s.env, 'sentry-triage', 'p-g3', { admin });
    assert.equal(b.status, 403, JSON.stringify(b.body));
  }
  assert.equal(n(s.db, 'lane_runs'), 0);
});

test('G4 with the admin token a listed lane enqueues (single 201, batch 200)', async (t) => {
  const s = await fresh(t); if (!s) return;
  setting(s.db, 'signal_keys.read_lanes', 'sentry-triage');
  assert.equal((await enqueue(s.env, 'sentry-triage', 'p-g4a', { admin: ADMIN })).status, 201);
  assert.equal((await batch(s.env, 'sentry-triage', 'p-g4b', { admin: ADMIN })).status, 200);
  assert.equal(n(s.db, 'lane_runs'), 2);
});

test('G5 an unlisted lane enqueues with the bearer and claims with no token, as before; web-task is unchanged', async (t) => {
  const s = await fresh(t); if (!s) return;
  setting(s.db, 'signal_keys.read_lanes', 'sentry-triage');
  assert.equal((await enqueue(s.env, 'demo', 'p-g5')).status, 201);
  assert.equal((await batch(s.env, 'demo', 'p-g5b')).status, 200);
  const c = await claim(s.env, 'm-g5', ['demo']);
  assert.equal(c.status, 200);
  assert.equal('vault_token' in c.body, false);
  assert.equal((await enqueue(s.env, 'web-task', 'p-g5')).status, 403, 'web-task still needs the operator token');
  assert.equal((await enqueue(s.env, 'web-task', 'p-g5', { admin: ADMIN })).status, 201);
  const w = await claim(s.env, 'm-g5', ['web-task']);
  assert.match(w.body.vault_token || '', /^[A-Za-z0-9_-]{43}$/, 'web-task still mints a token');
});

test('G6 signalReadLanes: trim, lower case, lane names only; absent is []', () => {
  assert.ok(LANES, 'src/lib/signal-lanes.js exists');
  assert.deepEqual(LANES.signalReadLanes(' Sentry-Triage , ,bad lane!, posthog.pull '), ['sentry-triage', 'posthog.pull']);
  assert.deepEqual(LANES.signalReadLanes(null), []);
  assert.deepEqual(LANES.signalReadLanes(''), []);
});
