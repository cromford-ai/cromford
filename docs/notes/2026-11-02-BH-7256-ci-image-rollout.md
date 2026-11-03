# CI images slice 4: the project-layer kit and the per-repo child filer (BH-7256)

Doc: CI-IMAGES

This is the r4 build. It ports r3 (5e7e0e1d6, which is the r2 commit
6812bd8ee plus a note) onto main 4ded20624. It changes one thing: how slices
2 and 3 stay out of the rollout.

## Why r4 replaced the name list

r3 left cromford and project-6-os out by name, in two lists in
`bin/ci-image-rollout.sh`. Those lines named three fleet projects, so
`tests/fleet-projects-not-hardcoded-test.sh` refused the file. r3's fix round
added an allowlist line, and the guard-silenced gate refused that. A list of
names also goes stale: each repo a child moves onto the image would need a new
entry.

r4 removes the list. The script reads the fact from each repo: a workflow file
named exactly `ci-image.yml` or `ci-image.yaml`, or a `ci/ci-image.conf` file,
gives the verdict `on-image`, and that repo gets no child. On 2026-11-02
example-org/cromford and example-org/project-6 both hold
`.github/workflows/ci-image.yml`. A repo whose child PR merged holds
`ci/ci-image.conf`. `tests/fleet-projects-allowlist.txt` does not change.
`targets` now lists 15 projects; `plan` shows the two slices as `on-image`.

## What changed

- `ci-images/project-layer/` (new): the kit a fleet repo copies into `ci/`.
  `Dockerfile` (`FROM ${CI_BASE}`, `ARG CI_BASE=ghcr.io/example-org/ci-base:ad930bd49a76`,
  `npm ci` into `/opt/ci/node/app` with a `.lock-sha256` stamp),
  `ci-image.sh` (the `bin/ci-image.sh` contract, with the image name and the
  inputs read from `ci/ci-image.conf`), `ci-image.conf` (the example conf),
  `ci-image-job.yml` (the `ci-image` job and one test job in `container:` with
  host-only install steps), `child-ticket.md` (the child body template).
- `bin/ci-image-rollout.sh` (new): `targets`, `body <project>`, `plan`,
  `file [--apply]`. It files one child ticket per fleet repo that runs CI and
  is not on the image yet, on that project's own board. Dry run by default.
- `catalog/lanes.d/_lib.ci-image-rollout.json` (new): two knobs, read through
  `lib_env_apply ci-image-rollout`. Settings rows
  `lib.ci-image-rollout.ci_rollout_curl_max_time` (fallback 25 s, 5..120) and
  `lib.ci-image-rollout.ci_rollout_search_per_page` (fallback 100, 1..100).
- `docs/CI-IMAGES.md`: the "Rollout (slice 4)" section, the sandbox rule, the
  re-run wait, the knobs, the `on-image` rule, the MonkCI caveat and the
  acceptance table (15 rows: 2 `on-image`, 13 `pending`).
- `tests/ci-image-rollout.bh-7256-test.sh` (new): 139 checks, offline.

## What changed versus the closed PR #7356

#7356 closed unmerged on 2026-10-26 on `[BLOCK hardcoded-knob]`. the operator's scope
update (2026-10-30) asked for three changes. This rebuild ports #7356 and adds:

1. `curl --max-time 25` and `per_page=100` are knobs (above). The literals stay
   only as the documented fallbacks. A non-integer value falls back; a value
   out of range is clamped.
2. Sandbox repos leave the target list (rule below).
3. The doc says to wait before an `--apply` re-run. The script prints one
   stderr line after an `--apply` that filed on a GitHub board.
4. The child body and the job header carry a MonkCI caveat that points at
   example-org/project-6's host-run pattern.

## Why

The ticket asks for one PR per fleet repo, each from its own child ticket. A
cromford build edits only cromford, and a child on the
cromford board builds in cromford. So the child goes on each
project's own board, where its own lane builds it.

## Decisions and assumptions

- Targets are `bin/fleet-conf.sh --projects` minus every sandbox repo. On
  2026-11-02 that is 15 projects. cromford (slice 3) and project-6-os
  (example-org/project-6, slice 2) are targets, and `plan` decides them
  `on-image`.
- Sandbox rule: fleet.conf has no sandbox column. A sandbox is a project name
  with the dash token `sbx` or a repo name that holds `sandbox` (any case).
  Today that removes `cromford-sbx-linear` and `cromford-sbx-jira`. A rule
  matches a future sandbox row with no edit; a knob-held list would not.
- `project-6` (example-org/project-6-runtime) is a target. It is a different
  repo from slice 2's example-org/project-6.
- The project-6 slice is on example-org/project-6 main (550214ae). It pins the
  same `ci-base:ad930bd49a76` as the kit. It does not use `container:`,
  because on MonkCI a job container cannot reach the artifact service
  (project-6 PR #3238). The kit keeps its `container:` path and adds the
  caveat; a rewrite to the host-run pattern was not in the scope update.
- The re-run warning goes to stderr only after a GitHub-board filing. App
  boards are read through their list route, which has no index lag.
- The app-board dedup reads the one ticket list (the board contract has no
  pagination). A row matches on the marker line in `description` or on the
  exact child title, because the list route may omit `description`.
- The filer uses `gh api` REST calls only (issue search, issue create).
- The build did not run `file --apply`. Filing on up to 13 boards is an outward
  write. The operator runs `bin/ci-image-rollout.sh plan --all`, then
  `file --all --apply`, on the hub.
- r5 re-landed r4's code unchanged on main b45aff7b4; r4 opened no PR.
