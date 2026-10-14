# 2026-09-23 — BH-1608 (BH-1595.1): reconcile-prs owner heartbeat + watchdog page

**What changed.** reconcile-prs runs on one box (BH-1583). That box now beats
into D1 each tick (`bin/lib/reconcile-owner-beat.sh` → `POST /api/reconcile-prs/beat`).
The hub's `bin/jobs-watchdog.sh` calls `rcw_check` (`bin/lib/reconcile-owner-watch.sh`),
which reads `GET /api/reconcile-prs/owner`. It writes ONE ALERTS line,
`RECONCILE OWNER SILENT`, naming the configured owner and where that value came from
(settings or registry), once the beat is older than `RECONCILE_PRS_OWNER_STALE_TICKS`
ticks of the lane's cadence. When the beat comes back it writes `RECONCILE OWNER RESUMED`.

**Why.** If the owner box dies, or the owner row names a box that doesn't exist,
nothing reconciles and until now nothing paged.

**Rules.**
- Age is measured on the worker's clock from `COALESCE(beat_at, expected_since)`.
- The latch is `reconcile_owner_beat.alerted_at` (`PATCH /api/reconcile-prs/owner/alert`),
  written AFTER the ALERTS line, so a failed PATCH means the page repeats. It never means a missed page.
- Only the hub checks. If the worker is unreachable, the watchdog logs one line and does not page.
  If the lane is paused (`lane-off-reconcile-prs`/`all-off`), it stays silent and clears the latch.
- Knob: `RECONCILE_PRS_OWNER_STALE_TICKS` (jobs-watchdog, int, default 3, 2..144, required).
  A non-integer value runs no check and logs one line.

**Check it.** `bash tests/reconcile-prs-owner-beat.bh-1595-test.sh`;
`cd worker/jobs && node --test test/routes/reconcile-owner.bh-1595.test.js`.
