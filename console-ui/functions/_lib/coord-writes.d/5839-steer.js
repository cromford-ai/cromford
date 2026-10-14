import { isStr } from '../coord-writes.js';

export default [
  // BH-5839: the ticket page's Step in composer, a POST to `steer` exactly.
  // Strings only. The actor is stamped here. steer/take, steer/settle,
  // steer/<id>/claim and steer/<id>/delivered are box-side and stay 405 from a
  // browser, and so does a GET of steer/outbox (BOX_ONLY_GETS).
  { method: 'POST', path: 'steer', body: ['project', 'ticket', 'job_id', 'mode', 'text'], ok: isStr }
];
