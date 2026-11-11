// ticket_status and stuck_tickets (BH-8973): the live status of tickets, read
// from the hub's own D1 rows at call time. Each tool reads ONE console route
// (format ticket-status v1, worker/jobs/src/routes/ticket-status.js):
//   ticket_status  GET /api/coord/ticket-status?project=|repo=&key=...&issue=...
//   stuck_tickets  GET /api/coord/ticket-status/stuck?project=|repo=
// Neither reads the kanban pipeline snapshot.
//
// Then each tool reads the last commit time of every ticket's branch through
// the MCP's one GitHub seam (mcp/lib/github.mjs): GET
// /repos/<repo>/commits?sha=<branch>&per_page=1, in parallel, at most
// HARNESS_MCP_TICKET_STATUS_COMMIT_READS reads per call. Each ticket gets
// last_commit_at and commit_source: github, github_auth_not_configured,
// no_branch, no_repo, skipped_cap or github_error:<code>. A failed read is
// never a null shown as "no commits", and with no token nothing is sent.
import { consoleFetch, redact } from '../lib/console.mjs';
import { githubConfig, githubFetch, intKnob } from '../lib/github.mjs';

const ROUTE = '/api/coord/ticket-status';
const STUCK_ROUTE = `${ROUTE}/stuck`;
// The schema's input bound. The real cap is the worker's settings row
// ticket_status.batch_max; its 400 is shown as `http_400: too_many`.
const TICKETS_MAX = 50;
// Knob HARNESS_MCP_TICKET_STATUS_COMMIT_READS: branch commit reads per call.
// 20 is its documented fallback, the same as ticket_status.batch_max.
const COMMIT_READS_DEFAULT = 20;
const REPO_RE = /^(?!\.{1,2}\/)[A-Za-z0-9_.-]+\/(?!\.{1,2}$)[A-Za-z0-9_.-]+$/;

const isPlain = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);

// The redacted text is the one source: structuredContent is parsed back from
// it, so neither half can carry what the other scrubbed.
function reply(ctx, value) {
  const text = redact(JSON.stringify(value), ctx.cfg);
  return { content: [{ type: 'text', text }], structuredContent: JSON.parse(text) };
}
const fail = (ctx, t) => ({ content: [{ type: 'text', text: redact(t, ctx.cfg) }], isError: true });

const scopeProps = {
  repo: { type: 'string', minLength: 3, maxLength: 200 },
  project: { type: 'string', minLength: 1, maxLength: 64 },
};
const ticketItem = {
  type: 'object',
  properties: { key: { type: 'string', minLength: 1, maxLength: 64 }, issue: { type: 'integer', minimum: 1 } },
  additionalProperties: false,
};
const statusSchema = {
  type: 'object',
  properties: { ...scopeProps, tickets: { type: 'array', minItems: 1, maxItems: TICKETS_MAX, items: ticketItem } },
  required: ['tickets'],
  additionalProperties: false,
};
const stuckSchema = { type: 'object', properties: { ...scopeProps }, additionalProperties: false };

// Exactly one of repo / project, each the right type and length.
function scopeError(a) {
  const has = (k) => a[k] !== undefined;
  if (has('repo') === has('project')) return 'project_or_repo_required';
  for (const k of ['repo', 'project']) {
    const v = a[k];
    if (v === undefined) continue;
    const s = scopeProps[k];
    if (typeof v !== 'string' || v.length < s.minLength || v.length > s.maxLength) return `invalid_arguments: ${k}`;
  }
  return null;
}
// The tickets list: 1..50 items, each exactly one of key (1..64 chars) or
// issue (integer >= 1), nothing else. The registry's checks do not read arrays.
function ticketsError(list) {
  if (!Array.isArray(list) || list.length < 1 || list.length > TICKETS_MAX) return 'invalid_arguments: tickets';
  for (const [i, t] of list.entries()) {
    const p = `tickets[${i}]`;
    if (!isPlain(t)) return `invalid_arguments: ${p}`;
    for (const k of Object.keys(t)) if (!(k in ticketItem.properties)) return `invalid_arguments: ${p}.${k}`;
    if ((t.key === undefined) === (t.issue === undefined)) return `invalid_arguments: ${p}`;
    if (t.key !== undefined && (typeof t.key !== 'string' || t.key.length < 1 || t.key.length > 64)) return `invalid_arguments: ${p}.key`;
    if (t.issue !== undefined && !(Number.isInteger(t.issue) && t.issue >= 1)) return `invalid_arguments: ${p}.issue`;
  }
  return null;
}

const scopeQuery = (a) => (a.project !== undefined
  ? `project=${encodeURIComponent(a.project)}`
  : `repo=${encodeURIComponent(a.repo.trim())}`);

// One console GET -> the answer, or a failed reply.
async function read(ctx, route, path) {
  const r = await (ctx.consoleFetch ?? consoleFetch)(ctx.cfg, 'GET', path);
  if (!r.ok) return { err: fail(ctx, r.status === 404 ? `console route not available: ${route}` : r.error) };
  if (!isPlain(r.data) || !Array.isArray(r.data.tickets)) return { err: fail(ctx, `bad_payload: ${route}`) };
  return { data: r.data };
}

// The newest commit date on each ticket's branch, in parallel, capped.
async function withCommits(ctx, data) {
  const gh = ctx.github ?? githubConfig(process.env);
  const cap = intKnob(ctx.env ?? process.env, 'HARNESS_MCP_TICKET_STATUS_COMMIT_READS', COMMIT_READS_DEFAULT);
  const repo = typeof data.repo === 'string' && REPO_RE.test(data.repo) ? data.repo : null;
  let made = 0;
  let skipped = 0;
  const tickets = await Promise.all(data.tickets.map(async (t) => {
    if (!isPlain(t)) return t;
    const branch = typeof t.branch === 'string' && t.branch ? t.branch : null;
    if (!branch) return { ...t, last_commit_at: null, commit_source: 'no_branch' };
    if (!repo) return { ...t, last_commit_at: null, commit_source: 'no_repo' };
    if (made >= cap) { skipped += 1; return { ...t, last_commit_at: null, commit_source: 'skipped_cap' }; }
    made += 1;
    const r = await githubFetch(gh, `/repos/${repo}/commits?sha=${encodeURIComponent(branch)}&per_page=1`);
    if (!r.ok) {
      const source = r.error === 'github_auth_not_configured' ? r.error : `github_error:${r.error}`;
      return { ...t, last_commit_at: null, commit_source: source };
    }
    const c = Array.isArray(r.data) ? r.data[0] : null;
    const at = c?.commit?.committer?.date ?? c?.commit?.author?.date ?? null;
    return { ...t, last_commit_at: typeof at === 'string' ? at : null, commit_source: 'github' };
  }));
  return { ...data, tickets, commit_reads: { cap, made, skipped } };
}

async function ticketStatus(a, ctx) {
  const params = a.tickets.map((t) => (t.key !== undefined
    ? `key=${encodeURIComponent(t.key)}`
    : `issue=${t.issue}`));
  const path = `${ROUTE}?${scopeQuery(a)}&${params.join('&')}`;
  const { err, data } = await read(ctx, ROUTE, path);
  if (err) return err;
  return reply(ctx, await withCommits(ctx, data));
}

async function stuckTickets(a, ctx) {
  const { err, data } = await read(ctx, STUCK_ROUTE, `${STUCK_ROUTE}?${scopeQuery(a)}`);
  if (err) return err;
  return reply(ctx, await withCommits(ctx, data));
}

const FIELDS = 'state (queued, held, spawning, running with its stage, in_resolver with its rung, pr_open, merged, abandoned, stopped or not_known), machine and spawn time, last checkpoint, the last commit time on its branch, attempt history with outcome codes, what it waits on (each with its own state) and fresh_at';

export const tools = [
  {
    name: 'ticket_status',
    description: `The live status of one or more tickets of a repo or project, read from the hub's rows at call time (never the pipeline snapshot). Name each ticket by key or issue number. Per ticket: ${FIELDS}.`,
    kind: 'read',
    inputSchema: statusSchema,
    precheck: (a) => scopeError(a) ?? ticketsError(a.tickets),
    handler: ticketStatus,
  },
  {
    name: 'stuck_tickets',
    description: `The queued or claimed tickets of a repo or project with no activity for longer than the ticket_status.stuck_min settings row (default 90 minutes), oldest first, with the same fields as ticket_status: ${FIELDS}.`,
    kind: 'read',
    inputSchema: stuckSchema,
    precheck: (a) => scopeError(a),
    handler: stuckTickets,
  },
];
