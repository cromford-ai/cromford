// BH-6825: the pure half of the LEARNING panel on /staff/:agent
// (screens/staff/agent-learning.js). It reads the shapes the worker answers
// (worker/jobs/src/routes/staff-learning.js): GET /api/staff/learning, the
// drill-down GET /api/staff/learning/outcomes and POST
// /api/staff/promotions/decide. No DOM and no fetch here, so the tests drive
// it directly.
import { displayName } from './staff.js';

export const REASON_MAX = 500;

// A body with no windows or no decisions list is a failed read (null), never
// an empty panel.
export function learningState(res) {
  if (!res || typeof res !== 'object' || !res.agent || typeof res.agent !== 'object') return null;
  if (!Array.isArray(res.windows) || res.windows.length < 1 || !Array.isArray(res.decisions)) return null;
  const p = res.promotion;
  const promotion = p && typeof p === 'object' ? {
    ...p,
    evidence: p.evidence && Array.isArray(p.evidence.rows)
      ? p.evidence
      : { rows: [], total: null, truncated: false }
  } : null;
  return {
    agent: res.agent,
    windows: res.windows.filter((w) => w && typeof w === 'object'),
    promotion,
    decisions: res.decisions.filter((d) => d && typeof d === 'object'),
    decisionsMore: res.decisions_more === true,
    retentionDays: res.retention_days && Number.isFinite(res.retention_days.value) ? res.retention_days.value : null
  };
}

// No outcome is "n/a (no outcomes)", never 0%.
export const pct = (x) => (x === null || x === undefined || !Number.isFinite(x) ? 'n/a (no outcomes)' : `${Math.round(x * 100)}%`);

// The count cells of one window row, in column order. outcome 'all' is TOTAL.
export const COUNT_KEYS = [['merged', 'merged'], ['rejected', 'rejected'], ['noise', 'noise'], ['total', 'all']];

// The aria-label of a count button; TOTAL has no outcome word.
export const countLabel = (n, outcome, days) => `${n} ${outcome === 'all' ? '' : `${outcome} `}outcomes in ${days} days`;

export const outcomeHref = (findingId) =>
  (findingId === null || findingId === undefined || findingId === '' ? null : `/staff/finding/${encodeURIComponent(findingId)}`);

// The decide body, or null when it must not be sent.
export function decideBody({ id, decision, reason }) {
  if (!(typeof id === 'number' && Number.isInteger(id) && id > 0)) return null;
  if (decision !== 'approve' && decision !== 'void') return null;
  const r = typeof reason === 'string' ? reason.trim() : '';
  if (r.length < 1 || r.length > REASON_MAX) return null;
  return { id, decision, reason: r };
}

// One plain sentence per refusal the decide route answers.
export function errorText(err) {
  const b = (err && err.body) || {};
  switch (b.error) {
    case 'stale_level': return `refused: the agent's level moved to ${b.autonomy || 'another level'} after the proposal. Read the panel again.`;
    case 'above_cap': return `refused: ${b.to_level || 'that level'} is above the cap (${b.cap || 'unknown'}).`;
    case 'agent_not_active': return `refused: the agent is ${b.status || 'not active'}, so it cannot rise.`;
    case 'not_pending': return `refused: the proposal is already ${b.status || 'decided'}.`;
    case 'agent_approver': return 'refused: a staff agent or archie cannot decide a promotion. A person decides.';
    case 'reason': return `refused: the reason must be 1 to ${REASON_MAX} characters.`;
    case 'decide_unresolved': return 'the write ran but its read-back failed. Read the panel again before you retry.';
    default: return `refused: ${err && err.message ? err.message : String(err)}`;
  }
}

// The note after a 2xx, from the rows the route read back. No read-back, no note.
export function readBackText(ans) {
  const p = ans && ans.promotion;
  const d = ans && ans.decision;
  const a = ans && ans.agent;
  if (!p || !d || !a) return null;
  const who = displayName(a.name);
  const head = d.decision === 'approve'
    ? `${ans.existing ? 'Already approved' : 'Approved'}. ${who} is now ${a.autonomy}.`
    : `${ans.existing ? 'Already voided' : 'Voided'}. ${who} stays ${a.autonomy}.`;
  return `${head} Reason recorded for ${d.actor} at ${d.decided_at}.`;
}
