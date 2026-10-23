// batch_failure (BH-7714): why a Mergify batch failed, and which of its PRs
// can be re-queued. Input: a batch draft PR (`draft`) or a PR the batch
// ejected or held (`pr`). Read-only: GitHub REST GETs through the one seam,
// mcp/lib/github.mjs, with HARNESS_MCP_GITHUB_TOKEN; no console route, no gh.
//
// It returns the draft, its members, the PRs queued ahead of it and its head
// sha; each failed check with up to 40 failure lines (a knob, see CAP_DEFAULTS)
// from its job log; per
// failed check the member or ahead PRs whose changed files the lines name
// (the likely culprits); and per PR its state, head CI and current-head
// verdict check, plus `requeue_candidates`. A batch whose failed checks are
// all cancelled or timed out is `dead_shards` ("dead shards, re-queue all").
//
// Completeness is earned: a cap that applies or a read that fails sets
// `complete: false` and is named in `partial`. A PR is `culprit: false` only
// when its whole file list was read, the draft's whole check list was read
// AND every failed check's lines were read; otherwise it is `culprit: null`
// and never a re-queue candidate.
import { redact } from '../lib/console.mjs';
import { RAW_CAP, githubConfig, githubFetch, intKnob, scrubToken } from '../lib/github.mjs';
import { checkArgs } from './lib/schema.mjs';

const obj = (properties, required) => ({
  type: 'object', properties, ...(required ? { required } : {}), additionalProperties: false,
});
const str = (minLength, maxLength) => ({ type: 'string', minLength, maxLength });
const int = (minimum) => ({ type: 'integer', minimum });

// Caps are knobs (BH-7945): each is read per call from the MCP client's
// environment, and the number here is only the documented fallback when the
// knob is unset or not a positive integer.
export const CAP_DEFAULTS = Object.freeze({
  page: 3, // HARNESS_MCP_BATCH_PAGE_CAP: pages of 100 per list read
  candidate: 5, // HARNESS_MCP_BATCH_CANDIDATE_CAP: Mergify PRs read from a timeline
  log: 10, // HARNESS_MCP_BATCH_LOG_CAP: job logs read per call
  line: 40, // HARNESS_MCP_BATCH_LINE_CAP: failure lines per check
  lineLen: 500, // HARNESS_MCP_BATCH_LINE_LEN: chars per failure line
});
export const batchCaps = (env) => ({
  page: intKnob(env, 'HARNESS_MCP_BATCH_PAGE_CAP', CAP_DEFAULTS.page),
  candidate: intKnob(env, 'HARNESS_MCP_BATCH_CANDIDATE_CAP', CAP_DEFAULTS.candidate),
  log: intKnob(env, 'HARNESS_MCP_BATCH_LOG_CAP', CAP_DEFAULTS.log),
  line: intKnob(env, 'HARNESS_MCP_BATCH_LINE_CAP', CAP_DEFAULTS.line),
  lineLen: intKnob(env, 'HARNESS_MCP_BATCH_LINE_LEN', CAP_DEFAULTS.lineLen),
});
const MQ_REF = 'mergify/merge-queue/';
const MERGIFY = 'mergify[bot]';
// A `.` or `..` segment is refused: URL normalization would turn it into a
// different API path on the same origin.
const REPO_RE = /^(?!\.{1,2}\/)[A-Za-z0-9_.-]+\/(?!\.{1,2}$)[A-Za-z0-9_.-]+$/;
// The same list as worker/jobs/src/lib/merge-queue-intake.js FAILED_CONCLUSIONS.
const FAILED = new Set(['failure', 'timed_out', 'cancelled', 'action_required', 'startup_failure']);
const DEAD = new Set(['cancelled', 'timed_out']);
const PASSED = new Set(['success', 'neutral', 'skipped']);

const fmtBytes = (b) => (b % (1024 * 1024) === 0 ? `${b / (1024 * 1024)} MiB` : `${b} bytes`);
const fail = (t) => ({ content: [{ type: 'text', text: t }], isError: true });
const nullable = (v) => (v === undefined ? null : v);

// ---- pure parts ----

// The `- number: N` entries directly under `pull_requests:` in the Mergify
// metadata YAML. Fallback: "merge queue: checking #a + #b ... together" in the
// title. Neither → null.
export function membersOf(body, title) {
  const lines = String(body ?? '').split(/\r?\n/);
  const at = lines.findIndex((l) => /^pull_requests:\s*$/.test(l));
  if (at >= 0) {
    const out = [];
    for (const l of lines.slice(at + 1)) {
      if (!/^\s/.test(l)) break; // the next top-level key ends the list
      const m = /^ {0,2}- number: (\d+)\s*$/.exec(l);
      if (m) out.push(Number(m[1]));
    }
    if (out.length) return [...new Set(out)];
  }
  const t = /^merge queue: checking ((?:#\d+(?: \+ )?)+) together/.exec(String(title ?? ''));
  return t ? [...t[1].matchAll(/#(\d+)/g)].map((m) => Number(m[1])) : null;
}

// The PRs linked between "### Queued ahead of this batch" and the next
// heading, <details> or code fence.
export function aheadOf(body) {
  const lines = String(body ?? '').split(/\r?\n/);
  const at = lines.findIndex((l) => /^#{2,4}\s*Queued ahead of this batch/i.test(l));
  if (at < 0) return [];
  const out = [];
  for (const l of lines.slice(at + 1)) {
    if (/^(#{1,6}\s|<details|```)/.test(l)) break;
    for (const m of l.matchAll(/(?:(?<![\w/&])#|\/pull\/)(\d+)\b/g)) out.push(Number(m[1]));
  }
  return [...new Set(out)];
}

const TS = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z ?/;
const ANSI = /\u001b\[[0-9;?]*[A-Za-z]/g;
const ECHO = '\u001b[36;1m'; // GitHub's echo of the step script
const DONE = /^##\[error\]Process completed with exit code/;
const PATH_LINE = /(?:^|[^\w.@+/-])(?:\.{0,2}\/)?(?:[\w.@+-]+\/)*[\w@+-][\w.@+-]*\.[A-Za-z]\w*:\d+/;
const TAG = /^(?=[A-Z0-9_-]{3,}:)[A-Z][A-Z0-9_-]*(?:-GUARD|ERROR|FAIL):/;

const isFailureLine = (s) => {
  const t = s.trimStart();
  return t.startsWith('##[error]') || /^FAIL[: ]/.test(t) || t.startsWith('not ok ') || TAG.test(t) || PATH_LINE.test(t);
};

// A raw job log → {lines, lines_total, lines_source}. 'error': the first
// caps.line (40) failure lines. 'tail': no failure line other than the
// runner's own "Process completed", so the caps.line non-empty lines before it
// (or the last caps.line).
export function failureLines(raw, caps = CAP_DEFAULTS) {
  const cap = (s) => s.slice(0, caps.lineLen);
  const all = [];
  for (const line of String(raw ?? '').split(/\r?\n/)) {
    const t = line.replace(TS, '');
    if (t.startsWith(ECHO)) continue;
    const s = t.replace(ANSI, '').replace(/\r/g, '');
    if (/^##\[(?:group|endgroup)\]/.test(s)) continue;
    all.push(s);
  }
  const kept = all.filter(isFailureLine);
  if (kept.some((s) => !DONE.test(s))) {
    return { lines: kept.slice(0, caps.line).map(cap), lines_total: kept.length, lines_source: 'error' };
  }
  const end = all.findIndex((s) => DONE.test(s));
  const tail = (end >= 0 ? all.slice(0, end) : all).filter((s) => s.trim() !== '').slice(-caps.line).map(cap);
  return { lines: tail, lines_total: tail.length, lines_source: 'tail' };
}

// Paths the failure lines name: `dir/file.ext` (absolute, ./ or relative),
// plus a bare `file.ext` only when `:<line>` follows it.
export function namedPaths(lines) {
  const out = new Set();
  for (const l of lines) {
    for (const m of l.matchAll(/(?<![\w.@+-])(?:\.?\/)?(?:[\w.@+-]+\/)+[\w.@+-]+\.[A-Za-z]\w*/g)) out.add(m[0].replace(/^\.\//, ''));
    for (const m of l.matchAll(/(?<![\w.@+/-])([\w@+-][\w.@+-]*\.[A-Za-z]\w*):\d+/g)) out.add(m[1]);
  }
  return [...out];
}

// A PR file matches a named path when they are equal, or the path ends in
// "/<file>" (an absolute runner path). A bare suffix without "/" never does.
export const pathMatches = (p, f) => {
  const q = p.replace(/^\.\//, '');
  return q === f || q.endsWith('/' + f);
};

// The latest run (highest id) per check name.
export function latestByName(runs) {
  const by = new Map();
  for (const r of runs) {
    if (typeof r?.name !== 'string') continue;
    const had = by.get(r.name);
    if (!had || r.id > had.id) by.set(r.name, r);
  }
  return [...by.values()].sort((a, b) => a.id - b.id);
}

const isFailed = (r) => r.status === 'completed' && FAILED.has(r.conclusion);

// failed / dead_shards / pending / passed, from the latest runs per name.
// No run at all is pending: nothing has reported yet.
export function batchState(latest) {
  const failed = latest.filter(isFailed);
  if (failed.length) return failed.every((r) => DEAD.has(r.conclusion)) ? 'dead_shards' : 'failed';
  return latest.length && latest.every((r) => r.status === 'completed') ? 'passed' : 'pending';
}

// A PR's own head CI, the verdict check excluded. A completed run with any
// other conclusion (stale) needs a re-run, so it counts as pending.
function headCi(latest, verdictName) {
  const runs = latest.filter((r) => r.name !== verdictName);
  if (!runs.length) return 'none';
  if (runs.some(isFailed)) return 'failure';
  return runs.every((r) => r.status === 'completed' && PASSED.has(r.conclusion)) ? 'success' : 'pending';
}

// ---- GitHub reads ----

// Up to caps.page pages of a list. → {ok, items, complete} or the error.
async function pages(gh, caps, path, pick) {
  const items = [];
  for (let p = 1; p <= caps.page; p++) {
    const r = await githubFetch(gh, `${path}${path.includes('?') ? '&' : '?'}per_page=100&page=${p}`);
    if (!r.ok) return r;
    const got = pick(r.data);
    if (!Array.isArray(got)) return { ok: false, error: 'bad_payload' };
    items.push(...got);
    if (!r.next) return { ok: true, items, complete: true };
  }
  return { ok: true, items, complete: false };
}

const checkRuns = (gh, caps, repo, sha) =>
  pages(gh, caps, `/repos/${repo}/commits/${sha}/check-runs`, (d) => d?.check_runs);

const isDraftPull = (p) => typeof p?.head?.ref === 'string' && p.head.ref.startsWith(MQ_REF);

// The draft for an ejected or held PR: the newest Mergify cross-reference
// whose pull is a merge-queue draft that names the PR as a member or ahead.
async function findDraft(gh, caps, repo, n) {
  const tl = await pages(gh, caps, `/repos/${repo}/issues/${n}/timeline`, (d) => d);
  if (!tl.ok) return { error: tl.error };
  const cands = tl.items
    .filter((e) => e?.event === 'cross-referenced' && e.source?.issue?.user?.login === MERGIFY && e.source.issue.pull_request)
    .sort((a, b) => Date.parse(b.created_at) - Date.parse(a.created_at))
    .slice(0, caps.candidate);
  let readError = null;
  // In order, newest first, and stop at the first hit: usually the first.
  for (const e of cands) {
    const r = await githubFetch(gh, `/repos/${repo}/pulls/${e.source.issue.number}`);
    if (!r.ok) { readError ??= r.error; continue; }
    if (!isDraftPull(r.data)) continue;
    const members = membersOf(r.data.body, r.data.title) ?? [];
    if (members.includes(n) || aheadOf(r.data.body).includes(n)) return { pull: r.data };
  }
  if (readError) return { error: readError };
  return { notFound: { error: 'draft_not_found', searched_events: tl.items.length, timeline_complete: tl.complete } };
}

// One failed check's lines: its job log for a GitHub Actions run, else the
// check's own output text.
async function checkLines(gh, caps, repo, run, canRead) {
  const base = { name: run.name, id: run.id, conclusion: run.conclusion, app: nullable(run.app?.slug) };
  if (run.app?.slug !== 'github-actions') {
    const text = [run.output?.title, run.output?.summary].filter((s) => typeof s === 'string').join('\n');
    const lines = text.split(/\r?\n/).map((s) => s.replace(ANSI, '')).filter((s) => s.trim() !== '');
    return { ...base, lines: lines.slice(0, caps.line).map((s) => s.slice(0, caps.lineLen)), lines_total: lines.length, lines_source: 'summary' };
  }
  if (!canRead) return { ...base, lines: null, lines_source: 'not_read_cap' };
  const r = await githubFetch(gh, `/repos/${repo}/actions/jobs/${run.id}/logs`, { raw: true });
  if (!r.ok) return { ...base, lines: null, lines_source: 'read_failed', error: r.error };
  return { ...base, ...failureLines(r.text, caps), ...(r.truncated ? { log_truncated: true } : {}) };
}

// One member or ahead PR: the pull, its files, then its head check runs.
async function readPr(gh, caps, repo, n, role, verdictName) {
  const [p, f] = await Promise.all([
    githubFetch(gh, `/repos/${repo}/pulls/${n}`),
    pages(gh, caps, `/repos/${repo}/pulls/${n}/files`, (d) => d),
  ]);
  const out = { pr: n, role, partial: [] };
  if (p.ok) {
    Object.assign(out, { state: nullable(p.data.state), merged: p.data.merged === true, head_sha: nullable(p.data.head?.sha), title: nullable(p.data.title) });
  } else {
    Object.assign(out, { state: null, merged: null, head_sha: null, title: null, pull_error: p.error });
    out.partial.push(`pull #${n}: ${p.error}`);
  }
  if (f.ok) {
    out.files = f.items.flatMap((x) => [x?.filename, x?.previous_filename]).filter((x) => typeof x === 'string');
    out.files_complete = f.complete;
    if (!f.complete) out.partial.push(`files #${n}: more than ${caps.page * 100}`);
  } else {
    Object.assign(out, { files: null, files_complete: false, files_error: f.error });
    out.partial.push(`files #${n}: ${f.error}`);
  }
  out.head_ci = null;
  out.verdict = null;
  if (out.head_sha) {
    const c = await checkRuns(gh, caps, repo, out.head_sha);
    if (c.ok) {
      const latest = latestByName(c.items);
      out.head_ci = headCi(latest, verdictName);
      const v = latest.find((r) => r.name === verdictName);
      out.verdict = v ? (v.status === 'completed' ? nullable(v.conclusion) : 'pending') : null;
      if (!c.complete) out.partial.push(`checks #${n}: more than ${caps.page * 100}`);
    } else {
      out.partial.push(`checks #${n}: ${c.error}`);
    }
  }
  return out;
}

// The scrubbed, redacted text is the one source: structuredContent is parsed
// back from it, so neither half can carry what the other scrubbed.
function reply(ctx, gh, value, isError = false) {
  const text = redact(scrubToken(JSON.stringify(value), gh), ctx.cfg);
  return { content: [{ type: 'text', text }], structuredContent: JSON.parse(text), ...(isError ? { isError: true } : {}) };
}

async function batchFailure(a, ctx) {
  const gh = ctx.github ?? githubConfig(process.env);
  const caps = ctx.batchCaps ?? batchCaps(process.env);
  if (!gh.token) return fail('github_auth_not_configured');
  if (!gh.url) return fail('github_url_invalid');
  const repo = a.repo;
  const verdictName = a.verdict_check ?? 'lead-verdict';

  let pull;
  if (a.draft !== undefined) {
    const r = await githubFetch(gh, `/repos/${repo}/pulls/${a.draft}`);
    if (!r.ok) return fail(r.error);
    if (!isDraftPull(r.data)) return fail('not_a_batch_draft');
    pull = r.data;
  } else {
    const d = await findDraft(gh, caps, repo, a.pr);
    if (d.error) return fail(d.error);
    if (d.notFound) return reply(ctx, gh, d.notFound, true);
    pull = d.pull;
  }
  const draft = pull.number;
  const members = membersOf(pull.body, pull.title);
  if (!members) return fail('members_unparsed');
  const ahead = aheadOf(pull.body).filter((n) => !members.includes(n));
  const headSha = nullable(pull.head?.sha);
  if (!headSha) return fail('bad_payload');

  const roles = [...members.map((n) => [n, 'member']), ...ahead.map((n) => [n, 'ahead'])];
  const [cr, prs] = await Promise.all([
    checkRuns(gh, caps, repo, headSha),
    Promise.all(roles.map(([n, role]) => readPr(gh, caps, repo, n, role, verdictName))),
  ]);
  if (!cr.ok) return fail(cr.error);

  const latest = latestByName(cr.items);
  const state = batchState(latest);
  const dead = state === 'dead_shards';
  let logs = 0;
  const failedRuns = latest.filter(isFailed);
  const failed_checks = await Promise.all(failedRuns.map((r) => {
    const canRead = r.app?.slug === 'github-actions' && logs++ < caps.log;
    return checkLines(gh, caps, repo, r, canRead);
  }));

  const partial = prs.flatMap((p) => p.partial);
  if (!cr.complete) partial.push(`checks draft #${draft}: more than ${caps.page * 100}`);
  for (const c of failed_checks) {
    if (c.lines_source === 'read_failed') partial.push(`log ${c.name}: ${c.error}`);
    if (c.lines_source === 'not_read_cap') partial.push(`log ${c.name}: past the ${caps.log}-log cap`);
    if (c.log_truncated) partial.push(`log ${c.name}: over ${fmtBytes(gh.rawCap ?? RAW_CAP)}, the start not read`);
  }
  // A check past the page cap may be a failure nobody read: no PR is clean then.
  const linesKnown = cr.complete && failed_checks.every((c) => Array.isArray(c.lines));

  for (const c of failed_checks) {
    c.paths = c.lines ? namedPaths(c.lines) : null;
    // A heuristic, not proof: a log that names a file an innocent PR edited
    // makes that PR a culprit too. The candidates are advice only.
    c.culprits = dead || !c.paths ? [] : prs.filter((p) => p.files?.some((f) => c.paths.some((q) => pathMatches(q, f)))).map((p) => p.pr);
  }
  const culprits = [...new Set(failed_checks.flatMap((c) => c.culprits))].sort((x, y) => x - y);
  // A real failure (not cancelled, not timed out) whose lines name no changed
  // file was caused by a PR we cannot see: no PR is clean then, or the PR at
  // fault is re-queued and fails the next batch the same way.
  const unexplained = failed_checks.some((c) => !DEAD.has(c.conclusion) && c.culprits.length === 0);
  const open = (p) => p.state === 'open' && p.merged === false;
  const outPrs = prs.map(({ partial: _, ...p }) => {
    let culprit = null;
    if (!dead && culprits.includes(p.pr)) culprit = true;
    else if (!dead && p.files_complete && linesKnown && !unexplained) culprit = false;
    return { ...p, culprit };
  });
  // Only a finished, failed batch has candidates: a pending or passed batch
  // is still live, and its PRs need no re-queue.
  const settled = state === 'failed' || dead;
  const requeue_candidates = outPrs
    .filter((p) => settled && open(p) && (dead || (p.culprit === false && p.head_ci === 'success' && p.verdict === 'success')))
    .map((p) => p.pr);

  const out = {
    repo, draft, draft_url: nullable(pull.html_url), draft_state: nullable(pull.state), draft_title: nullable(pull.title),
    head_sha: headSha, members, ahead,
    ...(a.pr !== undefined ? { asked: { pr: a.pr, role: members.includes(a.pr) ? 'member' : 'ahead' } } : {}),
    batch_state: state, dead_shards: dead,
    ...(dead ? { note: 'dead shards, re-queue all' } : {}),
    failed_checks, culprits,
    culprit_unknown: !dead && failed_checks.length > 0 && culprits.length === 0,
    prs: outPrs, requeue_candidates, verdict_check: verdictName,
    complete: partial.length === 0,
  };
  if (partial.length) out.partial = partial;
  return reply(ctx, gh, out);
}

const inputSchema = obj({ repo: str(3, 200), pr: int(1), draft: int(1), verdict_check: str(1, 100) }, ['repo']);
const argCheck = checkArgs(inputSchema);

export const tools = [{
  name: 'batch_failure',
  description: 'Why a merge-queue batch failed: give a batch draft PR or a PR it ejected. Returns the draft, members and ahead PRs, ' +
    'each failed check with its failure lines, the PRs whose files those lines name (likely culprits), each PR\'s head CI and ' +
    'verdict, and the re-queue candidates. Marks "dead shards, re-queue all" when every failed check was cancelled or timed out. ' +
    'Read-only; needs HARNESS_MCP_GITHUB_TOKEN.',
  kind: 'read',
  inputSchema,
  precheck: (a) => {
    const bad = argCheck(a);
    if (bad) return bad;
    if (!REPO_RE.test(a.repo)) return 'invalid_arguments: repo';
    if ((a.pr === undefined) === (a.draft === undefined)) return 'pr_or_draft_required';
    return null;
  },
  handler: batchFailure,
}];
