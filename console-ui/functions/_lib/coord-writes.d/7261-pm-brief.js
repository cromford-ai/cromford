import { isStr } from '../coord-writes.js';

export default [
  // BH-7261: approve or reject one proposed brief move. The proxy stamps the actor.
  // claim, create, fail and sent are box-only and have no row, so they stay 405.
  { method: 'POST', path: 'pm/moves/decide', body: ['project', 'move_id', 'decision'], ok: isStr }
];
