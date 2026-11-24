// Merge-queue read tools (BH-5671, BH-5008.4). Each reads console routes only:
// GET /api/coord/merge-queue/live, plus the PR event log, the risk tiers and
// the build jobs, and the client-approval hub ledger row (BH-9901). No gh, no
// GitHub host. A field the route answers as null
// stays null; a failed optional read is named in `partial`, never shown as
// "nothing there".
import { consoleFetch, redact } from '../lib/console.mjs';
import { checkArgs } from './lib/schema.mjs';

const obj = (properties, required) => ({
  type: 'object', properties, ...(required ? { required } : {}), additionalProperties: false,
});
const str = (maxLength) => ({ type: 'string', minLength: 1, maxLength });
const int = (minimum) => ({ type: 'integer', minimum });

const LIVE = '/api/coord/merge-queue/live';
const EVENTS = '/api/coord/pr-state-events';
const TIERS = '/api/coord/risk-tiers';
const JOBS = '/api/coord/jobs';
// BH-9901: the hub ledger row a withheld PR's client-approval request writes.
// The read goes through the console's coord proxy; `partial` names it by the
// worker route, '/api/ledger', as the plan's M4 contract fixes it.
const LEDGER = '/api/coord/ledger';
const LEDGER_PARTIAL = '/api/ledger';
const APPROVAL_KIND = 'client-approval';
const APPROVAL_LABEL = 'waiting for client approval';
const ISO_UTC = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z$/;
// Request page sizes. A full page means there may be more: the result says so.
const EVENT_LIMIT = 50;
const JOB_LIMIT = 200;

const isPlain = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);
const fail = (t) => ({ content: [{ type: 'text', text: t }], isError: true });
const query = (pairs) => {
  const q = new URLSearchParams();
  for (const [k, v] of pairs) if (v !== undefined) q.append(k, String(v));
  const s = q.toString();
  return s ? '?' + s : '';
};

// One GET. → {ok, data} or {ok:false, error}; a 404 names the missing route.
async function getJson(ctx, path) {
  const r = await (ctx.consoleFetch ?? consoleFetch)(ctx.cfg, 'GET', path);
  if (r.ok) return { ok: true, data: r.data };
  if (r.status === 404) return { ok: false, status: 404, error: `console route not available: ${path.split('?')[0]}` };
  return { ok: false, status: r.status, error: r.error };
}

// The redacted text is the one source: structuredContent is parsed back from
// it, so neither half can carry what the other scrubbed.
function reply(ctx, value) {
  const text = redact(JSON.stringify(value), ctx.cfg);
  return { content: [{ type: 'text', text }], structuredContent: JSON.parse(text) };
}

// The live payload, or an error. A body without a batches array is a bad
// payload, never an empty queue.
async function readLive(ctx, project) {
  const r = await getJson(ctx, LIVE + query([['project', project]]));
  if (!r.ok) return r;
  if (!isPlain(r.data) || !Array.isArray(r.data.batches)) return { ok: false, error: `bad_payload: ${LIVE}` };
  return r;
}

// "dequeued(x)" and "dequeued (x)" → base "dequeued", detail "x".
function splitStage(stage) {
  if (typeof stage !== 'string') return { base: null, detail: null };
  const m = /^([^(]*?)\s*\(([^()]*)\)\s*$/.exec(stage);
  return m ? { base: m[1], detail: m[2] } : { base: stage.trim(), detail: null };
}

// "<owner>/<name>#<n>" → {repo, pr}, or null.
function splitKey(key) {
  const i = key.lastIndexOf('#');
  const pr = Number(key.slice(i + 1));
  if (i <= 0 || !Number.isInteger(pr) || pr <= 0) return null;
  return { repo: key.slice(0, i), pr };
}

const prsOf = (live) => (isPlain(live.prs) ? live.prs : {});
const nullable = (v) => (v === undefined ? null : v);

function mergeQueue(live) {
  const batches = live.batches.map((b) => {
    const done = b?.checks?.done;
    const total = b?.checks?.total;
    return {
      repo: nullable(b?.repo), draft: nullable(b?.draft), url: nullable(b?.url),
      members: nullable(b?.members), stage: nullable(b?.stage), checks: nullable(b?.checks),
      checks_text: Number.isInteger(done) && Number.isInteger(total) ? `${done}/${total}` : null,
      progress: nullable(b?.progress), eta_s: nullable(b?.eta_s), eta_basis: nullable(b?.eta_basis),
      failing: nullable(b?.failing), bisect: nullable(b?.bisect), outcome: nullable(b?.outcome),
    };
  });
  const pos = (w) => (Number.isFinite(w?.position) ? w.position : Infinity);
  const waiting = (Array.isArray(live.waiting) ? live.waiting : [])
    .map((w) => ({ repo: nullable(w?.repo), pr: nullable(w?.pr), position: nullable(w?.position) }))
    .sort((x, y) => pos(x) - pos(y));
  return { as_of: nullable(live.as_of), complete: nullable(live.complete), batches, waiting };
}

// A client-approval ledger row → the pr_stage field, or null. Only status
// 'waiting' with a v1 detail and an ISO UTC requested_at counts; every other
// status ('closed', 'approved', 'hold', unknown) or a bad detail is null.
export function clientApprovalOf(row, nowMs) {
  if (!isPlain(row) || row.status !== 'waiting' || typeof row.detail !== 'string') return null;
  let d;
  try { d = JSON.parse(row.detail); } catch { return null; }
  if (!isPlain(d) || d.v !== 1) return null;
  const t = typeof d.requested_at === 'string' && ISO_UTC.test(d.requested_at) ? Date.parse(d.requested_at) : NaN;
  if (!Number.isFinite(t)) return null;
  return {
    state: 'waiting', label: APPROVAL_LABEL,
    ticket_id: nullable(d.ticket_id), ticket_url: nullable(d.ticket_url),
    since: d.requested_at, age_s: Math.max(0, Math.floor((nowMs - t) / 1000)),
    head: nullable(d.head),
  };
}

const BLOCKING = /^(lead_block|ci_red|approved_not_queued)/;

async function prStage(a, ctx) {
  const live = await readLive(ctx);
  if (!live.ok) return fail(live.error);
  const want = `${a.repo.toLowerCase()}#${a.pr}`;
  const key = Object.keys(prsOf(live.data)).find((k) => k.toLowerCase() === want);
  const entry = key ? prsOf(live.data)[key] : null;
  // The follow-up reads use the repo as the queue spells it: D1 matches the
  // event log and the tiers on the exact slug.
  const repo = key ? splitKey(key).repo : a.repo;
  // The ledger key is always lowercase (D17): the writer lowercases it too.
  const [ev, rt, lg] = await Promise.all([
    getJson(ctx, EVENTS + query([['repo', repo], ['number', a.pr], ['limit', EVENT_LIMIT]])),
    getJson(ctx, TIERS + query([['repo', repo], ['pr', a.pr], ['limit', 1]])),
    getJson(ctx, LEDGER + query([['kind', APPROVAL_KIND], ['key', `${repo.toLowerCase()}#${a.pr}`]])),
  ]);
  const partial = [];
  const rows = ev.ok && Array.isArray(ev.data?.rows) ? ev.data.rows : null;
  if (!rows) partial.push(EVENTS);
  const tierRows = rt.ok && Array.isArray(rt.data?.rows) ? rt.data.rows : null;
  if (!tierRows) partial.push(TIERS);
  // A 404 is "no row": null, not partial. Any other failure, or a 200 with
  // no ledger object, is partial.
  let client_approval = null;
  if (lg.ok && isPlain(lg.data?.ledger)) client_approval = clientApprovalOf(lg.data.ledger, ctx.now ?? Date.now());
  else if (lg.status !== 404) partial.push(LEDGER_PARTIAL);

  const queue_stage = entry ? { stage: nullable(entry.stage), batch: nullable(entry.batch), at: nullable(entry.at) } : null;
  const lead = rows?.find((r) => r?.state !== 'gate' && r?.state !== 'queue') ?? null;
  const lead_stage = lead ? { state: lead.state, since: nullable(lead.since), reason: nullable(lead.reason) } : null;
  const stages = rows ? rows.slice().reverse().map((r) => ({
    stage: r?.state === 'queue' ? nullable(r.reason) : nullable(r?.state), since: nullable(r?.since), at: nullable(r?.at),
  })) : null;
  // The queue stage's own detail first. A blocking lead/CI reason counts only
  // when it is newer than the queue stage: a PR now checking in a batch is not
  // blocked by the lead_block it had before it was queued.
  let blocked_on = splitStage(queue_stage?.stage).detail;
  const leadIsCurrent = !queue_stage || Date.parse(lead?.at) > Date.parse(queue_stage.at);
  if (blocked_on === null && lead_stage && leadIsCurrent && BLOCKING.test(lead_stage.state)) blocked_on = lead_stage.reason;
  if (blocked_on === null && client_approval) blocked_on = client_approval.label;

  const out = {
    repo, pr: a.pr, queue_stage, lead_stage, stages,
    stages_complete: rows ? rows.length < EVENT_LIMIT : null,
    blocked_on, risk_tier: tierRows ? nullable(tierRows[0]?.tier) : null,
    client_approval,
    as_of: nullable(live.data.as_of),
  };
  if (partial.length) out.partial = partial;
  return reply(ctx, out);
}

const BUILD_GROUP = { plan: 'planning', execute: 'building', review: 'building', merge: 'queued' };

async function backlog(a, ctx) {
  const since = a.since === undefined ? null : Date.parse(a.since);
  if (Number.isNaN(since)) return fail('invalid_arguments: since');
  const [live, jobs] = await Promise.all([
    readLive(ctx, a.project),
    getJson(ctx, JOBS + query([['project', a.project], ['kind', 'build'], ['status', 'running'], ['limit', JOB_LIMIT]])),
  ]);
  if (!live.ok) return fail(live.error);

  const entries = Object.entries(prsOf(live.data)).map(([k, v]) => ({ key: splitKey(k), v }))
    .filter((e) => e.key && isPlain(e.v));
  const counts = {};
  for (const { v } of entries) {
    const base = splitStage(v.stage).base;
    if (base) counts[base] = (counts[base] ?? 0) + 1;
  }
  const out = { project: a.project, as_of: nullable(live.data.as_of), complete: nullable(live.data.complete), counts };
  if (since !== null) {
    out.since = a.since;
    out.changed = entries
      .map((e) => ({ ...e, t: Date.parse(e.v.at) }))
      .filter((e) => Number.isFinite(e.t) && e.t > since)
      .sort((x, y) => x.t - y.t)
      .map((e) => ({ repo: e.key.repo, pr: e.key.pr, stage: nullable(e.v.stage), batch: nullable(e.v.batch), at: e.v.at }));
  }
  const list = jobs.ok && Array.isArray(jobs.data?.jobs) ? jobs.data.jobs : null;
  if (list) {
    out.builds = { planning: [], building: [], queued: [] };
    for (const j of list) {
      const group = BUILD_GROUP[j?.stage];
      if (group) out.builds[group].push({ ticket_id: nullable(j.ticket_id), stage: j.stage, box: nullable(j.box) });
    }
    out.builds_complete = list.length < JOB_LIMIT;
  } else {
    out.builds = null;
    out.partial = [JOBS];
  }
  return reply(ctx, out);
}

const defs = [
  {
    name: 'merge_queue',
    description: 'The merge-queue batches (members, checks, progress, ETA, failing check, bisect step) and the waiting line.',
    kind: 'read',
    inputSchema: obj({ project: str(100) }),
    handler: async (a, ctx) => {
      const live = await readLive(ctx, a.project);
      if (!live.ok) return fail(live.error);
      return reply(ctx, mergeQueue(live.data));
    },
  },
  {
    name: 'pr_stage',
    description: "One PR's lead/CI stage and merge-queue stage, with per-stage timestamps, its blocker, its risk tier and whether it waits for client approval.",
    kind: 'read',
    inputSchema: obj({ repo: str(200), pr: int(1) }, ['repo', 'pr']),
    handler: prStage,
  },
  {
    name: 'backlog',
    description: "A project's PR counts per merge-queue stage, the PRs that changed stage after `since`, and its build tickets.",
    kind: 'read',
    inputSchema: obj({ project: str(100), since: str(40) }, ['project']),
    handler: backlog,
  },
];

export const tools = defs.map((t) => ({ ...t, precheck: checkArgs(t.inputSchema) }));
