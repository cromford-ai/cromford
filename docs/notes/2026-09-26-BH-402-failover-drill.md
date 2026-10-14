# Failover drill: renew pause, cron proposal, runbook (BH-402.4, BH-2750)

Doc: HUB-THINNING-PLAN

## What changed

- **Renew pause.** `bin/hub-lease.sh renew` now reads
  `flags/hub-lease-renew-paused` before any request. The file holds an integer
  epoch deadline (the format `FD_RENEW_PAUSE_FLAG` documents in
  `bin/lib/failover-drill-common.sh`). While now is before the deadline, renew
  logs `renew: paused by flags/hub-lease-renew-paused until <iso>` and exits 1
  with no worker call. A deadline at or before now, an empty file, or a
  non-integer one is deleted, logged as `renew: pause flag expired/invalid,
  removed`, and renew runs as before. With no file, the request is
  byte-identical to the old one. `check` and `promote` do not read the file.
- **Cron proposal.** `cron/boxes/hub.d/696-failover-drill-proposal.cron` is
  three comment lines. It adds nothing to any crontab. The proposed line has no
  `hub-lease.sh check &&` prefix: `render-crontab.sh` adds that gate itself
  once the line moves to `cron/lanes/` under `# @hub-lanes`, and
  `tests/hub-cron-gated-test.sh` counts the prefix even on comment lines.
- **Runbook.** `docs/HUB-THINNING-PLAN.md` has a new `## Failover drill
  (BH-402)` section: preconditions, expected noise, the command, reading the
  report, committing it, manual failback, and the env knobs.

## Why

The drill holds the hub's lease back on purpose so the watchdog promotes the
standby. If the drill is SIGKILLed mid-run, nothing is left to clean up the
pause. A self-expiring deadline in the flag means the next renew after that
deadline removes it, so the hub can never stay unrenewed past it.

## Touches

- Command: `bin/hub-lease.sh renew`.
- State: `flags/hub-lease-renew-paused`, `logs/hub-lease.log`.
- Test: `tests/hub-lease-renew-pause.bh-2750-test.sh`.
