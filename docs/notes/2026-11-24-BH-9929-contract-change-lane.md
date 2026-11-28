# BH-9929: the contract-change lane (expand, migrate, contract)

Doc: RUN-BUILD-GRAPH

## Cause

The migration gate (`bin/check-migration-appliable.sh`) allows additive SQL
only. Its refusal named no other path. So a build that needed a non-additive
change worked around the gate: project-6-os has 6 tables cloned only to add a
value to a CHECK list, and project-1 has 5 one-to-one side tables.

## Change

- The ticket type: the label `contract-change` (GitHub Issues) or the body line
  `Contract-change: yes` (board). `bin/lib/contract-change.sh` reads it
  (`cc_is_ticket`) and classes the SQL (`cc_classify_sql`: constraint, type,
  nullability, rename, drop-column, drop-table, merge).
- The gate refusal: a FLAGGED non-additive statement prints one more line,
  `<file>: contract-change: ...`, that names the lane, the label and the marker
  line. The exit code and the FLAGGED line do not change.
- The lane: a master files 3 children through `file_children --kind rollout`
  (`bin/lib/fc-contract-change.sh`, the `contract-change hook` block of
  `bin/lib/rb/plan.sh`). RESULT is the rollout word: `ROLLOUT_FILED 3` or
  `ROLLOUT_FAILED contract-change: <why>`.
- The step gate: `bin/contract-change-gate.sh` runs in the `contract-change
  gate` block of `bin/lib/rb/pr.sh`. A refusal is `REVIEW_BLOCKED
  contract-change gate (<step>): <why>`, exit 6, no PR. The evidence lines are
  `$BUILD/contract-step.md`; they ride in the PR body.
- The human verdict: a step with drop-table, drop-column, merge or type carries the
  label `contract-change:human` and the body line `CONTRACT-HUMAN-VERDICT:
  required`. `la_decide` holds it until a `--source human` MERGE stands on the
  head, in lane and client mode and in an ungoverned repo.
- The apply path: `bin/migration-autopilot.sh` applies a FLAGGED file only as
  an approved contract step: switch on, label `contract-step:contract`, step
  row with backup and restore, MERGE verdict. The approver classifies the file
  it applies, at the merge commit. The file must carry a contract statement,
  and every other statement must pass the additive gate (no DELETE, TRUNCATE,
  UPDATE, GRANT or DO beside it). Every action inside a contract statement
  must be a contract or additive action (`cc_riders_sql`): a `DISABLE ROW
  LEVEL SECURITY` or `OWNER TO anon` in the same ALTER TABLE parks the file.
  The action splitter skips `'...'` literals and `"..."` names. The apply
  uses the same Scope 4 rule as the merge, judged on the FILE, not on the PR
  labels: a drop-table, drop-column, merge or type class needs a `--source human`
  MERGE on the head (a person confirms the self-attested BACKUP and
  RESTORE-TESTED lines before rows can be lost); a constraint,
  nullability or rename class needs the normal MERGE. So a step the lane may
  merge is a step it applies. A file whose only miss is the verdict is
  `contract-pending`: the autopilot asks again each tick inside its window,
  so a verdict posted after the merge is read. A FLAGGED file on an expand or
  migrate step is never applied. Every other miss keeps the FLAGGED (human)
  path. The actor is `contract-change:<approver>`.
- The project-6-os apply path is `bin/hotfix-migrate.sh` (workflow mode,
  `before_merge`, `local_gate` advisory). It applies BEFORE the merge, so the
  `la_decide` hold cannot stop it. With the switch on, a FLAGGED contract
  change goes to the workflow only as an approved contract step
  (`hm_contract_step`, the same approver), on the worktree head the verdict
  judged; `local_gate` advisory never passes an unapproved one. The proof
  comment and the step row record who approved it. An unreadable switch or a
  missing verdict is a hold; re-run the stage after the verdict.
- The SQL the lane reads: `scripts/migrations/*.sql` AND the project's
  `migrations_glob.<project>` row (`cc_sql_added`; project-6-os keeps its SQL
  in `prisma/sql/`). An unreadable row is could-not-run (rc 2). The old
  migration files of that directory are not old-shape reads.
- The contract-step gate refuses the same riders before the PR opens.
- The ledger: table `contract_changes` (jobs worker), the console project page
  section `CONTRACT CHANGES`. `GET /api/contract-changes` answers each step
  PR's live verdict from the verdicts table (the newest reviewed head, a
  human row first), with its source. The stored `verdict` is shown only when
  the PR has no lead or human verdict row.
- The switch: settings row `lib.contract-change.<project>.contract_change_enabled`,
  seeded 1 for project-6-os and project-3. Off is today's behaviour: the ticket
  is planned as an ordinary ticket.

## App-side apply contract (project-2)

The project-6-os apply path is in this repo (`bin/hotfix-migrate.sh`, above).
The project-6 workflow's own allow-list still runs after it. Each app apply
endpoint in another repo (the project-2 apply endpoint) must meet this
contract before it runs a non-additive statement:

1. Accept a DROP or another contract-class statement only with a
   `contractStep: {project, parentTicket, step, approvedBy}` field in the
   request.
2. Before it runs the statement, read the step row again from
   `GET /api/contract-changes?project=<p>&parent_ticket=<n>&step=<s>` on the
   jobs worker, and refuse when the row is absent or has no backup or restore
   reference. Read the verdict from the verdicts table
   (`GET /api/verdicts?repo=&pr=&head=&standing_only=1`, what `vd_standing`
   reads), never from the row: any holder of the jobs bearer can write the
   row. Refuse unless MERGE or MERGE-WITH-NOTES stands on the head, from
   `--source human` for a drop-table, drop-column, merge or type class.
3. Record `approvedBy` in its own apply ledger with the file and the time.

Without `contractStep`, the endpoint keeps its current refusal. This endpoint
lives in another repo, so it needs a ticket on its own board.

## Limits

- The box holds no production DB credentials. The `BACKUP:` and
  `RESTORE-TESTED:` lines come from an operator or an app-side job. The gate
  checks the lines and the step row, not the dump.
- The query-log count is the app's own evidence on the `OLD-SHAPE-READS:`
  line (migrate and contract steps). The gate checks the window against
  `CONTRACT_CHANGE_QUERY_LOG_WINDOW_H`. At the contract step the gate also
  proves the window from git: the last first-parent commit on main that
  touched a line naming the old shape (`git log -G`) is at least that many
  hours old. The window starts at the merge, not at the deploy; a deploy
  that lags the merge by hours shortens the real window by that lag.
- The contract step greps the old-shape names on the branch AND on main
  (the code production serves). A contract PR that removes the last read in
  the same PR as the drop is refused: hotfix-migrate applies before the
  merge, and production runs main until the deploy (BH-9929 refute review).
  So a writer named on the migrate step (`OLD-SHAPE-WRITERS:`) stops in an
  ordinary PR merged before the contract step. The migrate step's backfill
  script is skipped when the contract step names it (`BACKFILL-SCRIPT:`) and
  main holds it with the migrate header.
- A column type change is a human class, as a drop is: a cast such as
  `TYPE integer USING NULL`, or `numeric -> integer`, loses stored values.
- The project-2 apply endpoint lives in another repo. It needs its own
  ticket.
- The merge lanes that do not call `la_decide` (the GitHub-native enqueue and
  the direct merge on a repo that is not on Mergify) do not hold a
  `contract-change:human` PR.
