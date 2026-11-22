# BH-9887 C0 — a withheld client-mode head asks the product board for approval

Doc: MERGE-CONDUCTOR

## The defect

Client mode (BH-9625, project-3) withholds every PR head that touches a
member-facing path: `la_decide` answers rc 1. The conductor's `mc_nhv_gate`
then set `MC_NEEDS_HV` and sent one internal warn beat (`la_human_needed`).
Nothing reached the product board. The project-3 ticket kept reading "waiting on
team", and four PRs (#1242, #1246, #1249, #1260) waited 1 to 2 days.

## The change (slice C0)

1. `mc_nhv_gate` (bin/lib/mc/classify.sh), on rc 1 with actions=1, calls
   `mc_ca_withheld` when a fragment defines it. The `la_human_needed` beat
   stays as before. The `mc_la_decide` memo now keeps `LA_PROTECTED_PATHS`
   (`MC_LA_MEMO_PATHS`).
2. `bin/merge-conductor.d/bh-9887-client-approval.sh` (`mc_ca_withheld`):
   switch on, a build record, the head's marker not settled, no kill switch:
   ONE detached `bin/client-approval-request.sh` and one `client-approval
   request spawned` line (STARTED only).
3. `bin/client-approval-request.sh <project> <slug> <pr> <head> <rec|-> [<paths>]`:
   under `flock -n`, one `POST {board}/tickets/{ticketId}/approval-requests`
   with `Idempotency-Key: client-approval:<project>:<pr>:<head>`, then ONE
   fixed client-safe ticket comment (who can approve, the Approve button).
4. `bin/lib/client-approval.sh`: switch, knobs, marker, body builders, the
   board POST seam, prune.

## Answers

| Board answer | Marker | Effect |
|---|---|---|
| 2xx JSON object, or 409 | `sent`, then `done` after the comment | `request_id`, `approvers` kept |
| 404 | `absent-route` | one log line per head, no ALERTS line; asked again after `absent_recheck_s` |
| anything else (000, 401, 5xx, non-object 2xx) | `failed`, attempts+1 | at `retry_max`: `cap-spent` + ONE ALERTS line |

No ticket id in the record: `no-ticket`. Not an in-app board: `not-board`.
A comment that fails `retry_max` times: `comment=cap-spent` + ONE ALERTS line.

## Marker (v1)

`state/client-approval/<project>/<pr>-<head40>.json` (box-local,
`catalog/state-paths.d/9887-client-approval.json`). Slices C1 (take the
approval from the board) and C2 (close the request, console field) read it
through `ca_mark_read`.

## Settings rows

`client_approval_board.<owner>.<name>` = `on|off` (no row = off; seeded `on`
for `example-org/project-3`), and `client_approval_board.retry_max` (5),
`timeout_s` (15), `absent_recheck_s` (3600), `marker_keep_d` (90),
`prune_max` (200). Seed: `worker/jobs/schema.d/202611220800-bh-9887-client-approval-board-seed.sql`.

## Shared contract to confirm with the board (TK-805)

The answer of the request route carries `id` (or `request.id`) and
`approvers` as an array of `{name}` objects or strings. 409 means this head
already has a request. The fake board
(`tests/fixtures/client-approval/fake-board.py`) pins this shape.

## Tests

`tests/client-approval-request.bh-9887-test.sh` (the real script against the
fake board) and `tests/mc/client-approval-hook.bh-9887-test.sh` (the real
`mc_nhv_gate` and fragment, plus one real conductor tick).
