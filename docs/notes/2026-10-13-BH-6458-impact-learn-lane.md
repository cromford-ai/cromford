# A hub lane opens the learned-edge PR (BH-6458, slice C1 of BH-6390)

Doc: TESTING

## Why

C0 (#6451) shipped `bin/impact-learn.sh record`, which turns one
`dequeue_events` row into learned impact-map edges. It had no caller. A
merge-queue ejection recorded a culprit, a class and the failed suites, and
nothing read that row for the map.

## What changed

- `bin/impact-learn-lane.sh` is a new hub lane, hourly at :23
  (`cron/lanes/416-impact-learn-lane.cron`, behind `hub-lease.sh check`).
  Lane id `impact-learn-lane`, registry `catalog/lanes.d/impact-learn-lane.json`,
  off switch `flags/lane-off-impact-learn-lane`.
- One tick:
  1. One open PR on `impact-learn/edges` stops the tick. Nothing is read.
     An open PR older than `IMPACT_LEARN_PR_STALE_H` pages once
     (`impact-learn-stale:<n>`).
  2. It reads `IMPACT_LEARN_WINDOW_H` hours of `dequeue_events` for
     `HARNESS_REPO`.
  3. A row is a candidate only when it is `culprit`, class `rule-break` or
     `semantic-test`, and names a `tests/…sh` suite. A row in
     `state/impact-learn/seen.tsv` is dropped. A row with no class yet is not
     marked, so a later tick reads it again.
  4. It adds a detached worktree of `origin/main` in
     `${REPOS_ROOT:-/root/repos}/<repo>`, builds the map once, and runs the
     tree's own `bin/impact-learn.sh record --map` per candidate. The map is
     built again after each event that wrote an edge.
  5. A fragment whose path or suite is not on main is deleted (`dead=`).
  6. More than `IMPACT_LEARN_MAX_EDGES` new edges opens no PR and pages
     `impact-learn-mass` once. Else one commit, a force push to
     `impact-learn/edges`, and one `POST repos/<slug>/pulls`. Only a 201 with
     a PR number counts.
  7. The rows with outcome `edges`, `none` or `unreachable` go into
     `seen.tsv`. Lines older than the window are pruned. A failed, mass or
     dry tick marks nothing.
- `bin/impact-learn.sh record` takes `--map <file>`, a map that
  `bin/test-impact.sh map` already built. On the cromford tree, one
  `select --map-only` took 18.3 s with no map and 1.6 s with a prebuilt map
  (measured 2026-10-13 on the build box).
- Each tick writes one line to `logs/impact-learn.log`:
  `<iso> impact-learn <slug> events= candidates= edges= dead= unreachable= failed= <outcome>`.

## Knobs

All are lane knobs in `catalog/lanes.d/impact-learn-lane.json`. A settings row
wins over env, and env wins over the default.

| Knob | Default | Range | Meaning |
|---|---|---|---|
| `IMPACT_LEARN_ACT` | 1 | 0..1 | 0 = dry: prints `would-open`, pushes and marks nothing |
| `IMPACT_LEARN_WINDOW_H` | 168 | 1..720 | hours of events read; also the `seen.tsv` prune age |
| `IMPACT_LEARN_MAX_EVENTS` | 50 | 1..500 | candidates per tick, oldest first |
| `IMPACT_LEARN_MAX_EDGES` | 30 | 1..200 | more new edges than this opens no PR and pages |
| `IMPACT_LEARN_MAX_PATHS` | 10 | 1..100 | passed to `record --max-paths` |
| `IMPACT_LEARN_PR_STALE_H` | 48 | 1..720 | an open lane PR older than this pages once |

## The one-open-PR rule

The lane keeps one open PR at a time on the fixed branch `impact-learn/edges`.
While it is open, the lane learns nothing. Merge or close it to let the lane
learn again. The lane never merges its PR.

## How to drive it

- Dry run on the hub: `IMPACT_LEARN_ACT=0 /root/harness/bin/impact-learn-lane.sh`.
- Last tick: `tail -1 /root/harness/logs/impact-learn.log`.
- Suite: `tests/impact-learn-lane.bh-6458-test.sh`.

## Not in this slice

- C2 (#6459): the builder gate and the `learned` why-kind.
- C3 (#6460): edge expiry.
