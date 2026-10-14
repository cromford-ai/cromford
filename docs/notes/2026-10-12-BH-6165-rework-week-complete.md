# Rework rollup: completeness is per repo and week (BH-6165)

Doc: DORA

## Cause

The rework rollup (`logs/outcome-rework-rollup.csv`) had no `cromford`
rows. The ticket named fleet.conf membership and `bin/outcome-metrics.sh:326`.
Neither is the cause. `fleet.conf` maps `cromford` to
`example-org/cromford`, and line 326 does not feed the rollup.

`rework_scan` (`bin/lib/outcome-rework.sh`) writes the rollup. It rolled up a
repo only when every PR in its scan had its product files read. One unread PR
put the whole repo out of the rollup for that run.

- example-org/cromford merged 2003 PRs between 2026-08-13 and 2026-10-12.
- The backfill scan is 60 days.
- One run reads at most `min(REWORK_FETCH_CAP, core.remaining - REWORK_GH_RESERVE)`
  file lists, that is at most 1500.

So one run never read every cromford PR, and the repo never got a row.
The live rollup had rows for the first 7 fleet.conf projects only.

## The rule now

Completeness is per repo and week. A closed ISO week of a repo rolls up when
both conditions are true:

1. The repo's pulls listing succeeded this run.
2. No PR of the repo merged in `[Monday 00:00Z, Monday + 7d + REWORK_WINDOW_DAYS]`
   is unread. Both ends are inclusive.

Such a week has its full denominator, and every PR that could rework one of its
PRs was read. Its row is final, so the append-once rollup can write it. A
project rolls up a week only when the week is complete for every listed repo of
that project.

The same rule gates reworked findings: a PR A becomes a finding only when its
week is complete. Every read PR is still a candidate B.

A week that holds an unread PR writes nothing. The next run reads more PRs off
the cache and retries it. `REWORK_COMPLETE`, the backfill marker, the
"product-file reads incomplete" log line and the fetch budget keep their
meaning: they still describe the whole repo.

## Scratch files

`rework_scan` writes two scratch files under `$WORK/rework/` and reads them in
the same call:

- `listed.tsv`: `slug<TAB>project`, one line per repo whose listing succeeded.
- `missing.tsv`: `slug<TAB>merged_at`, one line per PR whose file list was not
  read (fetch budget out or a failed read).

## Tests

`tests/outcome-rework-partial.bh-6165-test.sh` drives a capped run through
`bin/outcome-metrics.sh` and pins the week boundary. R13 in
`tests/outcome-rework-test.sh` now asserts that only the week of the unread PR
waits.
