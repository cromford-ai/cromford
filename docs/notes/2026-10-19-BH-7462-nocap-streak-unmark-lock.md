# No-capacity streak alert and the hub unmark under the gate lock (BH-7462)

Doc: MERGE-CONDUCTOR, PROJECT-LANES

## What changed

Two items of hardening on the BH-6890 project gate
(`bin/lib/mc/project-placement.sh`), before #6895 turns the hub fallback off.

1. **No-capacity streak alert.** With `lane_fallback.merge-conductor.<project>`
   = `hub`, the gate counts no-capacity cycles in
   `state/merge-conductor/project-fly/<project>.nocap-n`
   (`_mc_proj_nocap_count`). At `mc_project_fly.nocap_alert_n` cycles in a row
   it sends one ALERTS line through `mc_proj_alert`:
   `<n> no-capacity cycles in a row: no lane-run machine claimed a merge-conductor row of <project> within <stale>s (row <id>); ...`.
2. **Unmark under `<project>.lock`.** `mc_proj_hub_unmark` now takes
   `<project>.lock` (`flock -w 10`, the gate's own wait) before it reads
   `<project>.hubtick` and removes it. A later tick writes its mark under the
   same lock, so an earlier tick's unmark can no longer remove it. If the lock
   is not taken in 10 s, or cannot be opened, the unmark leaves the mark and
   logs one `hub mark of <project> left in place` line. A mark of a pid that
   ended never blocks an enqueue (`_mc_proj_hub_busy` checks the pid start
   stamp), so a left mark costs nothing. `bin/merge-conductor.sh` is not
   changed.

## The knob

| Settings row | Seed | Meaning |
|---|---|---|
| `mc_project_fly.nocap_alert_n` | 3 | no-capacity cycles in a row that raise one held ALERTS line (1..86400); code default `MC_PROJ_NOCAP_ALERT_N=3` |

Seeded by `worker/jobs/schema.d/202610191622-bh-7462-mc-nocap-alert-n.sql`.

## What counts as one cycle

One count per row: the gate's stale arm, when the row ended now (withdrawn
unclaimed, or already `died` + `withdrawn ...` and not yet taken back) and the
fallback is hub. The backoff ticks of the same withdrawn row do not count.
These do not count either: a withdraw the worker does not answer, a row
claimed before the withdraw, fallback `off` (its own path already alerts on
each stale row), a young queued row, no row, and a failed jobs read.

## What resets the streak

A row a machine claimed: the newest row is `claimed`, `done`, `deferred` or
`failed` (died, failed or a bad done row). No row, a young queued row and a
failed read do not reset it.

## Alert hold

The streak alert uses the same per-project hold as the machine-failed streak
(`<project>.alert-at`, `mc_project_fly.alert_s`, `--id mc-project-fly-<project>`),
so the two streaks give at most one line per project per hour together.

## Rollback

Set `mc_project_fly.nocap_alert_n` to 86400. The unmark change has no knob.

Verified by `tests/merge-conductor-project.bh-7462-test.sh`.
