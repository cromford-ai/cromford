# One tracker answer before any GitHub write (BH-7919)

Doc: tracker-adapter

## What changed

Wave 1 of #7916. A Linear project registered with fleet.conf column 4 `-`
read as a GitHub Issues project to every lane that tested column 4 itself.
Its key `CRO-12` became GitHub issue #12 in the PR body (`Closes #12`), in the
BUILD BLOCKED comment and in the needs-human hold.

- `bin/lib/tracker.sh` gains `tracker_kind` (the `tracker_adapter` answer,
  cached per process), `tracker_context` (the adapter's `TRK_*` context for
  all four trackers), `tracker_key_prefix` and `trk_gh_issue_number`.
- `bin/lib/tracker/linear.sh` gains `trk_linear_context`, the twin of
  `trk_jira_context` (env `LINEAR_*`, rows `tracker_linear.<p>.*`).
- `trk_gh_issue_number` is now the only KEY-to-number step. It answers rc 3
  unless the tracker is github-issues. Ported: `TICKET_META`,
  `TICKET_THREAD_SIG`, the `CLOSES_LINE` block, `escalate_block`,
  `issue_closures`, `_ee_post_human`, `_ee_lift_epoch`, and the replan
  comment (`RPC_N` in `bin/lib/rb/plan.sh`), which now writes
  `replan-comment-skipped` instead of posting on the wrong issue.
- The three hand-built board contexts (`bin/deploy-rollback-board.sh`,
  `bin/lib/execute-empty.sh`, `bin/lib/fc-board.sh`) call `tracker_context`.
  The local `tracker_context` in `bin/deploy-rollback-board.sh` is now
  `_drb_context`.
- `ticket_identity` accepts `CRO-12` on a linear project and refuses it on a
  GitHub one. Source (a2) of `ticket_identity_conflict` and
  `preplan_key_prefix` ask the tracker kind first.
- `tests/tracker-direct-calls-ratchet.bh-7919-test.sh` and
  `tests/fixtures/tracker-direct-allowlist.txt` stop a new script from
  reading column 4 or calling a tracker API directly.

## The root handoff (rebuild r2)

The suite-reach gate refused the first build: `tests/lib-root-records.bh-2613-test.sh`
went from 313/0 to 312/1 on case `a6-seed-H`. `_trk_board_context` resolved
its root from `HARNESS` or `H`, then ran `bin/internal-token-for.sh` without
that root. The token script reads only `HARNESS`, else its own directory. With
only `H` set, it took the lib's own copy of `bin/` as its root, and on the
token fault it wrote `logs/ALERTS.log` and `flags/alerted-token-*` there. As
root over a root-owned checkout the case passed, because the child's write
into the checkout failed silently. Exported to a `nobody`-owned copy and run
as `nobody` (the gate's shape), it failed. The fix is one line: the lib calls
the token script with `HARNESS="$root"`. Case C7 of
`tests/tracker-kind-seam.bh-7919-test.sh` pins it in a writable copy of `bin/`.

## Behaviour that moved on purpose

- A tracker_adapter row with a typo (`linaer`) on a column 4 `-` project
  used to get `Closes #N`. Now it gets nothing: the guard fails closed.
- `issue_closures` refuses a digit-prefixed key (`TS2-12`). It used to read
  `12` out of it.
- fc-board resolves its token the BH-1955 way: a digit-prefixed token
  variable now resolves, two token variables are refused with the existing
  ALERTS line, the value is read from the env file and not from an exported
  variable, and a missing base writes the board-creds ALERTS line once a day.
- `_ee_post_human` and `_ee_lift_epoch` on a GitHub project accept a
  `<PREFIX>-<n>` ticket as well as a bare number.

## What did not change

No lane reads Linear or Jira. No new knob, row, table, cron line or alert.
With no `tracker_adapter.<p>` row every existing project routes as before.
