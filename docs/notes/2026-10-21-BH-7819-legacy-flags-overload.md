# Legacy flag writes answer a D1 overload with a 503 (BH-7819)

Doc: OPERATING

## The gap

Sentry issue CROMFORD-HARNESS-Y: `putLegacy` in
`worker/jobs/src/routes/flags.js` threw
`D1_ERROR: D1 DB is overloaded. Requests queued for too long.` (5 events).
BH-6805 put the ported-name branch of `PUT /api/flags` and `DELETE /api/flags`
inside `d1OverloadGuarded`. The legacy branch (a non-ported name such as
`wip-limit-*`) called `putLegacy` with no guard. A give-up became an uncaught
throw: an HTTP 500 to the box and one Sentry event.

## The retry, as it stands (not changed here)

- `withD1Retry` (`worker/jobs/src/lib/d1-retry.js`) retries an error whose
  message contains `D1 DB is overloaded`. That matches both wire messages:
  `Requests queued for too long.` and `Too many requests queued.`
- `D1_RETRY_ATTEMPTS = 5` attempts. The delay before attempt n+1 is
  `min(1000, 100 * 2^(n-1))` ms, with jitter `d/2 + random * d/2`. The total
  wait before a give-up is 750..1500 ms (BH-6690, BH-6813).
- After the last attempt it rethrows the same error with `d1Attempts` set.
- `putLegacy` writes one flag per call: one read, one `batch` (the upsert and
  0 or 1 `config_changes` audit row), one read-back. There is no row-by-row
  write to chunk.

## What changed

- The legacy `PUT /api/flags` branch runs `putLegacy` inside
  `d1OverloadGuarded("pause_flags", …, "PUT <name>")`.
- The legacy `DELETE /api/flags` branch runs its pre-read and `putLegacy`
  inside `d1OverloadGuarded("pause_flags", …, "DELETE <name>")`. An overload on
  the pre-read is a 503, never a 404.
- On a give-up the answer is 503
  `{"error":"pause_flags unavailable","detail":"…overloaded…","retryable":true,"d1_attempts":5}`
  and the worker writes one line:
  `d1-overload: pause_flags PUT <name> answered 503 after 5 attempt(s)`.
  `bin/lib/jobs/req.sh` retries that 503 once. A batch is one transaction, so
  a give-up writes nothing, and the re-send writes the row and one audit row.
- If the batch has committed and only the read-back overloads, the answer is
  200 `{"flag":null,"written":true}` and one line
  `d1-overload: pause_flags read-back <name> after a committed write, …`.
  The box does not re-send a write that landed.
- Every other error still throws and reaches Sentry. No schema change.

Test: `worker/jobs/test/flags-legacy-overload.bh-7819.test.js`.
