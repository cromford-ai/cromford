# An operator's ABANDON survives a worker outage on the box that saw it (BH-2505)

Doc: HARNESS-COORDINATION

## What changed

- **`job_ticket_abandoned` (`bin/lib/jobs/jobs.sh`) keeps a per-box cache.**
  One file per ticket, `$JOBS_HARNESS/state/abandoned-tickets/<project>/<key>`,
  holding the abandoned job id.
- **A good read refreshes it.** An abandoned newest build row writes the file
  (a temp file in the same dir, then `mv -f`). An empty `.jobs` array, or a
  newest build row for this ticket in any other status, deletes it. An answer
  about a different ticket or kind (a worker older than the filters) returns
  rc 1 as before and leaves the file alone.
- **rc 2 now reads it.** When the worker does not answer, or answers something
  unreadable, a cached key answers rc 0 with its job id. Every other ticket
  still gets rc 2.
- Both callers inherit this with no change of their own: the pool's
  `QROW requeue` (`bin/fly-pool.sh`) refuses the requeue, and `br_one`
  (`bin/blocked-resolver.sh`) takes no rung.

## Why

The r2 review of #2481 (BH-2406): with the worker down, the helper failed open,
so the pool could requeue a ticket an operator had abandoned. This closes that
only for tickets this box has already read as abandoned.

## What it does not cover

- **No cache without `JOBS_HARNESS`.** `bin/jobs-client.sh` sets it from
  `HARNESS`, so every production caller has it. A bare-sourced `jobs.sh` (tests
  only) reads and writes nothing.
- **Unsafe names skip the cache.** A project or key that does not match
  `^[A-Za-z0-9][A-Za-z0-9._-]*$` is answered exactly as before.
- **A corrupt file is not an ABANDON.** An empty file, or one whose first line
  is not a plain id (`^[A-Za-z0-9._:-]+$`), answers rc 2.
- **Per box only.** A box that never read the ABANDON before the outage fails
  open as before; `state/` is not synced between boxes.
- **No expiry.** An entry leaves only when a good read shows the ticket is not
  abandoned (a newer build attempt, or no row).
- **The resume pass is unchanged.** `bin/lib/resume-dead.sh` decides from its
  own status listing, not from this helper.

Tests: `tests/job-abandon-cache.bh-2505-test.sh`.
