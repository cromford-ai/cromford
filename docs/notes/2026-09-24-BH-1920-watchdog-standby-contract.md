# Watchdog warm-standby contract: KV shape, failoverTick stub, node test runner

Doc: watchdog-spec

## What changed

BH-1920, order 1 of 5 under #401 (warm-standby hub). This lays down the shape
the other four children build on. It adds no routes and no promotion logic, and
it writes no KV.

- `worker/watchdog/src/standby.js` has the key helpers (`STANDBY_PREFIX`,
  `standbyKey(box)`, `failoverKey(epoch)`), `snapshotAgeMin(id, nowMs)` and
  `listStandbys(env, nowMs)`.
- `worker/watchdog/src/failover.js` exports `failoverTick(env, t)`. It does
  nothing yet. The failover child fills it in.
- `scheduled` in `worker/watchdog/src/index.js` has a step 4 that calls
  `failoverTick` inside its own try/catch, after steps 1-3. A throw there gets
  logged and can't suppress a liveness alert. `BOXES` and `HUB` are unchanged.
- `worker/watchdog/package.json` sets `npm test` to `node --test test/*.test.js`.
  It has no dependencies, so there's no lockfile.
- `tests/watchdog-failover.bh-401-test.sh` runs that node suite from the
  `tests/*.sh` loop. Its exit code is node's, so CI picks it up without a
  `harness-ci.yml` edit.
- The BH-1137 guard (`tests/harness-ci-worker-jobs.bh-1137-test.sh`) used to
  require a workflow job for every `worker/*` package with a test script. It
  now also counts a `tests/*.sh` runner that `cd`s into `worker/<name>` and
  runs `node --test` or `npm test` there. Without that change, this PR's
  package.json would have turned the guard red. The guard runs its new rule
  against fixture trees, so a runner that only mentions the directory in a
  comment, or runs no tests, still fails.

## KV shape

| Key | Value | Written by |
|---|---|---|
| `standby:<box>` | `{ts, of, snapshot, ok}`: `ts` ms epoch, `of` the hub it streams from, `snapshot` a `YYYYMMDDTHHMMSSZ` id, `ok` boolean | the watchdog, from the standby's POST `{of, snapshot, ok}` (it adds `ts`) |
| `failover:<epoch>` | `{ts, from, to, result}`, result `pending`, `promoted` or `failed:<status>`, 30-day TTL | the failover child |

`listStandbys` reads every page of `standby:` keys and skips any value that
isn't a JSON object. Each row is `{box, of, snapshot, ok, report_age_min,
stream_age_min}`. Both ages are whole minutes, floored. `stream_age_min` is
null for a snapshot id that doesn't parse (including calendar-invalid ones like
month 13). `report_age_min` is null when `ts` or `nowMs` isn't a finite number. Neither
age ever falls back to 0.
