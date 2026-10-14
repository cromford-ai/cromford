# The standby heartbeat and verify-queue worker routes

Doc: HUB-RECOVERY-MCP

## What changed

- **`worker/jobs/src/routes/hub-standby.js`**: `POST /api/hub/standby/heartbeat
  {box, of, snapshot, ok}` upserts one `standby_status` row per box with
  `reported_at` = now. A bad `box` or `of`, or an `ok` that is not the JSON
  literal true/false, is 400 with no row. A box with no `box_status` row is 409
  `unknown_box`. A `snapshot` that is not a `YYYYMMDDTHHMMSSZ` stamp is stored
  as null, never refused.
- **`worker/jobs/src/routes/hub-recovery.js`**: `GET /api/hub/recovery` now
  reads `standby_status`. `role.standby` is the box names, `role.standby_note`
  is null when there are rows and "no standby has reported a heartbeat yet"
  when there are none, and a new top-level `standbys` carries the rows. The
  hardcoded `standby: []` and the "not tracked yet (#401)" note are gone.
- **`worker/jobs/src/routes/hub-standby-verify.js`**: the four verify-queue
  routes on `standby_verify_runs`, shaped like `restore-lab.js`. Request needs
  `confirm: true` (a refusal writes one `standby_verify_refused` audit row), a
  box that never sent a heartbeat is 409 `unknown_standby`, and the run and its
  `standby_verify_request` audit row go in one batch. A second request while
  one is open answers 200 `deduped: true`.

## The claimer is the box

`standby_verify_runs` has no `claimed_by` column (the contract owns the
schema), so claim and result both bind `box = claimer` in their SQL. A standby
can only take and finish its own runs; any other claimer gets `{run: null}` on
claim and 409 `not_claimed_by_you` on result. A `claimed` run older than the
settings row `standby_verify_claim_ttl_s` (seeded 1800 by the contract; code
fallback 1800) is re-offered to the same box.

## Not in this change

The box-side lane that sends the heartbeat and runs the drill (#2640), the Hub
STANDBY panel (#2641) and the verify UI (#2642). Nothing calls these routes
until those land. `tests/standby-contract.bh-2519-test.sh` now checks that each
route module exports an array instead of an empty one.
