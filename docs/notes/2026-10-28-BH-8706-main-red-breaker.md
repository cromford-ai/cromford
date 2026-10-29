# BH-8706: the main-red breaker (pause, file, resume)

Ticket: BH-8706 (KIND bug, label hotfix).
Doc: MERGIFY, MERGE-CONDUCTOR

## What changed

- New hub lane `bin/main-red-breaker.sh`, `*/5`, behind `bin/hub-lease.sh check`
  (`cron/lanes/777-main-red-breaker.cron`, `catalog/lanes.d/main-red-breaker.json`).
  It reads `flags/main-red-<owner>-<repo>`, which `bin/main-red-detector.sh`
  writes. It never writes or removes that flag.
- Flag up, Mergify repo: every open PR with the exact label `merge-queue`, and
  without `fix-main-red`, gets `merge-queue-paused`. The ledger row
  `main_red_breaker <owner>/<repo>` is written `pausing` BEFORE the first label
  POST. If that write fails, no label goes on. After the POSTs the row goes
  `paused` with every PR whose POST answered 2xx.
- Flag up with `sha=` and `since=`: one issue per red episode, labels
  `ai-build,hotfix`, on the repo's own GitHub Issues. The body lists the failed
  jobs, their failed steps and failure annotations, the PR merges between the
  last green run of the same workflow and the red sha, and the log links. It
  carries `PR-Labels: fix-main-red`, so the fix PR passes the freeze. Dedup:
  ledger row `main_red_hotfix <owner>/<repo>@<since>`, then the body marker
  `<!-- main-red-breaker: <owner>/<repo>@<since> -->` in the open hotfix issues.
- Flag gone, row `pausing` or `paused`: the label is removed from every open PR
  that has it. Then each PR the row lists or the label was on is re-queued
  through `mc_requeue_mergify` (remove `dequeued`, post `@mergifyio requeue`).
  Mergify does not take a dequeued PR back by itself (docs/MERGIFY.md). The
  breaker does not call `mc_requeued_record`, so a pause costs no PR its one
  BH-636 requeue. A closed PR or a PR without `merge-queue` is not re-queued.
  The row goes `resumed` only when every DELETE answered ok, every PR is done
  and a re-read shows 0 labelled PRs.
- Mergify: the queue_conditions of the non-hotfix queue_rules (default, solo,
  flake-fix) carry `-label=merge-queue-paused`. queue_conditions bind every
  entry path, the label rule and the `@mergifyio queue` command, and a PR that
  stops matching them leaves the queue (the BH-2275 mechanism). The non-hotfix
  pull_request_rules carry it too. The hotfix queue and rule do not. It is not
  in merge_conditions: Mergify evaluates those on the batch draft, which never
  carries the PR's labels, so the line would do nothing.
- Conductor: `mc_queue_left_why` answers `paused` for an OPEN PR with the pause
  label. The settle arm keeps the row QUEUED, writes one `qpaused` mark per head
  and takes no ejection strike. When a paused PR sits on a GREEN main for a
  second tick, the conductor sends one warn per head (stranded label). After a
  resume, a `qpaused` mark on the head buys one tick of grace (`qresumed`)
  while Mergify takes the PR back. The breaker writes that mark before its
  requeue, so the grace holds even if the conductor never saw the pause.
- `MAIN_RED_BREAKER_PAUSE_LABEL` is `settable:false`. The Mergify files hold the
  literal, so a changed value would fail open.
- Detector: `MAIN_RED_SKIP_RE_OVERRIDES` (settings row
  `lane.main-red-breaker.main_red_skip_re_overrides`, default `{}`) replaces the
  global skip regex for one repo. With `{}` nothing changes.

## What did not change

- The detector still sends the one `--critical` page per episode. The breaker
  sends no page. It sends one `warn` per episode only when the ticket create
  fails (`--id main-red-breaker-file:<owner>/<repo>@<since>`).
- No migration lane changes. `bin/migration-autopilot.sh` applies migrations of
  code that is already merged and deployed. Pausing it would leave deployed
  code reading missing tables.
- **example-org/project-6 is NOT paused by this change.** Its `.mergify.yml` is
  not rendered from the template, so Mergify there ignores the label. Each
  tick the breaker reads the repo's `.mergify.yml`. If it has no
  `-label=merge-queue-paused` condition, the breaker writes no label, logs one
  `does not exclude merge-queue-paused — not paused` line per episode, and the
  hotfix ticket says the queue is NOT paused. The same applies to project-3,
  project-2 and project-5 until their `bin/mergify-sync.sh apply` PRs
  merge. If the read fails, the labels go on and the ticket says the pause is
  unconfirmed. The hotfix ticket and the freeze on new enqueues work on every
  repo now.
- A repo on the GitHub native merge queue has no label hook. Its queued PRs are
  not paused. The existing freeze still stops new enqueues there.
- A project with an in-app board (fleet.conf column 4 is not `-`) gets one log
  line and no ticket.

## Operator steps

1. Run `bin/mergify-sync.sh apply`. The template change makes project-3,
   project-2 and project-5 drift once; apply opens one sync PR per repo.
2. If you change `MAIN_RED_BREAKER_PAUSE_LABEL`, re-render every Mergify conf.
3. File the project-6-os ticket below on example-org/project-6 with the labels
   `ai-build` and `hotfix`. Its `.mergify.yml` is not template-managed.
4. After that ticket lands, set the knob for project-6, for example:
   `bin/harness-ctl.sh set main-red-breaker MAIN_RED_SKIP_RE_OVERRIDES '{"example-org/project-6":"(nightly|smoke|publish|deploy)"}'`.

## project-6-os repo-side ticket

Title: Main-red breaker: run the impacted E2E on push to main, and honor merge-queue-paused

Body:

The harness main-red breaker (cromford BH-8706) pauses queued PRs when
main is red. Two repo-side changes are needed in example-org/project-6:

1. `.github/workflows/e2e.yml`: on a `push` to `main`, run the impacted specs
   (the same selection a PR run uses, against the pushed commit) instead of
   skipping all shards. Also make `ci.yml` run the unit suite on a
   "push_trusted" push to main (TK-2341 skips it today). Without these runs,
   main's push checks stay green through an E2E break, and the detector
   cannot see the red.
2. `.mergify.yml`: add `- -label=merge-queue-paused` to the `queue_conditions`
   of every non-hotfix queue in `queue_rules`, and to the conditions of every
   non-hotfix pull_request_rule. The queue_conditions line is the one that
   counts: a PR queued by `@mergifyio queue` is checked against it, not
   against the pull_request_rule. Do not add it to the hotfix queue or rule,
   so `fix-main-red` PRs still land.

Acceptance:
- A push to main that breaks an impacted E2E spec turns the push run red.
- A PR with `merge-queue` and `merge-queue-paused` is not queued by Mergify.
- A PR with `fix-main-red` is still queued while the pause label is on others.

After it lands, the harness operator sets `MAIN_RED_SKIP_RE_OVERRIDES` for
example-org/project-6 so its E2E workflow counts as required.

## Round 3: three suites this branch turned red

Mergify dequeued PR #8747 on three suites this branch alone turned red. In
round 3 I fixed those three and changed no breaker decision:
`tests/no-state-files.bh-4159-test.sh` S1 (`state/main-red-breaker/` was not
classed), `tests/tracker-direct-calls-ratchet.bh-7919-test.sh` R1 (three direct
issue-API calls) and `tests/config-slice-cost-mc.bh-1939-test.sh` L1 (a literal
knob default in `bin/lib/mc/queue.sh`). `state/main-red-breaker/` is now a
`box-local` row in `catalog/state-paths.json`. The lane runs only on the hub,
and the records that dedup (the hotfix ticket, the pause episode) are already
`main_red_hotfix` and `main_red_breaker` job-ledger rows. A lost note file
costs at most one extra log line, warn or requeue per PR per episode. The
label POST, the label DELETE and the issue POST go through the github-issues
tracker adapter: `tracker_label_add`, `tracker_label_remove` and a new verb
`tracker_create` (`trk_gh_create`). `mc_queue_left_why` reads the pause label
through `lane_knob main-red-breaker MAIN_RED_BREAKER_PAUSE_LABEL`.

## Not verified here

- No live Mergify probe. This box did not put the pause label on a PR in a
  live queue and watch it leave, then come back after the requeue. The
  mechanism is the one BH-2275 already uses (a queue_conditions line that
  stops matching dequeues the PR). The first red episode on cromford or
  project-5 after `bin/mergify-sync.sh apply` is the live check: look for
  `paused N PR(s)` and `re-queued` lines in `logs/main-red-breaker.log` and the
  `dequeued` / `queued` labels on those PRs.
