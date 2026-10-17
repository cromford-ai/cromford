# One watcher per component decides its alerts (BH-6972, wave 2 of #6546)

Doc: ALERTS-GROOMING-SPEC, ALERTS-STATE-MACHINE

## What changed

A new hub lane, `component-watch` (`bin/component-watch.sh`, every 15 minutes,
`cron/lanes/734-component-watch.cron`). Wave 1 (#6971) stamps each alert with
the component that owns it (`catalog/components.tsv`). This lane gives each
component one bounded model run that decides each of its open alerts. Wave 3
(#6973) shows the decisions in the console. That is out of scope here.

## One tick

1. The dispatch (no argument) passes the lane gate and reads three settings
   rows once: `component_watch.budget_usd` (0.5), `component_watch.max_tickets`
   (2), `component_watch.max_attempts` (3). A missing row uses that fallback. A
   settings outage, or a value that is not a number in range (budget 0..20,
   tickets 0..10, attempts 1..10), is one line and no run. A budget of 0 is one
   line, `budget 0 (component_watch.budget_usd); no run`, and no run.
2. Every catalog row must load in `bin/component-of.sh`. The owner-doc check of
   `--check` is not run, because a box has no `docs/`.
3. Each component starts one detached run, unless
   `flags/lane-off-component-watch-<component>` holds it (one `held` line).
4. One run reads the component's newest 50 open alerts and its ledger row
   (`ledgers kind=component_watch key=<component>`) in parallel. The fp is the
   first 16 hex of sha256 over the sorted `id<TAB>last_seen` lines. The ledger
   keeps the fp of the set the last run left behind (its resolved alerts
   removed). The same fp after a `done` run is one `UNCHANGED` line and no
   model call. The same fp at `max_attempts` is one `UNCHANGED (failed <n>x)`
   line. An attempt is every call that does not leave the set `done`: a failed
   call, a call whose rows failed to apply or to record, or a call that leaves
   the set `pending` (for example a deferred ticket next to an alert the model
   left undecided or invalid, as with `max_tickets` 0). Only a call that leaves
   the set `done` sets attempts to 0. At the cap, a
   `pending` row with deferred tickets still files them, with no model call.
   So a lasting failure (a 409 on park, a 422 on the issue POST, no GitHub
   credential) costs at most `max_attempts` calls for one alert set.
   The ledger also keeps `park_next`, the earliest until of the parks the run
   left in place. A park changes the state, not `last_seen`, so the fp does
   not change. When `park_next` has come, the same fp is not `UNCHANGED`: the
   run sends the expired park to the model again (one run per expiry).
5. `GET /api/alerts/decisions?alert_ids=` gives the newest decision of each
   alert. A park whose until is ahead, and a ticket or escalate that landed
   with no sighting since, are settled and not sent. A `deferred` ticket is
   filed with no model call. Every other alert goes to ONE `bin/agent-call.sh`
   call: stage and role `component-watch`, no tools, `--max-budget-usd` from
   the budget row. The alert lines and log lines are wrapped as untrusted data.
6. Each decision is checked. An id that was not sent is dropped (one
   `unknown-id` line). The first decision for an id wins. A bad verdict, a park
   until in the past or more than 30 days ahead, an empty reason, or a ticket
   with no title is an `invalid` row, and nothing is applied.
7. Apply: resolve is `POST /api/alerts/actions action=resolve`; park is `PATCH
   /api/alerts/state parked` (already parked is `noop`); escalate is a `note`
   action, and no page is sent; tickets are grouped by title and filed as
   `ai-build` issues on `HARNESS_REPO`, at most `max_tickets` a run. An alert
   whose marker `<!-- component-watch-alert:<id> -->` is in an open issue is
   `ticket-exists`. A capped group is `deferred` with one `ticket-capped` line,
   and the next run files it.
8. One `POST /api/alerts/decisions` with every row, one log line per row, then
   the ledger: `done` only when the rows were recorded and no row is deferred
   or failed. A summary line ends the run.

## Table and routes

`alert_decisions` (`worker/jobs/schema.d/202610170620-bh-6972-alert-decisions.sql`):
alert_id, component, run_id, verdict, until, reason, title, outcome, issue, at.
Outcomes: `applied`, `noop`, `deferred`, `ticket-exists`, `invalid`,
`failed:<why>`. Three indexes, one per read. Retention rule
`alert_decisions.age` deletes rows older than `retention.alert_decisions.days`
(90) in the hourly `bin/d1-retention.sh` run (dry run first, as seeded).

- `POST /api/alerts/decisions` `{run_id, component, decisions:[...]}`: 1..60
  rows; one bad row is a 400 that writes nothing.
- `GET /api/alerts/decisions` with exactly one of `alert_id=`, `alert_ids=`
  (1..50, the newest row of each), `component=`; `limit` 1..200.

## Switches

- All components: `flags/lane-off-component-watch`, or
  `bin/harness-ctl.sh off component-watch "<reason>"`.
- One component: `bin/harness-ctl.sh off component-watch --project <component> "<reason>"`.
- Spend: `component_watch.budget_usd` = 0 stops every run; `LLM_LANE_ENABLED`
  and `LLM_USD_CAP_DAY` lane knobs apply through `bin/lib/llm-gate.sh`.

## Log contract

`logs/component-watch.log`, one line per decision:
`<ts> <component> <alert id> <verdict> <outcome>[ #<issue>][ until=<until>] <reason cut to 120>`,
and one summary line per run:
`<ts> <component> run=<id> open=<n> decided=<n> resolve=<n> park=<n> ticket=<n> escalate=<n> deferred=<n> invalid=<n> failed=<n> undecided=<n> filed=<n> calls=<0|1>`.

## Assumptions (from the plan)

- One registry file with `per_project_hold: true`, not one per component. The
  per-component flag is the ticket's name, `lane-off-component-watch-<component>`.
  `tests/lanes-registry-test.sh` needs the literal `lane_gate_or_exit <id>` in
  each wired lane's script, so ten lanes cannot share one script.
- park sets the existing `parked` state; the until lives in the decision row,
  and the lane re-offers the alert after it.
- escalate is a note action and the alert stays open. No page: up to 500
  escalations are possible on the first tick.
- Alerts that the model gives one title go in one issue. The cap counts issues.
- A capped ticket is stored `deferred` and filed by the next run with no call.
- Issues go to `HARNESS_REPO`, because the watched components are harness lanes.
- The prompt puts the alerts before the lane state and the log tails, so the
  byte cut removes log lines before it removes an alert.

## Known limits (review findings not changed in code)

- The open-issue read stops at 10 pages of 100 rows, pull requests included
  (`bin/lib/gh-rest-list.sh`). If the repo has more than 1000 open issues and
  pull requests, an old marker can be missed and the 1000-row guard does not
  trip. The newest issues come first, so a recent component-watch issue is
  found. A fix needs a truncation signal in the shared list reader.
- Retention deletes decision rows older than 90 days, the newest row of an
  alert too. An alert with no sighting for 90 days can then be decided again
  after its fp changes. The open-issue marker stops a duplicate issue; a
  second escalate note is possible. Keeping the newest row per alert needs a
  per-row subquery in the retention read, which the index law forbids.
- The lane drops code points above U+FFFF from a reason and a title. The
  route counts UTF-16 units, so an emoji could otherwise pass the lane's cut
  and fail the route's limit, and that 400 refuses the whole batch.
- The issue body replaces each backtick of an alert line with `'`, so an
  alert line cannot close the fence around it.
