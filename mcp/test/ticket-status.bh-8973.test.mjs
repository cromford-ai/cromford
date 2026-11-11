// The ticket_status and stuck_tickets tools in mcp/tools/ticket-status.mjs
// (BH-8973). Every case goes through the REAL registry (loadTools + callTool)
// and the REAL consoleFetch against the stub console; the branch commit reads
// go through the REAL githubFetch against a second stub. globalThis.fetch is
// wrapped with a recorder BEFORE the tools load, so every request is counted
// and any request off the two stubs is refused.
// The fixture is the worker's GET /api/ticket-status answer for the S3 rows
// (worker/jobs/test/ticket-status.bh-8973.test.js S3 pins that).
//   M1 the worker fixture round-trips          M2 schema refusals send nothing
//   M3 commit reads: token, none, no branch, cap  M4 a GitHub 500 is per ticket
//   M5 console 404 and 400 too_many             M6 live: no pipeline, no cache
//   M7 a token-shaped value is redacted
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const fetched = [];
const realFetch = globalThis.fetch;
const origins = new Set();
globalThis.fetch = (input, init) => {
  const url = String(input instanceof Request ? input.url : input);
  fetched.push(url);
  if (![...origins].some((o) => url.startsWith(o + '/'))) return Promise.reject(new Error(`blocked off-stub fetch: ${url}`));
  return realFetch(input, init);
};

const { loadTools, callTool } = await import('../lib/tools.mjs');
const { startStub } = await import('./lib/stub-console.mjs');

const HERE = dirname(fileURLToPath(import.meta.url));
const FIXTURE = JSON.parse(readFileSync(join(HERE, 'fixtures/ticket-status.bh-8973.json'), 'utf8'));
const clone = (v) => JSON.parse(JSON.stringify(v));
const TOKEN = 'tok-fixture-ticket-status';
const GH_TOKEN = 'gh-tok-fixture-ticket-status';
const ROUTE = '/api/coord/ticket-status';
const PATH = `${ROUTE}?project=s3&key=BH-8973`;
const STUCK = `${ROUTE}/stuck?project=s3`;
const REPO = FIXTURE.repo;
const COMMITS = (branch) => `/repos/${REPO}/commits?sha=${encodeURIComponent(branch)}&per_page=1`;
const COMMIT_AT = '2026-11-02T11:50:00Z';

const registry = await loadTools(new URL('../tools/', import.meta.url));

async function setup(t, { routes = {}, gh = true, ghRoutes, ghFail = {}, env = {} } = {}) {
  const stub = await startStub({ routes: { [PATH]: { json: FIXTURE }, ...routes } });
  const ghStub = await startStub({
    routes: ghRoutes ?? { [COMMITS('ticket/bh-8973')]: { json: [{ sha: 'abc1234', commit: { committer: { date: COMMIT_AT } } }] } },
    fail: ghFail,
  });
  origins.add(stub.url);
  origins.add(ghStub.url);
  t.after(async () => { origins.delete(stub.url); origins.delete(ghStub.url); await stub.close(); await ghStub.close(); });
  const ctx = {
    cfg: { url: stub.url, token: TOKEN, secret: null },
    github: { url: ghStub.url, token: gh ? GH_TOKEN : null },
    env,
  };
  const call = (name, args) => callTool(registry, name, args, ctx);
  return { stub, ghStub, call };
}
const out = (r) => {
  assert.notEqual(r.isError, true, r.content?.[0]?.text);
  assert.deepEqual(JSON.parse(r.content[0].text), r.structuredContent);
  return r.structuredContent;
};
const refused = (r, re) => {
  assert.equal(r.isError, true, JSON.stringify(r));
  assert.match(r.content[0].text, re);
};
const withTickets = (tickets) => ({ ...clone(FIXTURE), tickets });

test('M1 the worker fixture round-trips: state, machine, fresh_at and the branch commit time', async (t) => {
  const { call, stub, ghStub } = await setup(t);
  const o = out(await call('ticket_status', { project: 's3', tickets: [{ key: 'BH-8973' }] }));
  assert.deepEqual(stub.requests.map((q) => `${q.method} ${q.path}`), [`GET ${PATH}`]);
  assert.equal(o.tickets[0].state, 'running');
  assert.equal(o.tickets[0].stage, 'execute');
  assert.equal(o.tickets[0].machine, 'm-fixture-1');
  assert.equal(o.tickets[0].last_checkpoint_at, FIXTURE.tickets[0].last_checkpoint_at);
  assert.equal(o.fresh_at, FIXTURE.fresh_at);
  assert.equal(o.tickets[0].last_commit_at, COMMIT_AT);
  assert.equal(o.tickets[0].commit_source, 'github');
  assert.deepEqual(ghStub.requests.map((q) => q.path), [COMMITS('ticket/bh-8973')]);
  assert.equal(ghStub.requests[0].authorization, `Bearer ${GH_TOKEN}`);
});

test('M2 schema refusals send 0 requests; a valid call sends exactly 1 console GET', async (t) => {
  const { call, stub, ghStub } = await setup(t, { routes: {
    [`${ROUTE}?repo=example-org%2Fs3-fixture&key=BH-8973&issue=12`]: { json: FIXTURE },
    [STUCK]: { json: { project: 's3', repo: REPO, fresh_at: FIXTURE.fresh_at, stuck_min: 90, scanned: 1, truncated: false, tickets: [] } },
  } });
  const before = fetched.length;
  const many = Array.from({ length: 51 }, (_, i) => ({ key: `BH-${i}` }));
  for (const [args, re] of [
    [{}, /project_or_repo_required/],
    [{ tickets: [{ key: 'BH-1' }] }, /project_or_repo_required/],
    [{ project: 's3', repo: 'a/b', tickets: [{ key: 'BH-1' }] }, /project_or_repo_required/],
    [{ project: 's3' }, /invalid_arguments: tickets/],
    [{ project: 's3', tickets: [] }, /invalid_arguments: tickets/],
    [{ project: 's3', tickets: many }, /invalid_arguments: tickets/],
    [{ project: 's3', tickets: [{ issue: 1.5 }] }, /invalid_arguments: tickets\[0\]\.issue/],
    [{ project: 's3', tickets: [{ issue: 0 }] }, /invalid_arguments: tickets\[0\]\.issue/],
    [{ project: 's3', tickets: [{ key: 'A', issue: 1 }] }, /invalid_arguments: tickets\[0\]/],
    [{ project: 's3', tickets: [{}] }, /invalid_arguments: tickets\[0\]/],
    [{ project: 's3', tickets: [{ key: 'A', extra: 1 }] }, /invalid_arguments: tickets\[0\]\.extra/],
    [{ project: 's3', tickets: ['BH-1'] }, /invalid_arguments: tickets\[0\]/],
    [{ project: 's3', tickets: [{ key: 'x'.repeat(65) }] }, /invalid_arguments: tickets\[0\]\.key/],
  ]) refused(await call('ticket_status', args), re);
  refused(await call('stuck_tickets', {}), /project_or_repo_required/);
  refused(await call('stuck_tickets', { project: 's3', repo: 'a/b' }), /project_or_repo_required/);
  assert.equal(fetched.length, before, 'a refusal sends nothing');
  assert.equal(stub.requests.length + ghStub.requests.length, 0);

  out(await call('ticket_status', { repo: 'example-org/s3-fixture', tickets: [{ key: 'BH-8973' }, { issue: 12 }] }));
  assert.deepEqual(stub.requests.map((q) => `${q.method} ${q.path}`), [`GET ${ROUTE}?repo=example-org%2Fs3-fixture&key=BH-8973&issue=12`]);
  const s = out(await call('stuck_tickets', { project: 's3' }));
  assert.deepEqual(stub.requests.slice(1).map((q) => `${q.method} ${q.path}`), [`GET ${STUCK}`]);
  assert.deepEqual([s.stuck_min, s.scanned, s.truncated, s.tickets], [90, 1, false, []]);
});

test('M3 commit reads: one per branch with a token, none without, no_branch, and the cap knob', async (t) => {
  const two = withTickets([
    { ...clone(FIXTURE.tickets[0]) },
    { ...clone(FIXTURE.tickets[0]), key: 'BH-2', branch: 'ticket/bh-2' },
    { ...clone(FIXTURE.tickets[0]), key: 'BH-3', branch: null },
  ]);
  const ghRoutes = {
    [COMMITS('ticket/bh-8973')]: { json: [{ commit: { committer: { date: COMMIT_AT } } }] },
    [COMMITS('ticket/bh-2')]: { json: [{ commit: { committer: { date: '2026-11-02T10:00:00Z' } } }] },
  };
  {
    const { call, ghStub } = await setup(t, { routes: { [PATH]: { json: two } }, ghRoutes });
    const o = out(await call('ticket_status', { project: 's3', tickets: [{ key: 'BH-8973' }] }));
    assert.deepEqual(o.tickets.map((x) => [x.key, x.last_commit_at, x.commit_source]),
      [['BH-8973', COMMIT_AT, 'github'], ['BH-2', '2026-11-02T10:00:00Z', 'github'], ['BH-3', null, 'no_branch']]);
    assert.equal(ghStub.requests.length, 2);
  }
  {
    const { call, ghStub } = await setup(t, { routes: { [PATH]: { json: two } }, ghRoutes, gh: false });
    const o = out(await call('ticket_status', { project: 's3', tickets: [{ key: 'BH-8973' }] }));
    assert.deepEqual(o.tickets.map((x) => x.commit_source), ['github_auth_not_configured', 'github_auth_not_configured', 'no_branch']);
    assert.deepEqual(o.tickets.map((x) => x.last_commit_at), [null, null, null]);
    assert.equal(ghStub.requests.length, 0, 'no token, no GitHub request');
  }
  {
    const { call, ghStub } = await setup(t, { routes: { [PATH]: { json: two } }, ghRoutes, env: { HARNESS_MCP_TICKET_STATUS_COMMIT_READS: '1' } });
    const o = out(await call('ticket_status', { project: 's3', tickets: [{ key: 'BH-8973' }] }));
    assert.deepEqual(o.tickets.map((x) => x.commit_source), ['github', 'skipped_cap', 'no_branch']);
    assert.equal(ghStub.requests.length, 1);
    assert.deepEqual(o.commit_reads, { cap: 1, made: 1, skipped: 1 });
  }
});

test('M3b an answer with no repo (no projects row) is no_repo per branch, and sends nothing to GitHub', async (t) => {
  const { call, ghStub } = await setup(t, { routes: { [PATH]: { json: { ...clone(FIXTURE), repo: null } } } });
  const o = out(await call('ticket_status', { project: 's3', tickets: [{ key: 'BH-8973' }] }));
  assert.deepEqual([o.tickets[0].commit_source, o.tickets[0].last_commit_at], ['no_repo', null]);
  assert.equal(ghStub.requests.length, 0);
});

test('M4 a GitHub 500 is a per-ticket commit_source; the rest of the answer is intact', async (t) => {
  const { call } = await setup(t, { ghFail: { [COMMITS('ticket/bh-8973')]: 500 } });
  const o = out(await call('ticket_status', { project: 's3', tickets: [{ key: 'BH-8973' }] }));
  assert.equal(o.tickets[0].commit_source, 'github_error:github_http_500');
  assert.equal(o.tickets[0].last_commit_at, null);
  assert.equal(o.tickets[0].state, 'running');
});

test('M5 a console 404 is "route not available"; a 400 too_many is shown as given', async (t) => {
  const { call, stub } = await setup(t, { routes: { [`${ROUTE}?project=s3&key=BH-1&key=BH-2`]: { status: 400, json: { error: 'too_many', max: 1 } } } });
  stub.fail(PATH, 404);
  refused(await call('ticket_status', { project: 's3', tickets: [{ key: 'BH-8973' }] }), /^console route not available: \/api\/coord\/ticket-status$/);
  refused(await call('ticket_status', { project: 's3', tickets: [{ key: 'BH-1' }, { key: 'BH-2' }] }), /^http_400: too_many$/);
  stub.fail(STUCK, 404);
  refused(await call('stuck_tickets', { project: 's3' }), /console route not available: \/api\/coord\/ticket-status\/stuck/);
});

test('M6 live reads: never the pipeline snapshot, and two answers give two results (no cache)', async (t) => {
  // One stub whose routes map is swapped between the two calls.
  const routes = { [PATH]: { json: FIXTURE } };
  const stub = await startStub({ routes });
  origins.add(stub.url);
  t.after(async () => { origins.delete(stub.url); await stub.close(); });
  const ctx = { cfg: { url: stub.url, token: TOKEN, secret: null }, github: { url: null, token: null }, env: {} };
  const ask = () => callTool(registry, 'ticket_status', { project: 's3', tickets: [{ key: 'BH-8973' }] }, ctx);
  const a = out(await ask());
  routes[PATH] = { json: withTickets([{ ...clone(FIXTURE.tickets[0]), state: 'pr_open', stage: null }]) };
  const b = out(await ask());
  assert.deepEqual([a.tickets[0].state, b.tickets[0].state], ['running', 'pr_open']);
  assert.equal(stub.requests.length, 2, 'each call reads the console');
  assert.equal(fetched.some((u) => u.includes('pipeline')), false, 'never /api/dash/kanban/pipeline');
});

test('M7 a token-shaped value in the answer is redacted in the text and structuredContent', async (t) => {
  const leaky = withTickets([{ ...clone(FIXTURE.tickets[0]), machine: TOKEN }]);
  const { call } = await setup(t, { routes: { [PATH]: { json: leaky } } });
  const r = await call('ticket_status', { project: 's3', tickets: [{ key: 'BH-8973' }] });
  assert.equal(r.content[0].text.includes(TOKEN), false);
  assert.equal(JSON.stringify(r.structuredContent).includes(TOKEN), false);
  assert.equal(r.structuredContent.tickets[0].machine, '[redacted]');
});
