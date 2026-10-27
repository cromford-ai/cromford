import { isStr } from '../coord-writes.js';

// project and kind are strings; fields is a plain object of strings. A field
// that fails is not forwarded, and the worker answers the body without it with
// its own 400.
const isTrackerTestField = (k, v) => (k === 'fields'
  ? Boolean(v) && typeof v === 'object' && !Array.isArray(v) && Object.values(v).every((x) => typeof x === 'string')
  : isStr(k, v));

export default [
  // BH-7936: the tracker sheets' Test and connect (src/ui/TrackerSheets.js).
  // The worker puts the fields in a one-time KV row and files a hub-probe row.
  // The hub's take route (POST onboarding/tracker-secret/take) has no row here,
  // so a browser gets 405 for it.
  { method: 'POST', path: 'onboarding/tracker-test', body: ['project', 'kind', 'fields'], ok: isTrackerTestField }
];
