# BH-7695: a box that cannot run the repo suite records `could-not-run: <item>`

Doc: RUN-BUILD-GRAPH

## Why
On 2026-10-20 a build box reviewed project-6 #2084 with no `node_modules` and no `DATABASE_URL`. The suite exit was 127. The lens prompt reads a nonzero exit as a BLOCK, so the review blocked on the box. The same suites passed on a set-up machine (unit 276/276, e2e 3/3).

PR #7780 was the first fix. It failed the lead request on a miss, so a lead review on an npm repo never finished. PR #8960 fixed that and was closed for the knob-key red below. The r3 and r4 builds opened no PR. This r5 build carries r4's code onto main 211f83d3. It does not fail the lead request.

## What is checked (`bin/lib/suite-preflight.sh`)
- `node_modules` (HARD): the repo declares npm dependencies, the suite command is a node command (or the npm arm's own `npm run`) that does not install its own packages, and `node_modules` is absent or empty with no `.pnp.cjs`. The suite is not run.
- `DATABASE_URL` (SOFT): a prisma repo, no URL in the env, in `.env`, `.env.test`, `.env.local` or from the throwaway Postgres, AND the red suite output has a DB signature (`P1001`, `P1012`, `Environment variable not found: DATABASE_URL`, `Can't reach database server`, `PrismaClientInitializationError`). An assertion red stays red. A green stays green.
- Each name in `SUITE_PREFLIGHT_ENV` (SOFT) that is empty, on a red suite.

## The two paths
- Build (`HARNESS_SUITE_RUN`, npm arm, `bin/lib/rb/gates.sh`): a HARD miss gets one setup attempt (`npm ci`, or `npm install --no-package-lock` with no lockfile) and one re-check. Still missing: no prelude, no suite, `HARNESS_PREFLIGHT: could-not-run: node_modules …` and `HARNESS_EXIT: could-not-run: node_modules`, and one infra alert per project per box per UTC day (`bin/alert-line.sh --id suite-preflight-<project>-<host>`). A SOFT miss on a red suite: `HARNESS_EXIT: could-not-run: <items> (suite rc <n>)`. The harness Postgres (one cluster, or one per file on the BH-8499 serial path) counts as a provided DB. The BH-8175, BH-8499 and BH-9285 (CI locale) `could-not-run` exits keep their exact value: the post hook reads only an integer rc.
- Lead review (`bin/lead-review.sh` host suite, lib loaded by `libs.d/202611131555-bh-7695-suite-preflight.sh`, logic in `sp_lead_suite` so the hotspot keeps one call and its old two lines as the no-lib fallback): a HARD miss does not run the suite. The report says `- host suite: could-not-run: node_modules (not run; …): <cmd>`, and the prompt's Host suite section says `[NOTE] not verified here, never a BLOCK`. The model still reviews and the request finishes with a verdict. No install, no fail, no alert: a fresh lead worktree never has `node_modules`, and no box setup can change that. A SOFT miss on a red suite: `- host suite: could-not-run: <items> (suite rc <n>): <cmd>`.

## Status words
- `HARNESS_EXIT: could-not-run: <items>[ (suite rc <n>)]`: the box could not run the suite. Not green and not red. `LIVE_SUITE` reads it as `tests_green not-run` and names the item. `bin/lib/evidence.sh` does not use the file as a test source. The CI run on the PR head is the suite verdict.
- `HARNESS_PREFLIGHT: setup <cmd> (rc=<n>)`: the one setup attempt and its real rc.

## Knobs (fly-pool, per project)
- `SUITE_PREFLIGHT_INSTALL` (default 1): 0 turns off the build-path setup attempt.
- `SUITE_PREFLIGHT_SETUP_S` (default 900, 60..3600 s): the bound on that attempt. PR #8960 named it `SUITE_PREFLIGHT_INSTALL_TIMEOUT_S`. Its per-project key `lane.fly-pool.<project>.suite_preflight_install_timeout_s` is 67 chars at the longest project, over the 64-char limit of the settings route (`worker/jobs/src/routes/settings.js`), and `tests/lanes-registry-test.sh` went red on main. The shorter name keeps every key at 57 chars or less.
- `SUITE_PREFLIGHT_ENV` (default empty): extra env names the suite needs.

## With BH-9434 (open PR #9521)
Its reader `pv_suite_class` maps any `HARNESS_EXIT` value with a non-digit to could-not-run, so `could-not-run: node_modules` is a could-not-run there too. If it merges, its retry on a clean state and its BUILD_DEFERRED also apply to this exit.

## The lead report replay (BH-8945)
The artifact replay and the disk replay read the report's `- host suite: …` line with `^- (host suite: .*)$`. The new value matches and is copied verbatim.

## Operator action on the alert
`[suite-preflight] <project>/<key> on <box>: could-not-run: node_modules after one setup attempt …` means this box cannot install the repo's packages (registry access, disk, a private package). Fix the box or route the project to a box that can. The PR is not at fault.

Tests: `tests/suite-preflight.bh-7695-test.sh`, `tests/lead-review-preflight.bh-7695-test.sh`.
