# BH-6746: main CI after a direct merge, and the deploy train ships green shas only

Wave 3 of 5 of #6541. Wave 2 (BH-6745) lets the merge conductor merge a PR
directly in `landing.mode=optimistic`. That merge never ran in a merge-queue
batch, so its tree was untested. This change does three things.

## 1. The `landing-path` commit status (the conductor)

When `mc_settle_merged` (bin/lib/mc/settle.sh) writes the ledger merge detail
`merge-conductor path=direct`, it also posts the commit status
`landing-path=success`, description `path=direct`, on the merge sha.
The writer is `landing_path_publish` (bin/lib/mc/landing.sh), through
`vs_publish` with `LEAD_VERDICT_CONTEXT=landing-path`.

- The ledger row and the status come from one predicate (`landing_direct_path`).
- A failed post writes one conductor log line `<key> LANDING_PATH_OWED <why>`.
  It is not retried. CI then runs the full corpus on that push.
- Why a status: a CI runner cannot read the jobs ledger (no `HARNESS_SECRET`
  on a runner).

## 2. The `push-direct` CI class and the `main-ci` status (Harness CI)

`bin/ci-plan.sh` gives a push to main one of three classes. The plan job
outputs it as `push_class`.

| Class | When | What runs |
|---|---|---|
| `queue-tested` | pushed by `mergify[bot]` and the tree is a green batch head | no corpus (unchanged) |
| `push-direct` | `CI_PLAN_LANDING=1`, not `mergify[bot]`, and the newest `landing-path` status is `success` / `path=direct` | `test-impact.sh select --changed` over `HEAD^1..HEAD`, plus `test-impact.sh always` |
| `full` | anything else | the full corpus (unchanged) |

- The plan polls for the status for `CI_PLAN_DIRECT_WAIT_S` seconds (repo
  variable, default 120), every `CI_PLAN_DIRECT_POLL_S` (default 10).
- A push-direct plan escalates to `full`, with the reason, on: a path that
  `catalog/ci-batch-escalate.tsv` names, test-impact's own `full:` answer, an
  empty or unreadable diff, or a selection of every suite.
- Each shard passes `CI_PLAN_PUSH_CLASS` and reads no status.
- The plan job has `statuses: read` for the status read.

The new job `main-ci status` runs on every push to main. It posts the commit
status `main-ci` on the pushed sha: `failure` when a needed job failed or was
cancelled, else `success`. A failed post is a red job.

## 3. The deploy train gate

With the deploy-train knob `DEPLOY_MAIN_CI_GATE=1`, `bin/deploy-train.sh`
departs only on an origin/main HEAD whose `main-ci` status is `success`
(bin/lib/deploy-main-ci.sh). The check runs after the flock and before any
claim.

| main-ci on HEAD | Log line | Result |
|---|---|---|
| success | `MAIN_CI_GREEN <sha8>` | departs; TARGET is pinned to that sha |
| failure | `MAIN_CI_RED <sha8>` | no departure; the next green head departs |
| none, pending or unreadable, under the bound | `MAIN_CI_WAIT <sha8> (<m>m of <bound>m, …)` | no departure |
| same, at or past the bound | `MAIN_CI_UNKNOWN <sha8> after <m>m` | no departure; one ALERTS line per sha |

- The bound is `DEPLOY_MAIN_CI_WAIT_MIN` (default 45 minutes), counted from
  the first tick that saw the sha.
- A queued sha that is not an ancestor of the gated sha stays queued (it is
  not claimed and its file is not removed).
- One REST statuses read per gated tick. A success is cached per sha in
  `state/deploy-main-ci/<project>/<sha>`. Files there older than 7 days are
  deleted on each gated tick.
- `bin/deploy-request.sh` does not change: it only enqueues.

### Turn the gate on for a project

1. Make sure that project's CI posts a `main-ci` commit status on every push
   to main. Today only cromford's Harness CI does.
2. Run `bin/harness-ctl.sh set deploy-train DEPLOY_MAIN_CI_GATE 1 <project>`.
3. Read `logs/deploy-train.log` on the next tick for a `MAIN_CI_*` line.

With the gate on and no `main-ci` status, the train never departs and logs
`MAIN_CI_UNKNOWN` at the bound. That is why the default is 0 (off).

## Assumptions

- "The ledger marks path=direct" is read by CI through the `landing-path`
  commit status, which the conductor posts from the same predicate.
- "Fast-only" for a batch push is today's `queue-tested` answer.
- "Whole-repo set" is the always set plus the learned `*` rows that
  `test-impact.sh select` already returns.
- A direct merge that changes an escalating path runs the full corpus.
- `deploy.main_ci_wait_min` is the deploy-train lane knob
  `DEPLOY_MAIN_CI_WAIT_MIN` (a settings row through `lane_env_apply`).
- The gate is per-project opt-in, default off.
- The departure sha stays origin/main HEAD. The train does not walk back to
  an older green sha.
- cromford itself ships through `bin/fleet-propagate.sh`, which this
  change does not gate.

## Not verified here

- A live push-to-main run that posts `main-ci` (it needs this change on main).
- A live direct merge that posts `landing-path` (it needs
  `landing.mode=optimistic`).
- `actionlint` (not installed on this box).
