# The same-finding tripwire: two REVIEW_BLOCKED on one finding hold the issue (BH-3445)

Doc: RUN-BUILD-GRAPH

## What changed

This is slice 3 of 5 of BH-3433. The two stubs in `bin/lib/needs-human/trip.sh`
are now real. `LENS_REFUSE review` already calls `nh_trip_on_block` (BH-3442),
so no caller changed.

- `nh_trip_on_block <project> <issue> <review.md> <build-id> [<action>]`
  works out a fingerprint from the FINAL round of review.md. Re-reviews are
  appended, so the final round is everything after the second-to-last
  `VERDICT: APPROVE|BLOCK` line. The fingerprint is `nh_fingerprint` of the
  action (arg 5, else the round's first `NEEDS_HUMAN:` line), or else of the
  round's sorted BLOCK headlines (`F<n>`, `B<n>` or `<n>.` after markdown,
  containing the word block, not `non-block`/`not block`). With neither, it
  logs `fp:none` and stops.
- `nh_trip_note <project> <issue> <fp> <build-id>` keeps the D1 ledger row
  kind `review_block_fp`, key `<project>#<issue>#<fp>`. The detail is a JSON
  array of distinct build ids (newest 50), and the status is its length. A
  build id already in the array writes nothing, so a resumed build never counts
  twice. rc 0 at or above the threshold, 1 below it, 2 when the ledger is
  unreadable: no jobs client loaded, a read outage, a failed put, or a detail
  that is not an array of strings. rc 2 never counts and never trips, and a
  malformed row is never overwritten.
- The threshold is the settings row `lib.needs-human.needs_human_trip_count`
  through `lib_env_apply needs-human`, read on every call. It is clamped to
  2..10 and a clamp is logged. With no row and no env, it is 2.
- On a trip, the placer runs first:
  `bin/needs-human-hold.sh <p> <n> <fp> "pause-and-diagnose: the same review finding blocked <c> builds: <headline>" tripwire`.
  Then one alert goes out through `bin/alert-line.sh --project <p> --id nh-trip:<p>#<n>#<fp>`:
  `[needs-human] TRIPWIRE <p>#<n>: <c> REVIEW_BLOCKED builds on the same finding (fp <fp>), paused for diagnosis — <issue url>`.
  If the placer fails, the alert says `hold NOT placed (placer rc <rc>)`.
  If `lane_switch needs-human-hold-off` is on, no placer call is made and the
  alert says `NOT paused: needs-human-hold-off is on`. The ticket said alert
  then hold. The placer goes first so the alert can say what actually happened.
- Every call logs one `trip:` line to `logs/needs-human.log` (stderr when
  neither HARNESS nor H is set, and then nothing rooted is called). Nothing is
  printed on stdout and the function always returns 0, so the build's terminal
  is never changed.

## What usually lies

- **"paused for diagnosis" before BH-3443 lands.** Until then the placer is
  the stub, which exits 0 and places nothing. The alert takes the stub's rc 0
  at its word.
- **The headline fingerprint under-trips.** Two independent reviews rarely
  write the same set of headlines, and the headline fingerprint needs the set
  to match exactly. The `NEEDS_HUMAN:` action is the stable path.
- **Concurrent blocks on one key.** The ledger update is a read then a write,
  not atomic. Build-key locks keep one build per ticket at a time, so two
  blocks on one key at once is not a shape the harness produces.
- **A non-issues board never trips.** `NH_ISSUE` is empty there by design.

## Pinned by

`tests/needs-human-tripwire.bh-3445-test.sh` (N, D, U, K, T, F, H, S, E, C).
`tests/needs-human-contract.bh-3442-test.sh` T1 now expects rc 2 from
`nh_trip_note` with no jobs client loaded.
