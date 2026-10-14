# project-5's Mergify queue: 6 in flight, batches of 4, one retry (BH-3439)

Doc: MERGIFY

## What changed

`config/mergify/repos/project-5.conf` set only `slug` and `check`, so project-5
ran the template defaults: `max_parallel_checks: 3`, `batch_size: 4`,
`max_checks_retries: 0`. Its committed `.mergify.yml` carries
`max_checks_retries: 1` (per the ticket; this build's token could not read
example-org/project-5), so the next sync would have quietly dropped the retry.

The conf now sets `max_parallel_checks=6`, `batch_size=4` and
`max_checks_retries=1`, and its comment gives the reasoning. project-5's CI is
one job (`Build + Unit tests`, about 10-20 min on a MonkCI 4 vCPU VM). A red
head batch throws away at most 5 stacked batches (~50-100 runner-min) plus one
retry run. The retry matches what the repo already runs. The hotfix queue stays
batch 1 / 0 retries, as the template fixes it.

The in-repo copies follow the render: `tests/fixtures/mergify/project-5.mergify.yml`
and the `docs/MERGIFY.md` §2 block (both pinned by
`tests/mergify-template.bh-1673-test.sh` A8).

## The drift check

The drift check is `bin/mergify-sync.sh check` (BH-1699), run daily at 06:47Z
by the `mergify-sync` hub lane. It reads each conf'd repo's committed
`.mergify.yml` from its default branch, compares it with
`bin/mergify-template.sh compare`, and prints `DRIFT` (rc 1, one ALERTS line
per repo per day naming the fix) when they differ. `override=` in the conf,
or the `# harness-mergify: override` marker in the file, exempts the repo.
`tests/mergify-drift-project-5.bh-3439-test.sh` pins it on this case with the
real comparator: today's conf vs today's file is DRIFT, the new conf vs its own
render is IN_SYNC, and `override=` is OVERRIDE.

## After merge (operator step)

This change does not touch example-org/project-5. Once it has propagated to the
hub, run:

    /root/harness/bin/mergify-sync.sh apply example-org/project-5

It opens a PR on `harness/mergify-sync-<sha8>` in example-org/project-5 that sets
the rendered file, and it never merges. Until that PR merges, the daily check
reports project-5 as DRIFT, and its ALERTS line names the same command. After
it merges, `bin/mergify-sync.sh check example-org/project-5` prints `IN_SYNC`.
