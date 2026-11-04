# Lead review jobs (BH-1950)

**What it is:** a box lane, `bin/lead-review.sh tick`, that reviews the heads
the needs-review worklist lists (`GET /api/pr-state/needs-review`, BH-4956)
and answers lead review requests (`lead_review_requests`, BH-1948) for the
repos the box owns. For each one it claims the request under the job key
`lr-<pr>-<sha12>` (lane
`lead-review`), checks out exactly the requested head in a scratch worktree,
runs the repo's Verification Contract command, and asks the `lead.review` model
route for a verdict with `prompts/lead-review.md`. The answer is one of
`MERGE`, `MERGE-WITH-NOTES` or `BLOCK`.

**How a user reaches it:** the lane itself has **no UI route**; Mission Control
shows its spend, running jobs, worklist and failures at `/lead-reviews`
(BH-4957: KANBAN → LEAD REVIEWS). It runs from cron on every non-hub box
(`cron/lanes/710-lead-review.cron`, every 5 minutes). By hand on a box:

**How a user reaches it:** there is **no UI route**. It runs from cron on every
non-hub box (`cron/lanes/710-lead-review.cron`, every 15 minutes, a backstop)
and when `bin/wake-loop.sh` claims a `lead-review` row the enqueue lane rang
through the wakes doorbell (`bin/lib/lead-chain-wake.sh`). By hand on a box:

```bash
/root/harness/bin/lead-review.sh tick
tail -5 /root/harness/logs/lead-review.log
```

**What to look at:**

- `logs/lead-review.log`: one `tick seen=N owned=M done=… superseded=… failed=…
  skipped=… deferred=… concurrency=… running=… started=… worklist=… paid=…
  replayed=… capped=… rung=… total=… prs=…` line per tick, plus one line per
  request it acted on. `worklist=` is the needs-review items read this tick,
  `paid=` the items whose request was already `done` (no model call),
  `replayed=` the patch-same replays (no model call), `capped=` the items held
  by the daily spend row or the per-PR tripwire. `rung=` counts the lead-land rings this tick sent. Until the `/api/lead-reviews` routes are deployed every tick logs
  `lead-review routes not deployed; tick skipped`.
- The worklist (BH-4956), first: for each `LEAD_REVIEW_AUTO_REPOS` repo this
  box owns (the lead-review-land knob), `pr_needs_review` lists the heads to
  review, nudged first, then hotfix, then the oldest approval. A failed read is
  `needs-review for <slug> unreadable (rc=1); nothing starts from its worklist
  this tick`. An item is claimed with `POST /api/lead-reviews/start`; a request
  row for the same `(repo, pr, head)` is worked in its place, by id. Every
  eligible item starts as soon as a slot is free; there is no per-tick start
  cap. Before a claim: `skip <key>: another worker holds
  locks/lead-review-<key>.lock`, `skip <key>: 3 counted attempts on this head`,
  `skip <key>: <repo>#<pr> had agent calls for LEAD_REVIEW_MAX_PER_PR_DAY=<n>
  lead reviews today on this box` (only a review the model answered is
  counted), with one `lane-alert` warn a PR a UTC day, id
  `lead-trip-<owner_repo>-<pr>-<YYYYMMDD>`. `/start` answering terminal `done` logs `paid already <key>`. A
  head carrying the patch of an earlier lead verdict logs `replayed <key>: lead
  <word> from <prev12> (<how>); no agent call` and posts `reviewer_model:
  lead-replay`, `report_ref: lead-replay:<prev12>:<how>`.
- The limits, re-read before each start: `lead_review.concurrency` (fleet-wide;
  no row = `no lead_review.concurrency row; the box cap governs`; the running
  count unreadable = `lead_review running count unreadable; no start this
  pass`) and `lead_review.daily_spend_usd` (no row = no cap; at the cap
  `lead_review.daily_spend_usd reached (<spend> of <cap> USD)` and one
  `lane-alert` warn a UTC day, id `lead-spend-cap-<YYYYMMDD>`; unreadable =
  no start and no alert).
- Counted failures (live head unreadable, checkout failed, artifact or result
  post failed, a stale claim taken over) log `counted attempt <n> of 3 on
  <repo>#<pr>@<sha12>: <reason>` (`pr_attempts` kind `lead-review-<n>`). The
  third posts `outcome=failed detail="attempts-exhausted: <reason>"` and the
  gate fact `review_failed_sha`. A worker that leaves its row `running` on
  purpose (rc 74..79, a rate limit, a GitHub rate limit on the live head, or
  a counted failure) PUTs `pr_attempts` kind `lead-review-free`; the next
  takeover logs `<key>: the claim taken over was released by this lane; not
  counted` and deletes it.
- The queue (BH-5151), second: the tick reads every page of the list, following
  `next_after`. `total=` is every requested+running row it read and `prs=` the
  distinct `repo#pr` among them. One of these lines means the read stopped
  early: `request list hit LEAD_REVIEW_MAX_PAGES=<n> after <rows> rows`,
  `request list page <k> failed`, or `request list truncated and the worker
  returned no next_after (cursor paging not deployed)`.
- The order: hotfix first (the PR carries the `hotfix` label, `HOTFIX_LABEL`;
  only while the hotfix lane is on, so `hotfix-lane-off` or `HOTFIX_LANE=0`
  also drops hotfix-first ordering here), then `priority` (higher first, `bin/lead-verdict.sh request … --priority
  <n>`), then oldest. A `requested` or `running` row whose PR is closed or whose
  head moved is superseded before any review (`superseded <key>: pr closed` /
  `head moved to <sha12>`); a `running` row under a live job refuses the claim.
- A worker fault ends the tick: `job_open for <key> failed (worker unusable);
  tick ended` or `claim of <id> for <key> answered 503 (…); tick ended`, and the
  summary ends `stopped=worker left=<n>`.
- `POST /api/lead-reviews/start` (BH-4955, bearer only) is the takeover path:
  it creates the row for `(repo, pr, head_sha)` if it is missing and moves it
  to `running` for the caller's job. A `running` row whose job is not live
  (job status is not `running`, or its `activity_age_s` is 15 minutes or more,
  the jobs watchdog's own measure) is taken over instead of wedging, a
  `superseded` row is restarted, and `done`/`failed` rows answer 409
  `terminal:true`. The shell client is `lr_start` in `bin/lib/lead-reviews.sh`
  (rc 0 started, 3 terminal, 4 held by a live job, 1 anything else). The lane
  calls it for a worklist item with no request row (BH-4956).

- The lead-land doorbell (BH-5317): a review whose terminal result (done, or
  outcome failed) was delivered logs `lead-land doorbell rung for
  <repo>#<pr>@<sha12>`, and the hub's land lane promotes it within seconds. A
  review whose rules pack could not run logs `lead-land doorbell withheld for
  <repo>#<pr>@<sha12> (rules pack could not run); the */15 cron covers it`. A
  refused ring (the kill switch `flags/lead-chain-wake-off`, or the route
  down) logs `lead-land doorbell not rung for <repo>#<pr> (rc <n>)`.
  Superseded, skipped and non-terminal failures never ring.
- The owed rerun: a tick that finds the lock held logs `tick skipped: the
  previous tick still holds locks/lead-review-tick.lock (a review is running)
  (rerun owed)` and writes `state/lead-review/rerun-owed`. The holder, when it
  ends, logs `rerun owed (depth <n>/<max>)` and launches one tick. It does the
  same when it left work deferred to its start cap or deadline. At the bound it
  logs `rerun owed but depth <n>/<max> reached; cron covers it`.
- `state/lead-reviews/<key>.md`: the report. Its head names the verdict, the
  host suite line (`host suite: <cmd> rc=<n>`, `host suite: no host suite
  declared`, `host suite: skipped (CI green on <sha12>: <n> checks)` or
  `host suite: off (LEAD_REVIEW_HOST_SUITE)`) and the reviewer model; the
  reviewer's answer follows verbatim.
  The same path is the job's `lead_review_report` artifact and the request's
  `report_ref`. On a pool machine (`LEAD_REVIEW_EPHEMERAL=1`, BH-8945) the
  disk dies with the machine, so `report_ref` is
  `artifact:<job>/lead_review_report`; `bin/lead-review-report.sh <id>` prints
  the stored report from the hub on any box.
- The host suite and CI (`LEAD_REVIEW_HOST_SUITE`, default `skip-if-ci-green`):
  before running the repo's Verification Contract command the lane reads the
  head's check runs (`GET repos/<repo>/commits/<sha>/check-runs`, REST). It
  skips the suite only when every check the BASE branch's `.mergify.yml`
  (`origin/<base>`, never the PR's own copy) `queue_conditions` require (`check-success = "<name>"`, less `lead-verdict`,
  which this review publishes) has a successful run on that exact sha, and no
  GitHub Actions run on it is pending or failed (skipped/neutral is fine for
  the rest, e.g. path-filtered corpus shards; Mergify's own `Mergify Merge
  Queue` / `Summary` runs are not CI results and do not block). Anything else runs it and logs
  `<key>: host suite runs (CI not known green on <sha12>: <why>)`. `<n> checks`
  is the number of required checks verified. A skipped suite still puts one
  line under the prompt's `## Host suite`: it was not run on this box, CI's
  required checks passed on this head, do not claim local test evidence.
  `always` runs it every time. `off` never does, on EVERY repo (fleet-wide):
  each review logs `<repo>: host suite not run (LEAD_REVIEW_HOST_SUITE=off,
  fleet-wide); no verification ran on this box for <key>` and the prompt says
  no host suite ran, so the no-declared-suite cap applies. An unknown value is
  `always`, logged once a tick.
- A PR that changes what CI runs gets neither skip, because CI's green is then
  the PR's own CI: when the diff `origin/<base>...<sha>` touches a file
  `lr_ci_cfg_inputs` lists from the BASE tree (`.github/`, `.mergify.yml`,
  other CI systems' config, `bin/ci-*`, `bin/test-impact*`, `catalog/ci-*`,
  `catalog/test-impact*`, every file the base workflows name, the
  `package.json`/`Makefile` of the root and of each directory they name, and
  the libs and data files the CI scripts among them read), or when that list
  or the diff cannot be read, both the suite and the pack run and the log says
  `<key>: host suite runs (the PR changes CI itself: <path>)` and
  `<key>: rules pack runs (the PR changes CI itself: <path>)`. A base
  `.mergify.yml` that uses a YAML anchor, alias, merge key or `extends:` gives
  no required list (the suite runs). Flip it with a settings row: `bin/harness-ctl.sh set lead-review
  LEAD_REVIEW_HOST_SUITE <value>`; the next tick reads it, no deploy.
- The rules pack and CI (cromford only, same knob, same single check-run
  read): CI runs the PR's OWN `bin/rules-pack.sh` and catalog, which a PR can
  weaken; the lead runs the box's trusted copy. So the lead skips its pack only
  when (1) the diff `origin/<base>...<sha>` touches none of the pack's inputs,
  derived from the trusted install by `lr_rp_inputs` (the pack, its
  `bin/lib/rules-pack*.sh` libs, `catalog/rules-pack.tsv`, every path a catalog
  row names, and every path those files name: the libs they source, the confs
  they read, `checks/`), and (2) CI's `Syntax + shellcheck + config integrity`
  (which runs `bin/rules-pack.sh --skip determinism`) and `Test determinism
  lint` both passed on the reviewed sha. The report then says
  `- rules pack: skipped (CI green on <sha12>)` and the prompt tells the
  reviewer it is clean. A diff touching an input logs `<key>: rules pack runs
  (trusted copy: the PR changes the rules pack's own input <path>)`; a list or
  diff that cannot be read runs it too. CI pending, failed, missing, another sha
  or an unreadable read runs the pack and logs `<key>: rules pack runs (CI not
  known green on <sha12>: <why>)`. `off` stops the host suite only; the pack
  still follows these rules.

**Preconditions:** a `lead.review` row in `model_routes` (seeded by BH-1948;
without one the request stays `requested` and the log says `no model route for
lead.review`), a clone of the repo under `/root/repos/<project>`, and the box
not being the hub (the hub logs `hub runs no agent work` and stops).

**Knobs** (`catalog/lanes.d/lead-review.json`): `LEAD_REVIEW_MAX_PER_PR_DAY` (4),
`LEAD_REVIEW_DEADLINE_S` (3600, closes starts only), `LEAD_REVIEW_DIFF_MAX_BYTES` (400000),
`LEAD_REVIEW_MAX_PAGES` (20), `LEAD_REVIEW_HOST_SUITE` (`skip-if-ci-green`;
`always` | `off`), `LEAD_REVIEW_RERUN_MAX` (3, the owed-rerun depth; 0 =
off). Settings rows: `lead_review.concurrency`, `lead_review.daily_spend_usd`
(BH-4956). Off switch: `flags/lane-off-lead-review`.

**What usually lies:** `total=N+` (with the `+`) is a floor, not the D1 count:
the read stopped early and the line before it says why. `superseded=` rows were
never reviewed.

**Suite:** `HARNESS_TEST_SANDBOX=1 bash tests/lead-review-lane.bh-1950-test.sh`
runs the real tick against a stubbed worker, gh and agent-call and real git.
`HARNESS_TEST_SANDBOX=1 bash tests/lead-review-queue.bh-5151-test.sh` runs it
against a paging worker for the queue, the order, the dead-row sweep and the
503 stop. `HARNESS_TEST_SANDBOX=1 bash tests/lead-review-rings-land.bh-5317-test.sh`
covers the lead-land ring and
`HARNESS_TEST_SANDBOX=1 bash tests/lead-review-concurrent.bh-5317-test.sh` the
tick lock and the owed rerun. The worklist, its limits and the paid-once order
are `tests/lead-review-worklist.bh-4956-test.sh`,
`tests/lead-review-throughput.bh-4956-test.sh`,
`tests/lead-review-no-wedge.bh-4956-test.sh`,
`tests/lead-review-spend-cap.bh-4956-test.sh` and
`tests/lead-review-paid-once.bh-4956-test.sh` (each with
`HARNESS_TEST_SANDBOX=1 bash`).
