# BH-9437 — the blocked-resolver ladder: five fixes

Doc: MERGE-CONDUCTOR

This note changes the `review-changes-requested` row of docs/MERGE-CONDUCTOR.md: a
round that produced no verified commit is the terminal only when no round is owed.

Ticket: example-org/cromford#9437. Code: `bin/blocked-resolver.d/bh-9437-*.sh`,
one-line hooks in `bin/blocked-resolver.sh`, `bin/lib/br/cap.sh` (`BR_CAPN_FLOOR`)
and `bin/lib/rb/plan.sh` (`KIND: review-replan`).

## The rules

1. **No rebuild on the same red** (`bh-9437-red-sig.sh`, `brlad_red_gate`). Before
   `br_rebuild_fresh` closes a ci-red PR, the gate reads the failing check runs of
   the PR head (filtered by the repo's required list when it answers) and stores
   them as `.red_sigs`. When the set equals the set of the PR before it, the ladder
   stops: no close, no enqueue, one `red-repeat` attempt, `.red_stop`, and ONE warn
   alert `red-repeat:<project>:<key>:<head12>` that names the checks and both PRs.
   The PR stays open. A new push restarts the compare. An unreadable read keeps
   today's rebuild. The gate sits after the cap check, so a spent ladder still
   abandons. The #9425 "main was red" / "flaky" marks are not on main yet and are
   not read.
2. **One re-plan at the review fix cap** (`bh-9437-review-replan.sh`). When
   `br_cap_notes` returns on an ALWAYS-BLOCK floor finding (`BR_CAPN_FLOOR=1`),
   the ticket gets a `KIND: review-replan` build note (the prior PR, the floor
   findings, the fix-round history) and a fresh build. `.review_replans` moves only
   when a job was bought, with the carried notes as a floor. The next cap abandons.
   A person's `CHANGES_REQUESTED` still abandons, as before.
3. **Verify against main, a brief from the last round, the real review cap**
   (`bh-9437-verify-baseline.sh`). A red typecheck or unit step counts as verified
   when the same commands on current main are red with the same failures (a subset
   check on parsed failure ids; an unparseable step stays red). The baseline is
   built in a detached worktree and cached per main sha. The last failed round's
   verify output rides in the next round's brief. A review park's failed round with
   a round still owed un-marks its head, so `BR_REVIEW_FIX_ROUNDS` rounds really run.
   An agent timeout (rc 124) is left to BH-9404.
4. **Re-review before rebuild** (`bh-9437-rereview.sh`). A green push sends
   `bin/lead-verdict.sh request <slug> <pr> <sha>` and stores `.rereview`.
   `br_rebuild_fresh` holds (rc 3, nothing spent, the cap close included) while a
   lead-review request for that head is `requested` or `running` and no verdict
   stands. A moved head, a standing verdict or a finished request releases it.
5. **Iron-law: adjudication only** (`bh-9437-ironlaw-adj.sh`). `br_fix_round` never
   runs for reason `iron-law` (`brlad_ila_no_fix`, the first line). `br_adjudicate`
   reads the head before the diff and again after it; a head that moved buys
   nothing, and the ruling (`.ila_ruled`) and the ACCEPT bind to that head. A moved
   head is scanned (`ilc_covered`): hits already accepted carry the ACCEPT with no
   model call, a new hit buys one adjudication, up to `BR_ILA_ADJ_MAX` heads; then
   the ticket is rebuilt. A REJECT is carried to the rebuild as a ruling note.

## Knobs (catalog/lanes.d/blocked-resolver.knobs.d/)

| Knob | Default | 0 means |
|---|---|---|
| `BR_RED_SIG_STOP` | 1 | no compare |
| `BR_REVIEW_REPLAN_MAX` | 1 | abandon at the cap |
| `BR_VERIFY_ON_MAIN` | 1 | any red step fails the round |
| `BR_VERIFY_BASELINE_TIMEOUT_S` | 1800 | (min 60) |
| `BR_VERIFY_PREV_BYTES` | 4000 | no brief |
| `BR_REREVIEW_GATE` | 1 | no ask, no hold |
| `BR_ILA_ADJ_MAX` | 3 | (min 1) |

Each fragment reads its knob through `brlad_knob`: a non-number is said once and
falls back to the default, and a number out of range is clamped.

## Record fields and files, and their retention

- `state/blocked-resolver/<p>/<key>.json`: `red_sigs` (last 8 rows), `red_stop`,
  `review_replans`, `rereview`, `rereview_said`, `ila_ruled`; attempt actions
  `red-repeat`, `review-replan`, `rereview-asked`. They live and retire with the
  record (`BR_FINISHED_RECORD_RETIRE_DAYS`, BH-9369).
- `state/blocked-resolver/<p>/<key>.verify-baseline.txt`, `.fix-verify.prev.txt`,
  `.capnotes-floor.txt`: one file per key, overwritten, never appended.
- `state/build-notes/<p>/<KEY>.md` with first line `KIND: review-replan`: consumed by
  the next build's plan stage like every other carried note.

Tests: `tests/br-red-sig.bh-9437-test.sh`, `tests/br-review-replan.bh-9437-test.sh`,
`tests/br-verify-baseline.bh-9437-test.sh`, `tests/br-rereview-gate.bh-9437-test.sh`,
`tests/br-ironlaw-adj.bh-9437-test.sh`, and §3a/§3c of
`tests/resolver-review-consumer-test.sh` (the real script end to end).
