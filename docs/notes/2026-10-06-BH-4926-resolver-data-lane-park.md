# The resolver parks a data-lane block as DATA_LANE, never on the abandon ladder (BH-4926)

Doc: LANES, migration-ledger

## What changed

- `bin/blocked-resolver.sh` sources `bin/lib/data-lane.sh`. Right after the
  merged guard in `br_one`, a `rescue-giving-up`, `rebuild-review-blocked` or
  `review-changes-requested` row goes through `br_data_lane_route`. When the
  final review round is a `dl_candidate` (one finding, one `DATA_LANE:` path in
  the reviewed diff, VERDICT BLOCK), the row is parked `outcome=DATA_LANE` and
  answers rc 3, the HELD answer: no rung, no PER_TICK slot. The record is the
  row's own build dir, or the ticket's newest local build dir with a
  `review.md` when the row has none. A final round with no `DATA_LANE:` line
  never touches git. A `DATA_LANE:` line whose reviewed sha, diff or file
  cannot be read holds the row and never abandons it.
- Escalation, once per fingerprint: a ledger status `flagged … fp=<FP>` or
  `failed … fp=<FP>`, or an empty `DATA_LANE_APP_BASE` in `env/<project>.env`
  with no ledger row, writes an `escalate-data-lane` attempt and
  `data_lane_escalated=<FP>` first, then one
  `lane-alert --id data-lane-escalate:<project>:<pr|key>:<FP>`. An unknown
  ledger holds with no alert.
- Release: a ledger `applied`/`already-applied` at the same FP plus a
  `data-lane-probe.md` that contains `fp=<FP>` runs one rung,
  `data-lane-release`. It finds the PR (the row's url, or the open PR on the
  record's branch), requires its live head to equal the reviewed sha, claims
  `data_lane_released="<FP> <head>"`, and calls `br_rereview` kind `data-lane`.
  That kind never reuses a verdict already bought on the head (it was bought
  before the apply) and passes the probe to `mc_rereview` as `MC_RR_EVIDENCE`,
  which appends it after the prior review. Unset, the prompt is unchanged.
  APPROVE keeps the row DATA_LANE until the merged guard resolves it. BLOCK
  clears the outcome and the ladder owns it; the same FP and head never park
  again. No read gives the claim back. A paid read with no verdict is asked
  again, up to `BR_NOVERDICT_MAX`, then escalated once. Nothing here merges,
  enqueues or builds.
- `br_abandon` refuses a DATA_LANE row, or a record whose review is a
  candidate (or unreadable as one), until its release has run on that FP and
  head. The refusal is one log line and rc 4, so `br_abandon_rebuild` posts no
  ticket comment.
- `br_from_rebuilds` keeps offering a DATA_LANE row, and reads past the
  data-lane attempt rows when it looks for the last ladder attempt.

## Why

`bin/needs-human-hold.sh` answers "not an issues board" on an in-app board, so a
review whose only BLOCK was an unapplied migration walked
`rebuild-review-blocked -> abandon-rebuild`. TK-32 was ABANDONED that way and
TK-40 to TK-42 sat for three days.

## Not done here

No prod apply and no live release were exercised: the app's pre-merge endpoint
is a separate ticket. The proof is `tests/resolver-data-lane.bh-4926-test.sh`
in a scratch tree.
