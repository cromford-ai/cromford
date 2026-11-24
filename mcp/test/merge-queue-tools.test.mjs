// BH-5671 (BH-5008.4): the merge-queue MCP tools in mcp/tools/merge-queue.mjs.
// Every case goes through the REAL registry (loadTools + callTool) and the
// REAL consoleFetch against the stub console HTTP server. globalThis.fetch and
// node:child_process are wrapped with recorders BEFORE the tools load, so the
// "no GitHub, no gh" claim is measured, not read off the source.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createRequire, syncBuiltinESMExports } from 'node:module';
import { cpSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

// ---- recorders, installed before any tool module is imported ----
const fetched = [];
const realFetch = globalThis.fetch;
let stubOrigin = null;
globalThis.fetch = (input, init) => {
  const url = String(input instanceof Request ? input.url : input);
  fetched.push(url);
  // Never let a stray request leave the box: anything off the stub fails here.
  if (!stubOrigin || !url.startsWith(stubOrigin + '/')) return Promise.reject(new Error(`blocked off-stub fetch: ${url}`));
  return realFetch(input, init);
};
const spawned = [];
const cp = createRequire(import.meta.url)('node:child_process');
for (const fn of ['spawn', 'exec', 'execFile', 'execSync', 'execFileSync', 'spawnSync', 'fork']) {
  cp[fn] = (...a) => { spawned.push(`${fn} ${String(a[0])}`); throw new Error(`child_process.${fn} blocked`); };
}
syncBuiltinESMExports();

const { loadTools, callTool } = await import('../lib/tools.mjs');
const { startStub } = await import('./lib/stub-console.mjs');

const HERE = dirname(fileURLToPath(import.meta.url));
const MCP_DIR = join(HERE, '..');
const FIXTURE = JSON.parse(readFileSync(join(HERE, 'fixtures/merge-queue-live.bh-5008.json'), 'utf8'));
const clone = (v) => JSON.parse(JSON.stringify(v));
const SECRET = 'sec-fixture';
const TOKEN = 'tok-fixture-merge-queue';

const LIVE = '/api/coord/merge-queue/live';
const events = (repo, n) => `/api/coord/pr-state-events?repo=${encodeURIComponent(repo)}&number=${n}&limit=50`;
const tiers = (repo, n) => `/api/coord/risk-tiers?repo=${encodeURIComponent(repo)}&pr=${n}&limit=1`;
const JOBS = '/api/coord/jobs?project=widgets&kind=build&status=running&limit=200';
// BH-9901: pr_stage also reads the client-approval hub ledger row. The stub
// answers an unrouted path 200 {ok:true}, which is no ledger answer and would
// name '/api/ledger' in `partial`; these cases have no row, so the hub's 404.
const ledger = (repo, n) => `/api/coord/ledger?kind=client-approval&key=${encodeURIComponent(`${repo.toLowerCase()}#${n}`)}`;
const NO_ROW = { status: 404, json: { error: 'not found' } };

// The event log for #101, newest first, as GET /api/pr-state-events answers it.
const EVENTS_101 = {
  rows: [
    { state: 'queue', since: '2026-10-09T03:20:00Z', reason: 'dequeued(Jobs worker failed alone)', at: '2026-10-09T03:20:01Z' },
    { state: 'gate', since: 'lead-review', reason: 'approve', at: '2026-10-09T02:40:00Z' },
    { state: 'queue', since: '2026-10-09T03:00:00Z', reason: 'checking', at: '2026-10-09T03:00:01Z' },
    { state: 'approved_not_queued', since: '2026-10-09T02:30:00Z', reason: 'waiting for queue', at: '2026-10-09T02:30:01Z' },
    { state: 'ci_running', since: '2026-10-09T02:00:00Z', reason: null, at: '2026-10-09T02:00:01Z' },
  ],
  as_of: '2026-10-09T03:25:00Z',
};
const EVENTS_102 = {
  rows: [
    { state: 'queue', since: '2026-10-09T03:10:00Z', reason: 'checking', at: '2026-10-09T03:10:01Z' },
    { state: 'lead_block', since: '2026-10-09T02:10:00Z', reason: 'missing test for X', at: '2026-10-09T02:10:01Z' },
  ],
  as_of: '2026-10-09T03:25:00Z',
};
const JOBS_BODY = {
  jobs: [
    { ticket_id: 'W-1', stage: 'plan', box: 'box-a', status: 'running' },
    { ticket_id: 'W-2', stage: 'execute', box: 'box-b', status: 'running' },
    { ticket_id: 'W-3', stage: 'review', box: 'box-a', status: 'running' },
    { ticket_id: 'W-4', stage: 'merge', box: 'box-c', status: 'running' },
  ],
  as_of: '2026-10-09T03:25:00Z',
};

function baseRoutes(live = FIXTURE) {
  return {
    [LIVE]: { json: live },
    [`${LIVE}?project=widgets`]: { json: live },
    [events('acme/widgets', 101)]: { json: EVENTS_101 },
    [events('acme/widgets', 102)]: { json: EVENTS_102 },
    [tiers('acme/widgets', 101)]: { json: { rows: [{ repo: 'acme/widgets', pr: 101, tier: 'T2' }], truncated: false } },
    [tiers('acme/widgets', 102)]: { json: { rows: [], truncated: false } },
    [JOBS]: { json: JOBS_BODY },
    [ledger('acme/widgets', 101)]: NO_ROW,
    [ledger('acme/widgets', 102)]: NO_ROW,
  };
}

const registry = await loadTools(new URL('../tools/', import.meta.url));

// One stub + cfg per case; every request the case sent is in `stub.requests`.
async function withStub(t, routes = baseRoutes(), auth = { secret: SECRET }) {
  const stub = await startStub({ routes });
  stubOrigin = stub.url;
  t.after(() => stub.close());
  const ctx = { cfg: { url: stub.url, token: null, secret: null, ...auth } };
  const call = (name, args) => callTool(registry, name, args, ctx);
  const api = () => stub.requests.filter((q) => !q.path.startsWith('/login/'));
  return { stub, ctx, call, api };
}
const out = (r) => {
  assert.notEqual(r.isError, true, r.content?.[0]?.text);
  return r.structuredContent;
};

test('1 registry loads merge_queue, pr_stage, backlog as read tools', async () => {
  const closed = (s) => s.type !== 'object' ||
    (s.additionalProperties === false && Object.values(s.properties ?? {}).every(closed));
  for (const name of ['merge_queue', 'pr_stage', 'backlog']) {
    const t = registry.get(name);
    assert.ok(t, `missing ${name}`);
    assert.equal(t.kind, 'read', name);
    assert.ok(closed(t.inputSchema), `${name} has an open object level`);
  }
  assert.deepEqual(registry.get('pr_stage').inputSchema.required, ['repo', 'pr']);
  assert.deepEqual(registry.get('backlog').inputSchema.required, ['project']);
});

test('2 merge_queue returns the batch with checks 10/14 and its ETA', async (t) => {
  const { call, api } = await withStub(t);
  const o = out(await call('merge_queue', {}));
  assert.deepEqual(api().map((q) => q.path), [LIVE]);
  const b = o.batches.find((x) => x.draft === 9001);
  assert.deepEqual(b.members, [101, 102, 103]);
  assert.deepEqual(b.checks, { done: 10, total: 14 });
  assert.equal(b.checks_text, '10/14');
  assert.equal(b.eta_s, 420);
  assert.equal(b.failing.name, 'jobs-worker');
  assert.equal(b.progress, 0.71);
  const bis = o.batches.find((x) => x.draft === 9002);
  assert.equal(bis.bisect.step, 1);
  assert.equal(bis.bisect.steps, 2);
  assert.equal(bis.failing, null);
  assert.equal(o.complete, true);
  assert.equal(o.as_of, FIXTURE.as_of);
});

test('2b merge_queue passes project as an encoded query parameter', async (t) => {
  const { call, api } = await withStub(t);
  out(await call('merge_queue', { project: 'widgets' }));
  assert.deepEqual(api().map((q) => q.path), [`${LIVE}?project=widgets`]);
});

test('3 eta_s null passes through as null; checks_text still built', async (t) => {
  const live = clone(FIXTURE);
  live.batches[0].eta_s = null;
  live.batches[0].progress = null;
  live.complete = false;
  const { call } = await withStub(t, baseRoutes(live));
  const o = out(await call('merge_queue', {}));
  const b = o.batches.find((x) => x.draft === 9001);
  assert.equal(b.eta_s, null);
  assert.equal(b.progress, null);
  assert.equal(b.checks_text, '10/14');
  assert.equal(o.complete, false, 'complete:false passes through');
});

test('3b checks_text is null when the route counts are not integers', async (t) => {
  const live = clone(FIXTURE);
  live.batches[0].checks = { done: null, total: 14 };
  const { call } = await withStub(t, baseRoutes(live));
  const b = out(await call('merge_queue', {})).batches.find((x) => x.draft === 9001);
  assert.equal(b.checks_text, null);
});

test('4 waiting is in position order; null position sorts last', async (t) => {
  const live = clone(FIXTURE);
  live.waiting.push({ repo: 'acme/widgets', pr: 106, position: null });
  live.waiting.unshift(live.waiting.pop());
  const { call } = await withStub(t, baseRoutes(live));
  const o = out(await call('merge_queue', {}));
  assert.deepEqual(o.waiting.map((w) => [w.pr, w.position]), [[104, 1], [105, 2], [106, null]]);
});

test('4b an empty waiting line is [], not null', async (t) => {
  const live = clone(FIXTURE);
  live.waiting = [];
  const { call } = await withStub(t, baseRoutes(live));
  assert.deepEqual(out(await call('merge_queue', {})).waiting, []);
});

test('5 a payload without batches is an error, not an empty queue', async (t) => {
  const { call } = await withStub(t, { [LIVE]: { json: { waiting: [], prs: {} } } });
  const r = await call('merge_queue', {});
  assert.equal(r.isError, true);
  assert.match(r.content[0].text, /^bad_payload/);
});

test('5b a console without the live route answers route not available', async (t) => {
  const { stub, call } = await withStub(t, {});
  stub.fail(LIVE, 404);
  const r = await call('merge_queue', {});
  assert.equal(r.isError, true);
  assert.equal(r.content[0].text, `console route not available: ${LIVE}`);
});

test('6 pr_stage member PR is checking', async (t) => {
  const { call } = await withStub(t);
  const o = out(await call('pr_stage', { repo: 'acme/widgets', pr: 102 }));
  assert.deepEqual(o.queue_stage, { stage: 'checking', batch: 9001, at: '2026-10-09T03:10:00Z' });
  assert.deepEqual(o.lead_stage, { state: 'lead_block', since: '2026-10-09T02:10:00Z', reason: 'missing test for X' });
  assert.equal(o.blocked_on, null, 'a queue stage with no detail and a non-lead current stage: no blocker');
  assert.equal(o.risk_tier, null, 'no risk-tier row answers null');
  assert.equal(o.partial, undefined);
});

test('7 pr_stage culprit is dequeued(Jobs worker failed alone), with tier and stages oldest first', async (t) => {
  const { call } = await withStub(t);
  const o = out(await call('pr_stage', { repo: 'acme/widgets', pr: 101 }));
  assert.equal(o.queue_stage.stage, 'dequeued(Jobs worker failed alone)');
  assert.equal(o.blocked_on, 'Jobs worker failed alone');
  assert.equal(o.risk_tier, 'T2');
  assert.deepEqual(o.lead_stage, { state: 'approved_not_queued', since: '2026-10-09T02:30:00Z', reason: 'waiting for queue' });
  assert.deepEqual(o.stages, [
    { stage: 'ci_running', since: '2026-10-09T02:00:00Z', at: '2026-10-09T02:00:01Z' },
    { stage: 'approved_not_queued', since: '2026-10-09T02:30:00Z', at: '2026-10-09T02:30:01Z' },
    { stage: 'checking', since: '2026-10-09T03:00:00Z', at: '2026-10-09T03:00:01Z' },
    { stage: 'gate', since: 'lead-review', at: '2026-10-09T02:40:00Z' },
    { stage: 'dequeued(Jobs worker failed alone)', since: '2026-10-09T03:20:00Z', at: '2026-10-09T03:20:01Z' },
  ]);
  assert.equal(o.stages_complete, true);
});

test('7b the contract stage form "dequeued (detail)" gives the same blocker', async (t) => {
  const live = clone(FIXTURE);
  live.prs['acme/widgets#101'].stage = 'dequeued (Jobs worker failed alone)';
  const { call } = await withStub(t, baseRoutes(live));
  const o = out(await call('pr_stage', { repo: 'acme/widgets', pr: 101 }));
  assert.equal(o.blocked_on, 'Jobs worker failed alone');
});

test('7c with no queue detail, a lead_block reason is the blocker', async (t) => {
  const live = clone(FIXTURE);
  delete live.prs['acme/widgets#102'];
  const { call } = await withStub(t, baseRoutes(live));
  const o = out(await call('pr_stage', { repo: 'acme/widgets', pr: 102 }));
  assert.equal(o.queue_stage, null);
  assert.equal(o.blocked_on, 'missing test for X');
});

test('8 pr_stage marks a failed risk-tiers read as partial, not absent', async (t) => {
  const { stub, call } = await withStub(t);
  stub.fail(tiers('acme/widgets', 101), 500);
  const o = out(await call('pr_stage', { repo: 'acme/widgets', pr: 101 }));
  assert.equal(o.risk_tier, null);
  assert.deepEqual(o.partial, ['/api/coord/risk-tiers']);
  assert.equal(o.queue_stage.stage, 'dequeued(Jobs worker failed alone)');
});

test('8b pr_stage: a failed events read is partial; a failed live read fails the tool', async (t) => {
  const { stub, call } = await withStub(t);
  stub.fail(events('acme/widgets', 101), 500);
  const o = out(await call('pr_stage', { repo: 'acme/widgets', pr: 101 }));
  assert.equal(o.lead_stage, null);
  assert.equal(o.stages, null);
  assert.deepEqual(o.partial, ['/api/coord/pr-state-events']);
  stub.fail(LIVE, 500);
  const r = await call('pr_stage', { repo: 'acme/widgets', pr: 101 });
  assert.equal(r.isError, true);
  assert.equal(r.content[0].text, 'http_500');
});

test('9 pr_stage matches the repo case-insensitively, never by prefix', async (t) => {
  const { call } = await withStub(t);
  const o = out(await call('pr_stage', { repo: 'Acme/Widgets', pr: 102 }));
  assert.equal(o.queue_stage.stage, 'checking');
  assert.equal(o.risk_tier, null);
  assert.equal(o.partial, undefined, 'the follow-up reads use the repo as the queue spells it');
  assert.equal(out(await call('pr_stage', { repo: 'acme/widgets', pr: 10 })).queue_stage, null);
  assert.equal(out(await call('pr_stage', { repo: 'acme/widget', pr: 101 })).queue_stage, null);
});

test('9b pr_stage refuses a missing pr and sends nothing', async (t) => {
  const { call, api } = await withStub(t);
  const r = await call('pr_stage', { repo: 'acme/widgets' });
  assert.equal(r.isError, true);
  assert.equal(r.content[0].text, 'invalid_arguments: pr');
  assert.equal(api().length, 0);
});

const SINCE = '2026-10-09T03:00:00Z';

test('10 backlog(since) lists exactly the PRs that changed stage after since', async (t) => {
  const { call } = await withStub(t);
  const o = out(await call('backlog', { project: 'widgets', since: SINCE }));
  // 103 is AT since (excluded), 104 before, 105 has an unparseable at.
  assert.deepEqual(o.changed.map((c) => [c.repo, c.pr, c.stage]), [
    ['acme/widgets', 102, 'checking'],
    ['acme/widgets', 101, 'dequeued(Jobs worker failed alone)'],
  ]);
  assert.equal(o.since, SINCE);
});

test('10b backlog without since omits changed', async (t) => {
  const { call } = await withStub(t);
  const o = out(await call('backlog', { project: 'widgets' }));
  assert.equal('changed' in o, false);
});

test('11 backlog counts per stage and groups build tickets planning/building/queued', async (t) => {
  const { call, api } = await withStub(t);
  const o = out(await call('backlog', { project: 'widgets' }));
  assert.deepEqual(o.counts, { dequeued: 1, checking: 2, queued: 2 });
  assert.equal('merging' in o.counts, false, 'an absent stage is absent, not 0');
  assert.deepEqual(o.builds, {
    planning: [{ ticket_id: 'W-1', stage: 'plan', box: 'box-a' }],
    building: [{ ticket_id: 'W-2', stage: 'execute', box: 'box-b' }, { ticket_id: 'W-3', stage: 'review', box: 'box-a' }],
    queued: [{ ticket_id: 'W-4', stage: 'merge', box: 'box-c' }],
  });
  assert.equal(o.builds_complete, true);
  assert.equal(o.complete, true);
  assert.deepEqual(api().map((q) => q.path).sort(), [`${LIVE}?project=widgets`, JOBS].sort());
});

test('11b backlog: a failed jobs read is partial, builds null', async (t) => {
  const { stub, call } = await withStub(t);
  stub.fail(JOBS, 500);
  const o = out(await call('backlog', { project: 'widgets' }));
  assert.equal(o.builds, null);
  assert.deepEqual(o.partial, ['/api/coord/jobs']);
  assert.deepEqual(o.counts, { dequeued: 1, checking: 2, queued: 2 });
});

test('11c backlog: a full jobs page sets builds_complete false', async (t) => {
  const routes = baseRoutes();
  routes[JOBS] = { json: { jobs: Array.from({ length: 200 }, (_, i) => ({ ticket_id: `W-${i}`, stage: 'plan', box: 'b' })) } };
  const { call } = await withStub(t, routes);
  const o = out(await call('backlog', { project: 'widgets' }));
  assert.equal(o.builds_complete, false);
});

test('12 backlog refuses an unparseable since and sends no request', async (t) => {
  const { call, api } = await withStub(t);
  const r = await call('backlog', { project: 'widgets', since: 'yesterday' });
  assert.equal(r.isError, true);
  assert.equal(r.content[0].text, 'invalid_arguments: since');
  assert.equal(api().length, 0);
  const r2 = await call('backlog', {});
  assert.equal(r2.content[0].text, 'invalid_arguments: project');
  assert.equal(api().length, 0);
});

test('13 zero GitHub and zero gh calls across all three tools', async (t) => {
  fetched.length = 0;
  spawned.length = 0;
  const { stub, call } = await withStub(t);
  out(await call('merge_queue', {}));
  out(await call('merge_queue', { project: 'widgets' }));
  out(await call('pr_stage', { repo: 'acme/widgets', pr: 101 }));
  out(await call('pr_stage', { repo: 'acme/widgets', pr: 102 }));
  out(await call('backlog', { project: 'widgets', since: SINCE }));
  assert.ok(fetched.length >= 9, `recorder saw ${fetched.length} fetches`);
  assert.deepEqual(fetched.filter((u) => /github\.com/.test(u)), []);
  assert.deepEqual(fetched.filter((u) => !u.startsWith(stub.url + '/')), []);
  assert.deepEqual(spawned, []);
});

test('14 mutation: an added GitHub fetch in merge_queue is caught by the recorder', async (t) => {
  const dir = mkdtempSync(join(tmpdir(), 'mcp-mq-mut-'));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  cpSync(MCP_DIR, dir, { recursive: true });
  const file = join(dir, 'tools/merge-queue.mjs');
  const anchor = 'const live = await readLive(ctx, a.project);';
  const src = readFileSync(file, 'utf8');
  assert.equal(src.split(anchor).length, 2, 'mutation anchor not found exactly once');
  writeFileSync(file, src.replace(anchor, "await fetch('https://api.github.com/repos/acme/widgets/pulls').catch(() => {}); " + anchor));
  const { loadTools: load2, callTool: call2 } = await import(join(dir, 'lib/tools.mjs'));
  const mut = await load2(join(dir, 'tools'));
  fetched.length = 0;
  const { ctx } = await withStub(t);
  await call2(mut, 'merge_queue', {}, ctx);
  assert.equal(fetched.filter((u) => u.includes('api.github.com')).length, 1, 'the recorder must see the GitHub call');
});

test('15 a token cfg: the token never appears in any output', async (t) => {
  const live = clone(FIXTURE);
  live.batches[0].eta_basis = `basis ${TOKEN}`;
  const routes = baseRoutes(live);
  const { call, stub } = await withStub(t, routes, { token: TOKEN });
  const texts = [];
  for (const [n, a] of [['merge_queue', {}], ['pr_stage', { repo: 'acme/widgets', pr: 101 }], ['backlog', { project: 'widgets' }]]) {
    const r = await call(n, a);
    for (const c of r.content) texts.push(c.text);
    texts.push(JSON.stringify(r.structuredContent));
  }
  assert.ok(stub.requests.every((q) => q.authorization === `Bearer ${TOKEN}`));
  assert.deepEqual(texts.filter((x) => x.includes(TOKEN)), []);
  assert.ok(texts[0].includes('[redacted]'), 'the planted token was redacted, not dropped');
});

test('7d a lead_block newer than the queue stage is the blocker', async (t) => {
  const routes = baseRoutes();
  routes[events('acme/widgets', 102)] = { json: { rows: [
    { state: 'lead_block', since: '2026-10-09T03:15:00Z', reason: 'needs a rebase', at: '2026-10-09T03:15:01Z' },
    ...EVENTS_102.rows,
  ] } };
  const { call } = await withStub(t, routes);
  const o = out(await call('pr_stage', { repo: 'acme/widgets', pr: 102 }));
  assert.equal(o.queue_stage.stage, 'checking');
  assert.equal(o.blocked_on, 'needs a rebase');
});

test('9c inverse case: a mixed-case queue key matches a lowercase query', async (t) => {
  const live = clone(FIXTURE);
  live.prs['Acme/Widgets#102'] = live.prs['acme/widgets#102'];
  delete live.prs['acme/widgets#102'];
  const routes = baseRoutes(live);
  routes[events('Acme/Widgets', 102)] = { json: EVENTS_102 };
  routes[tiers('Acme/Widgets', 102)] = { json: { rows: [] } };
  const { call } = await withStub(t, routes);
  const o = out(await call('pr_stage', { repo: 'acme/widgets', pr: 102 }));
  assert.equal(o.queue_stage.stage, 'checking');
  assert.equal(o.repo, 'Acme/Widgets');
  assert.equal(o.partial, undefined);
});
