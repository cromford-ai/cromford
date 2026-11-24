// BH-9901: pr_stage's `client_approval` field, read from the hub ledger row
// (kind client-approval, key "<owner/name lowercased>#<pr>") through the
// console's coord proxy. Every case goes through the REAL registry and the
// REAL consoleFetch against the stub console HTTP server. M7 reads the exact
// row the box writes: tests/fixtures/client-approval/ledger-row.bh-9901.json.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { loadTools, callTool } from '../lib/tools.mjs';
import { consoleFetch } from '../lib/console.mjs';
import { startStub } from './lib/stub-console.mjs';
import { clientApprovalOf } from '../tools/merge-queue.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const LIVE_FIXTURE = JSON.parse(readFileSync(join(HERE, 'fixtures/merge-queue-live.bh-5008.json'), 'utf8'));
const ROW_FIXTURE = JSON.parse(readFileSync(join(HERE, '../../tests/fixtures/client-approval/ledger-row.bh-9901.json'), 'utf8'));
const SECRET = 'sec-fixture';
// The fixture's repo comes from its key, never typed here: G2
// (generic-defaults.test.mjs) keeps owner names out of mcp/. Mixed case on
// purpose, so the call also proves the read lowercases the key.
const [FX_REPO_LC, FX_PR] = ROW_FIXTURE.key.split('#');
const FX_REPO = FX_REPO_LC.split('/').map((p) => p[0].toUpperCase() + p.slice(1)).join('/');
const NOW = Date.parse('2026-11-18T12:06:40Z'); // 3600 s after the fixture's requested_at

const LIVE = '/api/coord/merge-queue/live';
const events = (repo, n) => `/api/coord/pr-state-events?repo=${encodeURIComponent(repo)}&number=${n}&limit=50`;
const tiers = (repo, n) => `/api/coord/risk-tiers?repo=${encodeURIComponent(repo)}&pr=${n}&limit=1`;
// The key literal is written out, not derived, so a dropped lowercase is a miss.
const ledgerPath = (key) => `/api/coord/ledger?kind=client-approval&key=${encodeURIComponent(key)}`;

const EVENTS_101 = { rows: [
  { state: 'queue', since: '2026-10-09T03:20:00Z', reason: 'dequeued(Jobs worker failed alone)', at: '2026-10-09T03:20:01Z' },
] };
const EVENTS_102 = { rows: [
  { state: 'queue', since: '2026-10-09T03:10:00Z', reason: 'checking', at: '2026-10-09T03:10:01Z' },
  { state: 'lead_block', since: '2026-10-09T02:10:00Z', reason: 'missing test for X', at: '2026-10-09T02:10:01Z' },
] };
const NO_TIERS = { json: { rows: [] } };

const detail = (over = {}) => JSON.stringify({
  v: 1, project: 'widgets', head: 'a'.repeat(40), ticket_id: 'W-7',
  ticket_url: 'https://board.example.test/feature-board?ticket=W-7', request_id: 'r-fixture-1',
  requested_at: '2026-11-18T11:06:40Z', closed_at: null, close_reason: null, ...over,
});
const row = (key, over = {}) => ({ ledger: {
  kind: 'client-approval', key, status: 'waiting', detail: detail(),
  created_at: '2026-11-18T11:06:41Z', updated_at: '2026-11-18T11:06:41Z', ...over,
} });

function routes(extra = {}) {
  return {
    [LIVE]: { json: LIVE_FIXTURE },
    [events('acme/widgets', 101)]: { json: EVENTS_101 },
    [events('acme/widgets', 102)]: { json: EVENTS_102 },
    [tiers('acme/widgets', 101)]: NO_TIERS,
    [tiers('acme/widgets', 102)]: NO_TIERS,
    [ledgerPath('acme/widgets#101')]: { json: row('acme/widgets#101') },
    [ledgerPath('acme/widgets#102')]: { json: row('acme/widgets#102') },
    ...extra,
  };
}

const registry = await loadTools(new URL('../tools/', import.meta.url));

async function withStub(t, r = routes(), ctxExtra = {}) {
  const stub = await startStub({ routes: r });
  t.after(() => stub.close());
  const ctx = { cfg: { url: stub.url, token: null, secret: SECRET }, now: NOW, ...ctxExtra };
  const call = async (args) => {
    const res = await callTool(registry, 'pr_stage', args, ctx);
    assert.notEqual(res.isError, true, res.content?.[0]?.text);
    return res.structuredContent;
  };
  const api = () => stub.requests.filter((q) => !q.path.startsWith('/login/')).map((q) => q.path);
  return { stub, ctx, call, api };
}

const WAITING = {
  state: 'waiting', label: 'waiting for client approval', ticket_id: 'W-7',
  ticket_url: 'https://board.example.test/feature-board?ticket=W-7',
  since: '2026-11-18T11:06:40Z', age_s: 3600, head: 'a'.repeat(40),
};

test('M1 a waiting row: client_approval fields, and blocked_on when nothing else blocks', async (t) => {
  const { call, api } = await withStub(t);
  const o = await call({ repo: 'acme/widgets', pr: 102 });
  assert.deepEqual(o.client_approval, WAITING);
  assert.equal(o.blocked_on, 'waiting for client approval');
  assert.equal(o.partial, undefined);
  assert.ok(api().includes(ledgerPath('acme/widgets#102')));
});

test('M2 a queue detail present: blocked_on keeps the queue detail', async (t) => {
  const { call } = await withStub(t);
  const o = await call({ repo: 'acme/widgets', pr: 101 });
  assert.deepEqual(o.client_approval, WAITING);
  assert.equal(o.blocked_on, 'Jobs worker failed alone');
});

test('M3 a 404 (no row): client_approval null, no partial, blocked_on unchanged', async (t) => {
  const { call } = await withStub(t, routes({ [ledgerPath('acme/widgets#102')]: { status: 404, json: { error: 'not found' } } }));
  const o = await call({ repo: 'acme/widgets', pr: 102 });
  assert.equal(o.client_approval, null);
  assert.equal(o.partial, undefined);
  assert.equal(o.blocked_on, null);
});

test('M4 a 500: client_approval null, partial names /api/ledger', async (t) => {
  const { stub, call } = await withStub(t);
  stub.fail(ledgerPath('acme/widgets#102'), 500);
  const o = await call({ repo: 'acme/widgets', pr: 102 });
  assert.equal(o.client_approval, null);
  assert.deepEqual(o.partial, ['/api/ledger']);
  assert.equal(o.blocked_on, null);
});

test('M5 a 200 with no ledger object: client_approval null + partial', async (t) => {
  for (const body of [{ ok: true }, { ledger: null }, { ledger: 'waiting' }, { ledger: [] }]) {
    const { call } = await withStub(t, routes({ [ledgerPath('acme/widgets#102')]: { json: body } }));
    const o = await call({ repo: 'acme/widgets', pr: 102 });
    assert.equal(o.client_approval, null, JSON.stringify(body));
    assert.deepEqual(o.partial, ['/api/ledger'], JSON.stringify(body));
  }
});

test('M6 status closed (and every other non-waiting status): null, not partial', async (t) => {
  for (const status of ['closed', 'approved', 'hold', 'WAITING', 'mystery']) {
    const { call } = await withStub(t, routes({ [ledgerPath('acme/widgets#102')]: { json: row('acme/widgets#102', { status }) } }));
    const o = await call({ repo: 'acme/widgets', pr: 102 });
    assert.equal(o.client_approval, null, status);
    assert.equal(o.partial, undefined, status);
    assert.equal(o.blocked_on, null, status);
  }
});

test('M6b a bad detail: not JSON, v != 1, bad or missing requested_at → null', () => {
  const base = row('k').ledger;
  assert.deepEqual(clientApprovalOf(base, NOW), WAITING, 'the control case is waiting');
  const bad = [
    { detail: 'not json' }, { detail: null }, { detail: JSON.stringify([1]) },
    { detail: detail({ v: 2 }) }, { detail: detail({ v: '1' }) },
    { detail: detail({ requested_at: 'yesterday' }) }, { detail: detail({ requested_at: null }) },
    { detail: detail({ requested_at: '2026-13-45T99:99:99Z' }) }, { detail: detail({ requested_at: '2026-11-18 11:06:40' }) },
  ];
  for (const over of bad) assert.equal(clientApprovalOf({ ...base, ...over }, NOW), null, JSON.stringify(over));
  assert.equal(clientApprovalOf(null, NOW), null);
  assert.equal(clientApprovalOf({ ...base, status: 'closed' }, NOW), null);
});

test('M7 the shared fixture row the box writes', async (t) => {
  assert.equal(FX_PR, '501');
  assert.notEqual(FX_REPO, FX_REPO_LC, 'the call repo is mixed case');
  const r = routes({
    [events(FX_REPO, 501)]: { json: { rows: [] } },
    [tiers(FX_REPO, 501)]: NO_TIERS,
    [ledgerPath(ROW_FIXTURE.key)]: { json: { ledger: ROW_FIXTURE } },
  });
  const { call, api } = await withStub(t, r);
  const o = await call({ repo: FX_REPO, pr: 501 });
  assert.ok(api().includes(ledgerPath(ROW_FIXTURE.key)), 'the read used the fixture key');
  assert.deepEqual(o.client_approval, {
    state: 'waiting', label: 'waiting for client approval', ticket_id: 'T-501',
    ticket_url: 'https://os.project-3.example/feature-board?ticket=T-501',
    since: '2026-11-18T11:06:40Z', age_s: 3600, head: '00000000000000000000000000000000000001f5',
  });
  assert.equal(o.blocked_on, 'waiting for client approval');
  assert.equal(o.partial, undefined);
});

test('the request key is lowercased: Acme/Widgets-OS → acme/widgets-os#<pr>', async (t) => {
  const r = routes({
    [events('Acme/Widgets-OS', 501)]: { json: { rows: [] } },
    [tiers('Acme/Widgets-OS', 501)]: NO_TIERS,
    [ledgerPath('acme/widgets-os#501')]: { json: row('acme/widgets-os#501') },
  });
  const { call, api } = await withStub(t, r);
  const o = await call({ repo: 'Acme/Widgets-OS', pr: 501 });
  const sent = api().filter((p) => p.startsWith('/api/coord/ledger'));
  assert.deepEqual(sent, ['/api/coord/ledger?kind=client-approval&key=acme%2Fwidgets-os%23501']);
  assert.equal(o.client_approval?.ticket_id, 'W-7');
});

test('age_s uses the process clock when ctx.now is not set', async (t) => {
  // The clock is pinned (mock timers, Date only): one hour after requested_at.
  const { call } = await withStub(t, routes(), { now: undefined });
  t.mock.timers.enable({ apis: ['Date'], now: Date.parse('2026-11-18T12:06:40Z') });
  const o = await call({ repo: 'acme/widgets', pr: 102 });
  t.mock.timers.reset();
  assert.equal(o.client_approval.age_s, 3600);
});

test('the ledger read runs in the same Promise.all as the events and tiers reads', async (t) => {
  // Each follow-up answer is held until all three requests are in the stub's
  // log (or 500 ms pass). The log is snapshotted when the FIRST follow-up
  // answer is released. Sequential reads never issue the next request while
  // the first is held, so the snapshot would miss it.
  let stubRef = null;
  let firstSnapshot = null;
  const followUps = () => stubRef.requests.filter((q) => !q.path.startsWith('/login/') && !q.path.startsWith(LIVE));
  const held = async (cfg, method, path, body) => {
    const r = await consoleFetch(cfg, method, path, body);
    if (path.startsWith(LIVE)) return r;
    // At most 50 waits of 10 ms: a bound by count, not by the wall clock.
    for (let i = 0; i < 50 && followUps().length < 3; i++) await new Promise((res) => setTimeout(res, 10));
    if (firstSnapshot === null) firstSnapshot = followUps().map((q) => q.path.split('?')[0]);
    return r;
  };
  const { stub, call } = await withStub(t, routes(), { consoleFetch: held });
  stubRef = stub;
  await call({ repo: 'acme/widgets', pr: 102 });
  assert.deepEqual(firstSnapshot.slice().sort(),
    ['/api/coord/ledger', '/api/coord/pr-state-events', '/api/coord/risk-tiers']);
  const order = stub.requests.filter((q) => !q.path.startsWith('/login/')).map((q) => q.path.split('?')[0]);
  assert.equal(order[0], LIVE, 'the live read comes first');
});
