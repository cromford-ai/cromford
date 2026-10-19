import { isScalar } from '../coord-writes.js';

export default [
  // BH-7243.1: move and edit a roadmap idea (a CAS on expected_version). The
  // actor is stamped here; every other field the browser sends is dropped.
  // isScalar keeps expected_version a number and every other field a string.
  { method: 'POST', path: 'roadmap/ideas/move', body: ['id', 'project', 'to_lane', 'expected_version', 'reason'], ok: isScalar },
  { method: 'POST', path: 'roadmap/ideas/edit', body: ['id', 'project', 'title', 'note', 'link', 'source', 'expected_version'], ok: isScalar }
];
