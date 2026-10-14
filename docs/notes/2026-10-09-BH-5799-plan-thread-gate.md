# A plan must cite the newest ticket comments (BH-5799)

Doc: RUN-BUILD-GRAPH

## Why

A review of 300 PRs (#4168 to #5787) found 12 BLOCKs with one shape. A later
comment changed the scope, and the plan built the ticket body anyway. Examples:
#5459, #5237, #4785, #4761. The plan prompt already said "THREAD RECENCY IS
LAW". Nothing checked it. On a GitHub-issue project (`board_prefix` = `-`),
`TICKET_FP` in `bin/lib/rb/plan.sh` is empty, so the three existing thread
gates are off there. A reused or adopted plan was never compared with the
thread.

## What changed

- **Plan prompts.** The build plan prompt (`bin/lib/rb/plan.sh`, plan prompt
  block) and the pre-plan prompt (`bin/run-preplan.sh`) tell the planner to
  read the thread newest first and to write a `## Spec changes from comments`
  section. Each line starts with a comment id. No scope change is the single
  line `none`. `prompts/plan-contract.md` §14 has the rule.
- **Stamp.** `plan-thread-at` holds the UTC time the plan session started. The
  fresh plan writes `$BUILD/plan-thread-at` just before `CC plan`. The pre-plan
  writes `plans/<project>-<key>/plan-thread-at` just before `agent-call.sh
  preplan`. `bin/fly-pool.sh` relays it to the Fly machine with `base-sha` and
  `ticket-fp`. The pre-plan HIT arm copies it into `$BUILD`. The coordination
  DB row carries it too: `preplan_put` sends it as `thread_at`, the worker
  stores it in the `preplans.thread_at` column (added by `ensureColumns`, so
  the deploy applies it), and `preplan_fetch` writes it back as
  `plan-thread-at`.
- **New lib `bin/lib/plan-thread.sh`.** `ptg_check` pages the issue comments
  (up to 1000) through `gh_rest`. A comment COUNTS when all of these are true:
  - its author is a person (`user.type` is not `Bot`) or our App (`hs_ours`
    from `bin/lib/harness-self.sh`);
  - `created_at` or `updated_at` is after the stamp;
  - its normalized body is not in `$BUILD/own-comments.sha256`;
  - plan.md does not carry its id as a whole token, or its `node_id`.
  Any counting comment refuses the plan. Third-party bots never count.
- **Call site A**, `# >>> plan thread gate (BH-5799)` in `bin/lib/rb/plan.sh`,
  just before the plan checkpoint. A reused or adopted plan that is refused
  goes to `plan.md.thread-refused`, and `ticket-fp`, `call-fp` and
  `plan-thread-at` are removed. The checkpoint then plans fresh in the same
  run. A refused hub pre-plan dir is removed, and `preplan-outcome` becomes
  `STALE uncited newer comment(s) <ids>`. Log line: `PLAN_THREAD_REFUSED
  (reused plan) …`. Exception: a resumed build (`RESUME_BUILD`), or a branch
  that already carries a diff over BASE, does not plan fresh. EXECUTE would
  skip that branch, and the old diff would ship under the new plan. It ends
  `PLAN_STALE` (exit 3), like call site B. Log line: `PLAN_THREAD_REFUSED
  (reused plan, resumed branch) …`.
- **Call site B**, `# >>> plan thread pre-review (BH-5799)`, the first block of
  `rb_review` in `bin/lib/rb/review.sh`, before any lens or smoke push. A
  refused plan goes to `plan.md.thread-refused`. The build ends `RESULT
  "PLAN_STALE uncited comment(s) newer than the plan: <ids> — re-plan"`, exit 3.
  `bin/orphan-reconcile.sh` does not count a `parked` row as an owner, so the
  ticket is relaunched after the 12-minute grace window.
- **Own posts.** The replan comment (`plan.sh`), the BUILD BLOCKED notice
  (`escalate_block` in `bin/lib/rb/execute.sh`) and the sibling sequencing
  note (`bin/plan-sibling.sh note`) are added to `own-comments.sha256` after
  the post returns 0. So is the resolver's adjudication on the issue
  (`# >>> adjudication issue post (BH-5799)` in `bin/blocked-resolver.sh`),
  into the record dir that an ACCEPT resumes. A resolver ACCEPT resume does
  not refuse its own plan.
- **PR body.** `# >>> spec changes section (BH-5799)` in `bin/lib/rb/pr.sh`
  copies the section (1500 bytes max) next to `## Assumptions`. A plan with no
  section gets the line `The plan carried no 'Spec changes from comments'
  section.`
- **Lead review.** `prompts/lead-review-checklist.md` v3, item 1, compares the
  section with the thread. `bin/lead-review.sh` adds a `comment-id: <id>` line
  under each `### <login> at <created_at>` heading. The heading line did not
  change.
- **Plan gate.** `bin/plan-gate.sh` does not score the section as tasks.

## Stamp sources, in order

1. `plan-thread-at`.
2. An adopted pre-plan with no stamp: every comment counts as newer. It
   passes only when it cites every counting comment, or the thread has none.
   Only a DB row published before the `thread_at` column has no stamp. The
   worker deletes rows after 14 days, so this case ends 14 days after the
   worker deploy.
3. Any other plan with no stamp (a build dir from before this change): the
   mtime of plan.md, with the line `plan-thread: no stamp, using plan.md mtime`.

## Fail open

An unreadable thread (a non-zero `gh_rest`, a page that is not an array, more
than 1000 comments) writes one `plan-thread: … — gate fails open` line and the
build continues. An in-app board project answers `n/a` and makes no call.

## Knob

`PLAN_THREAD_GATE_ENFORCE` (`catalog/lanes.d/_lib.plan-thread.json`, int 0..1,
default 1). 0 = warn only: one `PLAN_THREAD_WARN` line, the plan is kept.

## Check on a box

```bash
grep -h 'plan-thread:\|PLAN_THREAD_' /root/harness/builds/cromford-*/pipeline.log | tail
ls /root/harness/builds/cromford-*/plan-thread-at | tail -3
```

Suite: `tests/plan-thread-gate.bh-5799-test.sh`.
