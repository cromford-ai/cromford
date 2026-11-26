# BH-7921 plan (fixture: the output a stub repair pass writes; the Verify list cut to the three target suites)

## Verify (run, not edited)

One command per suite. The gate runs the wide selection.
- `HARNESS_TEST_SANDBOX=1 bash tests/run-build-linear-stub-test.sh`
- `HARNESS_TEST_SANDBOX=1 bash tests/run-build-jira-stub-test.sh`
- `HARNESS_TEST_SANDBOX=1 bash tests/docs-connectors.bh-7924-test.sh`

## Tasks

### T0. Apply the r5 commits to current main

- `git fetch origin ticket/bh-7921-r5`, then `git cherry-pick 43abe668 31af8676 7e75fa59` onto `ticket/bh-7921-r6` (base main `ff31170c` or newer). Then `git mv docs/notes/2026-11-04-BH-7921-run-build-tracker-contract.md docs/notes/2026-11-15-BH-7921-run-build-tracker-contract.md` and change the date line inside it to the build day (2026-11-15). No other edit unless a VALIDATE below fails on a drift from main. If a cherry-pick conflicts (a main commit landed after this plan), resolve it to main's surrounding code plus r5's added lines, and record each hunk in the PR body.
- Checked for this plan: the three commits apply clean with `git cherry-pick -n` on main `ff31170c` (scratch tree `/tmp/bh7921-r6c`; git auto-merged `execute.sh`, `plan.sh` and `pr.sh` with no conflict).
- VALIDATE: `git diff --stat origin/main...HEAD -- bin` lists exactly the five `bin/` files of Files to touch, and `bash -n bin/lib/rb-tracker.sh bin/lib/rb/plan.sh bin/lib/rb/execute.sh bin/lib/rb/pr.sh bin/lib/rb/gates.d/closed-issue-skip.sh && shellcheck -S error bin/lib/rb-tracker.sh bin/lib/rb/plan.sh bin/lib/rb/execute.sh bin/lib/rb/pr.sh bin/lib/rb/gates.d/closed-issue-skip.sh`
- SATISFIES: "`run-build.sh <p> CRO-12 CRO-12` runs plan, execute, PR open, hold and close-out against the tracker, and the PR is attached to the Linear issue or commented on the Jira issue." (the slice C0 code, built as r1-r5) and comment 6743667001 "the operator wants this built and merged now"


## Failure modes

- Decision rule (which arm a site takes, `rbt_kind`): github-issues arm: settings row absent + column 4 `-` (source: fleet.conf today); row `github-issues`. board arm: column 4 `EP` and no row; row `board`. jira/linear arm: row `linear` with column 4 `-` (source: comment 6329844320, `tracker_adapter.cromford-sandbox-linear=linear`); row `jira` with column 4 `-`. Near misses: row `Linear` (refused by `tracker_adapter`, rc 1 → today's code); row `linear` but `tracker.sh` missing (rc 1 → today's code, and `trk_gh_issue_number` is also absent, so nothing posts); key `CRO-12` on a github-issues project (`trk_gh_issue_number` → 12, today's behavior). Test: L1 and J1 assert every case.
- Decision rule (refresh `ticket-fp` after an own write): refresh → stored fp equals the pre-write fp and the write rc 0 (BLOCKED notice on Linear; `PR:` comment on Jira). Keep → a human comment landed before our write (fp0 differs); our write failed (rc 1, 75); the pre-write read failed; no `ticket-fp` file (a fresh build). Near misses: a status-only move before the write (status is not in the fp, so it refreshes); a human comment between our write and the post-write read (refreshes; that comment is hidden from the resume stale gate, see Edge cases); our own notice deduped by the mark (no write, no refresh). Test: L8 (resume after a notice → no PLAN_STALE), L9 (human comment before the notice → PLAN_STALE on resume), L10 (failed post → `ticket-fp` unchanged), J5 (Jira, the same as L8), J7 (resume after the `PR:` comment → no PLAN_STALE).
- Decision rule (close-out after merge): close → no REFUTED claim, no SLICE line. Keep open → evidence.json with one REFUTED claim; plan.md with `SLICE: C0 of #12`. Near misses: an INCONCLUSIVE claim (closes, as BH-5798); a plan that says "slice" in prose without the `SLICE:` line anchor (closes). Test: L12, L13, L14.
- Decision rule (closed skip): refuse → Linear state type `completed`, `canceled` (normalized `state: closed`); Jira category `done`. Build → Linear `started` ("In Review"), `unstarted`, `backlog`; Jira `indeterminate`; a read that failed (rc 1, 75) → build. Test: L5, L6, J4.
- Exit paths: closed skip → `BUILD_REFUSED` + exit 3, no job claim, no queue row (same as GitHub). Every other new path returns 0 and leaves the build running. The state it writes: `$BUILD/tracker-ticket.json`, `$BUILD/tracker.log`, `$BUILD/ticket-fp`, `$BUILD/own-comments.sha256`, and the comment marks (D1 `commented` row + `$HARNESS/state` stamp). No budget or counter is touched. Test: L5 asserts the RESULT line and exit 3; L11 asserts rc 0 after a failed link.
- Writer/reader round-trip: `$BUILD/ticket-fp` `trk:<hex>`: writers `plan.sh:1286`, the replan refresh `:1665`, and `rbt_own_write`; readers the resume stale gate (:1203) and `ptg_refuse_plan` (deletes it). Test: L8 writes it through `TICKET_FP`, rewrites it through `rbt_own_write`, and reads it through the lifted resume stale gate. `$BUILD/tracker-ticket.json`: writer `TICKET_FP`/the closed skip; readers `TICKET_META`. Test: L3.
- Decision rule (D6 asks for the "Today" sentence): asks → `pr.sh` without the literal `tracker_kind` (main before this PR; N6's stripped fixture). Stands down → `pr.sh` with it (this head; N6b's appended line). Near misses: `rbt_kind` alone without the literal (D6 asks, so the routing line must name `tracker_kind`, T8); the literal only in a comment (D6 stands down, by design of BH-7924's grep). source: `tests/docs-connectors.bh-7924-test.sh:155-167`. Test: the checkout run (D1-D6 green, D6 stood down), N6 (rc 1), N6b (rc 0).
- Alert or freeze blast radius: n/a — C0 adds no alert and no freeze. The closed skip reuses the existing BUILD_REFUSED terminal, at most once per launch of a closed ticket.
- Defaults in prod: n/a — no new knob. The behavior turns on only for a project whose settings row `tracker_adapter.<p>` says jira or linear. Today those are the two sandbox projects (comment 6329844320).
- Status evidence: the `pipeline.log` lines "linked PR <url> on <key> (<kind>)", "moved <key> to review", "closed out <key> after merge" each follow an adapter rc 0. A failure line names the rc and the owner (C2 lanes). Test: L11, L12, J6, J8 assert the line for each rc.

SIZE: M
