# Review autopilot: the record is ledger rows when no-twin-ledgers is up (BH-4156 C1)

Doc: DB-COORDINATION-SPEC

## What changed

`bin/review-autopilot.sh` keeps no record file when the `no-twin-ledgers` flag
is up. The flag is read once per tick (`lt_on`). With the flag down, the lane is
the file record it was before, byte for byte.

| what it was | the row (flag up) |
|---|---|
| `state/review-autopilot/<slug>-<num>-<head12>` | `ledgers` row `review_autopilot`, key `<owner/repo>#<num>@<head12>`. Status is the state word (`reviewed`, `skipped`, `reviewed-unposted`, `empty`, `failed`, `*-terminal`). Detail is the whole record text, `sha=` lines included. |
| `<key>.body` | row `review_autopilot_body`, same key, status `cached`, detail the comment. Status `dropped` after the post. |
| `count-<project>-<YYYYMMDD>` | row `review_autopilot_cap`, key `<project> <YYYYMMDD>` (it existed). No count file is written. |
| the newest `reviewed` key of a PR (verdict replay, BH-2310) | row `review_autopilot_pr`, key `<owner/repo>#<num>`, detail the head12 and then the record. |

`diff-<repo>-<n>.txt` stays a file. It is the model's input for one call, not a
record.

## Rules

- The row is read before any spend. An unreadable row (the worker did not
  answer, or a legacy key file is still on disk) buys nothing and posts nothing
  for that head. The lane logs one line for the head.
- An unreadable `review_autopilot_cap` row with `REVIEW_AUTOPILOT_DAILY_CAP` set
  buys nothing for the project that tick.
- The ledger route cuts `detail` at 4000 characters
  (`worker/jobs/src/routes/ledger.js`). `lt_put_rc` (`bin/lib/ledger-twin.sh`)
  refuses a value over 4000 bytes or a status over 128, and sends nothing. A
  comment over the limit, or a body whose row write failed, is cached in the
  local `<key>.body` file. That file is a cache, not the record. `ap_body_get`
  reads the row, then the file. A failed post is re-posted with no model call,
  the PR marker is asked first, and after `REVIEW_AUTOPILOT_POST_TRIES` the head
  goes `unposted-terminal` with one alert that names the file. The body drain
  deletes the file when its PR closes.
- A record row whose write failed is kept in `<key>.pending`. The next tick
  writes it to the row before it reads the row. Until it writes, the head is
  unreadable and buys nothing, so `FAIL_TRIES` and the empty bound hold. A cap
  row whose write failed is kept in the count file, which folds into the row on
  the next tick (the higher wins).
- The order does not change: the record says `reviewed-unposted` before the
  post, and `reviewed` only after the comment is up and its box verdict row is
  recorded.
- `ap_import_legacy` runs per project in row mode. A leftover key file becomes
  its row and is removed. Its body is imported first. A row that is already
  there wins, so a re-run imports nothing twice. A body file over the limit
  stays as the local cache, and its key still imports. A file that does not import is
  kept, and its head stays unreadable until it imports. A leftover count file
  for today folds into the cap row when it is higher, and is removed.
- `bin/review-autopilot.sh --print-body <owner/repo> <num> <head12>` prints a
  cached body row. The `unposted-terminal` alert names this command in row
  mode.
- `REVIEW_AUTOPILOT_NOW` pins the lane's clock, only with
  `HARNESS_TEST_SANDBOX=1`.

## Before the flag goes up on the hub

1. Read the flag: `bin/jobs-client.sh flag-active no-twin-ledgers`.
2. If it is down, the lane uses files, and nothing here is live.
3. After a flip, read the log for `imported legacy key` lines and for
   `is unreadable` lines.

Test: `HARNESS_TEST_SANDBOX=1 bash tests/review-autopilot-rows.bh-4156-test.sh`.
