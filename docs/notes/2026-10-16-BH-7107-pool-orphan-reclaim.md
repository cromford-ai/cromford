# The pool reclaims orphan slots, names a stall, and cancels held in-flight builds (BH-7107)

Doc: FLY-BUILDER-TRIAL, OPERATOR-SETUP

## Why

On 2026-10-16 the project-6-os pool had every slot held by job files whose
machines Fly no longer had. `bin/fly-pool.sh` read only
`FLY_API_TOKEN_<PROJECT>`. With that value empty, the tick ran `exit 0` before
the reap, with no log line and no alert. The reap's dead path, the BH-660 sweep
and the spawn never ran. `LIVE` still counted every job file, so the budget
stayed 0.

## What changed

1. **Token order** (`bin/lib/fly-token.sh`, `fly_token_resolve`). The pool tick
   uses `FLY_API_TOKEN_<P>` first, then the org `FLY_API_TOKEN` from `fly.env`.
   It never reads an inherited `FLY_ACCESS_TOKEN`. A tick on the org token
   writes one line: `using the org FLY_API_TOKEN: FLY_API_TOKEN_<P> is not set`.
   The org token applies to the whole tick: reap, sweep and spawn.
2. **No token, app set.** The tick is no longer silent. It writes one line
   per tick, keeps the stall state below, and pages after the stall window:
   `[pool/<p>] queued <Q>, building unknown, for <N>m: no Fly token
   (FLY_API_TOKEN_<P> or FLY_API_TOKEN) in fly.env: ...`. It makes no Fly call
   and touches no job or queue file. With no app, the tick exits as before.
3. **Stall alert** (`pool_stall_tick`, `bin/lib/pool-stall.sh`). After the
   spawn budget: queued > 0, budget 0, no hotfix exemption and 0 machines
   `started` in this tick's listing (or `unknown` when the listing was
   unusable). The first stalled tick is kept in `state/pool-stall/<p>.json`
   `{since,cause}`, and a clear tick removes it. Every stalled tick writes a
   `stall:` line. Past `POOL_STALL_ALERT_S`, one ALERTS line per project per
   hour names the cause (flags `alerted-pool-stall-<p>-h<HH>-<YYYYmmdd>`).
4. **In-flight HOLD cancel** (`pool_inflight_hold_step`). In the reap, for a
   live machine with no RESULT, on GitHub-issue tickets only (never a board
   cuid, never an `RB-` key):
   - It uses the hold cache first. Else it reads the thread only when the
     open ai-build listing key changed or the issue left the listing.
     `POOL_INFLIGHT_HOLD_READS` caps those reads per tick, and a deferred read
     is logged.
   - The verdict and its first-seen time ride the machine json as
     `.inflight_hold {ticket,key,verdict,seen_at}`. A record for another
     ticket is ignored.
   - After `POOL_INFLIGHT_HOLD_GRACE_S`, a closed issue destroys the machine,
     removes its file and parks the row `failed`. Any other HOLD (comment,
     label, title, body, ABANDON) requeues the row with attempt, deaths and
     deferrals unchanged, so the spawn gate holds it until the HOLD lifts.
   - These never cancel: `label-absent`, an unreadable read, a clear verdict,
     lower-case "hold" in prose, and a verdict younger than the grace.

## Knobs (settings rows on the `fly-pool` lane)

| Knob | Default | 0 means |
|---|---|---|
| `POOL_STALL_ALERT_S` | 1800 | off |
| `POOL_INFLIGHT_HOLD_READS` | 4 | in-flight cancel off |
| `POOL_INFLIGHT_HOLD_GRACE_S` | 600 | cancel on the first held read |

A value that is not a number is named in `fly-pool.log` and the default is used.

## Operator step

If the hub's `fly.env` has neither `FLY_API_TOKEN_project-6_OS` nor
`FLY_API_TOKEN`, add one of them. Until then the new alert names the missing
token. With a token, the first tick reaps the orphan job files through the
existing dead path, and the freed slots spawn the queue.

## Not changed

The other per-project token readers (`bin/fly-dispatch.sh`,
`bin/pipeline-health.sh`, `bin/fly-machine-state.sh`, `bin/lib/box-ops-fly.sh`)
still read only `FLY_API_TOKEN_<P>`.

## Tests

`tests/fly-pool-stall-reclaim.bh-7107-test.sh`.
