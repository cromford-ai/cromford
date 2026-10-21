import { isStr } from '../coord-writes.js';

// An integer pr, strings for the rest. A field that fails is not forwarded,
// and the worker answers the body without it with its own 400.
const isAcceptField = (k, v) => (k === 'pr' ? Number.isInteger(v) && v > 0 : isStr(k, v));

export default [
  // BH-4157: the PR page's IRON-LAW HOLD panel. A person accepts the iron-law
  // hits on the head the conductor holds, with a reason. The worker binds the
  // row to that held head; the actor is stamped here.
  { method: 'POST', path: 'ironlaw-accept', body: ['repo', 'pr', 'head', 'reason'], ok: isAcceptField, needsReason: true }
];
