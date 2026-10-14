# Main-red pass: flagged repos first, and no silent skip (BH-6352)

Doc: VERIFICATION-MAP, OPERATING

## What happened

On 2026-10-13 the main-red freeze on `example-org/project-6` stayed up 39 minutes
after main was green again.

- Run 38322322575 (`ci`, sha `547879e4`) failed. The 00:04 pass raised the flag
  and set the ledger floor to `total=64 newest=2026-10-12T23:28:36Z`.
- The run was re-run. Attempt 2 ended `success` at 00:24:29Z. A re-run keeps
  its `created_at`.
- The scheduled pass at 00:42 logged repo 6 (`example-org/project-6-runtime`).
  It logged nothing for repos 7-13. `example-org/project-6` is repo 13, the last
  row of `fleet.conf`.
- At 00:43:26 an explicit run took `locks/main-red-detector.lock`. So the
  scheduled pass had ended by then. At 00:43:38 the explicit run cleared the
  flag (`main is green again on 547879e4 (ci)`).

## The three candidates

1. **The BH-1927 floor rejects a re-run page.** False. `mr_stale` calls a page
   stale only when its newest `created_at` is strictly older than the floor.
   The live page's newest run is 38322322575 with the floor's own `created_at`.
   The stale path also logs a line, and the 00:42 pass logged none.
2. **The pass ended before it reached the repo.** This is the cause the
   evidence fits. The detector has no time budget. It runs inside every full
   `bin/merge-conductor.sh` tick, serially, in `fleet.conf` order.
3. **A slug or flag-name collision between `project-6` and `project-6-os`.**
   False. `project-6` maps to `example-org/project-6-runtime`. Every per-repo key
   (flag, verdict file, ledger row, operator-clear map) is the whole slug.

## What changed

All in `bin/main-red-detector.sh`. No decision rule changed.

- A scheduled pass (no repo arguments) judges every repo with a
  `flags/main-red-<owner>-<repo>` file first. Both groups keep `fleet.conf`
  order. A run with repo arguments keeps its order.
- Each pass logs `pass start:` and `pass end:` lines. The end line gives the
  repos decided, the seconds, the exit code, the signal and the last repo.
- A flagged repo that a pass does not decide gets one line in
  `logs/main-red.log`: `<slug>: decision=none reason=<why> flag=<name>`. The
  reason is the verdict's own (`stale-page`, `no-runs`, ...), or `not-reached`
  (the pass ended first, from an EXIT trap with TERM/INT/HUP traps).
- A flag that no repo in a scheduled pass maps to gets
  `reason=not-in-repo-list`. A pass that finds the lock held logs
  `reason=lock-held` for each flag. With no flag up, both stay quiet.
- `--explain` logs none of these lines and installs no trap.
- A SIGKILL cannot be trapped and leaves no line. The next pass judges the
  flagged repo first.

Test: `tests/main-red-rerun-clear.bh-6352-test.sh`. Case R2 replays the
13-repo fleet with repo 7's read hung and the pass killed at 8 s. The
project-6 flag clears.

## Not known

Which event ended the 00:42 pass is not known from the build box. A kill of
the conductor tick and a shell abort give the same symptom. To find it, run
this on the hub:

```bash
grep -E '^2026-10-13 00:(3|4[0-3])' /root/harness/logs/main-red-detector.log /root/harness/logs/merge-conductor-cron.log
```

From now on the `pass end:` line names the exit code and signal of the pass.
