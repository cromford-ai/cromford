# BH-9407: the pool `machines list` retries, keeps the last good list, and names the error class

Date: 2026-11-24. Alert: 61289 (`pool-project-6-os`, dead-machine sweep skipped).

## What changed

- `bin/fly-pool.sh` (fragment `config/fly-pool.d/3350-bh-9407-listing-retry.sh`, called from 3400 and 3500):
  - A failed `machines list` call is retried. Waits: lane knob `POOL_LIST_RETRY_BACKOFF_S`, default `2 5 15` (4 calls).
  - Only the classes `timeout`, `api` and `other` with rc not 126/127 are retried. `auth`, `app-not-found`, a missing binary, a rc-0 answer and `[]` beside tracked files are not.
  - Each usable list is saved to `state/fly-pool-listing/<p>.json` (a cache path, `catalog/state-paths.d/9407-fly-pool-listing.json`) after the sweep, minus every machine a destroy removed that tick.
  - When every try fails, a non-empty saved list younger than `POOL_LIST_SAVED_MAX_AGE_S` (default 600) drives the sweep only. `LIST_OK` stays 0: the REAP asks `machine status`, no observe is sent, no build is requeued, and the orphan pass does not run.
  - The alert line and `.sweep.json` carry `class <c>, <n> tries`. The reason text is scrubbed of the Fly token.
- `destroy_machine` (2200) records each removed machine in `$LISTING.destroyed`.

## Why the saved list drops destroyed machines, and an empty one is not used

A saved list that still names a machine this hub destroyed would send a second destroy for it. An empty saved list has nothing to destroy, so the tick reports a dark sweep, as before. Both rules also keep `tests/fly-pool-sweep-test.sh` (not edited in this change) green: its §6 failing ticks run after good ticks whose machines were all destroyed.

## How to check

`HARNESS_TEST_SANDBOX=1 bash tests/fly-pool-sweep.bh-9407-test.sh`. The contract is in `docs/verification-map/fly-pool-sweep.md`.
