// BH-7713: post_block and clear_block in mcp/tools/review-verdict.mjs.
// In-process cases go through the REAL registry (loadTools + callTool) with a
// fake seam (ctx.reviewVerdictSeam) that holds one PR's GitHub state and
// throws on any call it does not know. globalThis.fetch and
// node:child_process are wrapped with recorders BEFORE the tools load, so
// "0 network calls" is measured. R14/R15 spawn the real server on a copied
// tree with the REAL seam, a fake `gh` on PATH and a fake bin/lead-verdict.sh.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createRequire, syncBuiltinESMExports } from 'node:module';
import { chmodSync, copyFileSync, cpSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { createInterface } from 'node:readline';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

// ---- recorders, installed before any tool module is imported ----
const fetched = [];
globalThis.fetch = (input) => {
  fetched.push(String(input instanceof Request ? input.url : input));
  return Promise.reject(new Error('fetch blocked'));
};
const spawned = [];
const cp = createRequire(import.meta.url)('node:child_process');
const realSpawn = cp.spawn; // R14/R15 start the server with this, never the tools
for (const fn of ['spawn', 'exec', 'execFile', 'execSync', 'execFileSync', 'spawnSync', 'fork']) {
  cp[fn] = (...a) => { spawned.push(`${fn} ${String(a[0])}`); throw new Error(`child_process.${fn} blocked`); };
}
syncBuiltinESMExports();

const { loadTools, callTool } = await import('../lib/tools.mjs');

const HERE = dirname(fileURLToPath(import.meta.url));
const MCP_DIR = join(HERE, '..');
const FIXTURES = join(HERE, 'fixtures/review-verdict.bh-7713');
const registry = await loadTools(join(MCP_DIR, 'tools'));

const REPO = 'acme/widgets';
const PR = 7;
const SHA = 'a'.repeat(40);
const OLD = 'b'.repeat(40);
const FINDINGS = '[BLOCK wrong-data] the total is off by one.\n[NOTE] a copy nit.';
const P = `repos/${REPO}`;

// One PR's GitHub state behind the seam. Each call is recorded as
// {method, path, body} or {lv: argv}. Lists over PAGE items answer as
// concatenated pages, the way `gh api --paginate` prints them.
const PAGE = 3;
function fakeGitHub(o = {}) {
  const st = {
    head: o.head ?? SHA, labels: o.labels ?? [], comments: o.comments ?? [], reviews: o.reviews ?? [],
    login: o.login ?? 'rev-person', fail: o.fail ?? {}, lvRc: o.lvRc ?? 0, lvOut: o.lvOut ?? 'lead-verdict: recorded',
    fullName: o.fullName ?? REPO, nextId: 100,
  };
  const calls = [];
  const pages = (list) => {
    if (list.length <= PAGE) return JSON.stringify(list);
    let out = '';
    for (let i = 0; i < list.length; i += PAGE) out += JSON.stringify(list.slice(i, i + PAGE)) + '\n';
    return out;
  };
  const ok = (v) => ({ rc: 0, stdout: typeof v === 'string' ? v : JSON.stringify(v), stderr: '' });
  const seam = {
    async gh(args, input) {
      assert.equal(args[0], 'api');
      const mi = args.indexOf('--method');
      const method = mi >= 0 ? args[mi + 1] : 'GET';
      const rawPath = args.at(-1).split('?')[0];
      // GitHub answers a repo path in any case; the fake does too. rawPath
      // keeps the spelling the tool sent.
      const path = rawPath.replace(/^repos\/[^/]+\/[^/]+/, (m) => (m.toLowerCase() === P.toLowerCase() ? P : m));
      const body = input === undefined ? undefined : JSON.parse(input);
      calls.push({ method, path, rawPath, body, paginate: args.includes('--paginate') });
      const key = `${method} ${path}`;
      if (st.fail[key] !== undefined) return { rc: 1, stdout: '', stderr: st.fail[key] };
      if (key === `GET ${P}/pulls/${PR}`) return ok({ number: PR, head: { sha: st.head }, base: { repo: { full_name: st.fullName } }, labels: st.labels.map((name) => ({ name })) });
      if (key === `GET ${P}/issues/${PR}/comments`) return ok(pages(st.comments));
      if (key === `GET ${P}/pulls/${PR}/reviews`) return ok(pages(st.reviews));
      if (key === 'GET user') return ok({ login: st.login });
      if (key === `POST ${P}/issues/${PR}/comments`) {
        const id = st.nextId++;
        const c = { id, body: body.body, html_url: `https://github.com/${REPO}/pull/${PR}#issuecomment-${id}` };
        st.comments.push(c);
        return ok(c);
      }
      if (key === `POST ${P}/pulls/${PR}/reviews`) {
        const r = { id: st.nextId++, state: body.event === 'REQUEST_CHANGES' ? 'CHANGES_REQUESTED' : body.event, commit_id: body.commit_id, body: body.body, user: { login: st.login } };
        st.reviews.push(r);
        return ok(r);
      }
      if (key === `DELETE ${P}/issues/${PR}/labels/merge-queue`) {
        st.labels = st.labels.filter((l) => l !== 'merge-queue');
        return ok(st.labels.map((name) => ({ name })));
      }
      const dm = new RegExp(`^PUT ${P}/pulls/${PR}/reviews/(\\d+)/dismissals$`).exec(key);
      if (dm) {
        const r = st.reviews.find((x) => x.id === Number(dm[1]));
        if (!r) return { rc: 1, stdout: '', stderr: 'gh: Not Found (HTTP 404)' };
        r.state = 'DISMISSED';
        return ok(r);
      }
      throw new Error(`unimplemented: ${key}`);
    },
    async leadVerdict(args) {
      calls.push({ lv: args });
      return { rc: st.lvRc, stdout: st.lvOut, stderr: '' };
    },
  };
  return { st, calls, seam };
}

const cfgOf = (o = {}) => ({ url: 'http://192.0.2.1', token: null, secret: null, allowlist: [REPO], ...o });
async function call(name, args, gh, cfg = cfgOf()) {
  return callTool(registry, name, args, { cfg, log: () => {}, reviewVerdictSeam: gh.seam });
}
const isWrite = (c) => c.lv || c.method !== 'GET';
const writes = (gh) => gh.calls.filter(isWrite);
const label = (c) => (c.lv ? `LV ${c.lv.join(' ')}` : `${c.method} ${c.path}`);
const part = (r, name) => r.structuredContent.parts.find((p) => p.part === name);
const block = (o = {}) => ({ repo: REPO, pr: PR, head_sha: SHA, findings: FINDINGS, confirm: true, ...o });
const clear = (o = {}) => ({ repo: REPO, pr: PR, head_sha: SHA, verdict: 'MERGE-WITH-NOTES', note: 'fixed in the new head', confirm: true, ...o });

test('R1 post_block: the reads, then the comment, the REQUEST_CHANGES review and the BLOCK row, in order', async () => {
  const gh = fakeGitHub();
  const r = await call('post_block', block(), gh);
  assert.equal(r.isError, undefined, JSON.stringify(r));
  assert.deepEqual(gh.calls.map(label).slice(0, 1), [`GET ${P}/pulls/${PR}`]);
  assert.deepEqual(gh.calls.slice(1, 3).map(label).sort(), [`GET ${P}/issues/${PR}/comments`, `GET ${P}/pulls/${PR}/reviews`]);
  assert.ok(gh.calls.slice(1, 3).every((c) => c.paginate), 'the dedup reads paginate');
  const w = writes(gh);
  assert.deepEqual(w.map(label), [
    `POST ${P}/issues/${PR}/comments`,
    `POST ${P}/pulls/${PR}/reviews`,
    `LV post ${REPO} ${PR} ${SHA} BLOCK --source human --report-url ${gh.st.comments[0].html_url}`,
  ]);
  assert.equal(w[1].body.event, 'REQUEST_CHANGES');
  assert.equal(w[1].body.commit_id, SHA);
  const s = r.structuredContent;
  assert.equal(s.repo, REPO);
  assert.equal(s.pr, PR);
  assert.equal(s.head_sha, SHA);
  assert.equal(s.verdict, 'BLOCK');
  assert.deepEqual(s.parts.map((p) => [p.part, p.status]),
    [['comment', 'ok'], ['review', 'ok'], ['verdict', 'ok'], ['dequeue', 'not_needed']]);
  assert.equal(part(r, 'comment').url, gh.st.comments[0].html_url);
  assert.equal(part(r, 'verdict').rc, 0);
  assert.deepEqual(JSON.parse(r.content[0].text), s);
});

test('R2 the comment and the review bodies carry the findings verbatim and the marker', async () => {
  const gh = fakeGitHub();
  await call('post_block', block(), gh);
  const [c, rv] = writes(gh);
  for (const b of [c.body.body, rv.body.body]) {
    assert.ok(b.startsWith(FINDINGS + '\n\n'), b);
    assert.match(b, new RegExp(`<!-- review-verdict:block ${SHA} [0-9a-f]{12} -->$`));
  }
  assert.equal(c.body.body, rv.body.body);
});

test('R3 a stale head refuses with head_moved and 0 writes', async () => {
  for (const head of [OLD, 'c'.repeat(40)]) {
    const gh = fakeGitHub({ head });
    const r = await call('post_block', block(), gh);
    assert.equal(r.isError, true);
    assert.match(r.content[0].text, /^head_moved: the head is [bc]{12}, not a{12}/);
    assert.equal(writes(gh).length, 0, JSON.stringify(gh.calls));
    assert.equal(gh.calls.length, 1, 'only the pull read');
  }
  // The arg is the previous head.
  const gh = fakeGitHub({ head: SHA });
  const r = await call('post_block', block({ head_sha: OLD }), gh);
  assert.match(r.content[0].text, /^head_moved/);
  assert.equal(writes(gh).length, 0);
  // An unreadable head is a refusal too, never a write.
  const bad = fakeGitHub({ fail: { [`GET ${P}/pulls/${PR}`]: 'gh: Not Found (HTTP 404)' } });
  const u = await call('post_block', block(), bad);
  assert.equal(u.isError, true);
  assert.match(u.content[0].text, /^head_unreadable: gh: Not Found/);
  assert.equal(writes(bad).length, 0);
});

test('R4 without confirm: true, confirm_required and 0 seam calls (both tools)', async () => {
  for (const extra of [{ confirm: undefined }, { confirm: 'true' }, { confirm: 1 }, { confirm: false }]) {
    for (const [name, args] of [['post_block', block(extra)], ['clear_block', clear(extra)]]) {
      const gh = fakeGitHub();
      if (extra.confirm === undefined) delete args.confirm;
      const r = await call(name, args, gh);
      assert.equal(r.isError, true);
      assert.equal(r.content[0].text, 'confirm_required', `${name} ${JSON.stringify(extra)}`);
      assert.equal(gh.calls.length, 0);
    }
  }
});

test('R5 head_sha format: 39 chars / 41 chars / non-hex refuse; upper case of the head is accepted', async () => {
  for (const h of ['a'.repeat(39), 'a'.repeat(41), 'g'.repeat(40), SHA.slice(0, 12)]) {
    const gh = fakeGitHub();
    const r = await call('post_block', block({ head_sha: h }), gh);
    assert.equal(r.content[0].text, 'invalid_arguments: head_sha', h);
    assert.equal(gh.calls.length, 0);
  }
  const gh = fakeGitHub();
  const r = await call('post_block', block({ head_sha: SHA.toUpperCase() }), gh);
  assert.equal(r.isError, undefined, JSON.stringify(r));
  assert.equal(r.structuredContent.head_sha, SHA);
  assert.ok(writes(gh).find((c) => c.lv)?.lv.includes(SHA), 'the row carries the lowercased sha');
});

test('R6 a repo off the allowlist or a bad repo path refuses with 0 calls', async () => {
  const gh = fakeGitHub();
  const r = await call('post_block', block({ repo: 'other/repo' }), gh);
  assert.equal(r.content[0].text, 'repo_not_allowlisted');
  const e = await call('clear_block', clear(), gh, cfgOf({ allowlist: [] }));
  assert.equal(e.content[0].text, 'repo_not_allowlisted');
  for (const repo of ['a/b/c', 'a/..', 'a /b']) {
    const g = await call('post_block', block({ repo }), gh, cfgOf({ allowlist: [repo.toLowerCase()] }));
    assert.equal(g.content[0].text, 'invalid_arguments: repo', repo);
  }
  const f = await call('post_block', block({ findings: '' }), gh);
  assert.equal(f.content[0].text, 'invalid_arguments: findings');
  const v = await call('clear_block', clear({ verdict: 'BLOCK' }), gh);
  assert.equal(v.content[0].text, 'invalid_arguments: verdict');
  assert.equal(gh.calls.length, 0);
});

test('R7 the merge-queue label: after the row, DELETE the label then post the dequeue comment', async () => {
  const gh = fakeGitHub({ labels: ['bug', 'merge-queue'] });
  const r = await call('post_block', block(), gh);
  assert.equal(r.isError, undefined, JSON.stringify(r));
  assert.deepEqual(writes(gh).map(label).slice(2), [
    `LV post ${REPO} ${PR} ${SHA} BLOCK --source human --report-url ${gh.st.comments[0].html_url}`,
    `DELETE ${P}/issues/${PR}/labels/merge-queue`,
    `POST ${P}/issues/${PR}/comments`,
  ]);
  assert.equal(writes(gh).at(-1).body.body, '@mergifyio dequeue');
  assert.equal(part(r, 'dequeue').status, 'ok');
});

test('R7b no merge-queue label: dequeue not_needed, no DELETE', async () => {
  const gh = fakeGitHub({ labels: ['bug'] });
  const r = await call('post_block', block(), gh);
  assert.equal(part(r, 'dequeue').status, 'not_needed');
  assert.ok(!gh.calls.some((c) => c.method === 'DELETE'));
  assert.equal(writes(gh).filter((c) => c.method === 'POST').length, 2);
});

test('R8 a failed part is reported and the parts after it still run', async () => {
  const gh = fakeGitHub({ fail: { [`POST ${P}/issues/${PR}/comments`]: 'gh: Resource not accessible (HTTP 403)' } });
  const r = await call('post_block', block(), gh);
  assert.equal(r.isError, true);
  assert.equal(part(r, 'comment').status, 'failed');
  assert.match(part(r, 'comment').error, /HTTP 403/);
  assert.equal(part(r, 'review').status, 'ok');
  assert.equal(part(r, 'verdict').status, 'ok');
  const lv = writes(gh).find((c) => c.lv).lv;
  assert.ok(!lv.includes('--report-url'), 'no comment url, no --report-url');

  for (const [rc, status] of [[4, 'partial'], [5, 'partial'], [3, 'refused'], [1, 'failed'], [2, 'failed']]) {
    const g = fakeGitHub({ lvRc: rc, lvOut: `lead-verdict: rc ${rc}` });
    const x = await call('post_block', block(), g);
    assert.equal(x.isError, true, `rc ${rc}`);
    assert.equal(part(x, 'verdict').status, status, `rc ${rc}`);
    assert.equal(part(x, 'verdict').rc, rc);
    assert.match(part(x, 'verdict').output, new RegExp(`rc ${rc}`));
  }
  // The dedup reads fail: the writes still go, and the result says so.
  const d = fakeGitHub({ fail: { [`GET ${P}/issues/${PR}/comments`]: 'boom', [`GET ${P}/pulls/${PR}/reviews`]: 'boom' } });
  const y = await call('post_block', block(), d);
  assert.equal(part(y, 'comment').status, 'ok');
  assert.equal(part(y, 'comment').dedup_read, 'failed');
  assert.equal(part(y, 'review').dedup_read, 'failed');
  // A seam that throws is a failed part, not a crash: gh (ghRun) and
  // lead-verdict.sh (verdictRow) both.
  const th = fakeGitHub();
  const throwing = { gh: th.seam.gh, leadVerdict: async () => { throw new Error('lv exploded'); } };
  const tv = await callTool(registry, 'post_block', block(), { cfg: cfgOf(), log: () => {}, reviewVerdictSeam: throwing });
  assert.equal(part(tv, 'verdict').status, 'failed');
  assert.match(part(tv, 'verdict').error, /lv exploded/);
  assert.equal(tv.isError, true);
  const ghThrows = { gh: async () => { throw new Error('gh exploded'); }, leadVerdict: th.seam.leadVerdict };
  const tg = await callTool(registry, 'post_block', block(), { cfg: cfgOf(), log: () => {}, reviewVerdictSeam: ghThrows });
  assert.equal(tg.isError, true);
  assert.match(tg.content[0].text, /gh exploded/);
  // A DELETE that answers rc 1 is a failed part too.
  const t = fakeGitHub({ labels: ['merge-queue'], fail: { [`DELETE ${P}/issues/${PR}/labels/merge-queue`]: 'gh: Label does not exist (HTTP 404)' } });
  const z = await call('post_block', block(), t);
  assert.equal(part(z, 'dequeue').status, 'failed');
  assert.match(part(z, 'dequeue').error, /Label does not exist/);
  assert.equal(z.isError, true);
});

test('R9 a retry with the same head and findings posts no second comment or review; a new head posts', async () => {
  const gh = fakeGitHub();
  await call('post_block', block(), gh);
  const n = writes(gh).length;
  const again = await call('post_block', block(), gh);
  assert.equal(again.isError, undefined, JSON.stringify(again));
  assert.equal(part(again, 'comment').status, 'skipped');
  assert.equal(part(again, 'comment').url, gh.st.comments[0].html_url);
  assert.equal(part(again, 'review').status, 'skipped');
  const posts = writes(gh).slice(n).filter((c) => c.method === 'POST');
  assert.equal(posts.length, 0, JSON.stringify(posts));

  // Same findings, no marker: posts. Other findings on the same head: posts.
  const plain = fakeGitHub({ comments: [{ id: 1, body: FINDINGS, html_url: 'https://github.com/acme/widgets/pull/7#issuecomment-1' }] });
  const p = await call('post_block', block(), plain);
  assert.equal(part(p, 'comment').status, 'ok');
  const other = await call('post_block', block({ findings: 'another finding' }), gh);
  assert.equal(part(other, 'comment').status, 'ok');
  assert.equal(part(other, 'review').status, 'ok');

  // A new head: the marker carries the head, so the block posts again.
  gh.st.head = 'c'.repeat(40);
  const next = await call('post_block', block({ head_sha: 'c'.repeat(40) }), gh);
  assert.equal(part(next, 'comment').status, 'ok');
  assert.equal(part(next, 'review').status, 'ok');
});

test('R10 clear_block: the row on the new head, then dismiss only the caller\'s CHANGES_REQUESTED', async () => {
  const gh = fakeGitHub({
    login: 'rev-person',
    reviews: [
      { id: 1, state: 'CHANGES_REQUESTED', commit_id: SHA, user: { login: 'rev-person' } },
      { id: 2, state: 'CHANGES_REQUESTED', commit_id: OLD, user: { login: 'rev-person' } },
      { id: 3, state: 'CHANGES_REQUESTED', commit_id: SHA, user: { login: 'Other' } },
      { id: 4, state: 'APPROVED', commit_id: SHA, user: { login: 'rev-person' } },
      { id: 5, state: 'DISMISSED', commit_id: OLD, user: { login: 'rev-person' } },
      { id: 6, state: 'CHANGES_REQUESTED', commit_id: OLD, user: { login: 'REV-Person' } },
      { id: 7, state: 'COMMENTED', commit_id: SHA, user: { login: 'rev-person' } },
      { id: 8, state: 'CHANGES_REQUESTED', commit_id: SHA, user: { login: 'another-one' } },
    ],
  });
  const r = await call('clear_block', clear(), gh);
  assert.equal(r.isError, undefined, JSON.stringify(r));
  const w = writes(gh);
  assert.deepEqual(w[0].lv, ['post', REPO, String(PR), SHA, 'MERGE-WITH-NOTES', '--source', 'human', '--note', 'fixed in the new head']);
  const puts = w.filter((c) => c.method === 'PUT');
  assert.deepEqual(puts.map((c) => c.path), [1, 2, 6].map((id) => `${P}/pulls/${PR}/reviews/${id}/dismissals`));
  for (const c of puts) assert.deepEqual(c.body, { event: 'DISMISS', message: `Cleared by MERGE-WITH-NOTES on ${SHA.slice(0, 12)}.` });
  assert.deepEqual(r.structuredContent.parts.map((p) => [p.part, p.status]), [['verdict', 'ok'], ['dismiss', 'ok']]);
  assert.deepEqual(part(r, 'dismiss').dismissed, [1, 2, 6]);
  assert.equal(r.structuredContent.verdict, 'MERGE-WITH-NOTES');
  const stateOf = (id) => gh.st.reviews.find((x) => x.id === id).state;
  assert.deepEqual([3, 4, 7, 8].map(stateOf), ['CHANGES_REQUESTED', 'APPROVED', 'COMMENTED', 'CHANGES_REQUESTED']);

  // MERGE with no note, and nothing to dismiss.
  const m = fakeGitHub({ reviews: [{ id: 9, state: 'CHANGES_REQUESTED', commit_id: SHA, user: { login: 'Other' } }] });
  const x = await call('clear_block', clear({ verdict: 'MERGE', note: undefined }), m);
  assert.deepEqual(writes(m)[0].lv, ['post', REPO, String(PR), SHA, 'MERGE', '--source', 'human']);
  assert.equal(part(x, 'dismiss').status, 'not_needed');
  assert.ok(!m.calls.some((c) => c.method === 'PUT'));
});

test('R11 clear_block: a failed row skips the dismiss; a failed PUT names its id', async () => {
  const reviews = () => [
    { id: 1, state: 'CHANGES_REQUESTED', commit_id: SHA, user: { login: 'rev-person' } },
    { id: 2, state: 'CHANGES_REQUESTED', commit_id: OLD, user: { login: 'rev-person' } },
  ];
  for (const rc of [1, 3, 4, 5]) {
    const gh = fakeGitHub({ lvRc: rc, reviews: reviews() });
    const r = await call('clear_block', clear(), gh);
    assert.equal(r.isError, true, `rc ${rc}`);
    assert.notEqual(part(r, 'verdict').status, 'ok');
    assert.equal(part(r, 'dismiss').status, 'skipped');
    assert.ok(!gh.calls.some((c) => c.method === 'PUT' || c.path === 'user'), `rc ${rc}: no dismiss read or PUT`);
  }
  const gh = fakeGitHub({ reviews: reviews(), fail: { [`PUT ${P}/pulls/${PR}/reviews/1/dismissals`]: 'gh: Validation Failed (HTTP 422)' } });
  const r = await call('clear_block', clear(), gh);
  assert.equal(r.isError, true);
  const d = part(r, 'dismiss');
  assert.equal(d.status, 'failed');
  assert.deepEqual(d.dismissed, [2]);
  assert.equal(d.failed.length, 1);
  assert.equal(d.failed[0].id, 1);
  assert.match(d.failed[0].error, /HTTP 422/);

  // A failed user read: failed, 0 PUTs.
  const u = fakeGitHub({ reviews: reviews(), fail: { 'GET user': 'gh: Bad credentials (HTTP 401)' } });
  const ur = await call('clear_block', clear(), u);
  assert.equal(part(ur, 'dismiss').status, 'failed');
  assert.ok(!u.calls.some((c) => c.method === 'PUT'));
});

test('R12 clear_block: a stale head writes nothing; no confirm calls nothing', async () => {
  const gh = fakeGitHub({ head: OLD, reviews: [{ id: 1, state: 'CHANGES_REQUESTED', commit_id: OLD, user: { login: 'rev-person' } }] });
  const r = await call('clear_block', clear(), gh);
  assert.equal(r.isError, true);
  assert.match(r.content[0].text, /^head_moved/);
  assert.equal(writes(gh).length, 0);
  const n = fakeGitHub();
  const x = await call('clear_block', clear({ confirm: false }), n);
  assert.equal(x.content[0].text, 'confirm_required');
  assert.equal(n.calls.length, 0);
});

test('R13 no token or secret leaves the tool, in text or structuredContent', async () => {
  const TOKEN = 'tok-fixture-rv-x';
  const SECRET = 'sec-fixture-rv-x';
  const cfg = cfgOf({ token: TOKEN, secret: SECRET });
  const leak = `auth ${TOKEN} and /login/${SECRET} and ${encodeURIComponent(SECRET)}`;
  const outs = [];
  const keep = (r) => outs.push(JSON.stringify(r));
  const gh = fakeGitHub({
    labels: ['merge-queue'], lvRc: 1, lvOut: leak,
    fail: {
      [`POST ${P}/issues/${PR}/comments`]: leak,
      [`POST ${P}/pulls/${PR}/reviews`]: leak,
      [`DELETE ${P}/issues/${PR}/labels/merge-queue`]: leak,
    },
  });
  keep(await call('post_block', block(), gh, cfg));
  keep(await call('clear_block', clear(), gh, cfg));
  const c2 = fakeGitHub({ reviews: [{ id: 1, state: 'CHANGES_REQUESTED', commit_id: SHA, user: { login: 'rev-person' } }], fail: { [`PUT ${P}/pulls/${PR}/reviews/1/dismissals`]: leak } });
  keep(await call('clear_block', clear(), c2, cfg));
  keep(await call('post_block', block(), fakeGitHub({ fail: { [`GET ${P}/pulls/${PR}`]: leak } }), cfg));
  const all = outs.join('\n');
  assert.ok(all.includes('[redacted]'), 'the leak text did reach the result, redacted');
  for (const v of [TOKEN, SECRET]) assert.ok(!all.includes(v), `${v} leaked: ${all}`);
  // Each text is capped.
  for (const o of outs) {
    for (const p of JSON.parse(o).structuredContent?.parts ?? []) {
      for (const f of ['error', 'output']) if (p[f]) assert.ok(p[f].length <= 300, `${f} not capped`);
    }
  }
});

// ---- end to end: the real server, the real seam, a fake gh and a fake lead-verdict ----
function tree(t) {
  const root = mkdtempSync(join(tmpdir(), 'mcp-rv-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  cpSync(MCP_DIR, join(root, 'mcp'), { recursive: true });
  mkdirSync(join(root, 'bin'));
  copyFileSync(join(FIXTURES, 'fake-lead-verdict.sh'), join(root, 'bin/lead-verdict.sh'));
  chmodSync(join(root, 'bin/lead-verdict.sh'), 0o755);
  mkdirSync(join(root, 'fakebin'));
  writeFileSync(join(root, 'fakebin/gh'), `#!/bin/sh\nexec "${process.execPath}" "${join(FIXTURES, 'fake-gh.mjs')}" "$@"\n`);
  chmodSync(join(root, 'fakebin/gh'), 0o755);
  return root;
}

function server(t, root, env) {
  const child = realSpawn(process.execPath, [join(root, 'mcp/server.mjs')], {
    env: { PATH: `${join(root, 'fakebin')}:/usr/bin:/bin`, HARNESS_CONSOLE_URL: 'http://192.0.2.1:9', ...env },
    stdio: ['pipe', 'pipe', 'pipe'],
  });
  t.after(() => child.kill());
  const pending = new Map();
  createInterface({ input: child.stdout }).on('line', (line) => {
    const m = JSON.parse(line);
    pending.get(m.id)?.(m);
    pending.delete(m.id);
  });
  let id = 0;
  return (method, params) => new Promise((resolve) => {
    const mid = ++id;
    pending.set(mid, resolve);
    child.stdin.write(JSON.stringify({ jsonrpc: '2.0', id: mid, method, params }) + '\n');
  });
}

test('R14 end to end: tools/list, then post_block through the real seam, in order', async (t) => {
  const root = tree(t);
  const LOG = join(root, 'calls.log');
  const rpc = server(t, root, { HARNESS_MCP_REPO_ALLOWLIST: REPO, FAKE_LOG: LOG, FAKE_GH_HEAD: SHA });
  await rpc('initialize', { protocolVersion: '2025-11-25' });
  const list = (await rpc('tools/list', {})).result.tools;
  for (const n of ['post_block', 'clear_block']) {
    const tl = list.find((x) => x.name === n);
    assert.ok(tl, `missing ${n}`);
    assert.ok(tl.inputSchema.required.includes('confirm'));
    assert.equal(tl.inputSchema.additionalProperties, false);
  }
  const r = (await rpc('tools/call', { name: 'post_block', arguments: block() })).result;
  assert.equal(r.isError, undefined, JSON.stringify(r));
  assert.deepEqual(r.structuredContent.parts.map((p) => [p.part, p.status]),
    [['comment', 'ok'], ['review', 'ok'], ['verdict', 'ok'], ['dequeue', 'not_needed']]);
  const lines = readFileSync(LOG, 'utf8').trim().split('\n').map((l) => JSON.parse(l));
  const shown = lines.map((l) => (l.lv ? `LV ${l.lv.join(' ')}` : `${l.method} ${l.path}`));
  assert.equal(shown[0], `GET ${P}/pulls/${PR}`);
  assert.deepEqual(shown.slice(1, 3).sort(), [`GET ${P}/issues/${PR}/comments?per_page=100`, `GET ${P}/pulls/${PR}/reviews?per_page=100`]);
  assert.deepEqual(shown.slice(3), [
    `POST ${P}/issues/${PR}/comments`,
    `POST ${P}/pulls/${PR}/reviews`,
    `LV post ${REPO} ${PR} ${SHA} BLOCK --source human --report-url https://github.com/${REPO}/pull/${PR}#issuecomment-1`,
  ]);
  assert.equal(lines[4].input.event, 'REQUEST_CHANGES');
  assert.equal(lines[4].input.commit_id, SHA);
  assert.ok(lines[3].input.body.startsWith(FINDINGS));

  // A stale head through the real seam: 1 read, 0 writes.
  rmSync(LOG);
  const s = (await rpc('tools/call', { name: 'post_block', arguments: block({ head_sha: OLD }) })).result;
  assert.match(s.content[0].text, /^head_moved/);
  assert.equal(readFileSync(LOG, 'utf8').trim().split('\n').length, 1);
});

test('R15 end to end without confirm: confirm_required, the fake gh never runs', async (t) => {
  const root = tree(t);
  const LOG = join(root, 'calls.log');
  const rpc = server(t, root, { HARNESS_MCP_REPO_ALLOWLIST: REPO, FAKE_LOG: LOG, FAKE_GH_HEAD: SHA });
  await rpc('initialize', { protocolVersion: '2025-11-25' });
  const args = block();
  delete args.confirm;
  for (const [name, a] of [['post_block', args], ['clear_block', { ...clear(), confirm: 'true' }]]) {
    const r = (await rpc('tools/call', { name, arguments: a })).result;
    assert.equal(r.isError, true);
    assert.equal(r.content[0].text, 'confirm_required');
  }
  assert.equal(existsSync(LOG), false);
});

test('R17 the repo name GitHub returns is the one written: gh paths, the verdict row and the result (both tools)', async () => {
  const CANON = 'Acme/Widgets';
  for (const typed of ['acme/widgets', 'ACME/WIDGETS']) {
    const gh = fakeGitHub({ fullName: CANON, labels: ['merge-queue'] });
    const r = await call('post_block', block({ repo: typed }), gh);
    assert.equal(r.isError, undefined, JSON.stringify(r));
    assert.equal(r.structuredContent.repo, CANON);
    const lv = gh.calls.find((c) => c.lv);
    assert.equal(lv.lv[1], CANON, 'the BLOCK row is keyed on GitHub\'s spelling');
    for (const c of gh.calls.slice(1).filter((x) => !x.lv)) assert.ok(c.rawPath.startsWith(`repos/${CANON}/`), c.rawPath);

    const g2 = fakeGitHub({ fullName: CANON });
    const c2 = await call('clear_block', clear({ repo: typed }), g2);
    assert.equal(c2.isError, undefined, JSON.stringify(c2));
    assert.equal(c2.structuredContent.repo, CANON);
    assert.equal(g2.calls.find((c) => c.lv).lv[1], CANON, 'the MERGE row is keyed on GitHub\'s spelling');
    for (const c of g2.calls.slice(1).filter((x) => !x.lv && x.path !== 'user')) assert.ok(c.rawPath.startsWith(`repos/${CANON}/`), c.rawPath);
  }
  // An answer that names another repo, or no repo, refuses with 0 writes.
  for (const [fullName, re] of [['acme/other', /^repo_mismatch: GitHub names the repo acme\/other/], ['', /^head_unreadable: no base repo name/]]) {
    for (const tool of ['post_block', 'clear_block']) {
      const gh = fakeGitHub({ fullName });
      const r = await call(tool, tool === 'post_block' ? block() : clear(), gh);
      assert.equal(r.isError, true);
      assert.match(r.content[0].text, re);
      assert.equal(writes(gh).length, 0, JSON.stringify(gh.calls));
    }
  }
});

test('R18 the timeouts and the text cap are knobs; the literals are only the fallback', async () => {
  const { VERDICT_DEFAULTS, verdictKnobs } = await import('../tools/review-verdict.mjs');
  assert.deepEqual(verdictKnobs({}), { ghTimeoutMs: 60_000, lvTimeoutMs: 90_000, textCap: 300 });
  assert.deepEqual(verdictKnobs({}), { ...VERDICT_DEFAULTS });
  assert.deepEqual(
    verdictKnobs({ HARNESS_MCP_GH_TIMEOUT_MS: '5000', HARNESS_MCP_LV_TIMEOUT_MS: ' 7000 ', HARNESS_MCP_TEXT_CAP: '12' }),
    { ghTimeoutMs: 5000, lvTimeoutMs: 7000, textCap: 12 },
  );
  assert.deepEqual(
    verdictKnobs({ HARNESS_MCP_GH_TIMEOUT_MS: '0', HARNESS_MCP_LV_TIMEOUT_MS: 'abc', HARNESS_MCP_TEXT_CAP: '-4' }),
    { ...VERDICT_DEFAULTS },
  );
  // The text cap is read per call: a set knob cuts the part output.
  const prev = process.env.HARNESS_MCP_TEXT_CAP;
  process.env.HARNESS_MCP_TEXT_CAP = '10';
  try {
    const g = fakeGitHub({ lvRc: 1, lvOut: 'x'.repeat(50) + 'END-OF-OUT' });
    const r = await call('post_block', block(), g);
    assert.equal(part(r, 'verdict').output, 'END-OF-OUT');
  } finally {
    if (prev === undefined) delete process.env.HARNESS_MCP_TEXT_CAP;
    else process.env.HARNESS_MCP_TEXT_CAP = prev;
  }
});

test('R16 budget: the in-process cases made 0 fetches and 0 child_process calls', async () => {
  // Run both tools here too, so the case proves something when run alone.
  const gh = fakeGitHub({ labels: ['merge-queue'], reviews: [{ id: 9, state: 'CHANGES_REQUESTED', commit_id: OLD, user: { login: 'rev-person' } }] });
  assert.ok(!(await call('post_block', block(), gh)).isError);
  assert.ok(!(await call('clear_block', clear(), gh)).isError);
  assert.ok(gh.calls.length > 0);
  assert.deepEqual(fetched, []);
  assert.deepEqual(spawned, []);
});
