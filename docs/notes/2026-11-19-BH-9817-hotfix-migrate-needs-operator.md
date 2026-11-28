# BH-9817: the before-merge migration approval, needs-operator, and the held alert

Doc: DB-COORDINATION-SPEC, docs/verification-map/hotfix-migrate.md

## What changed
- The approval of `hm_wf_approve_head` (`bin/lib/hotfix-migrate-workflow.sh`)
  goes out as the reviewer (hub) App, or on the default credential when that
  App is the PR author. Before, a pool builder posted it as the builders App,
  which opened the PR, and GitHub answered 422.
- GitHub's response body (`message`, `errors`) is kept in
  `$BUILD/hotfix-approve.err`, in the stage's stderr and in the proof comment.
  Before, `gh api` stdout went to `/dev/null`, so only
  `gh: Unprocessable Entity (HTTP 422)` was left.
- A 422 on the approval is terminal for that head: decision `needs-operator`,
  ledger `approve_refused.head`, 0 review calls and 0 comments on a re-run of
  the same head. Any other failure stays `retry`.
- In `local_gate=advisory` mode a FLAGGED statement whose first keyword is on
  `hotfix_migrate.workflow_refuses.<project>` stops with `needs-operator`
  before any approval or dispatch (`bin/lib/hotfix-migrate-operator.sh`).
- `mc_hotfix_proof` reads `needs-operator` as `hold`. Before the park, the
  conductor asks the production ledger (`mc_bm_operator_applied` ->
  `mmh_decide`). `applied` releases the PR after a hand apply, as on main
  (#3851, #3857). The new conductor
  fragment `bin/merge-conductor.d/bh-9817-held-operator-alert.sh` raises one
  `HELD_NEEDS_OPERATOR` alert after `hotfix_migrate.held_alert_hours` (seed 6),
  then at most one per 24 h.

## Rows
`hotfix_migrate.held_alert_hours`, `hotfix_migrate.workflow_refuses.project-6-os`,
`hotfix_migrate.operator_step.project-6-os`
(`worker/jobs/schema.d/202611181628-bh-9817-hotfix-migrate-operator-seed.sql`).

## Not changed
The project-6 workflow allow-list and its `MIGRATE_COMMENT_ALLOWED` variable.
No proof comment names a `/migrate` command.
