# The cromford default merge queue batches up to 6 PRs (BH-8047)

Doc: CI-RUNNERS, MERGIFY

## What changed

On 2026-10-22 the `default` queue moved from `batch_size: 4`,
`batch_max_wait_time: 3 min` to `batch_size: 6`, `batch_max_wait_time: 2 min`.
The values live in `config/mergify/repos/cromford.conf`.
`.mergify.yml` is edited to match, and `bin/mergify-template.sh --check`
proves the two agree. The hotfix, flake-fix and solo queues stay at 1 PR and
0 s. `queue_conditions` and `merge_conditions` did not change.

## Why

CI cost hotfix. The MonkCI invoice was $9,284 for 1,160,553 4-vCPU minutes.
The merge queue ran about 54 batches a day, most of them one PR, and each
batch paid a full impact run of 409 to 1,038 suites. 6 PRs per batch with a
2-min wait give about 12 batches a day.

The ticket asks for a 2-min wait, which is shorter than the 3-min wait it
replaces. A shorter wait can fill fewer batches when PRs arrive slowly.
Watch the first days of batch drafts for member count.

## Rollback

Set `batch_size=4` and `batch_max_wait_time=3 min` in
`config/mergify/repos/cromford.conf`, edit `.mergify.yml` to match, and
run `bin/mergify-template.sh --check`. `1` / `0 s` turns batching off.

Tests: `tests/mergify-template.bh-8047-test.sh`.
