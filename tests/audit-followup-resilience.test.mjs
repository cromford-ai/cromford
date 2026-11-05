import { test, mock } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import worker from '../worker/watchdog/src/index.js';
import { failoverTick } from '../worker/watchdog/src/failover.js';

for (const file of ['audit-followup-resilience-egress.py', 'audit-followup-resilience-restore.py']) {
  test(file, { timeout: 30000 }, () => {
    const result = spawnSync('python3', ['-B', fileURLToPath(new URL(file, import.meta.url))], { encoding: 'utf8', timeout: 20000, maxBuffer: 262144 });
    assert.equal(result.status, 0, result.error?.message || result.stderr || result.stdout);
  });
}

const NOW = Date.parse('2026-11-05T12:30:00Z');
const MIN = 60000;
function kv(seed = {}) {
  const m = new Map(Object.entries(seed));
  return { m, async get(k) { return m.get(k) ?? null; }, async put(k, v) { m.set(k, v); }, async delete(k) { m.delete(k); }, async list({ prefix = '' } = {}) { return { keys: [...m.keys()].filter(k => k.startsWith(prefix)).map(name => ({ name })), list_complete: true }; } };
}

test('failed liveness delivery is retried on the next tick', async t => {
  t.mock.timers.enable({ apis: ['Date'], now: NOW });
  const KV = kv({ 'ping:box-hub': JSON.stringify({ ts: NOW - 20 * MIN }) });
  let attempts = 0;
  t.mock.method(globalThis, 'fetch', async () => { attempts++; return new Response('', { status: attempts === 1 ? 503 : 200 }); });
  const env = { KV, TELEGRAM_BOT_TOKEN: 'fixture-token', TELEGRAM_CHAT_ID: 'fixture-chat' };
  await worker.scheduled({}, env);
  assert.equal(KV.m.has('alerted:ping:box-hub'), false);
  await worker.scheduled({}, env);
  assert.equal(attempts, 2);
  assert.equal(KV.m.get('alerted:ping:box-hub'), String(NOW));
});

test('failed recovery delivery retains the incident until recovery is delivered', async t => {
  t.mock.timers.enable({ apis: ['Date'], now: NOW });
  const KV = kv({ 'ping:box-hub': JSON.stringify({ ts: NOW }), 'alerted:ping:box-hub': String(NOW - MIN) });
  let attempts = 0;
  t.mock.method(globalThis, 'fetch', async () => { attempts++; return new Response('', { status: attempts === 1 ? 503 : 200 }); });
  const env = { KV, TELEGRAM_BOT_TOKEN: 'fixture-token', TELEGRAM_CHAT_ID: 'fixture-chat' };
  await worker.scheduled({}, env);
  assert.equal(KV.m.has('alerted:ping:box-hub'), true);
  await worker.scheduled({}, env);
  assert.equal(attempts, 2);
  assert.equal(KV.m.has('alerted:ping:box-hub'), false);
});

test('automatic failover requires a current snapshot as well as a recent report', async t => {
  for (const snapshot of ['20261105T100000Z', '20261105T123100Z', 'invalid']) {
    const KV = kv({ 'cfg:failover': 'on', 'cfg:failover_hub_fence_s': '480', 'ping:box-hub': JSON.stringify({ ts: NOW - 20 * MIN }), 'ping:fixture-standby': JSON.stringify({ ts: NOW }), 'standby:fixture-standby': JSON.stringify({ ts: NOW, ok: true, of: 'box-hub', snapshot }) });
    let promotes = 0;
    const fetchMock = mock.method(globalThis, 'fetch', async (url) => {
      if (String(url).endsWith('/api/hub/promote')) { promotes++; return Response.json({ ok: true, lease: { holder: 'fixture-standby', epoch: 3 } }); }
      if (String(url).endsWith('/api/hub/lease')) return Response.json({ as_of: new Date(NOW).toISOString(), lease: { holder: 'box-hub', epoch: 2, updated_at: new Date(NOW - 11 * MIN).toISOString() } });
      return new Response('');
    });
    try { await failoverTick({ KV, JOBS_URL: 'https://jobs.fixture.invalid', HARNESS_SECRET: 'fixture-fleet-token' }, NOW); }
    finally { fetchMock.mock.restore(); }
    assert.equal(promotes, 0, snapshot);
    assert.equal(KV.m.has('failover:2'), false, snapshot);
  }
});
