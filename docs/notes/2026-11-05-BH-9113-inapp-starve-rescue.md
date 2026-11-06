# BH-9113: a starved ready ticket on an in-app board gets a launch attempt; no shard for a ticket that is building

Doc: TRIAGE-STATE

## Why

project-3, 2026-11-05. 15 tickets with `triageVerdict=ready` and `waitingOn=team`
had no launch from about 15:19Z to 21:40Z. The build queue was empty. Two
causes:

1. `tsv_pass` (`bin/lib/triage-starve.sh`) acted only on a GitHub board. An
   in-app board recorded `n/a: in-app board` and nothing acted on the key.
2. The shard loop (`rt_shards`, `bin/lib/rt/shards.sh`) gave TK-698 a slot at
   20:36, 20:46, 20:56, 21:06 and 21:16Z while its build ran. Each shard ended
   `claim refused: ticket :: ticket max 1 already running`.

## What changed

1. **The in-app attempt.** Each eligible in-app key (same order, same
   `TRIAGE_STARVE_FASTPATH_MAX` cap) gets one `_tsv_inapp_try`: the board
   snapshot's `status`, `triageVerdict` and `waitingOn`, then the `ts_enqueue`
   launch guard `_ts_owned`, then the `.enqueued` marker and
   `bin/run-build.sh` through the new `_ts_spawn_build`
   (`bin/lib/triage-state.sh`, shared with `ts_enqueue`). The ledger column 7
   is `launched` or `declined: <reason>`. The lane line ends `— inapp launched`
   or `— inapp declined: <reason>`. No model call.
2. **The pause.** A live builds pause now withholds the attempt on an in-app
   board too.
3. **The knob.** `TRIAGE_STARVE_INAPP_LAUNCH` (default 1; row
   `lib.triage-starve[.<p>].triage_starve_inapp_launch`). 0 restores the
   `n/a: in-app board` record.
4. **The shard skip.** `bin/lib/shard-building.sh` reads `job_builds_running`
   once per tick into `state/triage-shards/<p>/.building.tsv`. A key with a
   running build row, or a held `locks/build-key-<p>-<key>.lock`, gets no
   shard, no slot and no fingerprint stamp. One line per key:
   `triage shards: <K> skipped — build running (<why>); ...`. The key is
   re-armed. The summary line gains ` — building: <keys>`. An unreadable
   census skips nothing; the claim in `bin/triage-shard.sh` stays the backstop.

## Tests

`tests/triage-starve-inapp.bh-9113-test.sh`,
`tests/triage-shards-building.bh-9113-test.sh`. Case I1 of
`tests/triage-starve.bh-8475-test.sh` now pins the `n/a` record behind the
switch.
