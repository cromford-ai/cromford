# BH-4721 (BH-4717.1): cron lanes judged by their last completed tick

Doc: docs/verification-map/lane-heartbeat.md

What changed: `hb_start` takes an optional 6th argument `kind`. `cron` writes
`"kind":"cron"` into the heartbeat file, and with no argument the file is
byte-identical to before. `hb_done` on a `kind:cron` file writes
`state/heartbeat-done/<lane>` (`<epoch>\t<interval>`). The reaper drops a dead
`kind:cron` file with a log line instead of paging `<lane> dead`. It pages once,
id `hb-cron-<lane>-<last_done>`, when that stamp is older than
`hb_cron_interval <lane> × HB_STALE_MULT`, and resolves on a newer stamp.
`merge-conductor` declares `cron`.

Why: the backstop runs the conductor keyed under `timeout 240`. Every killed
tick left a file with a gone pid, and the reaper paged `merge-conductor dead`
under a fresh id each time (221 lines on 2026-10-05). It also never paged a
conductor that stopped completing ticks once its last file was marked or GC'd.

Not changed: the DB pass (`flags/lane-liveness-db`). A killed tick's `lanes`
row is overwritten by the next tick's `hb_start`, and the reaper sends no
`done` beat for a dropped file. `wake-loop` and `blocked-resolver` declare no
kind. The resolver's cadence backstop is a follow-up.

Tests: `tests/heartbeat-cron-lanes.bh-4717-test.sh`. The S9d conductor fixture
in `tests/heartbeat-reaper.bh-638-test.sh` now copies `bin/lib/deployment.sh`,
`gh-rest.sh` and `gh-rest-var.sh`. It was red on main without them.
