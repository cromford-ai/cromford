// BH-6822: the agent detail page's pure half. The timeline comes from the jobs
// worker's GET /api/staff/agent/:name/activity (routes/staff-activity.js):
// events of five kinds, newest first by (ts, kind, id), paged by an opaque
// cursor. Each row links to its record: a tick to /staff/tick/<id>, a finding
// event to /staff/finding/<id>, an outcome to its finding and its ticket, a
// decision to its finding when it has one (no decision screen exists).

import { agoFromMinutes, safeHttpsUrl } from './format.js';

export const tickHref = (id) => `/staff/tick/${encodeURIComponent(id)}`;
const findingHref = (id) => `/staff/finding/${encodeURIComponent(id)}`;

const KIND_LABEL = {
  tick: 'tick', 'finding.claimed': 'claimed', 'finding.recorded': 'recorded', outcome: 'outcome', decision: 'decision'
};

function tickResult(e) {
  if (e.phase === 'done') return 'done';
  const rc = e.phase === 'collect' ? e.collector_rc : e.phase === 'model' ? e.model_rc : null;
  return `stopped at ${e.phase}${rc !== null && rc !== undefined ? ` (rc ${rc})` : ''}`;
}
const tickSummary = (e) => `collected ${e.collected}, new ${e.new_items}, filed ${e.filed}, digested ${e.digested}`
  + `${e.held ? `, held ${e.held}` : ''}${e.failed ? `, failed ${e.failed}` : ''}${e.deferred ? `, deferred ${e.deferred}` : ''}`;

function rowOf(e) {
  const base = {
    key: `${e.kind}:${e.id}`, kind: e.kind, id: e.id, ts: e.ts, cursor: e.cursor, when: e.ts,
    kindLabel: KIND_LABEL[e.kind] || e.kind, href: null, ext: null, duration_s: null, cost: null, unpriced: 0
  };
  if (e.kind === 'tick') {
    return {
      ...base, summary: tickSummary(e), href: tickHref(e.id), result: tickResult(e), duration_s: e.duration_s,
      cost: e.cost && typeof e.cost.cost_usd === 'number' ? e.cost.cost_usd : null,
      unpriced: e.cost ? Number(e.cost.unpriced) || 0 : 0
    };
  }
  if (e.kind === 'finding.claimed' || e.kind === 'finding.recorded') {
    return { ...base, summary: e.title, href: findingHref(e.finding_id), ext: safeHttpsUrl(e.ticket_url), result: e.status };
  }
  if (e.kind === 'outcome') {
    return {
      ...base, summary: `${e.outcome} (${e.verdict})`, href: e.finding_id ? findingHref(e.finding_id) : null,
      ext: safeHttpsUrl(e.ticket_url), result: e.outcome
    };
  }
  return {
    ...base, summary: `${e.class}: ${e.recommendation} (${e.mode})`, href: e.finding_id ? findingHref(e.finding_id) : null,
    result: e.choice || 'no choice yet'
  };
}

// A body with no events array is a failed read (null), never an empty timeline.
export function activityRows(res) {
  if (!res || !Array.isArray(res.events)) return null;
  return {
    rows: res.events.filter((e) => e && typeof e === 'object' && typeof e.kind === 'string').map(rowOf),
    next: typeof res.next === 'string' ? res.next : null,
    lastTick: res.last_tick || null,
    costStatus: res.cost_status === 'unread' ? 'unread' : 'ok'
  };
}

const cmp = (a, b) => (a < b ? -1 : a > b ? 1 : 0);
// The worker's total order, newest first: ts, then kind, then id, each DESC.
export function mergePages(existing, page) {
  const byKey = new Map();
  for (const r of [...(existing || []), ...(page || [])]) if (!byKey.has(r.key)) byKey.set(r.key, r);
  return [...byKey.values()].sort((x, y) => cmp(y.ts, x.ts) || cmp(y.kind, x.kind) || (y.id - x.id));
}

// The last heartbeat, in words. null is "no tick yet"; undefined or an
// unreadable time is unknown, never "no tick".
export function heartbeatText(lastTickAt, nowMs = Date.now()) {
  if (lastTickAt === null) return 'no tick recorded yet';
  const t = typeof lastTickAt === 'string' ? Date.parse(lastTickAt) : NaN;
  if (Number.isNaN(t)) return 'last tick unknown (the roster read did not say)';
  const a = agoFromMinutes(Math.max(0, Math.round((nowMs - t) / 60000)));
  return a === 'now' ? 'last tick now' : `last tick ${a} ago`;
}
