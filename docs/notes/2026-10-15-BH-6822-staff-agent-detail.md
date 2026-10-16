# Staff agent detail page (BH-6822, slice 1/4 of Staff in Mission Control)

Doc: DB-COORDINATION-SPEC, CONSOLE

## What changed

`/staff/<agent>` is now the agent detail page. It shows, in this order:

1. The facts (role, accountable, autonomy, cap, status) and LAST HEARTBEAT,
   the age of the agent's newest tick, linked to that tick.
2. The chat seam (`console-ui/src/screens/staff/agent-chat.js`, #6823).
3. The AUTONOMY slot (`autonomySlot` prop, #6824).
4. ACTIVITY: the agent's timeline, newest first, 50 rows a page, with an
   OLDER button while there is a next page. A header click sorts the loaded
   rows only, and the table says so.
5. OPEN FINDINGS, unchanged.
6. The learning seam (`console-ui/src/screens/staff/agent-learning.js`, #6825).

The seams render nothing until their slices land.

`/staff/tick/<id>` is new: every field of one tick and its cost rows, with
each row's session id (the transcript pointer).

## The ticks store

Heartbeat ticks were only lines in the hub's `logs/staff.log`, and only for
ticks with work. They are now rows in D1:

- Table `staff_ticks` (`worker/jobs/schema.d/202610161355-bh-6822-staff-activity.sql`).
  One row per `bin/staff.sh tick` that got past its lock. `phase` names where
  the tick stopped: roster, soul, collect, claim, model, act, done.
- Writer: the EXIT trap of `bin/staff.sh` posts `POST /api/staff/ticks`. A
  failed post is one line in `logs/staff-ticks.log` and does not change the
  exit code. A killed tick, a tick that did not get its lock and a bad agent
  name record nothing.
- The tick key is `<agent>-<yyyymmdd>t<hhmmss>z-<pid>`. The same body again
  is a 200 replay. Another body under the same key is 409.
- Cost: agent-call runs with `COST_RUN_ID=staff-tick:<tick_key>`, so its
  `cost_rows` row carries that `run_id`. The timeline joins the cost by
  `run_id` (index `idx_cost_rows_run_id`). An unpriced row is counted, never
  read as $0.
- Retention: rule `staff_ticks.age` in the BH-6750 job, window
  `retention.staff_ticks.days` (90). `retention.dry_run` applies.

## The timeline read

`GET /api/staff/agent/<name>/activity?before=&limit=` merges five sources by
`(ts DESC, kind DESC, id DESC)`: `tick`, `finding.claimed`,
`finding.recorded`, `outcome`, `decision` (Archie: `archie_decisions`, no
ticks). Each source is one indexed statement with `LIMIT limit+1` past the
cursor, so a page is exact. The cursor is `<ts>~<kind>~<id>` of the last row
shown. `limit` is 1..200 (default 50). A bad `limit` or `before` is 400. An
agent not on the roster is 404.

`finding.recorded` shows the finding's current status at its `updated_at`.
The table keeps no status history, so earlier statuses are not shown.

`GET /api/staff/roster` rows now carry `last_tick_at`. If `staff_ticks` is not
readable, the roster still answers with `last_tick_at: null` and
`sources.last_tick: "unread"`.

## The kill switch text

The console writes `staff-kill-<agent>` and `staff-kill-all`. Until now
`bin/staff.sh` read only `staff-off-*`, so a console kill stopped nothing.
`bin/staff.sh` now reads `staff-off-all`, `staff-kill-all`, then
`staff-off-<agent>`, `staff-kill-<agent>`, before any read. The roster and the
kill modal now say the heartbeat reads the flags at the start of every tick,
and the modal shows the agent's last tick age.
