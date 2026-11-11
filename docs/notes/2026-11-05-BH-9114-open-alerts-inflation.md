# BH-9114: open console alerts were inflated (warn digests, per-pid reaper ids, a 500-row groom)

Doc: docs/ALERTS-STATE-MACHINE.md, docs/ALERTS-GROOMING-SPEC.md, docs/verification-map/lane-heartbeat.md

What changed. On 2026-11-05 the console showed 861 open alerts. Three causes,
three fixes, plus one screen change:

1. A warn digest is not an open alert. `bin/alert-digest.sh --warn-batch` now
   beats with `BEAT_STRICT=1`. When the console took the beat (rc 0), it closes
   its own row (akey `warnbatch:<box>:<ts>:<pid>`) with reason `digest` through
   `console_alert_resolve_akey` in `bin/lib/console-alert-resolve.sh`: one
   `GET /api/alerts/open`, exact akey match, one `POST /api/alerts/resolve`.
   The log line is `warn-batch digest row: resolved|not-found|not-configured|failed`
   in `logs/alerts-state.log`. Knob `ALERT_DIGEST_RESOLVE` (lane
   alert-warn-flush, default 1). The backstop is `bin/alerts-supersede.py`: an
   open row whose akey starts with `warnbatch:` is resolved with reason
   `digest` on every groom pass. The single warn rows are not touched.
2. `bin/heartbeat-reaper.sh` pages a LANE, not a pid. The file-pass id is
   `hb-<lane>` (was `hb-<lane>-<pid>-<started_at>`). A dead, non-cron instance
   is dropped with a `— not a page` log line when a later run of the same lane
   (the `.lane` field) started after it, or the lane's completion stamp
   (`state/heartbeat-done/<lane>`) is newer than its start. Two instances of one
   lane in one pass are one finding. After a dead page the reaper writes
   `state/heartbeat/<lane>.hbpaged` (`<epoch>\t<lane>`); a fresh run or a newer
   completion stamp resolves `hb-<lane>`, and a marker older than
   `HB_STALE_GC_S` is removed with no resolve. `bin/pr-owner-sweep.sh` is now a
   `cron` heartbeat lane (`hb_start ... cron`, `hb_done` at the end and on the
   no-repo exit), knobs `PR_OWNER_HB_INTERVAL_S` (1800) and
   `PR_OWNER_HB_EXPECT_S` (3600).
3. `bin/alerts-groom.sh` reads EVERY open row, oldest first, through D1 with an
   id cursor (`alerts_open_read` in `bin/lib/alerts-open-read.sh`), because the
   console's `/api/alerts/open` answers only the newest 500. Knobs
   `ALERTS_GROOM_PAGE_SIZE` (500), `ALERTS_GROOM_MAX_PAGES` (40). Any D1 failure
   falls back to today's API read. The log line is
   `open read: source=<d1|api> rows=<n> pages=<p> complete=<0|1>[ why=<...>]`.
   Supersede gets the same set (minus the groom's own resolves) through
   `ALERTS_OPEN_FILE`. Every resolve POST, in the groom and in supersede, is
   chunked at `ALERTS_GROOM_RESOLVE_CHUNK` (100).
4. The Mission Control Alerts screen shows a BY FAMILY strip under the stats
   strip (`console-ui/src/lib/alert-family.js`). A pill links to
   `/alerts?openfamily=<family>`, which filters the OPEN ALERTS table.

Why. Ticket BH-9114 (the operator, 2026-11-05).

Tests: `tests/alert-digest-resolve.bh-9114-test.sh`,
`tests/alerts-supersede-digest.bh-9114-test.sh`,
`tests/alerts-groom-paging.bh-9114-test.sh`,
`tests/heartbeat-reaper-lane-key.bh-9114-test.sh`,
`tests/pr-owner-sweep-heartbeat.bh-9114-test.sh`,
`tests/alert-family-console.bh-9114-test.sh` (runs
`console-ui/tests/alert-family.bh-9114.test.js`).
