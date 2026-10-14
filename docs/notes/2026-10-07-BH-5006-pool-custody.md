# BH-5006: pool close-out custody sweep, and a terminal skip that says why

Doc: FLY-BUILDER-TRIAL, OPERATOR-SETUP

Scope 3 of #5006 (from #4918 scope 4). Scopes 1, 2 and 4 are actions on other
tickets' PRs and are owned by other lanes; this note covers only the code.

## BH-4764: queued, never spawned, nobody told

Cause: `bin/fly-pool.sh` arm 3 of `pool_spawn_decision` (the push-rejected
terminal gate) skipped the row every tick with one `fly-pool.log` line and
nothing else. The row stayed `claimed`, `bin/jobs-watchdog.sh` released it to
`queued` after 6h, and `bin/fly-dispatch.sh` (`[ -f .../$RK.json ] && continue`)
never re-claims a key whose hub queue file still exists. So the ticket read
`queued` on every surface and never built.

Now the skip calls `pool_terminal_noted`:

- `state/pool/<p>/<KEY>.held` in the BH-1461 shape, so `bin/fleet-status-push.sh`
  counts it held, not queued. `first_seen` is the terminal's `created_at`,
  because the HOLD gate's clear arm deletes `.held` every tick before this gate.
- the queue row is closed `failed` with a `terminal: push to <branch> rejected
  at <sha> …` reason (never `died N times` / `deferred N times`), unless
  `queue_status` already says `failed`, has no row, or could not be read.
  The queue FILE stays, so a moved head still re-arms on the next tick.
  Flag-off only: with `build_queue_rows_only` on, the row IS the queue (the
  tick materialises jobs from `queue_list queued`), so a `failed` row would
  never be listed or re-checked again and nothing could re-arm it. There the
  row stays `queued` and the gate re-checks it every tick.
- one ALERTS line (`<KEY>.terminal-alerted`) and one REST ticket comment
  (`<KEY>.terminal-noted`, written only after the POST succeeds).
- the comment says "If needed, comment `RETRY`". The `if` is deliberate:
  `POOL_REARM_NEG_RE` reads it as a negation, so the note cannot re-arm its own
  terminal when it is posted on a PAT (a User, not a Bot).
- neither the page nor the note offers deleting the branch: `branch_head_rest`
  reads a 404 as empty and the terminal check treats empty as unchanged, so only
  a push or a human `RETRY` re-arms.
- `pool_terminal_check`'s two re-arm branches remove `.terminal-noted`,
  `.terminal-alerted` and `.held` with the terminal file, and
  `pool_terminal_rearm_row` puts a row that reads `failed` back to `queued`, so
  the spawn's queued->claimed claim lands and the ledger does not say `failed`
  while the build runs.

## Pool results with no board close-out

Three reap paths leave a hub pool dir with a RESULT and no custody marker, and
nothing revisits it: `pool_push_full` failing at reap, the rc-1 arm of
`pool_relay_retry` (it drops `RELAY_DEFERRED` whether or not the push landed),
and a project with no `tailnet_ip`. `bin/pipeline-health.sh` check 4 then counts
the dir as "no board close-out" for ever (`pool-cromford-BH-4583-202610050404`).
Which of the three left that particular dir was not readable from the build box.

`pool_custody_sweep` runs once per tick right after `pool_relay_retry`. For each
dir older than `POOL_CUSTODY_SWEEP_S`, oldest RESULT first, up to
`POOL_CUSTODY_SWEEP_MAX`:

1. a newer exact-key dir (`pool-<p>-<k>-*`, key compared exactly) with
   `RELAYED` or `COMMENTED` → `SUPERSEDED` (no network);
2. `bd_result_in_ledger` rc 0 → `RELAYED`;
3. rc 1 → one `pool_push_full` in the dir's lifetime (`RELAY_RETRIED`);
4. still no owner, no box, or no ledger client → one ALERTS line naming the dir,
   its age, the RESULT head and the reason (`CUSTODY_ALERTED`). An alerted dir
   gets only the superseded check after that.

rc 2+ (ledger unreadable) does nothing: unknown is not absent.

Knobs (lane `fly-pool`, settings rows): `POOL_CUSTODY_SWEEP_S` (3600, 0 = off)
and `POOL_CUSTODY_SWEEP_MAX` (10, 0 = off). Non-numeric values fall back.

Operator escape: `touch builds/<dir>/SUPERSEDED` closes a dir out by hand.

## Review fixes (2026-10-09, review of 72b69292)

- **Aged out, no network.** The sweep does not chase a RESULT older than
  `CLOSEOUT_AGE_OUT_H` (default 168h), the ceiling pipeline-health check 4
  already uses (`closeout_age_out_s`, `bin/lib/closeout-terminal.sh`). It writes
  `SUPERSEDED` ("aged out: RESULT <n>h old …") with no ledger read, no ssh push
  and no page. Without this, the first ticks after deploy would push and page
  about a hub's weeks-old backlog (370 dirs on one box, 356 of them older than
  7 days). Test AT9.
- **The hold row no longer flaps.** The HOLD gate's clear arm leaves a key that
  has a `.terminal` file alone. `pool_terminal_noted` puts the fleet-page hold
  row only when its `.held` marker is new. Both re-arm branches of
  `pool_terminal_check` lift the row with the files. Before this, each terminal
  key cost two coordination-DB writes per tick, and the row was absent between
  them. Test BT5.
- **Known cost, flag-off path.** With `build_queue_rows_only` off, a box
  `run-build` re-enqueue can set a terminal key's row back to `queued`, and the
  next tick closes it `failed` again. Each tick costs one GET and at most one
  `queue_done`, until the branch moves. The plan accepts this, and it is
  recorded here.
