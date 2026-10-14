# The merge-queue freeze dispatches its workflow on main once (BH-3891, part 4 of BH-3886)

Doc: MERGE-CONDUCTOR

## What changed

New `bin/lib/main-red-queue-dispatch.sh` defines `mrqd_self_dispatch <slug> <flagfile>`,
the hook `bin/main-red-detector.sh` already calls (BH-3888) when a `reason=queue`
flag survives a tick. The detector is not edited.

It dispatches the flag's own workflow (the basename of `path=`) on main once per
freeze episode, when all of these hold:

- the flag says `reason=queue`;
- the knob `lib.main-red-detector.main_red_queue_self_dispatch_min` (env
  `MAIN_RED_QUEUE_SELF_DISPATCH_MIN`, default 60) is above 0, and the freeze has
  held at least that many minutes since `raised=` (a legacy flag uses `detected=`);
- the ledger row `main_red_qdispatch <owner>/<repo>#<since>` was read and is absent;
- main's newest completed push run of that workflow is green, and no run of it is in flight on main.

The row is written as `dispatch=requested at=<stamp>` before the POST, and a write
that fails means no POST. A refused POST turns the row into `dispatch=refused`,
logs `dispatch REFUSED`, and sends one warn alert with the manual step
(`gh workflow run <wf> -R <slug> --ref main`). It is never retried. `--explain`
logs `WOULD SELF-DISPATCH` and writes and posts nothing.

## Why

A queue freeze clears on a green batch, or on a green `workflow_dispatch` run on
main newer than the freeze. When the queue is empty, no batch runs, and until now
someone had to dispatch Harness CI on main by hand. `since=` is the episode key,
so a new episode gets its own one dispatch.

## Operator surface

- `logs/main-red.log`: `SELF-DISPATCH:`, `WOULD SELF-DISPATCH`, `already requested … — not again`, `could not read/write the dispatch ledger`.
- The warn row on the console Alerts screen (existing `lane-alert.sh --severity warn main-red`).
- Turn it off: set the settings row to 0.

Suite: `tests/main-red-queue-self-dispatch.bh-3886-test.sh`.
