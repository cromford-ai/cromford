# The pool bundles before it spawns, and the spawn cap is a timed retry (BH-4859)

Doc: FLY-POOL-RESPAWN-CAP

## What was wrong

`spawn_one` in `bin/fly-pool.sh` ran `bin/fly-envbundle.sh` after it had already
bought the machine: claim, record a spawn against the per-key cap,
`fly machine run`, a 20 s boot, the harness sync, and only then the bundle. Each
bundle failure therefore cost a Fly machine and one slot of
`POOL_SPAWN_CAP_PER_KEY`. The bundler's stderr went to `/dev/null`, so the pool
log said `env bundle FAILED` and nothing else.

When those wasted slots hit the cap, the cap arm closed the row
`failed … deferred to a human` and deleted the queue file.
`bin/blocked-resolver.sh` only picks up `died N times` / `deferred N times`
reasons, so nothing read that row again.

## What changed

1. **Bundle before spawn.** The bundle runs after the queue claim and before
   `pool_spawn_cap_record` and `fly machine run`. It never needed `$MID`. If it
   fails, the `/dev/shm` bundle dir is removed, the row is handed back
   (`pool_unclaim`, rows-only) with `env bundle failed: <reason>`, and the
   function returns. No machine is bought and no spawn is recorded. The
   per-machine GitHub token swap, the account lease and the pushes stay after
   the spawn, because they are per machine.
2. **Infrastructure failures never count.** Every exit after the record where
   no build reached the machine calls `pool_spawn_cap_unrecord "$KEY"
   "$SPAWNCAPTS"`: no machine id from `machine run`, harness sync failed, and
   env/job push failed. The machine-run and sync exits also remove the bundle
   dir, which now exists there.
3. **The reason is kept.** The bundler's stderr is captured
   (`2>&1 >/dev/null`) and reduced by `pool_bundle_reason`: the last `FATAL:`
   message, else the last non-empty line, else `fly-envbundle.sh exited rc <n>
   and printed no reason`. Control characters are stripped, the text is cut to
   240 chars, and anything shaped like a credential becomes `reason withheld:
   the bundler's output looked like a credential`. The pool log line is
   `env bundle FAILED for <KEY>: <reason> — no machine spawned, job stays
   queued`. In `bin/fly-envbundle.sh` the two extract dies now carry the exit
   code (`ssh rc 255` is a connection failure; anything else is the remote
   script failing).
4. **The cap is a timed retry.** The cap arm no longer writes `QROW failed` or
   deletes the queue file. The row stays queued and the log says when it
   retries: `skipping <KEY>: spawn cap reached (<n> of <cap> in <w>s) —
   retried after HH:MMZ, …`. The time comes from the new
   `pool_spawn_cap_next_at`. It still pages once per episode, now as
   `POOL_SPAWN_CAP_WAIT`. The sentinel keeps its legacy name
   `<key>.defer-to-human` so live sentinels on the hub do not re-page.

## Why a timed retry and not a resolver hand-off

`br_rebuild_fresh` re-enqueues the same key. The pool would meet the same
`.spawns` log and trip the cap again on its next tick. The resolver's rebuild
ladder would be used up in a few ticks without a single machine, and the ticket
would end ABANDONED. The cap check is already a window timer, so the row just
waits for it. The loop still ends. After (1) and (2), every `.spawns` entry is a
machine that really ran a build, and builds that die or defer have their own
terminals (`pool-died-twice`, `pool-deferred-max`, then rebuild-fresh, then
ABANDONED).

## Trade-off

A harness-sync failure loop is no longer bounded by the cap. Each such tick
still writes `harness sync FAILED` to the pool log and destroys its machine.

## Relationship to #4800 (BH-4798)

#4800 edits the same `fly-envbundle.sh` call line (adds `--pool`) and adds two
"no GitHub credential" destroy exits after the spawn. #4800 landed first, so this
change is the second: it keeps `--pool` on the moved call, points #4800's
`2>>"$LOG"` at the capture fd (`LOG=/dev/fd/3` inside the substitution, so the
bundler's stderr is captured for the reason), and adds
`pool_spawn_cap_unrecord "$KEY" "$SPAWNCAPTS"` to #4800's two exits.
`tests/fly-pool-bundle-before-spawn.bh-4859-test.sh` B5 drives the second exit
(App tokens armed, no mint, no PAT in the bundle) and checks the cap count.

## Rows parked before this

Rows closed `failed … deferred to a human` before this change are not re-read by
anything. An operator recovers them with `queue_put`, after listing them with
`queue_list "" failed` filtered on `deferred to a human`.

## Tests

`tests/fly-pool-bundle-before-spawn.bh-4859-test.sh` drives
`bin/fly-pool.sh project-5` end to end. Cases d, g, n and p(2) of
`tests/fly-pool-respawn-cap.bh-1075-test.sh` changed on purpose, because they
pinned the old cap behaviour.
