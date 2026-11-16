import { isScalar } from '../coord-writes.js';

export default [
  // BH-6825: the agent page's LEARNING panel. A person approves or voids one
  // pending staff promotion, with a reason. The id is a number, the rest are
  // strings. The actor is stamped here; the worker refuses archie or a staff
  // agent as the actor. BH-9262: `boxOps` sends the owner proof, which the
  // worker needs for approve.
  { method: 'POST', path: 'staff/promotions/decide', body: ['id', 'decision', 'reason'], ok: isScalar, needsReason: true, boxOps: true }
];
