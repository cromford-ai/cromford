# The doorbell hears five more GitHub events, and `bin/webhook-rearm.sh` (BH-4058)

Doc: EVENTS

## What changed

`wakeOf` in `worker/jobs/src/lib/core.js` now turns these deliveries into wake
rows (it used to answer 202 and drop them):

- `issues.labeled` with `ai-build` or `hotfix` (any case) is an `issue` wake.
  The label name decides and is never stored.
- `deployment_status` `failure`/`error` is a new kind, `deploy_failed`. It is
  never `deploy`, because a `deploy` row launches post-merge QA.
- `status` (`success`/`failure`/`error`) and `workflow_run.completed` are
  `checks` on the sha, so they reach the conductor like `check_suite` does.
- `merge_group` `checks_requested`/`destroyed` is a new kind, `merge_group`.
  As `checks` its temporary head sha would miss pr-state.tsv and buy an unkeyed
  conductor run per queue entry.

`check_run.completed` was already mapped on main; nothing changed for it.

`bin/wake-loop.sh` acks `deploy_failed` and `merge_group` rows quietly: no lane
consumes them yet (#1034 follow-up), cron still covers both, and the wake-class
row hooks still see them.

`bin/load-project.sh`'s arming banner subscribes `status`, `workflow_run` and
`merge_group` too. Hooks armed before this change lack them;
`bin/webhook-rearm.sh` (dry run by default, `--apply` to write) adds them to
every fleet repo's existing receiver hook with an events-only PATCH. The App's
own webhook is reported, never written: that is the App settings page.

## Operator steps, in order

1. Merge, then deploy the worker (`bin/harness-sync.sh`).
2. On the hub: `bin/webhook-rearm.sh`, read it, then `bin/webhook-rearm.sh --apply`.
3. For repos served by the App webhook: add the three events and the App
   permissions Commit statuses, Actions and Merge queues (read) on the App
   settings page.
