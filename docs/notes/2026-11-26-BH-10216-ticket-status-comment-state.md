# BH-10216: the status comment row keeps the id and the hash; no read before an edit

Doc: OPERATING

Before: 215 spent GETs per hour (the ticket counted 119 GETs from
`ticket-status-comment.sh` on the hub ledger between 10:00Z and 10:33Z).

## The row contract

Table `ticket_status_comments` (BH-9503, primary key `project, ticket_key`). No
new table and no schema change.

| column | meaning |
|---|---|
| `comment_id` | the id of the ONE status comment on the issue |
| `fingerprint` | the hash of the last body the lane wrote. `''` = the id is known, the hash is not |

- Writer: the lane through `POST /api/ticket-status-comments`. `fingerprint: null`
  is stored as `''` with `final = 0`. `''` never equals a rendered hash, so the
  ticket stays due WITH its id.
- Forget: `DELETE /api/ticket-status-comments?project=&key=&comment_id=`. It
  deletes the row only while it still names that comment id (200,
  `{ok, deleted: 0|1}`).
- Reader: `GET /api/ticket-status-comments/due` (unchanged).

## The lane, per due ticket

| case | GitHub calls | worker calls |
|---|---|---|
| row, same hash | none (not due) | due read only |
| row, new hash | 1 PATCH | record |
| row, PATCH 404 (a person deleted the comment) | 1 PATCH, 1 POST, 0 GET | DELETE, then record |
| row, PATCH 404, DELETE fails | 1 PATCH | DELETE; `failed=1`, no POST |
| row, PATCH fails (not 404, not 75) | 1 PATCH | none; the old hash stays, the next tick PATCHes again |
| no row, our marked comment found | 1 list read, 1 PATCH | pre-record (`fingerprint: null`), then record |
| no row, no marked comment | 1 list read, 1 POST | record |
| due read fails | none | due read only; nothing written |

The list read happens only when there is no row. It reads at most
`TICKET_STATUS_COMMENT_ADOPT_PAGES` pages (default 3), as before.

## Proof

- `tests/ticket-status-comment-state.bh-10216-test.sh` (S1-S7) counts the fake
  GitHub calls by method for each case above.
- `worker/jobs/test/ticket-status-comment.bh-10216.test.js` (W1-W7) pins the
  DELETE (wrong id and wrong project delete 0 rows), the null hash and the
  EXPLAIN of the delete (primary key, no SCAN).

After the merge, the ticket gets the 24 h count from
`bin/gh-ledger-report.sh --per-merged-pr --by-repo --last 24h`.
