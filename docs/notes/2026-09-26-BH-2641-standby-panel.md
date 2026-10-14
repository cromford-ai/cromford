# STANDBY panel on /hub (BH-2641, BH-2519.3)

Doc: standby-hub

## What changed

The console's /hub page has a STANDBY section between ROLE and BACKUPS
(`console-ui/src/screens/hub/Standby.js`, mounted by `HubView`).

- **Rows come from the page's existing load.** `standbyRows(recovery, now)` in
  `console-ui/src/lib/standby.js` reads the `standbys` array of
  `GET /api/hub/recovery` (rows `{box, of_hub, snapshot, ok, reported_at}`).
  There is no second fetch.
- **Ages are null, never 0.** STREAM AGE parses the snapshot id with the same
  rule as the watchdog's `snapshotAgeMin` (calendar-invalid ids like
  `20261340T000000Z` are null). LAST REPORT parses `reported_at`. A null age
  reads `—` and sorts last in both directions.
- **STREAM** is `ok` only when `ok` is `1` or `true`. Anything else, missing
  included, reads FAILING.
- **Empty vs broken.** No `standbys` array and an empty `role.standby` is the
  empty state, "No standby has reported a heartbeat yet." No `standbys` array
  while `role.standby` names boxes is a contract break: the panel shows an error
  line naming those boxes, never the empty state.
- **Verify.** LAST VERIFY and the per-box history in the BOX drill-down mount
  the BH-2519 contract pieces in `console-ui/src/screens/hub/StandbyVerify.js`.
  They are still stubs that render nothing; the verify-console slice fills them.

## Until the worker slice deploys

The recovery answer carries no `standbys` and `role.standby` is `[]`, so the
section shows the empty state.
