# The rest of #5938's lanes stay on the hub for now (BH-6721, BH-6047.8, C8)

Doc: PROJECT-LANES

## What changed

Nothing moves. This note records, for each of the seven lanes #5938 names
for the move off the hub, why it stays on the hub today. It also records the
inputs each lane reads and writes, so the build that moves a lane starts from
a checked list. `tests/lanes-offhub.bh-6721-test.sh` pins the result.

## State on main (origin/main 7d5000fc, 2026-10-14)

- No C8 lane calls `pl_dispatch`. A grep over `bin/<lane>.sh` and every file
  in its source closure (`scratch_closure_list`) finds no call. The move onto
  the runner is #5944, and #5944 is open with no PR.
- No reader exists for `catalog/lane-run-inputs.d/<lane>.ro|.rw`.
  `bin/lib/lane-run-inputs.sh` (`lri_paths`, `lri_member_ok`) still lists
  only the blocked-resolver paths. The per-lane manifest reader is #6719, and
  #6719 is open with no PR.
- No lane runs on Fly. The blocked-resolver flip and its "live claimer" probe
  are #6260, and #6260 is open. So the ticket's condition for a placement
  fragment ("only when #6260's stats probe shows a live claimer") is false.
- The function `lp_decide` reads `lane_placement.<lane>` only from `pl_dispatch` and
  `bin/lane-snapshot-publish.sh`. A `fly` row for a lane that is not on
  `pl_dispatch` changes nothing, so this change ships no fragment.

The blocker on main is the same for all seven, and each lane line names it: not on
pl_dispatch (#5944 open); no manifest reader (#6719 open); no live claimer
(#6260 open).

## Each lane

- `dequeue-watch`: stays on the hub: not on pl_dispatch (#5944 open); no manifest reader (#6719 open); no live claimer (#6260 open). Also, one global `locks/dequeue-watch.lock` dedupes the whole fleet tick, and the `gh-budget` gate (`gh_budget_low dequeue-watch`) reads `state/gh-budget/<token>.json`, one cache for every lane on that GitHub token.
- `pr-url-reconcile`: stays on the hub: not on pl_dispatch (#5944 open); no manifest reader (#6719 open); no live claimer (#6260 open). Also, it walks `builds/*/` for every project in one tick under one global `locks/pr-url-reconcile.lock`. A per-project builds slice (the blocked-resolver shape) can carry that walk.
- `archie-fm`: stays on the hub: not on pl_dispatch (#5944 open); no manifest reader (#6719 open); no live claimer (#6260 open). Also, it takes the merge conductor's per-PR lock (`mc_pr_lock`, `$MC_H/locks/merge-conductor-<p>-<n>.lock`) with `flock -n 8` for each action. That lock is a file on the hub, and a lane machine cannot hold it. This is a fleet-wide input, so archie-fm stays after #5944 and #6719 too.
- `review-autopilot`: stays on the hub: not on pl_dispatch (#5944 open); no manifest reader (#6719 open); no live claimer (#6260 open). Also, one global `locks/review-autopilot.lock` and the shared `gh-budget` gate. Its review state is per project (`state/$P.pr-reviews.json`, `state/review-autopilot/<slug>-<num>-<head12>`), so it can be sliced.
- `fleet-status-push`: stays on the hub: not on pl_dispatch (#5944 open); no manifest reader (#6719 open); no live claimer (#6260 open). Also, it builds ONE fleet JSON from `logs/ALERTS.log`, `state/hub-lease.json`, `state/stale-owed.json`, `state/pool/*`, `state/build-queue/*`, `state/lane-down/*` and `flags/`. That is a fleet total, so it stays after #5944 and #6719 too.
- `metrics-collect`: stays on the hub: not on pl_dispatch (#5944 open); no manifest reader (#6719 open); no live claimer (#6260 open). Also, it appends to one `logs/metrics.csv` and dedupes on one `state/metrics-seen.txt` for every build of every project. That is a fleet total, so it stays after #5944 and #6719 too.
- `stale-owed-tickets`: stays on the hub: not on pl_dispatch (#5944 open); no manifest reader (#6719 open); no live claimer (#6260 open). Also, it writes the fleet counts to `state/stale-owed.json` and appends to the global `logs/READY-QUEUE.log`. That is a fleet total, so it stays after #5944 and #6719 too.

## Table (copied into the PR body)

| lane | inputs (read / write, per project) | moved or stays | hub CPU 24 h |
|---|---|---|---|
| `dequeue-watch` | read: `fleet.conf`, `state/gh-budget/*` (shared); write: `logs/dequeue-watch.log` | stays | not measured: logs/lane-prof.log is on the hub only |
| `pr-url-reconcile` | read: `builds/*/` (all projects), `fleet.conf`; write: `builds/<p>-*/{pr-body.md,RESULT,.pr-url-reconciled,.pr-url-reconcile-restack-*}`, `logs/pr-url-reconcile.log` | stays | not measured: logs/lane-prof.log is on the hub only |
| `archie-fm` | read: `fleet.conf`, conductor PR lock (hub only); write: `logs/archie-fm.log` | stays | not measured: logs/lane-prof.log is on the hub only |
| `review-autopilot` | read: `state/$P.pr-reviews.json`, `state/gh-budget/*` (shared); write: `state/review-autopilot/<slug>-*`, `logs/review-autopilot.log` | stays | not measured: logs/lane-prof.log is on the hub only |
| `fleet-status-push` | read: `logs/ALERTS.log`, `state/hub-lease.json`, `state/stale-owed.json`, `state/pool/*`, `state/build-queue/*`, `flags/` (fleet); write: one fleet JSON | stays | not measured: logs/lane-prof.log is on the hub only |
| `metrics-collect` | read: `builds/*/` (all projects); write: `logs/metrics.csv`, `state/metrics-seen.txt` (fleet) | stays | not measured: logs/lane-prof.log is on the hub only |
| `stale-owed-tickets` | read: `fleet.conf`, `builds/*/RESULT`; write: `state/stale-owed.json`, `logs/READY-QUEUE.log` (fleet) | stays | not measured: logs/lane-prof.log is on the hub only |

The build ran on a pool box. That box has no `logs/lane-prof.log`, so no CPU
number is given.

## When #5944 and #6719 land

Only `dequeue-watch`, `pr-url-reconcile` and `review-autopilot` have a
per-project slice. For those, these are DRAFT manifests in the #6719 format
(one glob a line, `$p` for the project). They are text here, not catalog
files, because no code reads `catalog/lane-run-inputs.d/` yet. The global
lock of each lane becomes a per-project dedupe key under `pl_dispatch`, and
the `gh-budget` cache stays per machine.

`dequeue-watch.ro`:

```
fleet.conf
flags/*
```

`dequeue-watch.rw`: empty (the lane writes only its log).

`pr-url-reconcile.ro`:

```
fleet.conf
builds/$p-*/**
builds/pool-$p-*/**
builds/fly-$p-*/**
```

`pr-url-reconcile.rw`:

```
builds/$p-*/pr-body.md
builds/$p-*/RESULT
builds/$p-*/.pr-url-reconciled
builds/$p-*/.pr-url-reconcile-restack-*
builds/$p-*/.verdict-handoff-done
builds/pool-$p-*/pr-body.md
builds/pool-$p-*/RESULT
builds/pool-$p-*/.pr-url-reconciled
builds/pool-$p-*/.pr-url-reconcile-restack-*
builds/pool-$p-*/.verdict-handoff-done
```

`review-autopilot.ro`:

```
fleet.conf
flags/*
state/$p.pr-reviews.json
state/review-autopilot/*
```

`review-autopilot.rw`:

```
state/review-autopilot/*
```

The review-autopilot state file is named by repo slug, not by project, so
the #6719 build must confirm that `state/review-autopilot/*` can be narrowed
to one project's slugs before it ships these globs.

The move itself needs three steps, each in its own PR: put the lane on
`pl_dispatch` (#5944), commit its `.ro`/`.rw` pair (#6719), and seed
`lane_placement.<lane>=fly` with a live-claimer probe (#6260). The test
refuses a `fly` fragment for a C8 lane that lacks the first two.
