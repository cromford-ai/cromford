# One full conductor tick per project; the autoenqueue ledger read retries once (BH-5463)

Doc: MERGE-CONDUCTOR

## Why

On 2026-10-08 the cromford merge queue stayed empty while approved PRs waited.

1. wake-loop started an unkeyed conductor tick every 12-15 min. Each tick ran
   536-1167 s. Two full ticks of one project ran at the same time, and the
   second one found the PR locks held: tick `20261008T080038Z-8739` counted
   `locked=82` of 100. It still spent the same API and re-review budget.
2. From 08:15:32Z to 08:15:39Z, `job_ledger_get autoenqueue` answered rc 1 for
   18 READY PRs in a row. G2 skipped each one, so nothing was sent that tick.
   At 08:21Z the same reads answered rc 2. The log did not name the HTTP code.

## What changed

- **Full-tick lock.** In the per-project loop of `bin/merge-conductor.sh`
  (block `>>> full-tick lock (BH-5463)`), a full (unkeyed) tick takes
  `locks/merge-conductor-<project>-fulltick.lock` with `flock -n` on fd 5. If
  another full tick holds it, the tick logs one line and that project stops:

  ```
  TICK <p> skipped: another full tick of <p> is still running (locks/merge-conductor-<p>-fulltick.lock) — keyed ticks still run (decision=skipped-tick-running)
  ```

  A skipped tick writes no `TICK <p> tick=` line and does not touch
  `tick-<p>.json`. The subshell that holds the lock only waits. `tick_project`
  runs in an inner subshell with fd 5 closed, so no detached lane (rebase,
  re-review, deploy verify, batch resolve) can hold the lock. Keyed ticks
  (`MC_ONLY_PR`) never take it. The per-PR, merge and git locks do not change.
- **Ledger retry.** `_ae_status` in `bin/lib/autoenqueue.sh` reads the ledger
  once more after 2 s when the answer is rc 1 and the file ledger has no line.
- **The code in the skip line.** `_jobs_req` (`bin/lib/jobs/req.sh`) writes one
  word to `$JOBS_STATUS_FILE` when the caller sets it: `http=<code>`,
  `curl_rc=<n>`, `no-secret` or `no-url`. Unset means no write. The G2 skip
  line now reads, for example:

  ```
  AUTOENQUEUE <slug>#<n> not enqueued at <h8>: ledger — the autoenqueue ledger is unreadable (http=503, retried once after 2s) and the file has no line — nothing sent this tick
  ```

- **Burst alert.** More than `MC_AE_LEDGER_BURST` (default 5) ledger skips in a
  row in one project tick give ONE `AUTOENQUEUE` alert through `mc_alert`. It
  names the count, the PR keys and the last code. After the alert, the rest of
  that tick reads the ledger once per row (skip text: `no retry: the ledger
  burst alert fired this tick`), so a hard outage costs at most
  `MC_AE_LEDGER_BURST + 1` retries.

## Knobs (settings rows, `catalog/lanes.d/merge-conductor.json`)

| Settings key | Default | 0 means |
|---|---|---|
| `lane.merge-conductor.mc_full_tick_single` | 1 | overlapping full ticks run, as before |
| `lane.merge-conductor.mc_ae_ledger_retry` | 1 | one ledger read, as before |
| `lane.merge-conductor.mc_ae_ledger_burst` | 5 | (min 1) |

## How to check it on the hub

1. `grep -E 'TICK cromford (tick=|skipped:)' /root/harness/logs/merge-conductor.log | tail -50`.
   No two `tick=` lines of one project overlap in time. `locked=` stays low.
2. `grep 'AUTOENQUEUE .* ledger' /root/harness/logs/merge-conductor.log | tail`.
   Every ledger skip names `http=` or `curl_rc=`.

Suites: `tests/conductor-full-tick-lock.bh-5463-test.sh`,
`tests/autoenqueue-ledger-retry.bh-5463-test.sh`.
