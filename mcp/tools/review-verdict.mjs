// Review verdict tools: post_block and clear_block. A person's BLOCK takes
// three writes to reach every merge lane and the fix-round lane: a PR comment
// with the findings, a REQUEST_CHANGES review on the head, and a human BLOCK
// verdict row. clear_block records the new verdict row and dismisses the
// caller's own standing CHANGES_REQUESTED reviews.
//
// These two tools do NOT go through the console. They run on the MCP host:
// `gh api` as the host's gh login, and bin/lead-verdict.sh from the checkout
// this server runs from, because the human verdict token lives on that host.
// The seam below is the only code that starts either one. Both tools refuse,
// with 0 calls, unless confirm is the boolean true and the repo is on
// HARNESS_MCP_REPO_ALLOWLIST (empty by default).
import { spawn } from 'node:child_process';
import { createHash } from 'node:crypto';
import { existsSync } from 'node:fs';
import { dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { redact } from '../lib/console.mjs';
import { intKnob } from '../lib/github.mjs';
import { checkArgs } from './lib/schema.mjs';

// Limits are knobs (BH-7945): each is read per call from the MCP host's
// environment, and the number here is only the documented fallback when the
// knob is unset or not a positive integer.
export const VERDICT_DEFAULTS = Object.freeze({
  ghTimeoutMs: 60_000, // HARNESS_MCP_GH_TIMEOUT_MS: one `gh api` call
  lvTimeoutMs: 90_000, // HARNESS_MCP_LV_TIMEOUT_MS: one bin/lead-verdict.sh run
  textCap: 300, // HARNESS_MCP_TEXT_CAP: chars of child output kept in a part
});
export const verdictKnobs = (env) => ({
  ghTimeoutMs: intKnob(env, 'HARNESS_MCP_GH_TIMEOUT_MS', VERDICT_DEFAULTS.ghTimeoutMs),
  lvTimeoutMs: intKnob(env, 'HARNESS_MCP_LV_TIMEOUT_MS', VERDICT_DEFAULTS.lvTimeoutMs),
  textCap: intKnob(env, 'HARNESS_MCP_TEXT_CAP', VERDICT_DEFAULTS.textCap),
});
const QUEUE_LABEL = 'merge-queue';
const LEAD_VERDICT = fileURLToPath(new URL('../../bin/lead-verdict.sh', import.meta.url));

// One child process. → {rc, stdout, stderr} or {rc: null, error}; never throws.
function run(cmd, args, { input, timeout, cwd, name }) {
  return new Promise((resolve) => {
    let child;
    try {
      child = spawn(cmd, args, { cwd, timeout, stdio: ['pipe', 'pipe', 'pipe'] });
    } catch (err) {
      return resolve({ rc: null, error: err?.message ?? String(err) });
    }
    let stdout = '';
    let stderr = '';
    child.stdout.on('data', (c) => { stdout += c; });
    child.stderr.on('data', (c) => { stderr += c; });
    child.on('error', (err) => resolve({ rc: null, error: err?.code === 'ENOENT' ? `${name} not found` : (err?.message ?? String(err)), stdout, stderr }));
    child.on('close', (code, signal) => {
      if (code !== null) return resolve({ rc: code, stdout, stderr });
      resolve({ rc: null, error: signal === 'SIGTERM' ? `${name} timed out after ${timeout / 1000}s` : `${name} killed by ${signal}`, stdout, stderr });
    });
    child.stdin.on('error', () => {});
    child.stdin.end(input ?? '');
  });
}

// The real seam. Tests pass ctx.reviewVerdictSeam instead.
export const reviewVerdictSeam = {
  gh: (args, input) => run('gh', args, { input, timeout: verdictKnobs(process.env).ghTimeoutMs, name: 'gh' }),
  leadVerdict: (args) => {
    if (!existsSync(LEAD_VERDICT)) return { rc: null, error: 'bin/lead-verdict.sh not found' };
    return run(LEAD_VERDICT, args, { timeout: verdictKnobs(process.env).lvTimeoutMs, cwd: dirname(dirname(LEAD_VERDICT)), name: 'bin/lead-verdict.sh' });
  },
};
const seamOf = (ctx) => ctx.reviewVerdictSeam ?? reviewVerdictSeam;

// Redact first, then cut, so a cut never leaves part of a secret.
const textCap = () => verdictKnobs(process.env).textCap;
const head = (ctx, s) => redact(String(s), ctx.cfg).slice(0, textCap());
const tail = (ctx, s) => redact(String(s), ctx.cfg).slice(-textCap());
const isPlain = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);

// Every top-level JSON value in text: `gh api --paginate` prints one array
// per page, back to back.
function parseAll(text) {
  const out = [];
  let depth = 0, start = -1, inStr = false, esc = false;
  for (let i = 0; i < text.length; i++) {
    const ch = text[i];
    if (inStr) {
      if (esc) esc = false;
      else if (ch === '\\') esc = true;
      else if (ch === '"') inStr = false;
      continue;
    }
    if (depth === 0 && ch !== '[' && ch !== '{') {
      if (/\s/.test(ch)) continue;
      throw new Error('bad_json');
    }
    if (ch === '"') inStr = true;
    else if (ch === '[' || ch === '{') { if (depth++ === 0) start = i; }
    else if (ch === ']' || ch === '}') { if (--depth === 0) out.push(JSON.parse(text.slice(start, i + 1))); }
  }
  if (depth !== 0 || inStr) throw new Error('bad_json');
  return out;
}

// One `gh api` call. → {ok, data} or {ok: false, error}.
async function gh(ctx, method, path, body) {
  const args = ['api', '--method', method, ...(body === undefined ? [] : ['--input', '-']), path];
  return ghRun(ctx, args, body === undefined ? undefined : JSON.stringify(body), (t) => JSON.parse(t));
}

// A GET of a list, every page. → {ok, data: [...]} or {ok: false, error}.
async function ghList(ctx, path) {
  return ghRun(ctx, ['api', '--method', 'GET', '--paginate', `${path}?per_page=100`], undefined, (t) => {
    const pages = parseAll(t);
    if (!pages.every(Array.isArray)) throw new Error('bad_json');
    return pages.flat();
  });
}

async function ghRun(ctx, args, input, parse) {
  let r;
  try {
    r = await seamOf(ctx).gh(args, input);
  } catch (err) {
    return { ok: false, error: head(ctx, err?.message ?? err) };
  }
  if (r?.rc !== 0) {
    const why = r?.error ?? (String(r?.stderr ?? '').trim() || `gh exit ${r?.rc}`);
    return { ok: false, error: head(ctx, why) };
  }
  try {
    return { ok: true, data: parse(String(r.stdout ?? '')) };
  } catch {
    return { ok: false, error: 'bad_json from gh' };
  }
}

// A POST that must answer a created object with an id.
async function create(ctx, path, body) {
  const r = await gh(ctx, 'POST', path, body);
  if (!r.ok) return r;
  if (!isPlain(r.data) || r.data.id === undefined || r.data.id === null) return { ok: false, error: 'no id in the answer' };
  return r;
}

// bin/lead-verdict.sh post ... as one part. rc 0 ok; 4 and 5 the row was
// recorded but its status was not published (partial); 3 the head moved
// (refused, nothing written); anything else failed.
async function verdictRow(ctx, argv) {
  let r;
  try {
    r = await seamOf(ctx).leadVerdict(argv);
  } catch (err) {
    return { part: 'verdict', status: 'failed', error: head(ctx, err?.message ?? err) };
  }
  if (!Number.isInteger(r?.rc)) return { part: 'verdict', status: 'failed', error: head(ctx, r?.error ?? 'no exit code') };
  const status = r.rc === 0 ? 'ok' : r.rc === 4 || r.rc === 5 ? 'partial' : r.rc === 3 ? 'refused' : 'failed';
  return { part: 'verdict', status, rc: r.rc, output: tail(ctx, `${r.stdout ?? ''}${r.stderr ?? ''}`.trim()) };
}

// The redacted text is the one source: structuredContent is parsed back from it.
function reply(ctx, value, isError) {
  const text = redact(JSON.stringify(value), ctx.cfg);
  return { content: [{ type: 'text', text }], structuredContent: JSON.parse(text), ...(isError ? { isError: true } : {}) };
}
const fail = (t) => ({ content: [{ type: 'text', text: t }], isError: true });
const BAD = new Set(['failed', 'partial', 'refused']);
const result = (ctx, repo, a, sha, verdict, parts) =>
  reply(ctx, { repo, pr: a.pr, head_sha: sha, verdict, parts }, parts.some((p) => BAD.has(p.status)));

// Step 0 for both tools: the head must be head_sha. → {pull, repo} or {refusal}.
// GitHub matches a repo path with any case, but the verdicts table matches
// repo exactly (worker/jobs/src/routes/verdicts.js). So every later gh path,
// the lead-verdict argv and the result use GitHub's own spelling,
// pull.base.repo.full_name, never the string the caller typed.
async function readHead(ctx, typed, pr, sha) {
  const r = await gh(ctx, 'GET', `repos/${typed}/pulls/${pr}`);
  if (!r.ok) return { refusal: fail(`head_unreadable: ${r.error}`) };
  const repo = typeof r.data?.base?.repo?.full_name === 'string' ? r.data.base.repo.full_name : '';
  if (!REPO_RE.test(repo)) return { refusal: fail('head_unreadable: no base repo name in the answer') };
  if (repo.toLowerCase() !== typed.toLowerCase()) return { refusal: fail(`repo_mismatch: GitHub names the repo ${repo}, not ${typed}`) };
  const live = typeof r.data?.head?.sha === 'string' ? r.data.head.sha.toLowerCase() : '';
  if (!/^[0-9a-f]{40}$/.test(live)) return { refusal: fail('head_unreadable: no head sha in the answer') };
  if (live !== sha) return { refusal: fail(`head_moved: the head is ${live.slice(0, 12)}, not ${sha.slice(0, 12)}`) };
  return { pull: r.data, repo };
}

export const marker = (sha, findings) =>
  `<!-- review-verdict:block ${sha} ${createHash('sha256').update(findings).digest('hex').slice(0, 12)} -->`;

async function postBlock(a, ctx) {
  const sha = a.head_sha.toLowerCase();
  const h = await readHead(ctx, a.repo.trim(), a.pr, sha);
  if (h.refusal) return h.refusal;
  const repo = h.repo;
  const base = `repos/${repo}`;

  const mark = marker(sha, a.findings);
  const body = `${a.findings}\n\n${mark}`;
  const [comments, reviews] = await Promise.all([
    ghList(ctx, `${base}/issues/${a.pr}/comments`),
    ghList(ctx, `${base}/pulls/${a.pr}/reviews`),
  ]);
  const parts = [];

  // A failed dedup read never skips a write; the part says it posted blind.
  const seenComment = comments.ok ? comments.data.find((c) => typeof c?.body === 'string' && c.body.includes(mark)) : null;
  let commentUrl = null;
  if (seenComment) {
    commentUrl = seenComment.html_url ?? null;
    parts.push({ part: 'comment', status: 'skipped', reason: 'already posted', url: commentUrl });
  } else {
    const c = await create(ctx, `${base}/issues/${a.pr}/comments`, { body });
    if (c.ok) commentUrl = c.data.html_url ?? null;
    parts.push({ part: 'comment', ...(c.ok ? { status: 'ok', id: c.data.id, url: commentUrl } : { status: 'failed', error: c.error }), ...(comments.ok ? {} : { dedup_read: 'failed' }) });
  }

  const seenReview = reviews.ok ? reviews.data.find((r) =>
    String(r?.commit_id ?? '').toLowerCase() === sha && r?.state === 'CHANGES_REQUESTED' &&
    typeof r?.body === 'string' && r.body.includes(mark)) : null;
  if (seenReview) {
    parts.push({ part: 'review', status: 'skipped', reason: 'already posted', id: seenReview.id });
  } else {
    const r = await create(ctx, `${base}/pulls/${a.pr}/reviews`, { event: 'REQUEST_CHANGES', commit_id: sha, body });
    parts.push({ part: 'review', ...(r.ok ? { status: 'ok', id: r.data.id } : { status: 'failed', error: r.error }), ...(reviews.ok ? {} : { dedup_read: 'failed' }) });
  }

  const argv = ['post', repo, String(a.pr), sha, 'BLOCK', '--source', 'human'];
  if (typeof commentUrl === 'string' && commentUrl.startsWith('https://')) argv.push('--report-url', commentUrl);
  parts.push(await verdictRow(ctx, argv));

  const labels = Array.isArray(h.pull.labels) ? h.pull.labels.map((l) => l?.name) : [];
  if (!labels.includes(QUEUE_LABEL)) {
    parts.push({ part: 'dequeue', status: 'not_needed' });
  } else {
    const del = await gh(ctx, 'DELETE', `${base}/issues/${a.pr}/labels/${QUEUE_LABEL}`);
    const deq = await create(ctx, `${base}/issues/${a.pr}/comments`, { body: '@mergifyio dequeue' });
    const p = { part: 'dequeue', status: del.ok && deq.ok ? 'ok' : 'failed', label: del.ok ? 'removed' : 'failed', comment: deq.ok ? 'posted' : 'failed' };
    if (!del.ok || !deq.ok) p.error = (del.ok ? deq : del).error;
    parts.push(p);
  }
  return result(ctx, repo, a, sha, 'BLOCK', parts);
}

async function clearBlock(a, ctx) {
  const sha = a.head_sha.toLowerCase();
  const h = await readHead(ctx, a.repo.trim(), a.pr, sha);
  if (h.refusal) return h.refusal;
  const repo = h.repo;
  const base = `repos/${repo}`;

  const argv = ['post', repo, String(a.pr), sha, a.verdict, '--source', 'human'];
  if (a.note !== undefined) argv.push('--note', a.note);
  const v = await verdictRow(ctx, argv);
  const parts = [v];
  // A CHANGES_REQUESTED is never lifted while its replacement row did not land.
  if (v.status !== 'ok') {
    parts.push({ part: 'dismiss', status: 'skipped', reason: 'verdict row not recorded' });
    return result(ctx, repo, a, sha, a.verdict, parts);
  }
  const [user, reviews] = await Promise.all([gh(ctx, 'GET', 'user'), ghList(ctx, `${base}/pulls/${a.pr}/reviews`)]);
  const login = typeof user.data?.login === 'string' ? user.data.login.trim().toLowerCase() : '';
  if (!user.ok || login === '') {
    parts.push({ part: 'dismiss', status: 'failed', error: user.ok ? 'no login in the user answer' : `user read: ${user.error}` });
    return result(ctx, repo, a, sha, a.verdict, parts);
  }
  if (!reviews.ok) {
    parts.push({ part: 'dismiss', status: 'failed', error: `reviews read: ${reviews.error}` });
    return result(ctx, repo, a, sha, a.verdict, parts);
  }
  const mine = reviews.data.filter((r) =>
    r?.state === 'CHANGES_REQUESTED' && typeof r?.user?.login === 'string' && r.user.login.trim().toLowerCase() === login);
  if (mine.length === 0) {
    parts.push({ part: 'dismiss', status: 'not_needed' });
    return result(ctx, repo, a, sha, a.verdict, parts);
  }
  const message = `Cleared by ${a.verdict} on ${sha.slice(0, 12)}.`;
  const answers = await Promise.all(mine.map((r) =>
    gh(ctx, 'PUT', `${base}/pulls/${a.pr}/reviews/${r.id}/dismissals`, { event: 'DISMISS', message })));
  const dismissed = [];
  const failed = [];
  answers.forEach((x, i) => (x.ok ? dismissed.push(mine[i].id) : failed.push({ id: mine[i].id, error: x.error })));
  parts.push({ part: 'dismiss', status: failed.length ? 'failed' : 'ok', dismissed, ...(failed.length ? { failed } : {}) });
  return result(ctx, repo, a, sha, a.verdict, parts);
}

// ---- schemas and the guard ----
const obj = (properties, required) => ({ type: 'object', properties, required, additionalProperties: false });
const REPO = { type: 'string', minLength: 3, maxLength: 200 };
const PR = { type: 'integer', minimum: 1 };
const SHA = { type: 'string', minLength: 40, maxLength: 40 };
const BOOL = { type: 'boolean' };
const REPO_RE = /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/;

// confirm, then the allowlist (exact on the trimmed, lowercased repo, the
// normalization loadConfig applies), then the schema, then the formats that
// keep the repo and the sha safe inside a gh api path.
function guard(schema) {
  const check = checkArgs(schema);
  return (args, ctx) => {
    if (args.confirm !== true) return 'confirm_required';
    const repo = typeof args.repo === 'string' ? args.repo.trim().toLowerCase() : '';
    if (!ctx.cfg.allowlist.includes(repo)) return 'repo_not_allowlisted';
    const bad = check(args);
    if (bad) return bad;
    if (!REPO_RE.test(repo) || repo.split('/').some((s) => s === '.' || s === '..')) return 'invalid_arguments: repo';
    if (!/^[0-9a-f]{40}$/i.test(args.head_sha)) return 'invalid_arguments: head_sha';
    return null;
  };
}

const POST_SCHEMA = obj({
  repo: REPO, pr: PR, head_sha: SHA,
  findings: { type: 'string', minLength: 1, maxLength: 60000 },
  confirm: BOOL,
}, ['repo', 'pr', 'head_sha', 'findings', 'confirm']);

const CLEAR_SCHEMA = obj({
  repo: REPO, pr: PR, head_sha: SHA,
  verdict: { type: 'string', enum: ['MERGE', 'MERGE-WITH-NOTES'] },
  note: { type: 'string', minLength: 1, maxLength: 500 },
  confirm: BOOL,
}, ['repo', 'pr', 'head_sha', 'verdict', 'confirm']);

export const tools = [
  {
    name: 'post_block',
    description: 'Block a PR head: post the findings as a PR comment, a REQUEST_CHANGES review on head_sha and a human BLOCK verdict row; dequeue it when it has the merge-queue label. Refuses when head_sha is not the current head. One result per part. Needs confirm: true and an allowlisted repo.',
    kind: 'guarded',
    inputSchema: POST_SCHEMA,
    precheck: guard(POST_SCHEMA),
    handler: postBlock,
  },
  {
    name: 'clear_block',
    description: "Clear a block on a new head: post a human MERGE or MERGE-WITH-NOTES verdict row on head_sha, then dismiss the caller's own standing CHANGES_REQUESTED reviews. Refuses when head_sha is not the current head. One result per part. Needs confirm: true and an allowlisted repo.",
    kind: 'guarded',
    inputSchema: CLEAR_SCHEMA,
    precheck: guard(CLEAR_SCHEMA),
    handler: clearBlock,
  },
];
