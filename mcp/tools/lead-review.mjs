// Lead review tools (BH-7711). lead_review_show reads one PR's verdict rows,
// its lead review requests and the BLOCK and NOTE findings of its lead report,
// all through console routes: the report is the job's lead_review_report
// artifact, or its lead_report transcript when the artifact was cut at the
// worker's 4000-unit cap. lead_review_request and lead_review_reset are the
// asks `lead-verdict.sh request` and `reset` make; each sends one POST, and
// only when confirm is the boolean true. A failed optional read is named in
// `partial`, never shown as "nothing there".
import { consoleFetch, redact } from '../lib/console.mjs';
import { checkArgs } from './lib/schema.mjs';

const obj = (properties, required) => ({ type: 'object', properties, required, additionalProperties: false });
const str = (maxLength) => ({ type: 'string', minLength: 1, maxLength });
const int = (minimum, maximum) => ({ type: 'integer', minimum, ...(maximum ? { maximum } : {}) });
const BOOL = { type: 'boolean' };

const VERDICTS = '/api/coord/verdicts';
const REQUESTS = '/api/coord/lead-reviews';
const JOBS = '/api/coord/jobs';
// The worker's page sizes: a full page means there may be more.
const PAGE = 100;
const FINDINGS_MAX = 100;
const FINDING_CHARS = 2000;

const REPO_RE = /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/;
const SHA_RE = /^[0-9a-f]{40}$/;
const ID_RE = /^[A-Za-z0-9._-]+$/;
const TITLE_RE = /^# Lead review .* \((.+)#(\d+) at ([0-9a-f]{40})\)$/;
const FINDING_RE = /^- \[((?:BLOCK|NOTE)[^\]]*)\]\s*(.*)$/;
const JOB_TOKEN_RE = /(?:^| )lead-job:(\S+)/;

const isPlain = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);
const fail = (t) => ({ content: [{ type: 'text', text: t }], isError: true });
const nullable = (v) => (v === undefined ? null : v);
const query = (pairs) => '?' + new URLSearchParams(pairs.map(([k, v]) => [k, String(v)])).toString();

async function getJson(ctx, path) {
  const r = await (ctx.consoleFetch ?? consoleFetch)(ctx.cfg, 'GET', path);
  if (r.ok) return { ok: true, data: r.data };
  if (r.status === 404) return { ok: false, error: `console route not available: ${path.split('?')[0]}` };
  return { ok: false, error: r.error };
}

// The redacted text is the one source: structuredContent is parsed back from
// it, so neither half can carry what the other scrubbed.
function reply(ctx, value) {
  const text = redact(JSON.stringify(value), ctx.cfg);
  return { content: [{ type: 'text', text }], structuredContent: JSON.parse(text) };
}

// The report to read: the newest verdict row whose note carries a
// `lead-job:<job>` token (the token starts the note or follows a space), else
// the newest done request that has a job. Either list may be null (its read
// failed). Returns {job_id, head_sha, verdict} or null.
export function pickReportJob(verdicts, requestsNewestFirst) {
  for (const v of verdicts ?? []) {
    const m = typeof v?.note === 'string' ? JOB_TOKEN_RE.exec(v.note) : null;
    if (m) return { job_id: m[1], head_sha: nullable(v.head_sha), verdict: nullable(v.verdict) };
  }
  for (const q of requestsNewestFirst ?? []) {
    if (q?.status === 'done' && typeof q.job_id === 'string' && q.job_id) {
      return { job_id: q.job_id, head_sha: nullable(q.head_sha), verdict: nullable(q.verdict) };
    }
  }
  return null;
}

// The `- [BLOCK ...]` and `- [NOTE ...]` items of a report, each with its
// indented continuation lines joined (the lc_findings rule of
// bin/lesson-classify.sh, extended to NOTE). At most FINDINGS_MAX per kind.
export function findings(body) {
  const out = { block: [], note: [], complete: true };
  let cur = null;
  const flush = () => {
    if (!cur) return;
    const list = cur.tag.startsWith('BLOCK') ? out.block : out.note;
    if (list.length < FINDINGS_MAX) list.push({ tag: cur.tag, text: cur.text.slice(0, FINDING_CHARS) });
    else out.complete = false;
    cur = null;
  };
  for (const line of body.split('\n')) {
    const m = FINDING_RE.exec(line);
    if (m) {
      flush();
      cur = { tag: m[1].trim(), text: m[2].trim() };
    } else if (cur && /^[ \t]+[^ \t]/.test(line)) {
      cur.text += ' ' + line.trim();
    } else {
      flush();
    }
  }
  flush();
  return out;
}

// The report's title line, when it names this repo (any case), pr and head.
function titleFor(body, repo, pr, head) {
  const line = body.split('\n').find((l) => l.startsWith('# Lead review '));
  const m = line ? TITLE_RE.exec(line) : null;
  if (!m || m[1].toLowerCase() !== repo.toLowerCase() || Number(m[2]) !== pr || m[3] !== head) return null;
  return line;
}

// The whole report from the job's newest lead_report transcript, or null with
// the reason it could not be used.
async function fullReport(ctx, job, repo, pr, head) {
  const base = `${JOBS}/${encodeURIComponent(job)}`;
  const idx = await getJson(ctx, `${base}/transcripts`);
  if (!idx.ok) return { why: `transcripts: ${idx.error}` };
  const rows = Array.isArray(idx.data?.transcripts) ? idx.data.transcripts : null;
  if (!rows) return { why: 'transcripts: bad_payload' };
  const slot = rows.filter((r) => r?.source === 'lead_report').at(-1);
  if (!slot) return { why: 'no lead_report transcript' };
  const tr = await getJson(ctx, `${base}/transcript` + query([['phase_id', slot.phase_id], ['attempt', slot.attempt]]));
  if (!tr.ok) return { why: `transcript: ${tr.error}` };
  const body = tr.data?.transcript?.body;
  if (typeof body !== 'string') return { why: 'transcript: bad_payload' };
  if (tr.data.transcript.truncated) return { why: 'the lead_report transcript is cut too' };
  const title = titleFor(body, repo, pr, head);
  if (!title) return { why: 'the lead_report transcript title names another repo, pr or head' };
  return { body, title };
}

// Where the report file sits, from the request that ran the job (else the
// newest request), so a person knows where to look.
function whereIs(requests, job) {
  const q = (requests ?? []).find((r) => r?.job_id === job) ?? (job ? null : (requests ?? [])[0]);
  if (!q) return 'no request row names it';
  return `request ${q.id} is ${q.status}, box ${q.box ?? 'unknown'}, report_ref ${q.report_ref ?? 'none'}`;
}

// {report} or {report: null, missing, partial?}.
async function readReport(ctx, a, pick, requests) {
  if (!pick) {
    return { report: null, missing: `no report job: no verdict note names lead-job: and no done request has a job (${whereIs(requests, null)})` };
  }
  const job = pick.job_id;
  const route = `${JOBS}/${encodeURIComponent(job)}/artifacts`;
  const art = await getJson(ctx, route);
  if (!art.ok) return { report: null, missing: `job ${job}: artifacts read failed: ${art.error}`, partial: route };
  const list = Array.isArray(art.data?.artifacts) ? art.data.artifacts : null;
  if (!list) return { report: null, missing: `job ${job}: artifacts: bad_payload`, partial: route };
  const row = list.find((x) => x?.artifact_kind === 'lead_review_report');
  if (!row) return { report: null, missing: `job ${job} has no lead_review_report artifact; the report file: ${whereIs(requests, job)}` };
  let d = null;
  try { d = JSON.parse(row.detail); } catch { d = null; }
  if (!isPlain(d) || typeof d.body !== 'string') return { report: null, missing: `job ${job}: the lead_review_report detail is not a report` };
  const head = typeof pick.head_sha === 'string' ? pick.head_sha.toLowerCase() : '';
  let body = d.body;
  let title = titleFor(body, a.repo, a.pr, head);
  if (!title) return { report: null, missing: `job ${job}: the report title does not name ${a.repo}#${a.pr} at ${head || 'a known head'}` };
  let from = 'artifact';
  let truncated = false;
  let truncated_why;
  if (d.truncated === true) {
    const full = await fullReport(ctx, job, a.repo, a.pr, head);
    if (full.body) {
      ({ body, title } = full);
      from = 'transcript';
    } else {
      truncated = true;
      truncated_why = full.why;
    }
  }
  const f = findings(body);
  const report = {
    job_id: job, head_sha: head, verdict: nullable(d.verdict ?? pick.verdict), from, truncated, title,
    block: f.block, note: f.note, findings_complete: f.complete && !truncated,
  };
  if (truncated_why) report.truncated_why = truncated_why;
  return { report };
}

const verdictOut = (v) => ({
  id: nullable(v?.id), created_at: nullable(v?.created_at), head_sha: nullable(v?.head_sha), verdict: nullable(v?.verdict),
  source: nullable(v?.source), reviewer: nullable(v?.reviewer), reviewer_model: nullable(v?.reviewer_model),
  report_url: nullable(v?.report_url), note: nullable(v?.note),
});
const requestOut = (q) => ({
  id: nullable(q?.id), status: nullable(q?.status), head_sha: nullable(q?.head_sha), created_at: nullable(q?.created_at),
  updated_at: nullable(q?.updated_at), heartbeat_at: nullable(q?.heartbeat_at), job_id: nullable(q?.job_id),
  box: nullable(q?.box), participant: nullable(q?.participant), verdict: nullable(q?.verdict),
  report_ref: nullable(q?.report_ref), detail: nullable(q?.detail), priority: nullable(q?.priority),
  reset_count: nullable(q?.reset_count), requested_by: nullable(q?.requested_by),
});

async function show(a, ctx) {
  const q = [['repo', a.repo], ['pr', a.pr]];
  const [vr, rr] = await Promise.all([
    getJson(ctx, VERDICTS + query(q)),
    getJson(ctx, REQUESTS + query([...q, ['limit', PAGE]])),
  ]);
  const vrows = vr.ok && Array.isArray(vr.data?.rows) ? vr.data.rows : null;
  const rrows = rr.ok && Array.isArray(rr.data?.requests) ? rr.data.requests : null;
  if (!vrows && !rrows) {
    return fail(`verdicts: ${vr.ok ? 'bad_payload' : vr.error}; requests: ${rr.ok ? 'bad_payload' : rr.error}`);
  }
  const partial = [];
  if (!vrows) partial.push(VERDICTS);
  if (!rrows) partial.push(REQUESTS);
  // The worker lists requests oldest first; this answer is newest first. A
  // worker that predates the pr filter answers the whole repo, so rows of
  // another pr are dropped here.
  const requests = rrows ? rrows.filter((q) => q?.pr === a.pr).reverse() : null;
  const r = await readReport(ctx, a, pickReportJob(vrows, requests), requests);
  if (r.partial) partial.push(r.partial);
  const out = {
    repo: a.repo, pr: a.pr,
    verdicts: vrows ? vrows.map(verdictOut) : null,
    verdicts_complete: vrows ? vrows.length < PAGE && vr.data.truncated !== true : null,
    requests: requests ? requests.map(requestOut) : null,
    requests_complete: rrows ? rr.data.truncated === false : null,
    report: r.report,
  };
  if (r.missing) out.report_missing = r.missing;
  if (partial.length) out.partial = partial;
  return reply(ctx, out);
}

async function post(ctx, path, body) {
  const r = await (ctx.consoleFetch ?? consoleFetch)(ctx.cfg, 'POST', path, body);
  if (r.ok) return { ok: true, data: r.data };
  if (r.status === 404) return { ok: false, error: `console route not available: ${path}` };
  return { ok: false, error: r.error };
}

async function request(a, ctx) {
  const body = { repo: a.repo, pr: a.pr, head_sha: a.head_sha.toLowerCase() };
  if (a.notes !== undefined) body.scope_notes = a.notes;
  if (a.priority !== undefined) body.priority = a.priority;
  const r = await post(ctx, REQUESTS, body);
  if (!r.ok) return fail(r.error);
  const row = r.data?.request;
  if (!isPlain(row)) return fail(`bad_payload: ${REQUESTS}`);
  // The lv_request rule: a 2xx whose row does not carry the asked priority
  // (already running or finished) did not do what was asked.
  if (a.priority !== undefined && row.priority !== a.priority) {
    return fail(redact(`priority_not_stored: request ${row.id} is ${row.status}`, ctx.cfg));
  }
  return reply(ctx, r.data);
}

async function reset(a, ctx) {
  const path = `${REQUESTS}/${encodeURIComponent(a.request_id)}/reset`;
  const r = await post(ctx, path, {});
  if (!r.ok) return fail(r.error);
  if (!isPlain(r.data)) return fail(`bad_payload: ${path}`);
  return reply(ctx, r.data);
}

// Shape checks the schema cannot say (checkArgs has no pattern).
const shapes = {
  lead_review_show: (a) => (REPO_RE.test(a.repo) ? null : 'invalid_arguments: repo'),
  lead_review_request: (a) => {
    if (!REPO_RE.test(a.repo)) return 'invalid_arguments: repo';
    if (!SHA_RE.test(a.head_sha.toLowerCase())) return 'invalid_arguments: head_sha';
    return null;
  },
  lead_review_reset: (a) => (ID_RE.test(a.request_id) && a.request_id !== '.' && a.request_id !== '..'
    ? null : 'invalid_arguments: request_id'),
};

const defs = [
  {
    name: 'lead_review_show',
    description: "One PR's lead review: verdict rows newest first, the lead review requests newest first, and the BLOCK and NOTE findings of its lead report.",
    kind: 'read',
    inputSchema: obj({ repo: str(200), pr: int(1) }, ['repo', 'pr']),
    handler: show,
  },
  {
    name: 'lead_review_request',
    description: 'Ask the lead for a review of one head (the sha is used as given, never looked up). notes become the scope notes; priority 1..1000 puts it ahead. Needs confirm: true.',
    kind: 'guarded',
    inputSchema: obj({ repo: str(200), pr: int(1), head_sha: str(40), notes: str(4000), priority: int(1, 1000), confirm: BOOL },
      ['repo', 'pr', 'head_sha', 'confirm']),
    handler: request,
  },
  {
    name: 'lead_review_reset',
    description: 'Send a lead review request back to requested: a finished one, or a running one whose heartbeat is past the stale limit. Needs confirm: true.',
    kind: 'guarded',
    inputSchema: obj({ request_id: str(128), confirm: BOOL }, ['request_id', 'confirm']),
    handler: reset,
  },
];

// confirm first, so a call without it sends nothing whatever else is wrong;
// then the schema, then the shapes. Read tools have no confirm.
export const tools = defs.map((t) => {
  const check = checkArgs(t.inputSchema);
  const shape = shapes[t.name];
  return {
    ...t,
    precheck: (args) => {
      if (t.kind === 'guarded' && args.confirm !== true) return 'confirm_required';
      return check(args) ?? shape(args);
    },
  };
});
