import { isStr } from '../coord-writes.js';

export default [
  // BH-7936, BH-7968: the tracker sheets' Test and connect (src/ui/TrackerSheets.js).
  // The sheet first stores its sealed fields as a secret envelope (the
  // secrets/envelope row), then sends only the envelope id here. The worker
  // checks the envelope's scope and files a hub-probe row.
  { method: 'POST', path: 'onboarding/tracker-test', body: ['project', 'kind', 'envelope_id'], ok: isStr }
];
