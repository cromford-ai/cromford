import { isStr } from '../coord-writes.js';

export default [
  // BH-6823: a note to one staff agent, from the agent page's CHAT pane and the
  // /chat STAFF tabs. Strings only. The actor is stamped here. staff/chat/take
  // and staff/chat/settle are box-side (bin/staff.sh) and stay 405 from a
  // browser.
  { method: 'POST', path: 'staff/chat', body: ['agent', 'text'], ok: isStr }
];
