import { isStr } from '../coord-writes.js';

export default [
  // BH-7243.0: add a roadmap idea. Strings only. The actor is stamped here;
  // every other field the browser sends is dropped.
  { method: 'POST', path: 'roadmap/ideas', body: ['project', 'title', 'note', 'source', 'link', 'idem_key'], ok: isStr }
];
