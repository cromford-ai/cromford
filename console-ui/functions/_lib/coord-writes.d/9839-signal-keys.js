import { isStr } from '../coord-writes.js';

// BH-9839: the project Signals page (slice C1 of BH-9800). set, clear and
// test of one project's signal key on the jobs worker (routes/signal-keys.js).
// `boxOps` sends the BH-9262 owner proof, which the worker needs for each of
// them. The GET list rides the GET passthrough; read and hub-read have no row,
// so a browser POST to them is 405. A browser `actor`, `value` or
// `ciphertext` is dropped; the actor is stamped by the proxy.
const isFields = (v) => Boolean(v) && typeof v === 'object' && !Array.isArray(v)
  && Object.values(v).every((x) => typeof x === 'string');
const setOk = (k, v) => (k === 'fields' ? isFields(v) : typeof v === 'string');

export default [
  { method: 'POST', path: 'signal-keys/set', body: ['project', 'kind', 'fields'], ok: setOk, boxOps: true },
  { method: 'POST', path: 'signal-keys/clear', body: ['project', 'kind'], ok: isStr, boxOps: true },
  { method: 'POST', path: 'signal-keys/test', body: ['project', 'kind'], ok: isStr, boxOps: true }
];
