# Watchdog header auth, phase 1 (BH-9264, C0)

Doc: watchdog-spec, OPERATOR-SETUP, OUTSIDE-DEADMAN, DASH-TICKETS-SNAPSHOT

Phase 1 of #9264. An outside audit (cromford-ai/cromford#5 and #6) found that
the watchdog took its secret in the URL (`?s=`), so the secret was in logs and
in curl argv, and that it reused HARNESS_SECRET. Removing both at once stops
every box that does not have the new secret yet, and the watchdog then reports
those boxes dead. So the fix comes in two phases.

## What changed

- `worker/watchdog/src/auth.js` (new) holds all route auth. `src/index.js`
  calls `fleetAuth` on the 14 fleet route checks and `stampAuth` on
  `POST /api/stamp/<name>`. The old `authed()` is deleted.
- A caller sends `Authorization: Bearer <secret>`. Fleet routes take
  `WATCHDOG_SECRET`, or `HARNESS_SECRET` as the phase 1 fallback. The stamp
  route takes `STAMP_SECRET` only. A present header decides alone: wrong is 403,
  with no fall-through to `?s=`. The compare is constant-time.
- `?s=` still works. Each use writes ONE line
  `watchdog query-auth route=<path> box=<name|->`. A header match on
  `HARNESS_SECRET` while `WATCHDOG_SECRET` is set writes ONE line
  `watchdog fallback-auth route=<path> box=<name|->`. No line holds a secret.
- `WATCHDOG_SECRET` equal to `HARNESS_SECRET`: every fleet route answers 500,
  `watchdog misconfigured: WATCHDOG_SECRET must differ from HARNESS_SECRET`.
- `worker/watchdog/wrangler.jsonc` turns on `observability`, so Workers Logs
  keep the lines for the 24 h count. `logs.invocation_logs` is `false`: an
  invocation record stores the request URL, and every `?s=` caller would put
  `HARNESS_SECRET` into Cloudflare's stored logs. Only the console lines stay.
- `bin/lib/watchdog-url.sh` gains `watchdog_secret <env-dir>` (lookup:
  `.watchdog-secret`, `$WATCHDOG_SECRET`, `$HARNESS_SECRET`) and
  `watchdog_curl <secret> <curl args>` (curl reads the header from a config on
  a file descriptor; no here-string). The 8 callers use them:
  watchdog-ping, watchdog-poll, progress-push, tickets-snapshot-push,
  cost-rollup, state-restore `--standby`, fleet-status-push and
  mac/mac-burn-push. The Mac reads `~/.orgo/.watchdog-secret`, else
  `~/.orgo/.harness-secret`.
- `.github/workflows/publish-cromford.yml` pipes the stamp header to `curl -K -`.
- watchdog-poll and fleet-status-push used HARNESS_SECRET only for the
  watchdog. They now use the same lookup as the ping, so a box's
  `env/.watchdog-secret` wins there too.

## Operator steps (outside this repo)

1. `wrangler secret put WATCHDOG_SECRET` on harness-watchdog, a new value that
   differs from its `HARNESS_SECRET` binding.
2. `env/.watchdog-secret` (mode 600) on every box, and `~/.orgo/.watchdog-secret`
   on the Mac, with that value.
3. Change the harness-console watchdog proxy (`example-org/cromford-console`)
   to send `Authorization: Bearer <WATCHDOG_SECRET>`. Until then its GETs show
   as `query-auth` lines.
4. After the deploy, count 24 h of `watchdog query-auth` and
   `watchdog fallback-auth` lines and post the count on #9264.

The order of steps 1-3 is free: phase 1 accepts both secrets on both transports.

## Phase 2 condition

A later PR removes `?s=` and the HARNESS_SECRET fallback, and a refused request
then answers 401. It ships only after 24 h with 0 `query-auth` and 0
`fallback-auth` lines.

## Tests

`tests/watchdog-auth.bh-9264-test.sh` (runs `worker/watchdog/test/auth.bh-9264.test.js`
through the real fetch export) and `tests/watchdog-auth-callers.bh-9264-test.sh`
(the 8 callers and the workflow step with a recording fake curl: no secret in
argv, no `s=` in a URL, the Bearer header in the curl config).
