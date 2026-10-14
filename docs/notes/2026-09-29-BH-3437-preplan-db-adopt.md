# Pool builds fetch their own pre-plan, every box publishes one, and the hit rate is watched (BH-3437)

Doc: RUN-BUILD-GRAPH, DB-COORDINATION-SPEC

## The trace

BH-3437's own pool build missed its own pre-plan. All times are 2026-09-29 Z:

| when | what |
|---|---|
| 16:56:20 | issue created |
| 17:06:07 | queue row enqueued |
| 17:07:53 | the hub's `bin/fly-pool.sh` pushed `job.json` to the machine. `push_preplan` ran right after, found no `preplans` row, and relayed nothing |
| 17:08:14 | the watcher's `bin/run-preplan.sh` published the pre-plan (`base_sha dbac2f52`) |
| 17:08:40 | the builder's adopt block logged `PREPLAN_MISS no pre-plan for BH-3437 (relay dir empty, hub plans/ empty)` |

Seven days of `GET /api/preplans/adoption` before this change: cromford
0 adopted / 76 miss while 328 cromford rows sat in `preplans`; project-5
0 / 42. `preplan_index` held no rows at all for project-5, project-1 or
project-3.

## What changed

Two defects, two fixes, and one new signal.

- **The builder asks the DB itself.** The only reader of a `preplans` row was
  `push_preplan` on the hub, once, at dispatch. The adopt block in
  `bin/lib/rb/plan.sh` now looks in the relay dir, then `plans/`, then calls
  `preplan_fetch` into `$BUILD/preplan-db/`. A row found there goes through
  the same thread-fingerprint and `preplan_check` staleness checks as a relayed
  one. The MISS line names the hop that answered:
  `coordination DB has no row` (fetch rc 1), `coordination DB unreachable`
  (rc 2), or `coordination DB not asked` (no jobs client on the machine). The
  relay is unchanged and still wins when it has the plan.
- **Every box publishes.** `bin/run-preplan.sh` gated the publish on
  `preplan_publish_wanted`, which was evaluated before `jobs-client.sh` was
  sourced and so fell back to `flags/builder-fly-<p>`, a hub-side routing file
  watcher boxes do not carry. The gate and the function are gone. Every box
  with a jobs client publishes. A local-built project's row is read by nothing
  and ages out with the existing 14-day retention.
- **Hit rate.** `GET /api/preplans/adoption` adds `builds`
  (adopted + stale + miss) and `hit_rate` (adopted / builds, null with no
  builds) to each project and day row. `rate` and `bought` are unchanged.
  `bin/pipeline-health.sh` writes one `pre-plan hit rate <W>d:` line per tick
  to `logs/pipeline-health.log`. It fires a warn digest keyed
  `preplanzero:<p>` (retractable) when a project has at least
  `PREPLAN_HIT_ZERO_MIN_BUILDS` builds (default 10, 0 = off) in
  `PREPLAN_HIT_WINDOW_DAYS` (default 7) and adopted none. When the adoption
  read fails, the block writes nothing and keeps active `preplanzero` keys live
  rather than retracting them. The console PREPLAN ADOPTION panel shows
  HIT RATE, BUILDS and a `0% HIT` tag.

## Still open

A pre-plan published after the builder's adopt point still misses. Nothing
waits for one. The MISS detail now says so (`coordination DB has no row`), so
the size of that window can be measured.
