# Merged and deploy-audited tickets advance on in-app boards (BH-3927)

Doc: BOARD-API-CONTRACT

## What changed

- New lane `bin/merged-ticket-advance.sh <project> [--cooled] [--dry-run]`.
  On an in-app board it reads the `in_progress` and `review` tickets. For each
  one whose newest build on this box (`builds/<p>-<KEY>-<12 digits>` or
  `builds/pool-<p>-<KEY>-…`) opened a PR, it looks up the LAST line in
  `state/postmerge-qa-done.txt` for that exact build. It falls back to the
  `postmerge_qa` ledger row when the file has no line. On `PASS` or
  `NOT_COVERED_NO_QA_ENV` it posts one comment, then moves the ticket: `done`
  if `system` filed it, `review` if anyone else did. A client ticket already in
  `review` is left alone.
- It holds the ticket on a newer build of the key that is not a PR, and on a
  client comment after the audit stamp. The harness's own comments are not the
  client: userId `system`, the board's self actor name (the
  `bin/lib/prebuild-repro/thread.sh` table, else
  `${BOARD_SELF_ACTORS:-System} Harness`), or a body with the lane's own
  `This is merged and` sentence. So a move that failed after the comment
  landed is retried alone on the next run.
- A held ticket still costs a GET against `MERGED_ADVANCE_MAX`, so a capped run
  writes the next candidate's id to `state/merged-advance-<p>.next` and the
  next run starts there and wraps round. Held tickets at the head of the list
  never starve the rest.
- `inapp_released_lines` (`bin/lib/rt/scope.sh`) calls it with `--cooled` right
  before the in-app parent close, so a split's last child reaching `done` lets
  the parent close in the same tick.
- The in-app parent close (`bin/decompose-parent-close.sh`) moves a
  client-filed parent to `review` instead of `done`. A parent with no reporter
  still goes to `done`. A client-filed parent already in `review` is dropped
  from the candidate list before any request, so it never spends
  `PARENT_CLOSE_MAX`. Its log line now reads
  `PARENT_CLOSED <KEY> (moved to <status>)`.
- A person's move back wins. An echoed move writes a moved marker (ledger row
  and `state/merged-advance-<p>-<id>-<token>.moved`). A ticket that carries it
  and is open again is held as `moved-back`, and the lane never moves it again.
  A move that fails is retried once per run, up to `MERGED_ADVANCE_MOVE_TRIES`
  (3) runs; then the lane writes one `MERGED_ADVANCE_GAVE_UP <KEY>` line, sends
  one alert, and stops trying (`move-gave-up`). The comment stands.
- Knobs `MERGED_ADVANCE_MAX` (10, 0 = off), `MERGED_ADVANCE_COOLDOWN_S` (600)
  and `MERGED_ADVANCE_MOVE_TRIES` (3) are settings rows under `lib.merged-advance`
  (`catalog/lanes.d/_lib.merged-advance.json`). Kill switch:
  `flags/merged-advance-off`.
- One `MERGED_ADVANCE moved=N comment-only=N skipped: …` line per run that read
  the board goes to `logs/<p>.log`, plus `MERGED_ADVANCE_CAPPED` when the cap
  stopped the run early.

## Why

A merged, deployed ticket stayed in `in_progress` until someone moved it by
hand, and on a split that also kept the parent open.

## Known gap

`bin/postmerge-qa.sh` does not audit `builds/pool-<p>-*`, so a pool-built
ticket counts `no-audit` here until it does.
