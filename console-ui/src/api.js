// Same-origin client for /api/dash/*. In production the Pages Functions proxy
// in functions/ forwards to the worker, so the `dash` cookie rides along and
// there is no CORS and no bearer flow in the browser.

import { ROUTING_CHANGES_LIMIT } from './lib/routing.js';
import { FLAKES_LIMIT } from './lib/ci-health.js';
import { BATCHES_LIMIT } from './lib/ci-batches.js';
import { HOLD_LEDGER_KIND, holdKey } from './lib/ticket-hold.js';
import { QUEUE_LIMIT } from './lib/queue-panel.js';
import { ideasApi } from './lib/roadmap-api/ideas.js';
import { boardApi } from './lib/roadmap-api/board.js';
import { wavesApi } from './lib/roadmap-api/waves.js';
import { waveFileApi } from './lib/roadmap-api/wave-file.js';
import { aiAccountsApi } from './lib/ai-accounts.js';

export class AuthError extends Error {
  constructor() {
    super('unauthorized');
    this.name = 'AuthError';
  }
}

async function request(path, init) {
  let res;
  try {
    res = await fetch(path, { credentials: 'same-origin', ...init });
  } catch (e) {
    throw new Error('network unreachable');
  }
  // 403 is the documented unauthenticated answer; a 404 carrying the same
  // error body is the other shape the worker can produce off-cookie.
  let body = null;
  const text = await res.text();
  if (text) {
    try { body = JSON.parse(text); } catch { body = null; }
  }
  // BH-5750: the box-commands owner gate answers 403 {error:"owner_only"} to
  // a signed-in session that is not an owner. That is a refusal to show, not
  // a lost session, so it is the one 403 that is not an AuthError.
  if ((res.status === 403 && !(body && body.error === 'owner_only'))
    || (res.status === 404 && body && body.error === 'unauthorized')) {
    throw new AuthError();
  }
  if (!res.ok) {
    const reason = body && body.error ? body.error : `http_${res.status}`;
    const err = new Error(reason);
    err.status = res.status;
    // The parsed body rides along: a 409 from the model-routes guard says
    // WHICH scope moved (`stale`), and a status code alone cannot (BH-1563).
    err.body = body;
    throw err;
  }
  if (body === null) throw new Error('bad response');
  return body;
}

const get = (path) => request(path);

// A worker path (/api/x) as the coord proxy's path (/api/coord/x): the proxy
// forwards /api/coord/<rest> to the worker's /api/<rest>.
const coordPath = (workerPath) => '/api/coord' + workerPath.replace(/^\/api(?=\/)/, '');

const post = (path, payload) =>
  request(path, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(payload)
  });

// Map a box_console_commands row onto the {status, command, log} shape that
// logOutcome reads. The row may come bare or wrapped as {command} / {row}. An
// unknown status stays pending so pollCommand's timeout still ends it, and a
// body that does not parse to an object is fetch_failed, never an empty file.
function rowToLogs(payload, id) {
  const row = [payload, payload && payload.command, payload && payload.row]
    .find((r) => r && typeof r.status === 'string');
  if (!row) return { status: 'pending' };
  const failed = { status: 'ready', command: { id, result: 'fetch_failed' } };
  if (row.status === 'expired') return failed;
  if (row.status !== 'done' && row.status !== 'failed') return { status: 'pending' };
  let log = null;
  try { log = JSON.parse(row.body); } catch { log = null; }
  if (!log || typeof log !== 'object') return failed;
  return { status: 'ready', command: { id, result: row.result }, log };
}

// How many merged builds the SHIPPED column asks for. Exported so the test and
// the request agree on one number rather than two copies of "50".
export const PIPELINE_SHIPPED_LIMIT = 50;

export const api = {
  fleet: () => get('/api/dash/fleet'),
  machines: () => get('/api/dash/machines'),
  // Participant machines (BH-5353), through the coord proxy. A decision is
  // approve | deny | revoke; the proxy stamps the actor and adds the lead token.
  participants: () => get(coordPath('/api/participants')),
  participant: (id) => get(coordPath(`/api/participants/${encodeURIComponent(id)}`)),
  participantDecide: (id, verb, body = {}) =>
    post(coordPath(`/api/participants/${encodeURIComponent(id)}/${verb}`), body),
  projects: () => get('/api/dash/projects'),
  project: (p) => get(`/api/dash/p/${encodeURIComponent(p)}`),
  run: (id) => get(`/api/dash/runs/${encodeURIComponent(id)}`),
  build: (id) => get(`/api/dash/builds/${encodeURIComponent(id)}`),
  prs: (p, opts = {}) =>
    get(`/api/dash/prs/${encodeURIComponent(p)}?limit=${opts.limit || 20}${opts.checks ? '&checks=1' : ''}`),
  pr: (p, n) => get(`/api/dash/pr/${encodeURIComponent(p)}/${encodeURIComponent(n)}`),
  // `include=archived` is the console's own parameter, not the worker's: the
  // Pages Function at functions/api/dash/kanban/pipeline.js hides dead rows
  // past the archive window by default and returns the whole column, flagged,
  // when this is set. Nothing is deleted either way.
  // `shipped_limit` is a RENDERING bound, not a data one. The worker's default
  // is "everything merged in the last 14 days", and five fleet repos merged
  // ~313 PRs in the last fortnight — a SHIPPED column of a few hundred cards in
  // a `.kb__col` that has no max-height. Fifty is what a column can show; the
  // worker sends counts.merged_deployed_total alongside it, so the caveat reads
  // "showing 50 of 313" and nothing is hidden without saying so.
  pipeline: (p, opts = {}) => {
    const q = new URLSearchParams();
    if (p) q.set('project', p);
    if (opts.includeArchived) q.set('include', 'archived');
    q.set('shipped_limit', String(opts.shippedLimit || PIPELINE_SHIPPED_LIMIT));
    const s = q.toString();
    return get(`/api/dash/kanban/pipeline${s ? `?${s}` : ''}`);
  },
  // BH-6980: the newest scheduler tick's verdicts (worker/jobs/src/routes/scheduler.js).
  schedulerReady: (p) => get('/api/coord/scheduler/ready?project=' + encodeURIComponent(p)),
  // BH-6980: a project's dependency edges, LIMIT 500 (worker/jobs/src/routes/ticket-edges.js).
  ticketEdges: (p) => get('/api/coord/ticket-edges?project=' + encodeURIComponent(p)),
  // The hub's own ticket snapshot: ONE call carrying every OS board, instead of
  // four live calls out to the client board APIs. It is a snapshot, so its
  // generated_at_epoch (SECONDS) is rendered alongside it.
  ticketsSnapshot: () => get('/api/dash/tickets-snapshot'),
  // Two reads, and the cursor semantics differ between them — mixing their
  // cursors is the bug to avoid:
  //   no target  -> every thread, ONE global `last_id` (guaranteed contract)
  //   ?target=X  -> that thread only, and `last_id` is then PER-TARGET, so it
  //                 must never be fed back as a shared cursor or the next tab
  //                 starts too high and silently skips everything below it.
  // The screen uses the untargeted read: one request covers every thread, so
  // per-target unread dots are exact and immediate rather than lagging behind a
  // rotation. Its cursor is kept under the reserved ALL_THREADS key.
  chat: (since = 0, target = null) =>
    get(`/api/dash/chat?since=${encodeURIComponent(since)}${target ? `&target=${encodeURIComponent(target)}` : ''}`),
  // `target` is omitted for the orchestrator so a POST to the default target is
  // byte-identical to the pre-target contract.
  sendChat: (text, target) =>
    post('/api/dash/chat', target && target !== 'orchestrator' ? { text, target } : { text }),
  commands: (limit = 50) => get(`/api/dash/commands?limit=${limit}`),
  costs: () => get('/api/dash/costs'),
  // Meter-anchored cost, through the SAME coord proxy DORA uses (it forwards
  // any GET, so no new Pages Function). Computed in the worker on purpose: the
  // factor is money arithmetic, and a second copy of it in a browser would
  // eventually quote a different dollar figure for the same PR.
  costAnchored: (opts = {}) => {
    const q = new URLSearchParams();
    if (opts.day) q.set('day', opts.day);
    else q.set('window', opts.window || '24h');
    if (opts.limit) q.set('limit', String(opts.limit));
    return get(`/api/coord/metrics/cost-anchored?${q.toString()}`);
  },
  // Per-account usage from cost_rows (BH-167), same coord proxy as costAnchored.
  accountUsage: (window = '5h') => get('/api/coord/metrics/account-usage?window=' + encodeURIComponent(window)),
  // Each lane's spend today against its alert line and ceiling (BH-6174), same
  // coord proxy. No day = the worker's UTC today.
  laneSpend: (day) => get('/api/coord/metrics/lane-spend' + (day ? '?day=' + encodeURIComponent(day) : '')),
  // Newest hourly utilization snapshot per project (BH-4011), same coord proxy.
  utilization: () => get('/api/coord/utilization'),
  // Spend grouped by project/stage/runner/model/billing/ticket (BH-3557). A
  // filter present as '' is sent as `k=` (the worker reads IS NULL); null and
  // undefined are dropped.
  costBreakdown: (params = {}) => {
    const q = new URLSearchParams();
    for (const k of ['since', 'until', 'group', 'limit', 'project', 'stage', 'runner', 'model', 'billing_mode', 'ticket']) {
      if (params[k] !== null && params[k] !== undefined) q.set(k, String(params[k]));
    }
    return get('/api/coord/metrics/cost-breakdown?' + q.toString());
  },
  // Triage tickets paid for unchanged input, per day and project (BH-3926).
  triagePaidUnchanged: (days = 14) => get('/api/coord/metrics/triage-paid-unchanged?days=' + encodeURIComponent(days)),
  // BLOCK findings per week and category, and the rows behind one cell (BH-5806).
  blockFindingsWeekly: (weeks = 8) => get('/api/coord/block-findings/weekly?weeks=' + encodeURIComponent(weeks)),
  blockFindings: ({ category, week, limit = 200 } = {}) => {
    const q = new URLSearchParams();
    if (category) q.set('category', category);
    if (week) q.set('week', week);
    q.set('limit', String(limit));
    return get('/api/coord/block-findings?' + q.toString());
  },
  // The weekly lesson digest: BLOCK rate overall and per category, the lessons (BH-5808).
  lessonsDigest: (days = 7) => get('/api/coord/lessons/digest?days=' + encodeURIComponent(days)),
  // BH-2647: one row per credential (OAuth / GH App) with its live leases; read-only.
  tokenHealth: () => get('/api/coord/account-leases/health'),
  // Calls per distinct input by lane (BH-2537), and the individual cost rows
  // behind one input, same coord proxy.
  laneDedup: (days = 7) => get('/api/coord/metrics/lane-dedup?days=' + encodeURIComponent(days)),
  costRows: (params = {}) => {
    const q = new URLSearchParams();
    for (const k of ['guard_fp', 'lane_id', 'since', 'limit']) {
      const v = params[k];
      if (v !== null && v !== undefined && v !== '') q.set(k, String(v));
    }
    return get(`/api/coord/metrics/cost-rows?${q.toString()}`);
  },
  // The coordination DB (phase 3), through the Pages proxy in
  // functions/api/coord/. Different worker, different bearer, same origin and
  // the same `dash` session — see that file for why the check is delegated.
  jobs: (opts = {}) => {
    const q = new URLSearchParams();
    if (opts.project) q.set('project', opts.project);
    if (opts.status) q.set('status', opts.status);
    if (opts.kind) q.set('kind', opts.kind);
    // One ticket's rows (BH-4990, the /t/<KEY> page). The worker filters on it.
    if (opts.ticket_id) q.set('ticket_id', opts.ticket_id);
    q.set('limit', String(opts.limit || 100));
    return get(`/api/coord/jobs?${q.toString()}`);
  },
  job: (id) => get(`/api/coord/jobs/${encodeURIComponent(id)}`),
  // BH-2323: operator RETRY / REQUEUE on one job. No actor in the body: the
  // coord proxy stamps it. Answers are job-retry.js's {decision, reason, ...}.
  retryJob: (id, body) => post(`/api/coord/jobs/${encodeURIComponent(id)}/retry`, body),
  requeueJob: (id, body) => post(`/api/coord/jobs/${encodeURIComponent(id)}/requeue`, body),
  abandonJob: (id, body) => post(`/api/coord/jobs/${encodeURIComponent(id)}/abandon`, body),
  // BH-2510: the Project page's QUEUES panel. Three reads at the worker's own
  // clamps, and the two actions (actor stamped by the proxy, reason required).
  // The actions answer 501 until a BH-2510 sibling lands them.
  queueRows: (project, status) => get(`/api/coord/queue?project=${encodeURIComponent(project)}&status=${encodeURIComponent(status)}&limit=${QUEUE_LIMIT}`),
  deployQueueRows: (project, status) => get(`/api/coord/deploy-queue?project=${encodeURIComponent(project)}&status=${encodeURIComponent(status)}&limit=${QUEUE_LIMIT}`),
  mergeTrains: (project, limit) => get(`/api/coord/merge-trains?project=${encodeURIComponent(project)}&limit=${encodeURIComponent(limit)}`),
  queueAction: (body) => post('/api/coord/queue/action', body),
  deployQueueAction: (body) => post('/api/coord/deploy-queue/action', body),
  // A PR's head-bound review verdicts (BH-1952), GET /api/verdicts on the jobs
  // worker. `head` only goes out when it is a full 40-hex sha: the worker then
  // adds `standing` for THAT head, and a partial one would be a 400.
  verdicts: (repo, pr, head) => {
    const q = new URLSearchParams({ repo, pr: String(pr) });
    if (typeof head === 'string' && /^[0-9a-f]{40}$/.test(head)) q.set('head', head);
    return get(`/api/coord/verdicts?${q.toString()}`);
  },
  // The lead's protected-path globs for one repo (BH-4147, GET/PUT
  // /api/lead-protected-paths on the jobs worker). The proxy stamps added_by.
  protectedPaths: (repo) => get(`/api/coord/lead-protected-paths?repo=${encodeURIComponent(repo)}`),
  // BH-4957: the /lead-reviews screen's reads. The gate facts and the
  // worklist are per repo (worker/jobs/src/routes/pr-state.js, BH-4953); the
  // event log is newest first and `since` filters its `at` column.
  prNeedsReview: (repo, limit) => {
    const q = new URLSearchParams({ repo });
    if (limit) q.set('limit', String(limit));
    return get(`/api/coord/pr-state/needs-review?${q.toString()}`);
  },
  prGate: (repo) => get(`/api/coord/pr-state/gate?${new URLSearchParams({ repo }).toString()}`),
  prStateEvents: ({ since, limit } = {}) => {
    const q = new URLSearchParams();
    if (since) q.set('since', since);
    if (limit) q.set('limit', String(limit));
    return get(`/api/coord/pr-state-events?${q.toString()}`);
  },
  // lead_review_requests rows, oldest first; {requests, truncated}.
  leadReviews: ({ status, repo, limit } = {}) => {
    const q = new URLSearchParams();
    if (status) q.set('status', status);
    if (repo) q.set('repo', repo);
    if (limit) q.set('limit', String(limit));
    return get(`/api/coord/lead-reviews?${q.toString()}`);
  },
  // The projects table ({projects:[{project, repo, ...}]}): repo -> project.
  coordProjects: () => get('/api/coord/projects'),
  setProtectedPath: ({ repo, glob, op }) =>
    request('/api/coord/lead-protected-paths', {
      method: 'PUT',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ repo, glob, op })
    }),
  // The mission view's stream: the job row, its phases, and every stage event
  // with an id ABOVE `since`. Same proxy and same session as api.job — `since`
  // is an event-id cursor, not a time window, and 0 means "from the start", so
  // a screen that has been open for an hour still asks for one page of new
  // rows rather than the whole build again every 5 seconds.
  live: (id, since = 0) =>
    get(`/api/coord/jobs/${encodeURIComponent(id)}/live?since=${encodeURIComponent(since)}`),
  // ONE attempt's conversation. Deliberately a separate call from api.job: the
  // detail response carries only the transcript INDEX, because that page polls
  // every 20s and a job with four attempts would otherwise ship ~600KB twice a
  // minute to draw headings nobody opened. A body is fetched on click.
  jobTranscript: (id, phaseId, attempt) =>
    get(`/api/coord/jobs/${encodeURIComponent(id)}/transcript`
      + `?phase_id=${encodeURIComponent(phaseId)}&attempt=${encodeURIComponent(attempt)}`),
  burn: (days = 14) => get(`/api/coord/burn?days=${encodeURIComponent(days)}`),
  // BH-2543: pre-plan adoption for one project (route shape in bin/lib/preplan-cadence.sh).
  preplanAdoption: (p, days) =>
    get(`/api/coord/preplans/adoption?${new URLSearchParams({ project: p, days: String(days) })}`),
  // BH-5267: the files that conflicted or were rebased most on one project's box.
  conflictHotspots: (project, limit) => get(`/api/coord/conflict-hotspots?project=${encodeURIComponent(project)}&limit=${encodeURIComponent(limit)}`),
  // BH-6061: the Fly idle reaper's last started-machine snapshot and its stops in the last 24 h.
  flyIdle: () => get('/api/coord/fly-idle'),
  // Lane liveness (2026-08-30): what is SUPPOSED to be ticking, and whether it
  // is. Same worker, same proxy, same session as the jobs read above — and the
  // rows arrive with the verdict already computed, so this screen and
  // bin/jobs-watchdog.sh can never disagree about whether a lane is dead.
  lanes: () => get('/api/coord/lanes'),
  // BH-2515: who this session's writes are recorded as ({actor, access,
  // email}), answered by the coord Pages function itself, not the worker.
  whoami: () => get('/api/coord/whoami'),
  // The fleet's alert table (2026-09-19), same worker, same proxy and the same
  // session as the lanes read above. `state`, `family`, `box` and `component` are the
  // worker's own filters — the screen never filters rows it already has, or the
  // count it shows would describe a different set than the one it asked for.
  // `limit` is a RENDERING bound, not a data one: the worker answers
  // `truncated: true` when it bit, and the section says so.
  alerts: (opts = {}) => {
    const q = new URLSearchParams();
    for (const k of ['state', 'family', 'box', 'component']) if (opts[k]) q.set(k, String(opts[k]));
    if (opts.limit) q.set('limit', String(opts.limit));
    const qs = q.toString();
    return get(`/api/coord/alerts${qs ? `?${qs}` : ''}`);
  },
  // One operator action on one alert row (BH-2324). `action` is checked here
  // for the same reason lanesAll checks its word: a typo must be a refusal in
  // the browser, not a request the worker answers about something else.
  alertAction: async (id, action, note) => {
    if (!['ack', 'snooze', 'resolve', 'note'].includes(action)) {
      throw new Error(`alertAction takes ack, snooze, resolve or note, not ${action}`);
    }
    return post('/api/coord/alerts/actions', { id, action, ...(note ? { note } : {}) });
  },
  // The action log for one alert. `limit` rides only when given; the worker
  // owns the default and the clamp.
  alertActions: (id, limit) => {
    const q = new URLSearchParams();
    q.set('id', String(id));
    if (limit) q.set('limit', String(limit));
    return get(`/api/coord/alerts/actions?${q}`);
  },
  // What bin/component-watch.sh decided on open alerts (BH-6972), by ONE of
  // `alert_id` or `component`. The worker refuses zero or two keys with a 400;
  // the check here makes that a refusal in the browser, before a request.
  // `limit` rides only when given; the worker owns the default and the clamp.
  alertDecisions: async (opts = {}) => {
    const keys = ['alert_id', 'component'].filter((k) => opts[k]);
    if (keys.length !== 1) throw new Error('alertDecisions takes exactly one of alert_id or component');
    const q = new URLSearchParams();
    q.set(keys[0], String(opts[keys[0]]));
    if (opts.limit) q.set('limit', String(opts.limit));
    return get(`/api/coord/alerts/decisions?${q}`);
  },
  // DORA, through the same coord proxy (it forwards any GET, so no new Pages
  // Function). The metrics are computed IN THE WORKER on purpose: the payload
  // carries the p50/p90 and the evidence string for each, and a second
  // implementation here would eventually disagree with the endpoint about what
  // the fleet's lead time is.
  dora: (opts = {}) => {
    const q = new URLSearchParams();
    if (opts.project) q.set('project', opts.project);
    q.set('days', String(opts.days || 14));
    return get(`/api/coord/metrics/dora?${q.toString()}`);
  },
  // The lane control plane (#1132), same worker and same proxy as the jobs read
  // above. The REGISTRY is catalog/lanes.json as the worker baked it — what
  // exists and what each knob may be set to. The STATUS is what is actually
  // thrown, what each lane last did, and what it cost. Two calls because the
  // first changes only on a deploy and the second is polled.
  // The worker answers `{ registry: <catalog/lanes.json>, as_of }`; every
  // reader wants the catalog itself (`.lanes`). Unwrapped here, so the Settings
  // screens see declared lanes rather than drawing each one NOT IN REGISTRY
  // (found by the BH-2327 drive against the real route).
  lanesRegistry: async () => {
    const body = await get('/api/coord/lanes/registry');
    return body && body.registry && Array.isArray(body.registry.lanes) ? body.registry : body;
  },
  lanesStatus: (project) =>
    get(`/api/coord/lanes/status${project ? `?project=${encodeURIComponent(project)}` : ''}`),
  // The master switch. `which` is checked here rather than interpolated blindly:
  // this helper builds a POST path, and a caller's typo must be a refusal in the
  // browser, not an unknown route the operator reads as "nothing happened".
  lanesAll: async (which, body) => {
    if (which !== 'all-off' && which !== 'all-on') {
      throw new Error(`lanesAll takes all-off or all-on, not ${which}`);
    }
    return post(`/api/coord/lanes/${which}`, body);
  },
  coordFlags: () => get('/api/coord/flags'),
  // The live pause rows (BH-1672), same worker and same proxy (it forwards any
  // GET). Writes do NOT go this way: END and PAUSE are commands through
  // api.action, because the poller must also clear or set the box's flag file.
  pauses: () => get('/api/coord/pauses?active=1'),
  setCoordFlag: (name, active, reason) =>
    request('/api/coord/flags', {
      method: 'PUT',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ name, active: active ? 1 : 0, actor: 'console', reason })
    }),
  // BH-5643: a flag write with an optional value (a wip-limit-<p> row holds a
  // number). The worker takes a string only, so a value is sent as one, and no
  // value key at all when there is none. The coord proxy stamps actor.
  setFlag: (name, active, value, reason) => {
    const body = { name, active: active ? 1 : 0, reason };
    if (value !== null && value !== undefined) body.value = String(value);
    return request('/api/coord/flags', {
      method: 'PUT',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify(body)
    });
  },
  // BH-4153: the /flags screen. The merged list from both stores (optional
  // scope/prefix/active filters), a SET of one (scope, name) row, and its soft
  // CLEAR. No actor goes out on either write: the coord proxy stamps it.
  coordFlagsAll: (params = {}) => {
    const q = new URLSearchParams(Object.entries(params || {})
      .filter(([, v]) => v !== undefined && v !== null && v !== '')).toString();
    return get(`/api/coord/flags${q ? `?${q}` : ''}`);
  },
  setCoordFlagRow: (body) =>
    request('/api/coord/flags', {
      method: 'PUT',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify(body)
    }),
  clearCoordFlag: (q) => request(`/api/coord/flags?${q}`, { method: 'DELETE' }),
  // BH-6825: the LEARNING panel on /staff/:agent. One agent's windows and
  // proposal, the outcome rows behind one count (empty params dropped), and
  // the human approve or void of a pending promotion (the proxy stamps actor).
  staffLearning: (agent) => get(coordPath(`/api/staff/learning?agent=${encodeURIComponent(agent)}`)),
  staffLearningOutcomes: (agent, { days, outcome, before, limit } = {}) => {
    const q = new URLSearchParams(Object.entries({ agent, days, outcome, before, limit })
      .filter(([, v]) => v !== undefined && v !== null && v !== '')).toString();
    return get(coordPath(`/api/staff/learning/outcomes?${q}`));
  },
  staffDecidePromotion: (body) => post(coordPath('/api/staff/promotions/decide'), body),
  // BH-5567: the /staff screen's reads. Its kill switch writes through the two
  // flag calls above.
  staffRoster: () => get(coordPath('/api/staff/roster')),
  staffFindings: (agent) => get(coordPath(`/api/staff/findings?agent=${encodeURIComponent(agent)}`)),
  staffFinding: (id) => get(coordPath(`/api/staff/finding?id=${encodeURIComponent(id)}`)),
  // BH-6824: the agent page's AUTONOMY panel. The read is the worker's
  // GET /api/staff/autonomy; the two writes go through the coord proxy, which
  // stamps the actor and refuses a blank reason (coord-writes.d/6824-*).
  staffAutonomy: (agent) => get(coordPath(`/api/staff/autonomy?agent=${encodeURIComponent(agent)}`)),
  staffSetAutonomy: (body) => post(coordPath('/api/staff/agents/autonomy'), body),
  staffSetDelegation: (body) => post(coordPath('/api/staff/classes/delegation'), body),
  // BH-6823: one staff agent's chat thread (newest first, `before` the id
  // cursor `next` of the last page) and a send. The proxy stamps the actor.
  staffChat: (agent, before) => get(coordPath(`/api/staff/chat?agent=${encodeURIComponent(agent)}${
    before === undefined || before === null ? '' : `&before=${encodeURIComponent(before)}`}`)),
  staffChatSend: (body) => post(coordPath('/api/staff/chat'), body),
  // BH-6822: the agent page's timeline (one page, `before` the cursor of the
  // last row shown) and one tick with its cost rows.
  staffActivity: (agent, { before, limit } = {}) => {
    const q = new URLSearchParams(Object.entries({ before, limit })
      .filter(([, v]) => v !== undefined && v !== null && v !== '')).toString();
    return get(coordPath(`/api/staff/agent/${encodeURIComponent(agent)}/activity${q ? `?${q}` : ''}`));
  },
  staffTick: (id) => get(coordPath(`/api/staff/tick?id=${encodeURIComponent(id)}`)),
  // Hub recovery (BH-1909). The worker routes are BH-1942 contract stubs that
  // answer 501 until #1943/#1944 land. The coord proxy forwards the GETs; its
  // write allowlist does not include the two POSTs yet, so they answer 405 there
  // until #1945/#1946 add them.
  hubRecovery: () => get('/api/coord/hub/recovery'),
  promoteHub: (body) => post('/api/coord/hub/promote', body),
  restoreLab: (body) => post('/api/coord/hub/restore-lab', body),
  restoreLabRuns: () => get('/api/coord/hub/restore-lab'),
  // BH-2519.0 contract: the standby verify queue. Its worker routes are empty
  // until BH-2519's verify slice lands.
  standbyVerify: (body) => post('/api/coord/hub/standby/verify', body),
  standbyVerifyRuns: () => get('/api/coord/hub/standby/verify'),
  // BH-2518: a box/machine op request, and the recent commands (optionally one box's).
  boxCommand: (body) => post('/api/coord/box-commands', body),
  boxCommands: (box) => get('/api/coord/box-commands' + (box ? '?box=' + encodeURIComponent(box) : '')),
  // BH-5750 C4: the hub's last Orgo computer list per account (ORGO STATE).
  orgoComputers: () => get('/api/coord/orgo-computers'),
  // BH-2521: the SEED REGISTRY plan/apply/runs and the CHAT BINDINGS read/edit.
  // No actor goes out: the coord proxy stamps it. BH-2995: the apply and the
  // edit carry the dialog's reason, which the proxy requires.
  seedPlan: () => get('/api/coord/settings/seed-registry/plan'),
  seedApply: (plan_fp, reason) => post('/api/coord/settings/seed-registry/apply', { plan_fp, reason }),
  seedRuns: () => get('/api/coord/settings/seed-registry/runs'),
  telegramTopics: () => get('/api/coord/telegram-topics'),
  telegramTopicSet: (project, thread_id, reason) =>
    request('/api/coord/telegram-topics', {
      method: 'PUT',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ project, thread_id, reason })
    }),
  // BH-2329.3: live main-red freezes, and the audited CLEAR of one.
  mainRed: () => get('/api/coord/main-red'),
  clearMainRed: (body) => post('/api/coord/main-red/clear', body),
  // The pre-call guard's counter (K3), one row per (project, stage, fp) in the
  // window. The worker caps it at 200 keys and says nothing when it bit.
  callGuard: (hours = 24) => get(`/api/coord/call-guard?hours=${encodeURIComponent(hours)}`),
  // The audited reset (BH-2331). No actor goes out: the coord proxy stamps it,
  // because who did a write is the proxy's to say, not the browser's.
  resetCallGuard: ({ project, stage, fp, reason }) =>
    request(`/api/coord/call-guard?${new URLSearchParams({ project, stage, fp, reason }).toString()}`, {
      method: 'DELETE'
    }),
  // BH-2634: the /ci screen's reads, and the audited quarantine toggle. No
  // actor goes out: the coord proxy stamps it.
  ciHealth: (repo) => get(`/api/coord/ci-health${repo ? `?${new URLSearchParams({ repo })}` : ''}`),
  // BH-5374: the queue waste ledger's per-day rollup (worker routes/queue-batch-minutes.js).
  queueBatchMinutesDaily: (days) => get(`/api/coord/queue-batch-minutes/daily?${new URLSearchParams({ days: String(days) })}`),
  flakes: (repo, since) => get(`/api/coord/metrics/flakes?${new URLSearchParams({
    ...(repo ? { repo } : {}), ...(since ? { since } : {}), limit: String(FLAKES_LIMIT)
  })}`),
  // BH-4972: the merge-queue batch ledger (BH-4971's GET /api/ci-batches).
  ciBatches: (repo, since) => get(`/api/coord/ci-batches?${new URLSearchParams({
    ...(repo ? { repo } : {}), since, limit: String(BATCHES_LIMIT)
  })}`),
  // BH-4981: one row per culprit merge the main-red safety net reverted, newest
  // first, for the /ci MAIN-RED REVERTS section. A plain ledger list read.
  mainRedAttrib: (limit = 200) => get(coordPath(`/api/ledger?kind=main_red_attrib&limit=${limit}`)),
  flakeQuarantine: (repo) => get(`/api/coord/metrics/flakes/quarantine?${new URLSearchParams({ ...(repo ? { repo } : {}), active: '1' })}`),
  flakeQuarantineChanges: (repo, test) =>
    get(`/api/coord/metrics/flakes/quarantine/changes?${new URLSearchParams({ repo, test, limit: '50' })}`),
  // BH-5369: the suite ledger's saved minutes per day, and one day's runs.
  suiteReuseSaved: (days, repo) =>
    get(coordPath(`/api/suite-results/saved?${new URLSearchParams({ days: String(days), ...(repo ? { repo } : {}) })}`)),
  suiteReuseRuns: (day, repo, cls) =>
    get(coordPath(`/api/suite-results/runs?${new URLSearchParams({ day, ...(repo ? { repo } : {}), ...(cls ? { class: cls } : {}) })}`)),
  putFlakeQuarantine: ({ repo, test, active, reason }) =>
    request('/api/coord/metrics/flakes/quarantine', {
      method: 'PUT',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ repo, test, active, reason })
    }),
  // Every settings row (BH-1657's PROJECT ACCOUNTS reads the account.* rows).
  settings: () => get('/api/coord/settings'),
  // A knob row on the settings table. The key is built in lib/settings.js and
  // is lowercase there for a reason the worker enforces — see settingKey().
  setCoordSetting: (body) =>
    request('/api/coord/settings', {
      method: 'PUT',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify(body)
    }),
  // BH-4846: delete a custom theme row. The proxy admits ui.theme.custom.<slug>
  // only, and stamps the actor; the worker audits it in config_changes.
  deleteCoordSetting: (key) =>
    request(`/api/coord/settings/${encodeURIComponent(key)}`, { method: 'DELETE' }),
  // CONTROLS (BH-2513): one config kind's rows, and one row's write, through
  // the same coord proxy. `desc` is a CONTROL_KINDS entry, whose paths are the
  // worker's (/api/review-gate); the proxy adds that /api back itself. No
  // actor here: the proxy stamps it.
  controlsList: (desc) => get(coordPath(desc.path)),
  controlsPut: (desc, body) =>
    request(coordPath(desc.putPath), {
      method: 'PUT',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify(body)
    }),
  // A ticket's hold row (BH-2326), through the coord proxy. The worker 404s
  // `{error:'not found'}` for an absent row, which is a real answer (not held),
  // so that one reply resolves to `{ledger:null}`. Anything else still throws,
  // and the caller reads that as unknown, never as not held.
  ticketHold: (project, n) =>
    get(coordPath(`/api/ledger?kind=${HOLD_LEDGER_KIND}&key=${encodeURIComponent(holdKey(project, n))}`))
      .catch((e) => {
        if (e && e.status === 404 && e.body && e.body.error === 'not found') return { ledger: null };
        throw e;
      }),
  // Steer notes (BH-5839), through the coord proxy: the Step in composer's
  // send (the proxy stamps the actor) and the ticket's notes for the echo.
  steer: (body) => post(coordPath('/api/steer'), body),
  steerNotes: (project, ticket) =>
    get(coordPath(`/api/steer?project=${encodeURIComponent(project)}&ticket=${encodeURIComponent(ticket)}`)),
  // Model routes (BH-1510.3), same worker and same proxy as the lane reads
  // above. The list read carries the runner list and per-rung provenance; the
  // one-role read is the resolver's own answer. Prices are model_prices as the
  // worker stores them — per TOKEN; the screen converts to $/1M.
  // `unroutedSince` (BH-2512) adds the stages the cost ledger saw since then
  // with no stage.* route; without it the URL is exactly the old one.
  modelRoutes: (project, unroutedSince) => {
    const q = new URLSearchParams();
    if (project) q.set('project', project);
    if (unroutedSince) q.set('unrouted_since', unroutedSince);
    const qs = q.toString();
    return get(`/api/coord/model-routes${qs ? `?${qs}` : ''}`);
  },
  modelRoute: (role, project) =>
    get(`/api/coord/model-routes/${encodeURIComponent(role)}${project ? `?project=${encodeURIComponent(project)}` : ''}`),
  modelPrices: () => get('/api/coord/model-prices'),
  modelRouteChanges: (opts = {}) => {
    const q = new URLSearchParams();
    q.set('role', opts.role);
    if (opts.project) q.set('project', opts.project);
    if (opts.limit) q.set('limit', String(opts.limit));
    return get(`/api/coord/model-route-changes?${q.toString()}`);
  },
  // The WHOLE ladder, always: the worker replaces (scope, role) in one call.
  putModelRoute: (body) =>
    request('/api/coord/model-routes', {
      method: 'PUT',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify(body)
    }),
  resetModelRoute: (body) => post('/api/coord/model-routes/reset', body),
  // BH-2512: take a role off the hub (tombstoned), and one model's price source.
  removeModelRoute: (body) => post('/api/coord/model-routes/remove', body),
  setModelPriceSource: (body) =>
    request('/api/coord/model-prices/source', {
      method: 'PUT',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify(body)
    }),
  // Builder routing (BH-2328): one project's row (404 = no row), its audit
  // trail, and the row upsert. The coord proxy stamps actor on the PUT.
  routing: (p) => get(`/api/coord/routing/${encodeURIComponent(p)}`),
  // BH-5643: every routing row in one read (worker LIMIT 500), for the Fleet ROUTE column.
  routingAll: () => get('/api/coord/routing'),
  routingChanges: (p, limit = ROUTING_CHANGES_LIMIT) =>
    get(`/api/coord/routing-changes?project=${encodeURIComponent(p)}&limit=${encodeURIComponent(limit)}`),
  putRouting: (body) =>
    request('/api/coord/routing', {
      method: 'PUT',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify(body)
    }),
  // Cost/lane caps as rows (BH-2563): one row's edit and its audit trail. The
  // coord proxy stamps actor on the PUT, so none is sent from here.
  putCostCap: ({ key, value, reason }) =>
    request('/api/coord/cost-caps', {
      method: 'PUT',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ key, value, reason })
    }),
  costCapChanges: ({ key, limit } = {}) => {
    const q = new URLSearchParams();
    if (key) q.set('key', key);
    if (limit) q.set('limit', String(limit));
    const qs = q.toString();
    return get(`/api/coord/cost-cap-changes${qs ? `?${qs}` : ''}`);
  },
  // BH-2375: config_changes, the one audit store, filtered by kind and name
  // (payload in worker/jobs/src/routes/config-changes.js).
  configChanges: ({ kind, name, limit } = {}) => {
    const q = new URLSearchParams();
    if (kind) q.set('kind', kind);
    if (name) q.set('name', name);
    if (limit) q.set('limit', String(limit));
    const qs = q.toString();
    return get(`/api/coord/config-changes${qs ? `?${qs}` : ''}`);
  },
  // One settings row: {key, setting: row|null, source}.
  coordSetting: (key) => get(`/api/coord/settings/${encodeURIComponent(key)}`),
  // BH-2325: the merge queue and the conductor's held pages. The coord proxy
  // forwards the GETs, and its write allowlist admits the PATCH and the release
  // POST (BH-3157), each checked and rebuilt there before it reaches the worker.
  mergeQueue: ({ project, status, limit } = {}) => {
    const q = new URLSearchParams();
    if (project) q.set('project', project);
    if (status) q.set('status', status);
    if (limit) q.set('limit', String(limit));
    const qs = q.toString();
    return get(`/api/coord/merge-queue${qs ? `?${qs}` : ''}`);
  },
  // BH-5667: the live Mergify batches (worker/jobs/src/routes/merge-queue-live.js).
  // The coord proxy forwards the GET as-is. ui/merge-queue-live-data.js polls it.
  mergeQueueLive: ({ project } = {}) =>
    get(coordPath('/api/merge-queue/live') + (project ? `?project=${encodeURIComponent(project)}` : '')),
  // BH-5022: the risk tier of each classified PR head, newest first, read-only.
  // The coord proxy forwards the GET as-is; there is no console write.
  riskTiers: ({ repo, pr, tier, limit } = {}) => {
    const q = new URLSearchParams();
    if (repo) q.set('repo', repo);
    if (pr !== undefined && pr !== null && pr !== '') q.set('pr', String(pr));
    if (tier) q.set('tier', tier);
    if (limit) q.set('limit', String(limit));
    const qs = q.toString();
    return get(`/api/coord/risk-tiers${qs ? `?${qs}` : ''}`);
  },
  // BH-4157: the conductor's iron-law hold on a PR and its ACCEPT rows
  // (worker/jobs/src/routes/ironlaw-accept.js); the write goes through the
  // coord proxy row coord-writes.d/7581-ironlaw-accept.js, which stamps actor.
  ironLawHold: (repo, pr) =>
    get(coordPath(`/api/ironlaw-accept?${new URLSearchParams({ repo, pr: String(pr) }).toString()}`)),
  ironLawAccept: (body) => post(coordPath('/api/ironlaw-accept'), body),
  // BH-5430: the merge-queue break-risk score of each enqueued PR head, newest
  // updated_at first, read-only. The coord proxy forwards the GET as-is.
  queueRisk: ({ repo, pr, route, limit } = {}) => {
    const q = new URLSearchParams();
    if (repo) q.set('repo', repo);
    if (pr !== undefined && pr !== null && pr !== '') q.set('pr', String(pr));
    if (route) q.set('route', route);
    if (limit) q.set('limit', String(limit));
    const qs = q.toString();
    return get(`/api/coord/queue-risk${qs ? `?${qs}` : ''}`);
  },
  setMergeQueue: (body) =>
    request('/api/coord/merge-queue', {
      method: 'PATCH',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify(body)
    }),
  heldPages: (limit) =>
    get(`/api/coord/conductor/held${limit ? `?limit=${encodeURIComponent(limit)}` : ''}`),
  releaseHeldPage: (body) => post('/api/coord/conductor/held/release', body),
  // One SUM over the cost ledger (never a page of rows, which caps and would
  // under-report a busy stage). Every filter is an equality the worker applies.
  llmSpend: (opts = {}) => {
    const q = new URLSearchParams();
    for (const k of ['stage', 'runner', 'project', 'since', 'lane']) if (opts[k]) q.set(k, String(opts[k]));
    return get(`/api/coord/metrics/llm-spend?${q.toString()}`);
  },
  // BH-2553: the LLM sites list and one site's cost rows (stubs until the
  // BH-2540 siblings land; payload in worker/jobs/src/routes/llm-sites.js).
  llmSites: () => get('/api/coord/metrics/llm-sites'),
  llmSiteRows: (id) => get('/api/coord/metrics/llm-sites/rows?site=' + encodeURIComponent(id)),
  // The product stage's proposals, through the Pages proxy in
  // functions/api/ideas/. The console worker has no JSON read for them, so
  // that function reads the rows the worker's own beats wrote — see its header.
  ideas: (opts = {}) => {
    const q = new URLSearchParams();
    if (opts.project) q.set('project', opts.project);
    if (opts.status) q.set('status', opts.status);
    if (opts.limit) q.set('limit', String(opts.limit));
    const qs = q.toString();
    return get(`/api/ideas/proposals${qs ? `?${qs}` : ''}`);
  },
  idea: (project, slug) =>
    get(`/api/ideas/proposals/${encodeURIComponent(project)}/${encodeURIComponent(slug)}`),
  // The outcome + steering view, through the Pages proxy in
  // functions/api/outcomes/. ONE call carrying five tables (outcome findings,
  // the merge ledger, per-PR costs, daily burn, the review-gate rows) because
  // the screen cannot say anything true from any one of them alone — a revert
  // count without the merge count it divides by is not a rate. That function is
  // GET-only: nothing on OUTCOMES writes, least of all its own gate.
  outcomes: () => get('/api/outcomes/summary'),
  // The old cockpit's own views (NOW / HISTORY / NEEDS / the deep half of the
  // per-project page), through the Pages proxy in functions/api/cockpit/. Same
  // reason as ideas: the console worker server-renders those pages and exposes
  // no JSON for them, so that function reads the rows its beats wrote.
  cockpitNow: () => get('/api/cockpit/now'),
  cockpitNeeds: (project) =>
    get(`/api/cockpit/needs${project ? `?project=${encodeURIComponent(project)}` : ''}`),
  // `before` is a run id, not a page number: the ledger grows while you page.
  cockpitHistory: (opts = {}) => {
    const q = new URLSearchParams();
    if (opts.project) q.set('project', opts.project);
    if (opts.kind) q.set('kind', opts.kind);
    if (opts.outcome) q.set('outcome', opts.outcome);
    if (opts.before) q.set('before', String(opts.before));
    q.set('limit', String(opts.limit || 100));
    return get(`/api/cockpit/history?${q.toString()}`);
  },
  cockpitBuildHistory: (opts = {}) => {
    const q = new URLSearchParams();
    if (opts.project) q.set('project', opts.project);
    if (opts.before) q.set('before', String(opts.before));
    q.set('limit', String(opts.limit || 100));
    return get(`/api/cockpit/history/builds?${q.toString()}`);
  },
  cockpitProject: (p) => get(`/api/cockpit/project/${encodeURIComponent(p)}`),
  // The box_console_commands row first, through the coord proxy (BH-2656). A
  // worker that does not serve the route yet answers 404 `unknown endpoint`,
  // and only that falls back to the dash read. An AuthError carries no status,
  // so a 404 `unauthorized` is rethrown with everything else.
  logs: async (commandId) => {
    const id = encodeURIComponent(commandId);
    try {
      return rowToLogs(await get(`/api/coord/box-console-commands/${id}`), commandId);
    } catch (e) {
      if (e.status !== 404) throw e;
      return get(`/api/dash/logs/${id}`);
    }
  },
  action: (payload) => post('/api/dash/action', payload),
  // BH-7243: the roadmap calls, one factory per child ticket
  // (src/lib/roadmap-api/), so no child edits this object.
  ...ideasApi({ get, post, coordPath }),
  ...boardApi({ get, post, coordPath }),
  ...wavesApi({ get, post, coordPath }),
  ...waveFileApi({ get, post, coordPath }),
  // BH-7966: the AI account rows and the envelope status (lib/ai-accounts.js).
  ...aiAccountsApi({ get, post, coordPath })
};

// `project` is mandatory on both fetches and there is no default: an empty or
// unregistered one comes back as a refused beat, i.e. a pane that never fills.
export const LOG_KINDS = ['triage', 'alerts', 'pipeline', 'cost', 'decisions'];
export const ARTIFACT_KINDS = ['plan', 'review', 'security', 'qa', 'evidence', 'pipeline', 'cost', 'context'];
// The hub owns no project of its own but holds the fleet-level logs. Triage is
// per project, so `hub` + `triage` is refused upstream — never offer it.
export const HUB_LOG_KINDS = ['alerts', 'pipeline', 'cost', 'decisions'];

export function fetchLog(project, which) {
  if (!project) throw new Error('project is mandatory for fetch_log');
  return api.action({ type: 'fetch_log', project, which });
}

export function fetchArtifact(project, key, which) {
  if (!project || project === 'hub') throw new Error('fetch_artifact is always project-scoped');
  if (!key) throw new Error('fetch_artifact needs a ticket key');
  return api.action({ type: 'fetch_artifact', project, key, which });
}

// Poll a command id until its tail lands. `ready` can still carry missing:true
// or an error — those are outcomes to render, not failures to swallow.
export function pollCommand(commandId, { onUpdate, intervalMs = 5000, timeoutMs = 180000 }) {
  let stopped = false;
  const startedAt = Date.now();
  const tick = async () => {
    if (stopped) return;
    try {
      const res = await api.logs(commandId);
      if (stopped) return;
      onUpdate(res);
      if (res.status === 'ready' || res.status === 'dead_letter') return;
    } catch (e) {
      if (stopped) return;
      if (e instanceof AuthError) { onUpdate({ status: 'auth' }); return; }
      onUpdate({ status: 'pending', poll_error: e.message });
    }
    if (Date.now() - startedAt > timeoutMs) {
      onUpdate({ status: 'timeout' });
      return;
    }
    setTimeout(tick, intervalMs);
  };
  tick();
  return () => { stopped = true; };
}
