# Staff charter and autonomy tables (BH-5559, wave 2 of #5556)

Doc: DB-COORDINATION-SPEC

## What changed

The jobs DB has four new tables and two new views (`worker/jobs/schema.sql`,
BH-5559 block):

- `staff_agents`: one row per staff agent. Columns: name, role, accountable,
  autonomy, cap, status, soul_path. A CHECK keeps autonomy at or below cap.
- `staff_lanes`: (agent, lane). No rows yet. Lanes move to an agent in waves 7-9.
- `staff_classes`: (agent, class) with a per-class cap, never_delegable, state
  and streak. No rows yet. Classes arrive with each agent's soul (wave 4).
- `staff_decisions`: the same columns as `archie_decisions`, plus agent. No
  writer yet. Waves 4 and 6 add the writers.
- Views `agent_classes` and `agent_decisions`: Archie's rows with agent
  `archie`, plus the staff rows.

Seven agents are seeded in observe mode: autonomy `automation`, cap
`augmentation`, status `active`, accountable `operator@example.com`, soul path
`prompts/staff/<name>-soul.md`. The roles are quartermaster (cost), watchman
(security), dispatcher (health), inspector (quality), millwright
(maintenance), clerk (records) and archivist (memory). The soul files do not
exist yet. Nothing in this wave reads them.

One settings row: `staff.delegate_after` = 5, the agreements in a row a staff
class needs before it can be delegated. If the row is absent or not an integer
in 1..1000, the route uses 5 and says `min_streak_source: "default"`.

Four routes (`worker/jobs/src/routes/staff.js`, behind the bearer):

| Route | Result |
|---|---|
| `GET /api/staff/agents` | `{agents, invalid, complete}`. Each agent is a charter checked with `agent-core/schema/charter.schema.json`. A row that fails is in `invalid`, not in `agents`, and `complete` is false. |
| `GET /api/staff/agent?name=` | `{agent}`. 400 `name`, 404 `{"error":"agent not found"}`, 503 `agent row invalid`. |
| `POST /api/staff/agents/autonomy` `{agent, autonomy, actor}` | 200, or 409 `above_cap`, 403 `self_promotion` (a raise by `archie` or a staff agent), 404. A lower level is open to any actor. |
| `POST /api/staff/classes/delegation` `{agent, class, decision, actor}` | `delegate` passes only if agent-core `decide('autonomy', <lower of agent cap and class cap>, …)` answers allow (else 409 `capped` or `never_delegable`) and the streak reaches `staff.delegate_after` (else 409 `not_earned`). 403 `self_delegation`, 409 `agent_not_active`. `ask_first` puts the class back and sets the streak to 0. |

## Why the Archie tables did not get an agent column

The ticket asks to generalize `archie_classes` and `archie_decisions` with an
`agent` column. `ALTER TABLE … ADD COLUMN` is not additive here: a second
apply fails on the duplicate column, and `bin/harness-sync.sh` then skips the
`harness-jobs` deploy. `tests/schema-additive.bh-1000-test.sh` refuses it. Also,
`archie_classes` has the key `class` alone. So the Archie tables and
`src/routes/archie-autonomy.js` do not change. The staff tables carry the
agent column, and the views read both. Archie's routes read only `archie_*`
and the staff routes read only `staff_*`, so a class in one family is not
visible to the other.

## Apply order

`bin/harness-sync.sh` applies `worker/jobs/schema.sql` before
`wrangler deploy` and skips the deploy if a statement fails. So the tables
exist before the routes that read them. If the routes run first, they answer
503 `staff_agents schema not applied`, not a 404.

## Probes after the deploy

1. `GET /api/staff/agents` returns 7 agents and `complete: true`.
2. `GET /api/staff/agent?name=ghost` returns 404 `{"error":"agent not found"}`.
3. `POST /api/staff/agents/autonomy {"agent":"watchman","autonomy":"autonomy","actor":"operator"}` returns 409 `above_cap`.
4. Hub probe `d1-count staff_agents all` returns 7.

Tests: `worker/jobs/test/staff-charter.test.js`, run by
`tests/staff-charter.bh-5559-test.sh`.
