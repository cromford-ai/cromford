# BH-9865: the merged-ticket advance holds a multi-slice master ticket

`bin/merged-ticket-advance.sh` moved an in-app ticket to `review` (a `system`
ticket to `done`) when its newest build passed the deploy audit. It did not
read the plan's `SLICE:` line. `bin/board-closeout.sh` (BH-8333) keeps a slice
ticket in `in_progress`, and `bin/decompose-parent-close.sh` closes the master
when every child is done. So the lane moved the master after slice 1 and told
the client "Moving it to review so you can check it".

## Change

- The lane sources `bin/lib/slice-board.sh` and calls `slice_board_token`, the
  test `bin/board-closeout.sh` uses. Only rc 0 (a SLICE line for THIS ticket,
  by id, by KEY, or `The build for THIS ticket is C<k>`) holds.
- Local path: the newest build dir's `plan.md`, read after the audit check and
  before the ticket GET.
- Peer path: the merged PR's body, from the `pulls/<n>` read the lane already
  makes. A held peer ticket does not read the version route.
- A held ticket gets no comment, no move, no turn, no marker.
- The `MERGED_ADVANCE` log line ends with a new field, `slice-plan=N`.
- With no `slice-board.sh` on the box, nothing is held (as before).

Suite: `tests/merged-ticket-advance.bh-9865-test.sh`.

Doc: VERIFICATION-MAP
