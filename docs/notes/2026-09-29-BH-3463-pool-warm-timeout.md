# Pool bakes: warm-build timeout, capture, catalog skip, capped retry (BH-3463)

Doc: FLY-BUILDER-TRIAL

A project-4 / project-1 `next build` hung inside the warm stage (`[warm 5/5]`),
which had no timeout of its own. Every bake of those pools ran into
`bin/fleet-propagate.sh`'s 1800 s outer timeout with no image pushed, and a
catalog-only merge rebaked all ten pools on the way.

## What changed

- `fly/warm-build.sh` (new) is the warm build step. It runs the build under
  `timeout -k 30 WARM_BUILD_TIMEOUT_S`, prints `warm-build: TIMED OUT after
  <n>s` on a timeout, and always exits 0, so the image ships cold rather than
  not at all. `fly/Dockerfile`'s warm stage copies it in and declares
  `ARG WARM_BUILD_TIMEOUT_S=600`.
- `bin/fly-image-build.sh` passes `--build-arg WARM_BUILD_TIMEOUT_S` on a warm
  bake: the `pool.warm_build_timeout_s` settings row, then env, then 600.
- `bin/fleet-propagate.sh`:
  - a diff whose fleet paths are all under `catalog/` bakes no pool (hub and
    boxes still sync);
  - `pools.<p>.warm` (`cold` / `warm` / empty) and `pools.<p>.capture` in the
    record; a warm timeout or an outer rc 124 writes
    `logs/fly-image-build/<p>-<sha7>.log` (step timings + last 200 lines,
    pruned at 14 days);
  - a clean run with a warm timeout alerts `--severity warn` naming the capture;
  - a failed bake keeps its dirty marker and is retried on the next due tick,
    at most `POOL_BAKE_RETRY_MAX` (default 2, `0` = off) times per pool per UTC
    day, counted in `state/fly/<p>.bake-retries`.

Operator reference: `docs/verification-map/pool-warm-timeout.md`.
