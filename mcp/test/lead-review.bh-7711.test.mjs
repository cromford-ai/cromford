// BH-7711: the lead review MCP tools in mcp/tools/lead-review.mjs.
// lead_review_show reads a PR's verdict rows, its lead review requests and the
// BLOCK and NOTE findings of its report (the job's lead_review_report
// artifact, or its lead_report transcript when the artifact was cut).
// lead_review_request and lead_review_reset are guarded: confirm must be the
// boolean true, or nothing is sent.
// Every case goes through the REAL registry (loadTools + callTool) and the
// REAL consoleFetch against the stub console. globalThis.fetch is wrapped
// before the tools load, so "0 other network calls" is measured.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { createInterface } from 'node:readline';
import { fileURLToPath } from 'node:url';
import { join } from 'node:path';

const fetched = [];
const realFetch = globalThis.fetch;
let stubOrigin = null;
globalThis.fetch = (input, init) => {
  const url = String(input instanceof Request ? input.url : input);
  fetched.push(url);
  if (!stubOrigin || !url.startsWith(stubOrigin + '/')) return Promise.reject(new Error(`blocked off-stub fetch: ${url}`));
  return realFetch(input, init);
};

const { loadTools, callTool } = await import('../lib/tools.mjs');
const { startStub } = await import('./lib/stub-console.mjs');
const lr = await import('../tools/lead-review.mjs').catch(() => ({}));

const SERVER = fileURLToPath(new URL('../server.mjs', import.meta.url));
const TOKEN = 'tok-fixture-lead-review';
const SECRET = 'sec-fixture-lead-review';
const COOKIE = 'ck-fixture-lead-review';

const REPO = 'acme/app';
const PR = 7;
const SHA = '1f'.repeat(20);
const OLD_SHA = '0e'.repeat(20);
const Q = 'repo=acme%2Fapp&pr=7';
const VERDICTS = `/api/coord/verdicts?${Q}`;
const REQUESTS = `/api/coord/lead-reviews?${Q}&limit=100`;
const artifacts = (job) => `/api/coord/jobs/${job}/artifacts`;
const transcripts = (job) => `/api/coord/jobs/${job}/transcripts`;
const transcript = (job, p, a) => `/api/coord/jobs/${job}/transcript?phase_id=${p}&attempt=${a}`;

// A report in the shape bin/lead-review.sh writes: the title line names the
// key, the repo#pr and the head; findings are `- [BLOCK ...]` / `- [NOTE]`
// items with indented continuation lines.
const title = (sha = SHA, repo = REPO, pr = PR) => `# Lead review lr-${pr}-${sha.slice(0, 12)} (${repo}#${pr} at ${sha})`;
const REPORT = [
  title(),
  '',
  '- verdict: BLOCK',
  '- reviewer model: fixture-model',
  '',
  'Findings',
  '- [BLOCK wrong-data] src/a.js:10: the total drops the project-2 line',
  '- [BLOCK core-flow-broken] src/b.js:4: the save button posts to a route',
  '  that does not exist',
  '- [NOTE] docs/x.md:1: a typo',
  '-[BLOCK] no space, not a finding',
  '- [blocker] lowercase, not a finding',
  'text with a [BLOCK] mid-line, not a finding',
  '- none',
  '',
].join('\n');
// lr_detail's shape: {body, path, verdict} as a JSON string.
const detail = (body, extra = {}) => JSON.stringify({ body, path: '/srv/state/lead-review/lr-7.md', verdict: 'BLOCK', ...extra });

const VERDICT_ROWS = [
  { id: 42, repo: REPO, pr: PR, head_sha: SHA, verdict: 'BLOCK', source: 'lead', reviewer: 'hub', reviewer_model: 'fixture-model',
    report_url: null, note: 'lead-review:req-2 lead-job:J9 report:/srv/state/lead-review/lr-7.md', created_at: '2026-10-20T12:00:00Z' },
  { id: 40, repo: REPO, pr: PR, head_sha: OLD_SHA, verdict: 'MERGE', source: 'lead', reviewer: 'hub', reviewer_model: 'fixture-model',
    report_url: null, note: 'lead-review:req-1 lead-job:J1', created_at: '2026-10-19T12:00:00Z' },
];
// The worker answers oldest first.
const REQUEST_ROWS = [
  { id: 'req-1', repo: REPO, pr: PR, head_sha: OLD_SHA, status: 'done', job_id: 'J1', box: 'box-a', verdict: 'MERGE',
    report_ref: '/srv/r1.md', created_at: '2026-10-19T11:00:00Z', updated_at: '2026-10-19T12:00:00Z' },
  { id: 'req-2', repo: REPO, pr: PR, head_sha: SHA, status: 'done', job_id: 'J9', box: 'box-b', verdict: 'BLOCK',
    report_ref: '/srv/state/lead-review/lr-7.md', created_at: '2026-10-20T11:00:00Z', updated_at: '2026-10-20T12:00:00Z' },
];
const artifactsOf = (d) => ({ artifacts: [{ artifact_kind: 'build_log', detail: 'x' }, { artifact_kind: 'lead_review_report', ref: '/srv/r.md', detail: d }] });

function routes(over = {}) {
  return {
    [VERDICTS]: { json: { repo: REPO, pr: PR, rows: VERDICT_ROWS, truncated: false } },
    [REQUESTS]: { json: { requests: REQUEST_ROWS, truncated: false } },
    [artifacts('J9')]: { json: artifactsOf(detail(REPORT)) },
    ...over,
  };
}

const registry = await loadTools(new URL('../tools/', import.meta.url));

async function withStub(t, r = routes(), auth = { token: TOKEN }) {
  const stub = await startStub({ routes: r });
  stubOrigin = stub.url;
  t.after(() => stub.close());
  const ctx = { cfg: { url: stub.url, token: null, secret: null, allowlist: [], ...auth } };
  const call = (name, args) => callTool(registry, name, args, ctx);
  const api = () => stub.requests.filter((q) => !q.path.startsWith('/login/'));
  return { stub, call, api };
}
const out = (r) => {
  assert.notEqual(r.isError, true, r.content?.[0]?.text);
  return r.structuredContent;
};
const errText = (r) => {
  assert.equal(r.isError, true, JSON.stringify(r));
  return r.content[0].text;
};
const offStub = () => fetched.filter((u) => !u.startsWith(stubOrigin + '/'));

test('T0 registry: show is read, request and reset are guarded, all closed', () => {
  const closed = (s) => s.type !== 'object' ||
    (s.additionalProperties === false && Object.values(s.properties ?? {}).every(closed));
  assert.equal(registry.get('lead_review_show')?.kind, 'read');
  assert.equal(registry.get('lead_review_request')?.kind, 'guarded');
  assert.equal(registry.get('lead_review_reset')?.kind, 'guarded');
  for (const n of ['lead_review_show', 'lead_review_request', 'lead_review_reset']) assert.ok(closed(registry.get(n).inputSchema), n);
  assert.deepEqual(registry.get('lead_review_show').inputSchema.required, ['repo', 'pr']);
  assert.ok(registry.get('lead_review_request').inputSchema.required.includes('confirm'));
  assert.ok(registry.get('lead_review_reset').inputSchema.required.includes('confirm'));
});

// ---- show ----

test('S1 show: verdicts newest first, requests newest first, the BLOCK and NOTE findings', async (t) => {
  const { call } = await withStub(t);
  const o = out(await call('lead_review_show', { repo: REPO, pr: PR }));
  assert.deepEqual(o.verdicts.map((v) => v.id), [42, 40]);
  assert.equal(o.verdicts[0].verdict, 'BLOCK');
  assert.equal(o.verdicts_complete, true);
  assert.deepEqual(o.requests.map((q) => q.id), ['req-2', 'req-1']);
  assert.equal(o.requests[0].box, 'box-b');
  assert.equal(o.requests_complete, true);
  assert.equal(o.report.job_id, 'J9');
  assert.equal(o.report.head_sha, SHA);
  assert.equal(o.report.from, 'artifact');
  assert.equal(o.report.truncated, false);
  assert.equal(o.report.title, title());
  assert.deepEqual(o.report.block, [
    { tag: 'BLOCK wrong-data', text: 'src/a.js:10: the total drops the project-2 line' },
    { tag: 'BLOCK core-flow-broken', text: 'src/b.js:4: the save button posts to a route that does not exist' },
  ]);
  assert.deepEqual(o.report.note, [{ tag: 'NOTE', text: 'docs/x.md:1: a typo' }]);
  assert.equal(o.report.findings_complete, true);
  assert.equal('partial' in o, false);
  assert.deepEqual(offStub(), []);
});

test('S1b report job choice: verdict lead-job token, then the newest done request', () => {
  assert.equal(typeof lr.pickReportJob, 'function', 'pickReportJob is exported');
  const v = (note, id = 1) => ({ id, note, head_sha: SHA, verdict: 'BLOCK' });
  const rq = (status, job_id, head_sha = OLD_SHA) => ({ status, job_id, head_sha, verdict: 'MERGE' });
  const cases = [
    [[v('lead-review:abc lead-job:J9 report:/x')], [], 'J9'],
    [[v('lead-job:J9')], [], 'J9'],
    [[v('no token here')], [rq('done', 'J4')], 'J4'],
    [[v('lead-job:J2', 2), v('lead-job:J1', 1)], [], 'J2'],
    [[v('lead-job:')], [], null],
    [[v('xlead-job:J1')], [], null],
    [[], [rq('running', 'J5'), rq('requested', 'J6')], null],
    [null, [rq('done', 'J7')], 'J7'],
    [[v('lead-job:J8')], null, 'J8'],
  ];
  for (const [verdicts, requests, want] of cases) {
    const got = lr.pickReportJob(verdicts, requests);
    assert.equal(got ? got.job_id : null, want, JSON.stringify({ verdicts, requests }));
  }
  assert.equal(lr.pickReportJob([], [rq('done', 'J4', SHA)]).head_sha, SHA);
});

test('S1c finding lines: what counts and what does not', () => {
  assert.equal(typeof lr.findings, 'function', 'findings is exported');
  const f = lr.findings([
    '- [BLOCK needs-human] a', '- [BLOCK] b', '  continued', '\tand more', '- [NOTE] c',
    '-[BLOCK] x', '- [blocker] x', 'a [BLOCK] mid-line', '- none', '> - [BLOCK] quoted',
  ].join('\n'));
  assert.deepEqual(f.block, [{ tag: 'BLOCK needs-human', text: 'a' }, { tag: 'BLOCK', text: 'b continued and more' }]);
  assert.deepEqual(f.note, [{ tag: 'NOTE', text: 'c' }]);
  assert.equal(f.complete, true);
  const many = lr.findings(Array.from({ length: 105 }, (_, i) => `- [BLOCK] item ${i}`).join('\n'));
  assert.equal(many.block.length, 100);
  assert.equal(many.complete, false);
  assert.equal(lr.findings(`- [NOTE] ${'x'.repeat(3000)}`).note[0].text.length, 2000);
});

test('S2 the verdicts and requests GETs are both sent before the artifacts GET', async (t) => {
  const { call, api } = await withStub(t);
  out(await call('lead_review_show', { repo: REPO, pr: PR }));
  const paths = api().map((q) => `${q.method} ${q.path}`);
  assert.deepEqual(paths.slice(0, 2).sort(), [`GET ${REQUESTS}`, `GET ${VERDICTS}`].sort());
  assert.deepEqual(paths.slice(2), [`GET ${artifacts('J9')}`]);
});

test('S3 a cut artifact: the whole lead_report transcript is used; a cut transcript keeps truncated', async (t) => {
  const cut = REPORT.split('- [NOTE]')[0];
  const full = REPORT + '- [BLOCK] src/c.js:1: a finding past the cut\n';
  const idx = { transcripts: [
    { phase_id: 0, attempt: 1, source: 'agent' },
    { phase_id: 0, attempt: 1, source: 'lead_report' },
    { phase_id: 0, attempt: 2, source: 'lead_report' },
  ] };
  const base = {
    [artifacts('J9')]: { json: artifactsOf(detail(cut, { truncated: true })) },
    [transcripts('J9')]: { json: idx },
  };
  {
    const { call, api } = await withStub(t, routes({ ...base, [transcript('J9', 0, 2)]: { json: { transcript: { body: full, truncated: 0 } } } }));
    const o = out(await call('lead_review_show', { repo: REPO, pr: PR }));
    assert.equal(o.report.from, 'transcript');
    assert.equal(o.report.truncated, false);
    assert.ok(o.report.block.some((b) => b.text === 'src/c.js:1: a finding past the cut'));
    assert.equal(o.report.note.length, 1);
    assert.ok(api().some((q) => q.path === transcript('J9', 0, 2)));
  }
  {
    const { call } = await withStub(t, routes({ ...base, [transcript('J9', 0, 2)]: { json: { transcript: { body: full, truncated: 1 } } } }));
    const o = out(await call('lead_review_show', { repo: REPO, pr: PR }));
    assert.equal(o.report.from, 'artifact');
    assert.equal(o.report.truncated, true);
    assert.equal(o.report.block.length, 2);
    assert.equal(o.report.note.length, 0);
  }
  {
    // A transcript whose title names another head is not used.
    const other = full.replace(title(), title(OLD_SHA));
    const { call } = await withStub(t, routes({ ...base, [transcript('J9', 0, 2)]: { json: { transcript: { body: other, truncated: 0 } } } }));
    const o = out(await call('lead_review_show', { repo: REPO, pr: PR }));
    assert.equal(o.report.from, 'artifact');
    assert.equal(o.report.truncated, true);
  }
});

test('S4 a report whose title names another head is no report', async (t) => {
  const { call } = await withStub(t, routes({ [artifacts('J9')]: { json: artifactsOf(detail(REPORT.replace(title(), title(OLD_SHA)))) } }));
  const o = out(await call('lead_review_show', { repo: REPO, pr: PR }));
  assert.equal(o.report, null);
  assert.match(o.report_missing, /title/);
  assert.deepEqual(o.verdicts.map((v) => v.id), [42, 40]);
});

test('S5 no report job, and a job with no artifact: report null, report_missing names box and report_ref', async (t) => {
  {
    const reqs = [{ id: 'req-3', repo: REPO, pr: PR, status: 'failed', job_id: 'J3', box: 'box-c', report_ref: '/srv/r3.md', head_sha: SHA, created_at: '2026-10-20T11:00:00Z' }];
    const { call, api } = await withStub(t, routes({
      [VERDICTS]: { json: { rows: [], truncated: false } },
      [REQUESTS]: { json: { requests: reqs, truncated: false } },
    }));
    const o = out(await call('lead_review_show', { repo: REPO, pr: PR }));
    assert.equal(o.report, null);
    assert.match(o.report_missing, /box-c/);
    assert.match(o.report_missing, /\/srv\/r3\.md/);
    assert.equal(api().length, 2, 'no artifacts read without a report job');
  }
  {
    const { call } = await withStub(t, routes({ [artifacts('J9')]: { json: { artifacts: [{ artifact_kind: 'build_log', detail: 'x' }] } } }));
    const o = out(await call('lead_review_show', { repo: REPO, pr: PR }));
    assert.equal(o.report, null);
    assert.match(o.report_missing, /J9/);
    assert.match(o.report_missing, /box-b/);
    assert.match(o.report_missing, /\/srv\/state\/lead-review\/lr-7\.md/);
  }
  {
    const { call } = await withStub(t, routes({ [artifacts('J9')]: { json: artifactsOf('{not json') } }));
    const o = out(await call('lead_review_show', { repo: REPO, pr: PR }));
    assert.equal(o.report, null);
    assert.match(o.report_missing, /detail/);
  }
});

test('S6 one failed read is named in partial; both failed is an error', async (t) => {
  {
    const { stub, call } = await withStub(t);
    stub.fail(REQUESTS, 500);
    const o = out(await call('lead_review_show', { repo: REPO, pr: PR }));
    assert.equal(o.requests, null);
    assert.equal(o.requests_complete, null);
    assert.deepEqual(o.partial, ['/api/coord/lead-reviews']);
    assert.deepEqual(o.verdicts.map((v) => v.id), [42, 40]);
    assert.equal(o.report.job_id, 'J9', 'the verdict token still finds the report');
  }
  {
    const { stub, call } = await withStub(t);
    stub.fail(REQUESTS, 500);
    stub.fail(VERDICTS, 500);
    assert.match(errText(await call('lead_review_show', { repo: REPO, pr: PR })), /http_500/);
  }
  {
    // A full page is not complete.
    const rows = Array.from({ length: 100 }, (_, i) => ({ ...VERDICT_ROWS[1], id: 1000 - i, note: null }));
    const { call } = await withStub(t, routes({
      [VERDICTS]: { json: { rows, truncated: true } },
      [REQUESTS]: { json: { requests: REQUEST_ROWS, truncated: true, next_after: 'x,1' } },
    }));
    const o = out(await call('lead_review_show', { repo: REPO, pr: PR }));
    assert.equal(o.verdicts_complete, false);
    assert.equal(o.requests_complete, false);
  }
});

test('S6b a worker that ignores pr: rows of another pr are not shown', async (t) => {
  const other = { ...REQUEST_ROWS[1], id: 'req-other', pr: 8, job_id: 'J8', created_at: '2026-10-20T13:00:00Z' };
  const { call } = await withStub(t, routes({ [REQUESTS]: { json: { requests: [...REQUEST_ROWS, other], truncated: false } } }));
  const o = out(await call('lead_review_show', { repo: REPO, pr: PR }));
  assert.deepEqual(o.requests.map((q) => q.id), ['req-2', 'req-1']);
});

test('S7 bad arguments are refused and send nothing', async (t) => {
  const { call, api } = await withStub(t);
  for (const args of [{ repo: REPO, pr: 0 }, { repo: 'x', pr: 7 }, { repo: REPO, pr: 7, extra: 1 }, { repo: REPO }, { pr: 7 },
    { repo: 'a/b c', pr: 7 }, { repo: REPO, pr: '7' }]) {
    assert.match(errText(await call('lead_review_show', args)), /^invalid_arguments/, JSON.stringify(args));
  }
  assert.equal(api().length, 0);
});

// ---- request ----

const REQ_ARGS = { repo: REPO, pr: PR, head_sha: SHA.toUpperCase(), notes: 'look at the cache', priority: 5, confirm: true };
const POST_REQ = '/api/coord/lead-reviews';

test('Q1 request without confirm: confirm_required and 0 requests', async (t) => {
  const { call, api } = await withStub(t);
  for (const c of [undefined, false, 'true', 1]) {
    const args = { ...REQ_ARGS };
    if (c === undefined) delete args.confirm; else args.confirm = c;
    assert.equal(errText(await call('lead_review_request', args)), 'confirm_required', String(c));
  }
  // confirm is checked first: a call that is wrong in every other way still says confirm_required.
  assert.equal(errText(await call('lead_review_request', { pr: 'x', extra: 1 })), 'confirm_required');
  assert.equal(api().length, 0);
});

test('Q2 request with confirm: one POST with the lowercased sha, the notes as scope_notes and the priority', async (t) => {
  const stored = { request: { id: 'req-9', repo: REPO, pr: PR, head_sha: SHA, status: 'requested', priority: 5 } };
  const { call, api } = await withStub(t, routes({ [POST_REQ]: { status: 201, json: stored } }));
  const o = out(await call('lead_review_request', REQ_ARGS));
  assert.equal(o.request.id, 'req-9');
  const sent = api();
  assert.equal(sent.length, 1);
  assert.equal(sent[0].method, 'POST');
  assert.equal(sent[0].path, POST_REQ);
  assert.equal(sent[0].authorization, `Bearer ${TOKEN}`);
  assert.deepEqual(sent[0].body, { repo: REPO, pr: PR, head_sha: SHA, scope_notes: 'look at the cache', priority: 5 });

  const bare = await withStub(t, routes({ [POST_REQ]: { status: 201, json: { request: { id: 'req-10', status: 'requested', priority: null } } } }));
  out(await bare.call('lead_review_request', { repo: REPO, pr: PR, head_sha: SHA, confirm: true }));
  assert.deepEqual(bare.api()[0].body, { repo: REPO, pr: PR, head_sha: SHA });
});

test('Q3 a short or non-hex sha, a bad repo or priority: refused, 0 requests', async (t) => {
  const { call, api } = await withStub(t);
  for (const over of [{ head_sha: SHA.slice(0, 39) }, { head_sha: 'g'.repeat(40) }, { head_sha: SHA + 'a' }, { repo: 'nope' },
    { priority: 0 }, { priority: 1001 }, { priority: 2.5 }, { pr: 0 }, { notes: 'x'.repeat(4001) }, { extra: 1 }]) {
    assert.match(errText(await call('lead_review_request', { ...REQ_ARGS, ...over })), /^invalid_arguments/, JSON.stringify(over));
  }
  assert.equal(api().length, 0);
});

test('Q4 a stored row without the asked priority is an error', async (t) => {
  const answer = { request: { id: 'req-9', status: 'running', priority: null }, existing: true };
  const { call, api } = await withStub(t, routes({ [POST_REQ]: { status: 200, json: answer } }));
  assert.equal(errText(await call('lead_review_request', REQ_ARGS)), 'priority_not_stored: request req-9 is running');
  assert.equal(api().length, 1);
});

test('Q5 a refusal from the console carries its http code and reason', async (t) => {
  const { call } = await withStub(t, routes({ [POST_REQ]: { status: 409, json: { error: 'already exists with different scope_notes' } } }));
  assert.match(errText(await call('lead_review_request', REQ_ARGS)), /^http_409: already exists/);
});

// ---- reset ----

const ID = 'lead-review-r1';
const RESET = `/api/coord/lead-reviews/${ID}/reset`;

test('X1 reset without confirm: confirm_required and 0 requests', async (t) => {
  const { call, api } = await withStub(t);
  for (const c of [undefined, false, 'true', 1]) {
    const args = { request_id: ID };
    if (c !== undefined) args.confirm = c;
    assert.equal(errText(await call('lead_review_reset', args)), 'confirm_required', String(c));
  }
  assert.equal(api().length, 0);
});

test('X2 reset with confirm: one POST to the reset route with {}', async (t) => {
  const { call, api } = await withStub(t, routes({ [RESET]: { json: { request: { id: ID, status: 'requested', reset_count: 1 } } } }));
  const o = out(await call('lead_review_reset', { request_id: ID, confirm: true }));
  assert.equal(o.request.status, 'requested');
  const sent = api();
  assert.equal(sent.length, 1);
  assert.equal(sent[0].method, 'POST');
  assert.equal(sent[0].path, RESET);
  assert.deepEqual(sent[0].body, {});
});

test('X3 an id of . or .. or with a slash is refused, 0 requests', async (t) => {
  const { call, api } = await withStub(t);
  for (const id of ['..', '.', 'a/b', 'a b', '', 'x'.repeat(129)]) {
    assert.match(errText(await call('lead_review_reset', { request_id: id, confirm: true })), /^invalid_arguments/, id);
  }
  assert.equal(api().length, 0);
});

test('X4 a reclaimed stale running request comes back with reclaimed_from', async (t) => {
  const answer = {
    request: { id: ID, status: 'requested', job_id: null, reset_count: 1 },
    reclaimed_from: { job_id: 'J-old', box: 'box-a', participant: null, last_beat: '2026-10-20T10:00:00Z' },
    stale_s: 900,
  };
  const { call } = await withStub(t, routes({ [RESET]: { json: answer } }));
  const o = out(await call('lead_review_reset', { request_id: ID, confirm: true }));
  assert.equal(o.reclaimed_from.job_id, 'J-old');
  assert.equal(o.stale_s, 900);
  assert.equal(o.request.status, 'requested');
  const busy = await withStub(t, routes({ [RESET]: { status: 409, json: { error: 'lead review request is running (job J-live)' } } }));
  assert.match(errText(await busy.call('lead_review_reset', { request_id: ID, confirm: true })), /^http_409: lead review request is running/);
});

// ---- no secret leaves through the real server ----

function spawnServer(env) {
  const child = spawn(process.execPath, [SERVER], { env: { PATH: process.env.PATH, ...env }, stdio: ['pipe', 'pipe', 'pipe'] });
  let stderr = '';
  child.stderr.on('data', (c) => { stderr += c; });
  const pending = new Map();
  createInterface({ input: child.stdout }).on('line', (line) => {
    const m = JSON.parse(line);
    pending.get(m.id)?.(m);
    pending.delete(m.id);
  });
  const exited = new Promise((r) => child.on('exit', r));
  let id = 0;
  const rpc = (method, params) => new Promise((resolve) => {
    pending.set(++id, resolve);
    child.stdin.write(JSON.stringify({ jsonrpc: '2.0', id, method, params }) + '\n');
  });
  return { rpc, end: async () => { child.stdin.end(); await exited; return stderr; }, kill: () => child.kill() };
}

// The reset route has no fixture, so the stub echoes the auth headers back:
// the tool must scrub them. The report and the stored request row are
// fixtures that carry the credential values, so show and request are checked
// the same way.
async function leakRun(env, stubOpts, values) {
  const echo = `echo ${values.join(' ')}`;
  const leaky = `${REPORT}- [NOTE] ${echo}\n`;
  const stub = await startStub({ ...stubOpts, routes: routes({
    [artifacts('J9')]: { json: artifactsOf(detail(leaky)) },
    [POST_REQ]: { status: 201, json: { request: { id: 'req-9', status: 'requested', priority: null, scope_notes: echo } } },
  }) });
  const srv = spawnServer({ HARNESS_CONSOLE_URL: stub.url, ...env });
  try {
    const seen = [];
    const keep = (r) => {
      seen.push(JSON.stringify(r));
      for (const c of r.result?.content ?? []) seen.push(c.text);
      if (r.result?.structuredContent !== undefined) seen.push(JSON.stringify(r.result.structuredContent));
    };
    const results = [];
    for (const [name, args] of [
      ['lead_review_show', { repo: REPO, pr: PR }],
      ['lead_review_request', { repo: REPO, pr: PR, head_sha: SHA, confirm: true }],
      ['lead_review_reset', { request_id: ID, confirm: true }],
    ]) {
      const r = await srv.rpc('tools/call', { name, arguments: args });
      keep(r);
      results.push(r);
    }
    const stderr = await srv.end();
    return { seen, stderr, stub, results };
  } finally {
    srv.kill();
    await stub.close();
  }
}

const leaks = (texts, v) => texts.filter((x) => typeof x === 'string' && x.includes(v));

test('L0 in process, without the server: each tool scrubs its own answer', async (t) => {
  // server.mjs redacts again on the way out; this pins the tool's own layer.
  const leaky = `${REPORT}- [NOTE] echo ${TOKEN}\n`;
  const { call } = await withStub(t, routes({
    [artifacts('J9')]: { json: artifactsOf(detail(leaky)) },
    [POST_REQ]: { status: 201, json: { request: { id: 'req-9', status: 'requested', priority: null, scope_notes: TOKEN } } },
  }));
  for (const [name, args] of [
    ['lead_review_show', { repo: REPO, pr: PR }],
    ['lead_review_request', { repo: REPO, pr: PR, head_sha: SHA, confirm: true }],
    ['lead_review_reset', { request_id: ID, confirm: true }],
  ]) {
    const r = await call(name, args);
    assert.notEqual(r.isError, true, r.content?.[0]?.text);
    const text = r.content[0].text;
    assert.ok(text.includes('[redacted]'), `${name}: positive control, the answer carried the token`);
    assert.ok(!text.includes(TOKEN), `${name} text leaked the token`);
    assert.ok(!JSON.stringify(r.structuredContent).includes(TOKEN), `${name} structuredContent leaked the token`);
  }
});

test('L1 token: all three tools run, the token never surfaces', async () => {
  const { seen, stderr, stub, results } = await leakRun({ HARNESS_CONSOLE_TOKEN: TOKEN }, {}, [TOKEN]);
  for (const r of results) assert.notEqual(r.result?.isError, true, JSON.stringify(r));
  const posts = stub.requests.filter((q) => q.method === 'POST');
  assert.equal(posts.length, 2);
  assert.ok(posts.every((q) => q.authorization === `Bearer ${TOKEN}`), 'positive control: the token was sent');
  for (const r of results) assert.ok(r.result.content[0].text.includes('[redacted]'), 'positive control: each answer carried the credential');
  assert.deepEqual(leaks(seen, TOKEN), []);
  assert.ok(!stderr.includes(TOKEN), stderr);
});

test('L2 secret: one login, neither the secret nor the cookie surfaces', async () => {
  const { seen, stderr, stub, results } = await leakRun({ HARNESS_CONSOLE_SECRET: SECRET }, { cookie: COOKIE }, [SECRET, COOKIE]);
  for (const r of results) assert.notEqual(r.result?.isError, true, JSON.stringify(r));
  assert.equal(stub.requests.filter((q) => q.path.startsWith('/login/')).length, 1);
  assert.ok(stub.requests.filter((q) => q.method === 'POST').every((q) => q.cookie === `dash=${COOKIE}`), 'positive control: the cookie was sent');
  for (const v of [SECRET, COOKIE]) {
    assert.deepEqual(leaks(seen, v), [], `${v} surfaced`);
    assert.ok(!stderr.includes(v), stderr);
  }
});
