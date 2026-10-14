# Deployment defaults and the deployment lint (BH-4080, #3979 wave 6)

Doc: config-inventory, OPERATOR-SETUP

## What changed

- Every value specific to our deployment that production code carried as a bare
  literal now has one documented default in one home:
  - shell: `bin/lib/deployment.sh`, registered in
    `catalog/lanes.d/_lib.deployment.json`, all `settable: false`:
    `HARNESS_REPO`, `HARNESS_GH_OWNER`, `HARNESS_OPERATOR_LOGIN`,
    `HARNESS_GIT_NAME`, `HARNESS_GIT_EMAIL`, `HARNESS_MERGE_GIT_NAME`,
    `HARNESS_BOT_GIT_NAME`, `HARNESS_BOT_GIT_EMAIL`,
    `HARNESS_WORKERS_SUBDOMAIN`, `HARNESS_BOX_PREFIX`, `HARNESS_HUB_BOX`.
    The defaults are today's values, so nothing moves on our boxes. Another
    operator sets them in `env/global.env`
    (`env-templates/lanes/377-deployment-defaults.env.example`).
  - console: `console-ui/src/lib/deployment.js` (`FLEET_LOGIN`,
    `PRODUCT_COCKPIT_URL`).
  - jobs worker: `worker/jobs/src/lib/deployment-defaults.js`
    (`ANCHOR_DEFAULT_ACCOUNT_MAP`, re-exported from `core.js`).
- Project repo slugs come from fleet.conf column 2 only. The literal slug
  tables in `bin/lander.sh`, `bin/deploy-train.sh`, `bin/merge-queue.sh`,
  `bin/check-migration-prs.sh`, `bin/unblocked-children.sh`,
  `bin/lib/dep-verify-lib.sh` and `bin/triage-gate.sh` are gone. A project with
  no row is refused with a log line; it never gets a guessed slug.
- `bin/vercel-deploy-snapshot.sh` pushes to the boxes `bin/box-for.sh` names for
  vercel.conf's projects instead of three hardcoded hostnames. Today that adds
  `box-project-1-1` (project-1's box in fleet.conf) to the three.
- `bin/fly-sync-harness.sh` reads its checkout from `HARNESS_CHECKOUT`. A
  `HARNESS_REPO` that is a path (`/…`) still counts there; a slug does not.
- Two copy changes: `bin/poll-commands.sh` answers `refused: not a whitelisted
  fleet PR`, and the console's PR page says `no GitHub repo configured`. The
  cost-parity alert lines drop the `(example-org/cromford#NNN)` reference.
- `bin/deployment-lint.sh` fails on a new deployment literal outside its home
  (families in `catalog/deployment-literals.tsv`, exceptions in
  `tests/no-hardcoded-deployment-allowlist.txt`). `bin/config-inventory.sh`
  writes `docs/config-inventory/deployment.{json,md}`, the checked-in report.
- Consumers source `"${HARNESS_DEPLOYMENT_FILE-<beside itself>/deployment.sh}"`.
  On a box the variable is unset; `tests/lib/scratch.sh` points it at the
  checkout's copy so scratch trees that copy one lib keep working.

## Why

#3979 (open-source rollout): another operator's install must not silently
push as our login, open issues on our repo or ssh to our boxes.

## Pinned by

`tests/no-hardcoded-deployment.bh-4080-test.sh`,
`worker/jobs/test/deployment-defaults.bh-4080.test.js`,
`console-ui/tests/deployment-defaults.bh-4080.test.js`.
