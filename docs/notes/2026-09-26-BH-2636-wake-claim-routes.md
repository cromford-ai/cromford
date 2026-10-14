# Wake claim, cursor and cooldown routes (BH-2525.1, BH-2636)

Doc: EVENTS

## What changed

The worker now answers the four routes the BH-2525 contract slice's shell
client already calls. All of them are in `worker/jobs/src/routes/wakes.js`,
registered between `GET /api/wakes/summary` and `GET /api/wakes`.

- **`POST /api/wakes/claim {box, repos[], kinds_all_repos[], limit}`** scans
  `wakes` above the box's `wake_cursors` row (0 when there is none) for rows
  whose lowercased repo is in `repos` or whose kind is in `kinds_all_repos`,
  `ORDER BY id LIMIT limit`. It claims them with `INSERT OR IGNORE INTO
  wake_claims ... RETURNING wake_id`, in slices of 99 ids, and answers only the
  rows that statement returned: `{wakes, cursor, scanned_top, as_of}`.
  `scanned_top` is the highest id scanned (the cursor when nothing was). The
  claim does not move the cursor. A claim is per (wake, box), so it is a
  dedupe and not a lock: another box gets the same wake.
- **`GET /api/wakes/cursor?box=`** answers `{box, cursor}`; `cursor` is `null`
  for a box with no row, never 0.
- **`PUT /api/wakes/cursor {box, cursor}`** upserts with
  `MAX(cursor, excluded.cursor)` and answers the stored value, so a stale PUT
  never moves a watermark back.
- **`POST /api/wakes/cooldown/take {kind, project, window_s, box}`** is one
  conditional upsert on `wake_cooldowns`; `taken` is `changes === 1`.
- **`POST /api/wakes/prune`** also deletes `wake_claims` rows whose wake no
  longer exists, after the wakes delete, bounded by the same `limit`. It adds
  `claims_deleted` and `claims_capped`; `capped` still means the wakes sweep.
  `wake_claims` joined `CREATED_TABLES` so the prune self-creates it on a
  database the schema apply has not reached, as it already does for `wakes`.

## Refusals

Every bad input is a 400 before any statement: a box, kind or project that
fails `laneName`; `limit` outside 1..500; `window_s` outside 0..604800; a
cursor that is not a non-negative integer; `repos` or `kinds_all_repos` that
is not an array of at most 500 strings of 1..200 chars; and both lists empty,
because a claim never takes all rows.

## Failure

If a later claim slice throws, the route answers 500. Earlier slices' claims
stay recorded but were never returned, so that box skips those wakes rather
than running a lane twice. `wakes_claim` prints nothing on a non-2xx.

## Tests

`worker/jobs/test/wake-claims.bh-2636.test.js` (A1-A8) drives every route
through `worker.fetch` over node:sqlite with `schema.sql` applied.
