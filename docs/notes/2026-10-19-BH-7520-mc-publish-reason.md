# Conductor publish names its cause, waits for the lock, sends no stale snapshot (BH-7520)

Doc: MERGE-CONDUCTOR, PROJECT-LANES

## Cause

On 2026-10-19 the hub logged `project-6-os project-fly: snapshot publish failed ()`
twice. Run 12126 then ended rc 66: the machine's `lri_fetch` refused a snapshot
older than `lane_snapshot.max_age_s`.

- `lri_publish` (`bin/lib/lane-run-inputs.sh`) waited 10 s for
  `locks/lane-snapshot-merge-conductor-<project>.lock` and returned 1 with no
  output. Every other failure return was silent too.
- The cron publisher (`bin/lane-snapshot-publish.sh`, minutes 6,16,...,56)
  holds the same lock across its file walk, tar and two HTTP reads. The
  14:46:58Z and 14:47:18Z lines fall inside the 14:46 cron run. The hold time
  of that run is not known on this box (the hub's
  `logs/lane-snapshot-publish.log` was not read).
- `_mc_proj_enqueue` ran `mc_proj_publish || true` and enqueued the row anyway.

## What changed

1. `lri_publish` prints one `lri_publish: <reason>` line on stderr at each
   failure, for example
   `lri_publish: lock busy: locks/lane-snapshot-merge-conductor-<p>.lock held past 30s`
   or `lri_publish: commit failed (http 500)`. rc and the success line do not
   change.
2. `lri_publish` and `lri_apply_pending` wait `LRI_LOCK_WAIT_S` seconds
   (1..600, else 10). Only `mc_proj_publish` sets it. The cron publisher and
   fly-pool keep 10 s.
3. `mc_proj_publish` logs the last non-empty line of the lib output, or
   `rc=<n>, no output`. The line `failed ()` cannot occur.
4. After a failed publish, `mc_proj_publish` reads
   `GET /api/lane-snapshots/merge-conductor/<p>`. It enqueues only when
   `age_s + mc_project_fly.snapshot_margin_s <= lane_snapshot.max_age_s`.
   Otherwise `_mc_proj_enqueue` returns 1 before `lp_enqueue`, and the gate
   runs the tick on the hub (`fallback=enqueue-failed (no fresh snapshot: ...)`).
   With `lane_fallback.merge-conductor.<p>=off` no row and no hub work: the
   next tick tries again.

## Log lines (`logs/merge-conductor.log`)

| Line | Meaning |
|---|---|
| `<p> project-fly: snapshot publish failed (<reason>) — the cron publisher's snapshot is used (<age>s old)` | publish failed, the snapshot is fresh enough, a row is enqueued |
| `<p> project-fly: snapshot publish failed (<reason>) — no fresh snapshot (<why>); this tick of <p> stays on the hub` | no row; `<why>` is `no snapshot`, `snapshot read failed (http <n>)`, `unreadable age` or `snapshot <age>s old, max <max>s less margin <m>s` |
| `<p> project-fly: write-back apply failed (<reason>)` | the apply before the publish failed; the publish still runs |

## The knobs

| Settings row | Seed | Meaning |
|---|---|---|
| `mc_project_fly.publish_lock_wait_s` | 30 | seconds the apply and the publish each wait for the per-project lock (1..600, else 30) |
| `mc_project_fly.snapshot_margin_s` | 300 | seconds of headroom under `lane_snapshot.max_age_s` that a reused snapshot needs, because the machine checks the age at claim |

Seeded by `worker/jobs/schema.d/202610192317-bh-7520-mc-publish-lock-wait.sql`.

## Rollback

Set `mc_project_fly.publish_lock_wait_s` to 10 for the old wait. The stale
snapshot check has no off switch. To stop machine rows, set
`lane_placement.merge-conductor.<p>` to `hub`.

Verified by `tests/merge-conductor-publish.bh-7520-test.sh`.
