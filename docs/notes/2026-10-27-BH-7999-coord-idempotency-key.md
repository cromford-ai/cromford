# The coord proxy forwards an Idempotency-Key for opted-in rows (BH-7999)

Doc: none

## What changed

- A coord write row (`console-ui/functions/_lib/coord-writes.d/*.js`) may set
  `idempotencyKey: true`. For such a row, `functions/api/coord/[[path]].js`
  reads the browser's `Idempotency-Key` header, trims it and checks it with
  the worker's own rule, `^[A-Za-z0-9._:-]{8,128}$`. A missing or bad key is
  a 400 `idempotency_key_required`, and nothing is forwarded. A good key is
  forwarded as `idempotency-key`, and the stamped actor goes with it as
  `x-harness-actor`.
- One row sets it: `POST onboarding/runs` in `7935-onboarding-runs.js`, the
  create behind Start setup on `/projects/new`.
- Rows that do not set the field are unchanged. They forward neither header.

## Why

Before this, the proxy forwarded only `authorization` and `content-type`.
The worker's create route (`worker/jobs/src/routes/onboarding.js`) answers
400 without a key, so a write row alone could not create a run from the
browser. The key is what makes a retried Start setup return the first run
instead of a second one.

## Settings rows

`worker/jobs/schema.d/202610270351-bh-7935-onboarding-board-ready.sql` seeds
`onboarding.product_board_ready` (0), `onboarding.detect_poll_ms` (3000) and
`onboarding.detect_poll_max_s` (120). The form reads them; the code defaults
are the same values.
