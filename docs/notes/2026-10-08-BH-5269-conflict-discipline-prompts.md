# Conflict discipline in the builder prompts, the hotspot list in the primer, and the Shared-files report (BH-5269)

Doc: OPERATING, PLAN-CONTRACT

## What changed

- `prompts/build-discipline.md` has a new section with rules D51-D55: a new
  file over a shared list, the fragment pattern, no per-ticket changelog
  headers, `scratch_install_closure` in tests, and no new logic in a hotspot
  file when a module for that concern exists.
- `prompts/plan-contract.md` has a new §11. A plan carries a `## Shared files`
  section: one line per hotspot file it names, with a reason, or `None`.
- New `bin/lib/hotspot-context.sh`. `bin/verification-map.sh render` uses it to
  add a `--- CONFLICT HOTSPOTS` section to the project primer
  (`state/<project>-context.md`). The rows come from
  `GET /api/conflict-hotspots` (the `conflict_hotspots` table, BH-5267).
  `Sources:` ends with `conflict-hotspots=<state>`:
  - `yes`: rows, cited, with counts; `(top N of M files)` when truncated;
  - `none`: measured, zero rows;
  - `never`: no successful measurement yet (`ABSENT`);
  - `off`: knob 0 or bad (`ABSENT`);
  - `unknown`: `JOBS_URL` empty (no coordination DB), outage, wrong shape
    (`COULD NOT READ`).
  `JOBS_URL` resolves as for every worker caller: UNSET (the normal state of a
  pool build machine) takes the fleet worker through `bin/jobs-client.sh`.
  EMPTY makes no request; the suites run with it EMPTY
  (`tests/lib/scratch.sh`), so they stay offline. A row whose file
  name is not a plain repo path is dropped and counted.
- `render --hotspots-out <file>` writes the kept paths, one per line, on `yes`
  and `none`. On every other state it removes the file.
- The build's plan stage (`bin/lib/rb/plan.sh`) passes
  `--hotspots-out "$BUILD/hotspots.txt"` and runs the plan gate with
  `PLAN_GATE_HOTSPOTS="$BUILD/hotspots.txt"`. It logs one line:
  `plan gate: shared files <ok|unlisted|unread> (unlisted=<n>, noreason=<n>)`.
- `bin/plan-gate.sh` with `PLAN_GATE_HOTSPOTS` prints `PLAN_SHARED_NAMED`,
  `  SHARED_UNLISTED: <path>`, `  SHARED_NOREASON: <path>` and
  `PLAN_SHARED: ok|unlisted|unread` before `PLAN_TRACE`. A mention is a whole
  path outside fences and `## Sibling claims`. The exit code and the trace
  verdict do not change. Without the variable the output is the same as before.

## Why

Parallel builds conflict on a few shared files (docs/CONFLICT_HOTSPOTS.md).
The planner now sees this project's list and must say why it touches one.

## Knob

`PLAN_CONTEXT_HOTSPOT_TOP` (`catalog/lanes.d/_lib.plan-context-hotspots.json`,
row `lib.plan-context-hotspots[.<project>].plan_context_hotspot_top`): rows in
the section and the hotlist. Default 10, 0..50, 0 = off. A bad value is off and
prints one `PLAN_CONTEXT_HOTSPOTS_BADKNOB` stderr line.

## Proof

- `tests/prompt-conflict-discipline.bh-5269-test.sh`: the prompt sections and
  the real render with a stub worker.
- `tests/plan-gate-shared-files.bh-5269-test.sh`: a replay of three recorded
  plans (`.harness/specs/BH-5001`, `BH-2411`, `BH-4969`) through the real gate,
  and the build's plan-gate block.
