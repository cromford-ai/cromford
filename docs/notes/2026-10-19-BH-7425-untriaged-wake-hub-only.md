# BH-7425: untriaged-wake stays on the hub

Doc: OPERATING

The lane-move tool and its module contract: docs/notes/2026-10-17-BH-7252-pipeline-health-move.md.

## What changed

The jobs schema fragment
`worker/jobs/schema.d/202610191454-bh-7425-untriaged-wake-hub-only.sql` seeds one
settings row:

- key: `lane_placement.untriaged-wake.hub_only`
- value: `one fleet-wide run, not pl_dispatch per project; its unblocked-children call runs decompose-parent-close --cooled, which shares state/parent-close-<p>.* and reads builds/<p>-* with the hub wake-loop (BH-7425)`
- actor: `seed`

The statement is `INSERT OR IGNORE`. An operator value wins over the seed.
`bin/harness-sync.sh` applies the fragment before the jobs worker deploy.

With the row present, `lp_decide untriaged-wake` answers `hub` and
`LP_WHY=hub_only: <value>`, also when `lane_placement.untriaged-wake=fly`.
`bin/lane-move.sh` (g2) reports the lane `held`. `bin/lane-cpu-rank.sh` shows the
reason. No module `bin/lib/lane-move/untriaged-wake.sh` is added.

## Why the lane cannot move (ticket step 1)

1. The lane is not per project. `bin/untriaged-wake.sh:92` reads every project
   with `ut_gh_projects` and loops over all of them in one process (`:93-145`).
   It never calls `pl_dispatch` (`bin/lib/project-lanes.sh:167`), the only
   reader of `lp_decide` that enqueues `lane_runs` rows. Cron runs it directly
   (`cron/lanes/171-untriaged-wake.cron`). A `lane_placement.untriaged-wake=fly`
   row has no effect, and the lane-move check (`bin/lane-move.sh:43-50`, one
   `done` lane_runs row per project) cannot pass.
2. The lane shares live hub state with `bin/wake-loop.sh`.
   `bin/untriaged-wake.sh:128` runs `bin/unblocked-children.sh <project>` with
   `REVDEP_TAKE=0`. Revdep is on by default (`bin/lib/revdep-lib.sh:58-62`), so
   `bin/unblocked-children.sh:179-181` runs
   `bin/decompose-parent-close.sh <p> --cooled`. That script reads and writes:
   - `state/parent-close-<p>.last`, the cooldown mark (`:100`, `:134`);
   - `state/parent-close-<p>.keys`, the wake backstop (`:127`, `:829`);
   - `state/parent-close-cursor-<p>` (`:435`), `state/parent-close-skip-<p>-<N>`
     (`:752`), `state/parent-close-commented-<p>-<N>` (`:791`);
   - `builds/<p>-<N>-*/RESULT` (`:177`), the PR links of a client-facing close
     comment;
   - `logs/<p>.log` (`:91`, `:807`, `:823`).
   `bin/wake-loop.sh:759` makes the same call on the hub and writes the same
   cooldown mark and keys file.
3. No `catalog/lane-run-inputs.d/untriaged-wake.{ro,rw}` manifest exists, so
   `lri_fetch` carries none of this state. A manifest does not fix it: a machine
   copy of the cooldown mark and keys file races the hub writer, so each
   write-back is a compare-and-set conflict. The lane-move check needs 0
   conflicts. A machine has no `builds/`, so a close comment loses its PR links.

## What a later move needs

A separate ticket must do all of these:

1. Split `bin/untriaged-wake.sh` into a `--dispatch` pass through `pl_dispatch`
   and a `--project <p>` run.
2. Move the parent-close cooldown mark and keys file off hub files, or keep the
   parent-close call on the hub.
3. Add `catalog/lane-run-inputs.d/untriaged-wake.{ro,rw}` and a
   `lane-snapshot-publish.sh --lane untriaged-wake` cron line.
4. Add `bin/lib/lane-move/untriaged-wake.sh` and its test.
5. Remove the hub_only row (see below).

## Undo

The row has no API undo. The jobs worker refuses an empty value
(`worker/jobs/src/routes/settings.js:412`), and its DELETE route removes only
`ui.theme.custom.<slug>` rows (`:549`). `lp_hub_only_reason`
(`bin/lib/lane-placement.sh:117`) reads any non-empty value as a reason. So the
later move ticket removes the row in its own reviewed change. Until then, the
kill switch for the lane is unchanged: it runs on the hub.
