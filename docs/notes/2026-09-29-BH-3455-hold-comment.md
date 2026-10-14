# The merge conductor can post one hold comment per PR and kind (BH-3455)

Doc: MERGE-CONDUCTOR

BH-3455, order 4 of 5 of #3436. It builds on the BH-3452 contract, which put an
inert `mc_hold_comment` in `bin/lib/mc-hold-comment.sh`. This slice gives it a
real body. Nothing calls it yet: the sibling slices #3453/#3454 wire it into
the conductor, so production ticks behave exactly as before until one of them
lands.

## What one call does

`mc_hold_comment <owner/repo#n> <head> <kind> <reason>` always returns 0.

1. `MC_HOLD_COMMENT=0` returns at once. Otherwise the `MC_HOLD_COMMENT_TRACE`
   seam appends its line, as in the contract.
2. A kind `mc_hold_comment_clears` does not know posts nothing (`main-red`,
   `merges-off`, `asked`, `conductor`, `block-gate`, unreadable reads, checks,
   mergeable, anything else). Neither does a key that is not `owner/repo#n`.
3. Observe (`ACTIONS` not 1) or kill (`KILL=1`) sends nothing and writes one
   `HOLD_COMMENT WOULD <key> <kind>` log line per PR and kind.
4. Otherwise it posts once, through `mc_issue_comment` (REST, body by file),
   and logs `HOLD_COMMENT <key> <kind>`.

## The dedupe key

`<owner/repo lowercased>#<n>@<kind>`. The head is not in it: a hold that
outlives a push is the same hold, and a second comment on every push would be
noise. A different kind on the same PR is a new comment by design.

## The two stores

- The job ledger, kind `hold_comment`, key as above. Detail JSON carries
  `head`, `kind`, `at`, plus `attempts`/`reason` on a failure and
  `recovered:true` on a crash recovery.
- `$MC_STATE_DIR/hold-comments.txt`, append-only lines
  `<id> <status> <iso-ts> <head8>`; the last line for an id wins. It is read
  FIRST, so a PR that already has its comment costs no network at all. Only a
  file miss asks the ledger. No file line and no ledger answer skips the call
  (`HOLD_COMMENT <key> <kind> skipped: ledger and file both unreadable ...`):
  it fails closed.
- `$MC_STATE_DIR/hold-comments-would.txt` holds the observe-mode ids. It is a
  separate file so a WOULD never reads as posted, and switching observe off
  later still posts once. The attempts ledger is not used because an attempts
  row moves `read_memo_fp` and buys a PR re-read (`classify.sh`).

## Write, send, confirm

The states are `posting`, `posted` and `failed-<n>`.

- `posting` is written (ledger or file) BEFORE the POST. If both writes fail,
  nothing is sent.
- `posted` is written only when `mc_issue_comment` returns 0, which needs a 2xx.
- Anything else writes `failed-<n>`, where n is one more than the larger of the
  last status's n and the file's failed lines. The third failure logs one
  `gave up after 3 failed posts (HTTP …)` line and the id is terminal
  (`HC_MAX_FAILS=3`).
- The send runs under `flock -n` on `locks/hold-comment-<id>.lock`: dedupe, not
  a queue. The loser returns. The status is read again inside the lock.
- A `posting` status read inside the lock means a sender crashed between the
  write and the confirm. The PR thread is read once (`mc_rest_pages`, `since`
  the posting line's time) for the kind's marker. Found: `posted`, nothing
  sent. Unreadable: skip this tick. Absent: send.

## The body

Exactly two lines:

```
<!-- bh-hold-comment:KIND -->
We're not queueing this PR yet. Reason: R. What clears it: C. The merge conductor picks it up on its next pass once that happens.
```

The reason is flattened onto the second line: CR, LF and tab become spaces,
em and en dashes become `, `, whitespace is squeezed, a trailing `.` is
trimmed, and it is capped at 300 characters (`HC_REASON_MAX`). An empty reason
drops the `Reason:` sentence. So every line starts with `<!--` or `We're`.
That matters because the PAT posts as a User, and the PR-thread readers that
act on User comments (`bg_marker_block/clear/approve/resume` in
`bin/lib/block-gate.sh`, `hold_classify_thread` in `bin/lib/hold.sh`) are
line-anchored: a reason that carried `HOLD:`, `RESUME` or `VERDICT: APPROVE` at
the start of a line would otherwise be read as an instruction.

## Pipeline view

After a successful post, and only for the READY-row kinds (`ticket-hold`,
`pr-hold`, `hold-label`, `lead`, `lead-mergify`, `dep-hold`, `hotfix`), it calls
`mc_ready_why "$key" "$head" "$kind" "$reason"` once. `tightened`, `provenance`
and `iron-law` are classifier parks before READY, so they post but write no
ready-why note. The global `_MC_HC_IN` is set around that call, so a call back
into `mc_hold_comment` from inside `mc_ready_why` never calls it again.

## Turning it off

Set the `MC_HOLD_COMMENT` settings row on lib `hold-comment` to `0`. The lib
reads it when it is sourced, so from the next conductor run that sources it
the call returns at once: nothing sent, nothing written.

Tests: `tests/conductor-hold-comment.bh-3455-test.sh`; the contract stays pinned
by `tests/mc-hold-comment-contract.bh-3452-test.sh`.
