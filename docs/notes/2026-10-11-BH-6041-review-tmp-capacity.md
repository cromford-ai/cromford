# Lead reviews ran 1 at a time: /tmp leftovers and a 4 GB tmpfs (BH-6041)

Doc: tmp-sweep, OPERATING

## What changed

- `bin/tmp-sweep.sh`: the default `TMP_SWEEP_PATTERNS` replaces `bh[0-9]*-*`
  with `bh[0-9]*` and adds `pr[0-9]*`, `lr[0-9]*` and `rules-pack-snap.*`.
  `MIN_AGE_MIN` (180) and every keep-rule are unchanged. Bare `pr*` and `bh*`
  are not in the list: they match tool caches such as `prisma-engines`.
- `bin/lib/review-pool.sh`: a lane that sets `RPOOL_TMP_PREFIX` gives each
  worker its own dir, `<tmp path>/<prefix><tickpid>-<id>` (mode 711), exported
  as `RPOOL_TMP_OWN`. The worker's EXIT trap removes it (normal exit, TERM).
  After a SIGKILL the tick's collect removes it. `rpool_finish` removes any
  `<prefix><tickpid>-*` left. The pool also sets `RPOOL_CAP_WHY`, the text of
  its `concurrency capped` line. `bin/review-prs.sh` sets no prefix and does
  not change.
- `bin/lead-review.sh`: sets `RPOOL_TMP_PREFIX=lr`. A worker points
  `RULES_PACK_SNAPSHOT_TMP` at its own dir, so the rules pack's
  `rules-pack-snap.*` snapshot goes with the worker.
- `bin/lib/lead-review-capped.sh` (new): after `rpool_init`, when /tmp or memory
  caps concurrency below `LEAD_REVIEW_CONCURRENCY` (or below
  `LEAD_REVIEW_CAP_ALERT_MIN`, 4, when concurrency is 0) for
  `LEAD_REVIEW_CAP_ALERT_AFTER_MIN` (30) minutes, one warn goes through
  `bin/lane-alert.sh` with id `lead-review-capped-<box>`. The first uncapped
  tick resolves it. A `LEAD_REVIEW_BOX_MAX` cap never warns. State:
  `state/lead-review-capped.<box>`, `<first capped epoch> <0|1 warned>`.
- `bin/tmpfs-ensure.sh` (new): sizes a tmpfs /tmp at `TMPFS_RAM_PCT` (50) percent
  of MemTotal, whole GB, never below 4G. It remounts only to grow, and it writes
  or updates one fstab line so a reboot keeps the size. It does nothing when
  /tmp is not a tmpfs. `bin/bootstrap-machine.sh` runs it (`== tmpfs ==`) and
  `bin/update-runners.sh` runs it daily. Log: `logs/tmpfs-ensure.log`.
- Knobs: `LEAD_REVIEW_CAP_ALERT_AFTER_MIN` and `LEAD_REVIEW_CAP_ALERT_MIN` on
  lead-review; `TMPFS_RAM_PCT` on update-runners.

## Why

On 2026-10-11 box-small logged `concurrency capped at 1 by /tmp` on
every lead-review tick from at least 15:06Z, and 6 requests waited each tick.
/tmp was a 4 GB tmpfs. A 2-day-old `/tmp/bh5775` held 1.1 GB, and no sweep
pattern matched it. On review-2 the operator's 8 GB remount had no fstab line.

## Operator check

- `bin/tmp-sweep.sh --dry-run` lists any `bh<N>`, `pr<N>` or `lr<N>-*` older
  than 180 min.
- `bin/tmpfs-ensure.sh --dry-run` prints the size it would declare and what it
  would do. review-2 is not a fleet box, so update-runners does not reach it:
  run `bin/tmpfs-ensure.sh` there by hand.

Tests: `tests/tmp-sweep.bh-6041-test.sh`, `tests/review-pool-tmp-own.bh-6041-test.sh`,
`tests/lead-review-capped-alert.bh-6041-test.sh`, `tests/tmpfs-ensure.bh-6041-test.sh`.
