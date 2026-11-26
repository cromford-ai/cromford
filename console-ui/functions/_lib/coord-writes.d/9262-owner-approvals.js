import { jsonError } from '../coord-writes.js';

export default [
  // BH-9262 (C1): the /machines OWNER APPROVALS panel. Both rows send the
  // owner proof (`boxOps`), which the worker needs on each. The actor is
  // stamped here. A field of the wrong type is a 400, never dropped, so a
  // decide never reaches the worker without its decision.
  // Decide one approval: owner-approvals/<id>/decide, decision and an optional
  // result_ref (the command id or the class the owner's action produced).
  { method: 'POST', path: isDecidePath, body: ['decision', 'result_ref'], build: decideBody, boxOps: true },
  // The console's archie delegation, the APPROVE on an archie_delegation row.
  // No console write row existed for it before C1.
  { method: 'POST', path: 'archie/classes/delegation', body: ['class', 'decision', 'min_streak', 'reason'], build: delegationBody, boxOps: true }
];

// owner-approvals/<id>/decide, the id a positive integer.
function isDecidePath(rest) {
  return /^owner-approvals\/[1-9][0-9]{0,15}\/decide$/.test(rest);
}

const has = (o, k) => Object.prototype.hasOwnProperty.call(o, k);

function decideBody(sent) {
  if (sent.decision !== 'approved' && sent.decision !== 'declined') return { error: jsonError(400, 'decision must be approved or declined') };
  const body = { decision: sent.decision };
  if (has(sent, 'result_ref') && sent.result_ref !== null) {
    if (typeof sent.result_ref !== 'string') return { error: jsonError(400, 'result_ref must be a string') };
    body.result_ref = sent.result_ref;
  }
  return { body };
}

function delegationBody(sent) {
  for (const k of ['class', 'decision']) {
    if (typeof sent[k] !== 'string') return { error: jsonError(400, `${k} must be a string`) };
  }
  const body = { class: sent.class, decision: sent.decision };
  if (has(sent, 'min_streak')) {
    if (!Number.isInteger(sent.min_streak)) return { error: jsonError(400, 'min_streak must be an integer') };
    body.min_streak = sent.min_streak;
  }
  if (has(sent, 'reason')) {
    if (typeof sent.reason !== 'string') return { error: jsonError(400, 'reason must be a string') };
    body.reason = sent.reason;
  }
  return { body };
}
