# The extra-usage meter pages back, says why a poll failed, and is loud when it fails or freezes (BH-3985)

Doc: COST

## What changed

- `GET /api/metrics/extra-usage` takes `until`, the cost-rows convention:
  inclusive and newest-first. A caller that got a full page asks again with
  `until` = the oldest `ts` it saw and dedupes on `(box, ts)`, the primary key.
  The order is now `ts DESC, box DESC` so two pages never split same-second rows
  differently. The response echoes `until` (null when unset). The limit cap is
  still 1000. `bin/cost-reconcile.sh` and `bin/lib/extra-usage-read.sh` send no
  `until` and read exactly what they read before; teaching them to page is not
  part of this change.
- `extra_usage_snapshots` has a new `error_body TEXT` column (schema.sql CREATE
  plus `ensureColumns`, additive). The POST stores `error_body` with
  `COALESCE`, so a replay that sends none keeps the stored one.
- `bin/extra-usage-track.sh` keeps the vendor's HTTP error body after
  `HTTP Error NNN` on stderr, and a failed poll posts it as `error_body`
  (13th argument of `metric_extra_usage` in `bin/lib/jobs/cost.sh`). It is one
  line, at most 1500 characters, with `Bearer <x>` and `sk-ant-…` replaced by
  `[redacted]`. The CSV keeps its 11 columns.
- Two new alerts, each at most once per UTC day per login (a
  `flags/alerted-extra-usage-{errors,flat}<suffix>-<YYYYMMDD>` file, touched
  only when the alert went out):
  - `extra-usage-errors-<label>` (warn) when the last `EXTRA_USAGE_ERROR_STREAK`
    (default 3) CSV rows are all `status=error`. A `no-login` or `ok` row ends
    the streak. An ok poll resolves it.
  - `extra-usage-flat-<label>` (warn) when the meter's READINGS have held one
    value for at least 12h, every one of those readings was in overage
    (`in_overage=1`: extra enabled, weekly at 100% or more, spend limit not
    reached), and `GET /api/metrics/account-usage?window=12h` says
    the account's priced cost rows over those 12h are more than
    `EXTRA_USAGE_FLAT_MIN_USD` (default 5). A failed read, an absent label or
    `usd: null` never fires and never clears; the run log says which. The worker
    read happens only when a meter is locally flat in overage. The meter only
    moves past the weekly credits, so a still meter inside them is normal (the
    same doctrine as cost-anchored's `fully_overage`): a 12h-flat run that was
    not in overage the whole time never reads the worker, never fires, clears a
    firing alert, and logs `no alert: not in overage for the last 12h`. A meter
    that moved resolves it.
  Both knobs are registered on the `extra-usage-track` lane, so a settings row
  reaches them. A non-integer (and, for the streak, `0`) falls back to the
  default, and the per-run `extra-usage-track loud:` line names the value in
  force and where it came from.
- `GET /api/metrics/account-usage` accepts `window=12h`.
- `meterAccounts` (`worker/jobs/src/lib/core.js`) no longer puts failed polls
  (`extra_used_usd` NULL) into the meter span. They are counted as
  `failed_polls`, and `snapshots` counts readings. A span whose first or last
  poll failed used to lose its delta, so cost-anchored reported
  `operator@example.com` as `unmeasured` ("a poll in this span carried no meter
  value") while its meter moved. An account whose every poll failed now reads
  `unmeasured` with "every meter poll in this window failed (N)", not
  `no-login`. The `fully_overage` rule is unchanged and now applies to readings.
  cost-anchored accounts carry `failed_polls`. account-usage `meter.polls` counts
  readings, which also changes what `xcheck_accounts` can compare: a failed last
  poll no longer suppresses the gap alert.

## Why

The Oct 3 report: history older than about 10 days could not be read, the
project-6 meter sat at $13.93 with `error` rows and nothing paged, and
cost-anchored said no account was metered while one was.
