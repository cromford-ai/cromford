# Move a project box to a Fly machine: cutover and rollback, slice C1 (BH-8410, MKF-7)

Doc: HUB-THINNING-PLAN, RESTORE

## What changed

Slice C1 of #8322 adds the verbs that write the rows and the old box crontab.
Slice C0 (`inventory`, `provision`, `seed`, the no-write `tick`, `proof`) is in
[2026-10-25-BH-8322-MKF-7-box-move.md](2026-10-25-BH-8322-MKF-7-box-move.md).
An operator runs these on the hub:

```
bin/box-move.sh cutover --step B1|B2|B3|B4|B5 [--confirm] [--force-drain] <oldbox> <newbox>
bin/box-move.sh rollback [--confirm] [--force-drain] <oldbox> <newbox>
```

`bin/box-move.sh tick --real` stays refused on the command line (exit 2,
`tick --real runs only inside cutover --step B5`). B5 is its only caller.

Files: `bin/box-move.sh` (the verbs, flags, knobs, lock),
`bin/lib/box-move/cutover.sh` (the steps and rollback),
`tests/box-move-cutover.bh-8410-test.sh`, `tests/box-move-rollback.bh-8410-test.sh`
and their fixture `tests/lib/box-move-cutover-fixture.bh-8410.sh`.

## The record (on the hub)

All of it is in `state/box-move/<newbox>/`, next to `target.json`. A dead old
box or a dead new box does not take the rollback record with it.

- `steps.tsv`: `<stamp>\t<step>\t<ok|fail|reset>\t<detail>`. The status of a
  step is its LAST row.
- `old-crontab`: the old box `crontab -l`, saved by B2. A B2 re-run after
  `crontab -r` keeps the saved file.
- `old-rows.tsv`: `box\t<oldbox>\t<box_id>\t<ip>\t<role>` and one
  `project\t<p>` line per project, saved once by B2. B3, B4, B5 and rollback
  read it, because after B4 `bm_rows_resolve` refuses (the new box runs
  projects).

## The steps

Each step refuses (exit 3, nothing done) when the step before it is not `ok`.
Without `--confirm` a step prints `WOULD RUN <step text>` and
`nothing changed: add --confirm to run`, and makes no call.

| Step | What it does | `ok` is written after |
|---|---|---|
| B1 preflight | Hub only. The newest `tick-*.tsv` (by name) has line 1 `# mode=nowrite at=<epoch>`, is under `BOX_MOVE_TICK_MAX_AGE_S` old, has a `# reach ssh=0 flyctl=0` line (`hmr_c1_reach`), and no lane with `rc != 0`, `refused == 0`, `timed_out == 0` outside `BOX_MOVE_B1_ALLOW`. `target.json` has `ts_ip`, and its `box_id` is the rows box id of the old box. | the table is judged |
| B2 stop the old box | Save `old-rows.tsv` and `old-crontab` on the hub. On the old box: LOCAL `flags/lane-off-update-runners` (so a `fleet-propagate.sh` run cannot put the crontab back), `crontab -r`, `hub-move.sh drain`. | 0 active crontab lines, drained (or `--force-drain`) |
| B3 copy | `BACKUP_FORCE=1 state-backup.sh` on the old box, `seed` from that new snapshot, then LOCAL `flags/all-off` on the old box (after the backup: `state-backup.sh` is lane-gated). | a new `backup-last.json` ts and a seed that ended done |
| B4 rows | `REGISTRY_SOURCE=db`, `REGISTRY_ADMIN_TOKEN` and `HARNESS_SECRET` must be set (exit 3, names only). `registry.sh add-box <newbox> --ip <ts_ip> --like <box_id> --id <box_id> --role <old role>`, then `registry.sh move-project <p> --box <newbox>` for each saved project that is not there yet. | `fleet-conf.sh --projects-on-box` reads the saved list on the new box and nothing on the old box; `--tailnet-ip-of-box <newbox>` is `ts_ip` |
| B5 start the new box | Split-brain check: both boxes have 0 active crontab lines and `flags/all-off` on. Clear the new box LOCAL all-off, `hub-move.sh tick --real` there, remove `state/hub-move/target-seeded`, `update-runners.sh`. A failed tick sets the new box all-off again, so a B5 re-run passes the check. | the new crontab has active lines and its all-off reads off |

B4 never calls `registry.sh drain-box`: it deletes the lane rows of a box ID,
and the new box keeps the old box id. In `REGISTRY_SOURCE=file` mode the rows
are the committed `fleet.conf`, which box-move never edits: B4 refuses and says
to move the projects with `bin/box-register.sh` in a PR.

After B4 the C0 verbs `seed`, `inventory` and the no-write `tick` refuse
(`bm_rows_resolve`: the new box runs projects). A seed after cutover would
overwrite live state, so that refusal is the safe answer.

## Rollback

One command puts back the old rows and the old box crontab:

1. Preflight (exit 3, nothing done): `old-crontab` exists and has active
   lines, and `old-rows.tsv` exists. When `steps.tsv` has a B4 row, the B4
   registry preflight runs too. Without `--confirm` it prints `WOULD RUN
   rollback: ...` and exits 0.
2. The new box (when `target.json` has `ts_ip`): LOCAL all-off on, then
   `crontab -r`, then `hub-move.sh drain`. An unreachable new box is exit 4
   with nothing changed; with `--force-drain` it is taken as stopped.
3. The rows, only when B4 ran: `move-project <p> --box <oldbox>` for each
   saved project not there yet, then `set-box-role <newbox> retired`. Read
   back with `--projects-on-box`.
4. The old box: clear LOCAL all-off and `lane-off-update-runners`, then install
   `old-crontab` (its text rides stdin into a temp file there). The active
   line count must equal the saved file's count.
5. `steps.tsv`: a `reset` row for B1..B5, then `rollback ok`. A later cutover
   starts at B1, so the B5 split-brain check runs again.

A failed move back stops before step 4: the old crontab is not installed.
Every step reads state before it writes, so a re-run is safe. The new box keeps
its state and stands by with all-off. State written on the new box after B3 is
not copied back.

## Knobs

Env knobs of an operator-run CLI (the BH-7715 and C0 pattern), each with its
fallback in the `bin/box-move.sh` header. A bad value is exit 2.

| Knob | Fallback | Note |
|---|---|---|
| `BOX_MOVE_DRAIN_TIMEOUT_S` | `1800` | the hub-move drain default; a build runs up to ~1 h, so `--force-drain` exists |
| `BOX_MOVE_TICK_MAX_AGE_S` | `86400` | the hub-move C1 window: an older shadow tick may not match the crontab |
| `BOX_MOVE_B1_ALLOW` | empty | a comma list of lane ids; an id covers its `~N` duplicates |

## Exits and lock

0 done (or WOULD RUN printed); 2 usage or a bad knob; 3 preflight refused (one
stderr line, one `bin/alert-line.sh --id box-move-preflight` row, no
`steps.tsv` row); 4 a step failed (recorded `fail`; the sub-steps before it
stay done). `cutover --confirm` and `rollback --confirm` take
`locks/box-move-<newbox>.lock` (held = print and exit 0). Without `--confirm`
they take no lock.

## Operator runbook

1. Load the registry credentials: `set -a; . <env dir>/global.env; set +a`
   (`REGISTRY_SOURCE=db`, `REGISTRY_ADMIN_TOKEN`, `HARNESS_SECRET`).
2. Run `bin/box-move.sh tick <oldbox> <newbox>` and read the table.
3. For each step B1 to B5: run it without `--confirm`, read the WOULD RUN
   line, then run it with `--confirm`.
4. If a step fails, read its `fail` row in `steps.tsv`, fix the cause, and run
   the same step again.
5. To go back at any point after B2: `bin/box-move.sh rollback --confirm
   <oldbox> <newbox>`.

Probes (not run from a build box):

- `bin/box-move.sh cutover --step B1 box-project-6-os-1 box-mkfly`
  prints WOULD RUN and changes nothing.
- `bin/box-move.sh rollback box-project-6-os-1 box-mkfly` prints
  WOULD RUN after B2, or refuses (exit 3) before it.
