# Main-red: re-check flagged repos every 5 minutes (BH-6502)

Doc: MERGE-CONDUCTOR, VERIFICATION-MAP, OPERATING

## What happened

On 2026-10-13 the main-red freeze on `example-org/project-6` stayed up for most of
an hour after main was green again, two times (after the 12:30Z green, and from
the 15:26Z red flagged at 16:03Z to an operator's hand run at 16:34Z).

## Cause

`bin/main-red-detector.sh` has no cron line. Its only caller is the merge
conductor's FULL tick (`bin/merge-conductor.sh`, `[ -z "$MC_ONLY_KEYS" ]`).
Wake-loop runs of the conductor are keyed and do not run it. Full ticks pass
`bin/lib/cadence-backstop.sh merge-conductor`, which defaults to 60 minutes
(BH-5521). So the detector ran once an hour, at :02-:03. BH-6352 put flagged
repos first in that pass. It did not change how often the pass runs.

## What changed

- New hub lane `main-red-recheck`: `bin/main-red-recheck.sh`, cron `*/5`
  (`cron/lanes/341-main-red-recheck.cron`, behind `bin/hub-lease.sh check`),
  registry row `catalog/lanes.d/main-red-recheck.json`.
- With no `flags/main-red-<owner>-<repo>` freeze up, the lane exits. It makes no
  GitHub read and does not start the detector. The two switch files
  `main-red-detector-off` and `main-red-pr-pair-off` are not freezes.
- With a freeze up, at most every `MAIN_RED_RECHECK_MIN` minutes, it writes
  `state/main-red/recheck.last` (epoch seconds) and runs
  `bin/main-red-detector.sh --flagged-only`.
- `--flagged-only` resolves the repo list as the hourly pass does, keeps only
  the slugs whose flag is up (list order), and runs the same per-repo loop. No
  flagged slug in the list = exit 0 with no line. It does not log stray flags.
- The hourly pass in the merge conductor is unchanged.

## Knob

Settings row `lane.main-red-recheck.main_red_recheck_min` (minutes), then env
`MAIN_RED_RECHECK_MIN`, then 5. 0 = off. A value that is not a whole number is
5. A run is allowed 30 s early for cron jitter. No row is seeded: prod runs 5.

## Cost and the log line

One Actions runs read per flagged repo per tick. The existing extra reads fire
only in their existing cases (queue arm repos, burst re-read, jobs read on a new
red sha, confirming re-read on a first raise). Each recheck pass logs the real
count in `logs/main-red.log`:

    pass start: recheck, <n> flagged repo(s): <slugs>
    recheck: <n> flagged repo(s), <r> Actions read(s)
    pass end: decided ...

## Kill switch

`bin/harness-ctl.sh off main-red-recheck` (`flags/lane-off-main-red-recheck`),
or set the row to 0. `main-red-detector-off` still stops the detector itself.

## Measurement after deploy (ticket acceptance 4)

For each of the next 3 red-to-green events in `logs/main-red.log` on the hub:

1. Take the green run id from the resolve alert's run URL.
2. Run `gh api repos/<slug>/actions/runs/<id> -q .updated_at`.
3. Take the clear time from the `recheck:` tick that cleared the flag in
   `logs/main-red.log`.
4. Post the three differences on BH-6502. The target is under 6 minutes.

Test: `tests/main-red-flagged-recheck.bh-6502-test.sh`.
