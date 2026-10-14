# Ten seed families for alert_family_scripts, with their verify scripts (BH-2577, BH-2544.4)

Doc: ALERT-REMEDIATION

## What changed

- **`worker/jobs/schema.sql` seeds ten `alert_family_scripts` rows**, one
  `INSERT OR IGNORE` each. They carry `on_clear='settle'`, `on_repro='model'`,
  `actor='seed-bh-2544'`, `enabled=1` and priorities 10 to 100. A re-apply never
  resets an operator's edit.
- **`bin/alert-verify/<id>.sh`: ten read-only verify scripts.** They follow the
  protocol in the header of `bin/triage-family-scripts.sh`. Exit 0 plus a proof
  line means cleared, 1 means it still reproduces, and 75 means any doubt
  (a rate limit, a 404, an absent row, a missing file, or two different subjects
  in one family). Each makes at most two reads and reads at most 20 KB of any
  log. None of them contains a model id.
- **`bin/lib/alert-verify.sh`** is the shared stdin parsing (`av_field`,
  `av_one`) and the PR-state read through `bin/gh-pr-state.sh`. It also sets
  `GH_ETAG=0` and `GH_REST_OPTIONAL=1`, so a verify is the first read the quota
  reserve refuses.

Nothing reads the rows yet. The runner is still the BH-2568 no-op until the
runner sibling lands.

## The ten rows

| pri | id | match | cleared when |
|---|---|---|---|
| 10 | mc-state-note | line `conductor: <slug>#<n> <STATE> ` | gh-pr-state reads MERGED/CLOSED (a line whose own state is terminal is doubt) |
| 20 | pipeline-health-clean-open | akey `health:sweepstall:` | the PR named in the akey is not OPEN |
| 30 | merge-queue-pr | line `Merge queue: #<n> ` | the PR is not OPEN |
| 40 | main-red | line `[orchestrator/main-red] <slug> main is (STILL )?RED` | every check-run on main completed, none failed, at least one success |
| 50 | ghdefault-visibility | line `DEFAULT GH TOKEN CANNOT SEE <slug> ` | GET repos/<slug> on the inherited default token answers 200 |
| 60 | hb-db-silent | line `<lane> on <box> is silent\|overdue: its last beat was <N>m ago` | `jobs-client.sh lane-procs` reads fresh or ended |
| 70 | lane-silent | line `[jobs-watchdog] LANE SILENT: <project>@<box> ` | `jobs-client.sh lanes` reads live |
| 80 | deferral-backlog | line `[alert-triage] DEFERRAL BACKLOG: <n> lines spooled` | the spool is not over TRIAGE_SPOOL_ALERT (the lane pages only above it), read between ticks: while the alert-triage lock is held a short spool is doubt (75) |
| 90 | fleet-propagate-partial | line `[orchestrator/fleet-propagate] propagating <sha> … FAILED in part` | the last run line for that sha, in the last 20 KB of the log, is clean |
| 100 | pr-url-reconcile-verdict | akey `prurlreconcile:verdict:` | the PR is closed, or `vd_standing` finds a verdict for its current head |

## Where this departs from the ticket's default set, and why

- **`hb-stale` became `hb-db-silent`.** `bin/fleet-heartbeat.sh`, the only
  emitter of `hb-stale`, was deleted in BH-1031. The heartbeat-reaper's DB page
  is its successor.
- **`sweepstall` became `lane-silent`.** `health:sweepstall:` is the same alert
  as the pipeline-health row, so priority order would make a second row on it
  unreachable. The lane-tick clearing rule the ticket gave belongs to the
  jobs-watchdog's LANE SILENT page.
- **Line regexes, not the ticket's akey prefixes, for most rows.**
  `bin/lane-alert.sh` re-keys its beats to `orclane:<ID>`, so `conductor:`,
  `main-red-` and `ghdefault-` never appear as the akey. `akey_prefix` is used
  only where the emitter writes the akey itself.
- **Staleness is the worker's own state**, not a 15 min / 2x cadence threshold
  recomputed in the script. That keeps one definition shared with the pager.
- **"Has a verdict row" means a standing verdict for the PR's current head.**
  A verdict on an older head is exactly what "owes a verdict" pages about.
- **`deferral-backlog` never clears from inside a tick.** The tick drains the
  spool (`bin/alert-triage.sh:185`) before the family registry runs and puts
  the backlog back after it (`:1264`). Read mid-tick, the file shows only new
  arrivals, so a clear from it would settle a live page. The script checks the
  lane lock before and after the read. While the lock is held, a spool at or
  under the cap is doubt (75) and one over it is a repro (1). From its only
  caller today, the row therefore settles nothing, and the family still goes
  to a session. A true in-tick clear needs the lane to record its post-respool
  depth, which is the lane's change to make, not this slice's (D25). The suite
  pins the drained-spool state with the lock held on an inherited fd, the same
  shape as the real call. It cannot stage a tick that starts between the two
  lock checks, so the check before the read has no test that fails without it.

## Tests

`tests/alert-verify-seeds.bh-2577-test.sh` drives every script with a cleared,
a reproducing and a doubt fixture, and checks that no run writes a file. It
applies the schema twice and pins the ten rows. It also checks each matcher
against its family's line and the adversarial negatives.
`tests/alert-triage-hooks.bh-2544-test.sh` case 7 now expects 10 rows, not 0.
