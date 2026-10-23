# Secret envelopes: a one-time ciphertext the hub reads once (BH-7964, BH-7937.0)

Doc: DB-COORDINATION-SPEC

## What changed

This is the first slice of BH-7937 (onboarding UI wave 4). A caller can now
give the hub a secret (an AI account key, a tracker token) without the jobs
worker ever holding the plain value. The caller seals the secret to the hub's
public key. The worker stores only the ciphertext. The hub reads it once, and
the read deletes the row.

- **Tables** (`worker/jobs/schema.d/202610220411-bh-7964-secret-envelopes.sql`):
  `secret_envelopes` (one row per envelope, PK `id`, index
  `ix_secret_envelopes_expires`) and `secret_envelope_events` (append-only
  audit: `stored`, `consumed`, `expired`; indexes
  `ix_secret_envelope_events_env` and `ix_secret_envelope_events_at`).
- **Settings rows**: `secret_envelope_ttl_s` = `900` (an integer in
  60..86400; any other value uses the code default 900) and
  `hub_envelope_public_key` = `''` (BH-7937.2 fills it; nothing reads it yet).
- **`POST /api/secrets/envelope {scope, ciphertext}`** (main bearer). The scope
  is `ai-account:<name>` or `tracker:<name>` (`[a-z0-9._:@-]{1,96}`, no `..`).
  The ciphertext is base64, 344..1024 chars. Answers `{id, expires_at}`. The row
  and its `stored` event land in one batch.
- **`GET /api/secrets/envelope/:id`** (main bearer AND header
  `x-envelope-hub-token` equal to the worker secret `ENVELOPE_HUB_TOKEN`, both
  trimmed, constant-time compare). One `DELETE … RETURNING` reads and deletes.
  503 when `ENVELOPE_HUB_TOKEN` is unset or blank. 403 on a wrong hub token.
  404 on a bad id, no row, or an expired row (the expired row is deleted too).
  A second read is 404. `/:id/status` and `/:id/confirm` do not match.
- **Seams** for the siblings: `src/routes/secret-envelope-apply.js`
  (BH-7937.2) and `src/routes/ai-accounts.js` (BH-7937.3), each
  `routes = []`, with the fragments `bh-7964-secret-envelope-apply.txt` and
  `bh-7964-ai-accounts.txt`. A sibling adds its route lines to THESE fragments.
  A second fragment for the same family makes the route loader throw.
- The route module exports `hubTokenOk`, `checkEnvelopeScope`,
  `envelopeEvent` and `ENVELOPE_EXPIRED_SQL` for the siblings.

## New env var

`ENVELOPE_HUB_TOKEN`. Set it in:

1. The jobs worker: `wrangler secret put ENVELOPE_HUB_TOKEN`.
2. The hub: `/etc/harness/env/global.env`.

Until it is set, the GET answers 503 and no ciphertext can leave the worker.

## Retention

An envelope row dies on its one read. An expired row is refused and deleted on
read. The sweep of expired rows that nobody read, and the archive rule for
`secret_envelope_events`, are BH-7937.2. This slice ships the indexes they use.

## Tests

`worker/jobs/test/secret-envelopes.bh-7964.test.js` (the real `worker.fetch`
on node:sqlite) and `tests/secret-envelopes.bh-7964-test.sh` (CI's runner for it).
