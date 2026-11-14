# Gate: pre-queue fresh main

owner: BH-9559.8

The builder's pre-PR selection gate (`bin/selection-gate.sh`, BH-8062) runs the
merge-queue batch's own selection on the test host. Since BH-9697 it runs that
selection on the PR **merged with fresh main**, and a suite that main itself
breaks is quarantined instead of failing every build.

## Step 1b: fresh main

Switch: the fly-pool knob `SELECTION_GATE_FRESH_MAIN` (default 1;
`bin/lib/selection-gate.sh` passes it). The script alone defaults to 0.

1. The gate fetches the tip of origin's `main` into a private ref
   `refs/harness/sg-fresh-main-<pid>`, under `timeout SELECTION_GATE_FRESH_FETCH_S`
   (default 60). It reads the sha and deletes the ref at once.
   `SELECTION_GATE_FRESH_REF=<ref>` names a local ref instead (a test seam).
2. `git merge-tree --write-tree` merges main onto HEAD.
3. `git commit-tree` wraps the tree in a commit with parents HEAD and main. No
   ref points at it and nothing pushes it.
4. The gate checks that commit out as a detached worktree. Steps 2 to 6 run
   there, with main's tip as the base. The planner sees `TI_BASE=<main>` and
   `HEAD=<merged>`, which is what the batch sees. The suite ledger (BH-9177)
   fingerprints the merged tree.
5. gate.txt `head:` stays the PR head. `base:` is main's tip.

Any other outcome writes one `fresh-main: off (<why>)` line, and the gate runs
on HEAD as before:

| why | when |
|---|---|
| `cannot resolve <ref>` | `SELECTION_GATE_FRESH_REF` does not name a commit |
| `no origin remote` | the checkout has no `origin` |
| `fetch of origin main failed (rc N)` | the fetch failed or passed its timeout |
| `head already contains main <sha12>` | nothing to merge |
| `head conflicts with main <sha12>` | merge-tree rc 1 |
| `merge-tree failed (rc N)` | any other merge-tree failure |
| `commit-tree failed` | the commit object could not be made |
| `no worktree` | no temp dir, or `git worktree add` failed |

One EXIT trap (`_sg_cleanup`) removes the base-run worktree and the merged
worktree on every exit (green, red, could-not-run, no-selection).

## Suite quarantine

Switch: the fly-pool knob `SELECTION_GATE_SUITE_QUARANTINE` (default 1). The
script alone defaults to 0. The row write needs the base run
(`SELECTION_GATE_BASELINE_RUN=1`, BH-8901).

- **Gate step 5.** A red suite with an active `suite_quarantine` row moves to
  `quarantined:`. A suite that the diff changes stays red, whatever its row
  says.
- **Gate step 6.** A suite that is red on the merged tree, red on main (the
  base run), and not changed by the diff gets an active row
  (`bin/jobs-client.sh suite-quarantine-put`). It moves to `quarantined:`
  only when the write returned rc 0. A failed write keeps it on
  `baseline-red:` and adds ` write-failed <suite>`. More than
  `SELECTION_GATE_QUARANTINE_MAX_NEW` (default 3) candidates in one run writes
  none and adds ` quarantine-cap: <n> > <max>`. Many suites red on main at once
  looks like a host problem.
- A list that cannot be read (no `REPO_SLUG`, a worker error) adds
  ` unreadable`. Then no suite moves on a row and no row is written.
- A quarantined suite does not fail the gate. It is on none of `red:`,
  `noted:` and `baseline-red:`.

### The lifecycle

1. The gate writes the row (`worker/jobs/schema.d/202611141237-bh-9697-suite-quarantine.sql`,
   one active row per (repo, suite)).
2. `bin/flaky-tier.sh` step 4b (hub, daily) files ONE `ai-build` repair
   ticket `[suite-quarantine] <suite>` per row with no `repair_issue`. An open
   issue with the marker `<!-- harness-suite-quarantine: <suite> -->` is
   reused. At most `SUITE_QUARANTINE_MAX_NEW` (default 3) new tickets per tick.
   The ticket comes first, the row link second.
3. `bin/flaky-tier.sh` step 6 projects the active rows into `CI_QUARANTINE`,
   with the flaky rows. `bin/ci-plan.sh` batch mode drops them through its
   `--quarantine` path. A protected suite is never projected.
4. `bin/flaky-tier.sh` step 5b releases a row when the newest cached scheduled
   nightly run that is newer than the row, on a sha other than
   `main_sha_red`, has the suite green. The next projection drops it.
5. The worker deletes a released row after `suite_quarantine.retention_days`
   (60). An active row is never deleted.

`SUITE_QUARANTINE_ACT=0` skips steps 4b and 5b. `--dry-run` and
`FLAKY_TIER_ACT=0` write nothing.

## gate.txt lines

After the `reuse:` line, only with the quarantine switch on:

    quarantined: <comma list|->[ unreadable][ quarantine-cap: <n> > <max>][ write-failed <suite>]…

Last, only with the fresh-main switch on:

    fresh-main: <on <main12>|off (<why>)|->

`-` means the run stopped before step 1b (no head, no merge base). Every
gate.txt reader reads by line prefix, so the two lines change no existing
read. `bin/lib/selection-gate.sh` adds ` quarantined=<n>` to its log line.

## Knobs

| knob | lane | default |
|---|---|---|
| `SELECTION_GATE_FRESH_MAIN` | fly-pool | 1 |
| `SELECTION_GATE_FRESH_FETCH_S` | fly-pool | 60 |
| `SELECTION_GATE_SUITE_QUARANTINE` | fly-pool | 1 |
| `SELECTION_GATE_QUARANTINE_MAX_NEW` | fly-pool | 3 |
| `SUITE_QUARANTINE_MAX_NEW` | flaky-tier | 3 |
| `SUITE_QUARANTINE_ACT` | flaky-tier | 1 |
| `suite_quarantine.retention_days` | settings row | 60 |
