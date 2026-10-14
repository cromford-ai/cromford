# A member's `full` label escalates a batch, and the SPA and worker jobs skip batches that cannot touch them (BH-4969, C1 of BH-4964)

Doc: MERGIFY, COST

## What changed

- `bin/ci-plan.sh`, the `mergify/merge-queue/*` case. Mergify doesn't copy a
  member PR's labels onto the batch draft, so after C0 a PR labelled `full`
  was batch-selected with the rest of its batch. `member_full` now reads every
  distinct `#<n>` in the draft's title and body (`CI_PR_BODY`) through
  `gh api repos/$CI_REPO/pulls/<n>` with the job's own token:
  - a `full` label on any of them -> `the 'full' label on #<n>`
  - no repo, no gh, no `#<n>`, more than 40 refs, a failed read, or a reply
    without a labels array -> `member labels unreadable (<which>)`. A failed
    read is never "no label".
  - That covers the "queued ahead" and "bisected from" refs as well. Their
    commits are in the tree being tested, and reading one costs a GET.
- Shards don't read GitHub. The shard's re-plan gets the plan job's
  `escalation` as `CI_PLAN_ESCALATION`. A reason forces the corpus with no gh
  call. `-` skips only the member read, and every other check is recomputed
  from the same inputs, so `--expect-n` keeps agreeing.
- New outputs `spa` and `worker`. They are 1 on every path except a batch that
  stays `batch-selected` with no changed path that `cbe_affects` the job. A
  path is affected when it's under `console-ui/` (spa) or `worker/` (worker),
  which is built in, or when a `spa`/`worker` row in
  `catalog/ci-batch-escalate.tsv` matches. The rows cover `catalog/lanes.d/`,
  `catalog/lanes.json` and `worker/jobs/schema.sql` for both jobs, plus
  `bin/lib/jobs/` for worker. They also cover every path the two trees read
  from outside themselves:
  - spa: `worker/jobs/src/lib/config-changes.js` and `worker/watchdog/src/`,
    which console-ui tests import
  - worker: `bin/lanes-build.sh` and `bin/worker-schema-upgrade.sh` (the
    job's own steps), `bin/lib/d1-schema.sh`, `bin/lib/hub-probes/`,
    `bin/lib/mc/log.sh`, `bin/agent-call.sh`, `tests/fixtures/daily-digest/`,
    `fleet.conf` and four `catalog/*.json` files
  The ones that also escalate still get a row, so removing an escalate row
  can't switch a job off. `tests/ci-plan-spa-worker.bh-4969-test.sh` (X1-X3)
  scans both trees for quoted `../` paths, and the two jobs' workflow steps for
  `bin/` scripts. It fails on any target that has no row, so a new cross-tree
  import can't quietly reopen the gap. An unreadable rules file, or a changed
  path list that can't be read, answers "affected".
  The step summary gains a `spa: <0|1> worker: <0|1>` line.
- `.github/workflows/harness-ci.yml`:
  - the plan job gets `pull-requests: read`, `CI_PR_BODY` (env only) and the
    `spa`/`worker` outputs
  - the shard re-plan gets `CI_PLAN_ESCALATION`
  - `console-ui` and `worker-jobs` keep their job-level `corpus == '1'` gate,
    start with a `not affected by this batch` step on `== '0'`, and run every
    real step on `!= '0'`, so a missing output runs the job
  - both jobs still conclude success under the same names, and `.mergify.yml`
    is unchanged
- The two existing batch suites now pass `CI_PLAN_ESCALATION=-`, because a
  batch with no member list escalates as unreadable. bh-4968 case 11's exact
  output-key list gains `spa worker`.

## Not observed yet

Nothing has been seen on a real merge-queue run yet. After merge, a
console-ui-only batch should show `mode=batch-selected` in the plan notice,
"Jobs worker — routes + schema" green with only its skip step run, and the SPA
job running its real steps.
