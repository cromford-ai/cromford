# Workflow checkouts keep no credential (BH-6522)

Doc: CI-RUNNERS

## The gap

`actions/checkout@v4` writes the job token into `.git/config` as
`http.https://github.com/.extraheader` unless the step says
`persist-credentials: false`. All 16 checkout steps in `.github/workflows/`
kept it. Every later step of the job could read the token, including the steps
that run PR code.

## What changed

- Every `actions/checkout` step in `harness-ci.yml` (10), `harness-nightly.yml`
  (4), `prequeue-gate.yml` (1) and `publish-cromford.yml` (1) has
  `persist-credentials: false` under `with:`. No job pushes with the checkout
  token. `publish-cromford` pushes over SSH with `CROMFORD_DEPLOY_KEY`.
- Two fetches still need the token. Each step gets it as env
  (`PQ_GIT_TOKEN` in the prequeue `verdict` step, `SCHEMA_GIT_TOKEN` in
  `schema.sql applies over main's`). At the top of `run:` the step masks the
  base64 header, keeps it in a shell variable that is not exported, and unsets
  the env var. `pq_fetch` / `schema_fetch` give the header to that ONE
  `git fetch` through `GIT_CONFIG_COUNT/KEY_0/VALUE_0`. It is never in argv and
  never in `.git/config`. With no token they run a plain `git fetch`, so the
  suites that run the step text against a local bare origin still pass.
- The plan step sets `CI_PLAN_MAIN_HEAD_CMD` to
  `gh api repos/<repo>/git/ref/heads/main --jq .object.sha`. `bin/ci-plan.sh`
  `queue_tested` reads main's head through `gh` and the step's `GH_TOKEN`, not
  `git ls-remote origin`. If that read fails, the push runs the full corpus.
- The `lint` job runs `SQL identifier marker lint (BH-6514)`
  (`bin/sql-ident-lint.sh`) on every PR, directly after the model-id lint.

## The rule for a new workflow step

A new `actions/checkout` step must carry `persist-credentials: false`.
`tests/workflow-checkout-creds.bh-6514-test.sh` case W1 is red otherwise. If a
step truly needs the persisted token, put `persist-credentials: true` on that
one step and the line `# needs the checkout token: <the fetch>` directly above
its `- uses:`. W1 counts it as an exception and prints the count. A new git
network read in a step uses the `pq_fetch` shape above instead.
