// BH-7714: the batch_failure MCP tool in mcp/tools/batch-failure.mjs and its
// GitHub seam mcp/lib/github.mjs. Every tool case goes through the REAL
// registry (loadTools + callTool) and the REAL githubFetch against a loopback
// stub that serves fixtures/batch-failure.bh-7714.json. globalThis.fetch and
// node:child_process are wrapped BEFORE the tools load, so "0 network calls
// off the stub, no gh" is measured. B12 spawns the real server.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createRequire, syncBuiltinESMExports } from 'node:module';
import { cpSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { createInterface } from 'node:readline';
import http from 'node:http';
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
  if (!stubOrigin || !url.startsWith(stubOrigin + '/')) return Promise.reject(new Error(`blocked off-stub fetch: ${url}`));
  return realFetch(input, init);
};
const spawned = [];
const cp = createRequire(import.meta.url)('node:child_process');
const realSpawn = cp.spawn; // B12 only: the test spawns the server, the tool never may
for (const fn of ['spawn', 'exec', 'execFile', 'execSync', 'execFileSync', 'spawnSync', 'fork']) {
  cp[fn] = (...a) => { spawned.push(`${fn} ${String(a[0])}`); throw new Error(`child_process.${fn} blocked`); };
}
syncBuiltinESMExports();

const { loadTools, callTool } = await import('../lib/tools.mjs');
const { githubConfig, githubFetch, scrubToken } = await import('../lib/github.mjs');
const bf = await import('../tools/batch-failure.mjs');

const HERE = dirname(fileURLToPath(import.meta.url));
const MCP_DIR = join(HERE, '..');
const FIXTURE = JSON.parse(readFileSync(join(HERE, 'fixtures/batch-failure.bh-7714.json'), 'utf8'));
const clone = (v) => JSON.parse(JSON.stringify(v));
const GH_TOKEN = 'gh-tok-fixture-a';
const R = '/repos/acme/widgets';
const P1 = '?per_page=100&page=1';
const HEAD = FIXTURE.head_sha;
const ESC = '\u001b';
const registry = await loadTools(new URL('../tools/', import.meta.url));

// A GitHub stand-in. Routes are the fixture's: {status, json|text, headers}.
// `{{origin}}` becomes the stub origin, `{{auth}}` the request's authorization
// header (B12 echoes the token back to prove the reply scrubs it).
function startGithub(routes) {
  const requests = [];
  const server = http.createServer((req, res) => {
    req.resume();
    req.on('end', () => {
      const authorization = req.headers.authorization ?? null;
      requests.push({ method: req.method, path: req.url, authorization });
      const fill = (s) => s.split('{{origin}}').join(origin).split('{{auth}}').join(String(authorization));
      const r = routes[req.url];
      if (!r) {
        res.writeHead(404, { 'content-type': 'application/json' });
        return res.end('{"message":"Not Found"}');
      }
      const headers = Object.fromEntries(Object.entries(r.headers ?? {}).map(([k, v]) => [k, fill(v)]));
      const text = r.text !== undefined ? r.text : JSON.stringify(r.json ?? null);
      res.writeHead(r.status ?? 200, { 'content-type': r.text !== undefined ? 'text/plain' : 'application/json', ...headers });
      res.end(fill(text));
    });
  });
  let origin;
  return new Promise((resolve) => server.listen(0, '127.0.0.1', () => {
    origin = `http://127.0.0.1:${server.address().port}`;
    resolve({
      url: origin, requests,
      close: () => new Promise((r) => { server.closeAllConnections?.(); server.close(() => r()); }),
    });
  }));
}

async function withGithub(t, routes = clone(FIXTURE.routes), token = GH_TOKEN) {
  const gh = await startGithub(routes);
  stubOrigin = gh.url;
  t.after(() => gh.close());
  const ctx = { cfg: { url: 'http://console.invalid', token: null, secret: null }, github: { url: gh.url, token } };
  const call = (args) => callTool(registry, 'batch_failure', args, ctx);
  return { gh, ctx, call };
}
const ok = (r) => {
  assert.notEqual(r.isError, true, r.content?.[0]?.text);
  assert.deepEqual(r.structuredContent, JSON.parse(r.content[0].text), 'structuredContent is the text, parsed');
  return r.structuredContent;
};
const pr = (o, n) => o.prs.find((x) => x.pr === n);
const run = (id, name, conclusion, status = 'completed', slug = 'github-actions') =>
  ({ id, name, status, conclusion: status === 'completed' ? conclusion : null, app: { slug }, output: { title: null, summary: null } });
const setChecks = (routes, runs) => { routes[`${R}/commits/${HEAD}/check-runs${P1}`] = { json: { total_count: runs.length, check_runs: runs } }; };

test('B1 culprit: the PR that adds bin/x.sh is the culprit, the other 3 members are clean', async (t) => {
  const { call, gh } = await withGithub(t);
  const o = ok(await call({ repo: 'acme/widgets', draft: 900 }));
  assert.equal(o.draft, 900);
  assert.equal(o.head_sha, HEAD);
  assert.deepEqual(o.members, [101, 102, 103, 104]);
  assert.deepEqual(o.ahead, [99]);
  assert.equal(o.batch_state, 'failed');
  assert.equal(o.dead_shards, false);
  // The failed-then-passed "Jobs worker" is not failed: latest run per name wins.
  assert.deepEqual(o.failed_checks.map((c) => c.name), ['Syntax + shellcheck + config integrity']);
  const c = o.failed_checks[0];
  assert.equal(c.lines_source, 'error');
  assert.ok(c.lines.includes('STATE-PATHS-GUARD: bin/x.sh:79: writes state/remote-results'), JSON.stringify(c.lines));
  assert.ok(c.paths.includes('bin/x.sh'), JSON.stringify(c.paths));
  assert.deepEqual(c.culprits, [102]);
  assert.deepEqual(o.culprits, [102]);
  assert.equal(o.culprit_unknown, false);
  assert.equal(pr(o, 102).culprit, true);
  for (const n of [101, 103, 104]) {
    assert.equal(pr(o, n).culprit, false, `#${n}`);
    assert.equal(pr(o, n).head_ci, 'success', `#${n}`);
    assert.equal(pr(o, n).verdict, 'success', `#${n}`);
    assert.equal(pr(o, n).role, 'member');
  }
  assert.deepEqual(o.requeue_candidates, [101, 103, 104]);
  assert.equal(o.complete, true);
  assert.equal(o.partial, undefined);
  assert.ok(gh.requests.every((q) => q.method === 'GET'));
  assert.deepEqual(spawned, []);
});

test('B2 red head CI, a failed verdict and a merged ahead PR are never re-queue candidates', async (t) => {
  const routes = clone(FIXTURE.routes);
  const sha = (n) => 'a'.repeat(37) + String(n).padStart(3, '0');
  routes[`${R}/commits/${sha(101)}/check-runs${P1}`] = { json: { total_count: 3, check_runs: [
    run(1, 'Harness CI', 'success'), run(2, 'Harness CI', 'failure'), run(3, 'lead-verdict', 'success')] } };
  routes[`${R}/commits/${sha(103)}/check-runs${P1}`] = { json: { total_count: 2, check_runs: [
    run(1, 'Harness CI', 'success'), run(2, 'lead-verdict', 'failure')] } };
  routes[`${R}/commits/${sha(104)}/check-runs${P1}`] = { json: { total_count: 1, check_runs: [run(1, 'Harness CI', null, 'in_progress')] } };
  const { call } = await withGithub(t, routes);
  const o = ok(await call({ repo: 'acme/widgets', draft: 900 }));
  assert.equal(pr(o, 101).culprit, false);
  assert.equal(pr(o, 101).head_ci, 'failure');
  assert.equal(pr(o, 103).verdict, 'failure');
  assert.equal(pr(o, 104).head_ci, 'pending');
  assert.equal(pr(o, 104).verdict, null);
  const ahead = pr(o, 99);
  assert.equal(ahead.role, 'ahead');
  assert.equal(ahead.merged, true);
  assert.equal(ahead.culprit, false);
  assert.deepEqual(o.requeue_candidates, []);
});

test('B3 dead shards: only cancelled shards → the dead-shard mark, every open PR a candidate', async (t) => {
  const routes = clone(FIXTURE.routes);
  setChecks(routes, [run(6001, 'Harness CI shard 1', 'cancelled'), run(6002, 'Harness CI shard 2', 'cancelled'),
    run(6003, 'Harness CI shard 3', 'cancelled'), run(6004, 'Syntax', 'success')]);
  const { call } = await withGithub(t, routes);
  const o = ok(await call({ repo: 'acme/widgets', draft: 900 }));
  assert.equal(o.dead_shards, true);
  assert.equal(o.note, 'dead shards, re-queue all');
  assert.equal(o.batch_state, 'dead_shards');
  assert.deepEqual(o.culprits, []);
  assert.equal(o.failed_checks.length, 3);
  assert.deepEqual(o.requeue_candidates, [101, 102, 103, 104], 'the merged ahead PR #99 is not re-queued');

  // The dead-shard decision table, on the conclusions of the latest run per name.
  const st = (runs) => bf.batchState(bf.latestByName(runs));
  assert.equal(st([run(1, 'a', 'timed_out'), run(2, 'b', 'timed_out'), run(3, 'c', 'cancelled')]), 'dead_shards');
  assert.equal(st([run(1, 'a', 'cancelled'), run(2, 'b', 'failure')]), 'failed');
  assert.equal(st([run(1, 'a', 'startup_failure')]), 'failed');
  assert.equal(st([run(1, 'a', 'success'), run(2, 'b', null, 'in_progress')]), 'pending');
  assert.equal(st([run(1, 'a', 'success')]), 'passed');
  assert.equal(st([run(1, 'a', 'cancelled'), run(2, 'a', 'success')]), 'passed', 'a re-run that passed is not failed');
});

test('B3b cancelled + failure is not dead: the culprit search runs', async (t) => {
  const routes = clone(FIXTURE.routes);
  setChecks(routes, [run(6001, 'Harness CI shard 1', 'cancelled'), run(5001, 'Syntax + shellcheck + config integrity', 'failure')]);
  const { call } = await withGithub(t, routes);
  const o = ok(await call({ repo: 'acme/widgets', draft: 900 }));
  assert.equal(o.dead_shards, false);
  assert.equal(o.note, undefined);
  assert.deepEqual(o.culprits, [102]);
});

test('B4 pr → draft through the timeline; a member and an ahead PR get their role', async (t) => {
  const { call, gh } = await withGithub(t);
  const o = ok(await call({ repo: 'acme/widgets', pr: 103 }));
  assert.equal(o.draft, 900, 'the newer human cross-reference, the Mergify issue and the backport PR are skipped');
  assert.deepEqual(o.asked, { pr: 103, role: 'member' });
  assert.deepEqual(o.culprits, [102]);
  assert.ok(!gh.requests.some((q) => q.path === `${R}/pulls/880`), 'the older draft is never read');
  assert.ok(!gh.requests.some((q) => q.path === `${R}/pulls/555`), 'a human PR is never a candidate');
  const a = ok(await call({ repo: 'acme/widgets', pr: 99 }));
  assert.equal(a.draft, 900);
  assert.deepEqual(a.asked, { pr: 99, role: 'ahead' });
});

test('B5 membersOf reads the YAML block, aheadOf the ahead section', () => {
  const body = [
    'This pull request has been created by Mergify to speculatively check the mergeability of #11, #12, #13, #14.',
    '',
    '### Queued ahead of this batch',
    '',
    '- [#7](https://github.com/acme/widgets/pull/7) one',
    '- #8 two',
    '- https://github.com/acme/widgets/pull/9 three',
    '- #10 four',
    '',
    '<details>',
    '<summary>Mergify metadata</summary>',
    '',
    '```yaml',
    '---',
    'checking_base_sha: ' + 'b'.repeat(40),
    'pull_requests:',
    '  - number: 11',
    '    scopes: []',
    '  - number: 12',
    '  - number: 13',
    '  - number: 14',
    'previous_failed_batches:',
    '  - draft_pr_number: 5',
    '    checked_pulls:',
    '      - number: 6',
    '...',
    '```',
    '</details>',
  ].join('\n');
  assert.deepEqual(bf.membersOf(body, ''), [11, 12, 13, 14]);
  assert.deepEqual(bf.aheadOf(body), [7, 8, 9, 10]);
  assert.deepEqual(bf.aheadOf('no section here #5'), []);
  assert.deepEqual(bf.membersOf('no yaml', 'merge queue: checking #21 + #22 together'), [21, 22]);
  assert.equal(bf.membersOf('no yaml', 'some title #3'), null);
});

test('B6 a normal PR as draft, and a PR with no Mergify cross-reference', async (t) => {
  const routes = clone(FIXTURE.routes);
  // A timeline longer than 3 pages: never a bare "nothing there".
  for (const p of [1, 2, 3]) {
    routes[`${R}/issues/778/timeline?per_page=100&page=${p}`] = {
      json: [{ event: 'labeled', created_at: '2026-10-20T08:00:00Z' }],
      headers: { link: `<{{origin}}${R}/issues/778/timeline?per_page=100&page=${p + 1}>; rel="next"` },
    };
  }
  const { call } = await withGithub(t, routes);
  const n = await call({ repo: 'acme/widgets', draft: 101 });
  assert.equal(n.isError, true);
  assert.equal(n.content[0].text, 'not_a_batch_draft');
  const m = await call({ repo: 'acme/widgets', pr: 777 });
  assert.equal(m.isError, true);
  assert.equal(m.structuredContent.error, 'draft_not_found');
  assert.equal(m.structuredContent.searched_events, 1);
  assert.equal(m.structuredContent.timeline_complete, true);
  const l = await call({ repo: 'acme/widgets', pr: 778 });
  assert.equal(l.isError, true);
  assert.equal(l.structuredContent.error, 'draft_not_found');
  assert.equal(l.structuredContent.searched_events, 3);
  assert.equal(l.structuredContent.timeline_complete, false);
  const g = await call({ repo: 'acme/widgets', draft: 4040 });
  assert.equal(g.isError, true);
  assert.equal(g.content[0].text, 'github_http_404');
});

// [line, kept?]. Source of each row: plan.md "Failure modes" (live = a real
// 2026-10-20 job log line; assumed = a common tool format).
const KEEP_DROP = [
  ['STATE-PATHS-GUARD: bin/remote-results-retention.sh:79: writes state/remote-results', true],
  ['FAIL: C7 1 public file(s) name worker/cloud: tests/suite-reach-check.bh-7669-test.sh', true],
  ['not ok 3 - parses the body', true],
  ['bin/x.sh:79:5: error: unexpected token [SC1073]', true],
  [`${ESC}[31mFAIL: wrapped in colour${ESC}[0m`, true],
  [`${ESC}[36;1mFAIL=0${ESC}[0m`, false],
  ['  fail-on-cache-miss: false', false],
  ['schema-additive.bh-1000-test: 2 pass, 0 fail (750 statements in worker/jobs/schema.d (composed))', false],
  ['(node:3328) [DEP0169] DeprecationWarning: `url.parse()` behavior is not standardized and prone to errors that have security implications.', false],
  ['##[group]Run FAIL=0', false],
  ['ok 4 - failures: 0', false],
  ['connecting to 127.0.0.1:8080', false],
  ['  * [new branch]          fix/pipeline-health-skip-failed-park -> origin/fix/pipeline-health-skip-failed-park', false],
];

test('B7 failureLines keeps the failure rows and drops the near misses', () => {
  for (const [line, keep] of KEEP_DROP) {
    const raw = `2026-10-20T14:01:05.0000000Z noise line\n2026-10-20T14:01:05.1000000Z ${line}\n`;
    const r = bf.failureLines(raw);
    const plain = line.replace(/\u001b\[[0-9;?]*[A-Za-z]/g, '');
    if (keep) {
      assert.equal(r.lines_source, 'error', line);
      assert.deepEqual(r.lines, [plain], line);
    } else {
      assert.equal(r.lines_source, 'tail', `kept a near miss: ${line}`);
    }
  }
  // namedPaths: a path with an extension, an absolute runner path, ./ and a bare name:line.
  const paths = bf.namedPaths([
    'STATE-PATHS-GUARD: bin/x.sh:79: writes state/remote-results',
    '/home/runner/work/widgets/widgets/lib/y.py:12: boom',
    'FAIL: ./tests/a.bh-1-test.sh',
    'z.js:4 bad, connecting to 127.0.0.1:8080, see bin/x.sh.bak:1',
  ]);
  assert.deepEqual(paths.sort(), ['/home/runner/work/widgets/widgets/lib/y.py', 'bin/x.sh', 'bin/x.sh.bak', 'tests/a.bh-1-test.sh', 'z.js'].sort());
  const m = (p, f) => bf.pathMatches(p, f);
  assert.equal(m('bin/x.sh', 'bin/x.sh'), true);
  assert.equal(m('/home/runner/work/widgets/widgets/bin/x.sh', 'bin/x.sh'), true);
  assert.equal(m('tests/a.bh-1-test.sh', 'tests/a.bh-1-test.sh'), true);
  assert.equal(m('bin/x.sh.bak', 'bin/x.sh'), false);
  assert.equal(m('bin/x.sh', 'in/x.sh'), false, 'a suffix match needs a / boundary');
  // "Process completed" is kept next to a real failure line...
  const both = bf.failureLines('FAIL: x\n##[error]Process completed with exit code 1.\n');
  assert.deepEqual(both.lines, ['FAIL: x', '##[error]Process completed with exit code 1.']);
  // ...but alone it gives the tail before it, not the bare exit line.
  const t = bf.failureLines('a\nb\n##[error]Process completed with exit code 1.\nc\n');
  assert.equal(t.lines_source, 'tail');
  assert.deepEqual(t.lines, ['a', 'b']);
});

test('B8 at most 40 failure lines, stripped of escape codes and timestamps', () => {
  const rows = [];
  for (let i = 0; i < 300; i++) {
    const err = i % 5 === 0 && rows.filter((r) => r.includes('FAIL')).length < 55;
    rows.push(`2026-10-20T14:01:${String(i % 60).padStart(2, '0')}.1234567Z ${err ? `${ESC}[31mFAIL: case ${i} in bin/t${i}.sh:${i}${ESC}[0m` : `step ${i} fine`}`);
  }
  // 300 rows, every 5th an error: 60 candidates, the first 55 kept as FAIL.
  const raw = rows.join('\n');
  const r = bf.failureLines(raw);
  assert.equal(r.lines_total, 55);
  assert.equal(r.lines.length, 40);
  assert.equal(r.lines_source, 'error');
  for (const l of r.lines) {
    assert.ok(!l.includes(ESC), l);
    assert.doesNotMatch(l, /^\d{4}-\d{2}-\d{2}T/);
    assert.match(l, /^FAIL: case /);
  }
  assert.equal(r.lines[0], 'FAIL: case 0 in bin/t0.sh:0');
  const long = bf.failureLines(`FAIL: ${'x'.repeat(900)}\n`);
  assert.equal(long.lines[0].length, 500);
});

test('B9 refusals send nothing: no token, bad arguments', async (t) => {
  const { call, gh } = await withGithub(t, clone(FIXTURE.routes), null);
  const r = await call({ repo: 'acme/widgets', draft: 900 });
  assert.equal(r.isError, true);
  assert.equal(r.content[0].text, 'github_auth_not_configured');
  for (const [args, code] of [
    [{}, 'invalid_arguments: repo'],
    [{ repo: 'acme widgets', draft: 1 }, 'invalid_arguments: repo'],
    [{ repo: 'acme/..', draft: 1 }, 'invalid_arguments: repo'],
    [{ repo: '../widgets', draft: 1 }, 'invalid_arguments: repo'],
    [{ repo: 'acme/.', draft: 1 }, 'invalid_arguments: repo'],
    [{ repo: 'acme/widgets' }, 'pr_or_draft_required'],
    [{ repo: 'acme/widgets', pr: 1, draft: 2 }, 'pr_or_draft_required'],
    [{ repo: 'acme/widgets', draft: 0 }, 'invalid_arguments: draft'],
    [{ repo: 'acme/widgets', draft: 1, extra: 1 }, 'invalid_arguments: extra'],
  ]) {
    const x = await call(args);
    assert.equal(x.isError, true, JSON.stringify(args));
    assert.equal(x.content[0].text, code, JSON.stringify(args));
  }
  assert.equal(gh.requests.length, 0);
  // The seam itself sends nothing without a token.
  const before = fetched.length;
  assert.deepEqual(await githubFetch({ url: gh.url, token: null }, '/x'), { ok: false, status: 0, error: 'github_auth_not_configured' });
  assert.equal(fetched.length, before);
  assert.deepEqual(githubConfig({}), { url: 'https://api.github.com', token: null, rawCap: 8 * 1024 * 1024 });
  assert.deepEqual(githubConfig({ HARNESS_MCP_GITHUB_URL: ' http://127.0.0.1:9/ ', HARNESS_MCP_GITHUB_TOKEN: ' t-fixture \n' }),
    { url: 'http://127.0.0.1:9', token: 't-fixture', rawCap: 8 * 1024 * 1024 });
  assert.equal(githubConfig({ HARNESS_MCP_GITHUB_URL: 'ftp://x' }).url, null);
});

test('B10 the job log follows the redirect once, with no authorization header', async (t) => {
  const { call, gh } = await withGithub(t);
  const o = ok(await call({ repo: 'acme/widgets', draft: 900 }));
  const logReq = gh.requests.find((q) => q.path === `${R}/actions/jobs/5001/logs`);
  const blob = gh.requests.find((q) => q.path.startsWith('/blob/'));
  assert.equal(logReq.authorization, `Bearer ${GH_TOKEN}`, 'positive control: the API call is authorized');
  assert.ok(blob, 'the blob was read');
  assert.equal(blob.authorization, null, 'the signed blob URL gets no token');
  assert.equal(gh.requests.filter((q) => q.path.startsWith('/blob/')).length, 1);
  assert.ok(!JSON.stringify(o).includes('sig=fixture-signed'), 'the signed URL is never returned');
});

test('B11 a rate-limited files read: culprit unknown, named in partial, not a candidate', async (t) => {
  const routes = clone(FIXTURE.routes);
  routes[`${R}/pulls/103/files${P1}`] = { status: 403, json: { message: 'API rate limit exceeded' }, headers: { 'x-ratelimit-remaining': '0' } };
  const { call } = await withGithub(t, routes);
  const o = ok(await call({ repo: 'acme/widgets', draft: 900 }));
  assert.equal(pr(o, 103).culprit, null);
  assert.equal(pr(o, 103).files_error, 'github_rate_limited');
  assert.ok(o.partial.includes('files #103: github_rate_limited'), JSON.stringify(o.partial));
  assert.equal(o.complete, false);
  assert.deepEqual(o.requeue_candidates, [101, 104]);
  assert.deepEqual(o.culprits, [102]);

  // A failed log read leaves every non-matching PR unknown, never clean.
  const r2 = clone(FIXTURE.routes);
  r2[`${R}/actions/jobs/5001/logs`] = { status: 429, json: {}, headers: { 'retry-after': '60' } };
  const b = await withGithub(t, r2);
  const o2 = ok(await b.call({ repo: 'acme/widgets', draft: 900 }));
  assert.equal(o2.failed_checks[0].lines_source, 'read_failed');
  assert.equal(o2.failed_checks[0].error, 'github_rate_limited');
  assert.deepEqual(o2.culprits, []);
  assert.equal(o2.culprit_unknown, true);
  assert.ok(o2.prs.every((x) => x.culprit === null), JSON.stringify(o2.prs));
  assert.deepEqual(o2.requeue_candidates, []);
  assert.equal(o2.complete, false);

  // A file list past page 3 is incomplete: no match there is not "clean".
  const r3 = clone(FIXTURE.routes);
  for (const p of [1, 2, 3]) {
    r3[`${R}/pulls/101/files?per_page=100&page=${p}`] = {
      json: [{ filename: `docs/p${p}.md`, status: 'added' }],
      headers: { link: `<{{origin}}${R}/pulls/101/files?per_page=100&page=${p + 1}>; rel="next"` },
    };
  }
  const c = await withGithub(t, r3);
  const o3 = ok(await c.call({ repo: 'acme/widgets', draft: 900 }));
  assert.equal(pr(o3, 101).files_complete, false);
  assert.equal(pr(o3, 101).culprit, null);
  assert.ok(!o3.requeue_candidates.includes(101));
  assert.equal(o3.complete, false);

  // Draft check runs past page 3: an unseen check may be a failure, so no PR is clean.
  const r4 = clone(FIXTURE.routes);
  const first = r4[`${R}/commits/${HEAD}/check-runs${P1}`];
  for (const p of [1, 2, 3]) {
    r4[`${R}/commits/${HEAD}/check-runs?per_page=100&page=${p}`] = {
      json: p === 1 ? first.json : { total_count: 400, check_runs: [run(8000 + p, `extra ${p}`, 'success')] },
      headers: { link: `<{{origin}}${R}/commits/${HEAD}/check-runs?per_page=100&page=${p + 1}>; rel="next"` },
    };
  }
  const d = await withGithub(t, r4);
  const o4 = ok(await d.call({ repo: 'acme/widgets', draft: 900 }));
  assert.ok(o4.partial.includes('checks draft #900: more than 300'), JSON.stringify(o4.partial));
  assert.deepEqual(o4.culprits, [102]);
  assert.equal(pr(o4, 102).culprit, true);
  assert.ok(o4.prs.filter((x) => x.pr !== 102).every((x) => x.culprit === null), JSON.stringify(o4.prs));
  assert.deepEqual(o4.requeue_candidates, []);
});

test('B11b scrubToken removes the raw and the JSON-escaped token', () => {
  const gh = { token: 'tok"fixture\\z' };
  const s = scrubToken(`a tok"fixture\\z b ${JSON.stringify('tok"fixture\\z').slice(1, -1)} c`, gh);
  assert.equal(s, 'a [redacted] b [redacted] c');
  assert.equal(scrubToken('x', { token: null }), 'x');
});

test('B13 the other exit paths: unparsed members, the log cap, a truncated log, bad JSON, no network', async (t) => {
  const routes = clone(FIXTURE.routes);
  routes[`${R}/pulls/901`] = { json: { ...routes[`${R}/pulls/900`].json, number: 901, title: 'queue', body: 'no metadata' } };
  routes[`${R}/pulls/902`] = { text: '{not json' };
  const runs = [];
  for (let i = 0; i < 12; i++) {
    runs.push(run(7000 + i, `shard ${i}`, 'failure'));
    routes[`${R}/actions/jobs/${7000 + i}/logs`] = { text: `FAIL: shard ${i}\n` };
  }
  setChecks(routes, runs);
  // Over 8 MiB: the start is dropped, the end (where the failure is) is kept.
  routes[`${R}/actions/jobs/7000/logs`] = { text: `FAIL: lost at the start\n${'x'.repeat(9 * 1024 * 1024)}\nFAIL: kept at the end\n` };
  const { call } = await withGithub(t, routes);
  const u = await call({ repo: 'acme/widgets', draft: 901 });
  assert.equal(u.isError, true);
  assert.equal(u.content[0].text, 'members_unparsed');
  const j = await call({ repo: 'acme/widgets', draft: 902 });
  assert.equal(j.content[0].text, 'bad_json');
  const o = ok(await call({ repo: 'acme/widgets', draft: 900 }));
  assert.equal(o.failed_checks.length, 12);
  assert.equal(o.failed_checks.filter((c) => c.lines_source === 'not_read_cap').length, 2);
  assert.ok(o.partial.includes('log shard 11: past the 10-log cap'), JSON.stringify(o.partial));
  const big = o.failed_checks.find((c) => c.name === 'shard 0');
  assert.equal(big.log_truncated, true);
  assert.deepEqual(big.lines, ['FAIL: kept at the end']);
  assert.ok(o.partial.includes('log shard 0: over 8 MiB, the start not read'));
  assert.equal(o.complete, false);
  assert.ok(o.prs.every((x) => x.culprit === null), 'an unread log leaves every PR unknown');

  const bad = await callTool(registry, 'batch_failure', { repo: 'acme/widgets', draft: 900 },
    { cfg: { url: 'http://console.invalid' }, github: { url: null, token: GH_TOKEN } });
  assert.equal(bad.content[0].text, 'github_url_invalid');
  const gone = await startGithub({});
  stubOrigin = gone.url;
  await gone.close();
  const n = await callTool(registry, 'batch_failure', { repo: 'acme/widgets', draft: 900 },
    { cfg: { url: 'http://console.invalid' }, github: { url: gone.url, token: GH_TOKEN } });
  assert.equal(n.content[0].text, 'github_network_error');
});

test('B16 every cap is a knob (BH-7945): env overrides, a bad value keeps the fallback', async (t) => {
  assert.deepEqual(bf.batchCaps({}), { page: 3, candidate: 5, log: 10, line: 40, lineLen: 500 });
  assert.deepEqual(bf.batchCaps({
    HARNESS_MCP_BATCH_PAGE_CAP: '7', HARNESS_MCP_BATCH_CANDIDATE_CAP: ' 2 ', HARNESS_MCP_BATCH_LOG_CAP: '25',
    HARNESS_MCP_BATCH_LINE_CAP: '0', HARNESS_MCP_BATCH_LINE_LEN: 'abc',
  }), { page: 7, candidate: 2, log: 25, line: 40, lineLen: 500 });
  assert.equal(githubConfig({ HARNESS_MCP_GITHUB_RAW_CAP: '1024' }).rawCap, 1024);
  assert.equal(githubConfig({ HARNESS_MCP_GITHUB_RAW_CAP: '-5' }).rawCap, 8 * 1024 * 1024);
  const few = bf.failureLines('FAIL: a1234\nFAIL: b1234\nFAIL: c1234\n', { ...bf.CAP_DEFAULTS, line: 2, lineLen: 4 });
  assert.deepEqual(few.lines, ['FAIL', 'FAIL']);
  assert.equal(few.lines_total, 3);

  // The tool reads the knobs: 3 failed logs with a log cap of 1 → 2 unread,
  // and a 64 KiB raw cap truncates a 100 KB log and names that cap.
  const routes = clone(FIXTURE.routes);
  const runs = [];
  for (let i = 0; i < 3; i++) {
    runs.push(run(7100 + i, `shard ${i}`, 'failure'));
    routes[`${R}/actions/jobs/${7100 + i}/logs`] = { text: `FAIL: shard ${i}\n` };
  }
  routes[`${R}/actions/jobs/7100/logs`] = { text: `FAIL: lost\n${'y'.repeat(100000)}\nFAIL: kept\n` };
  setChecks(routes, runs);
  const { ctx } = await withGithub(t, routes);
  ctx.github.rawCap = 64 * 1024;
  ctx.batchCaps = bf.batchCaps({ HARNESS_MCP_BATCH_LOG_CAP: '1' });
  const o = ok(await callTool(registry, 'batch_failure', { repo: 'acme/widgets', draft: 900 }, ctx));
  assert.equal(o.failed_checks.filter((c) => c.lines_source === 'not_read_cap').length, 2);
  assert.ok(o.partial.includes('log shard 2: past the 1-log cap'), JSON.stringify(o.partial));
  assert.ok(o.partial.includes('log shard 0: over 65536 bytes, the start not read'), JSON.stringify(o.partial));
  assert.deepEqual(o.failed_checks.find((c) => c.name === 'shard 0').lines, ['FAIL: kept']);
  assert.equal(o.complete, false);
});

test('B17 a pending or passed batch is live: no re-queue candidates', async (t) => {
  for (const [runs, state] of [[[run(7200, 'shard 0', null, 'in_progress')], 'pending'], [[run(7201, 'shard 0', 'success')], 'passed']]) {
    const routes = clone(FIXTURE.routes);
    setChecks(routes, runs);
    const { call } = await withGithub(t, routes);
    const o = ok(await call({ repo: 'acme/widgets', draft: 900 }));
    assert.equal(o.batch_state, state);
    assert.deepEqual(o.requeue_candidates, [], state);
  }
});

test('B14 a read log that names no changed file: every PR unknown, no candidate', async (t) => {
  const routes = clone(FIXTURE.routes);
  routes['/blob/job-5001.txt?sig=fixture-signed'] = { text: 'FAIL: C7 1 public file(s) name worker/cloud\n' };
  const { call } = await withGithub(t, routes);
  const o = ok(await call({ repo: 'acme/widgets', draft: 900 }));
  assert.equal(o.failed_checks[0].lines_source, 'error');
  assert.deepEqual(o.culprits, []);
  assert.equal(o.culprit_unknown, true);
  assert.ok(o.prs.every((x) => x.culprit === null), JSON.stringify(o.prs.map((x) => [x.pr, x.culprit])));
  assert.deepEqual(o.requeue_candidates, []);

  // Mixed: one check names #102, a second real failure names nothing. The
  // second one's cause is unseen, so the others stay unknown, not clean.
  const r2 = clone(FIXTURE.routes);
  const first = r2[`${R}/commits/${HEAD}/check-runs${P1}`].json.check_runs;
  setChecks(r2, [...first, run(5100, 'C7 public names', 'failure')]);
  r2[`${R}/actions/jobs/5100/logs`] = { text: 'FAIL: C7 1 public file(s) name worker/cloud\n' };
  const b = await withGithub(t, r2);
  const o2 = ok(await b.call({ repo: 'acme/widgets', draft: 900 }));
  assert.deepEqual(o2.culprits, [102]);
  assert.equal(pr(o2, 102).culprit, true);
  assert.ok(o2.prs.filter((x) => x.pr !== 102).every((x) => x.culprit === null), JSON.stringify(o2.prs));
  assert.deepEqual(o2.requeue_candidates, []);
});

test('B15 a non-log redirect keeps the token on the same origin; a cross-origin one is an error', async (t) => {
  const gh = await startGithub({
    '/repos/old/name/pulls/1': { status: 301, headers: { location: '{{origin}}/repos/new/name/pulls/1' } },
    '/repos/new/name/pulls/1': { json: { number: 1 } },
    '/repos/old/name/pulls/2': { status: 301, headers: { location: 'http://elsewhere.invalid/repos/new/name/pulls/2' } },
  });
  stubOrigin = gh.url;
  t.after(() => gh.close());
  const cfg = { url: gh.url, token: GH_TOKEN };
  const r = await githubFetch(cfg, '/repos/old/name/pulls/1');
  assert.equal(r.ok, true, JSON.stringify(r));
  assert.equal(r.data.number, 1);
  const moved = gh.requests.find((q) => q.path === '/repos/new/name/pulls/1');
  assert.equal(moved.authorization, `Bearer ${GH_TOKEN}`, 'a renamed private repo is still read with the token');
  const x = await githubFetch(cfg, '/repos/old/name/pulls/2');
  assert.deepEqual(x, { ok: false, status: 301, error: 'github_http_301' });
  assert.ok(!fetched.some((u) => u.includes('elsewhere.invalid')), 'the token never goes to another origin');
});

// ---- B12: the real server, end to end ----

function spawnServer(server, env) {
  const child = realSpawn(process.execPath, [server], { env: { PATH: process.env.PATH, ...env }, stdio: ['pipe', 'pipe', 'pipe'] });
  let stderr = '';
  child.stderr.on('data', (c) => { stderr += c; });
  const pending = new Map();
  createInterface({ input: child.stdout }).on('line', (line) => {
    const m = JSON.parse(line);
    pending.get(m.id)?.(m);
    pending.delete(m.id);
  });
  let id = 0;
  const rpc = (method, params) => new Promise((resolve) => {
    pending.set(++id, resolve);
    child.stdin.write(JSON.stringify({ jsonrpc: '2.0', id, method, params }) + '\n');
  });
  const exited = new Promise((r) => child.on('exit', r));
  return { rpc, stderr: () => stderr, end: async () => { child.stdin.end(); await exited; return stderr; }, kill: () => child.kill() };
}

const E2E_TOKEN = 'gh-tok-fixture-z';
function echoRoutes() {
  const routes = clone(FIXTURE.routes);
  routes[`${R}/pulls/900`].json.title = 'merge queue: {{auth}}';
  routes['/blob/job-5001.txt?sig=fixture-signed'].text += '##[error]echo {{auth}}\n';
  routes[`${R}/commits/${'a'.repeat(37)}101/check-runs${P1}`] = { status: 500, json: { message: 'boom {{auth}}' } };
  const runs = routes[`${R}/commits/${HEAD}/check-runs${P1}`].json.check_runs;
  runs.push({ ...run(5100, 'external lint', 'failure', 'completed', 'lint-app'), output: { title: 'lint failed', summary: 'FAIL: {{auth}} in bin/x.sh:3' } });
  return routes;
}

async function e2e(t, server) {
  const gh = await startGithub(echoRoutes());
  t.after(() => gh.close());
  const consoleStub = http.createServer((req, res) => { res.writeHead(404); res.end(); });
  await new Promise((r) => consoleStub.listen(0, '127.0.0.1', r));
  t.after(() => new Promise((r) => consoleStub.close(r)));
  const srv = spawnServer(server, {
    HARNESS_CONSOLE_URL: `http://127.0.0.1:${consoleStub.address().port}`,
    HARNESS_MCP_GITHUB_TOKEN: E2E_TOKEN, HARNESS_MCP_GITHUB_URL: gh.url,
  });
  t.after(() => srv.kill());
  const list = await srv.rpc('tools/list', {});
  const r = await srv.rpc('tools/call', { name: 'batch_failure', arguments: { repo: 'acme/widgets', draft: 900 } });
  const stderr = await srv.end();
  const seen = [JSON.stringify(r), ...(r.result?.content ?? []).map((c) => c.text), JSON.stringify(r.result?.structuredContent), stderr];
  return { gh, list, r, seen };
}

test('B12 end to end: listed read-only, reply parsed back, the GitHub token never returned', async (t) => {
  const { gh, list, r, seen } = await e2e(t, join(MCP_DIR, 'server.mjs'));
  const tool = list.result.tools.find((x) => x.name === 'batch_failure');
  assert.ok(tool, 'batch_failure is listed');
  assert.equal('confirm' in tool.inputSchema.properties, false);
  assert.equal(tool.inputSchema.additionalProperties, false);
  assert.deepEqual(tool.inputSchema.required, ['repo']);
  assert.equal(registry.get('batch_failure').kind, 'read');
  assert.equal(r.result.isError, undefined, JSON.stringify(r.result));
  const o = r.result.structuredContent;
  assert.deepEqual(o, JSON.parse(r.result.content[0].text));
  assert.deepEqual(o.culprits, [102]);
  assert.ok(o.partial.some((p) => p.startsWith('checks #101: github_http_500')), JSON.stringify(o.partial));
  assert.equal(pr(o, 101).head_ci, null);
  const ext = o.failed_checks.find((c) => c.name === 'external lint');
  assert.equal(ext.lines_source, 'summary');
  assert.ok(gh.requests.some((q) => q.authorization === `Bearer ${E2E_TOKEN}`), 'positive control: the stub saw the token');
  assert.ok(gh.requests.every((q) => q.method === 'GET'), 'the tool writes nothing');
  assert.ok(seen.join('\n').includes('[redacted]'), 'the echo reached the reply, scrubbed');
  for (const s of seen) assert.ok(!String(s).includes(E2E_TOKEN), `token leaked: ${s}`);
});

test('B12 mutation: without the scrubToken call the token leaks', async (t) => {
  const dir = mkdtempSync(join(tmpdir(), 'mcp-mut-'));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  cpSync(MCP_DIR, dir, { recursive: true });
  const file = join(dir, 'tools/batch-failure.mjs');
  const src = readFileSync(file, 'utf8');
  const anchor = 'scrubToken(JSON.stringify(value), gh)';
  assert.equal(src.split(anchor).length, 2, 'mutation anchor not found exactly once');
  writeFileSync(file, src.replace(anchor, 'JSON.stringify(value)'));
  const { seen } = await e2e(t, join(dir, 'server.mjs'));
  assert.ok(seen.some((s) => String(s).includes(E2E_TOKEN)), 'the leak check would see a broken scrub');
});
