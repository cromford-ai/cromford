# Staff autonomy and delegation controls, with an audit (BH-6824, Staff in Mission Control 3/4)

Doc: DB-COORDINATION-SPEC, CONSOLE

## What changed

The staff agent page `/staff/<agent>` has a new AUTONOMY section. It shows
the agent's level, cap and status, each staff class with its state, and the
last changes. An operator can change the level and the delegation of one
class there. Each change needs a reason, and each real change writes one
audit row.

- New D1 table `staff_autonomy_changes`
  (`worker/jobs/schema.d/202610161625-bh-6824-staff-autonomy-changes.sql`).
  One row per real change: agent, kind (`autonomy` or `delegation`), class
  (NULL for a level change), from, to, actor, reason, time. Indexes:
  `idx_staff_autonomy_changes_agent_id` serves the page list, and
  `idx_staff_autonomy_changes_created` serves the retention read.
- `POST /api/staff/agents/autonomy` and `POST /api/staff/classes/delegation`
  (`worker/jobs/src/routes/staff.js`) take an optional `reason`. The value is
  a string of 1-500 characters after trim. Any other value is
  `400 {error: "reason"}`. A real change writes the audit row in the same D1
  batch as the state UPDATE (`INSERT ... SELECT ... WHERE changes() = 1`). A
  no-op, a refusal or a racing write writes no row. A 200 that wrote a row
  carries `change_id`. A route with no reason still works, and the row
  records `reason` NULL.
- The level UPDATE now also requires the level that the route read. If a
  racing write moved the level first, the answer is
  `409 {error: "changed_underneath", agent}` and nothing is written.
- `POST /api/staff/classes/delegation` refuses ANY change to a protected class
  (`never_delegable = 1`, or a name that `isProtectedSlug` matches) with
  `409 never_delegable`. Before this change, `ask_first` on such a class
  answered 200 and set its streak to 0.
- `ask_first` on a class that is already `ask_first` answers
  `200 {existing: true}`, writes nothing and keeps the streak. Before this
  change, it set the streak to 0.
- New `GET /api/staff/autonomy?agent=<name>`
  (`worker/jobs/src/routes/staff-autonomy.js`, fragment
  `worker/jobs/test/route-table.d/786-staff-autonomy.txt`). It answers the
  agent, `levels`, `classes` (with `effective_cap`, `protected` and
  `display_state`), `delegate_after`, and the newest audit rows. The answer
  also has `changes_limit`, `changes_limit_source` and `changes_truncated`.
  Archie is not a staff agent, so `agent=archie` is 404. A missing audit
  table is `503 staff_autonomy_changes schema not applied`.
- The coord proxy admits the two writes
  (`console-ui/functions/_lib/coord-writes.d/6824-staff-autonomy.js`). It
  refuses a blank reason with 400 and stamps the actor.
- Console: `console-ui/src/screens/staff/agent-autonomy.js` (`AgentAutonomy`,
  `AgentAutonomyView`) and `console-ui/src/lib/staff-autonomy.js`.
  `StaffAgentView` takes an optional `autonomySlot` prop, and
  `StaffAgentScreen` passes the panel. The level select offers only the levels
  at or below the cap. A protected class has no edit control. A capped class
  shows DELEGATE… disabled, with the reason. The modal closes only on a 2xx,
  and the panel then shows the GET read-back, not the request.

## Settings rows

- `staff.autonomy_changes_shown` (seed 20, range 1-500): the number of audit
  rows that the page lists. If the value is absent or junk, the code uses 20
  and the answer says `changes_limit_source: "default"`.
- `retention.staff_autonomy_changes.days` (seed 1095, 0 = off): the retention
  window.

## Retention

New rule `staff_autonomy_changes.age` in `worker/jobs/src/routes/retention.js`.
It removes an audit row older than the window. The rows are governance
history, made by a human, tens a year, so the window is three years.
`retention.dry_run` applies.

## Not covered

- The automatic demotion in `staff-outcomes.js` (a class goes back to
  `ask_first` on an overrule) writes `staff_classes` directly. It writes no
  audit row here. It has its own `staff_outcomes` row.
- The UI never changes a cap. The cap shows as read-only.
