# Merge-conductor lane manifest and alert lines through the jobs API (BH-6889, BH-6881.5)

Doc: HARNESS-COORDINATION, ALERTS-STATE-MACHINE

## What changed

Part 5 of #6881. A `lane-run` machine has no hub `builds/` records, no
`flags/` and no `logs/ALERTS.log`. This slice gives the merge conductor a lane
manifest pair and gives every lane-run machine a way to raise alert lines.
Nothing places `merge-conductor` on Fly yet. That is BH-6881.6.

1. `catalog/lane-run-inputs.d/merge-conductor.ro` and `.rw` (see "The
   manifest" below).
2. A new path-line token `$repokey` in `bin/lib/lane-run-inputs.sh`.
3. Table `alert_lines` and three bearer-gated routes in
   `worker/jobs/src/routes/alert-lines.js`.
4. `bin/alert-line.sh`: with `LANE_RUN_ID` set, it posts the line
   (`alr_post`, `bin/lib/alert-line-remote.sh`) and exits 0. Any failure
   takes the old local path.
5. `bin/lane-snapshot-publish.sh` step 3: `alr_apply` replays unapplied lines
   into the hub `logs/ALERTS.log` and marks them applied.

## The alert-lines contract

- `POST /api/alert-lines {lane, project, line, stamp?, severity?, alertid?, run_id?}`
  answers `{id, dup}`. The worker computes
  `dedup_key = sha256(lane|project|run_id|line)`, so one run that posts the
  same line twice makes one row. `lane` and `project` match
  `[A-Za-z0-9][A-Za-z0-9._-]{0,63}`. `line` is 1-2000 chars with no newline.
  `stamp` is at most 40 chars, and `line` starts with `stamp` and a space.
  `severity` is `info`, `warn` or `critical`. A 400 names the field first.
- `GET /api/alert-lines?unapplied=1&limit=n` (1..500, default 200) answers
  `{lines, truncated, as_of}`, oldest id first.
- `POST /api/alert-lines/applied {ids}` (1..500 ids) answers `{applied}`. It
  marks only rows that are not applied, so a repeat answers `{applied:0}`.
- A missing table answers 503 on every route.

### Write order on the hub

`alr_apply` runs once per publisher tick, for every lane, under
`flock -n locks/alert-lines-apply.lock` (held: `skipped (busy)`, no request).
For each row, in id order:

1. If `state/alert-lines-applied/<dedup_key>` exists, it does not replay the
   row. It acks it again.
2. Else it runs `env -u LANE_RUN_ID ALERT_LINE_STAMP=<stamp>
   bin/alert-line.sh [--severity s] [--id k] --project p <text>`. The hub line
   is byte-identical to the machine's line, the beat carries the same
   `--id`, and the replay never posts back.
3. It touches the marker.

After the loop it sends one ack for every replayed or marked id. The worst case
is one repeated line, after a crash between the append and the marker. A failed
ack leaves the markers, so the next tick does not repeat the line.

The summary clause is `alert lines: <r> replayed, <s> already applied, ack
<ok|failed|none>[, more]`. `, more` means more than `alert_lines.apply_max`
rows wait. `alert lines: off (not configured)` (empty `JOBS_URL` or
`HARNESS_SECRET`) sends no request. A read or ack failure raises
`lane-snapshot-alert-lines` (warn), and the next good tick resolves it. It does
not change the publisher's exit code.

Markers older than the larger of the two retention windows plus one day are
deleted, so a marker always outlives its row.

### Retention and settings

| Settings row | Default | Use |
|---|---|---|
| `retention.alert_lines.applied_days` | 7 | rule `alert_lines.applied`: applied rows past the window |
| `retention.alert_lines.unapplied_days` | 30 | rule `alert_lines.unapplied`: rows the hub never replayed |
| `alert_lines.apply_max` | 200 | rows one tick replays (1..500) |

`bin/d1-retention.sh` runs both rules with no edit: it runs every rule the
worker returns. They count only, while `retention.dry_run` is 1. The rows are
operational lines, not money or history. The hub `ALERTS.log` holds the
replayed copy, so the rows are deleted.

### Indexes

`ux_alert_lines_dedup` serves the insert conflict and the id lookup.
`idx_alert_lines_applied (applied_at, id)` serves the unapplied read and both
retention reads. The mark uses the primary key. W3 in
`worker/jobs/test/alert-lines.bh-6889.test.js` proves each one with
`EXPLAIN QUERY PLAN` on 5,000 rows.

## The gap this does not close

The conductor raises most of its alerts through `bin/lane-alert.sh`
(`mc_alert`, `bin/lib/mc/log.sh`). That script appends to `logs/ALERTS.log`
itself and does not call `bin/alert-line.sh`. So on a machine those lines stay
machine-local. The flip ticket (BH-6881.6) must route `lane-alert.sh` too. The
`.rw` NOT CARRIED block names it.

## The manifest

The inventory is from a run, not from a read of the source alone.
`tests/lane-run-inputs-mc-manifest.bh-6889-test.sh` publishes the `mgfy`
snapshot of a fixture hub, extracts it into a machine root, and runs
`LANE_RUN_ID=t1 bin/merge-conductor-pr.sh mgfy example-org/mgfy-os#31 <head>`
there and on the hub.

- T1a/T1b: every fixture file starts with atime < mtime. A moved atime is a
  read, and a new file or a moved mtime is a write. Every read path must pass
  `lri_member_ok … ro`, and every written path must pass `… rw`. With `strace`
  on PATH the suite also checks an `openat` trace. The suite prints
  `SKIP T1-trace` when atime does not move on the mount.
- T1c: the hub run and the machine run print the same `PROF mc-pr` line and
  leave the same `pr-state.tsv` row. A machine copy with `flags/main-red-mgfy`
  holds the PR, so the flag is read from the snapshot.

An entry that the fixture does not reach says `(not reached by the fixture)`
next to its `file:line`.

### `$repokey`

The conductor keeps no per-project directory. Its per-PR markers sit in shared
dirs (`stuck/`, `read-memo/`, `ready-why/`, …) and are named by the fleet.conf
repo with every character outside `[A-Za-z0-9._-]` folded to `_`
(`mc_safe_name`, `mc_handoff_id`). A manifest path line can now say
`$repokey`, which `_lri_compile` replaces with that fold, case kept. So
`state/merge-conductor/stuck/$repokey_*` takes `example-org_mgfy-os_31_READY_x`
and refuses `example-org_mgfy-os-console_31`. A project with no repo in
fleet.conf is a parse error (one `lri:` line, rc 1).

`pr-state.tsv` is fleet-wide. The `.rw` holds the literal path line and
`@rows state/merge-conductor/pr-state.tsv ^$slug#` (the #6884 form), so the
snapshot and a write-back carry only this repo's rows.

### Not carried

The `.rw` NOT CARRIED block lists what a run writes and the snapshot does not
carry. The fleet-wide ones are `logs/ALERTS.log` from `lane-alert.sh`,
`attempts.txt`, the re-review budget file, `lane-epoch`, `hold-reminder-at`,
`diffs/*` and `state/stack-follow/*`. The flip ticket must solve them before
merge-conductor runs on Fly.
