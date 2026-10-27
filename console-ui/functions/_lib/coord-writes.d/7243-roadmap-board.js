import { isScalar } from '../coord-writes.js';

export default [
  // BH-7243.2: hand links and the decisions log of the roadmap board. The
  // actor is stamped here; every other field the browser sends is dropped.
  // isScalar keeps `issue` a number and every other field a string.
  { method: 'POST', path: 'roadmap/links', body: ['idea_id', 'project', 'issue'], ok: isScalar },
  { method: 'POST', path: 'roadmap/links/remove', body: ['idea_id', 'project', 'issue'], ok: isScalar },
  { method: 'POST', path: 'roadmap/decisions', body: ['project', 'kind', 'title', 'body'], ok: isScalar },
  { method: 'POST', path: 'roadmap/decisions/decide', body: ['id', 'project', 'status', 'expected_status'], ok: isScalar }
];
