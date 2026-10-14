# Merge-queue PATCH and held-page release write an audit row (BH-3156, BH-2325.1)

Doc: MERGE-CONDUCTOR

## What changed

Two worker handlers now write one `config_changes` row in the same
`env.DB.batch` as their own write, through `configChangeStmts` in
`worker/jobs/src/lib/config-changes.js`. The kinds `merge_queue` and
`held_page` came with the BH-3155 contract.

- `PATCH /api/merge-queue`: kind `merge_queue`, name `<project>#<pr>`,
  before/after hold `status` and `reason`, `actor` from the body (`api` when
  absent), `reason` from the body. No row when status and reason are both
  unchanged. A 404 or 409 writes nothing, not even the table.
- `POST /api/conductor/held/release`: kind `held_page`, name
  `<repo>#<number>`, `before_json` holds `state`, `head`, `kind`, `text`,
  `mode`, `first_held_at`, `after_json` is `'null'`, `reason` is `why`. No row
  when there was nothing to release (`{released:0}`). A blank `why` is still a
  400 that deletes and audits nothing. `released` is still the DELETE's own
  `meta.changes`.

Request and response shapes and status codes are unchanged, so the box-side
callers (`merge_queue_set`, `held_page_release`) are untouched. No route or
schema change. The route contract is `docs/verification-map/conductor-held-pages-api.md`.

## Why

`why` on a release was demanded and then dropped, and a merge-queue status
change left no record of who moved it. Both are now readable with
`GET /api/config-changes?kind=merge_queue` and `?kind=held_page`.

## Not covered

`POST /api/merge-queue` (enqueue and re-queue) also writes `merge_queue.status`
and is not audited. The ticket scopes the PATCH only.

The release reads the row before its batch, so a concurrent release that wins
between the read and the DELETE still leaves an audit row with `released:0`.
This is the same window as the `rules.js` DELETE.
