# Hold, retry and spend gates on the lead review worklist (BH-5876, child 4 of #5870)

Doc: LEAD-REVIEW

## What changed

- Seven gate files in `bin/lib/lead-gates.d/`, run by the loader
  `bin/lib/lead-gates.sh` for a worklist head with no request row. Each one is
  the enqueue's gate, moved with the least change:
  - `75-self-check.sh` (gate 7, BH-5798) and `78-body-lint.sh` (gate 8,
    BH-5790). Both read one `psc_check` run per head (`lgsc_run`,
    `bin/lib/lead-gates-selfcheck.sh`). Gate 7 holds on a refusal that is not
    a `body-*` rule, gate 8 on a `body-*` refusal. A hold writes ONE PR comment
    per (head, body) that names every refusal, and is bounded by
    `PR_SELF_CHECK_MAX_WAIT_MIN`. Gate 8 writes the per-head notes file once,
    and `lg_field_self_check_notes` sends it as job meta `self_check_notes`.
  - `85-rebase-hold.sh` (gate 10, BH-5796): the conductor's row on this head,
    GitHub DIRTY, or a `git merge-tree` conflict in the clone holds. A clean
    head that `dup_main_pr` flags is started with job meta `dup_note`.
  - `57-traced-hold.sh` (gate 10a, BH-5795): a stacked base with no traced
    run holds, with one `scope=impact` dispatch per head, bounded by
    `LEAD_REVIEW_TRACED_MAX_WAIT_MIN`. Past the bound the job carries
    `traced_note`.
  - `90-caps.sh` (gate 13): `LEAD_REVIEW_ENQUEUE_MAX_PER_TICK` and the
    dispatcher's `LEAD_REVIEW_MAX_PER_PR_DAY` (`lw_pr_day_ok`). It runs before
    `job_open`, so a capped head makes no job POST.
  - `95-retry-reclaim.sh` (gate 11, BH-5779): `lg_tick_reclaim` calls
    `POST /api/lead-reviews/reclaim-stale` once a tick. `lg_gate_retry` resets a
    failed lead review up to `LEAD_REVIEW_FAILED_RETRY_MAX` times per head,
    and leaves environment failures to `bin/lead-review-land.sh` when it owns
    them.
  - `97-doorbell.sh` (gate 15, BH-4057): `lg_post_doorbell` rings lead-review
    after a claim. A ring failure is one log line.
- One new knob lib, `bin/lib/lead-gates-knobs.sh`. `lgk_load` reads the
  `lead-review-enqueue` lane's knobs once a process, in a subshell. A registry
  read that fails, or an empty per-tick cap, holds every worklist head.
- No new knob and no new store. The gates use the enqueue's state paths and
  formats (`state/lead-review-enqueue/selfcheck-*`, `selfcheck-notes-*`,
  `traced-*`, `failed-retry.tsv`, `alerted-*`). The derived note files under
  `state/lead-review-gates/` (`dup-*`, `traced-note-*`) are deleted after 14
  days by the gates' tick hooks. `lg_tick_reclaim` drops `failed-retry.tsv`
  rows older than 30 days, as the enqueue does.

## Decisions

- File numbers 75 and 78, not the 35 and 38 the ticket names. At 35 the self
  check would run before `50-replay-delta.sh`, `55-snapshot.sh` (the PR body
  read) and `60-risk.sh`, so it would hold free replays and risk-tier sign-offs.
  The enqueue runs the self check after the risk tier. Test S7 pins the order.
- File number 57 for the traced hold, by the same rule. The enqueue runs the
  traced hold before the risk tier. It needs the PR body, so it comes after
  `55-snapshot.sh` and before `60-risk.sh`. After 60, a low-tier head under
  `enforce` on a stacked base would get a risk-tier MERGE sign-off with no
  test run on it, and both lanes read that verdict. Test T10 pins the order.
- The per-tick cap is back on worklist items. BH-4956 had no per-tick start
  cap. The enqueue already caps new requests at `LEAD_REVIEW_ENQUEUE_MAX_PER_TICK`,
  so spend does not grow. Request rows are not counted. A head that passes
  gate 13 and is then held by gate 11 still uses its place.
- Gate 11 is kept. `needsReviewRows` (`worker/jobs/src/lib/pr-gate.js`) leaves
  out only `review_failed_sha`, so a row that `reclaim-stale` moves to `failed`
  stays on the worklist, and `lr_start` answers terminal on it every tick.
- The doorbell rings the lane that runs it. The ring is deduped per (PR, head)
  in the wakes table, and the rerun is bounded by `LEAD_REVIEW_RERUN_MAX`.

## Not done here

- `bin/lead-review-enqueue.sh` is unchanged and still runs on the hub. Its
  suites (`lead-enqueue-self-check.bh-5798`, `lead-enqueue-body-lint.bh-5790`,
  `lead-enqueue-traced-wait.bh-5795`, `lead-enqueue-rebase-hold.bh-5796`,
  `lead-review-enqueue-failed-retry.bh-5779`, `lead-review-chain-doorbell.bh-4057`)
  stay as its coverage until the retirement child (BH-5877).
- The three new job meta keys are a record. Nothing reads them yet.
- Nothing changes in prod until an operator sets `LEAD_REVIEW_WORKLIST=1` on a
  box. The default is 0.
