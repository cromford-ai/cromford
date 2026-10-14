# The size gate's limits are settings rows, 700 lines / 20 files by default (BH-4985)

Doc: RUN-BUILD-GRAPH

## What changed

- `bin/size-threshold.sh` resolves each axis, first hit wins:
  `size_gate.<axis>.<project>` row → `size_gate.<axis>` row →
  `flags/size-gate-<project>` → `catalog/size-thresholds.conf` → 700 / 20.
  Rows come from `state/settings-cache.json` through `bin/lib/lane-gate.sh`,
  the TTL cache every lane shares, so a build makes no request of its own.
  Junk or 0 in a row falls through like it does in the flag and catalog. No
  cache, a corrupt cache or `LANE_GATE_DISABLE=1` means no rows. New fields:
  `src` (`row|flag|catalog|default`, or `lines:<a>,files:<b>` when the axes
  differ) and `all` (`<lines> <files> <src>`).
- `worker/jobs/schema.sql` seeds `size_gate.lines=700` and `size_gate.files=20`
  with `INSERT OR IGNORE`, actor `seed`. harness-sync applies it before deploy.
  A re-apply never resets an edit made on /config. The actor is not
  `registry-seed`, because lane-gate files those rows under `.seeded`, which no
  lookup reads.
- The source goes on the record: `SIZE_LIMITS: … src=<src>` (via
  `SIZE_LIMITS_SRC`), the pipeline.log `SIZE:` line and the `size_gate`
  artifact's `limits.src`.
- Every fallback that restated 300/12 now says 700/20 (`plan.sh`, `pr.sh`,
  `size-gate.sh`, `run-decompose.sh`). The 15% tolerance is unchanged.

## Why

the operator, 2026-10-06, from measured split-vs-whole data: splitting below about
1,000 shipped lines cost more money and time than building whole. The thread's
follow-up asked for the number to be a database setting, not a constant.

## Operating it

- Fleet: edit `size_gate.lines` / `size_gate.files` on /config (audited).
- One project: `bin/jobs-client.sh setting-set size_gate.lines.<project> <n> "<note>"`.
- Check a box: `bin/size-threshold.sh <project> all`.
- Hotfix tier (2026-10-07): a `hotfix` ticket reads
  `size_gate.<axis>.hotfix.<project>` → `size_gate.<axis>.hotfix` (seeded
  1500 / 30) before everything above; src `row:hotfix`. Check it with
  `SIZE_TIER=hotfix bin/size-threshold.sh <project> all`. With no hotfix rows
  the ticket gets the normal chain.
- `catalog/size-thresholds.conf` and `flags/size-gate-<project>` now lose to
  the settings rows. On a box with a worker the seeded fleet rows always
  answer, so a catalog row or a box flag does nothing there. They only matter
  when the worker is down or the cache is missing. Tune with rows instead.

## Not done here

- `docs/config-inventory/` is not regenerated in this PR. The inventory suite
  passes (43 pass, 1 warn), and the warn is drift that was already on main
  (`distinct_variables` 1653 vs 2783) and has nothing to do with this change.
  Committing it would put unrelated churn in this diff.
