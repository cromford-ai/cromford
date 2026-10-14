# BH-4488: hard caps per (build, stage), the execute-stage tracer

Doc: AGENT-CALL, BUILD-TRIPWIRE

**What changed.** A build's execute stage can now be capped by two settings
rows. Before every execute call whose output lands in a build dir,
`bin/agent-call.sh` reads the build's own `cost.csv` and compares its total
against:

- `budget.stage.execute.max_calls`: the number of `execute` rows already in
  the build's `cost.csv` (one row per executed attempt).
- `budget.stage.execute.max_usd`: the sum of those rows' priced `cost_usd`.

At or over either cap, the call is not made. `bin/lib/budget-stop.sh` writes
`$BUILD/BUDGET_STOP` once and sends one alert (`lane-alert.sh --id
budget-stop:<project>:<build>`, or `alert-line.sh` where there is no
lane-alert). agent-call exits 74, with `$OUT` reading
`AGENT_CALL_REFUSED budget-stop <verdict>`. `CC()` in `bin/lib/rb/plan.sh` then
ends the build: build-board stage `budget_stop`, verdict `BUDGET_STOP`, and
`RESULT "BUILD_REFUSED BUDGET_STOP <verdict>"`. The console's Build page shows
the stage as "stopped at its budget cap", with the progress strip stopped at
execute.

**How to set one.** `PUT /api/settings` with key
`budget.stage.execute.max_calls` (or `.max_usd`) and a number. `off`, or no
row, leaves it unarmed. `0` is a real cap: no execute calls at all.

**The verdict line** (line 1 of `BUDGET_STOP`):
`budget_stop <stage> <reason> calls=<n> max_calls=<cap|-> usd=<x> max_usd=<cap|-> unpriced=<n>`.
Reasons:

- `max_calls` or `max_usd`: the cap was reached.
- `cap-unreadable:<key>`: the row is there, but its value is not a number.
  The call is refused (fails closed).
- `settings-unreadable`: the settings cache file exists but is not valid JSON
  with `.values`. The call is refused.
- `total-unreadable`: the build's `cost.csv` exists and cannot be read. The
  call is refused.

No settings cache on the box counts as unarmed, not unreadable.

**What counts.** Only rows whose stage is exactly `execute` count.
`execute-advisor` rows count toward neither cap. A row with no numeric cost is
counted as a call and as `unpriced`, and adds no dollars. Refused calls write
only the zero-cost global ledger row (`budget-stop:<reason>`), never a build
row. The check runs once per agent-call invocation, so a fallback ladder
inside that one invocation can go past the cap by that ladder's attempts.

**What clears it.** Nothing inside the build dir. Once the marker exists,
every later call into that dir is refused, at any stage, even with the cap row
removed. A fresh build of the ticket starts with a fresh total. TRIPWIRE takes
precedence over BUDGET_STOP when both markers are present.

**Out of scope here.** Token caps, per-tenant caps and other stages
(`BS_STAGES` in the lib is `execute` only). Those are later waves of BH-4475.

Pinned by `tests/budget-stop-tracer-test.sh` and
`console-ui/tests/stages.bh-4488.test.js`.
