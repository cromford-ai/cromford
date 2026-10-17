# Staff learning view on the agent page (BH-6825, Staff in Mission Control 4/4)

Doc: OPERATOR-SETUP

## What changed

The agent page `/staff/<agent>` shows what the BH-5563 learning loop
measures and proposes. Before this, the numbers were only in an API.

- New panel `console-ui/src/screens/staff/agent-learning.js`
  (`AgentLearning({agent, row})`, the agent-learning seam) and its pure lib
  `console-ui/src/lib/staff-learning.js`. `StaffAgentView` in
  `console-ui/src/screens/Staff.js` mounts it after OPEN FINDINGS.
- Sections: LEARNING (one row per window: precision, noise rate, merged,
  rejected, noise, total), OUTCOMES (opens when you click a count), PROMOTION
  PROPOSAL (the pending proposal and its evidence, with APPROVE… and VOID…)
  and DECISIONS (the newest 5 decisions with reason, actor and time).
- New worker routes in `worker/jobs/src/routes/staff-learning.js`, registered
  by `worker/jobs/test/route-table.d/787-staff-learning.txt`:
  - `GET /api/staff/learning?agent=`: the two windows, the pending promotion
    with its evidence (the newest 20 applied outcomes since the agent's last
    level change, with the true total), and the newest 5 decisions.
  - `GET /api/staff/learning/outcomes?agent=&days=&outcome=&before=&limit=`:
    the rows behind one count, newest first, cursor `before=<resolved_at>|<id>`.
  - `POST /api/staff/promotions/decide {id, decision, reason, actor}`.
- New coord write row `console-ui/functions/_lib/coord-writes.d/6825-staff-promotions.js`:
  `POST staff/promotions/decide`, body `id, decision, reason`, a reason is
  required, the actor is stamped.
- New schema fragment `worker/jobs/schema.d/202610170334-bh-6825-staff-learning.sql`:
  table `staff_promotion_decisions` (UNIQUE `promotion_id`, index
  `(agent, decided_at)`), index `idx_staff_outcomes_agent_resolved` on
  `staff_outcomes(agent, resolved_at)`, and three settings rows.
- Retention: the rules `staff_promotions.void` and `staff_promotions.applied`
  in `worker/jobs/src/routes/retention.js` delete the decision rows of the
  promotions they delete, as a `pre` in the same batch. No new rule.

## Rules

- A window is measured on `resolved_at`. A row at the cutoff is in. No
  outcome in a window is `n/a (no outcomes)`, never 0%.
- Precision is agent-core `precision()` over the verdicts: merged is agree,
  rejected and noise are overrule. Noise rate is noise / total.
- Approve uses the rules of `POST /api/staff/agents/autonomy`: never above
  the cap, only an active agent, and only from the level the proposal was
  made at. It raises the agent, marks the promotion applied and records the
  reason, in one D1 batch. The decision row is written first and every later
  statement needs it, so a refusal writes nothing.
- Refusals: 403 `agent_approver` (archie or a staff agent, any case), 409
  `stale_level`, `above_cap`, `agent_not_active`, `not_pending`. A replay of
  the same decision is 200 `existing: true`.
- The modal closes only on a 2xx. The note is the route's read-back, and the
  panel reads the GET again.

## Knobs

| Settings row | Default | Range | Meaning |
|---|---|---|---|
| `staff.learning.short_days` | 7 | 1..365 | the short window |
| `staff.learning.long_days` | 30 | 1..365 | the long window |
| `staff.learning.page_max` | 100 | 1..200 | max rows per drill-down page |

Junk or absent is the default, and the answer names the source. The outcome
retention keeps 180 days (`retention.staff_outcomes.days`); the panel says so
when a window is longer.

## Not in scope

Pending noise suppressions are a different proposal with their own route
(`POST /api/staff/suppressions/decide`). The panel does not list them.
