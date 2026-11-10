# BH-9127: Archie on the team screen, and spend per staff agent

Doc: docs/verification-map/entries/BH-9127.md, docs/verification-map/entries/BH-5567.md

What changed:

1. Archie posts heartbeats. `bin/lib/archie-hb.sh` posts one
   `POST /api/staff/ticks` row (agent `archie`) for each orchestrate turn
   past its claim, each `bin/archie.sh tick` that got its lock, and each
   `bin/archie-research.sh` run that got its lock. A failed post writes one
   line to `logs/archie-heartbeat.log` and returns 0. The orchestrate posts
   run after `deliver_reply` and the reply status, so they never delay a reply.
2. Archie writes activity rows. A new table `staff_turns` holds one row per
   orchestrate turn (outcome `answered`, `no_reply` or `stopped`) and one per
   `archie.sh tick` that acted (a beat or a model call; outcome `acted`,
   trigger `sweep` or `follow-up`). The writer is `POST /api/staff/turns`
   (`worker/jobs/src/routes/staff-turns.js`). The summary is the first
   non-blank line of the reply, token-scrubbed in the lib and again in the
   route. The route refuses a summary over `staff.turns.summary_in_max` (2000)
   and the lib cuts to that same row. The route stores
   `staff.turns.summary_max_chars` (200) of it. The link is
   the first GitHub issue or PR URL in the reply. A research run posts a
   heartbeat only.
3. The turn's cost. Orchestrate model calls carry
   `COST_RUN_ID=staff-turn:<turn_key>`. The timeline reads the turn's cost
   rows by that run id at page time. The cost is not stored on the row; it
   reads `n/a` until the box pushes its cost rows.
   The run id is the turn's own call's. `bin/agent-call.sh` and
   `bin/claude-cost.sh` un-export `COST_RUN_ID` (`export -n`), so a build the
   turn starts keeps its build dir as `run_id`, and cost per PR stays with the
   build (`tests/archie-turn-run-id.bh-9127-test.sh`).
4. The timeline (`GET /api/staff/agent/:name/activity`) has a new event kind
   `turn`, and Archie now gets `tick` events and `last_tick`.
5. Spend on the roster (`GET /api/staff/roster`): `spend_usd` (today, UTC),
   `spend_usd_7d` (the last `staff.spend.window_days` days, default 7),
   unpriced counts, `spend_lanes` and `spend_window_days`. An agent's rows are
   the rows of its lanes (`staff_lanes` plus the settings row
   `staff.spend.lane_map`, which holds Archie's lanes), plus its own heartbeat
   calls on the shared lane `staff` (through `staff_ticks.cost_run_id`). A row
   counts once. 0 means the read found no row; null means the read failed or
   the lane map is not valid (`sources.spend`).
6. Console: the `/staff` SPEND cell and the `/staff/<agent>` SPEND facts link
   to `/costs?agent=<name>`, which shows that agent's lanes from LANE SPEND.

Settings rows (seeded in `worker/jobs/schema.d/202611102058-bh-9127-staff-turns.sql`):
`staff.spend.lane_map`, `staff.spend.window_days`, `staff.turns.summary_in_max`, `staff.turns.summary_max_chars`,
`retention.staff_turns.days` (90; rule `staff_turns.age` of the BH-6750 job).

Indexes: `idx_staff_turns_agent_started`, `idx_staff_turns_started`. The roster
lane read uses `idx_cost_rows_lane_ts`, which `core.d` creates through
ensureColumns; it is not in the schema fragment, because `lane_id` is an added
column (the #2473 rule). The tick spend read pins `idx_staff_ticks_started`
with `INDEXED BY`, because with no table statistics the planner walks the
whole agent index instead.
