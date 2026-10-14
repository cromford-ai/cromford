# The backstop starts one run per PR; READY past TTL is re-kicked; any failed diff read is scanned from git (BH-6000 parts 2-4)

Doc: MERGE-CONDUCTOR

## What happened (2026-10-11)

- #4546, #5704, #5727, #5990 and #5999 logged `WINDOW_DEFERRED` on every backstop fire. The */5 backstop gave at
  most 6 keys (`MC_BACKSTOP_MAX_KEYS`) to ONE keyed conductor run with one shared worker window
  (`MC_WORKERS_DONE_BY`). Keys that did not fit were carried to later fires.
- #5982 sat in READY past its TTL with "no deterministic re-kick for this state" on every tick.
- #5993 logged "the diff read was UNVERIFIABLE so the iron-law scan NOT run" on every tick. Only a 406 fell back to
  the local git diff (BH-5914).

## What changed

1. **One run per candidate** (`bin/merge-conductor-backstop.sh`). Each fire starts one detached
   `MC_ONLY_PR=<key> merge-conductor.sh` per candidate. Each run has its own `timeout MC_BACKSTOP_TIMEOUT_S` and its
   own flock (`locks/mc-backstop-<key>.lock`). There is no cap, no shared window and no carry file. A key whose run
   from an earlier fire still holds its lock is left alone (one log line) and is offered again on the next fire, so
   no key is started twice or dropped. `MC_BACKSTOP_MAX_KEYS` is deprecated: it has no effect, and the log names it
   when it is set.
2. **READY past its TTL** (`mc_ready_rekick` in `bin/lib/mc/classify.sh`). When the conductor has recorded no hold
   for the head (`mc_ready_why_last`), the conductor starts one keyed run for the PR now (`kw_conductor`), once per
   (PR, head). A head the conductor holds on purpose (main-red, dependency, unread diff, base guard, budget) is left
   alone, as BH-4596's review asked. The STUCK page stays the one alert.
3. **Any failed diff read** (`mc_pr_diff_or_local`): a 403, 429, 5xx or no answer falls back to the local
   `git diff`, like a 406. The log names the HTTP status.

## Operating

- Backstop log: `N candidate(s): M detached keyed conductor run(s) started, one per PR`, and
  `<key>: its run from an earlier fire still holds ... left alone this fire`.
- Measured on the hub at 2026-10-11 ~12:45Z (read-only): 29 candidates. A 6-key backstop run used up to 10
  processes (226 MB summed RSS). A single-key run used 1-4 processes (10-101 MB summed RSS). One conductor bash
  process is about 1.8 MB PSS. The hub has 8 CPUs and 13.4 GB available. One run per candidate is roughly 29 x 4
  processes per fire, all short-lived.
