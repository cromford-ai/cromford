// BH-6824 (Staff in Mission Control 3/4): the pure half of the agent page's
// AUTONOMY panel (screens/staff/agent-autonomy.js). The read is
// GET /api/staff/autonomy (worker/jobs/src/routes/staff-autonomy.js); the
// writes are the two existing staff routes, POST staff/agents/autonomy and
// POST staff/classes/delegation, through the coord proxy, which stamps the
// actor and refuses a blank reason. Every body is built here, and a write the
// server would refuse anyway (above the cap, a protected class, no reason) is
// refused here first, before any request.

export const LEVELS = ['automation', 'augmentation', 'autonomy'];
// The worker's limit on a reason (staff.js REASON_MAX).
export const REASON_MAX = 500;

const rank = (levels, l) => levels.indexOf(l);

// The GET body as the panel's state, or null when it is not a full answer (a
// failed read). An agent with no classes is `classes: []`, an empty list.
export function autonomyState(res) {
  if (!res || typeof res !== 'object' || !res.agent || typeof res.agent !== 'object') return null;
  if (!Array.isArray(res.classes) || !Array.isArray(res.changes)) return null;
  return {
    agent: res.agent,
    levels: Array.isArray(res.levels) && res.levels.length ? res.levels : LEVELS,
    classes: res.classes,
    changes: res.changes,
    truncated: res.changes_truncated === true,
    limit: res.changes_limit,
    delegateAfter: res.delegate_after || null
  };
}

// The levels a CHANGE LEVEL… can pick: at or below the cap, minus the current
// one. An unknown cap offers nothing.
export function levelOptions(level, cap, levels = LEVELS) {
  const c = rank(levels, cap);
  if (c < 0) return [];
  return levels.filter((l, i) => i <= c && l !== level);
}

export const canEditClass = (c) => Boolean(c) && c.protected !== true && c.display_state !== 'never_delegable';
// The decision a class's action button sends: a delegated class goes back to
// ask_first, an ask_first class is offered for delegation.
export const classTarget = (c) => (c && c.state === 'delegated' ? 'ask_first' : 'delegate');
// Why a DELEGATE… is disabled, or null when it is not: either cap below
// autonomy refuses it on the server (409 capped).
export function delegateBlock(c) {
  if (!canEditClass(c) || classTarget(c) !== 'delegate') return null;
  return c.effective_cap === 'autonomy' ? null : `capped at ${c.effective_cap || 'unknown'}: delegation needs autonomy`;
}

export function reasonOf(raw) {
  const r = typeof raw === 'string' ? raw.trim() : '';
  return r.length >= 1 && r.length <= REASON_MAX ? r : null;
}
export function reasonHint(raw) {
  const r = typeof raw === 'string' ? raw.trim() : '';
  if (!r) return 'a reason is required';
  if (r.length > REASON_MAX) return `the reason must be ${REASON_MAX} characters or fewer`;
  return null;
}

// The POST staff/agents/autonomy body, or null when it must not be sent.
export function autonomyBody(agent, to, cap, reason, levels = LEVELS) {
  const r = reasonOf(reason);
  if (!agent || r === null) return null;
  if (rank(levels, to) < 0 || rank(levels, cap) < 0 || rank(levels, to) > rank(levels, cap)) return null;
  return { agent, autonomy: to, reason: r };
}

// The POST staff/classes/delegation body, or null when it must not be sent.
export function delegationBody(agent, c, reason) {
  const r = reasonOf(reason);
  if (!agent || r === null || !canEditClass(c)) return null;
  const decision = classTarget(c);
  if (decision === 'delegate' && delegateBlock(c)) return null;
  return { agent, class: c.class, decision, reason: r };
}

// A refused write as one plain sentence. `body` is the server's JSON answer.
export function errorText(body) {
  const e = body && body.error;
  switch (e) {
    case 'above_cap': return `refused: ${body.autonomy || 'that level'} is above the cap (${body.cap || 'unknown'}).`;
    case 'never_delegable': return 'refused: this class is never delegable.';
    case 'capped': return `refused: the agent cap (${body.agent_cap || 'unknown'}) or the class cap (${body.class_cap || 'unknown'}) is below autonomy.`;
    case 'not_earned': return `refused: needs ${body.min_streak} agreements in a row, has ${body.streak}.`;
    case 'self_promotion': return 'refused: an agent cannot raise an agent.';
    case 'self_delegation': return 'refused: an agent cannot delegate a class.';
    case 'changed_underneath': return 'refused: the level changed while you were editing. The panel shows the new value.';
    case 'agent_not_active': return `refused: the agent is ${body.status || 'not active'}.`;
    default: return `refused: ${e || 'the server gave no reason'}`;
  }
}
