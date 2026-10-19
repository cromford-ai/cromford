# review-autopilot stays on the hub (BH-7427)

Doc: OPERATING, PROJECT-LANES

## What changed

The seeds now carry the settings row `lane_placement.review-autopilot.hub_only`
(`worker/jobs/schema.d/202610191522-bh-7427-review-autopilot-hub-only.sql`,
`INSERT OR IGNORE`). Its value is the reason the lane cannot move to a Fly
lane-run machine.

`lp_decide` (`bin/lib/lane-placement.sh`) answers `hub` with
`LP_WHY="hub_only: <reason>"` when this row is not empty, also when
`lane_placement.review-autopilot` says `fly`. `bin/lane-move.sh` gate g2 answers
`held hub_only: ...` for the lane. `bin/lane-cpu-rank.sh` prints the reason.

Today no `lane_placement.review-autopilot` row is seeded, so the lane already
runs on the hub through `lane_placement.default`. This row changes no run
today. It stops a later flip to `fly` while the blockers below are open.

No module `bin/lib/lane-move/review-autopilot.sh` is added. #7427 step 1 says:
if the lane reads hub-local state that a lane-run snapshot cannot carry, do not
move it.

## Evidence: the hub-local inputs

A project run (`bin/review-autopilot.sh <p>`) reads these hub-local things.
Line numbers are at main b0bdaba0.

| input | where | can a lane-run snapshot carry it? |
|---|---|---|
| `${REPOS_ROOT:-/root/repos}/$P/.git`, and `patch_same_fetch` into it (the free verdict replay) | bin/review-autopilot.sh:992-1012 | No. A snapshot is a tar of allow-listed files (bin/lib/lane-run-inputs.sh). It cannot carry a git clone. The machine clone cache holds only clones that other rows made, so a clone is not certain. With no clone the `[ -d .../.git ]` guard is false, the replay is skipped, and the run buys a paid review for a head whose patch did not change. review-rescue has the same blocker (catalog/lane-run-inputs.d/review-rescue.rw). |
| `state/review-autopilot/<slug>-<num>-<head12>`, `.body`, `.pending`, `count-<p>-<day>` (dedupe ledger in file mode, cached reviews, daily cap) | bin/review-autopilot.sh:210, 831, 853, 882, 1002 | Only with a new `.rw` manifest. None exists in catalog/lane-run-inputs.d/. The files are keyed by repo slug, not by project (docs/notes/2026-10-14-BH-6721-lanes-offhub.md). |
| `state/$P.pr-reviews.json` (review-prs.sh state) | bin/review-autopilot.sh:970 | Only with a new `.ro` manifest. With no copy, the check misses and a second review is bought. |
| `state/pauses.json` (pause cache that the hub dispatch refreshes) | bin/review-autopilot.sh:733-748 | Only with a new `.ro` manifest. |
| a per-project "run done" line for a lane-move module to count | none: a project run writes a beat only when it reviewed a PR (bin/review-autopilot.sh:1300-1306) | No such line exists. A module has nothing to count, so lane-move would answer `waiting lane-idle` on each tick. |

Rows 1 and 5 are hub-local state that no snapshot carries.

## Kill row

To remove the hold, write an empty value. An empty value is "no hub_only"
(`lp_hub_only_reason`, bin/lib/lane-placement.sh):

    bin/jobs-client.sh setting-set lane_placement.review-autopilot.hub_only ''

## What a later move needs

1. A per-project run-done line in `bin/review-autopilot.sh`, in the STAMP
   format that `bin/lib/lane-move/pipeline-health.sh` counts.
2. A `catalog/lane-run-inputs.d/review-autopilot.ro` and `.rw` pair, with the
   slug-keyed state narrowed to the project.
3. A repo clone on the machine, or a REST patch-same check that needs no clone.
4. A `lane_placement.review-autopilot` seed with the value `hub`.
5. The module `bin/lib/lane-move/review-autopilot.sh`, then the empty kill row
   above.

## Tests

- `tests/lane-move-review-autopilot.bh-7427-test.sh`: the seed row, no
  placement row and no module, and the real `lp_decide` over the row.
- `tests/lanes-offhub.bh-6721-test.sh` O3: the exact key
  `'lane_placement.<lane>.hub_only'` is a reason row, not a placement. M-f pins
  it, and a `lane_placement.review-autopilot` row still turns O3 red.
