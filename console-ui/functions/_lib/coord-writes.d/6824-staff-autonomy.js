import { isStr } from '../coord-writes.js';

export default [
  // BH-6824: the agent page's AUTONOMY panel. Set one staff agent's level, and
  // delegate or ask_first one staff class. Strings only, and a reason is
  // required (the worker writes it into the staff_autonomy_changes row). The
  // actor is stamped here; the worker refuses a raise above the cap and any
  // change to a protected class.
  { method: 'POST', path: 'staff/agents/autonomy', body: ['agent', 'autonomy', 'reason'], ok: isStr, needsReason: true },
  { method: 'POST', path: 'staff/classes/delegation', body: ['agent', 'class', 'decision', 'reason'], ok: isStr, needsReason: true }
];
