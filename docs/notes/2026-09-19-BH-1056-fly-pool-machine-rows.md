# Pool writes Fly machine registry rows (observe, put, close, advisory)

Doc: DB-COORDINATION-SPEC, fly-pool-sweep

**What changed.** `bin/fly-pool.sh` now writes to the Fly machine registry rows
introduced in BH-1054. On every tick, after the `fly machines list` proves usable,
it calls `machines_row machines_observe` to refresh the observed state before
the REAP loop mutates anything. After a successful spawn and after a reuse, it
calls `machine_put` with role `pool`, the job key/ticket, auth account and
state — plus the image on a spawn, and no image on a reuse, where `IMAGE` is
not yet in scope and the row already carries the image the machine booted with.
At every terminal destroy path it calls `machines_row_close`, which records
`destroyed`, `gone`, or `destroy_failed` (with flyctl's error detail). When a
live registry row names a key that has no local tracking file, the tick logs an
advisory and still spawns.

All of this is guarded by the `fly_machines_rows` setting (env first, then
`setting_get fly_machines_rows`) and by `command -v machines_row`; when the flag
is off, missing, or the worker is unreachable, the tick issues no worker
requests, leaves its file lifecycle unchanged, exits 0, and logs at most one
`machines row:` line. §2 (spawn), §3c (reuse) and §6 (reap, transport down) of
the suite are what check that; they are not an assurance.

**Why.** The registry is the hub-side ledger of which machines exist, what they
are building, and how they ended. Keeping it current from the pool lets the
console, the cost reconciler, and the triage/review lanes reason about pool
machines without polling Fly per machine.

**What it touches.**

- `bin/fly-pool.sh` — the `machines_row` helper and the seven call sites listed
  above, each inside a `# >>> machines rows (BH-1035)` region.
- `bin/fly-pool.sh`, one line that is NOT part of the registry work and is called
  out here because it rides this PR: the spawn-halt check read a hardcoded
  `/root/harness/flags/pool-halt-$P`, which is the one path in the file that
  ignores `$HARNESS`. It now reads `$HARNESS/flags/pool-halt-$P`. Prod behaviour
  is identical — `HARNESS` defaults to `/root/harness` at the top of the script —
  and it is what let the suite halt spawns to isolate the reap and reuse paths.
- `tests/fly-machines-rows-pool.bh-1056-test.sh` — new scratch suite that drives
  the real `bin/fly-pool.sh` with stubbed `flyctl`/`curl` and asserts on request
  logs, artifact files, and `fly-pool.log` lines.
- `docs/verification-map/fly-pool-sweep.md` and `docs/verification-map/entries/BH-1056.md`
  — updated to describe the new row-write behavior and how to drive it.

**The rule this note is itself an instance of:** one note per change, never edited
after merge; a correction is a later note.
