# BH-7616: pipeline-health reads one open-PR list per repo per tick

Doc: OPERATING

Slice C1 of #7616 (the rest of #7397). #7397 states the item as "one PR list
per repo per tick, not per PR". C0 (#7641) built the load shed.

## What changed

`bin/pipeline-health.sh` read the open-PR list of the same repo 5 times per
tick, with no shared cache. C1 moved the 3 reads below. C2 (below) moved the
other 2: the starved-project read and the stall-alerts read.

| section | read before | read now |
|---|---|---|
| stalepr (project run) | `harness_pr_list` (live REST pages) | `harness_pr_list` with `HPL_SNAPSHOT=1`, so `prs_open_list` |
| stale parent (project run) | raw `gh api repos/<slug>/pulls?state=open&per_page=100` | `ph_open_list`, so `prs_open_list` |
| lead merge unqueued (fleet run) | the same raw read | `ph_open_list`, so `prs_open_list` |

The new block `# >>> open list (BH-7616)` sources `bin/lib/pr-snapshot.sh`.
That is the store the merge conductor, batch-resolve, pr-state-reconcile and
stuck-work already share: `state/pr-snapshot/<owner_repo>/open.json`, kept for
`PR_SNAPSHOT_TTL_S` (60 s; `PR_SNAPSHOT_QUIET_TTL_S`, 300 s, when no wake
arrived). The lane adds a reader, not a format.

The lane reads through the snapshot only when all of these are true:

1. The run has no `--sections` (`PH_SECTIONS` is empty).
2. `bin/lib/pr-snapshot.sh` loaded.
3. `_prs_on`: `PR_SNAPSHOT=1` and a TTL above 0.

Otherwise the lane unsets `HPL_SNAPSHOT` and every read is today's live read.

A `--sections` run is a PR webhook wake. It re-judges a PR that GitHub just
changed, so it reads live, even when a parent process exported
`HPL_SNAPSHOT=1`.

A failed snapshot read (403, 429, 5xx, 404) prints nothing and returns its
rc. Each section then carries its standing keys, as a failed raw read did.
A failed read is never an empty list.

The stale-parent page-cut alert now fires at `PH_OPEN_CAP` rows: 1000 under
the snapshot (the 10-page stop of `_gh_rest_list`), 100 otherwise. The
snapshot list is complete up to 1000 rows, so PRs past row 100 are judged now.
A standing `staleparent:<p>:page-cut` key for a repo with 100-999 open PRs is
retracted by the epilogue on the first tick.

Each changed block keeps a one-line fallback
(`command -v ph_open_list … || ph_open_list() { gh api …; }`), so a suite that
extracts one block alone runs today's read.

`catalog/lane-run-inputs.d/pipeline-health.rw`: `state/pr-snapshot/*` is a
machine-local cache. A write-back never carries it.

## Kill switch

Set the settings row `lib.pr-snapshot.PR_SNAPSHOT=0`. Every snapshot reader,
this lane included, goes back to live reads with today's request shapes.

## Before and after

Open-list reads of one repo per tick, counted in the fake gh log of
`tests/pipeline-health-open-list.bh-7616-test.sh`:

| run | before (`PR_SNAPSHOT=0`) | after |
|---|---|---|
| full run, no hub clone (E2 vs E1) | 2 | 1 |
| stalepr + stale parent + lead merge unqueued (R2 vs R1) | 3 | 1 |

The after count is 0 when another lane filled the snapshot inside its TTL.
These C1 counts cover the 3 C1 sections only. The starved and stall reads
stayed live until C2.

## C2: the starved-project and stall-alerts reads

C1 left 2 live reads of the same list in the project run:

| section | read before | read now |
|---|---|---|
| `# >>> starved project` | `gh_rest_pr_list_all <slug> open 100` | `ph_open_rows <slug> 100` |
| `# >>> stall alerts` (stale HOLD owner and stalled blocker, one lazy read per project) | `gh_rest_pr_list_all <slug> open 200` | `ph_open_rows <slug> 200` |

`ph_open_rows <slug> <max>` is in the `# >>> open list (BH-7616)` block. With
`HPL_SNAPSHOT=1` it reads `prs_open_list` and prints the first `<max>` rows.
Otherwise it calls `gh_rest_pr_list_all <slug> open <max>`, today's read.

Both reads ask GitHub for the same list in the same order (created, desc).
Only the row cap is different. So the snapshot cut to 100 or 200 rows gives
each check the same rows as today.

A failed snapshot read, or a corrupt snapshot that `jq` cannot read, prints
nothing and returns its rc (75 for `jq`). The starved check then takes
`gh_repo_list_failed` and skips the project, as today. The stall block then
sets `STPRS='?'`, the judge answers unknown, and the pair key is carried, as
today. `ph_open_rows` removes its temp file on every path.

Each of the 2 blocks keeps a one-line fallback
(`command -v ph_open_rows … || ph_open_rows() { gh_rest_pr_list_all "$1" open "$2"; }`),
so a suite that extracts one block alone runs today's read.

The kill switch does not change: `lib.pr-snapshot.PR_SNAPSHOT=0`.

Open-PR list reads of one repo in a project run (`--project fx`), counted in
the fake gh log of `tests/pipeline-health-open-list-rest.bh-7616-test.sh`:

| run | before (`PR_SNAPSHOT=0`, E2) | after (E1) |
|---|---|---|
| stalepr + starved + stall alerts | 3 | 1 |
| the same, with a fresh `open.json` from another lane (E3) | 3 | 0 |

These counts come from a fixture, not from a hub measurement.

## Not in this ticket's slices C1 and C2

- Per-PR reads that are still one call per PR per tick: the staledequeue
  `pulls/<n>` head read, the leadunqueued `commits/<sha>/status` and
  `pulls/<n>/reviews` reads, `bin/blocked-resolver.sh` and
  `bin/repair-on-push.sh`. Each needs its own freshness key. The staledequeue
  head cannot come from the 60 s snapshot: a head pushed inside the TTL gives
  a false "no new head" page.
- Pool scheduling off the hub: the sibling tickets BH-7516, BH-7636 and
  BH-6896 S2-S6 own it. The "batch it" half is on main (#7479).
- The hub measurement with `bin/hub-load-report.sh` (load p90 against the cap,
  0 WINDOW_DEFERRED). It runs on the hub after these merge.
