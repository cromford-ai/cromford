# A queued build row follows the project's routing, and a row nothing will claim pages (BH-3316)

Doc: EVENTS, DB-COORDINATION-SPEC

## Why

On 2026-09-28 five cromford rows (BH-1174, 1795, 1805, 2040, 2091) sat
`queued` for up to 349 minutes with `target=local` on a pool-routed project.
Only `bin/fly-dispatch.sh` and `bin/fly-pool.sh` claim build_queue rows, and
they claim `fly`, so nothing was ever going to pick these up. They came in
through `jobs-client.sh queue-put P KEY ID` with no target, and `queue_put`
defaulted that to `local`. Nothing paged: pipeline-health check 1 reads only
`state/build-queue/` files, and orphan-reconcile read each row as the ticket's
owner. They were retargeted by hand at 20:01Z.

## What changed

1. **`queue_put` with no target uses the project's routing** (`bin/lib/jobs/queue.sh`).
   `fly` on a fly1/pool project, `local` otherwise. An explicit `local` or
   `fly` is sent as given. Three helpers sit next to it:
   - `queue_routing_facts <p>` prints `builder|halted`. The D1 routing row
     (`routing_get`) answers first. If that read fails (outage, 404, unknown
     builder), the `flags/` files answer (`routing_row_from_files`).
   - `queue_route_target <facts>` maps the builder to `fly` or `local`.
   - `queue_target_stranded <facts> <target>` flags exactly two shapes:
     `local` on a fly1/pool project, and `fly` while routing is halted. A `fly`
     row on a `local` answer is not flagged, because `local` is also what a box
     with no flags and no routing row reports.
2. **The deferral requeue retargets** (`bin/jobs-watchdog.sh`). A deferred
   `local` row on a fly1/pool project is re-queued as `fly`, and the
   `queue-defer-requeue` log line carries `retarget=local->fly`. The sweep never
   flips a `fly` row to `local`, and a `fly` row on a halted pool stays `fly`.
3. **pipeline-health pages a stranded row** (block `stranded queue row`). A
   queued row older than `STRANDED_QUEUE_MIN` minutes (a settings row on the
   `pipeline-health` lane, default 60) whose target is stranded pages
   `strandedqueue:<p>:<key>` once per 2h, and the page carries the two retarget
   commands. `strandedqueue` is in `RETRACT_NS`, so the page retracts once the
   row is retargeted. A queue outage skips the project. A full 500-row page is
   named in its own `strandedqueue:<p>:page-cut` line.
4. **orphan-reconcile reports a stranded row instead of reading it as an
   owner** (`bin/orphan-reconcile.sh`). The row no longer owns the ticket. If
   nothing else owns it (PR, blocker, hold, grace), the verdict is `STRANDED`
   with why `stranded-target:queue row queued target=<t>`. It is NOT launched,
   because the launch would be a duplicate put against that same row. The run
   logs `reconcile: stranded-target — KEY(...)` and its summary line ends
   `stranded=<n>`.

## Retargeting by hand

The page names the commands. For each row:

    bin/jobs-client.sh queue-done <project> <KEY> done "retarget"
    bin/jobs-client.sh queue-put  <project> <KEY> <ticket-id> fly
