# Context-pack wire, shell side, and the child plan tripwire hook (BH-3492)

Doc: RUN-BUILD-GRAPH

## What changed

This is slice 1 of 5 of BH-3478 (the contract slice). A split child should
start its plan from the map its parent's planner already built, not survey
the repo again. This slice adds the shell half of that wire and the one
plan-stage hook the tripwire sibling plugs into.

- `bin/lib/context-pack.sh` (sourced, never run). It loads the jobs client
  lazily, the same way `_mr_ensure_client` in `bin/lib/model-route.sh` does,
  and puts the caller's `nounset`/`pipefail` back afterwards. Its root is
  `${HARNESS:-${H:-}}` only (D43). With an empty root and no client beside the
  lib, every call returns 1.
  - `cp_put <project> <child> <parent> <base-sha> <pack-file>`: POSTs
    `/api/context-packs` with `{project, ticket_key, parent_key, pack_md,
    base_sha?, box?}` (the pack goes in through `jq --rawfile` and is never
    sliced). rc 0 = published (prints `published`), 3 = the worker answered
    4xx (400/404/409/413), 1 = 5xx, unreachable, no client, or a caller bug
    (bad token, child == parent, empty pack file; these never reach the
    network). `JOBS_HTTP` is cleared before the call, so a stale 4xx can't
    turn an outage into a 3.
  - `cp_fetch <project> <key> <dst>`: GETs `/api/context-packs?project=&key=`.
    rc 0 = wrote `<dst>` (pack_md, exact bytes) and `<dst>.parent` (parent_key)
    through temp files and `mv`. rc 2 = 404, or a row whose parent_key equals
    the key. rc 1 = outage, 5xx, or a 200 that is not a context pack (garbage,
    `{}`, null, empty pack_md or parent_key). `<dst>` and `<dst>.parent` are
    touched only on rc 0.
  - `cp_preamble <pack-file>`: prints the fixed `WARM START: this ticket is a
    split child of <parent>. ...` sentence, a blank line, and the pack. With no
    pack or no `<pack-file>.parent` it prints nothing and returns 1.
- `bin/lib/rb/plan.sh`: a new `# >>> child plan tripwire (BH-3478)` block sits
  right after `# <<< size gate`, so it only runs on the non-split path. It
  sources `context-pack.sh` and `child-plan-tripwire.sh` when they are present.
  If `CP_PARENT` is unset it uses `$BUILD/context-pack.md` when that file is
  already there, or fetches it with `JOBS_ALERT=0 cp_fetch`, and reads
  `CP_PARENT` from the `.parent` file. With no parent it does nothing and logs
  nothing. With a parent it writes one `pipeline.log` line:
  `CHILD_PLAN_TRIPWIRE <first line of cpt_check>` when the checker is defined,
  or `CHILD_PLAN_TRIPWIRE skipped (no checker)` when it isn't. The checker runs
  inside `$(...)` with `|| true`, so a non-zero return or an `exit` can't change
  the build's rc or path. The block ends in `true`.

## What is not here yet

The worker route `POST/GET /api/context-packs`, `cp_compose`, the settings rows
(`child_plan_tripwire_pct`, `child_preplan_delta_tokens`) and `cpt_check`
itself come from sibling slices of BH-3478. Until the route deploys, every
build's fetch gets a 404 (rc 2, no alert), and the hook logs nothing.

## Tests

`tests/context-pack-wire.bh-3492-test.sh` stubs `_jobs_req`, drives the three
functions through each rc, and runs the hook block extracted from the flattened
pipeline (`tests/lib/rb-all.sh`) in a scratch harness.
