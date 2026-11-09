// The "To do (waiting)" view (BH-9116): every open board ticket that is not in
// flight, with the one reason it waits. Pure: the Pages Function
// (functions/api/dash/kanban/waiting.js) runs it over two reads, the hub's
// ticket snapshot and the jobs worker's POST /api/waiting/state rows.
//
// THE JOIN is on the exact pair (project, key), and on (project, id) for a
// row that recorded the board's internal id. pairKey is the one place a pair
// is built (trimmed, case kept), so a row of project B never answers for a
// ticket of project A that has the same key text.
//
// CANDIDATES. A done ticket is not one. A todo (or unknown status) ticket is
// one unless it is in flight. A review ticket is one only while it waits on the
// client or the requester; any other review ticket is a PR in review, so it is
// in flight. An in_progress ticket is one only when its claim is stale.
// IN FLIGHT: a running job whose heartbeat (or updated_at, with no beat) is at
// most stale_claim_min old, or a claim at most stale_claim_min old.
//
// THE REASON, first match wins (WAITING_REASONS is that order):
//   not-triaged          no verdict from either source, and not waiting on the client
//   needs-clarification  verdict needs_clarification, or the board waits on client/requester
//   blocked-by           a hard parent edge whose parent is open in the same project
//   ready-not-queued     verdict buildable/ready, no live queue row, no deferral answer
//   queued               a queued or ready queue row (position, age)
//   deferred             the last build answer was a deferral (reason text)
//   stale-claim          a claimed row older than stale_claim_min, no live job
//   other                anything else, so no open ticket is dropped
// A triage_state verdict counts only for the current input (verdict_hash ==
// input_hash, or no input_hash); else the board's own triage_verdict counts.

import { safeHttpsUrl, prNumberFromUrl } from './format.js';
import { ticketPath } from './line.js';

export const WAITING_REASONS = [
  'not-triaged', 'needs-clarification', 'blocked-by', 'ready-not-queued',
  'queued', 'deferred', 'stale-claim', 'other'
];

export const REASON_LABEL = {
  'not-triaged': 'no triage verdict for the current ticket text',
  'needs-clarification': 'triage asked a question that is not answered',
  'blocked-by': 'a hard parent ticket is still open',
  'ready-not-queued': 'buildable, but no build is queued',
  queued: 'in the build queue',
  deferred: 'the last build answer was a deferral',
  'stale-claim': 'claimed, but no build is running',
  other: 'open, with a verdict no rule covers'
};

// The fallbacks of the jobs worker's knob rows (worker/jobs/src/routes/waiting.js).
const STALE_CLAIM_MIN_DEFAULT = 30;       // settings row waiting.stale_claim_min
const MAX_TICKETS_DEFAULT = 2000;         // settings row waiting.max_tickets
const DEFER_LOOKBACK_MIN_DEFAULT = 10080; // settings row waiting.defer_lookback_min
const REASON_TEXT_MAX_DEFAULT = 200;      // settings row waiting.reason_text_max

export const PROJECT_RE = /^[a-z0-9][a-z0-9._-]{0,63}$/;
const KEY_RE = /^[A-Za-z0-9._#-]{1,64}$/;

// The deferral answers, anchored on the shapes the harness writes. A word in
// free text ("deferred to the user", "budget table") is not one.
const DEFER_RES = [
  /^BUILD_DEFERRED\b/i, /\bOVERLAP_DEFER\b/i, /\bREFUSED\b/i, /\bparked\b/i,
  /\bbudget[- ]?(cap|project-day|stage-day)\b/i, /\busd-cap-day\b/i,
  /\bspawn[- ]?(cap|hold)\b/i, /\bwip[- ]?limit\b/i, /\block held\b/i
];
export const isDeferral = (text) => typeof text === 'string' && text !== '' && DEFER_RES.some((re) => re.test(text));

const BUILDABLE = new Set(['buildable', 'ready']);
const CLARIFY = new Set(['needs_clarification', 'waiting_client']);
const CLIENT_SIDE = new Set(['client', 'requester']);

const pairKey = (project, key) => `${String(project).trim()}\u0000${String(key).trim()}`;
const norm = (v) => (typeof v === 'string' && v.trim() !== '' ? v.trim().toLowerCase() : null);
const knob = (v, def) => (typeof v === 'number' && Number.isInteger(v) && v > 0 ? v : def);
const ageMin = (iso, now) => {
  const t = Date.parse(iso || '');
  return Number.isFinite(t) ? Math.max(0, Math.floor((now - t) / 60000)) : null;
};

// The open tickets of the snapshot, in one order (project name, then board
// order), as {project, key, id, ticket}. A key the jobs route would refuse is
// left out; an id it would refuse is dropped to null. The Pages Function sends
// exactly this list, and the classifier reads it again, so a truncated read
// cuts both at the same place.
export function openTickets(snapshot, project = null) {
  const projects = (snapshot && snapshot.projects) || {};
  const out = [];
  for (const p of Object.keys(projects).sort()) {
    if (project && p !== project) continue;
    if (!PROJECT_RE.test(p)) continue;
    for (const t of (projects[p] && projects[p].tickets) || []) {
      if (!t || typeof t !== 'object' || norm(t.status) === 'done') continue;
      const key = typeof t.key === 'string' ? t.key.trim() : (t.key === null || t.key === undefined ? '' : String(t.key));
      if (!KEY_RE.test(key)) continue;
      const id = typeof t.id === 'string' && KEY_RE.test(t.id.trim()) ? t.id.trim() : null;
      out.push({ project: p, key, id, ticket: t });
    }
  }
  return out;
}

const byPair = (rows, keyField) => {
  const m = new Map();
  for (const r of rows || []) {
    if (!r || r.project === undefined || r[keyField] === undefined || r[keyField] === null) continue;
    const k = pairKey(r.project, r[keyField]);
    if (!m.has(k)) m.set(k, []);
    m.get(k).push(r);
  }
  return m;
};
const lookup = (m, project, key, id) => [
  ...(m.get(pairKey(project, key)) || []),
  ...(id !== null && id !== key ? (m.get(pairKey(project, id)) || []) : [])
];

export function classifyWaiting(snapshot, state, { now = Date.now(), project = null } = {}) {
  const st = state || {};
  const knobs = {
    stale_claim_min: knob(st.knobs && st.knobs.stale_claim_min, STALE_CLAIM_MIN_DEFAULT),
    max_tickets: knob(st.knobs && st.knobs.max_tickets, MAX_TICKETS_DEFAULT),
    defer_lookback_min: knob(st.knobs && st.knobs.defer_lookback_min, DEFER_LOOKBACK_MIN_DEFAULT),
    reason_text_max: knob(st.knobs && st.knobs.reason_text_max, REASON_TEXT_MAX_DEFAULT)
  };
  const cut = (s) => (typeof s === 'string' && s !== '' ? s.slice(0, knobs.reason_text_max) : null);
  const staleMin = knobs.stale_claim_min;

  const all = openTickets(snapshot, project);
  const read = st.truncated ? all.slice(0, knobs.max_tickets) : all;
  const unread = all.length - read.length;

  // Open tickets per project, by key and id, for the blocker lookup.
  const open = new Map();
  for (const x of openTickets(snapshot)) {
    open.set(pairKey(x.project, x.key), x);
    if (x.id) open.set(pairKey(x.project, x.id), x);
  }

  const triage = byPair(st.triage, 'ticket_key');
  const queue = byPair(st.queue, 'ticket_key');
  const live = byPair(st.live_jobs, 'ticket_id');
  const parked = byPair(st.parked_jobs, 'ticket_id');
  const edges = byPair((st.edges || []).filter((e) => e && e.kind === 'hard'), 'child');
  const position = new Map();
  const perProject = new Map();
  for (const r of st.positions || []) {
    if (!r || !r.project || !r.ticket_key) continue;
    const n = (perProject.get(r.project) || 0) + 1;
    perProject.set(r.project, n);
    position.set(pairKey(r.project, r.ticket_key), n);
  }

  const counts = Object.fromEntries(WAITING_REASONS.map((r) => [r, 0]));
  const rows = [];
  const staleClaims = [];
  const reconcile = { todo: 0, review_waiting_client: 0, in_progress_stale: 0, todo_in_flight: 0 };
  let inFlight = 0;

  for (const x of read) {
    const t = x.ticket;
    const status = norm(t.status);
    const boardWaiting = norm(t.waiting_on ?? t.waitingOn);
    const q = lookup(queue, x.project, x.key, x.id)[0] || null;
    const jobs = lookup(live, x.project, x.key, x.id);
    const liveJob = jobs.find((j) => {
      const a = ageMin(j.beat_at || j.updated_at, now);
      return a !== null && a <= staleMin;
    }) || null;
    const claimAge = q && q.status === 'claimed' ? ageMin(q.claimed_at || q.updated_at, now) : null;
    const freshClaim = claimAge !== null && claimAge <= staleMin;
    // A claim with no readable time and no live job has nothing that says it
    // is alive, so it is stale.
    const staleClaim = Boolean(q && q.status === 'claimed' && !freshClaim && !liveJob);
    if (staleClaim) staleClaims.push({ project: x.project, key: x.key, id: x.id });

    let candidate;
    if (status === 'review') {
      candidate = CLIENT_SIDE.has(boardWaiting);
      if (candidate) reconcile.review_waiting_client++;
    } else if (status === 'in_progress') {
      candidate = staleClaim;
      if (candidate) reconcile.in_progress_stale++;
    } else {
      reconcile.todo++;
      candidate = !(liveJob || freshClaim);
      if (!candidate) reconcile.todo_in_flight++;
    }
    if (!candidate) { inFlight++; continue; }

    const tri = lookup(triage, x.project, x.key, x.id)[0] || null;
    const triVerdict = tri && (tri.input_hash === null || tri.input_hash === undefined || tri.verdict_hash === tri.input_hash)
      ? norm(tri.verdict) : null;
    const boardVerdictRaw = norm(t.triage_verdict ?? t.triageVerdict);
    const boardVerdict = boardVerdictRaw === 'untriaged' ? null : boardVerdictRaw;
    const verdict = triVerdict || boardVerdict;
    const waitingOn = boardWaiting || norm(tri && tri.waiting_on);
    const park = lookup(parked, x.project, x.key, x.id)
      .sort((a, b) => String(b.updated_at || '').localeCompare(String(a.updated_at || '')))[0] || null;
    const blockerEdge = lookup(edges, x.project, x.key, x.id)
      .find((e) => open.has(pairKey(x.project, e.parent))) || null;
    const qDeferred = Boolean(q && isDeferral(q.reason));
    const qFinished = q && (q.status === 'done' || q.status === 'failed');

    let reason;
    let reasonText = null;
    let since = t.updatedAt || t.updated_at || null;
    let blocker = null;
    if (!verdict && !CLIENT_SIDE.has(boardWaiting)) {
      reason = 'not-triaged';
    } else if (CLARIFY.has(verdict) || CLIENT_SIDE.has(boardWaiting)) {
      reason = 'needs-clarification';
      since = (tri && tri.triaged_at) || since;
      reasonText = waitingOn ? `waiting on ${waitingOn}` : null;
    } else if (blockerEdge) {
      reason = 'blocked-by';
      const b = open.get(pairKey(x.project, blockerEdge.parent));
      blocker = { key: b.key, url: safeHttpsUrl(b.ticket.url), route: ticketPath(b.key) };
      since = (tri && tri.triaged_at) || since;
    } else if (BUILDABLE.has(verdict) && (!q || (qFinished && !qDeferred)) && !park) {
      reason = 'ready-not-queued';
      since = (q && q.finished_at) || (tri && tri.triaged_at) || since;
    } else if (q && (q.status === 'queued' || q.status === 'ready')) {
      reason = 'queued';
      since = q.enqueued_at || since;
      reasonText = cut(q.reason);
    } else if (qDeferred || park || verdict === 'hold') {
      reason = 'deferred';
      if (qDeferred) {
        reasonText = cut(q.reason);
        since = q.finished_at || q.updated_at || since;
      } else if (park) {
        reasonText = cut(park.reason) || `job ${park.status}`;
        since = park.updated_at || since;
      } else {
        reasonText = cut(tri && tri.reason) || 'triage verdict hold';
        since = (tri && tri.triaged_at) || since;
      }
    } else if (staleClaim) {
      reason = 'stale-claim';
      since = q.claimed_at || q.updated_at || since;
      reasonText = `claimed${q.claimed_by ? ` by ${q.claimed_by}` : ''}, no running job`;
    } else {
      reason = 'other';
      reasonText = verdict ? `verdict: ${verdict}` : null;
    }

    const job = park || jobs[0] || null;
    const claim = t.claim && typeof t.claim === 'object' ? t.claim : null;
    const prN = claim ? (Number.isInteger(claim.pr) && claim.pr > 0 ? claim.pr : prNumberFromUrl(claim.pr_url)) : null;
    counts[reason]++;
    rows.push({
      project: x.project,
      key: x.key,
      title: typeof t.title === 'string' ? t.title : '',
      board_status: status || 'unknown',
      reason,
      reason_text: reasonText,
      since,
      age_min: ageMin(since, now),
      waiting_on: reason === 'needs-clarification' ? (waitingOn || null) : null,
      blocker,
      position: reason === 'queued' ? (position.get(pairKey(x.project, x.key)) ?? null) : null,
      board_url: safeHttpsUrl(t.url),
      ticket_route: ticketPath(x.key),
      job_route: job && job.id ? `/jobs/${encodeURIComponent(job.id)}` : null,
      pr_route: prN !== null ? `/pr/${encodeURIComponent(x.project)}/${prN}` : null
    });
  }

  const gen = Number(snapshot && snapshot.generated_at);
  return {
    ok: true,
    as_of: st.as_of || null,
    snapshot_age_min: Number.isFinite(gen) && gen > 1e9 && gen < 4e9 ? Math.max(0, Math.round((now - gen * 1000) / 60000)) : null,
    snapshot_projects: Object.keys((snapshot && snapshot.projects) || {}).sort(),
    project_in_snapshot: project ? Boolean(snapshot && snapshot.projects && Object.prototype.hasOwnProperty.call(snapshot.projects, project)) : null,
    knobs,
    counts,
    total: rows.length,
    in_flight: inFlight,
    reconcile,
    stale_claims: staleClaims,
    rows,
    truncated: Boolean(st.truncated),
    unread,
    positions_truncated: Boolean(st.positions_truncated)
  };
}

// The PIPELINE board with every BUILDING card whose (project, ticket) pair is
// a stale claim taken out, and counts.building lowered by the cards taken out
// (the API count, not the column length, is what the header showed). Anything
// but an ok waiting payload with a stale_claims list leaves the board as sent.
export function dropStaleClaims(board, waiting) {
  if (!board || !board.columns || !Array.isArray(board.columns.building)) return board;
  if (!waiting || waiting.ok !== true || !Array.isArray(waiting.stale_claims)) return board;
  const stale = new Set();
  for (const s of waiting.stale_claims) {
    if (!s || !s.project) continue;
    if (s.key) stale.add(pairKey(s.project, s.key));
    if (s.id) stale.add(pairKey(s.project, s.id));
  }
  const keep = board.columns.building.filter((c) => {
    if (!c || !c.project) return true;
    const ids = [c.ticket, c.ticket_key, c.ticket_id].filter((v) => v !== undefined && v !== null && v !== '');
    return !ids.some((v) => stale.has(pairKey(c.project, v)));
  });
  const dropped = board.columns.building.length - keep.length;
  const had = Number(board.counts && board.counts.building);
  return {
    ...board,
    columns: { ...board.columns, building: keep },
    counts: { ...(board.counts || {}), building: Number.isFinite(had) ? Math.max(0, had - dropped) : keep.length },
    building_excluded_stale: dropped
  };
}
