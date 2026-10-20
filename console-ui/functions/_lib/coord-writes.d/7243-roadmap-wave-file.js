import { isStr } from '../coord-writes.js';

export default [
  // BH-7243.4: approve or reject a draft roadmap wave. Strings only. The
  // proxy stamps the actor; every other field the browser sends is dropped.
  // file-claim, filed, file-done and links/state are lane-only writes: they
  // have no row here, so a browser gets 405 on them.
  { method: 'POST', path: 'roadmap/waves/approve', body: ['id', 'project', 'expected_status'], ok: isStr },
  { method: 'POST', path: 'roadmap/waves/reject', body: ['id', 'project', 'reason'], ok: isStr }
];
