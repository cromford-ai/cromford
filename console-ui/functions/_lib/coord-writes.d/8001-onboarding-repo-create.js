import { isStr } from '../coord-writes.js';

export default [
  // BH-8001 (BH-7935.4): /projects/new's New repo panel, the create of a repo
  // from a template (worker/jobs/src/routes/onboarding-repo-create.js). The
  // body is the form: owner, name and the template key. `idempotencyKey: true`
  // makes the proxy forward the browser's Idempotency-Key, which the worker
  // requires, so a retried Create files one hub-probe row, not two.
  {
    method: 'POST', path: 'onboarding/repo-create',
    body: ['owner', 'name', 'template'], ok: isStr, idempotencyKey: true
  }
];
