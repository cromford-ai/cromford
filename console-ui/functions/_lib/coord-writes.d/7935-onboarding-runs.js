import { isStr } from '../coord-writes.js';

export default [
  // BH-7999 (BH-7935.2): /projects/new's Start setup, the create of an
  // onboarding run (worker/jobs/src/routes/onboarding.js). The body is the
  // run inputs. `idempotencyKey: true` makes the proxy forward the browser's
  // Idempotency-Key, which the worker requires, and the stamped actor as
  // x-harness-actor, which it stores as created_by.
  {
    method: 'POST', path: 'onboarding/runs',
    body: ['repo', 'project', 'tracker', 'box', 'prefix', 'base', 'prod'], ok: isStr, idempotencyKey: true
  }
];
