# The pool caches each issue's HOLD verdict, so a held ticket costs no thread read (BH-6549)

Doc: FLY-POOL-RESPAWN-CAP, GH-REST

## What happened

On 2026-10-13 the project-6-os pool cycle took about 30 min. The HOLD gate
(`bin/fly-pool.sh` `pool_spawn_decision`, step 1) read the issue and its whole
comment thread for every queued row on every tick. One read cost 30-45 s on
the loaded hub. About 19 held tickets cost about 12 min per cycle. New tickets
waited about 1 h from enqueue to spawn.

## Cause

`pool_hold_check` keeps its verdict in `_POOL_HOLD_CACHE`, a per-process array.
It runs inside `$( )`, so no verdict reaches the next row or the next tick.

## What changed

- New pure lib `bin/lib/pool-hold-cache.sh`: `phc_listing_keys`, `phc_get`,
  `phc_put`. No network, no knobs, no clock.
- `bin/fly-pool.sh` reads the open `ai-build` issue listing once per tick
  (`repos/<slug>/issues?state=open&labels=ai-build&per_page=100&page=N`, at most
  `POOL_HOLD_LIST_MAX_PAGES` pages). It reads the listing only when a GitHub
  issue row reaches the HOLD gate. The key of each issue is
  `<updated_at>|<comments>`.
- Step 1 asks the cache first. A hit takes the same held arm as a fresh read:
  the `skipping <KEY>: HOLD (…)` line, the `.held` marker, `psr_hold_put` and the
  once-comment. A miss reads the thread as before, then stores the verdict.
- The cache file is `state/pool/<p>/hold-cache/<n>.json`, format v1:
  `{"v":1,"n":"<n>","key":"<updated_at>|<comments>","lib":"<cksum of hold.sh>","verdict":"held\t…","at":<epoch>}`.
- Two lane knobs (fragments in `catalog/lanes.d/fly-pool.knobs.d/`):
  `POOL_HOLD_CACHE_TTL_S` (default 21600, 0 = off) and
  `POOL_HOLD_LIST_MAX_PAGES` (default 10).

## The fail-safe rule

The cache keeps only `held` verdicts. It can keep a row held. It never
releases one: a clear is always read from GitHub in the same tick. `held
closed` and `held label-absent` are not kept, because the pool parks those rows.
These cases are all a full read, which is the old path:

- no file, or a file that does not parse or has the wrong shape (counted `bad`);
- the listing key changed (a new comment, a label change, a title or body edit,
  a close);
- `bin/lib/hold.sh` changed (its checksum is in the entry);
- the entry is `POOL_HOLD_CACHE_TTL_S` old or more, or stamped in the future;
- the issue is not in the listing (closed, de-labelled, or past the page cap);
- the listing did not answer 200: every row of that tick misses.

If the full read is also unreadable, the existing `unreadable` arm skips the row
and keeps its `.held` marker, as before.

## The blind case

GitHub does not document that a comment EDIT changes the issue's `updated_at`.
An edit that turns a HOLD into a RESUME can be missed by the key. The TTL bounds
it to 6 h. A new `RESUME` comment changes the comment count, so the next tick
sees it.

## The summary line

One line per tick in `logs/fly-pool.log`, only when a GitHub issue row reached
the HOLD gate:

    [pool/<p>] hold cache: hits=<h> misses=<m> bad=<b> listing=<ok|truncated|unreadable(<code>)|off> read_s=<s> ttl_s=<ttl>

`read_s` is the wall time the full reads of that tick took.

## Rollback

Set `POOL_HOLD_CACHE_TTL_S=0` on the `fly-pool` lane. The pool then makes no
listing read and reads every thread, as before. The summary line says
`listing=off`.

## How to measure acceptance 4 (after deploy, on the hub)

1. Run `grep 'hold cache:' /root/harness/logs/fly-pool.log | tail`. `hits` must
   be near the held-row count and `listing` must be `ok`.
2. Compare the gaps between consecutive `[pool/project-6-os] skipping TK-*: HOLD`
   lines, and the spacing of the pool summary lines, for 3 cycles before the
   deploy and 3 cycles after it.
3. Compare the enqueue time of a new MK ticket with its `spawned` line.
4. The target is a cycle under 15 min. If the cycle is still longer, name the
   remaining per-row cost from those gaps in a follow-up ticket.

The test is `tests/pool-hold-cache.bh-6549-test.sh`.
