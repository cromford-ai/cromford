# watchdog-responder stays on the hub (BH-7426)

Doc: PROJECT-LANES, OPERATING

## Decision

BH-7426 asked to move `watchdog-responder` to Fly with `bin/lane-move.sh`.
Step 1 of the ticket says: if the lane reads hub-local state that a lane-run
machine cannot get, do not move it, and write the
`lane_placement.watchdog-responder.hub_only` row. The lane fails that check.
This change seeds the row. It adds no lane-move module.

## Evidence (main b0bdaba0)

1. `bin/watchdog-responder.sh:134` keeps the 12 h cooldown in
   `state/responder/handled.json`. This is one fleet-wide JSON file keyed
   `<project>:<key>`. The script rewrites it under a lock (lines 239, 257,
   285, 911-918). `catalog/lane-run-inputs.d/watchdog-responder.rw` does not
   carry it, and its header says so ("NOT CARRIED ... they block a flip of
   watchdog-responder to Fly"). A machine run starts with no cooldown, and
   its stamps are lost. Each 20-minute tick then pays again for the same
   decide and act model calls.
2. `bin/watchdog-responder.sh:364`: the act prompt starts
   `setsid /root/harness/bin/run-build.sh` and reads
   `/root/harness/state/build-queue/` and `/root/harness/state/fly-pool/` by
   hub path. On a lane-run machine, that launch fails or starts a build on
   the wrong box.
3. `bin/watchdog-responder.sh:405` and `:523` read the board token through
   `bin/internal-token-for.sh` (`env/<p>.env`). A lane-run machine does not
   have this credential (`.rw` header, and
   `docs/notes/2026-10-14-BH-6720-llm-alert-lanes-offhub.md`). Every item then
   goes down the evidence-missing path.
4. `bin/watchdog-responder.sh:74`: every project run appends to
   `logs/responder.log`. The lane-run write-back carries
   `logs/watchdog-responder.log`, not this file.

`bin/lib/llm-lane-project.sh:91` dispatches the lane through `pl_dispatch`, so
a `fly` row would move the runs. The blockers are real.

## The row

`worker/jobs/schema.d/202610191452-bh-7426-watchdog-responder-hub-only.sql`
seeds it with `INSERT OR IGNORE`, actor `seed`. `bin/harness-sync.sh` applies
it before the jobs worker deploy. The value is under 120 characters, because
`bin/lane-move.sh` and `bin/lane-cpu-rank.sh` show it.

With the row, `lp_decide watchdog-responder [p]` in
`bin/lib/lane-placement.sh` answers `hub` for every lane or project row,
`bin/lane-move.sh` holds the lane, and `bin/lane-cpu-rank.sh` shows the
reason. `tests/lane-move-watchdog-responder.bh-7426-test.sh` pins the row,
the absence of a module and of a `fly` seed, and the `lp_decide` answers.

Check it after the deploy:

    bin/jobs-client.sh setting-get lane_placement.watchdog-responder.hub_only

## To move the lane later

1. Solve the blockers: a shared cooldown store the machine can read and
   write, a hub-side build launch, and a board credential for the machine.
2. In one PR, remove the seed fragment, remove W1 and W2 from the test, and
   add `bin/lib/lane-move/watchdog-responder.sh` per the contract in
   `bin/lib/lane-move/pipeline-health.sh`.
3. An operator deletes the row in D1. `setting-set` cannot delete a row, and
   an empty value already reads as no reason.
