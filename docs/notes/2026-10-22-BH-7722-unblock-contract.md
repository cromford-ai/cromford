# BH-7722 (UNB-0): the Tackler contract — ledger, roster rows, lane skeleton and seams

Doc: MERGE-CONDUCTOR, OPERATOR-SETUP

## What changed

- **The decision ledger.** `worker/jobs/schema.d/202610221731-bh-7722-unblock-decisions.sql`
  creates `unblock_decisions` with the spec DDL plus one column, `answer_command_id`
  (the answer's command id, so a re-delivered reply counts once). Four indexes, one per
  query, named in the fragment. The same fragment seeds the settings rows
  `retention.unblock_decisions.days=180`, `unblock.enabled=1`,
  `unblock.project.cromford.mode=shadow` and `unblock.standing_approval.cromford=1`;
  the roster row `tackler` (role unblock, observe mode, cap autonomy), its lane `unblock`,
  15 `staff_classes` rows and the model route `unblock.judge` (copied from
  `stage.execute` rung 0, no model literal). The `stage.unblock` route is BH-7725's
  row (`202610211200-bh-7725-unblock-route.sql`); this fragment does not write it.
- **`infra-restart` is delegated from day one** (the operator, comment 6294289621 item 2). It is
  inert while the project is in shadow mode. The seven never-auto classes (spend,
  production, live-probe, client-board, merge, deploy, governance) are
  `never_delegable=1`, and the table CHECK keeps them `ask_first`.
- **The worker routes** (`worker/jobs/src/routes/unblock-decisions.js`):
  `POST /api/unblock/decisions/claim` (one INSERT; 409 on a held key),
  `POST /api/unblock/decisions/record` (claimed to one outcome, once),
  `GET /api/unblock/decisions` (by subject, project or outcome; `card=u-xxxxxx` implies
  `outcome=escalated`), `POST /api/unblock/decisions/:id/answer` (a person answers an
  escalated card; 409 only for the same command again, 422 for a row that is not
  escalated, 403 for an agent answerer).
- **Retention.** Rule `unblock_decisions.age` copies terminal rows older than the window
  to the archive D1, then deletes them. A `claimed` or `escalated` row never leaves. With
  the archive unbound nothing moves. `retention.dry_run` applies as for every rule.
- **The lane.** `bin/unblock.sh tick [--project <p>]`, every 10 minutes on the hub
  (`cron/lanes/417-unblock.cron`, registry `catalog/lanes.d/unblock.json`). Kill switches
  first (`staff-kill-all`, `staff-kill-tackler`, `staff-off-tackler`, `lane-off-unblock`,
  the row `unblock.enabled`), then the project lock and mode row, the collectors, the
  rules, a claim before any spend, and one record per decision.
- **Mode, lock and project list come from `bin/lib/unblock/scope.sh`** (BH-7727). The
  tick calls `unb_scope_mode`, `unb_scope_lock` and, with no `--project`,
  `unb_scope_projects` (each fleet.conf project whose mode is not off). It has no mode
  or lock reader of its own, so the tick and `act.sh` read one grammar.
- **The claim evidence** is cut by its size AFTER JSON encoding: a record over 8000
  encoded bytes becomes `{truncated:true, head}`, and the head is halved until the
  wrapper fits. A quote-heavy record no longer goes over the route's 8192 limit.
- **The record body** carries `model_calls` as an integer (`1.0`, `1.5` and `"1"` are 1)
  and `cost_usd` as a number, so the route never refuses a billed answer.
- **The catalog.** `catalog/unblock-rules.d/_cites.json` (G1 to G21, copied from the
  spec's guideline table) and `_schema.json` (one rule file). `prompts/staff/tackler-soul.md`.
  `catalog/context-budgets.d/7722-unblock.json` (stages `unblock` and `unblock-judge`).

## The seam conventions

- A collector is `bin/lib/unblock/collectors/<family>.sh` that defines
  `ub_collect_<family> <project> <repo>` (a `-` in the family is `_`) and prints JSONL.
- The rules engine is `ub_rules_eval` (records on stdin, decisions on stdout), loaded
  from `bin/lib/unblock/rules.sh` when that file exists.
- The stages are `ubt_stage_judge` and `ubt_stage_card`, each called with the decision
  JSON and the resolved model, and each printing `{outcome, detail, model_calls, cost_usd, card?}`.
- The act layer is `ub_act` (`bin/lib/unblock/act.sh`, BH-7726).

## The wiring gap

The sibling slices define their own entry points. This slice calls none of them by name:

- `unblock_collect_infra` (`collectors/infra.sh`, BH-7725, on main) is not
  `ub_collect_infra`, so the tick reports the `infra` family `unwired` today.
- `ubq_collect` (`collectors/queue.sh`, #7752) and `unblock_collect_review`
  (`collectors/review.sh`, #7753) are the same when they merge.
- `unblock_card_decide` (`card.sh`, on main) and `unblock_judge` (#7753) are not
  `ubt_stage_card` and `ubt_stage_judge`, so their decisions are `deferred`.

The tick makes 0 reads and 0 claims for each. Three adapters, one per family
(`ub_collect_infra`, `ub_collect_queue`, `ub_collect_review`), plus one per stage,
connect them to the convention above after #7752 and #7753 merge.

## Tests that changed

- `worker/jobs/test/unblock-metrics.bh-7728.test.js` R8: the table is in the composed
  schema now, so `ensureTable` rebuilds a dropped table. R8 asserts that each route
  recreates it and answers, never a 503. R6 seeds the class with an upsert (the fragment
  seeds it ask_first).
- `worker/jobs/test/staff-charter.test.js` S1, S2, S2b and `staff-outcomes.bh-5563.test.js`
  D6 exclude `tackler`; `staff-screen.test.js` W1 counts 9 roster rows. Tackler's own
  rows are pinned in `unblock-decisions.bh-7722.test.js` W3.
- `worker/jobs/test/model-routes-seed.bh-1908.test.js` test 1 lists `unblock.judge` as a
  copy of `stage.execute`'s claude rung 0.
- `tests/unblock-scope.bh-7727-test.sh` S0 counts this fragment's cromford rows in the
  composed schema (13 mode rows, two approvals) and still pins that the BH-7727 fragment
  seeds no cromford row.

## Off

`unblock.enabled=0`, `flags/lane-off-unblock`, `bin/harness-ctl.sh off unblock`,
`staff-kill-tackler` (the console's /staff kill button), `staff-kill-all`,
`flags/staff-off-tackler`. Act mode needs the row `unblock.project.<p>.mode=act` and
`UNBLOCK_ACT=1`; neither is set by this slice.
