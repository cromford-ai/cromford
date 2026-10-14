# A split child plans warm: delta pre-plan, child model route, `delta` cost tag (BH-3495)

Doc: RUN-BUILD-GRAPH, COST, MODEL-ROUTES

## What changed

This is slice 4 of 5 of BH-3478. The contract slice (BH-3492) added
`bin/lib/context-pack.sh`. This slice is its first reader. A ticket counts as a
split child only when the worker holds a `context_packs` row for its
(project, key). A body that quotes `Part of #` with no row, a row in another
project and a self-parent row are all "not a child", and those tickets plan
exactly as before.

- `bin/agent-call.sh`: `AGENT_CALL_ROW_NOTE=<tag>` adds `<tag>` to the cost
  row's note, joined with `;` like the other note tokens. It is cut to
  `[a-z0-9=:._-]` and 64 characters. With the variable unset, or reduced to
  nothing by that cut, the row is unchanged. The advisor sub-row of the same
  call carries the tag too, because it is the same call's spend.
- `bin/lib/child-plan.sh` (new): `child_plan_model <project> [fallback]`.
  1. `PLAN_MODEL_CHILD` from the environment.
  2. Rung 0 of role `stage.plan.child`, used only when its runner matches rung
     0's runner of role `plan`. On a mismatch it writes one ALERTS line per
     day per project (`stage.plan.child runner X differs from the plan
     route's runner Y — child plans stay on the plan route`) and falls
     through.
  3. Rung 0 of role `plan`.
  4. The fallback argument.
  5. Otherwise rc 75 with nothing printed.
  An unseeded `stage.plan.child` writes no ALERTS line. Nothing is cached, so
  a route change is picked up on the next call.
- `bin/run-preplan.sh`, block `# >>> context pack delta (BH-3478)`: when a
  pack is found, the pre-plan prompt starts with the WARM START preamble and
  the pack, the model comes from `child_plan_model`, and the call gets
  `AGENT_CALL_ROW_NOTE=delta` and `CONTEXT_KILL_TOKENS=<cap>`.
  `logs/preplan.log` gets `pre-plan delta: parent=<P> model=<M> token
  cap=<N> (<source>)`. With no row it logs `no context pack`; with an outage
  or an unreadable pack it logs `context pack unreachable — full pre-plan`.
  Either way the pre-plan then runs exactly as before: same prompt, and
  neither variable is set.
- `bin/lib/rb/plan.sh`, block `# >>> context pack (BH-3478)`: it reuses
  `$BUILD/context-pack.md` when a resumed build already has it, otherwise it
  calls `cp_fetch`. For a child it sets `CP_PARENT`, `CP_PREAMBLE` and
  `PLAN_MODEL` (from `child_plan_model`), and the `# >>> plan prompt` call
  gets `${CP_PREAMBLE:-}` in front of it. `pipeline.log` gets
  `CHILD_PLAN parent=<P> model=<M>`, or `CHILD_PLAN none (<why>)` where why
  is `no context pack`, `context pack unreachable` or `no context-pack lib`.
  The build plan gets no token cap.

## Where the plan.sh block sits, and why

The ticket asked for the block "directly above `# >>> plan launch`". It also
said the block "must also run when a pre-plan was adopted". On main those two
conflict: `# >>> plan launch` is inside the `else` arm of the checkpoint
`if [ -s "$BUILD/plan.md" ] && ! PLAN_IS_BLOCKED ...`, and adopted pre-plans
and resumes take the `then` arm. So the block sits right after
`# <<< call fp reuse`, before that `if`. It still runs before the plan launch,
and it also runs for adopted and resumed plans. That way `PLAN_MODEL` is the
child model for the plan call, the plan-gate repair, the size repair and the
PR body. `tests/child-plan-route.bh-3495-test.sh` P3 pins that order.

The contract's `# >>> child plan tripwire` block is unchanged. For a child it
finds `CP_PARENT` set and reads the same file, so it makes one GET. For a
non-child it still makes its own second GET, which answers 404. That costs one
cheap request, and the ticket forbade editing that block.

## Knobs

| knob | kind | fallback | read by |
|---|---|---|---|
| `child_preplan_delta_tokens` | settings row | 150000 (also used when the row is missing or not a positive integer; the log line says which) | `bin/run-preplan.sh` |
| `child_plan_tripwire_pct` | settings row | 50 | the tripwire checker (BH-3496), not this slice |
| `stage.plan.child` | model_routes role | role `plan` | `bin/lib/child-plan.sh` |
| `PLAN_MODEL_CHILD` | env | none | `bin/lib/child-plan.sh` (the operator's pin for child plans) |

`PLAN_MODEL` set in a box's env still pins non-child plans. For a child with
no `PLAN_MODEL_CHILD` and no child route, step 3 answers with the `plan`
route's model, as the ticket's order says. Set `PLAN_MODEL_CHILD` to pin
children too.

## Pointing child plans at Sonnet 5.5

Pick one:

- Console, Models page: give role `stage.plan.child` a rung 0 of
  `claude-sonnet-5-5` on the same runner as rung 0 of role `plan` (today
  `claude`).
- API: `PUT /api/model-routes` with
  `{"role":"stage.plan.child","ladder":[{"model":"claude-sonnet-5-5","runner":"claude"}]}`
  (add `"project":"<p>"` for one project only). The worker refuses a model
  that is not in `model_prices`. `claude-sonnet-5-5` is in
  `catalog/model-prices.json`.

If the runner differs from the `plan` route's, children stay on the plan route
and ALERTS says so once a day. No code change and no deploy are needed. The
model id lives only in the route row and in this note, never in `bin/`.

## How to see it working

- `grep -E 'pre-plan delta|no context pack|context pack unreachable' logs/preplan.log`
- `grep CHILD_PLAN builds/*/pipeline.log` (each line is followed by `PLAN (<model>)` on a fresh plan)
- `grep ',preplan,' logs/cost.csv | grep delta`
- Suites: `tests/preplan-delta.bh-3495-test.sh`, `tests/child-plan-route.bh-3495-test.sh`
