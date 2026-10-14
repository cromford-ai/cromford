# What writes PR gate facts, and the sweep that heals them (BH-4954)

Doc: pr-rows-contract

## What changed

BH-4953 added the gate table (`state='gate'` rows in `pr_state_events`) and
the needs-review query, with no writer. This adds three worker writers and
one hub lane. The fold and the eligibility rule are unchanged.

- **Webhook intake.** `/webhooks/github` calls `recordGithubGate`
  (`worker/jobs/src/lib/pr-gate-intake.js`) after the repo check and before
  `wakeOf`, because `wakeOf` drops `converted_to_draft` and the label events.
  The wake row and every response are unchanged. The source is the
  `X-GitHub-Delivery` id, so a redelivery is a duplicate. No delivery id means
  no gate row.
  - `pull_request` opened / reopened / synchronize / ready_for_review /
    converted_to_draft / closed → `head`, `draft`, `closed` (and `url`). If any
    of the three can't be read, no event is written at all.
  - `pull_request` labeled / unlabeled `hotfix` (case-insensitive, exact name)
    → `hotfix` 1 / 0.
  - `check_suite` completed, `conclusion: success`, `app.slug: github-actions`
    → `ci_green_sha` on every PR in `pull_requests[]`.
  - `issue_comment` created on a PR by a non-Bot → `held`. See the hold
    grammar below. Edited comments are not read; the sweep covers them.
- **Builder approve.** `PUT /api/jobs/:id/artifacts` for `verdict` or `pr_url`
  calls `recordBuilderApprove`. It writes `builder_approved_sha` when the job
  holds a settled (`settled !== false`) APPROVE, a github pull `pr_url`, and a
  sha. That sha is `reapproved@<sha>` from `headbound` when present, else
  `reviewed_sha`. The source is `approve@<sha>`.
- **Lead verdict.** `POST /api/verdicts` calls `recordLeadVerdict` for a lead
  or human row after the INSERT: `lead_verdict_sha`, `lead_verdict_word`,
  source `verdict#<id>`. A box row writes nothing.
- Every writer runs after its route's own write and never throws. A failure
  logs `console.warn("[pr-gate-intake] …")` and the route answers as before.
- **The sweep.** `bin/pr-state-reconcile.sh tick` runs on the hub every 15
  minutes for each repo in `LEAD_REVIEW_AUTO_REPOS`. It compares live facts
  with `pr_gate_facts` and writes one `reason=reconcile` event per stale field.
  The fields are `head`, `draft`, `closed` (reopened, or closed on GitHub while
  the db says open), `ci_green_sha` (`frp_ci` green), `builder_approved_sha`
  (`job_verdict` on the head, or `reapproved@<head>`), `lead_verdict_*`
  (`vd_standing`) and `held` (`hold_check_thread`). An unreadable read is
  skipped, never written. A failed write is counted `failed=`, never
  `corrected=`. It is skipped when `gh_budget_low` says low. The closed step
  runs only when the open list is complete (< 100 rows).

## Rules worth knowing

- **Which CI counts.** Green means a GitHub Actions check_suite with
  conclusion success. In cromford the only `pull_request` workflow is
  Harness CI, so that suite is Harness CI. A third-party app's suite never
  marks green. The sweep's `frp_ci` is stricter: every effective run and check
  must be green. A later red suite on the same sha does not clear
  `ci_green_sha`. So this rule depends on the workflow list: a second
  `pull_request` or `push` workflow would make green mean "some suite was
  green", and this rule must change with it.
- **An approval is not taken back on the same head.** A builder APPROVE on sha
  A that a BLOCK on the same sha A replaces (a re-review or a rescue) leaves
  `builder_approved_sha=A`, and the sweep never writes backwards. needs-review
  lists the PR until the head moves. Lead review is an added gate, not a merge.
- **The hold grammar subset.** The intake classifies the comment's FIRST line
  with `bin/lib/hold.sh`'s PR-thread regexes in hold.sh's order: lift
  (`RESUME`/`UNHOLD`), then abandon (`ABANDON`/`CLOSE-PR`), then hold (`HOLD`
  alone, `HOLD:`, `HOLD —`). It records only when the whole body classifies the
  same way. A first-line `HOLD:` with a later `RESUME` line records nothing,
  because hold.sh reads that comment as a lift. Abandon records `held=1` and a
  lift records `held=0`, matching `hold_check_thread`.
- **Sha facts are never retracted.** NULL is "no news". A head that goes red
  after green, or an approval withdrawn, is never written backwards. Every sha
  fact is compared with `head`, so a new head already invalidates it.
- **Ints compare null as 0.** For `draft`, `held` and `closed`, a cold first
  sweep writes only the facts that change eligibility.
- **The reconcile source** is `reconcile@<head12>@<field>@<sweep epoch>`, not
  the literal `reconcile@<head>@<field>`. With a 40-char head the literal form
  is 71 chars, over the 64-char `since` cap. It would also collide on the
  dedupe key the second time one field needs correcting on one head. The sweep
  is idempotent because it compares facts, not because of the key.
- **The knob.** `PR_STATE_RECONCILE_MAX_PER_SWEEP` (registry int, default 30,
  1..500, required) caps the corrections per sweep. The first sweep against an
  empty table is a cold backfill, and it defers instead of bursting: the rest
  are seen again next sweep. Empty or 0 refuses with a log line and writes
  nothing.

## The operator step

The three writers run in prod only once the jobs worker is deployed, and the
sweep runs only once the hub has this checkout. Neither reads the
`pr-state-rows` flag: the gate routes and the `pr_gate_*` verbs are not behind
it (`bin/lib/jobs/jobs.sh`). The ticket still names raising `pr-state-rows`
(`bin/jobs-client.sh flag-set` / `PUT /api/flags`) as the go-live step.
Raising it turns on the existing `pr_state_event_put` writers (the conductor,
`blocked-resolver.sh`), so it is an operator decision and not a build step.
After the deploy, probe `GET /api/pr-state/gate?repo=example-org/cromford`
once the first `pr-state-reconcile` sweep has run.

## Review fixes (2026-10-09, lead review lr-5060-f2bef1d50074)

- **One standing-source list.** `recordLeadVerdict` only accepted `lead` and
  `human`, while `vd_standing` (and so the reconcile sweep) also counts
  `risk-tier` (BH-5022). A risk-tier MERGE therefore left the PR in
  needs-review until the next sweep. `STANDING_SOURCES` now lives in
  `worker/jobs/src/lib/verdict-sources.js`, and the verdicts route, its SQL and
  the gate's event writer all import it. Tests L4 and L5 in
  `worker/jobs/test/pr-gate-intake.bh-4950.test.js`.
- **Known, accepted limits (NOTEs on that review):**
  - The fold keeps the newest non-null value by row id. Two `synchronize`
    deliveries that arrive out of order can set `head` back to the older sha
    until the next sweep, at most 15 minutes, repairs it.
  - The sweep judges `lead_verdict` only when `lead_verdict_sha != head`. A
    BLOCK and then a MERGE on the same head keep the first word until a hook
    write lands. needs-review reads only the sha today.
  - `gh_budget_low` rc 2 (budget unknown) reads as "not low", and the sweep
    runs, the same as lead-review-enqueue does.
