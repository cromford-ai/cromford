# builds/ retention archive and archived-build readers (BH-7437 part 2)

Doc: OPERATING

## What changed

- New hub lane `bin/builds-retention.sh`, daily at 04:27Z
  (`cron/lanes/737-builds-retention.cron`, registry
  `catalog/lanes.d/builds-retention.json`). It moves SETTLED build-dir groups
  older than the window from `builds/` to `builds-archive/<YYYYMM>/<dir>`. The
  move is a rename on the same filesystem. Nothing is deleted.
- New lib `bin/lib/build-archive.sh`: the index `builds-archive/index.tsv` (one
  row per moved dir, written before the move) and the readers `ba_dirs`,
  `ba_has_key`, `ba_path`, `ba_merged_other`.
- Three settings rows (seed `worker/jobs/schema.d/202610200111-bh-7437-builds-retention-settings.sql`):
  `builds_retention.window_days` (14), `builds_retention.dry_run` (1),
  `builds_retention.max_dirs` (2000). A missing row, an outage or a bad value
  uses the code default, and the run line names it `(default)`.
- Six by-key readers also look in the archive (table below).

## Which groups move

A group is every dir whose name parses to one `(project, KEY)`. A group moves
only whole, and only when every rule holds. The first failed rule is its kept
reason in the run line: `no-stamp`, `young` (a name stamp, or a RESULT or
COMMENTED mtime, newer than `now - (window_days + 1) days`), `not-merged` (no
RESULT line 1 starts `PR_MERGED`), `unswept` (the
`bin/orphan-reconcile.sh:1187` predicate), `remote-json`
(`state/remote-results/<p>/<K>.json` exists), `live` (the build-key lock is
held), `collision` (already archived; counts an error).

Known limit: in this repo only `bin/lib/resume-dead.sh:316` writes `PR_MERGED`
to a RESULT file. Merge-sweep records the merge in the jobs ledger and leaves
RESULT at `PR_CREATED`. So `not-merged` keeps most old groups today. The rule
is on the safe side: it never moves an unsettled group. The dry-run line shows
the real `not-merged` count before an operator turns on real moves. A wider
"merged" signal (the ledger or the merge conductor rows) is a later change.

## Readers of builds/

Class A: a reader that finds a build by key and makes a decision or answers a
person. Class B: a sweep over many dirs. Class C: a writer of a new dir.
"Safe by rule" means an archived group is merged, swept, has no held lock, no
remote-results json, and no RESULT or COMMENTED change for 15+ days, so the
reader has nothing to act on in it.

| Reader | Class | Status |
|---|---|---|
| `bin/fetch-artifact.sh:63` `build_dir` | A | Patched. Falls back to `ba_dirs`; beat `archived:true`, archive `build_dir`. |
| `bin/launch-fastpath.sh:802` check 17 | A | Patched. `ba_has_key` refuses: "prior build record exists (archived)". |
| `bin/lib/ticket-identity.sh:290` source b | A | Patched (source b2). `ba_merged_other` reports `<key> build-record merged`. The line keeps 3 fields: `bin/lib/rb/gates.sh:450` and `bin/free-slots.sh:61` read exactly 3. |
| `bin/lib/starved-ready.sh:122` | A | Patched. An archived key counts as built, so it is not probed. |
| `bin/merged-ticket-advance.sh:186` `_ma_builds` | A | Patched. Lists archived dirs, same 12-digit stamp rule and order. |
| `bin/lib/br/discovery.sh:110` ledger-only rows | A | Patched. `ba_path` makes the row "has a dir", so it is not re-offered. |
| `bin/orphan-reconcile.sh:1187` unswept check | A | Safe by rule: `unswept` keeps any such group in `builds/`. |
| `bin/pipeline-health.sh:624` staleremote | A | Safe by rule: `remote-json` keeps the group. |
| `bin/fleet-status-push.sh:214` RELAYED pairing | A | Safe by rule: `remote-json` keeps the group. |
| `bin/lib/mc/classify.sh:491` `mc_record_for` | A | Safe by rule: reads `PR_CREATED` records of open PRs; an archived group has a merged PR. |
| `bin/blocked-resolver.sh:3763` merged supersede | A | Safe by rule: marks a merged ticket's records long before the window ends. |
| `bin/blocked-resolver.sh:3367` | A | Safe by rule: a merged ticket is resolved, not rebuilt. |
| `bin/lib/closeout-overdue.sh:29` | A | Safe by rule: reads unswept dirs only. |
| `bin/lib/rt/staging.sh:114` stub close-out | A | Safe by rule: acts on a stub with RESULT and no COMMENTED. |
| `bin/split-watchdog.sh:121`, `:228` | A | Safe by rule: a merged child needs no watchdog action. |
| `bin/lib/split-chain.sh:92`, `:213` | A | Safe by rule: chain lookback is inside the window. |
| `bin/decompose-parent-close.sh:177` | A | Safe by rule: reads the thread first; a parent closes long before 15 days. |
| `bin/queued-fly-relayed.sh:23` | A | Safe by rule: a group with an unrelayed stub is `unswept`. |
| `bin/overlap-guard.sh:196` | A | Safe by rule: overlap is checked against open work only. |
| `bin/sibling-serial.sh:292`, `:450` | A | Safe by rule: sibling windows are 14 days or less. |
| `bin/replan-check.sh:123` | A | Safe by rule: a replan targets an open ticket. |
| `bin/plan-after.sh:229` | A | Safe by rule: blockers are open tickets. |
| `bin/iron-law-guard.sh:392` | A | Safe by rule: the current tick's dirs are young. |
| `bin/lookback-collect.sh:105` | A | Safe by rule: the lookback is recent. |
| `bin/lib/triage-state.sh:426` | A | Safe by rule: reads `REVIEW_BLOCKED` records only, which are `not-merged`. |
| `bin/lib/execute-empty.sh:251` | A | Safe by rule: `needs-human.lifted` belongs to an open build. |
| `bin/lib/br/discovery.sh:155`, `:486` | A | Safe by rule: offers parks (BLOCKED, DEAD), which are `not-merged`. |
| `bin/lib/br/opt/cirepair.sh:154` | A | Safe by rule: CI repair runs on an open PR. |
| `bin/lib/gate-release/reoffer.sh:126` | A | Safe by rule: reads `PLAN_BLOCKED` records, which are `not-merged`. |
| `bin/lib/preplan-lib.sh:583` | A | Safe by rule: mid-build keys are live. |
| `bin/review-rescue.sh:851`, `:1158` | A | Safe by rule: rescues `REVIEW_BLOCKED` records, which are `not-merged`. |
| `bin/triage-gate.sh:987` close-out sweep | B | Safe by rule: reads RESULT without COMMENTED only. |
| `bin/pipeline-health.sh:508`, `:581`, `:712` | B | Safe by rule: close-out and staleness checks read unswept or recent dirs. |
| `bin/reopen-metrics.sh:345` | B | Day windows of 14 days or less; the cut is window + 1 day on RESULT mtime. |
| `bin/metrics-collect.sh:123` | B | Unbounded sweep: loses only merged history older than the window. |
| `bin/commented-mirror.sh:71` | B | Safe by rule: archived dirs are already COMMENTED. |
| `bin/decompose-overlap-report.sh:69`, `bin/overlap-schedule.sh:299`, `bin/plan-overlap.sh:353`, `bin/conflict-check.sh:21` | B | Overlap reports use open work; merged history drops out. |
| `bin/rebase-train.sh:150`, `bin/postmerge-qa.sh:150` | B | Recent merges only (inside the window). |
| `bin/lib/triage-shards-lib.sh:579`, `bin/lib/rt/scope.sh:555` | B | Recent or open builds only. |
| `bin/lib/lane-run-inputs.sh` publisher walk | B | The archive is off its walk path; the walk gets shorter. |
| `bin/disk-clean.sh:163` | B | Prunes closeout-tsv rows of missing dirs; merged groups are closed out. |
| `bin/run-build.sh:38`, `bin/fly-pool.sh:3360`, `bin/review-rescue.sh:1067` | C | Writers of new dirs; never archived (young). |
| `bin/fly-pool.sh:2685`, `:2776`, `:3608` | B | Pool reap of recent dirs. |

"Safe by rule" entries were checked against the reader's own guard (the lines
named), not with a test each. The six patched readers have a test each
(`tests/build-archive-readers.bh-7437-test.sh` D1-D5, F1-F4).

## Operator steps

1. Read the dry-run list: `logs/builds-retention-dryrun.txt` (`<dir> TAB
   <YYYYMM>/<dir>`) and the last line of `logs/builds-retention.log`.
2. To start real moves: `bin/jobs-client.sh setting-set builds_retention.dry_run 0`.
3. To restore one dir: `mv builds-archive/<YYYYMM>/<dir> builds/<dir>`, then
   delete its rows from `builds-archive/index.tsv`.
4. To stop the lane: `bin/harness-ctl.sh off builds-retention`.

`builds-archive/` and its index are history and are kept. `bin/state-backup.sh`
does not read `builds-archive/`; older tarballs keep the moved summaries for 30
days, and the data stays on the hub disk.
