# Per-flip evidence runner and the STATE PATHS panel (BH-5000, slice C0)

Doc: MERGE-CONDUCTOR, OPERATOR-SETUP

## What changed

- New `bin/state-flip-evidence.sh <path> --since <YYYY-MM-DDTHH:MM[:SS]Z>`.
  It is the evidence an operator posts after flipping one dark DB path on the
  hub (#5000 scope step 5). It loads `bin/lib/sfe/<path>.sh`, found by
  filename, so each later path adds one file and edits no list. A module
  defines `sfe_flag_<p>`, `sfe_tick_<p> <since-epoch>`,
  `sfe_parity_<p> <since-epoch>` and
  `sfe_rollback_<p>` (`<p>` is the path with `-` as `_`). The runner prints
  `== flag ==`, `== tick ==`, `== parity ==`, the rollback command, then
  `RESULT: GREEN <path>` (rc 0) or `RESULT: NOT GREEN <path> (<n> check(s)
  failed)` (rc 1). A bad path, a bad `--since`, no jobs client or an empty
  `JOBS_URL` is rc 2 before any request.
- It is read-only apart from one thing: `bin/jobs-client.sh flag-active
  <name>` reconciles `flags/<name>` from its row, the same as every lane tick.
  Every other request is a GET, and `JOBS_ALERT=0`.
- First module: `bin/lib/sfe/pr-state-rows.sh` (order item 1).
  - flag: `flag-active pr-state-rows` answers rc 0 and its source line is
    `pause_flags row (active=1, …)`. A box file with no row, or a file newer
    than an active=0 row, is a FAIL.
  - tick: the newest `pr_state_events` row has `at` at or after `--since`.
    A non-404 error is `unreadable http=…`, never "no row since". The
    `logs/merge-conductor.log` mtime is printed as info. The conductor writes
    an event only when a PR changes state, so this check means "a transition
    was recorded since the flip", not "the lane ticked". In a quiet window the
    lane can run cleanly and still read `no pr_state_events row since`: wait
    for a PR to move (it may take more than one cycle) and run it again. After
    a rollback and re-flip, a sighting that re-POSTs the same
    `(repo, number, state, since, alerted)` is dropped by the dedupe index and
    does not count.
  - parity: every line of `state/merge-conductor/pr-state.tsv` whose `since`
    (column 3, the epoch of its last transition) is at or after `--since` has
    a `pr_state` row (`GET /api/pr-state?repo=<r>&limit=1000`) with the same
    number and state. Older lines are counted as `N pre-flip entries … not
    compared`: the flag shipped with no backfill and a PR that sits in one
    state writes no event, so a steady PR from before the flip never has a
    row. A `since` that is not an epoch is compared. A read that returns 1000
    rows FAILs as incomplete. A row with no tsv line is info, since another
    box may hold it. `attempts.txt` is counted and not compared, for the same
    no-backfill reason.
- Mission Control: `/settings`, HUB tab, new STATE PATHS section under
  PROTECTED PATHS. It shows one read-only row per path #5000 flips, in flip
  order: mode (`file`, `rows`, `shadow`, or `unread` when the read failed),
  the row or setting it came from, its `updated_at`, and a note. Each PATH
  links to `/config/flag/<name>` or `/config/setting/<name>`. The knobs go
  through `rowsOnlyState` (the `_flag_on_row` test). `no-twin-ledgers` on
  reads `shadow` because its file is still read first. `alerts-db` notes that
  a box's `ALERTS_DB_ENABLED=0` keeps it on file, which the console can't see.

## Hub run order (per item, operator)

1. Read the live value: `bin/jobs-client.sh flag-active <flag>` or
   `bin/queue-rows-flip-preflight.sh <gate>` for a knob.
2. Do not run the runner before the flip: the flag check fails and there are
   no rows yet, so it is `NOT GREEN` by construction. Readiness is step 1
   reading off and the lane's log showing clean ticks.
3. Flip it in a quiet window and note the UTC time.
4. After one full cycle of the lane:
   `HARNESS=/root/harness bin/state-flip-evidence.sh <path> --since <flip time>`.
5. Post its stdout on the ticket. On `NOT GREEN`, run the printed rollback
   line and stop.

## Not in this slice

The modules for the other paths: C1 `no-twin-ledgers`, C2 the five settings
knobs (parity through `bin/lib/qrf/<gate>.sh`), C3 `alerts-db`. Until a module
lands, the runner answers rc 2 for that path and lists the modules it has. The
panel already shows all eight paths.
