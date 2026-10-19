# Notes index

Rendered by `bin/render-doc-index.sh` from the notes in this directory.
Do not hand-edit: the next docs pass overwrites it. To record a change, add
`docs/notes/<YYYY-MM-DD>-<KEY>-<slug>.md` with a `Doc:` line naming the docs
it belongs to, and re-render.

## MERGE-CONDUCTOR

- 2026-10-18 — [Open PRs join the migration-number check; bare self-references move; foreign lock keys are noted (BH-7398)](2026-10-18-BH-7398-migration-renumber-open-prs.md)
- 2026-10-18 — [A colliding migration number is renumbered at rebase time (BH-7365)](2026-10-18-BH-7365-migration-renumber.md)
- 2026-10-17 — [A merge-queue batch drops the always-suites the pre-push gate already ran (BH-7289)](2026-10-17-BH-7289-always-set-prepush.md)
- 2026-10-17 — [A batch-fail suite fix goes first in the merge queue (BH-7279)](2026-10-17-BH-7279-flake-fix-queue.md)
- 2026-10-17 — [The pre-push gate runs every deterministic ratchet before the push (BH-7187)](2026-10-17-BH-7187-prepush-gate.md)
- 2026-10-17 — [Merge origin/main into a PR branch only on a real conflict (BH-7042)](2026-10-17-BH-7042-main-merge-only-on-conflict.md)
- 2026-10-17 — [The risk tier can call a head low by evidence, not only by path (BH-6968)](2026-10-17-BH-6968-evidence-low.md)
- 2026-10-17 — [Merge lock to the project lease, re-review cap to D1 (BH-6887, BH-6881.3)](2026-10-17-BH-6887-mc-lease-budget.md)
- 2026-10-17 — [Hub project-loop ratchet, cron staggers, lead-review lock measure (BH-5945)](2026-10-17-BH-5945-ratchet-and-staggers.md)
- 2026-10-17 — [BH-5373 r2: culprit ejection on, bisect off (2026-10-17)](2026-10-17-BH-5373-culprit-flip-on.md)
- 2026-10-16 — [BH-7121: a check run with completed_at and a green conclusion is completed](2026-10-16-BH-7121-check-run-completed-at.md)
- 2026-10-16 — [The schema restamp also renames the fragment in plan.md and the PR body (BH-7120)](2026-10-16-BH-7120-restamp-plan-and-body.md)
- 2026-10-16 — [A conflict round gets a brief that can resolve it (BH-6964)](2026-10-16-BH-6964-conflict-fix-brief.md)
- 2026-10-16 — [Direct merge in optimistic landing mode (BH-6745, wave 2 of #6541)](2026-10-16-BH-6745-optimistic-landing.md)
- 2026-10-16 — [The ci-read actions/runs read has a time bound (BH-6346)](2026-10-16-BH-6346-ci-read-bound.md)
- 2026-10-15 — [Lane-run machines: name the head-read error, check fleet repos at start, refuse unreadable repos at claim (BH-6942)](2026-10-15-BH-6942-lane-run-repo-check.md)
- 2026-10-15 — [Pre-queue verdicts: reuse by impact set, adopt a run from any worker, seed the batch-fail suites (BH-6924)](2026-10-15-BH-6924-prequeue-impact-reuse.md)
- 2026-10-15 — [A machine's conductor rebase as a queued pool job (BH-6888 C0, BH-6881.4)](2026-10-15-BH-6888-conductor-remote-spawn.md)
- 2026-10-15 — [Project lease with a fence token (BH-6883, BH-6881.1)](2026-10-15-BH-6883-project-lease.md)
- 2026-10-15 — [The conductor restamps stale schema fragments at queue time (BH-6842)](2026-10-15-BH-6842-schema-restamp.md)
- 2026-10-15 — [Lane-run machines run current code; a non-zero run is `failed` (BH-6817)](2026-10-15-BH-6817-lane-run-fresh-code.md)
- 2026-10-15 — [The head-lag branch-tip read has a time bound (BH-6810)](2026-10-15-BH-6810-head-lag-read-bound.md)
- 2026-10-15 — [The project-3 pre-merge gate refuses a head whose Vercel preview failed (BH-6501)](2026-10-15-BH-6501-project-3-preview-gate.md)
- 2026-10-15 — [A data-lane-only review BLOCK keeps its branch as a draft PR (BH-6467)](2026-10-15-BH-6467-data-lane-draft-rereview.md)
- 2026-10-14 — [The rebase train runs the caller check before it rebinds the approval (BH-6718)](2026-10-14-BH-6718-rebase-train-caller-check.md)
- 2026-10-14 — [Culprit reach uses the batch select; a non-test workflow edit selects (BH-6688)](2026-10-14-BH-6688-infra-path-reach.md)
- 2026-10-14 — [A slow read in the head-lag span is held, not paged (BH-6670)](2026-10-14-BH-6670-step-held.md)
- 2026-10-14 — [A lead|human post sends client level 4, and an old lib is named (BH-6617)](2026-10-14-BH-6617-client-level-4.md)
- 2026-10-14 — [A step-timeout kill reports the call trace (BH-6603)](2026-10-14-BH-6603-step-timeout-calls.md)
- 2026-10-14 — [The conductor's flags/MODE block lives in bin/lib/mc/tick-scope.sh (BH-6518)](2026-10-14-BH-6518-conductor-tick-mode-cut.md)
- 2026-10-14 — [The conductor's full-tick window lives in bin/lib/mc/tick-scope.sh (BH-6518)](2026-10-14-BH-6518-conductor-full-tick-window-cut.md)
- 2026-10-14 — [Merge-conductor per-PR workers on lane-run machines (BH-6495, BH-6047.5)](2026-10-14-BH-6495-conductor-fly.md)
- 2026-10-14 — [Merge-conductor state: one attempt read per repo per tick, and the fresh-hub drill (BH-4156)](2026-10-14-BH-4156-mc-batch-read-drill.md)
- 2026-10-13 — [A MERGE verdict dismisses the bot BLOCK review on the same head (BH-6548)](2026-10-13-BH-6548-same-head-dismiss.md)
- 2026-10-13 — [The stack-wait gate reads the parent PR state, not the parent branch (BH-6537)](2026-10-13-BH-6537-parent-pr-state.md)
- 2026-10-13 — [A human step done on a REVIEW_BLOCKED ticket re-reviews the built branch (BH-6536)](2026-10-13-BH-6536-human-step-rereview.md)
- 2026-10-13 — [The conductor's keyed-tick parse lives in bin/lib/mc/tick-scope.sh (BH-6518)](2026-10-13-BH-6518-conductor-tick-scope-cut.md)
- 2026-10-13 — [Main-red: re-check flagged repos every 5 minutes (BH-6502)](2026-10-13-BH-6502-main-red-recheck.md)
- 2026-10-13 — [A conductor worker traces its calls, and the head-lag refs read happens once per tick (BH-6462)](2026-10-13-BH-6462-head-lag-cost.md)
- 2026-10-13 — [The autoenqueue ledger read retries on a 2 s / 5 s / 10 s ladder and names its cause (BH-6433)](2026-10-13-BH-6433-ledger-read-backoff.md)
- 2026-10-13 — [Box merge queue re-checks CI, reviewed sha and park state before every merge (BH-6428)](2026-10-13-BH-6428-merge-queue-red-guard.md)
- 2026-10-13 — [A child slice builds on an open parent only with a disjoint Stack section (BH-6389)](2026-10-13-BH-6389-stack-wait.md)
- 2026-10-13 — [BH-6374 C1: sibling parts by board key, pool stacking, squash-base merge, replay](2026-10-13-BH-6374-sibling-parts-c1.md)
- 2026-10-13 — [A conductor worker step has its own timeout and logs STEP lines (BH-6351)](2026-10-13-BH-6351-step-timeout.md)
- 2026-10-13 — [The WORKER_DEADLINE Sentry event names the step and carries pr, worker_key and deadline_secs (BH-6347)](2026-10-13-BH-6347-deadline-tags.md)
- 2026-10-13 — [A conductor worker names its step at a deadline kill, stops at a 401, and caps its lock waits (BH-6346)](2026-10-13-BH-6346-conductor-worker-steps.md)
- 2026-10-13 — [A batch that failed only on a no-verdict shard re-queues its PR once (BH-6336)](2026-10-13-BH-6336-no-verdict-retry.md)
- 2026-10-13 — [The conductor carries a lead MERGE across a clean main merge (BH-6291)](2026-10-13-BH-6291-lead-carry.md)
- 2026-10-13 — [The shipped console gets a browser QA run after each Pages deploy (BH-5909, slice 3)](2026-10-13-BH-5909-console-postmerge-qa.md)
- 2026-10-13 — [2026-10-13 — BH-5373: the impact map's two fixes (the culprit flip waits)](2026-10-13-BH-5373-culprit-flip.md)
- 2026-10-13 — [Lead protected paths are read from the DB rows; the TSV is only a seed now (BH-4148, slice 4 of BH-4140)](2026-10-13-BH-4148-lead-protected-paths-db.md)
- 2026-10-12 — [Pre-queue gate: learned suites, the trace, and fresh against main (BH-6335)](2026-10-12-BH-6335-prequeue-learned-trace-fresh.md)
- 2026-10-12 — [Silent stalls alert or self-clear: dead HOLDs, finished tickets kept open, hard Blocked-by on a stale parent (BH-6308)](2026-10-12-BH-6308-silent-stalls.md)
- 2026-10-12 — [Every queue ejection records its cause, and a requeue waits for a pre-queue run (BH-6161)](2026-10-12-BH-6161-eject-cause-requeue-gate.md)
- 2026-10-11 — [worker/jobs/schema.sql leaves git (BH-6005.4, #6011)](2026-10-11-BH-6005-schema-sql-untracked.md)
- 2026-10-11 — [A conflict only in a generated file is regenerated, never parked (BH-6000 part 1)](2026-10-11-BH-6000-regenerate-generated-conflicts.md)
- 2026-10-11 — [A PR the merge queue ejected twice gets its fix round now, with the two failing batch runs (BH-6000 part 5)](2026-10-11-BH-6000-eject-fix-now.md)
- 2026-10-11 — [The backstop starts one run per PR; READY past TTL is re-kicked; any failed diff read is scanned from git (BH-6000 parts 2-4)](2026-10-11-BH-6000-backstop-per-pr.md)
- 2026-10-11 — [A console UI PR without QA: PASS on its head gets a lead BLOCK (BH-5909, slice 2)](2026-10-11-BH-5909-console-qa-gate.md)
- 2026-10-11 — [Console PRs get a preview deploy and browser QA before merge (BH-5909, slice 1)](2026-10-11-BH-5909-console-preview-qa.md)
- 2026-10-11 — [The in-build grace holds a medium head only while a build job is live on it (BH-5740)](2026-10-11-BH-5740-inbuild-grace-build-job.md)
- 2026-10-11 — [Pre-queue invariants: render-doc-sections and the jobs-worker schema tests (BH-5591)](2026-10-11-BH-5591-prequeue-generated-checks.md)
- 2026-10-11 — [The merge conductor reacts to PR events; the full tick is an hourly sweep (BH-5521)](2026-10-11-BH-5521-conductor-event-driven.md)
- 2026-10-11 — [Splits stop building long serial PR chains (BH-5520)](2026-10-11-BH-5520-split-chains.md)
- 2026-10-10 — [A merged slice files the rest of its issue (BH-5961)](2026-10-10-BH-5961-slice-remainder.md)
- 2026-10-10 — [One run per project: the shared per-project lane runner (BH-5913)](2026-10-10-BH-5913-project-lanes.md)
- 2026-10-10 — [The pre-queue gate renders catalog/lanes.json before its rows share a checkout (BH-5775)](2026-10-10-BH-5775-prequeue-render-race.md)
- 2026-10-10 — [Merge-queue reconciler lane (BH-5670)](2026-10-10-BH-5670-merge-queue-reconcile.md)
- 2026-10-10 — [BH-5006: close-out of scopes 1, 2 and 4, and the Acceptance 1 probe](2026-10-10-BH-5006-remaining-scopes.md)
- 2026-10-09 — [A culprit head is never requeued; only a new head clears it (BH-5819)](2026-10-09-BH-5819-ejected-never-requeued.md)
- 2026-10-09 — [A stacked child follows its moving parent; a conflicting head is not reviewed (BH-5796)](2026-10-09-BH-5796-stacked-parent-follow.md)
- 2026-10-09 — [A slow human_verdict_mode read no longer fails a verdict read, and the land lane retries a 503 post (BH-5773)](2026-10-09-BH-5773-verdicts-mode-cache.md)
- 2026-10-09 — [A BLOCKed parent PR with approved children gets the next fix round (BH-5741)](2026-10-09-BH-5741-parent-blocked-priority.md)
- 2026-10-09 — [Merge-queue stage rows, bisect, the waiting line and the per-PR track (BH-5669)](2026-10-09-BH-5669-queue-stages.md)
- 2026-10-09 — [An invariant red posts its evidence on the PR (BH-5439)](2026-10-09-BH-5439-prequeue-invariant-comment.md)
- 2026-10-09 — [The risk tier signs off rules-text-only PRs (BH-5325)](2026-10-09-BH-5325-rules-text-lane.md)
- 2026-10-08 — [The pre-queue gate reuses a fresh verdict when main moves (BH-5572)](2026-10-08-BH-5572-prequeue-reuse.md)
- 2026-10-08 — [A stacked child merges its open parent branch (BH-5519)](2026-10-08-BH-5519-stack-parent-merge.md)
- 2026-10-08 — [One full conductor tick per project; the autoenqueue ledger read retries once (BH-5463)](2026-10-08-BH-5463-full-tick-lock-ledger-retry.md)
- 2026-10-08 — [Break-risk score routes risky PRs to a size-1 solo queue (BH-5430)](2026-10-08-BH-5430-queue-solo-lane.md)
- 2026-10-08 — [The pre-queue gate runs the whole-repo invariant suites (BH-5438, #5429 child 0)](2026-10-08-BH-5429-prequeue-invariants.md)
- 2026-10-08 — [Turn a pre-queue invariant off, or rebudget it, from a settings row (BH-5440, #5429 child 2)](2026-10-08-BH-5429-invariant-overrides.md)
- 2026-10-08 — [The conductor names every Mergify batch reset and whether it was avoidable (BH-5372)](2026-10-08-BH-5372-batch-reset-classifier.md)
- 2026-10-07 — [Stacked children carry a rewritten parent: restack by patch-id, never rewrite a parent with children (BH-5234)](2026-10-07-BH-5234-stale-parent.md)
- 2026-10-07 — [Source files are held to structural checks, not line limits (BH-5228)](2026-10-07-BH-5228-structural-checks-not-line-limits.md)
- 2026-10-07 — [Direction is not a take-over, and a resolver hand-off acts, says why not, or pages (BH-5125)](2026-10-07-BH-5125-direction-handoff.md)
- 2026-10-07 — [Jev, a second opinion on the risk tier, in shadow only (BH-5024)](2026-10-07-BH-5024-jev-risk-shadow.md)
- 2026-10-07 — [A medium-risk PR gets its lead-grade review inside the build (BH-5023)](2026-10-07-BH-5023-inbuild-lead-review.md)
- 2026-10-07 — [A rule-based risk tier signs off low-risk PR heads (BH-5022)](2026-10-07-BH-5022-risk-tier.md)
- 2026-10-07 — [Per-flip evidence runner and the STATE PATHS panel (BH-5000, slice C0)](2026-10-07-BH-5000-state-flip-evidence.md)
- 2026-10-07 — [A red daily full run reverts its culprit through the hotfix lane and files the map gap (BH-4981)](2026-10-07-BH-4981-main-red-autorevert.md)
- 2026-10-07 — [2026-10-07 — BH-4980: eject the culprit, don't bisect (shipped in shadow)](2026-10-07-BH-4980-eject-culprit.md)
- 2026-10-07 — [The merge conductor works out each PR's impact lane, and Mergify parallel lanes ship dark (BH-4979)](2026-10-07-BH-4979-queue-impact-lanes.md)
- 2026-10-06 — [Archie's second playbook: the data lane (BH-4927, BH-4920.4)](2026-10-06-BH-4927-archie-data-lane.md)
- 2026-10-06 — [One slow PR worker is killed alone, and a READY row always says why (BH-4918)](2026-10-06-BH-4918-merge-path-stall.md)
- 2026-10-06 — [A head-moved merge_pr refusal frees its command key on every entry point (BH-4917)](2026-10-06-BH-4917-merge-pr-release-every-path.md)
- 2026-10-06 — [A conductor worker killed before fan-in says why, and a PR missing twice is worked alone](2026-10-06-BH-4842-fanin-solo.md)
- 2026-10-06 — [Archie, factory manager: stacks of three, the cap by action, killed ticks (BH-4784)](2026-10-06-BH-4784-archie-fm-stacks.md)
- 2026-10-05 — [BH-4641: the rebase lane union-resolves append-only conflicts](2026-10-05-BH-4641-union-append.md)
- 2026-10-05 — [BH-4596: an approval rebound to a moved head republishes the lead-verdict status](2026-10-05-BH-4596-rebind-publishes-status.md)
- 2026-10-05 — [BH-4585 (BH-4574.3): Archie's rebase-repair playbook](2026-10-05-BH-4585-archie-fm-playbooks.md)
- 2026-10-05 — [Archie, queue doctor: batch culprits, unqueued approvals, stale conductor rows (BH-4584, wave 2 of #4574)](2026-10-05-BH-4584-archie-fm-queue.md)
- 2026-10-05 — [Archie, factory manager: one stuck-PR playbook (BH-4583, wave 1 of #4574)](2026-10-05-BH-4583-archie-fm-tracer.md)
- 2026-10-05 — [Approved external PRs reach the merge queue (BH-4580, BH-4572.1)](2026-10-05-BH-4580-external-enqueue.md)
- 2026-10-05 — [The tier stops deciding who merges: tier_gate_mode (BH-4579, tracer of BH-4572)](2026-10-05-BH-4579-tier-gate-mode.md)
- 2026-10-05 — [Rules and prompts drop the human seat, with a lint (BH-4582, BH-4572.3)](2026-10-05-BH-4572-tier-retired.md)
- 2026-10-05 — [BH-4562: a PR Mergify merged is never logged EJECTED and parked BLOCKED](2026-10-05-BH-4562-merged-not-ejected.md)
- 2026-10-05 — [A failed batch is re-run one member at a time (BH-4550, #4545 child 4)](2026-10-05-BH-4550-batch-solo-rerun.md)
- 2026-10-05 — [The pre-queue gate runs on the CI pool (BH-4548, #4545 child 2)](2026-10-05-BH-4548-prequeue-dispatch.md)
- 2026-10-05 — [The pre-queue isolation gate, tracer slice (BH-4545 / BH-4547)](2026-10-05-BH-4545-prequeue-isolation.md)
- 2026-10-05 — [BH-3933: every open PR gets an owner (BH-3929.1)](2026-10-05-BH-3933-pr-owner-enroll.md)
- 2026-10-04 — [BH-4497: a dependency-held READY PR says when it is released, and its STUCK page reads the gate live](2026-10-04-BH-4497-dep-hold-release.md)
- 2026-10-04 — [BH-4474: an iron-law acceptance carries to a new head when the hits are unchanged](2026-10-04-BH-4474-ironlaw-carry.md)
- 2026-10-04 — [A human MERGE verdict row on the live head lifts a bot's comment BLOCK (BH-4468)](2026-10-04-BH-4468-human-verdict-lifts-bot-block.md)
- 2026-10-04 — [A full hub /tmp now says so, and the patch-id rebind stops leaking askpass files (BH-4464)](2026-10-04-BH-4464-hub-tmp-rebase-diagnosis.md)
- 2026-10-04 — [A head-moved merge_pr refusal no longer holds the command key once the moved head is re-reviewed (BH-4439)](2026-10-04-BH-4439-merge-pr-head-rekey.md)
- 2026-10-04 — [A PR Mergify did not name goes back in after a batch ejection (BH-4428)](2026-10-04-BH-4428-batch-eject-bystander.md)
- 2026-10-04 — [The blocked-resolver has no terminal that waits on a person (BH-4149)](2026-10-04-BH-4149-no-person-terminal.md)
- 2026-10-03 — [A stacked child whose parent has no PR is retargeted, and an orphan retarget owes a re-review (BH-3950, part 3 of BH-3943)](2026-10-03-BH-3950-stack-orphan-none-arm.md)
- 2026-10-03 — [A BLOCK that only says "CI did not run" clears itself when CI is green (BH-3934)](2026-10-03-BH-3934-block-ci-clear.md)
- 2026-10-03 — [Worker deploys move off the hub; the hub token proves it cannot write (BH-3905)](2026-10-03-BH-3905-deploy-off-hub.md)
- 2026-10-03 — [dequeue-watch ships dark and reports once (BH-3859)](2026-10-03-BH-3859-dequeue-watch-ship-dark.md)
- 2026-10-02 — [The merge-queue freeze dispatches its workflow on main once (BH-3891, part 4 of BH-3886)](2026-10-02-BH-3891-main-red-queue-self-dispatch.md)
- 2026-10-02 — [Merge-queue batch attribution (BH-3890, part 3 of BH-3886)](2026-10-02-BH-3890-main-red-queue-attr.md)
- 2026-10-02 — [The merge-queue arm's hooks, flag lines and knobs (BH-3888, part 1 of BH-3886)](2026-10-02-BH-3888-main-red-queue-hooks.md)
- 2026-10-02 — [The merge-queue freeze thaws on finished greens and green main pushes (BH-3889, part 2 of BH-3886)](2026-10-02-BH-3886-main-red-queue-thaw.md)
- 2026-10-02 — [Foreign-red attribution follow-ups: hub checkout, a later batch must have run the suite, cached reads, strict parse (BH-3857)](2026-10-02-BH-3857-foreign-red-hub-checkout.md)
- 2026-10-02 — [Enforce mode stops lead-token "human" rows standing; an unreadable mode fails closed (BH-3849)](2026-10-02-BH-3849-enforce-standing-fail-closed.md)
- 2026-10-02 — [A human verdict, and the switches that trust one, are signed by the worker (BH-3846)](2026-10-02-BH-3846-human-verdict-signature.md)
- 2026-10-01 — [A source=human verdict is proven by its own token, not the shared lead token (BH-3831)](2026-10-01-BH-3831-human-verdict-token.md)
- 2026-10-01 — [A newer human MERGE on the exact head overrides the conductor's own re-review BLOCK (BH-3814)](2026-10-01-BH-3814-human-verdict-overrides-rereview.md)
- 2026-10-01 — [A withheld lead-verdict stops every enqueue caller, and unqueues rows labelled before the gate (BH-3806)](2026-10-01-BH-3806-nhv-other-callers.md)
- 2026-10-01 — [The conductor's CI writes check the PR's live head first (BH-3804)](2026-10-01-BH-3804-ci-writes-live-head.md)
- 2026-10-01 — [A rerun never sees the fixed workflow: close/reopen instead (BH-3787)](2026-10-01-BH-3787-ci-timeout-rekick.md)
- 2026-10-01 — [The CI timeout budget fires: one repo page, no doomed rerun (BH-3786)](2026-10-01-BH-3786-ci-timeout-budget-alert.md)
- 2026-10-01 — [A lead BLOCK gets a fix round; the same finding twice, or a needs-human finding, holds the ticket (BH-3780)](2026-10-01-BH-3780-lead-block-fix-round.md)
- 2026-10-01 — [A lead-cleared head reaches the merge queue, and one that does not pages (BH-3778)](2026-10-01-BH-3778-lead-merge-enqueue.md)
- 2026-10-01 — [A withheld lead-verdict is NEEDS_HUMAN_VERDICT, not QUEUED (BH-3777)](2026-10-01-BH-3777-needs-human-verdict.md)
- 2026-10-01 — [A PR ejected from a red Mergify batch it did not break is re-queued once (BH-3776)](2026-10-01-BH-3776-foreign-red-requeue.md)
- 2026-10-01 — [A job that dies at its timeout is a repo problem, not a flake (BH-3775)](2026-10-01-BH-3775-ci-timeout-budget.md)
- 2026-09-30 — [dequeue-watch acts once per (PR, head, class), bounds its fix rounds, and has an LLM fallback (BH-3729)](2026-09-30-BH-3729-dequeue-watch-act-llm.md)
- 2026-09-30 — [The dequeue-watch lane is on (BH-3719, built in BH-3730)](2026-09-30-BH-3719-dequeue-watch.md)
- 2026-09-30 — [Post-merge verify: prod serves the sha we merged (BH-3690, slice C0)](2026-09-30-BH-3690-post-merge-verify.md)
- 2026-09-30 — [The hub lead-review lane is the verdict authority; protected paths need a human (BH-3683)](2026-09-30-BH-3683-lead-authority.md)
- 2026-09-29 — [A stale Mergify dequeue is requeued once a fresh verdict binds the new head (BH-3480)](2026-09-29-BH-3480-stale-dequeue-requeue.md)
- 2026-09-29 — [Lead review precision: a daily score of lead MERGEs that went wrong (BH-3548, BH-3479.4)](2026-09-29-BH-3479-precision.md)
- 2026-09-29 — [The land lane posts a lead BLOCK's findings to the PR, and samples MERGE verdicts for a spot-check (BH-3479.3, BH-3547)](2026-09-29-BH-3479-land-block-spotcheck.md)
- 2026-09-29 — [Lead review auto-request: the hub trigger lane (BH-3479.1, BH-3545)](2026-09-29-BH-3479-enqueue.md)
- 2026-09-29 — [Lead review contract: knobs, the Lead-Lane trailer, the findings marker and the rules-pack section (BH-3479.0, BH-3544)](2026-09-29-BH-3479-contract.md)
- 2026-09-29 — [Lead review: a versioned checklist, the ticket thread, and the rules pack first (BH-3479.2, BH-3546)](2026-09-29-BH-3479-checklist-rules-pack.md)
- 2026-09-29 — [Conductor holds hand themselves to mc_hold_comment (BH-3456, BH-3436.4)](2026-09-29-BH-3456-hold-comment-sites.md)
- 2026-09-29 — [The merge conductor can post one hold comment per PR and kind (BH-3455)](2026-09-29-BH-3455-hold-comment.md)
- 2026-09-29 — [The wake loop owes a conductor run it could not launch, and a checks wake's sha names its PR](2026-09-29-BH-3453-wake-owed-sha-keys.md)
- 2026-09-29 — [Merge conductor keyed backstop, every 5 minutes (BH-3436.2 / BH-3454)](2026-09-29-BH-3436-conductor-backstop.md)
- 2026-09-29 — [Mergify requires a head-bound `lead-verdict` status (BH-3348)](2026-09-29-BH-3348-lead-verdict-status.md)
- 2026-09-28 — [The console /merge-queue screen (BH-3158, BH-2325.3)](2026-09-28-BH-3158-merge-queue-screen.md)
- 2026-09-28 — [The coord proxy admits the merge-queue PATCH and the held-page release (BH-3157)](2026-09-28-BH-3157-proxy-writes.md)
- 2026-09-28 — [Merge-queue PATCH and held-page release write an audit row (BH-3156, BH-2325.1)](2026-09-28-BH-3156-worker-audit.md)
- 2026-09-27 — [sweepstall watches the merge conductor, and a held READY row says why](2026-09-27-SWEEPSTALL-conductor-reason.md)
- 2026-09-27 — [Rows first: every-tick pr-state rehydrate and the held-page read](2026-09-27-BH-2311.4-rows-first-rehydrate-held.md)
- 2026-09-27 — [Conductor, queue and tier2 attempt kinds go through the verbs](2026-09-27-BH-2311.3-callsite-kinds-verbs.md)
- 2026-09-27 — [Attempt ledger and land watermark: rows first](2026-09-27-BH-2311.1-attempts-rows-first.md)
- 2026-09-26 — [Review savings: a cheap route for trivial diffs, and every skipped review is counted](2026-09-26-BH-2545-review-savings.md)
- 2026-09-26 — [The hub queues fix rounds as rows and adopts their results (BH-2674, BH-2530.3)](2026-09-26-BH-2530-fix-round-queue.md)
- 2026-09-26 — [Attempt-ledger verbs: the contract](2026-09-26-BH-2311.0-attempt-verbs.md)
- 2026-09-25 — [A sliced master loses ai-build, and the hotfix close asks the guard](2026-09-25-BH-2508-slice-strip.md)
- 2026-09-25 — [The merge close-out leaves a sliced issue open](2026-09-25-BH-2477-slice-aware-closeout.md)
- 2026-09-25 — [merge-sweep enumerates builds of record from the ledger (BH-2312.1)](2026-09-25-BH-2312-builds-of-record-merge-sweep.md)
- 2026-09-25 — [Blocked resolver reads builds of record from the ledger (BH-2312.2)](2026-09-25-BH-2312-builds-of-record-blocked-resolver.md)
- 2026-09-25 — [Conductor markers and detached jobs as pr_attempts rows](2026-09-25-BH-2311.2-markers-jobs-kinds.md)
- 2026-09-25 — [A head that moved without its patch changing keeps its verdict, with no new review](2026-09-25-BH-2310-verdict-replay.md)
- 2026-09-25 — [Mergify refuses a PR with a standing change request, and an unreadable probe holds](2026-09-25-BH-2275-mergify-followups.md)
- 2026-09-25 — [The Project page's auto-merge toggle turns off one board, not the fleet](2026-09-25-2322-automerge-per-project.md)
- 2026-09-24 — [The conductor's ownership map is fragments, not one shared file](2026-09-24-LANE-E-mc-expected-map-fragments.md)
- 2026-09-24 — [Approved, CLEAN PRs enqueue in the tick they become READY](2026-09-24-LANE-D-merge-flow-enqueue.md)
- 2026-09-24 — [A red CI gets two repair rounds per branch, then a decision request](2026-09-24-LANE-D-ci-repair-cap.md)
- 2026-09-24 — [A refused console merge acks as a terminal refusal, never as a merge](2026-09-24-BH-932-refusal-ack-terminal.md)
- 2026-09-24 — [A PR the blocked-resolver closes unmerged moves its console build row to `superseded` or `abandoned`](2026-09-24-BH-389-resolver-closed-row.md)
- 2026-09-24 — [BH-2247: a zombie pid is a dead run to the fan-in check](2026-09-24-BH-2247-fanin-zombie.md)
- 2026-09-24 — [A directory is never a conf file, and a test that creates /nonexistent is a trace-safety hit](2026-09-24-BH-2210-nonexistent-path.md)
- 2026-09-24 — [A lead CHANGES_REQUESTED survives main merges, and a silent Mergify queue holds](2026-09-24-BH-2199-conductor-gates.md)
- 2026-09-24 — [The review lane's APPROVE is the App's, and it supersedes the lane's own stale blocking review](2026-09-24-BH-2119-review-prs-app-approve.md)
- 2026-09-24 — [BH-594 changed what conductor-sticky-handoff #438 expects; its old coverage moved to #439](2026-09-24-BH-2038-bh594-sticky-handoff-test-change.md)
- 2026-09-24 — [A jobs-worker outage no longer reads as "never kicked" in the head-lag check](2026-09-24-BH-1891-head-lag-outage-rc.md)
- 2026-09-24 — [The merge conductor and reconcile-prs account for every PR they enumerate](2026-09-24-BH-186-fanin.md)
- 2026-09-24 — [The keyed conductor launch folds case on both sides](2026-09-24-BH-1841-conductor-key-case.md)
- 2026-09-24 — [A keyed conductor tick loads the held-page cache, so a woken PR's held row waits for the flush](2026-09-24-BH-1840-keyed-tick-held-load.md)
- 2026-09-24 — [The BH-1677 / BH-1670 attempt sites go through the row helpers](2026-09-24-BH-1839-eject-sites-row-helpers.md)
- 2026-09-24 — [The attempt row read is memoised per tick, and one outage latches the tick](2026-09-24-BH-1831-attempt-tick-memo.md)
- 2026-09-24 — [The lanes honour pauses](2026-09-24-BH-1684-lanes-honor-pauses.md)
- 2026-09-24 — [The head-lag record is `headlag` rows, and a held verdict is cached per tip](2026-09-24-BH-1564-head-lag-rows.md)
- 2026-09-24 — [Lead review promotion lane, and the box-file verdict retired (BH-1951, BH-1525.3)](2026-09-24-BH-1525-lead-review-job.md)
- 2026-09-24 — [The harness regenerates the Prisma client on the prisma/schema/ folder layout too](2026-09-24-BH-1171-prisma-schema-folder.md)
- 2026-09-24 — [docs/notes/INDEX.md conflicts resolve by regeneration](2026-09-24-BH-1162-index-regenerated-on-conflict.md)
- 2026-09-24 — [Agent commits carry the box's git identity, and nothing else gets pushed](2026-09-24-BH-1134-commit-author.md)
- 2026-09-23 — [The dep gate's reads are ledgered, and an issue is read once per conductor tick](2026-09-23-BH-1735-pdg-tick-memo.md)
- 2026-09-23 — [Stacked-child restacks: knobs, parents merged outside the conductor, and delete order](2026-09-23-BH-1715-stack-follow-followups.md)
- 2026-09-23 — [Builds stop committing the files the conductor regenerates on merge](2026-09-23-BH-1680-generated-no-commit.md)
- 2026-09-23 — [BH-1678: the merge queue follows the child issue's Blocked-by and Order](2026-09-23-BH-1678-ticket-order-hold.md)
- 2026-09-23 — [BH-1677: a Mergify base-conflict ejection is rebased, not struck](2026-09-23-BH-1677-eject-rebase.md)
- 2026-09-23 — [BH-1676: the BH-1669 contract ships inert (two knobs, two stubs, a vocabulary)](2026-09-23-BH-1676-eject-rebase-contract.md)
- 2026-09-23 — [The conductor counts red per head, never across heads](2026-09-23-BH-1671-red-counted-per-head.md)
- 2026-09-23 — [A parent the conductor merges now restacks its stacked children](2026-09-23-BH-1670-stacked-child-restack.md)
- 2026-09-23 — [A reviewed, green tier-2 PR on a Mergify repo enqueues itself](2026-09-23-BH-1668-tier2-autoenqueue.md)
- 2026-09-23 — [A PR whose merge state stays unreadable now pages once, and gh-quota F3 notices a lost diff read](2026-09-23-BH-1634-unverifiable-streak-alert.md)
- 2026-09-23 — [The closed-unmerged settle reads the harness's own PR records, not the repo's closed list](2026-09-23-BH-1592-closed-settle-own-records.md)
- 2026-09-23 — [The conductor's attempts go through the row helpers, and a wake can key a tick](2026-09-23-BH-1387-conductor-rows-keyed-tick.md)
- 2026-09-22 — [2026-09-22 — BH-426: a GitHub quota gauge, an alert at 20 percent, and a counter](2026-09-22-BH-426-gh-quota-gauge.md)
- 2026-09-22 — [The conductor stops making the same GitHub read twice](2026-09-22-BH-1486-conductor-read-memo.md)
- 2026-09-22 — [BH-1468: `bin/blocked-resolver.sh` grows an optional-module seam, and four counters on the tick line](2026-09-22-BH-1468-opt-hooks.md)
- 2026-09-22 — [BH-1457 — the resolver spends nothing on finished rows, spends cheap first, and stops](2026-09-22-BH-1457-prepass-and-bounded-tick.md)
- 2026-09-22 — [The main-red detector can see a red main during a merge burst, and a PR pair can now hold merges](2026-09-22-BH-1451-main-red-burst-backwalk.md)
- 2026-09-22 — [The merge conductor's hub cron line fires every 30 minutes, not every 5](2026-09-22-BH-1389-conductor-cadence.md)
- 2026-09-22 — [The hub's merge-sweep cron line is retired, and two readers stop depending on files only one box has](2026-09-22-BH-1388-sweep-line-retired.md)
- 2026-09-22 — [BH-1385 (BH-1025.0): pr_state_events / pr_attempts, the client verbs, the conductor helpers](2026-09-22-BH-1385-pr-rows-contract.md)
- 2026-09-22 — [The gh_rest ETag counter file is swept, trapped, and the byte cap counts bytes](2026-09-22-BH-1322-gh-etag-counter-leak.md)
- 2026-09-22 — [BH-1302: `bin/lib/mc/locks.sh` finally has a suite that names it](2026-09-22-BH-1302-locks-suite.md)
- 2026-09-22 — [The review lane's verdict write keeps the `.ledger_sha` watermark](2026-09-22-BH-1289-verdict-write-keeps-watermark.md)
- 2026-09-22 — [2026-09-22 — BH-1285 merge pause / train / stacked guards](2026-09-22-BH-1285-merge-pause-guards.md)
- 2026-09-22 — [BH-1254: the hub MCP `pr` tool served #1212's real GitHub body; the body itself had been overwritten](2026-09-22-BH-1254-mcp-pr-body-was-github-body.md)
- 2026-09-22 — [One suite per module: `tests/blocked-resolver-test.sh` split seven ways, one shared fixture lib](2026-09-22-BH-1196-one-suite-per-module.md)
- 2026-09-22 — [BH-1026.0 (BH-1364): the queues-are-rows contract — three dark knobs, one shared active-key read](2026-09-22-BH-1026-queues-are-rows.md)
- 2026-09-21 — [gh_rest caches ETags and answers 304s from the cache](2026-09-21-BH-1295-gh-rest-etag.md)
- 2026-09-20 — [A park that cannot be resolved stops spending rungs, the oldest hand-off goes first, and a saturated lane says so once](2026-09-20-BH-1122-resolver-saturation.md)
- 2026-09-19 — [BH-998 — the conductor's head-bound re-review resolves its review model](2026-09-19-BH-998-rereview-review-model.md)
- 2026-09-19 — [BH-989 — the review lane reads the standing-review ledger only when the local cache cannot answer](2026-09-19-BH-989-review-lane-followups.md)
- 2026-09-19 — [An identity-blocked conductor row stops paging the budget and the TTL, and stops calling itself "waiting on a required check"](2026-09-19-BH-988-identity-blocked-not-paged.md)
- 2026-09-19 — [The main-red test-only exemption no longer depends on the cwd, and a landing pass re-reads the flag](2026-09-19-BH-987-main-red-gate-cwd-and-landing-memo.md)
- 2026-09-19 — [A reaped `RB-` stand-down fails the hub job file, and the ALERTS line stops overstating recovery](2026-09-19-BH-986-rb-alert-recovery-claim.md)
- 2026-09-19 — [The resolver's tick rotates across projects, says which ones it visited, and pages for one it has ignored for an hour](2026-09-19-BH-980-resolver-tick-fairness.md)
- 2026-09-19 — [A red-CI park merges main once more before the resolver buys an agent](2026-09-19-BH-970-resolver-regenerate-rung.md)
- 2026-09-19 — [The rebuild ledger's contract: row fields, `queue_row`, and two key-cache hooks](2026-09-19-BH-946-rebuild-ledger-contract.md)
- 2026-09-19 — [The main-red freeze reaches every merge lane, from the shared flag store](2026-09-19-BH-945-main-red-every-lane.md)
- 2026-09-19 — [The resolver's tick is spread across projects, and a project can be given a share](2026-09-19-BH-870-resolver-fairness.md)
- 2026-09-19 — [A merge to main re-offers a rebase to every open main-based PR](2026-09-19-BH-870-land-rebase.md)
- 2026-09-19 — [2026-09-19 — BH-784: the merge family's decision reads go through REST, and a limited read decides nothing](2026-09-19-BH-784-merge-family-reads-rest.md)
- 2026-09-19 — [The pool's PR_CREATED gate and seven close-out writers read GitHub over REST](2026-09-19-BH-781-decision-closeouts-read-rest.md)
- 2026-09-19 — [The ticket-key cache: a key `br_one` paid for is carried beside the row](2026-09-19-BH-487-ticket-key-cache.md)
- 2026-09-19 — [2026-09-19 — BH-1066: review-autopilot honours the agent-call rc, and stops posting twice](2026-09-19-BH-1066-review-autopilot-rc-honesty.md)
- 2026-09-19 — [2026-09-19 — BH-1047: the test-tamper gate learns that a stub flip is not a deletion](2026-09-19-BH-1047-stub-flip-not-deletion.md)
- 2026-09-19 — [2026-09-19 — BH-1037: agent-call.sh gets a choke point (the prompt ledger)](2026-09-19-BH-1037-agent-call-choke-guard.md)
- 2026-09-18 — [Every merge write goes over REST](2026-09-18-BH-892-merge-rest.md)
- 2026-09-18 — [A build whose PR never opened is owned end to end](2026-09-18-BH-614-pr-create-failed-owned.md)
- 2026-09-18 — [The hub half of REBASE_ON_POOL: enqueue, the `pool` job state, apply](2026-09-18-BH-541-pool-rebase-hub-half.md)
- 2026-09-18 — [The Changes-region check reads an empty region when a marker is missing](2026-09-18-BH-476-guardrail-region-fixes.md)
- 2026-09-18 — [Dated notes replace appending to the five contract docs](2026-09-18-BH-476-doc-notes-and-index.md)

## BUILD-CONCURRENCY

- 2026-10-18 — [Docker-pool host runner (BH-7347, slice C1 of #7300)](2026-10-18-BH-7347-docker-pool-runner.md)
- 2026-10-16 — [The pool never waits on a number we chose, and a machine-hour budget bounds the spend (BH-7190)](2026-10-16-BH-7190-pool-never-wait.md)
- 2026-10-14 — [A plan that shares a hot file with any open ticket PR is held (BH-6292)](2026-10-14-BH-6292-inflight-hotfile-hold.md)
- 2026-10-13 — [Six project loops on the per-project runner (BH-5944)](2026-10-13-BH-5944-project-loops-runner.md)
- 2026-10-11 — [Splits stop building long serial PR chains (BH-5520)](2026-10-11-BH-5520-split-chains.md)
- 2026-10-07 — [The plan-time overlap gate counts a hotspot a plan names only lightly (BH-5268)](2026-10-07-BH-5268-plan-overlap-hotspots.md)
- 2026-10-07 — [Pool machine reuse (BH-5025: slices BH-5025.0, .1, .2)](2026-10-07-BH-5046-pool-machine-reuse.md)
- 2026-10-07 — [A reused pool machine never hands a held build slot to the next build (BH-5021)](2026-10-07-BH-5021-pool-slot-clean.md)
- 2026-10-07 — [Cross-box claims read from the DB (BH-5002, BH-4951.3)](2026-10-07-BH-5002-claims-cross-box.md)
- 2026-10-03 — [In-app text dependencies: hold and release (BH-3946, slices BH-3963 and BH-3964)](2026-10-03-BH-3946-inapp-text-deps.md)
- 2026-09-30 — [A decomposition's dependent children launch stacked by default (BH-3684)](2026-09-30-BH-3684-stack-by-default.md)
- 2026-09-28 — [The overlap schedule stacks instead of deferring (BH-1174)](2026-09-28-BH-1174-overlap-stack.md)
- 2026-09-26 — [Fleet file claims: the two overlap readers read job_claims (BH-2524, BH-2630)](2026-09-26-BH-2524-file-claims-db.md)
- 2026-09-24 — [A plan's "## Sibling claims (not touched)" section is not its claim](2026-09-24-BH-623-sibling-claims-section.md)
- 2026-09-24 — [A `### Task` heading ends the skipped "## Sibling claims" section](2026-09-24-BH-1919-sibling-section-heading-end.md)
- 2026-09-23 — [Priority yield and lane reaper: the #717 review follow-ups](2026-09-23-BH-1142-yield-and-reaper-followups.md)
- 2026-09-23 — [Disk guard: alert at 85%, refuse to start a build at 92%](2026-09-23-BH-1123-disk-guard.md)
- 2026-09-22 — [BH-1300: a pool project's build ceiling can no longer drop in silence](2026-09-22-BH-1300-ceiling-drop-alert.md)
- 2026-09-22 — [2026-09-22 — BH-1285 merge pause / train / stacked guards](2026-09-22-BH-1285-merge-pause-guards.md)
- 2026-09-21 — [BH-1279: the schema seed no longer resurrects deleted repo/box caps, and a refused spawn no longer counts against the per-key spawn cap](2026-09-21-BH-1279-no-caps-seed.md)
- 2026-09-19 — [The rollout dispatch hook: a `## Rollout` master files its waves, it never plans](2026-09-19-BH-816-rollout.md)
- 2026-09-19 — [Four small ledger bugs: a stamp, a cursor, a stamp that outlived its rows, and a stale map](2026-09-19-BH-1042-small-ledger-bugs.md)
- 2026-09-19 — [A finished remote build reaches its box once: the ledger row is the dedupe key, and "could not ask" never relays](2026-09-19-BH-1041-remote-result-relay-once.md)
- 2026-09-19 — [A triage shard is deduped per TICKET, on a fingerprint persisted before the session is bought](2026-09-19-BH-1015-triage-shard-ticket-fp.md)
- 2026-09-18 — [The Changes-region check reads an empty region when a marker is missing](2026-09-18-BH-476-guardrail-region-fixes.md)
- 2026-09-18 — [Dated notes replace appending to the five contract docs](2026-09-18-BH-476-doc-notes-and-index.md)

## RUN-BUILD-GRAPH

- 2026-10-17 — [BH-6379 (BH-6372.1): the plan stage asks perf tickets for a target and a replay](2026-10-17-BH-6379-perf-plan-gate.md)
- 2026-10-14 — [The rebase train runs the caller check before it rebinds the approval (BH-6718)](2026-10-14-BH-6718-rebase-train-caller-check.md)
- 2026-10-13 — [The builder runs pr-self-check before it opens or edits the PR (BH-6393)](2026-10-13-BH-6393-builder-self-check-prepush.md)
- 2026-10-12 — [A running pool build yields at its next write point under HOLD (BH-6091)](2026-10-12-BH-6091-pool-hold-yield.md)
- 2026-10-10 — [Pool builds can read a second repo; a plan that cannot stops at PLAN (BH-5910)](2026-10-10-BH-5910-extra-read-repos.md)
- 2026-10-10 — [Design collisions at PLAN, and the caller list after the main merge (BH-5791)](2026-10-10-BH-5791-design-collisions.md)
- 2026-10-09 — [The lead review reads an oversize diff in parts; split required replaces the blind BLOCK (BH-5803)](2026-10-09-BH-5803-lead-review-diff-parts.md)
- 2026-10-09 — [A plan must cite the newest ticket comments (BH-5799)](2026-10-09-BH-5799-plan-thread-gate.md)
- 2026-10-08 — [BH-5526: a day spend cap never stops a ticket midway (slice C0)](2026-10-08-BH-5526-budget-never-midway.md)
- 2026-10-08 — [BH-5526: the cost autohalt holds new builds only, never in-flight work (slice C1)](2026-10-08-BH-5526-autohalt-holds-at-boundary.md)
- 2026-10-06 — [The size gate's limits are settings rows, 700 lines / 20 files by default (BH-4985)](2026-10-06-BH-4985-size-gate-settings.md)
- 2026-10-03 — [Every harness PR carries the Harness-Job / Harness-Ticket trailer (BH-4015, BH-3987 slice 2)](2026-10-03-BH-4015-pr-trailers-sites.md)
- 2026-10-03 — [Build PRs carry a Harness-Job / Harness-Ticket trailer (BH-3987, slice C0)](2026-10-03-BH-3987-pr-attribution.md)
- 2026-10-03 — [A split child gets a replan check once its blockers merge (BH-3955)](2026-10-03-BH-3955-replan-check.md)
- 2026-10-03 — [Decompose tracer-first: child 1 is an end-to-end path, siblings slice by capability (BH-3954)](2026-10-03-BH-3954-decompose-tracer-first.md)
- 2026-10-01 — [A lead BLOCK gets a fix round; the same finding twice, or a needs-human finding, holds the ticket (BH-3780)](2026-10-01-BH-3780-lead-block-fix-round.md)
- 2026-09-29 — [The rules pack runs in the pre-push gate, HARNESS_SUITE_RUN and the evidence table](2026-09-29-BH-3513-rules-pack-wiring.md)
- 2026-09-29 — [The child plan cost tripwire checker, cpt_check (BH-3496)](2026-09-29-BH-3496-child-plan-tripwire.md)
- 2026-09-29 — [Decompose composes and publishes one context pack per child (BH-3494)](2026-09-29-BH-3494-context-pack-compose.md)
- 2026-09-29 — [Context-pack wire, shell side, and the child plan tripwire hook (BH-3492)](2026-09-29-BH-3492-context-pack-wire.md)
- 2026-09-29 — [Decomposed and superseded builds end at an honest ledger stage (BH-3481.1)](2026-09-29-BH-3481.1-ledger-stages.md)
- 2026-09-29 — [The live-cost and build-tripwire seams: stub libs and their call sites (BH-3481.0)](2026-09-29-BH-3481.0-seams.md)
- 2026-09-29 — [A split child plans warm: delta pre-plan, child model route, `delta` cost tag (BH-3495)](2026-09-29-BH-3478-child-context-pack.md)
- 2026-09-29 — [The hub-probe request path: HUB_PROBE: lines from a build's own output (BH-3451)](2026-09-29-BH-3451-hub-probe-request-path.md)
- 2026-09-29 — [Needs-human release: a person's evidence reaches the next build (BH-3446)](2026-09-29-BH-3446-needs-human-release.md)
- 2026-09-29 — [The same-finding tripwire: two REVIEW_BLOCKED on one finding hold the issue (BH-3445)](2026-09-29-BH-3445-needs-human-tripwire.md)
- 2026-09-29 — [The needs-human classifier, review suffix and triage escalate hook (BH-3444)](2026-09-29-BH-3444-needs-human-classify.md)
- 2026-09-29 — [The waiting-on-human hold: the marker, the lane skip lines, the real placer (BH-3443)](2026-09-29-BH-3443-needs-human-hold.md)
- 2026-09-29 — [The needs-human contract: lib seams, stub placer, knob and hooks (BH-3442)](2026-09-29-BH-3442-needs-human-contract.md)
- 2026-09-29 — [Pool builds fetch their own pre-plan, every box publishes one, and the hit rate is watched (BH-3437)](2026-09-29-BH-3437-preplan-db-adopt.md)
- 2026-09-25 — [The pre-PR gate runs CI's orphan ratchet](2026-09-25-BH-2414-prepr-orphans.md)
- 2026-09-24 — [A held sweep no longer hides the board, and a deferral or an answered stub owes no close-out](2026-09-24-pool-sweep-wedge.md)
- 2026-09-24 — [run-build.sh runs its stages from bin/lib/rb/](2026-09-24-BH-572-run-build-cut.md)
- 2026-09-24 — [The pre-PR gate runs again on the head that opens the PR](2026-09-24-BH-2021-prepr-late-pass.md)
- 2026-09-24 — [An exhausted runner lane defers from every stage, and one cooled account no longer holds the project](2026-09-24-BH-1853-lane-exhausted-every-stage.md)
- 2026-09-24 — [The reopen rate's denominator is windowed to the same 14 days as its numerator](2026-09-24-BH-115-reopen-rate-window.md)
- 2026-09-23 — [BH-851 — the depth-1 split-child guard also reads the ticket body, and logs its decision](2026-09-23-BH-851-split-child-body-marker.md)
- 2026-09-23 — [The build runs CI's two deterministic gates before it opens its PR](2026-09-23-BH-1706-prepr-gate.md)
- 2026-09-23 — [Builds stop committing the files the conductor regenerates on merge](2026-09-23-BH-1680-generated-no-commit.md)
- 2026-09-23 — [2026-09-23 — BH-1554: the impact gate's budget is 450 s, and four smaller fixes from the #1541 round-2 review](2026-09-23-BH-1554-impact-gate-budget-450.md)
- 2026-09-23 — [The reopen rate is a D1 row; the build reads it through jobs-client](2026-09-23-BH-117-reopen-rate-row.md)
- 2026-09-22 — [A build of cromford runs the suites its diff can reach before it pushes](2026-09-22-BH-1524-builder-impact-gate.md)
- 2026-09-22 — [The PR a build opens is named after the ticket, and `## What` is cut at the merge base](2026-09-22-BH-1415-pr-title-merge-base.md)
- 2026-09-22 — [BH-1355: the migration gate sees `prisma/` files, and names them](2026-09-22-BH-1355-migration-gate-prisma-files.md)
- 2026-09-22 — [A failed shared-file extraction is named in the split comment, and its WARN carries the reason and the partial list](2026-09-22-BH-1343-extractor-failure-in-split-comment.md)
- 2026-09-22 — [BH-1335 — the rollout lane resumes, and two parser holes close](2026-09-22-BH-1335-rollout-parser-holes.md)
- 2026-09-21 — [BH-1310: the checkpoint squash resets onto merge-base($BASE, HEAD), not onto $BASE](2026-09-21-BH-1310-checkpoint-squash-merge-base.md)
- 2026-09-19 — [The pool's PR_CREATED gate and seven close-out writers read GitHub over REST](2026-09-19-BH-781-decision-closeouts-read-rest.md)
- 2026-09-18 — [A build whose PR never opened is owned end to end](2026-09-18-BH-614-pr-create-failed-owned.md)
- 2026-09-18 — [The stage-module presence check stops like F1](2026-09-18-BH-568-stage-module-stop.md)
- 2026-09-18 — [The Changes-region check reads an empty region when a marker is missing](2026-09-18-BH-476-guardrail-region-fixes.md)
- 2026-09-18 — [Dated notes replace appending to the five contract docs](2026-09-18-BH-476-doc-notes-and-index.md)

## OPERATOR-SETUP

- 2026-10-18 — [The harness sync heals a failed fast-forward, and the pool pages when it is under-used (BH-7382)](2026-10-18-BH-7382-sync-self-heal-pool-underuse.md)
- 2026-10-17 — [fly-onboard puts the project's Fly token on the console worker (BH-7196)](2026-10-17-BH-7196-console-fly-secrets.md)
- 2026-10-17 — [Cromford release commits carry bullet release notes (BH-7185)](2026-10-17-BH-7185-cromford-release-notes.md)
- 2026-10-16 — [The pool reclaims orphan slots, names a stall, and cancels held in-flight builds (BH-7107)](2026-10-16-BH-7107-pool-orphan-reclaim.md)
- 2026-10-16 — [Staff learning view on the agent page (BH-6825, Staff in Mission Control 4/4)](2026-10-16-BH-6825-staff-learning-view.md)
- 2026-10-15 — [The Fly idle reaper reads work, probes, and destroys (BH-6877)](2026-10-15-BH-6877-fly-usage-witness.md)
- 2026-10-15 — [Archie as Overlooker of the staff agents (BH-5562, wave 5 of #5556)](2026-10-15-BH-5562-archie-overlooker.md)
- 2026-10-14 — [Daily digest: a per-day cap on route reads (BH-6727, the sixth row source)](2026-10-14-BH-6727-digest-read-cap.md)
- 2026-10-14 — [A ticket can name a spec repo its pool build may read (BH-6576)](2026-10-14-BH-6576-spec-repos.md)
- 2026-10-14 — [Staff learning loop: outcomes, precision, proposals, demotion (BH-5563, wave 6 of #5556)](2026-10-14-BH-5563-staff-learning.md)
- 2026-10-13 — [CREATED_TABLES derives from worker/jobs/schema.d (BH-4987, slice C5)](2026-10-13-BH-4987-created-tables-derived.md)
- 2026-10-12 — [Onboarding checks browser-QA wiring, and a daily lane alerts until it is wired (BH-6254)](2026-10-12-BH-6254-qa-wiring.md)
- 2026-10-12 — [BH-5239: the Cloud control plane moved to example-org/cromford-web](2026-10-12-BH-5239-cloud-moved.md)
- 2026-10-11 — [The Fly idle reaper lane (BH-6061)](2026-10-11-BH-6061-fly-idle-reaper.md)
- 2026-10-11 — [worker/jobs/schema.sql leaves git (BH-6005.4, #6011)](2026-10-11-BH-6005-schema-sql-untracked.md)
- 2026-10-11 — [The fleet reads the D1 registry; fleet.conf is an export (BH-5651, wave 3 of BH-5633)](2026-10-11-BH-5651-registry-switch.md)
- 2026-10-11 — [Sentry issues become tickets (BH-5620, slice 4 of #5611)](2026-10-11-BH-5620-sentry-triage.md)
- 2026-10-11 — [Archie inward ideas prompt (BH-4768, slice 5 of #4760)](2026-10-11-BH-4768-archie-ideas-prompt.md)
- 2026-10-10 — [Pool builds can read a second repo; a plan that cannot stops at PLAN (BH-5910)](2026-10-10-BH-5910-extra-read-repos.md)
- 2026-10-10 — [Staff heartbeat: one generic tick for every staff agent (BH-5561, wave 4 of #5556)](2026-10-10-BH-5561-staff-heartbeat.md)
- 2026-10-10 — [Archie whole-factory watch prompt (BH-4767, slice 4 of #4760)](2026-10-10-BH-4767-archie-watch-prompt.md)
- 2026-10-09 — [One command registers a box in every box list (BH-5747)](2026-10-09-BH-5747-box-register.md)
- 2026-10-09 — [Archie tells the operator once when a metric is unreadable (BH-4765, BH-4760.1)](2026-10-09-BH-4765-archie-unreadable-told.md)
- 2026-10-09 — [Replay a lane prompt: the `prompt:` key (BH-4764, slice 1 of #4760)](2026-10-09-BH-4764-replay-prompt-key.md)
- 2026-10-08 — [review-prs re-reviews a blocked external PR's new head on GitHub (BH-5396)](2026-10-08-BH-5396-review-prs-stale-cr.md)
- 2026-10-08 — [Machines outside the pool can enroll as participants (BH-5348)](2026-10-08-BH-5348-participant-machines.md)
- 2026-10-07 — [Archie's soul is section files (BH-5244, BH-5235.0)](2026-10-07-BH-5244-archie-soul-sections.md)
- 2026-10-07 — [How to add an Archie soul section (BH-5235.1)](2026-10-07-BH-5235-soul-sections.md)
- 2026-10-07 — [BH-5006: pool close-out custody sweep, and a terminal skip that says why](2026-10-07-BH-5006-pool-custody.md)
- 2026-10-07 — [Per-flip evidence runner and the STATE PATHS panel (BH-5000, slice C0)](2026-10-07-BH-5000-state-flip-evidence.md)
- 2026-10-06 — [2026-10-06 — BH-4938: opt-in auto-deploy of main HEAD (child 3 of #4916)](2026-10-06-BH-4938-served-sha-autodeploy.md)
- 2026-10-06 — [2026-10-06 — BH-4936: served-sha watch, the tracer of #4916](2026-10-06-BH-4936-served-sha-watch.md)
- 2026-10-06 — [The public repo appends releases and reads as Cromford (BH-4901)](2026-10-06-BH-4901-cromford-append-branding.md)
- 2026-10-06 — [BH-4798: a box with no plain PAT no longer stops the pool at the env bundle](2026-10-06-BH-4798-pool-bundle-no-pat.md)
- 2026-10-06 — [Archie talks in the operator's DM, and says nothing when nothing is needed (BH-4779)](2026-10-06-BH-4779-archie-dm.md)
- 2026-10-06 — [Archie's research scout finishes its scoring and binds the cap per call (BH-4762)](2026-10-06-BH-4762-archie-research-produces.md)
- 2026-10-05 — [Archie checks: a usable dollar cap, budget stops retry within the hour, unreadable metrics re-check daily (BH-4609)](2026-10-05-BH-4609-archie-retry.md)
- 2026-10-05 — [Archie, whole-factory watch: one lever per incident, one ticket if it did not take (BH-4586, wave 4 of #4574)](2026-10-05-BH-4586-archie-fm-watch.md)
- 2026-10-04 — [Self-host install: the dry-run planner (BH-4081 slice C0, #3979 wave 7)](2026-10-04-BH-4081-selfhost-install.md)
- 2026-10-04 — [Deployment defaults and the deployment lint (BH-4080, #3979 wave 6)](2026-10-04-BH-4080-deployment-defaults.md)
- 2026-10-04 — [Archie's earned autonomy (BH-4067, wave 6 of #3966)](2026-10-04-BH-4067-archie-autonomy.md)
- 2026-10-04 — [Archie's learning loop (BH-4066, wave 5 of #3966)](2026-10-04-BH-4066-archie-learning.md)
- 2026-10-04 — [Archie's research scout: X and web into the Ideas ledger (BH-4065, wave 4 of #3966)](2026-10-04-BH-4065-archie-research-scout.md)
- 2026-10-04 — [Archie's skills and their replay runner (BH-4064, wave 3 of #3966)](2026-10-04-BH-4064-archie-skills.md)
- 2026-10-04 — [Archie wakes on events, not only on his schedule (BH-4063, wave 2 of #3966)](2026-10-04-BH-4063-archie-wakeups.md)
- 2026-10-03 — [Archie's tracer: initiative, check, message (BH-4062, wave 1 of #3966)](2026-10-03-BH-4062-archie-tracer.md)
- 2026-10-03 — [Queue wakes and the */10 fly backstops (BH-4172, last slice of BH-4059)](2026-10-03-BH-4059-queue-wakes.md)
- 2026-10-01 — [stuck-work: the contract slice and a stub hub lane (BH-3789)](2026-10-01-BH-3789-stuck-work-contract.md)
- 2026-10-01 — [stuck-work: the lane body, paging, the snapshot and the digest line (BH-3793)](2026-10-01-BH-3781-stuck-work.md)
- 2026-09-30 — [Post-merge verify: prod serves the sha we merged (BH-3690, slice C0)](2026-09-30-BH-3690-post-merge-verify.md)
- 2026-09-30 — [A PreToolUse tripwire stops agents printing env and secret files (BH-3689)](2026-09-30-BH-3689-secret-read-guard.md)
- 2026-09-29 — [The hub-probe lane (BH-3434, built in BH-3450)](2026-09-29-BH-3434-hub-probe.md)
- 2026-09-29 — [The model-watch lane (BH-3422, built in BH-3429)](2026-09-29-BH-3422-model-watch.md)
- 2026-09-28 — [Four side lanes skip the watchdog call when WATCHDOG_URL is unset (BH-3322)](2026-09-28-BH-3322-watchdog-url-side-lanes.md)
- 2026-09-28 — [WATCHDOG_URL is seeded into env/global.env from the repo (BH-2091, BH-3320)](2026-09-28-BH-2091-watchdog-url-seed.md)
- 2026-09-27 — [sweepstall watches the merge conductor, and a held READY row says why](2026-09-27-SWEEPSTALL-conductor-reason.md)
- 2026-09-26 — [Box-ops lane: every box runs its own console box commands (BH-2518.2, BH-2660)](2026-09-26-BH-2660-box-ops-lane.md)
- 2026-09-26 — [Post-merge QA pays the prodqa agent only when the drive failed](2026-09-26-BH-2547-postmerge-qa-agent-on-failure.md)
- 2026-09-26 — [Pool assignments become machines rows: parity, the flip, no more ssh sweep](2026-09-26-BH-2522-fly-pool-rows-parity.md)
- 2026-09-24 — [Three count pins become invariants, and the jobs-client map becomes fragments](2026-09-24-LANE-E-count-pins-to-invariants.md)
- 2026-09-24 — [An empty JOBS_URL is "not configured", the watchdog box list is config, and a failed merge-queue touch pages](2026-09-24-BH-1957-fork-safe-defaults.md)
- 2026-09-24 — [apply-migrations finds a fifth board's app base, board-invariants reads a served keyPrefix](2026-09-24-BH-1956-fleet-derive.md)
- 2026-09-24 — [Merge/review and lane-caps knobs move into the registry](2026-09-24-BH-1940-config-slice-merge-caps.md)
- 2026-09-24 — [Cost/billing and mission-control knobs now come from the registry](2026-09-24-BH-1939-config-slice-cost-mc.md)
- 2026-09-24 — [Two more literals become settings knobs: the lane-alert DM chat and the state-backup switch](2026-09-24-BH-1938-config-slice-small.md)
- 2026-09-24 — [One registry file per lib, and `endpoint_url` as the one URL resolver](2026-09-24-BH-1937-lib-files-and-endpoint-resolver.md)
- 2026-09-24 — [A new env-diff lane announces runner, billing, model and effort env changes](2026-09-24-BH-19-env-diff-lane.md)
- 2026-09-24 — [agent-call caches the stage route read, bounds its wait, and stops repeating the mismatch line](2026-09-24-BH-1837-stage-route-cache.md)
- 2026-09-24 — [agent-call reads the stage runner from the stage.* route and checks the model against it](2026-09-24-BH-1765-stage-runner-routes.md)
- 2026-09-24 — [The grok envelope probe, grok rows in cli_versions, and a per-box grok requirement](2026-09-24-BH-1636-grok-envelope-probe-and-per-box-cli.md)
- 2026-09-24 — [Agent commits carry the box's git identity, and nothing else gets pushed](2026-09-24-BH-1134-commit-author.md)
- 2026-09-23 — [The split-family watchdog lane (BH-1793, built in BH-1808)](2026-09-23-BH-1793-split-watchdog.md)
- 2026-09-23 — [grok output tokens include reasoning, and agent-call.sh's knobs are settings rows](2026-09-23-BH-1636-grok-reasoning-and-agent-call-knobs.md)
- 2026-09-23 — [Builders App follow-ups: pruned retry flags, a rotated installation hint, an owner row](2026-09-23-BH-1602-builders-app-followups.md)
- 2026-09-23 — [Disk guard: alert at 85%, refuse to start a build at 92%](2026-09-23-BH-1123-disk-guard.md)
- 2026-09-22 — [2026-09-22 — BH-426: a GitHub quota gauge, an alert at 20 percent, and a counter](2026-09-22-BH-426-gh-quota-gauge.md)
- 2026-09-22 — [grok is a runner CLI the fleet updates daily, and its 1.0.x cost row prices](2026-09-22-BH-1494-grok-cli-daily-update.md)
- 2026-09-22 — [2026-09-22 — BH-1304: case 7 renders its own registry, the stamp dir must be ours, harness-sync composes only on change](2026-09-22-BH-1304-render-on-change-stamp-owner.md)
- 2026-09-20 — [The propagate lane bakes at most two warm pools at once, one cold pool at a time, and says why a bake failed](2026-09-20-BH-1115-pool-bake-fanout.md)
- 2026-09-19 — [Eleven per-project lanes default to the App identity, and `--status` stops printing `?/?`](2026-09-19-BH-470-per-project-lane-default-auth.md)
- 2026-09-19 — [2026-09-19 — BH-1044: disk-clean bounds the four state accumulators](2026-09-19-BH-1044-hub-state-hygiene.md)
- 2026-09-19 — [Four small ledger bugs: a stamp, a cursor, a stamp that outlived its rows, and a stale map](2026-09-19-BH-1042-small-ledger-bugs.md)
- 2026-09-19 — [Post-merge QA stops re-offering a merge the gate never saw served](2026-09-19-BH-1022-postmerge-qa-deploy-age.md)
- 2026-09-18 — [Every merge write goes over REST](2026-09-18-BH-892-merge-rest.md)
- 2026-09-18 — [The Changes-region check reads an empty region when a marker is missing](2026-09-18-BH-476-guardrail-region-fixes.md)
- 2026-09-18 — [Dated notes replace appending to the five contract docs](2026-09-18-BH-476-doc-notes-and-index.md)
- 2026-09-18 — [Every box now installs, loads and verifies a kernel audit watch on the harness roots](2026-09-18-BH-443-auditd-installer.md)

## EVENTS

- 2026-10-17 — [Hub project-loop ratchet, cron staggers, lead-review lock measure (BH-5945)](2026-10-17-BH-5945-ratchet-and-staggers.md)
- 2026-10-16 — [A PLAN_BLOCKED build says why, and the stranded watch waits for an answer (BH-7116)](2026-10-16-BH-7116-plan-blocked-notice.md)
- 2026-10-15 — [Repair on push: a push to main wakes repair on the PRs it touches (BH-6963, wave 1 of #6542)](2026-10-15-BH-6963-repair-on-push.md)
- 2026-10-15 — [Wakes reads: claim cursor, claim indexes, summary table, dead cursors (BH-6799)](2026-10-15-BH-6799-wakes-read-cuts.md)
- 2026-10-15 — [The prod smoke probe is a browser page load on a per-project path (BH-6786)](2026-10-15-BH-6786-smoke-headers.md)
- 2026-10-15 — [Watchman: the security lanes, a history secret scan and a rotation register (BH-5565, wave 8 of #5556)](2026-10-15-BH-5565-watchman.md)
- 2026-10-15 — [Archie as Overlooker of the staff agents (BH-5562, wave 5 of #5556)](2026-10-15-BH-5562-archie-overlooker.md)
- 2026-10-14 — [Dispatcher: the health lanes, a dead-feed watch and a post-deploy output check (BH-5566, wave 9 of #5556)](2026-10-14-BH-5566-dispatcher.md)
- 2026-10-14 — [Quartermaster: the cost lanes and two cost checks (BH-5564, wave 7 of #5556)](2026-10-14-BH-5564-quartermaster.md)
- 2026-10-14 — [Staff learning loop: outcomes, precision, proposals, demotion (BH-5563, wave 6 of #5556)](2026-10-14-BH-5563-staff-learning.md)
- 2026-10-11 — [worker/jobs/schema.sql leaves git (BH-6005.4, #6011)](2026-10-11-BH-6005-schema-sql-untracked.md)
- 2026-10-11 — [Step in: notes reach the running build, the ticket and the hold (BH-5839)](2026-10-11-BH-5839-steer-notes.md)
- 2026-10-11 — [The merge conductor reacts to PR events; the full tick is an hourly sweep (BH-5521)](2026-10-11-BH-5521-conductor-event-driven.md)
- 2026-10-10 — [Staff heartbeat: one generic tick for every staff agent (BH-5561, wave 4 of #5556)](2026-10-10-BH-5561-staff-heartbeat.md)
- 2026-10-07 — [The lead-review chain is event-driven: a finished review rings lead-land (BH-5317)](2026-10-07-BH-5317-lead-review-rings-land.md)
- 2026-10-05 — [Jira and Linear webhooks ring the wakes doorbell; every delivery wakes once (BH-4079)](2026-10-05-BH-4079-webhook-intake.md)
- 2026-10-04 — [A finished Fly build rings the doorbell: `fly_result` → `queue` wake (BH-4171, slice of BH-4059)](2026-10-04-BH-4171-fly-result-queue-wake.md)
- 2026-10-04 — [BH-4055: PR events close merge-path alerts in the same drain](2026-10-04-BH-4055-pr-events-close-merge-alerts.md)
- 2026-10-03 — [A fly enqueue rings the doorbell: the `queue` wake tracer (BH-4169, first slice of BH-4059)](2026-10-03-BH-4169-queue-wake-tracer.md)
- 2026-10-03 — [A watchdog for armed-but-silent wake classes, and the arming runbook (BH-4060)](2026-10-03-BH-4060-wake-armed-watchdog.md)
- 2026-10-03 — [Queue wakes and the */10 fly backstops (BH-4172, last slice of BH-4059)](2026-10-03-BH-4059-queue-wakes.md)
- 2026-10-03 — [The doorbell hears five more GitHub events, and `bin/webhook-rearm.sh` (BH-4058)](2026-10-03-BH-4058-webhook-new-events.md)
- 2026-10-03 — [In-app text dependencies: hold and release (BH-3946, slices BH-3963 and BH-3964)](2026-10-03-BH-3946-inapp-text-deps.md)
- 2026-09-29 — [The wake loop owes a conductor run it could not launch, and a checks wake's sha names its PR](2026-09-29-BH-3453-wake-owed-sha-keys.md)
- 2026-09-29 — [deploy-verify reads deploy.<project>.kind before it polls (BH-3387)](2026-09-29-BH-3387-deploy-kind.md)
- 2026-09-28 — [A queued build row follows the project's routing, and a row nothing will claim pages (BH-3316)](2026-09-28-BH-3316-stranded-queue-target.md)
- 2026-09-28 — [The console poller forwards box commands as rows, not ssh (BH-2657, BH-2528.4)](2026-09-28-BH-2657-box-console-commands.md)
- 2026-09-27 — [Pre-plan cadence gate runs before the stale re-plan (BH-2998, BH-2992.4)](2026-09-27-BH-2992-preplan-gate-order.md)
- 2026-09-26 — [Untriaged wake: a doorbell for tickets GitHub never rings about (BH-2751 part 2, BH-2754)](2026-09-26-BH-2751-untriaged-wake.md)
- 2026-09-26 — [Wake claim, cursor and cooldown routes (BH-2525.1, BH-2636)](2026-09-26-BH-2636-wake-claim-routes.md)
- 2026-09-26 — [Pre-plan outcome as a stage_events row, and GET /api/preplans/adoption (BH-2543 slice 2, BH-2571)](2026-09-26-BH-2571-preplan-outcome-event.md)
- 2026-09-26 — [Review savings: a cheap route for trivial diffs, and every skipped review is counted](2026-09-26-BH-2545-review-savings.md)
- 2026-09-26 — [Wake claims, cursors and cooldowns: the contract](2026-09-26-BH-2525-wake-claims.md)
- 2026-09-26 — [Every box pulls its own wakes](2026-09-26-BH-2525-boxes-pull-wakes.md)
- 2026-09-25 — [Pre-plan readiness and cadence: the contract (BH-2543 slice 1, BH-2569)](2026-09-25-BH-2543-preplan-adoption.md)
- 2026-09-24 — [The doorbell reads the GitHub App's own webhook and stops asking for a PAT](2026-09-24-pool-doorbell-app-hook.md)
- 2026-09-24 — [A PR the blocked-resolver closes unmerged moves its console build row to `superseded` or `abandoned`](2026-09-24-BH-389-resolver-closed-row.md)
- 2026-09-24 — [BH-2133: the harness's own comments are not the board moving](2026-09-24-BH-2133-own-comments-not-input.md)
- 2026-09-23 — [The decompose parent close only closes a split it can verify](2026-09-23-BH-949-parent-close-verifies-children.md)
- 2026-09-23 — [BH-1655 — a merged split child wakes the next sibling on a polling board](2026-09-23-BH-1655-split-chain-advance.md)
- 2026-09-23 — [The conductor's attempts go through the row helpers, and a wake can key a tick](2026-09-23-BH-1387-conductor-rows-keyed-tick.md)
- 2026-09-22 — [Wake-class cooldowns become knobs, and prompts_touched finally fetches](2026-09-22-BH-1351-wake-class-knobs.md)
- 2026-09-22 — [BH-1079 record corrections: the -ge rationale, the gate's lookup, and the suite's count](2026-09-22-BH-1332-prstates-record-corrections.md)
- 2026-09-22 — [Two corrections to the wake classes: the reconcile-prs window and per-job check rows](2026-09-22-BH-1292-wake-classes-followups.md)
- 2026-09-22 — [BH-1267 — wakes retention prune, `idx_wakes_at`, and a lowercased wake-cursor key](2026-09-22-BH-1267-wakes-retention-cursor-key.md)
- 2026-09-22 — [2026-09-22 — BH-1163 part 2: the fast-path launcher reads GitHub over REST](2026-09-22-BH-1163-fastpath-rest.md)
- 2026-09-19 — [The pool's PR_CREATED gate and seven close-out writers read GitHub over REST](2026-09-19-BH-781-decision-closeouts-read-rest.md)
- 2026-09-19 — [A skip-only triage tick consumes the board fingerprint, and the PR-state ledger never takes an older answer](2026-09-19-BH-1079-prstates-consume-and-epoch.md)
- 2026-09-19 — [Wake classes: the shared contract before any lane is wired](2026-09-19-BH-1034-wake-classes.md)
- 2026-09-19 — [Push and flaky wake classes: the first two BH-1034 lanes wired](2026-09-19-BH-1034-push-flaky-classes.md)
- 2026-09-19 — [The first two wake classes: `pr-closed` and `pr-ci`](2026-09-19-BH-1034-pr-classes.md)
- 2026-09-19 — [Doorbell ringing from a `wakes` SELECT, and a cursor that survives a rebuild](2026-09-19-BH-1034-doorbell-ringing-cursor.md)
- 2026-09-19 — [The deploy wake class: deployment_status drives the train's verify and both migration lanes](2026-09-19-BH-1034-deploy-class.md)
- 2026-09-19 — [A triage session that fails every time is consumed after three attempts, not bought forever](2026-09-19-BH-1021-triage-fail-consume.md)
- 2026-09-18 — [In-app ticket dependencies: the read side, and why a board webhook is not the fast path](2026-09-18-BH-815-inapp-dependencies-read-side.md)
- 2026-09-18 — [The Changes-region check reads an empty region when a marker is missing](2026-09-18-BH-476-guardrail-region-fixes.md)
- 2026-09-18 — [Dated notes replace appending to the five contract docs](2026-09-18-BH-476-doc-notes-and-index.md)

## ACCOUNT-ROUTING

- 2026-10-03 — [One auth_account per account, and the served model on every cost row (BH-3986)](2026-10-03-BH-3986-cost-row-attribution.md)
- 2026-09-29 — [Pinned project accounts resolve on their owning boxes, and say so when they don't (BH-3559)](2026-09-29-BH-3559-pinned-account-aliases.md)
- 2026-09-27 — [Token health producers: OAuth logins and GitHub App mints report (BH-2646)](2026-09-27-BH-2646-token-health-producers.md)
- 2026-09-27 — [ACCOUNT & TOKEN HEALTH panel on /settings (BH-2516.3, BH-2647)](2026-09-27-BH-2516-token-health.md)
- 2026-09-25 — [quota-status: a fleet-only clear says it cleared the fleet cooldown](2026-09-25-BH-2464-fleet-clear-message.md)
- 2026-09-25 — [agent-call and orchestrate read and write fleet cooldown rows](2026-09-25-BH-2356-fleet-cooldown-readers.md)
- 2026-09-25 — [Account cooldowns are fleet facts (BH-2355)](2026-09-25-BH-2355-fleet-account-cooldowns.md)
- 2026-09-23 — [Own-account pins reach agent-call, the ladder, cost rows, the console and quota-status](2026-09-23-BH-1657-own-account-pins.md)
- 2026-09-22 — [The gh_rest ETag counter file is swept, trapped, and the byte cap counts bytes](2026-09-22-BH-1322-gh-etag-counter-leak.md)
- 2026-09-21 — [gh_rest caches ETags and answers 304s from the cache](2026-09-21-BH-1295-gh-rest-etag.md)
- 2026-09-19 — [The orchestrator turn tries every account it can reach, and its survival banner states the measured refusal](2026-09-19-BH-996-orc-turn-account-ladder.md)
- 2026-09-19 — [2026-09-19 — BH-1037: agent-call.sh gets a choke point (the prompt ledger)](2026-09-19-BH-1037-agent-call-choke-guard.md)
- 2026-09-18 — [Account cooldowns are keyed by vendor now, and there is a lever to clear one](2026-09-18-BH-940-vendor-scoped-cooldown.md)

## ADD-YOUR-OWN-MACHINE

- 2026-10-09 — [Lead review claims: heartbeat, reclaim, participants, separation of duties (BH-5351)](2026-10-09-BH-5351-participant-lead-review-claims.md)
- 2026-10-08 — [Machines outside the pool can enroll as participants (BH-5348)](2026-10-08-BH-5348-participant-machines.md)

## ADDING-A-BOX

- 2026-10-18 — [Box roles in the registry, a sync timer on every box, the watchdog list from the registry (BH-7303)](2026-10-18-BH-7303-registry-roles-sync-timer.md)
- 2026-10-14 — [The orchestrator handles box and project requests from chat (BH-5751)](2026-10-14-BH-5751-box-requests.md)
- 2026-10-10 — [2026-10-10 BH-5750: Mission Control box controls](2026-10-10-BH-5750-box-controls.md)
- 2026-10-10 — [Restart, stop, resize and retire an Orgo box (BH-5749)](2026-10-10-BH-5749-box-ops-orgo.md)
- 2026-10-09 — [One command launches an Orgo box (BH-5748)](2026-10-09-BH-5748-box-launch.md)
- 2026-10-09 — [One command registers a box in every box list (BH-5747)](2026-10-09-BH-5747-box-register.md)

## AGENT-CALL

- 2026-10-05 — [BH-4492: egress allowlist per build stage (wave 5 of BH-4475)](2026-10-05-BH-4492-egress-allowlist.md)
- 2026-10-05 — [BH-4489: hard caps on every stage and scope](2026-10-05-BH-4489-budget-caps-scopes.md)
- 2026-10-04 — [BH-4488: hard caps per (build, stage), the execute-stage tracer](2026-10-04-BH-4488-budget-stop-tracer.md)

## ALERT-REMEDIATION

- 2026-09-27 — [Ten seed families for alert_family_scripts, with their verify scripts (BH-2577, BH-2544.4)](2026-09-27-BH-2577-alert-verify-seeds.md)
- 2026-09-26 — [Guarded-lane agents no longer push; the harness does (BH-2741)](2026-09-26-BH-2741-agent-push-guard.md)
- 2026-09-25 — [BH-2544 (BH-2572): the alert-family registry runner](2026-09-25-BH-2544-registry-runner.md)
- 2026-09-25 — [BH-2359 (BH-2319.4): lane-down writers stamp fleet rows, reprobe reseeds from them](2026-09-25-BH-2359-lane-down-fleet-rows.md)
- 2026-09-23 — [2026-09-23 — BH-1687 (BH-1674 part 2): a down runner lane is re-probed and clears itself](2026-09-23-BH-1674-lane-reprobe.md)
- 2026-09-23 — [The rebuild rung never closes a CI-parked PR whose current head is green](2026-09-23-BH-1671-supersede-green-at-head.md)
- 2026-09-19 — [2026-09-19 — BH-1040: the migration ledger answers three ways, and "cannot ask" holds](2026-09-19-BH-1040-migration-ledger-three-answers.md)
- 2026-09-19 — [Tier 2 pays for a remediation payload once (BH-1038)](2026-09-19-BH-1038-remediate-payload-dedup.md)
- 2026-09-19 — [The box side of the alerts table: the row decides, the files follow](2026-09-19-BH-1030-alerts-producers.md)

## ALERTS-GROOMING-SPEC

- 2026-10-16 — [One watcher per component decides its alerts (BH-6972, wave 2 of #6546)](2026-10-16-BH-6972-component-watch.md)
- 2026-10-16 — [alerts-groom removes the dated box flag families (BH-5934, slice C0)](2026-10-16-BH-5934-groom-dated-box-flags.md)
- 2026-10-15 — [Every alert belongs to a component (BH-6971)](2026-10-15-BH-6971-alert-components.md)
- 2026-10-11 — [The three LLM alert lanes run per project (BH-5942)](2026-10-11-BH-5942-llm-lanes-per-project.md)
- 2026-10-04 — [BH-4055: PR events close merge-path alerts in the same drain](2026-10-04-BH-4055-pr-events-close-merge-alerts.md)
- 2026-10-03 — [Groom closes pipeline-health rows whose condition cleared (BH-4056)](2026-10-03-BH-4056-ph-absent-groom.md)
- 2026-10-03 — [pipeline-health merge alerts close when their PRs merge, close or get queued (BH-3997)](2026-10-03-BH-3997-merge-alerts-close-on-prs.md)
- 2026-09-26 — [The alerts groomer reads the DB, not the box](2026-09-26-BH-2526-alerts-groom-db-reads.md)
- 2026-09-19 — [The console reads the alerts table: a FLEET ROWS section on /alerts](2026-09-19-BH-1030-alerts-console.md)

## ALERTS-STATE-MACHINE

- 2026-10-16 — [One watcher per component decides its alerts (BH-6972, wave 2 of #6546)](2026-10-16-BH-6972-component-watch.md)
- 2026-10-16 — [pipeline-health project runs off the hub: the fleet-wide writes (BH-6892, BH-6881.10)](2026-10-16-BH-6892-pipeline-health-offhub.md)
- 2026-10-16 — [Merge-conductor lane manifest and alert lines through the jobs API (BH-6889, BH-6881.5)](2026-10-16-BH-6889-mc-manifest-alert-lines.md)
- 2026-10-15 — [Watchman: the security lanes, a history secret scan and a rotation register (BH-5565, wave 8 of #5556)](2026-10-15-BH-5565-watchman.md)
- 2026-10-14 — [Dispatcher: the health lanes, a dead-feed watch and a post-deploy output check (BH-5566, wave 9 of #5556)](2026-10-14-BH-5566-dispatcher.md)
- 2026-10-11 — [pipeline-health runs one process per project (BH-5941)](2026-10-11-BH-5941-pipeline-health-per-project.md)
- 2026-10-07 — [Direction is not a take-over, and a resolver hand-off acts, says why not, or pages (BH-5125)](2026-10-07-BH-5125-direction-handoff.md)
- 2026-10-06 — [2026-10-06 — BH-4938: opt-in auto-deploy of main HEAD (child 3 of #4916)](2026-10-06-BH-4938-served-sha-autodeploy.md)
- 2026-10-06 — [2026-10-06 — BH-4936: served-sha watch, the tracer of #4916](2026-10-06-BH-4936-served-sha-watch.md)
- 2026-10-05 — [BH-4724: self-heal notices go info, and the daily digest counts them](2026-10-05-BH-4724-self-heal-info.md)
- 2026-10-05 — [Archie, whole-factory watch: one lever per incident, one ticket if it did not take (BH-4586, wave 4 of #4574)](2026-10-05-BH-4586-archie-fm-watch.md)
- 2026-10-03 — [Groom closes pipeline-health rows whose condition cleared (BH-4056)](2026-10-03-BH-4056-ph-absent-groom.md)
- 2026-10-03 — [pipeline-health retractions close their console row (BH-4054)](2026-10-03-BH-4054-ph-retract-closes-row.md)
- 2026-10-03 — [One console row per alert condition (BH-4053)](2026-10-03-BH-4053-alert-row-per-condition.md)
- 2026-10-03 — [The outcome gap in the daily digest (BH-4017, BH-3987.3)](2026-10-03-BH-3987-outcome-gap.md)
- 2026-10-03 — [The results sweep reads the newest result first, and a held sweep keeps no stamp (BH-3953)](2026-10-03-BH-3953-results-sweep-unswept-key.md)
- 2026-10-01 — [stuck-work: the lane body, paging, the snapshot and the digest line (BH-3793)](2026-10-01-BH-3781-stuck-work.md)
- 2026-09-30 — [The daily digest renders now, and can carry one LLM paragraph (BH-3707)](2026-09-30-BH-3707-daily-digest-render.md)
- 2026-09-30 — [The daily-digest lane: one triaged beat a day (BH-3706, BH-3688)](2026-09-30-BH-3688-daily-digest.md)
- 2026-09-28 — [Alert-triage closes re-verified rows and keeps grok off (BH-2544.1, BH-2570)](2026-09-28-BH-2570-close-and-runners.md)
- 2026-09-27 — [Alert-line wave 3: library and small-script writers (BH-2365, BH-2314.3)](2026-09-27-BH-2365-alert-line-wave-3.md)
- 2026-09-27 — [Cost, health and orchestration alert writers go through alert-line.sh (BH-2314 part 3, BH-2364)](2026-09-27-BH-2364-alert-writers-cost-health.md)
- 2026-09-26 — [Untriaged digest lane: bin/untriaged-digest.sh (BH-2756, BH-2751 ask 4)](2026-09-26-BH-2751-untriaged-digest.md)
- 2026-09-26 — [bin/alert-line.sh: one alert line, noted at emit time (BH-2314 part 1, BH-2362)](2026-09-26-BH-2314-alert-line.md)
- 2026-09-25 — [Alert family scripts: the worker route (BH-2544.3, BH-2575)](2026-09-25-BH-2544-route.md)
- 2026-09-25 — [BH-2544 (BH-2572): the alert-family registry runner](2026-09-25-BH-2544-registry-runner.md)
- 2026-09-25 — [Alert-triage settlement contract: hooks, table and knobs (BH-2544.0, BH-2568)](2026-09-25-BH-2544-contract.md)
- 2026-09-25 — [flags/ config files read as settings rows (BH-2411, BH-2320.C5)](2026-09-25-BH-2411-conf-rows.md)
- 2026-09-24 — [Two more literals become settings knobs: the lane-alert DM chat and the state-backup switch](2026-09-24-BH-1938-config-slice-small.md)
- 2026-09-22 — [2026-09-22 — BH-1327: cliff-parked rows leave the claim queue, and the triaged miss line names what it missed](2026-09-22-BH-1327-alerts-claims-followups.md)
- 2026-09-22 — [BH-1300: a pool project's build ceiling can no longer drop in silence](2026-09-22-BH-1300-ceiling-drop-alert.md)
- 2026-09-22 — [The two alert readers now stand still on the conductor's own lines while it is paused](2026-09-22-BH-1201-readers-hold-conductor.md)
- 2026-09-19 — [2026-09-19 — BH-1071: the hub alert lanes claim rows](2026-09-19-BH-1071-alerts-claims.md)
- 2026-09-19 — [The jobs worker answers /api/alerts: note, state, resolve, claim, flush, list, families](2026-09-19-BH-1030-alerts-routes.md)
- 2026-09-19 — [The box side of the alerts table: the row decides, the files follow](2026-09-19-BH-1030-alerts-producers.md)

## ARCH-AUDIT

- 2026-10-08 — [The architecture audit gains a conflict section](2026-10-08-BH-5270-arch-audit-conflict-section.md)

## AUTH-PROBE

- 2026-09-27 — [The claude and runner canaries probe the credential first (BH-2560, BH-2549.2)](2026-09-27-BH-2560-credential-probe-canaries.md)

## BLOCKED-RESOLVER

- 2026-10-01 — [A newer human MERGE on the exact head overrides the conductor's own re-review BLOCK (BH-3814)](2026-10-01-BH-3814-human-verdict-overrides-rereview.md)

## BOARD-API-CONTRACT

- 2026-10-14 — [A ticket can name a spec repo its pool build may read (BH-6576)](2026-10-14-BH-6576-spec-repos.md)
- 2026-10-05 — [Ticket text is data, not instructions (BH-4491)](2026-10-05-BH-4491-untrusted-input.md)
- 2026-10-04 — [Only a listed human or the harness itself makes a ticket buildable (BH-4490)](2026-10-04-BH-4490-trigger-actor-gate.md)
- 2026-10-04 — [Tracker contract: one verb set, two adapters, the adapter chosen by a settings row (BH-4075)](2026-10-04-BH-4075-tracker-contract.md)
- 2026-10-03 — [The board API conformance lane, skeleton (BH-3958, part 1 of BH-3947)](2026-10-03-BH-3947-board-conformance.md)
- 2026-10-03 — [In-app text dependencies: hold and release (BH-3946, slices BH-3963 and BH-3964)](2026-10-03-BH-3946-inapp-text-deps.md)
- 2026-10-03 — [The in-app decompose lane files its own children and writes their dependencies (BH-3965, part 3 of BH-3946)](2026-10-03-BH-3946-decompose-deps.md)
- 2026-10-03 — [Merged and deploy-audited tickets advance on in-app boards (BH-3927)](2026-10-03-BH-3927-merged-ticket-advance.md)
- 2026-09-24 — [triage-gate alerts when a board token or base resolves to an empty value](2026-09-24-BH-2106-triage-gate-empty-token.md)
- 2026-09-24 — [Every board caller resolves its token the same way, and a prisma repo's suite gets its client first](2026-09-24-BH-1955-token-callers.md)
- 2026-09-23 — [The in-app board lane of the child filer exists: `bin/lib/fc-board.sh`](2026-09-23-BH-983-board-lane-filer.md)
- 2026-09-18 — [In-app ticket dependencies: the read side, and why a board webhook is not the fast path](2026-09-18-BH-815-inapp-dependencies-read-side.md)

## BOX-SETUP

- 2026-10-14 — [2026-10-14 — BH-6742: flyctl and gh stay current; security updates are provisioned](2026-10-14-BH-6742-runner-tools-current.md)

## BR-OPT

- 2026-10-05 — [BH-4668: the fix round on an external PR (BH-4664.1)](2026-10-05-BH-4668-external-pr-fix-round.md)
- 2026-10-05 — [BH-4664: external PRs in the blocked-resolver (BH-4667 is the tracer)](2026-10-05-BH-4664-external-pr-fix-rounds.md)

## BUILD-TRIPWIRE

- 2026-10-05 — [BH-4489: hard caps on every stage and scope](2026-10-05-BH-4489-budget-caps-scopes.md)
- 2026-10-04 — [BH-4488: hard caps per (build, stage), the execute-stage tracer](2026-10-04-BH-4488-budget-stop-tracer.md)

## BUILDER-ROUTING

- 2026-09-25 — [The Project page shows the routing row, its change log, and a HALT toggle](2026-09-25-BH-2328-routing-panel.md)

## CALL-GUARD

- 2026-10-14 — [The build tripwire alerts and never stops a build (BH-6705)](2026-10-14-BH-6705-tripwire-alert-only.md)
- 2026-10-08 — [review-prs re-reviews a blocked external PR's new head on GitHub (BH-5396)](2026-10-08-BH-5396-review-prs-stale-cr.md)
- 2026-10-03 — [A reused review APPROVE carries its provenance (BH-4134)](2026-10-03-BH-4134-reuse-provenance.md)
- 2026-10-03 — [A ticket the call-guard keeps refusing is parked, and an open PR skips the paid session (BH-3949, part 2 of BH-3943)](2026-10-03-BH-3949-triage-park.md)
- 2026-10-03 — [A PR head buys one lead review, and the fleet counts the ones it paid twice (BH-3941)](2026-10-03-BH-3941-lead-review-dedupe.md)
- 2026-10-03 — [review-prs, the conductor and the resolver share the per-head review key (BH-3940)](2026-10-03-BH-3940-review-head-lanes.md)
- 2026-10-03 — [The review autopilot stands down on any head-bound verdict but the builder's (BH-3939)](2026-10-03-BH-3939-review-autopilot-head-dedupe.md)
- 2026-09-29 — [The mid-build spend tripwire: rules, pause row, launch guard (BH-3481.4)](2026-09-29-BH-3481.4-tripwire.md)
- 2026-09-26 — [claude-cost follow-ups: K3 on the raw-claude callers, real lanes for box-chat and greenfield, one refused row per turn](2026-09-26-BH-2603-claude-cost-k3-lanes.md)
- 2026-09-25 — [LLM sites screen: the contract slice (BH-2540 part 1, BH-2553)](2026-09-25-BH-2540-llm-sites-screen.md)
- 2026-09-25 — [claude-cost.sh calls go through the lane gate and K3](2026-09-25-BH-2534-claude-cost-gate.md)
- 2026-09-25 — [The call guard caps a build's plan, execute and fix across builds](2026-09-25-BH-2413-call-guard-build-fp.md)
- 2026-09-25 — [Cost breaker card: RESET clears CAP HIT, the proxy wants a reason, the hub publishes autohalt](2026-09-25-BH-2397-cost-breaker-followups.md)
- 2026-09-25 — [Mission Control shows the cost breaker and can reset the call guard](2026-09-25-BH-2331-cost-breaker-card.md)
- 2026-09-25 — [The call guard is on by default for plan, preplan, execute, fix, triage, prodqa and lead-review](2026-09-25-BH-2305-call-guard-default-stages.md)

## CHECKPOINTS

- 2026-09-22 — [BH-1319: the checkpoint adopt path unshallows, both squash refusals return 1, and the callers record them](2026-09-22-BH-1319-squash-unshallow-rc-twin.md)

## CI-IMAGES

- 2026-10-17 — [A shared CI base image, ghcr.io/example-org/ci-base (BH-7254)](2026-10-17-BH-7254-ci-base-image.md)

## CI-RUNNERS

- 2026-10-17 — [harness-ci can run its four install-heavy jobs in a prebuilt image; the switch is off (BH-7255, slice C0)](2026-10-17-BH-7255-ci-image.md)
- 2026-10-15 — [Suite ledger across gates: prequeue reads and writes it, and the runner image is in the key (BH-6925)](2026-10-15-BH-6925-suite-ledger-cross-gate.md)
- 2026-10-15 — [Builds, fix rounds and the lead review run CI's lint job locally (BH-6897)](2026-10-15-BH-6897-ci-local.md)
- 2026-10-15 — [CI shard count by measured time; a workflow edit selects its readers; a 35-minute shard page (BH-6876)](2026-10-15-BH-6876-ci-shard-sizing.md)
- 2026-10-14 — [CI test value report: the extra sources and the report (BH-6640, BH-6618.4)](2026-10-14-BH-6618.4-report.md)
- 2026-10-14 — [CI test value report: the model fallback (BH-6639, BH-6618.3)](2026-10-14-BH-6618.3-model-fallback.md)
- 2026-10-14 — [CI test value report: the catch, test defect and order rules (BH-6638, BH-6618.2)](2026-10-14-BH-6618.2-catch-rules.md)
- 2026-10-14 — [CI test value report: the infra and flake rules (BH-6637, BH-6618.1)](2026-10-14-BH-6618.1-infra-flake-rules.md)
- 2026-10-14 — [CI test value report: the tracer CLI (BH-6636, BH-6618.0)](2026-10-14-BH-6618-ci-test-value-report.md)
- 2026-10-14 — [Workflow checkouts keep no credential (BH-6522)](2026-10-14-BH-6522-checkout-credentials.md)
- 2026-10-13 — [Suite fingerprint v2: a helper is an input of its consumers, and the nightly run never reuses (BH-6406, slice C1 of BH-6371)](2026-10-13-BH-6406-fingerprint-v2.md)
- 2026-10-13 — [The trap-target guard is retired; its stale references are fixed (BH-5541)](2026-10-13-BH-5541-trap-target-guard-retired.md)
- 2026-10-08 — [A merge-from-main PR push reuses the last green for the lint job's tree checks (BH-5357)](2026-10-08-BH-5357-pr-ci-merge-reuse.md)
- 2026-10-08 — [Suite ledger: run a suite once per input fingerprint (BH-5354.0 / BH-5366)](2026-10-08-BH-5354-suite-reuse.md)
- 2026-10-07 — [Trace-safety reads escaped redirects one layer down, and declare "(…)" is an interpreter (BH-5266)](2026-10-07-BH-5266-trace-safety-escaped-redirects.md)
- 2026-09-26 — [Mission Control has a CI health screen with the flaky-test quarantine toggle](2026-09-26-BH-2634-ci-health.md)
- 2026-09-26 — [A rendered.sh helper that dies inside $(...) turns its suite red (BH-2263)](2026-09-26-BH-2263-rendered-helpers-fail-red.md)
- 2026-09-24 — [Each tree is tested exactly once, in the merge queue](2026-09-24-ci-cost-cut-lanes.md)
- 2026-09-24 — [K1: a CI job-minutes watch, and bin/fleet-slo.sh finally on a cron line](2026-09-24-K1-ci-minutes-fleet-slo.md)
- 2026-09-24 — [A mirror mid-sync retries the apt update once, and apt fails in an `infra:` step](2026-09-24-BH-2128-ci-apt-update-retry.md)
- 2026-09-24 — [The pool's gate runs the gitleaks arm; publish-share checks its download](2026-09-24-BH-2115-gate-gitleaks.md)
- 2026-09-24 — [CI runs the share mirror's gitleaks gate instead of skipping it](2026-09-24-BH-2059-ci-gitleaks.md)
- 2026-09-23 — [PyYAML is on every machine the corpus runs on, and missing it is red in CI](2026-09-23-BH-1741-pyyaml-ci.md)
- 2026-09-22 — [BH-1323: CI moved to MonkCI; CI_RUNNER now refuses an unknown fleet](2026-09-22-BH-1323-monkci-fleet.md)

## CI-RUNNERS.md

- 2026-09-22 — [BH-1246 — ci-shellcheck follow-ups from the #1240 review](2026-09-22-BH-1246-ci-shellcheck-followups.md)

## CODEGRAPH

- 2026-09-23 — [BH-113 — every box indexes its own harness checkout](2026-09-23-BH-113-harness-checkout-codegraph.md)

## CONFIG

- 2026-09-30 — [The daily-digest contract: signatures, stubs, seeds and fixtures (BH-3703)](2026-09-30-BH-3703-daily-digest-contract.md)
- 2026-09-27 — [Sweeper and metrics kill switches read through lane_switch (BH-2444)](2026-09-27-BH-2444-sweeper-switches.md)
- 2026-09-27 — [gh wrapper, ledger, gate-self, hotfix and model-prices switches read as rows (BH-2442)](2026-09-27-BH-2442-gh-wrapper-switches.md)
- 2026-09-27 — [Five sourced-lib kill switches read as settings rows (BH-2429, BH-2409.3)](2026-09-27-BH-2429-switches-libs.md)
- 2026-09-26 — [Kill switch fallback is read-only and sighted; switch-migrate runs daily (BH-2412)](2026-09-26-BH-2412-switch-fallback-sighting.md)
- 2026-09-25 — [flags/ config files read as settings rows (BH-2411, BH-2320.C5)](2026-09-25-BH-2411-conf-rows.md)
- 2026-09-25 — [Kill switches a-f: the contract (BH-2407, built as BH-2431)](2026-09-25-BH-2407-switches-a-f.md)
- 2026-09-25 — [Kill switches read as settings rows (BH-2320, contract + pilot)](2026-09-25-BH-2320-lane-switch.md)
- 2026-09-25 — [Vendor API base URLs are endpoint knobs (endpoints wave 1)](2026-09-25-BH-1941-endpoints-vendor.md)

## CONFLICT_HOTSPOTS

- 2026-10-15 — [Hotspot split tickets (BH-6739, BH-6543.2)](2026-10-15-BH-6739-hotspot-split-ticket.md)
- 2026-10-11 — [Conflict hotspots: one count per merge, no mergify or stale refs (BH-5236)](2026-10-11-BH-5236-conflict-hotspots-dedupe.md)
- 2026-10-07 — [Every project's conflict hotspots, measured weekly and stored as rows](2026-10-07-BH-5267-conflict-hotspots-fleet.md)

## CONSOLE

- 2026-10-17 — [Mission Control shows components, their open alerts and the watcher's decisions (BH-6973)](2026-10-17-BH-6973-components-screen.md)
- 2026-10-15 — [Staff autonomy and delegation controls, with an audit (BH-6824, Staff in Mission Control 3/4)](2026-10-15-BH-6824-staff-autonomy-controls.md)
- 2026-10-15 — [Talk to a staff agent (BH-6823, slice 2/4 of Staff in Mission Control)](2026-10-15-BH-6823-staff-chat.md)
- 2026-10-15 — [Staff agent detail page (BH-6822, slice 1/4 of Staff in Mission Control)](2026-10-15-BH-6822-staff-agent-detail.md)
- 2026-10-14 — [A new coord write route is a fragment file, not a row in WRITES (BH-6487)](2026-10-14-BH-6487-coord-write-fragments.md)
- 2026-10-10 — [Mission Control catches a failed screen and reports it to Sentry (BH-5619)](2026-10-10-BH-5619-console-error-boundary.md)
- 2026-10-10 — [Staff screen (BH-5567, wave 10 of #5556)](2026-10-10-BH-5567-staff-screen.md)
- 2026-10-08 — [Mission Control participants screen (BH-5353, BH-5348.4)](2026-10-08-BH-5353-participants-screen.md)
- 2026-09-27 — [/hub SEED REGISTRY and CHAT BINDINGS writes require a reason (BH-2995, BH-2992.1)](2026-09-27-BH-2995-hub-reason.md)
- 2026-09-26 — [SEED REGISTRY panel on /hub (BH-2521, slice BH-2677)](2026-09-26-BH-2521-seed-registry-panel.md)
- 2026-09-26 — [The Idea screen posts, revises, kills and chats](2026-09-26-BH-2520-idea-screen-actions.md)
- 2026-09-26 — [CONTROLS: one console screen for the editable config kinds (BH-2513.4, BH-2621)](2026-09-26-BH-2513-config-editors.md)
- 2026-09-25 — [Console writes name the operator's Cloudflare Access email](2026-09-25-BH-2515-access-actor.md)

## CONTEXT-COMPOSITION

- 2026-10-15 — [Stage iron laws: one law-set directory, added by agent-call.sh (BH-6557)](2026-10-15-BH-6557-stage-iron-laws.md)
- 2026-10-10 — [Staff heartbeat: one generic tick for every staff agent (BH-5561, wave 4 of #5556)](2026-10-10-BH-5561-staff-heartbeat.md)
- 2026-09-25 — [Context kill as a runaway backstop: sized from p99, unmeasured lanes unarmed, repeat kills escalated](2026-09-25-BH-2538-context-kill-backstop.md)
- 2026-09-25 — [The context kill is armed on the build, preplan, lead-review, post-merge QA and product lanes](2026-09-25-BH-2309-context-kill-lanes.md)
- 2026-09-23 — [The rule-miner reads a digest, runs as stage `mine` on its route's runner, and refuses over its ceiling](2026-09-23-BH-1749-rule-miner-digest.md)

## COST

- 2026-10-17 — [BH-7262: product stage on for seven projects, and a per-run USD cap](2026-10-17-BH-7262-product-fleet-enable.md)
- 2026-10-15 — [The Fly idle reaper reads work, probes, and destroys (BH-6877)](2026-10-15-BH-6877-fly-usage-witness.md)
- 2026-10-14 — [The build tripwire alerts and never stops a build (BH-6705)](2026-10-14-BH-6705-tripwire-alert-only.md)
- 2026-10-14 — [Quartermaster: the cost lanes and two cost checks (BH-5564, wave 7 of #5556)](2026-10-14-BH-5564-quartermaster.md)
- 2026-10-12 — [BH-6175: failed calls write a priced $0 row; unpriced calls alert per lane (slice C5 of BH-5526)](2026-10-12-BH-6175-unpriced-calls.md)
- 2026-10-12 — [BH-6174: Mission Control shows each lane's spend today against its alert line and its ceiling (BH-5526 slice C4)](2026-10-12-BH-6174-lane-spend.md)
- 2026-10-11 — [Fly idle stops get a cost row, and Mission Control shows the idle machines (BH-6061)](2026-10-11-BH-6061-fly-idle-rows.md)
- 2026-10-11 — [The Fly idle reaper lane (BH-6061)](2026-10-11-BH-6061-fly-idle-reaper.md)
- 2026-10-11 — [BH-5526: a runaway spend ceiling per lane, seeded from p99, refusing only at a ticket boundary (slice C3)](2026-10-11-BH-5526-spend-ceiling.md)
- 2026-10-09 — [Prices are versioned DB rows, seeded from the committed files (BH-5652)](2026-10-09-BH-5652-prices-as-db-rows.md)
- 2026-10-08 — [BH-5526: spend alerts at 1.5x own p99 and at 3x the fleet $/PR median, refusing nothing (slice C2)](2026-10-08-BH-5526-spend-alerts.md)
- 2026-10-08 — [BH-5526: a day spend cap never stops a ticket midway (slice C0)](2026-10-08-BH-5526-budget-never-midway.md)
- 2026-10-08 — [BH-5526: the cost autohalt holds new builds only, never in-flight work (slice C1)](2026-10-08-BH-5526-autohalt-holds-at-boundary.md)
- 2026-10-06 — [A daily full CI run on main, and its red filed as a map gap (BH-4970, slice 3 of BH-4964)](2026-10-06-BH-4964-nightly-full.md)
- 2026-10-06 — [Merge-queue batches on /ci (BH-4972, C4 of BH-4964)](2026-10-06-BH-4964-c4-ci-screen.md)
- 2026-10-06 — [A per-batch CI cost ledger: one row per merge-queue batch run (BH-4971, C3 of BH-4964)](2026-10-06-BH-4964-c3-ledger.md)
- 2026-10-06 — [A member's `full` label escalates a batch, and the SPA and worker jobs skip batches that cannot touch them (BH-4969, C1 of BH-4964)](2026-10-06-BH-4964-c1-member-label-spa-worker.md)
- 2026-10-06 — [A merge-queue batch runs its impact set, not the whole corpus (BH-4968, C0 of BH-4964)](2026-10-06-BH-4964-c0-batch-impact.md)
- 2026-10-04 — [The cost rollup's checkpoints live in the DB (BH-4158)](2026-10-04-BH-4158-cost-checkpoints-db.md)
- 2026-10-04 — [Cost and lane caps as settings seed rows (BH-4155)](2026-10-04-BH-4155-caps-seed-rows.md)
- 2026-10-03 — [2026-10-03 — BH-4020: daily idle Fly machine alert](2026-10-03-BH-4020-fly-idle-check.md)
- 2026-10-03 — [The cost-rows allow list reaches --box and --verify, and a missing list says so (BH-3982, slice BH-4007)](2026-10-03-BH-4007-cost-rows-allowlist-all-modes.md)
- 2026-10-03 — [One price table, the missing rows, and `row_source=killed` (BH-3990)](2026-10-03-BH-3990-pricing-one-table.md)
- 2026-10-03 — [A Fly infra cost row at the live-machine reap (BH-4019, child 2 of #3989)](2026-10-03-BH-3989-fly-cost-rows.md)
- 2026-10-03 — [The extra-usage meter pages back, says why a poll failed, and is loud when it fails or freezes (BH-3985)](2026-10-03-BH-3985-extra-usage-meter.md)
- 2026-10-03 — [Grok rows record the fleet's price, not the vendor's ticks; a backfill for the history (BH-3984)](2026-10-03-BH-3984-grok-cost-reprice.md)
- 2026-10-03 — [The cron cost-rows mirror drops rows from projects that are not in the fleet (BH-3982, slice BH-4004)](2026-10-03-BH-3982-fixture-cost-rows.md)
- 2026-10-03 — [A PR head buys one lead review, and the fleet counts the ones it paid twice (BH-3941)](2026-10-03-BH-3941-lead-review-dedupe.md)
- 2026-09-29 — [Stage-less lanes report no cost; the fleet's spend moves to /costs SPEND BREAKDOWN (BH-3557)](2026-09-29-BH-3557-stageless-lane-cost.md)
- 2026-09-29 — [The mid-build spend tripwire: rules, pause row, launch guard (BH-3481.4)](2026-09-29-BH-3481.4-tripwire.md)
- 2026-09-29 — [The live cost meter and the boundary push (BH-3481.3)](2026-09-29-BH-3481.3-live-meter.md)
- 2026-09-29 — [Live cost rows: the cost_rows_live table, /api/cost/live, and the rollup's live block (BH-3481.2)](2026-09-29-BH-3481.2-live-route.md)
- 2026-09-29 — [A split child plans warm: delta pre-plan, child model route, `delta` cost tag (BH-3495)](2026-09-29-BH-3478-child-context-pack.md)
- 2026-09-28 — [Project triage off grok, and a fast-fail cooldown for any runner (BH-3224)](2026-09-28-BH-3224-triage-off-grok.md)
- 2026-09-28 — [Tests never write cost rows into the production cost_rows table (BH-3223)](2026-09-28-BH-3223-no-test-cost-rows.md)
- 2026-09-28 — [Cost rows keep lane_id and guard_fp from the emitter (BH-3220)](2026-09-28-BH-3220-cost-rows-lane-id.md)
- 2026-09-27 — [GET /api/metrics/llm-sites answers one real row per LLM site](2026-09-27-BH-2554-llm-sites-aggregate.md)
- 2026-09-26 — [Triage no-signal settle: four follow-ups (settled rows, alert row, relayed content, identities)](2026-09-26-BH-2604-triage-signal-follow-ups.md)
- 2026-09-26 — [The cost brake reaches the owning box during a harness-jobs outage](2026-09-26-BH-2599-cost-local-brake.md)
- 2026-09-26 — [Cost-caps contract: table, stub routes, Costs page mount points (BH-2511.0, BH-2563)](2026-09-26-BH-2563-cost-caps-contract.md)
- 2026-09-26 — [The cost read-out is a rendered table, not a model turn](2026-09-26-BH-2550-cost-readout-deterministic.md)
- 2026-09-26 — [The watchdog responder settles two known conditions without a model call](2026-09-26-BH-2548-responder-scripted-fixes.md)
- 2026-09-26 — [Review savings: a cheap route for trivial diffs, and every skipped review is counted](2026-09-26-BH-2545-review-savings.md)
- 2026-09-26 — [alerts-medic and watchdog-responder are priced in full](2026-09-26-BH-2541-medic-responder-priced.md)
- 2026-09-26 — [cost-readout and runner-bench bill to their own stage and project](2026-09-26-BH-2539-cost-readout-runner-bench-attribution.md)
- 2026-09-26 — [Cost readers read D1 only; no box is reached over ssh](2026-09-26-BH-2527-cost-readers-no-ssh.md)
- 2026-09-25 — [Triage shards settle a no-signal ticket change without a session](2026-09-25-BH-2542-triage-signal-settle.md)
- 2026-09-25 — [The cost autohalt writes pause rows only; box harness HEADs come from box_status](2026-09-25-BH-2529-box-head-from-box-status.md)
- 2026-09-25 — [review-prs: the D1 hold has a time limit, then subscription runners only](2026-09-25-BH-2457-review-prs-d1-hold-fallback.md)
- 2026-09-25 — [New unpriced pair alert: no usage is a parse problem, not a catalog one](2026-09-25-BH-2416-unpriced-no-usage-diagnosis.md)
- 2026-09-25 — [Cost breaker card: RESET clears CAP HIT, the proxy wants a reason, the hub publishes autohalt](2026-09-25-BH-2397-cost-breaker-followups.md)
- 2026-09-25 — [Mission Control shows the cost breaker and can reset the call guard](2026-09-25-BH-2331-cost-breaker-card.md)
- 2026-09-25 — [review-prs holds a paid review when the D1 verdict ledger cannot be read](2026-09-25-BH-2315-review-prs-d1-first.md)
- 2026-09-25 — [cost-rollup binds a build dir to its PR from the ledger (BH-2312.4)](2026-09-25-BH-2312-builds-of-record-cost-rollup.md)
- 2026-09-25 — [Unpriced cost rows: who is behind them, and a daily alert for a new pair](2026-09-25-BH-2306-unpriced-pairs.md)
- 2026-09-24 — [K1: the cost breakers brake, see zero-merge spend, count unpriced rows, and read the whole fleet](2026-09-24-K1-cost-containment.md)
- 2026-09-24 — [Account usage contract: `GET /api/metrics/account-usage` answers a stub shape](2026-09-24-BH-167-account-usage.md)
- 2026-09-24 — [The grok envelope probe, grok rows in cli_versions, and a per-box grok requirement](2026-09-24-BH-1636-grok-envelope-probe-and-per-box-cli.md)
- 2026-09-23 — [A codex-driven call reads its own session ledger, not the newest one](2026-09-23-BH-62-codex-session-binding.md)
- 2026-09-23 — [grok output tokens include reasoning, and agent-call.sh's knobs are settings rows](2026-09-23-BH-1636-grok-reasoning-and-agent-call-knobs.md)
- 2026-09-23 — [BH-1384 (BH-1201.3): the act session capped under the model cliff, the decision call pinned to claude](2026-09-23-BH-1384-responder-cliff-cap.md)
- 2026-09-22 — [grok is a runner CLI the fleet updates daily, and its 1.0.x cost row prices](2026-09-22-BH-1494-grok-cli-daily-update.md)
- 2026-09-22 — [BH-1361: the model → slug map is data (catalog/model-slugs.json), and the UNPRICED alert writes the line for you](2026-09-22-BH-1361-model-slugs-catalog.md)
- 2026-09-19 — [Every cost row is priced at write time, and a runner that floods the ledger with blank ones pages](2026-09-19-BH-1020-cost-row-priced.md)
- 2026-09-18 — [The grok lane stops paying the 200K doubling](2026-09-18-BH-656-runner-cliff.md)

## DB-COORDINATION-SPEC

- 2026-10-17 — [Docker-pool claim lease (BH-7300, slice C0)](2026-10-17-BH-7300-docker-pool-lease.md)
- 2026-10-16 — [The scheduler computes the ready set in shadow (BH-6978, BH-6547.2)](2026-10-16-BH-6978-scheduler-shadow.md)
- 2026-10-16 — [Measure and retire lessons (BH-5808, wave 3 of #5794)](2026-10-16-BH-5808-lesson-measure.md)
- 2026-10-15 — [Ticket edges and holds are rows (BH-6977, BH-6547.1)](2026-10-15-BH-6977-ticket-edges.md)
- 2026-10-15 — [Every alert belongs to a component (BH-6971)](2026-10-15-BH-6971-alert-components.md)
- 2026-10-15 — [Staff autonomy and delegation controls, with an audit (BH-6824, Staff in Mission Control 3/4)](2026-10-15-BH-6824-staff-autonomy-controls.md)
- 2026-10-15 — [Talk to a staff agent (BH-6823, slice 2/4 of Staff in Mission Control)](2026-10-15-BH-6823-staff-chat.md)
- 2026-10-15 — [Staff agent detail page (BH-6822, slice 1/4 of Staff in Mission Control)](2026-10-15-BH-6822-staff-agent-detail.md)
- 2026-10-15 — [Propose fixes for repeat causes (BH-5807, wave 2 of #5794)](2026-10-15-BH-5807-lesson-propose.md)
- 2026-10-14 — [Review autopilot: the record is ledger rows when no-twin-ledgers is up (BH-4156 C1)](2026-10-14-BH-4156-review-autopilot-rows.md)
- 2026-10-14 — [Merge-conductor state: one attempt read per repo per tick, and the fresh-hub drill (BH-4156)](2026-10-14-BH-4156-mc-batch-read-drill.md)
- 2026-10-14 — [The main-red lanes keep their records as rows (BH-4156, child C2)](2026-10-14-BH-4156-main-red-state-tables.md)
- 2026-10-13 — [CREATED_TABLES derives from worker/jobs/schema.d (BH-4987, slice C5)](2026-10-13-BH-4987-created-tables-derived.md)
- 2026-10-13 — [The pause_flags mirror is retired, and a lint freezes new flags/ writes (BH-4154, slice C0)](2026-10-13-BH-4154-mirror-retired.md)
- 2026-10-12 — [flag_on reads a ported routing name from its row (BH-5960)](2026-10-12-BH-5960-routing-rows-flag-on.md)
- 2026-10-11 — [Step in: notes reach the running build, the ticket and the hold (BH-5839)](2026-10-11-BH-5839-steer-notes.md)
- 2026-10-10 — [A project's migration SQL can live outside scripts/migrations (BH-5963)](2026-10-10-BH-5963-migrations-glob.md)
- 2026-10-10 — [Classify every BLOCK (BH-5806, wave 1 of #5794)](2026-10-10-BH-5806-classify-blocks.md)
- 2026-10-10 — [Staff screen (BH-5567, wave 10 of #5556)](2026-10-10-BH-5567-staff-screen.md)
- 2026-10-09 — [BH-5781: D1 overload relief](2026-10-09-BH-5781-d1-overload.md)
- 2026-10-09 — [Prices are versioned DB rows, seeded from the committed files (BH-5652)](2026-10-09-BH-5652-prices-as-db-rows.md)
- 2026-10-09 — [Mission Control flag columns and toggles (BH-5635.4)](2026-10-09-BH-5635.4-mission-control-flags.md)
- 2026-10-09 — [Pool routing and the WIP limit read through flag-on.sh (BH-5635.3)](2026-10-09-BH-5635.3-pool-callsites.md)
- 2026-10-09 — [Flag CLI and the one-time hub seed (BH-5635.1)](2026-10-09-BH-5635.1-flag-cli.md)
- 2026-10-09 — [One flag reader, fail-closed on a failed read (BH-5635.0)](2026-10-09-BH-5635.0-flag-reader.md)
- 2026-10-09 — [Staff findings ledger and suppressions (BH-5560, wave 3 of #5556)](2026-10-09-BH-5560-staff-findings.md)
- 2026-10-09 — [Staff charter and autonomy tables (BH-5559, wave 2 of #5556)](2026-10-09-BH-5559-staff-charter.md)
- 2026-10-08 — [Suite ledger: run a suite once per input fingerprint (BH-5354.0 / BH-5366)](2026-10-08-BH-5354-suite-reuse.md)
- 2026-10-07 — [jobs-client's usage line is generated from the arms (BH-5264, BH-5235.4)](2026-10-07-BH-5235-jobs-client-usage.md)
- 2026-10-07 — [New scripts may not write row-backed state paths (BH-5005, wave 6 of #4951)](2026-10-07-BH-5005-state-paths-guard.md)
- 2026-10-07 — [Pause flags decide from the pause_flags row (BH-5004, wave 5 of #4951)](2026-10-07-BH-5004-flag-row-authority.md)
- 2026-10-07 — [PR owner clocks, build notes and the digest guard become DB rows (BH-5003, wave 4 of #4951)](2026-10-07-BH-5003-owners-notes-digest-rows.md)
- 2026-10-07 — [Cross-box claims read from the DB (BH-5002, BH-4951.3)](2026-10-07-BH-5002-claims-cross-box.md)
- 2026-10-07 — [The Fly pool's spawn caps, terminals and holds as rows](2026-10-07-BH-5001-pool-state-db.md)
- 2026-10-06 — [Archie's second playbook: the data lane (BH-4927, BH-4920.4)](2026-10-06-BH-4927-archie-data-lane.md)
- 2026-10-06 — [Archie, factory manager: stacks of three, the cap by action, killed ticks (BH-4784)](2026-10-06-BH-4784-archie-fm-stacks.md)
- 2026-10-05 — [Archie, whole-factory watch: one lever per incident, one ticket if it did not take (BH-4586, wave 4 of #4574)](2026-10-05-BH-4586-archie-fm-watch.md)
- 2026-10-05 — [BH-4585 (BH-4574.3): Archie's rebase-repair playbook](2026-10-05-BH-4585-archie-fm-playbooks.md)
- 2026-10-05 — [Archie, queue doctor: batch culprits, unqueued approvals, stale conductor rows (BH-4584, wave 2 of #4574)](2026-10-05-BH-4584-archie-fm-queue.md)
- 2026-10-05 — [Archie, factory manager: one stuck-PR playbook (BH-4583, wave 1 of #4574)](2026-10-05-BH-4583-archie-fm-tracer.md)
- 2026-10-05 — [BH-4489: hard caps on every stage and scope](2026-10-05-BH-4489-budget-caps-scopes.md)
- 2026-10-04 — [Archie's earned autonomy (BH-4067, wave 6 of #3966)](2026-10-04-BH-4067-archie-autonomy.md)
- 2026-10-04 — [Archie's research scout: X and web into the Ideas ledger (BH-4065, wave 4 of #3966)](2026-10-04-BH-4065-archie-research-scout.md)
- 2026-10-04 — [Archie wakes on events, not only on his schedule (BH-4063, wave 2 of #3966)](2026-10-04-BH-4063-archie-wakeups.md)
- 2026-10-03 — [Archie's tracer: initiative, check, message (BH-4062, wave 1 of #3966)](2026-10-03-BH-4062-archie-tracer.md)
- 2026-09-29 — [Hub-probe request ledger: table and worker routes (BH-3448, BH-3434.1)](2026-09-29-BH-3448-hub-probe-ledger-routes.md)
- 2026-09-29 — [Pool builds fetch their own pre-plan, every box publishes one, and the hit rate is watched (BH-3437)](2026-09-29-BH-3437-preplan-db-adopt.md)
- 2026-09-28 — [A queued build row follows the project's routing, and a row nothing will claim pages (BH-3316)](2026-09-28-BH-3316-stranded-queue-target.md)
- 2026-09-28 — [HOLD / UNHOLD on the Build screen (BH-3149, BH-2326.3)](2026-09-28-BH-2326.3-build-hold-control.md)
- 2026-09-28 — [The hub handler for hold_ticket / unhold_ticket (BH-3147, BH-2326.1)](2026-09-28-BH-2326.1-ticket-hold-handler.md)
- 2026-09-28 — [The ticket-hold contract in the console (BH-3146, BH-2326.0)](2026-09-28-BH-2326-ticket-hold-console.md)
- 2026-09-28 — [Split-watchdog ledger: worker routes and shell verbs (BH-1806, BH-1793.1)](2026-09-28-BH-1806-split-watchdog-ledger-routes.md)
- 2026-09-27 — [A board pause says when it ends, and a flag flip leaves a trace](2026-09-27-V1-pause-expiry-flag-audit.md)
- 2026-09-27 — [config_changes: worker audit rows for cap, topic, seed and rule-delete writes (BH-2996, BH-2992.2)](2026-09-27-BH-2992-worker-audit.md)
- 2026-09-27 — [Fix-round finish and adopt retries are idempotent (BH-2997, BH-2992.3)](2026-09-27-BH-2992-fix-round-idempotent.md)
- 2026-09-27 — [config_changes: three new kinds and delete rows (BH-2994, BH-2992.0)](2026-09-27-BH-2992-contract.md)
- 2026-09-27 — [Box console command routes: /api/box-console-commands (BH-2654, BH-2528.1)](2026-09-27-BH-2654-box-console-commands-routes.md)
- 2026-09-27 — [Cost-caps editor, worker half: validator, routes, audit, seed split (BH-2511 W1-W3, BH-2564)](2026-09-27-BH-2564-cost-caps-editor-worker.md)
- 2026-09-27 — [/config/:kind/:name shows the current row and its history (BH-2379)](2026-09-27-BH-2379-config-detail-page.md)
- 2026-09-27 — [/config lists every setting and flag, with audited edits (BH-2378)](2026-09-27-BH-2378-config-list.md)
- 2026-09-27 — [Flag writes land in config_changes (BH-2377)](2026-09-27-BH-2377-flag-write-audit.md)
- 2026-09-27 — [Settings writes land in config_changes (BH-2376)](2026-09-27-BH-2376-settings-change-audit.md)
- 2026-09-27 — [/config stubs over the one audit store (BH-2375)](2026-09-27-BH-2375-config-changes-read.md)
- 2026-09-26 — [Product lanes write through to proposal rows (BH-2531 part 3, BH-2720)](2026-09-26-BH-2720-product-lane-rows.md)
- 2026-09-26 — [post-proposal asks the proposal row before it posts (BH-2531 part 3, BH-2719)](2026-09-26-BH-2719-post-proposal-row-guard.md)
- 2026-09-26 — [A stopped pool machine's result comes from a row, and the pause names its source (BH-2643)](2026-09-26-BH-2643-pool-result-row.md)
- 2026-09-26 — [The coord proxy admits the Controls editors' four PUTs (BH-2513.2, BH-2619)](2026-09-26-BH-2619-coord-controls-allowlist.md)
- 2026-09-26 — [Pre-plan outcome as a stage_events row, and GET /api/preplans/adoption (BH-2543 slice 2, BH-2571)](2026-09-26-BH-2571-preplan-outcome-event.md)
- 2026-09-26 — [Cost-caps contract: table, stub routes, Costs page mount points (BH-2511.0, BH-2563)](2026-09-26-BH-2563-cost-caps-contract.md)
- 2026-09-26 — [Product proposal rows: the table and the shell client (BH-2531 part 1, BH-2717)](2026-09-26-BH-2531-product-proposal-rows.md)
- 2026-09-26 — [The hub queues fix rounds as rows and adopts their results (BH-2674, BH-2530.3)](2026-09-26-BH-2530-fix-round-queue.md)
- 2026-09-26 — [Fleet file claims: the two overlap readers read job_claims (BH-2524, BH-2630)](2026-09-26-BH-2524-file-claims-db.md)
- 2026-09-26 — [The Fly image pointer, bake and bake time as a fly_images row](2026-09-26-BH-2523-fly-images.md)
- 2026-09-26 — [Registry seed apply: worker routes, fleet gate, run table (BH-2521.2, BH-2676)](2026-09-26-BH-2521-seed-apply-worker.md)
- 2026-09-26 — [/hub CHAT BINDINGS table with edit (BH-2521 slice 3, BH-2678)](2026-09-26-BH-2521-chat-bindings.md)
- 2026-09-26 — [Queue-row knob flips get a preflight (BH-2338, BH-2313.0)](2026-09-26-BH-2338-queue-row-flips.md)
- 2026-09-25 — [The cost autohalt writes pause rows only; box harness HEADs come from box_status](2026-09-25-BH-2529-box-head-from-box-status.md)
- 2026-09-25 — [Fleet cooldown knobs are settable, the guard is capped at the lane TTL, old tombs are collected (BH-2498)](2026-09-25-BH-2498-fleet-cooldown-knobs.md)
- 2026-09-25 — [CI replays worker schema.sql over main's, the way live D1 gets it](2026-09-25-BH-2473-schema-upgrade-replay.md)
- 2026-09-25 — [The ledger list pages on `(updated_at, key)`, not on a timestamp alone](2026-09-25-BH-2450-ledger-compound-cursor.md)
- 2026-09-25 — [Alert actions: the contract slice (BH-2368)](2026-09-25-BH-2368-alert-actions-contract.md)
- 2026-09-25 — [BH-2343 (BH-2316.0): brake ledger helper and alert_families state filter](2026-09-25-BH-2343-brake-ledger.md)
- 2026-09-25 — [Fleet cooldowns: the worker store (BH-2353, part of BH-2319)](2026-09-25-BH-2319-fleet-cooldowns.md)
- 2026-09-25 — [The triage gate's state has a ledger twin, so a moved box does not re-buy a triage](2026-09-25-BH-2318-triage-gate-ledger.md)
- 2026-09-25 — [The once-only comment markers and the resolver's counters are D1 rows](2026-09-25-BH-2317-comment-marks-db.md)
- 2026-09-25 — [Alert triage: the brake and the spools get a DB copy (BH-2344 / BH-2316.1)](2026-09-25-BH-2316-triage.md)
- 2026-09-25 — [The responder's 12h cooldown survives a dead hub (BH-2346, BH-2316.3)](2026-09-25-BH-2316-responder.md)
- 2026-09-25 — [BH-2345 (BH-2316.2): the medic's brakes survive a dead hub](2026-09-25-BH-2316-medic.md)
- 2026-09-25 — [BH-2350 (BH-2312.3): the orphan scan and the triage gate read the builds-of-record ledger](2026-09-25-BH-2312-builds-of-record-stale-owed-triage-gate.md)
- 2026-09-24 — [DEAD column holds back build rows whose GitHub issue is closed](2026-09-24-BH-938-dead-closed-issues.md)
- 2026-09-24 — [Kanban reads the whole issue_state ledger, not just its newest 1000 rows](2026-09-24-BH-2206-closed-issue-paging.md)
- 2026-09-24 — [An empty JOBS_URL is "not configured", the watchdog box list is config, and a failed merge-queue touch pages](2026-09-24-BH-1957-fork-safe-defaults.md)
- 2026-09-23 — [Pause flags reconcile last-writer-wins on mtime, and the watermark is gone](2026-09-23-BH-1370-flag-authority-lww.md)
- 2026-09-23 — [A rescued review reaches `logs/findings.log`: review-rescue clears `.findings-general`](2026-09-23-BH-118-rescued-review-harvest.md)
- 2026-09-22 — [2026-09-22 — BH-1531: the baked-CLI drift floor now runs on failed nights too](2026-09-22-BH-1531-fly-image-cli-followups.md)
- 2026-09-22 — [BH-1385 (BH-1025.0): pr_state_events / pr_attempts, the client verbs, the conductor helpers](2026-09-22-BH-1385-pr-rows-contract.md)
- 2026-09-22 — [Corrections to the BH-1036 record: 120 assertions, six kinds, and what section H actually does](2026-09-22-BH-1330-bh-1036-record-corrections.md)
- 2026-09-22 — [BH-1026.0 (BH-1364): the queues-are-rows contract — three dark knobs, one shared active-key read](2026-09-22-BH-1026-queues-are-rows.md)
- 2026-09-19 — [BH-1058 — fly-pool-tick.sh onboard-drain resolves retry policy from retry_policies](2026-09-19-BH-1058-onboard-retry-policy.md)
- 2026-09-19 — [2026-09-19 — BH-1057: the two one-shot Fly state writers now write their DB twin](2026-09-19-BH-1057-provision-image-rows.md)
- 2026-09-19 — [Pool writes Fly machine registry rows (observe, put, close, advisory)](2026-09-19-BH-1056-fly-pool-machine-rows.md)
- 2026-09-19 — [The Fly machine registry routes are wired](2026-09-19-BH-1055-machines-routes.md)
- 2026-09-19 — [Fly machine registry contract chunk (BH-1054)](2026-09-19-BH-1054-fly-machines-contract.md)
- 2026-09-19 — [Four small ledger bugs: a stamp, a cursor, a stamp that outlived its rows, and a stale map](2026-09-19-BH-1042-small-ledger-bugs.md)
- 2026-09-19 — [A finished remote build reaches its box once: the ledger row is the dedupe key, and "could not ask" never relays](2026-09-19-BH-1041-remote-result-relay-once.md)
- 2026-09-19 — [2026-09-19 — BH-1040: the migration ledger answers three ways, and "cannot ask" holds](2026-09-19-BH-1040-migration-ledger-three-answers.md)
- 2026-09-19 — [The six file-only idempotency markers get a row twin, behind one flag](2026-09-19-BH-1036-no-twin-ledgers.md)
- 2026-09-19 — [The jobs worker answers /api/alerts: note, state, resolve, claim, flush, list, families](2026-09-19-BH-1030-alerts-routes.md)

## DORA

- 2026-10-15 — [Who spends the GitHub REST budget (BH-6974, wave 1 of 3 of #6545)](2026-10-15-BH-6974-gh-budget-report.md)
- 2026-10-12 — [Rework rollup: completeness is per repo and week (BH-6165)](2026-10-12-BH-6165-rework-week-complete.md)
- 2026-10-03 — [`reworked`, a fourth outcome in bin/outcome-metrics.sh (BH-3956)](2026-10-03-BH-3956-rework-outcome.md)

## E2E-POLICY

- 2026-09-19 — [2026-09-19 — BH-1047: the test-tamper gate learns that a stub flip is not a deletion](2026-09-19-BH-1047-stub-flip-not-deletion.md)

## FINDINGS-LOG

- 2026-09-23 — [findings-log stops logging review scaffolding as findings](2026-09-23-BH-123-findings-scaffold-filter.md)

## FLAKY-TESTS

- 2026-10-14 — [CI test value report: the extra sources and the report (BH-6640, BH-6618.4)](2026-10-14-BH-6618.4-report.md)
- 2026-10-14 — [CI test value report: the model fallback (BH-6639, BH-6618.3)](2026-10-14-BH-6618.3-model-fallback.md)
- 2026-10-14 — [CI test value report: the catch, test defect and order rules (BH-6638, BH-6618.2)](2026-10-14-BH-6618.2-catch-rules.md)
- 2026-10-14 — [CI test value report: the infra and flake rules (BH-6637, BH-6618.1)](2026-10-14-BH-6618.1-infra-flake-rules.md)
- 2026-10-14 — [CI test value report: the tracer CLI (BH-6636, BH-6618.0)](2026-10-14-BH-6618-ci-test-value-report.md)
- 2026-10-11 — [The local test image runs gawk as awk; the tag moves to trixie.5 (BH-5583)](2026-10-11-BH-5583-test-image-gawk.md)
- 2026-10-09 — [The flaky-tier lane can release a quarantine row again (BH-4321)](2026-10-09-BH-4321-flaky-tier-release-wiring.md)
- 2026-10-05 — [BH-4585 (BH-4574.3): Archie's rebase-repair playbook](2026-10-05-BH-4585-archie-fm-playbooks.md)
- 2026-10-02 — [Foreign-red attribution follow-ups: hub checkout, a later batch must have run the suite, cached reads, strict parse (BH-3857)](2026-10-02-BH-3857-foreign-red-hub-checkout.md)
- 2026-10-01 — [The conductor's CI writes check the PR's live head first (BH-3804)](2026-10-01-BH-3804-ci-writes-live-head.md)
- 2026-10-01 — [A PR ejected from a red Mergify batch it did not break is re-queued once (BH-3776)](2026-10-01-BH-3776-foreign-red-requeue.md)
- 2026-09-26 — [Mission Control has a CI health screen with the flaky-test quarantine toggle](2026-09-26-BH-2634-ci-health.md)
- 2026-09-26 — [Audited flake quarantine routes and the merge gate (BH-2632, BH-2517.1)](2026-09-26-BH-2632-flake-quarantine-gate.md)
- 2026-09-20 — [The post-checkout hook always exits 0, ignores file checkouts, and reaches a hub that already has it; the test image gets rsync](2026-09-20-BH-1128-hook-exit-and-test-image-rsync.md)

## FLY-BUILDER-TRIAL

- 2026-10-18 — [The harness sync heals a failed fast-forward, and the pool pages when it is under-used (BH-7382)](2026-10-18-BH-7382-sync-self-heal-pool-underuse.md)
- 2026-10-16 — [The pool reclaims orphan slots, names a stall, and cancels held in-flight builds (BH-7107)](2026-10-16-BH-7107-pool-orphan-reclaim.md)
- 2026-10-15 — [Nightly filer labels as the App; the pool checks the label actor before a spawn (BH-6957)](2026-10-15-BH-6957-nightly-filer-actor.md)
- 2026-10-07 — [A reused pool machine never hands a held build slot to the next build (BH-5021)](2026-10-07-BH-5021-pool-slot-clean.md)
- 2026-10-07 — [BH-5006: pool close-out custody sweep, and a terminal skip that says why](2026-10-07-BH-5006-pool-custody.md)
- 2026-10-07 — [The Fly pool's spawn caps, terminals and holds as rows](2026-10-07-BH-5001-pool-state-db.md)
- 2026-09-30 — [fleet-propagate: warn while a pool retry is queued, page when retries run out (BH-3680)](2026-09-30-BH-3680-propagate-page-severity.md)
- 2026-09-29 — [Pool bakes: warm-build timeout, capture, catalog skip, capped retry (BH-3463)](2026-09-29-BH-3463-pool-warm-timeout.md)
- 2026-09-27 — [Credential probes are real; the fly SMOKE job spends no inference](2026-09-27-BH-2559-cred-probe-real.md)
- 2026-09-26 — [The Fly image pointer, bake and bake time as a fly_images row](2026-09-26-BH-2523-fly-images.md)

## FLY-ONBOARD

- 2026-09-19 — [BH-1058 — fly-pool-tick.sh onboard-drain resolves retry policy from retry_policies](2026-09-19-BH-1058-onboard-retry-policy.md)

## FLY-POOL

- 2026-10-17 — [Pool machines no longer exit before the hub pushes their job (BH-7215)](2026-10-17-BH-7215-pool-warmup.md)
- 2026-10-16 — [The pool never waits on a number we chose, and a machine-hour budget bounds the spend (BH-7190)](2026-10-16-BH-7190-pool-never-wait.md)

## FLY-POOL-RESPAWN-CAP

- 2026-10-15 — [A pool "push rejected" is compared with the remote before it is terminal (BH-6821)](2026-10-15-BH-6821-pool-push-rejected-landed.md)
- 2026-10-13 — [The pool caches each issue's HOLD verdict, so a held ticket costs no thread read (BH-6549)](2026-10-13-BH-6549-pool-hold-cache.md)
- 2026-10-11 — [Overlap deferrals stop using up the per-key pool spawn cap (BH-5912)](2026-10-11-BH-5912-overlap-defer-uncounted.md)
- 2026-10-06 — [The pool bundles before it spawns, and the spawn cap is a timed retry (BH-4859)](2026-10-06-BH-4859-bundle-before-spawn.md)
- 2026-09-26 — [A stopped pool machine's result comes from a row, and the pause names its source (BH-2643)](2026-09-26-BH-2643-pool-result-row.md)
- 2026-09-19 — [BH-1075 — Fly pool no longer re-spawns a ticket whose push was rejected](2026-09-19-BH-1075-fly-pool-respawn-cap.md)

## GH-REST

- 2026-10-13 — [The pool caches each issue's HOLD verdict, so a held ticket costs no thread read (BH-6549)](2026-10-13-BH-6549-pool-hold-cache.md)
- 2026-10-06 — [BH-4798: a box with no plain PAT no longer stops the pool at the env bundle](2026-10-06-BH-4798-pool-bundle-no-pat.md)
- 2026-10-05 — [BH-4659 (BH-4656.1): the conductor and batch-resolve read the PR snapshot; branch tips from one refs read](2026-10-05-BH-4659-pr-snapshot-lanes.md)
- 2026-10-05 — [BH-4658 (BH-4656 part 1): the PR snapshot, and lead-review-enqueue reads heads through it](2026-10-05-BH-4656-pr-snapshot.md)
- 2026-10-04 — [BH-4477: `bin/gh-ledger-report.sh`, the caller × endpoint view of the GitHub REST ledger](2026-10-04-BH-4477-gh-ledger-report.md)
- 2026-09-26 — [Shared untriaged read layer: bin/lib/untriaged-lib.sh (BH-2751 part 1, BH-2752)](2026-09-26-BH-2752-untriaged-lib.md)
- 2026-09-26 — [Untriaged digest lane: bin/untriaged-digest.sh (BH-2756, BH-2751 ask 4)](2026-09-26-BH-2751-untriaged-digest.md)
- 2026-09-24 — [C2: every fleet cron lane defaults to the GitHub App, not the operator's PAT](2026-09-24-C2-gh-app-default-cron.md)
- 2026-09-24 — [Single-site issue reads and writes moved to REST](2026-09-24-BH-1651-single-site-issue-reads-rest.md)
- 2026-09-22 — [A new `gh` subcommand in the harness is now red until the census covers it](2026-09-22-BH-791-gh-shim-passthrough-budget.md)

## HARNESS-COORDINATION

- 2026-10-17 — [Merge lock to the project lease, re-review cap to D1 (BH-6887, BH-6881.3)](2026-10-17-BH-6887-mc-lease-budget.md)
- 2026-10-16 — [The scheduler computes the ready set in shadow (BH-6978, BH-6547.2)](2026-10-16-BH-6978-scheduler-shadow.md)
- 2026-10-16 — [pipeline-health project runs off the hub: the fleet-wide writes (BH-6892, BH-6881.10)](2026-10-16-BH-6892-pipeline-health-offhub.md)
- 2026-10-16 — [Merge-conductor lane manifest and alert lines through the jobs API (BH-6889, BH-6881.5)](2026-10-16-BH-6889-mc-manifest-alert-lines.md)
- 2026-10-15 — [Ticket edges and holds are rows (BH-6977, BH-6547.1)](2026-10-15-BH-6977-ticket-edges.md)
- 2026-10-15 — [Project lease with a fence token (BH-6883, BH-6881.1)](2026-10-15-BH-6883-project-lease.md)
- 2026-10-14 — [The orchestrator handles box and project requests from chat (BH-5751)](2026-10-14-BH-5751-box-requests.md)
- 2026-10-10 — [2026-10-10 BH-5750: Mission Control box controls](2026-10-10-BH-5750-box-controls.md)
- 2026-10-03 — [fetch_artifact reads the pool build's remote dir, and a far box's answer reaches the beat (BH-3945)](2026-10-03-BH-3945-fetch-artifact-pool-dir-and-box-beat.md)
- 2026-09-26 — [An operator's ABANDON survives a worker outage on the box that saw it (BH-2505)](2026-09-26-BH-2505-abandon-cache.md)
- 2026-09-26 — [The main-red detector publishes the detail row and honours an operator clear (BH-2373)](2026-09-26-BH-2373-detector-main-red-row-and-clear.md)
- 2026-09-25 — [Mission Control can ABANDON a job, and nothing re-offers it](2026-09-25-BH-2406-job-abandon.md)
- 2026-09-25 — [Mission Control can RETRY and REQUEUE a job](2026-09-25-BH-2323-job-actions.md)
- 2026-09-24 — [The lanes honour pauses](2026-09-24-BH-1684-lanes-honor-pauses.md)

## HUB-RECOVERY-MCP

- 2026-10-07 — [Every project's conflict hotspots, measured weekly and stored as rows](2026-10-07-BH-5267-conflict-hotspots-fleet.md)
- 2026-09-26 — [Standby VERIFY from Mission Control: the console half (BH-2642, BH-2519.4)](2026-09-26-BH-2642-standby-verify-console.md)
- 2026-09-26 — [The standby heartbeat and verify-queue worker routes](2026-09-26-BH-2639-standby-worker-routes.md)
- 2026-09-24 — [The restore-lab routes and the hub lane that runs them](2026-09-24-BH-1944-restore-lab-routes.md)
- 2026-09-24 — [Hub recovery read and guarded promote are live (BH-1943)](2026-09-24-BH-1943-hub-recovery-routes.md)

## HUB-THINNING-PLAN

- 2026-09-26 — [Failover drill: renew pause, cron proposal, runbook (BH-402.4, BH-2750)](2026-09-26-BH-402-failover-drill.md)
- 2026-09-24 — [Watchdog hub failover: failoverTick promotes the one healthy standby](2026-09-24-BH-401-warm-standby-hub.md)
- 2026-09-19 — [`hub-lease.sh check` re-validates the cached epoch, behind a flag row; the hub checkout still has to be re-pointed by hand](2026-09-19-BH-1023-hub-lease-epoch.md)
- 2026-09-19 — [A missing D1 table is an answer now, the configured hub fails open, and the schema applies before the deploy](2026-09-19-BH-1000-hub-lease-fail-open.md)

## JOBS

- 2026-09-25 — [Builds of record: a ledger reader lib (BH-2312.0)](2026-09-25-BH-2312-builds-of-record-lib.md)
- 2026-09-25 — [cost-rollup binds a build dir to its PR from the ledger (BH-2312.4)](2026-09-25-BH-2312-builds-of-record-cost-rollup.md)

## LANES

- 2026-10-06 — [The resolver parks a data-lane block as DATA_LANE, never on the abandon ladder (BH-4926)](2026-10-06-BH-4926-resolver-data-lane-park.md)
- 2026-10-06 — [The appliability gate reads a scripts/migrate-*.ts migration (BH-4924)](2026-10-06-BH-4924-migrate-ts-lint.md)
- 2026-10-06 — [The data lane's first slice: a DATA_LANE: review line, and a head-bound pre-merge apply (BH-4923)](2026-10-06-BH-4923-data-lane-contract.md)
- 2026-10-06 — [The data lane proves its apply: probe, evidence file, evidence comment (BH-4925)](2026-10-06-BH-4920-data-lane.md)
- 2026-09-30 — [The lookback lane can be turned on: a dry week in the digest, then live (BH-3691)](2026-09-30-BH-3691-lookback-live.md)
- 2026-09-26 — [trap-eval and feature-map-draft name their lanes](2026-09-26-BH-2580-trap-eval-feature-map-lanes.md)
- 2026-09-25 — [Build calls bind the fly-pool lane (BH-2533 part 1, BH-2578)](2026-09-25-BH-2533-llm-knobs-every-lane.md)

## LEAD-REVIEW

- 2026-10-18 — [The review gets a NOTE for each body item the plan requires and the PR body lacks (BH-7378)](2026-10-18-BH-7378-pr-body-requires.md)
- 2026-10-17 — [The self-check refuses a gating PR with no fenced live-probes block (BH-7074)](2026-10-17-BH-7074-live-probes-gating.md)
- 2026-10-16 — [A builder APPROVE carries to a merge-only head, and the replay fetch retries (BH-7043)](2026-10-16-BH-7043-builder-carry.md)
- 2026-10-13 — [A PR carries only its own ticket's commits (BH-6394)](2026-10-13-BH-6394-foreign-commits.md)
- 2026-10-13 — [A test belongs to its ticket: the self-check enforces D51 (BH-6392)](2026-10-13-BH-6392-test-ownership.md)
- 2026-10-13 — [BH-6391: a lead re-review reads the delta, and keeps old findings stable](2026-10-13-BH-6391-rereview-delta-scope.md)
- 2026-10-13 — [2026-10-13 BH-6372.3: the lead review caps INCONCLUSIVE evidence on perf PRs at BLOCK](2026-10-13-BH-6372-lead-review-cap.md)
- 2026-10-13 — [Hold, retry and spend gates on the lead review worklist (BH-5876, child 4 of #5870)](2026-10-13-BH-5876-lead-gates-holds-caps.md)
- 2026-10-12 — [pr-self-check ends a body section at a same-or-higher heading (BH-6191)](2026-10-12-BH-6191-psc-section-level.md)
- 2026-10-12 — [The lead review keeps the review, not the postscript (BH-6090)](2026-10-12-BH-6090-lead-review-postscript.md)
- 2026-10-11 — [Silence, risk tier and in-build grace gates on the lead review worklist (BH-5875, child 3 of #5870)](2026-10-11-BH-5875-lead-gates-silence-risk.md)
- 2026-10-11 — [The lead review builds on the builder review of the same head (BH-5355)](2026-10-11-BH-5355-lead-builds-on-builder.md)
- 2026-10-09 — [The pre-review self-check: a PR body must match its head (BH-5798)](2026-10-09-BH-5798-pr-self-check.md)
- 2026-10-08 — [A reset lead review lands its new verdict (BH-5400)](2026-10-08-BH-5400-lead-review-reland.md)
- 2026-10-08 — [The lead review checks conflict shape, and its prompt carries the project's hotspots (BH-5271)](2026-10-08-BH-5271-lead-review-conflict-shape.md)

## LEDGER-HYGIENE

- 2026-09-25 — [flags/ config files read as settings rows (BH-2411, BH-2320.C5)](2026-09-25-BH-2411-conf-rows.md)

## LIB-ROOT-RESOLUTION

- 2026-09-28 — [BH-2652 (BH-2613.4): account, model, fan-in and record libs have no literal root](2026-09-28-BH-2652-lib-root-records.md)
- 2026-09-28 — [BH-2650 (BH-2613.2): triage, hotfix, pause and heartbeat libs have no literal root](2026-09-28-BH-2650-lib-root-triage.md)
- 2026-09-28 — [lane-gate, jobs/req, endpoints and the cost libs: no literal /root/harness root (BH-2649)](2026-09-28-BH-2649-lib-root-lane-gate-cost.md)
- 2026-09-26 — [bin/lib root resolution: no literal /root/harness fallback (contract, ratchet, child map)](2026-09-26-BH-2613-lib-root-resolution.md)

## LLM_CALL_SITES

- 2026-10-06 — [Archie's research scout finishes its scoring and binds the cap per call (BH-4762)](2026-10-06-BH-4762-archie-research-produces.md)
- 2026-10-04 — [Archie's research scout: X and web into the Ideas ledger (BH-4065, wave 4 of #3966)](2026-10-04-BH-4065-archie-research-scout.md)
- 2026-09-27 — [Credential probes are real; the fly SMOKE job spends no inference](2026-09-27-BH-2559-cred-probe-real.md)
- 2026-09-27 — [LLM sites: the drill route answers real cost rows (BH-2540 part 3, BH-2555)](2026-09-27-BH-2555-llm-site-rows.md)
- 2026-09-27 — [GET /api/metrics/llm-sites answers one real row per LLM site](2026-09-27-BH-2554-llm-sites-aggregate.md)
- 2026-09-26 — [claude-cost follow-ups: K3 on the raw-claude callers, real lanes for box-chat and greenfield, one refused row per turn](2026-09-26-BH-2603-claude-cost-k3-lanes.md)
- 2026-09-26 — [trap-eval and feature-map-draft name their lanes](2026-09-26-BH-2580-trap-eval-feature-map-lanes.md)
- 2026-09-26 — [The bootstrap smoke writes a cost row; the model lint catches bare aliases](2026-09-26-BH-2535-probe-calls-priced.md)
- 2026-09-25 — [LLM sites screen: the contract slice (BH-2540 part 1, BH-2553)](2026-09-25-BH-2540-llm-sites-screen.md)
- 2026-09-25 — [claude-cost.sh calls go through the lane gate and K3](2026-09-25-BH-2534-claude-cost-gate.md)
- 2026-09-25 — [Build calls bind the fly-pool lane (BH-2533 part 1, BH-2578)](2026-09-25-BH-2533-llm-knobs-every-lane.md)
- 2026-09-25 — [LLM gate: a lane's registered stages are the stages its script calls with](2026-09-25-BH-2304-lane-stage-alignment.md)

## MCP

- 2026-10-14 — [Console command kinds for fleet control (BH-6737)](2026-10-14-BH-6737-fleet-control-commands.md)
- 2026-10-09 — [Console and MCP comment_issue / hold_ticket reach the hub (BH-5820)](2026-10-09-BH-5820-board-commands.md)
- 2026-10-09 — [The MCP server reads the merge queue: merge_queue, pr_stage, backlog (BH-5671)](2026-10-09-BH-5671-mcp-merge-queue-tools.md)
- 2026-10-08 — [The local MCP server logs in with the console secret (BH-5226)](2026-10-08-BH-5226-mcp-cookie-login.md)
- 2026-10-07 — [The MCP server gets its read and action tools (BH-5224, part of BH-5218)](2026-10-07-BH-5218-mcp-server.md)

## MERGE-TRAINS

- 2026-09-28 — [A HOLD that lands after a train opened ejects that member (BH-1934)](2026-09-28-BH-1934-train-hold-eject.md)
- 2026-09-22 — [BH-1287: the fix shipped in #1297; this note is about the two knobs it left unpinned](2026-09-22-BH-1287-train-knob-rows.md)

## MERGIFY

- 2026-10-17 — [A test-infra path in a merge-queue batch runs its own suites and 40 canaries, not the corpus (BH-7287, wave 1 of BH-7033)](2026-10-17-BH-7287-infra-batch-select.md)
- 2026-10-17 — [A batch-fail suite fix goes first in the merge queue (BH-7279)](2026-10-17-BH-7279-flake-fix-queue.md)
- 2026-10-17 — [Merge origin/main into a PR branch only on a real conflict (BH-7042)](2026-10-17-BH-7042-main-merge-only-on-conflict.md)
- 2026-10-17 — [BH-5373 r2: culprit ejection on, bisect off (2026-10-17)](2026-10-17-BH-5373-culprit-flip-on.md)
- 2026-10-16 — [Direct merge in optimistic landing mode (BH-6745, wave 2 of #6541)](2026-10-16-BH-6745-optimistic-landing.md)
- 2026-10-15 — [Suite ledger across gates: prequeue reads and writes it, and the runner image is in the key (BH-6925)](2026-10-15-BH-6925-suite-ledger-cross-gate.md)
- 2026-10-15 — [2026-10-15 — BH-6801: a stacked PR's shards take the plan job's main merge-base](2026-10-15-BH-6801-shard-pinned-main-base.md)
- 2026-10-14 — [Culprit reach uses the batch select; a non-test workflow edit selects (BH-6688)](2026-10-14-BH-6688-infra-path-reach.md)
- 2026-10-14 — [A lead|human post sends client level 4, and an old lib is named (BH-6617)](2026-10-14-BH-6617-client-level-4.md)
- 2026-10-13 — [A stacked merge-queue batch escalates only on its own diff (BH-6490)](2026-10-13-BH-6490-own-diff-escalation.md)
- 2026-10-13 — [Suite fingerprint v2: a helper is an input of its consumers, and the nightly run never reuses (BH-6406, slice C1 of BH-6371)](2026-10-13-BH-6406-fingerprint-v2.md)
- 2026-10-13 — [A tests/lib helper or an add-only rules diff selects in a merge-queue batch (BH-6371, slice C0)](2026-10-13-BH-6371-testlib-batch-select.md)
- 2026-10-13 — [A batch that failed only on a no-verdict shard re-queues its PR once (BH-6336)](2026-10-13-BH-6336-no-verdict-retry.md)
- 2026-10-13 — [2026-10-13 — BH-5373: the impact map's two fixes (the culprit flip waits)](2026-10-13-BH-5373-culprit-flip.md)
- 2026-10-12 — [Mergify builds 3 speculative batches at once, not 8 (BH-6337)](2026-10-12-BH-6337-mergify-parallel-checks-three.md)
- 2026-10-12 — [Every queue ejection records its cause, and a requeue waits for a pre-queue run (BH-6161)](2026-10-12-BH-6161-eject-cause-requeue-gate.md)
- 2026-10-10 — [Merge-queue reconciler lane (BH-5670)](2026-10-10-BH-5670-merge-queue-reconcile.md)
- 2026-10-09 — [Merge-queue stage rows, bisect, the waiting line and the per-PR track (BH-5669)](2026-10-09-BH-5669-queue-stages.md)
- 2026-10-08 — [Break-risk score routes risky PRs to a size-1 solo queue (BH-5430)](2026-10-08-BH-5430-queue-solo-lane.md)
- 2026-10-07 — [A red daily full run reverts its culprit through the hotfix lane and files the map gap (BH-4981)](2026-10-07-BH-4981-main-red-autorevert.md)
- 2026-10-07 — [2026-10-07 — BH-4980: eject the culprit, don't bisect (shipped in shadow)](2026-10-07-BH-4980-eject-culprit.md)
- 2026-10-07 — [The merge conductor works out each PR's impact lane, and Mergify parallel lanes ship dark (BH-4979)](2026-10-07-BH-4979-queue-impact-lanes.md)
- 2026-10-06 — [A daily full CI run on main, and its red filed as a map gap (BH-4970, slice 3 of BH-4964)](2026-10-06-BH-4964-nightly-full.md)
- 2026-10-06 — [Merge-queue batches on /ci (BH-4972, C4 of BH-4964)](2026-10-06-BH-4964-c4-ci-screen.md)
- 2026-10-06 — [A per-batch CI cost ledger: one row per merge-queue batch run (BH-4971, C3 of BH-4964)](2026-10-06-BH-4964-c3-ledger.md)
- 2026-10-06 — [A member's `full` label escalates a batch, and the SPA and worker jobs skip batches that cannot touch them (BH-4969, C1 of BH-4964)](2026-10-06-BH-4964-c1-member-label-spa-worker.md)
- 2026-10-06 — [A merge-queue batch runs its impact set, not the whole corpus (BH-4968, C0 of BH-4964)](2026-10-06-BH-4964-c0-batch-impact.md)
- 2026-10-06 — [A merge-queue batch red on a suite main does not have is dropped, not filed as a main red (BH-4875)](2026-10-06-BH-4875-batch-suite-absent-at-main.md)
- 2026-10-05 — [Archie, queue doctor: batch culprits, unqueued approvals, stale conductor rows (BH-4584, wave 2 of #4574)](2026-10-05-BH-4584-archie-fm-queue.md)
- 2026-10-05 — [Approved external PRs reach the merge queue (BH-4580, BH-4572.1)](2026-10-05-BH-4580-external-enqueue.md)
- 2026-10-04 — [A PR Mergify did not name goes back in after a batch ejection (BH-4428)](2026-10-04-BH-4428-batch-eject-bystander.md)
- 2026-10-04 — [A merge-queue batch red stops being filed as a main red when main already passed those suites (BH-4329)](2026-10-04-BH-4329-batch-red-main-cleared.md)
- 2026-10-03 — [dequeue-watch ships dark and reports once (BH-3859)](2026-10-03-BH-3859-dequeue-watch-ship-dark.md)
- 2026-10-01 — [A withheld lead-verdict stops every enqueue caller, and unqueues rows labelled before the gate (BH-3806)](2026-10-01-BH-3806-nhv-other-callers.md)
- 2026-10-01 — [A lead-cleared head reaches the merge queue, and one that does not pages (BH-3778)](2026-10-01-BH-3778-lead-merge-enqueue.md)
- 2026-10-01 — [A withheld lead-verdict is NEEDS_HUMAN_VERDICT, not QUEUED (BH-3777)](2026-10-01-BH-3777-needs-human-verdict.md)
- 2026-10-01 — [A PR ejected from a red Mergify batch it did not break is re-queued once (BH-3776)](2026-10-01-BH-3776-foreign-red-requeue.md)
- 2026-09-30 — [The dequeue-watch lane is on (BH-3719, built in BH-3730)](2026-09-30-BH-3719-dequeue-watch.md)
- 2026-09-30 — [The hub lead-review lane is the verdict authority; protected paths need a human (BH-3683)](2026-09-30-BH-3683-lead-authority.md)
- 2026-09-29 — [A stale Mergify dequeue is requeued once a fresh verdict binds the new head (BH-3480)](2026-09-29-BH-3480-stale-dequeue-requeue.md)
- 2026-09-29 — [project-5's Mergify queue: 6 in flight, batches of 4, one retry (BH-3439)](2026-09-29-BH-3439-project-5-mergify-tuning.md)
- 2026-09-29 — [Mergify requires a head-bound `lead-verdict` status (BH-3348)](2026-09-29-BH-3348-lead-verdict-status.md)
- 2026-09-25 — [Mergify refuses a PR with a standing change request, and an unreadable probe holds](2026-09-25-BH-2275-mergify-followups.md)
- 2026-09-24 — [A lead CHANGES_REQUESTED survives main merges, and a silent Mergify queue holds](2026-09-24-BH-2199-conductor-gates.md)
- 2026-09-24 — [Mergify's hotfix queue keys on `fix-main-red`, not `hotfix`](2026-09-24-BH-2121-mergify-hotfix-key.md)
- 2026-09-24 — [The Mergify stuck-batch refresh waits on the required set, alerts only on the oldest draft, and retries a failed POST](2026-09-24-BH-1887-mergify-stuck-batch-followups.md)
- 2026-09-23 — [BH-1673 (BH-1698) — one Mergify template, rendered per repo](2026-09-23-BH-1673-mergify-template.md)

## MIGRATION_ENDPOINT_SPEC

- 2026-10-06 — [The data lane proves its apply: probe, evidence file, evidence comment (BH-4925)](2026-10-06-BH-4920-data-lane.md)

## MIRROR-NOTES

- 2026-10-15 — [The registry guard maps repo slugs by exact rows (BH-6797)](2026-10-15-BH-6797-registry-repo-rows.md)
- 2026-10-13 — [The Cromford seed filters move into the publisher, and a registry guard (BH-6494)](2026-10-13-BH-6494-cromford-filters.md)
- 2026-10-13 — [The publisher maps project-6's box short-name (BH-6469)](2026-10-13-BH-6469-box6-mirror-name.md)
- 2026-10-07 — [The share publisher drops `.harness/`, the build records (BH-5055)](2026-10-07-BH-5055-share-drops-harness-dir.md)
- 2026-10-05 — [The public copy, cromford-ai/cromford, is built and armed by a secret (BH-4083)](2026-10-05-BH-4083-public-release.md)

## MISSION-CONTROL

- 2026-09-27 — [Settings writes land in config_changes (BH-2376)](2026-09-27-BH-2376-settings-change-audit.md)

## MODEL-ROUTES

- 2026-10-05 — [Archie checks: a usable dollar cap, budget stops retry within the hour, unreadable metrics re-check daily (BH-4609)](2026-10-05-BH-4609-archie-retry.md)
- 2026-10-04 — [Archie's learning loop (BH-4066, wave 5 of #3966)](2026-10-04-BH-4066-archie-learning.md)
- 2026-10-04 — [Archie's research scout: X and web into the Ideas ledger (BH-4065, wave 4 of #3966)](2026-10-04-BH-4065-archie-research-scout.md)
- 2026-10-03 — [Archie's tracer: initiative, check, message (BH-4062, wave 1 of #3966)](2026-10-03-BH-4062-archie-tracer.md)
- 2026-10-03 — [A split child gets a replan check once its blockers merge (BH-3955)](2026-10-03-BH-3955-replan-check.md)
- 2026-09-30 — [The daily digest renders now, and can carry one LLM paragraph (BH-3707)](2026-09-30-BH-3707-daily-digest-render.md)
- 2026-09-30 — [The daily-digest contract: signatures, stubs, seeds and fixtures (BH-3703)](2026-09-30-BH-3703-daily-digest-contract.md)
- 2026-09-29 — [A split child plans warm: delta pre-plan, child model route, `delta` cost tag (BH-3495)](2026-09-29-BH-3478-child-context-pack.md)
- 2026-09-26 — [The cost read-out is a rendered table, not a model turn](2026-09-26-BH-2550-cost-readout-deterministic.md)
- 2026-09-26 — [Review savings: a cheap route for trivial diffs, and every skipped review is counted](2026-09-26-BH-2545-review-savings.md)
- 2026-09-26 — [cost-readout and runner-bench bill to their own stage and project](2026-09-26-BH-2539-cost-readout-runner-bench-attribution.md)
- 2026-09-26 — [A stage.* route for every catalogued stage](2026-09-26-BH-2536-stage-route-seed.md)
- 2026-09-26 — [The bootstrap smoke writes a cost row; the model lint catches bare aliases](2026-09-26-BH-2535-probe-calls-priced.md)
- 2026-09-26 — [The Models page removes routes, flips price sources, and lists unrouted stages](2026-09-26-BH-2512-models-ui-control.md)
- 2026-09-25 — [P4: plan-driven model routing, recorded in shadow](2026-09-25-P4-route-rules-shadow.md)
- 2026-09-25 — [agent-call and orchestrate read and write fleet cooldown rows](2026-09-25-BH-2356-fleet-cooldown-readers.md)
- 2026-09-24 — [env-diff masks a credential inside a value, and the bootstrap smoke model comes from model_routes](2026-09-24-BH-1993-env-diff-value-masking.md)
- 2026-09-24 — [Model routes: seed lint, empty-remove tombstone, in-batch audit, bundle deadline](2026-09-24-BH-1928-model-routes-follow-ups.md)
- 2026-09-24 — [agent-call caches the stage route read, bounds its wait, and stops repeating the mismatch line](2026-09-24-BH-1837-stage-route-cache.md)
- 2026-09-24 — [The runner per build stage is a model_routes row: `stage.<stage>`](2026-09-24-BH-1766-stage-runner-routes.md)
- 2026-09-24 — [agent-call reads the stage runner from the stage.* route and checks the model against it](2026-09-24-BH-1765-stage-runner-routes.md)
- 2026-09-24 — [The model-id literal lint is an error, pinned at 0, and CI runs it on every PR](2026-09-24-BH-1510-model-literal-lint-strict.md)
- 2026-09-23 — [A hub "no route" answer now drops the hub cache too](2026-09-23-BH-1588-hub-noroute-drops-cache.md)
- 2026-09-23 — [A project save now guards against the hub moving, and the ladders nobody could see are on screen](2026-09-23-BH-1563-model-route-follow-ups.md)

## MODULE-MAP

- 2026-10-16 — [bin/lead-review.sh split into bin/lib/lead-review/ modules, with a growth lint (BH-6293)](2026-10-16-BH-6293-lead-review-split.md)
- 2026-10-13 — [The resolver's build-record discovery sources live only in bin/lib/br/discovery.sh (BH-6517)](2026-10-13-BH-6517-br-discovery-cut.md)
- 2026-10-13 — [The resolver's ticket-key family lives only in bin/lib/br/keys.sh (BH-6461)](2026-10-13-BH-6461-br-keys-cut.md)
- 2026-10-13 — [The sweep's terminal-cache helpers live only in bin/lib/ms/terminal.sh (BH-5242)](2026-10-13-BH-5242-ms-terminal-cut.md)
- 2026-10-13 — [The resolver's record layer lives only in bin/lib/br/record.sh (BH-5241)](2026-10-13-BH-5241-br-record-cut.md)
- 2026-10-12 — [The resolver's ladder lives only in bin/lib/br/ladder.sh (BH-5241)](2026-10-12-BH-5241-br-ladder-cut.md)

## OPERATING

- 2026-10-18 — [BH-7304 (BH-7191.2): sha on change, sync facts, beat and nosync rules](2026-10-18-BH-7304-sha-on-change-beat-nosync.md)
- 2026-10-18 — [Box roles in the registry, a sync timer on every box, the watchdog list from the registry (BH-7303)](2026-10-18-BH-7303-registry-roles-sync-timer.md)
- 2026-10-18 — [BH-7252 C2: lane-move judges a late-found flip on a window it can see](2026-10-18-BH-7252-lane-move-late-flip.md)
- 2026-10-17 — [BH-7252 C1: move the pipeline-health project runs to lane-run](2026-10-17-BH-7252-pipeline-health-move.md)
- 2026-10-17 — [BH-7191 (BH-7302): fleet version check, the tracer](2026-10-17-BH-7191-fleet-version-check.md)
- 2026-10-16 — [A PLAN_BLOCKED build says why, and the stranded watch waits for an answer (BH-7116)](2026-10-16-BH-7116-plan-blocked-notice.md)
- 2026-10-16 — [stage_events_daily archive rule (BH-7109, Scope 4 + R5 of BH-6779)](2026-10-16-BH-7109-stage-events-daily-archive.md)
- 2026-10-16 — [D1 overload retry waits longer and names the query (BH-6813)](2026-10-16-BH-6813-d1-overload-retry-longer.md)
- 2026-10-15 — [An intent review for a medium-risk head (BH-6967)](2026-10-15-BH-6967-intent-review.md)
- 2026-10-15 — [Repair on push: a push to main wakes repair on the PRs it touches (BH-6963, wave 1 of #6542)](2026-10-15-BH-6963-repair-on-push.md)
- 2026-10-15 — [Nightly filer labels as the App; the pool checks the label actor before a spawn (BH-6957)](2026-10-15-BH-6957-nightly-filer-actor.md)
- 2026-10-15 — [Hub load baseline, posted once after 24 h (BH-6939, rest of #6882)](2026-10-15-BH-6939-hub-load-baseline.md)
- 2026-10-15 — [QA findings: collect first, one issue per screen or flow (BH-6902, slice C0)](2026-10-15-BH-6902-group-findings.md)
- 2026-10-15 — [Builds, fix rounds and the lead review run CI's lint job locally (BH-6897)](2026-10-15-BH-6897-ci-local.md)
- 2026-10-15 — [Hub load sampler lane (BH-6882, part of #6881)](2026-10-15-BH-6882-hub-load-sample.md)
- 2026-10-15 — [Ledger archive read fallback (BH-6863, slice C0 of BH-6780)](2026-10-15-BH-6863-ledger-archive-read.md)
- 2026-10-15 — [Ported-flag routes answer a D1 overload with a 503 (BH-6805)](2026-10-15-BH-6805-flags-overload-503.md)
- 2026-10-15 — [Hotspot split tickets (BH-6739, BH-6543.2)](2026-10-15-BH-6739-hotspot-split-ticket.md)
- 2026-10-15 — [A data-lane-only review BLOCK keeps its branch as a draft PR (BH-6467)](2026-10-15-BH-6467-data-lane-draft-rereview.md)
- 2026-10-14 — [Scheduled D1 retention (BH-6750, slice 2 of BH-6727)](2026-10-14-BH-6750-d1-retention.md)
- 2026-10-14 — [Sibling parts get a file list: project roots, list source, cause per wait (BH-6715)](2026-10-14-BH-6715-planned-file-roots.md)
- 2026-10-14 — [A HUMAN-STEP-DONE answer to the builder's REQUEST_CHANGES requests the lead review (BH-6696)](2026-10-14-BH-6696-human-step-done-lead-review.md)
- 2026-10-13 — [A human step done on a REVIEW_BLOCKED ticket re-reviews the built branch (BH-6536)](2026-10-13-BH-6536-human-step-rereview.md)
- 2026-10-13 — [The SQL identifier ratchet and `sqlIdent` (BH-6514, slice BH-6521)](2026-10-13-BH-6514-sql-ident-lint.md)
- 2026-10-13 — [Main-red: re-check flagged repos every 5 minutes (BH-6502)](2026-10-13-BH-6502-main-red-recheck.md)
- 2026-10-13 — [Main-red pass: flagged repos first, and no silent skip (BH-6352)](2026-10-13-BH-6352-main-red-pass-order.md)
- 2026-10-13 — [Dispatch mode per project: normal, hotfix-only with an allow-list, paused (BH-6350)](2026-10-13-BH-6350-dispatch-mode.md)
- 2026-10-13 — [Classify a cut lead report from its hub copy, and re-open the parked ones (BH-5915)](2026-10-13-BH-5915-reclassify-truncated.md)
- 2026-10-12 — [Silent stalls alert or self-clear: dead HOLDs, finished tickets kept open, hard Blocked-by on a stale parent (BH-6308)](2026-10-12-BH-6308-silent-stalls.md)
- 2026-10-12 — [A comment holds only on its first line, and every lane reads it one way (BH-6297)](2026-10-12-BH-6297-hold-first-line.md)
- 2026-10-12 — [Pool bake evidence reaches a cromford pool build (BH-6259, slice C0)](2026-10-12-BH-6259-bake-evidence-relay.md)
- 2026-10-12 — [fleet-propagate: box sync never waits on a pool bake (BH-6201)](2026-10-12-BH-6201-propagate-sync-before-bake.md)
- 2026-10-12 — [review-prs reports a /tmp cap once per cap episode, with the review-prs dir count (BH-6133)](2026-10-12-BH-6133-review-prs-tmp-cap-episode.md)
- 2026-10-12 — [review-prs owns its /tmp scratch and reports a /tmp cap once a day (BH-6130)](2026-10-12-BH-6130-review-prs-tmp-scratch.md)
- 2026-10-12 — [review-prs tick-start cleanup logs the bytes it freed (BH-6129)](2026-10-12-BH-6129-review-prs-reap-freed-bytes.md)
- 2026-10-12 — [The lead call's guard key names a changed PR body (BH-5888, re-plan 2)](2026-10-12-BH-5888-lead-guard-body-key.md)
- 2026-10-11 — [Lead reviews ran 1 at a time: /tmp leftovers and a 4 GB tmpfs (BH-6041)](2026-10-11-BH-6041-review-tmp-capacity.md)
- 2026-10-11 — [stuck-work on the per-project runner, its repeated reads cut; archie-fm-queue's settings fallback (BH-5943)](2026-10-11-BH-5943-stuck-work-runner.md)
- 2026-10-11 — [pipeline-health runs one process per project (BH-5941)](2026-10-11-BH-5941-pipeline-health-per-project.md)
- 2026-10-11 — [Lead re-review asked at once on a head push (BH-5581)](2026-10-11-BH-5581-lead-reenqueue-on-push.md)
- 2026-10-11 — [Review pool cap counts vCPU and tmpfs; static resolv.conf after a reboot (BH-5337)](2026-10-11-BH-5337-review-pool-cpu-tmpfs-dns.md)
- 2026-10-11 — [Archie, self-improvement loop: one ai-build issue per recurring cause (BH-4587, wave 5 of #4574)](2026-10-11-BH-4587-archie-fm-improve.md)
- 2026-10-10 — [A cut lead review report is stored whole on the hub (BH-5915)](2026-10-10-BH-5915-lead-report-transcript.md)
- 2026-10-10 — [The conductor's refusal holds on every box; a 406 diff is scanned from git (BH-5914)](2026-10-10-BH-5914-conductor-verdict-every-lane.md)
- 2026-10-10 — [A lead review report is bound to the PR body it read (BH-5888)](2026-10-10-BH-5888-lead-report-body.md)
- 2026-10-10 — [Fixtures look fake on purpose; the builder runs the leak gate (BH-5789)](2026-10-10-BH-5789-fixture-hygiene.md)
- 2026-10-10 — [Orchestrator turns run in parallel (BH-5336)](2026-10-10-BH-5336-parallel-orchestrator-turns.md)
- 2026-10-10 — [BH-5006: close-out of scopes 1, 2 and 4, and the Acceptance 1 probe](2026-10-10-BH-5006-remaining-scopes.md)
- 2026-10-09 — [The lead review reads an oversize diff in parts; split required replaces the blind BLOCK (BH-5803)](2026-10-09-BH-5803-lead-review-diff-parts.md)
- 2026-10-09 — [Lead reviews no longer get stuck on a failed request, a silent skip or a stale running row (BH-5779)](2026-10-09-BH-5779-lead-review-stuck.md)
- 2026-10-09 — [Flag CLI and the one-time hub seed (BH-5635.1)](2026-10-09-BH-5635.1-flag-cli.md)
- 2026-10-08 — [Conflict discipline in the builder prompts, the hotspot list in the primer, and the Shared-files report (BH-5269)](2026-10-08-BH-5269-conflict-discipline-prompts.md)
- 2026-10-07 — [Operating lessons, defaults and builder rules written down (BH-5289)](2026-10-07-BH-5289-operating-lessons.md)

## OUTSIDE-DEADMAN

- 2026-09-28 — [BH-3323: the off-box WATCHDOG_URL callers read the catalog](2026-09-28-BH-3323-watchdog-url-offbox.md)

## PLAN-CONTRACT

- 2026-10-15 — [Spec trace: plans and reviews check a slice against the spec it came from (BH-6485)](2026-10-15-BH-6485-spec-trace.md)
- 2026-10-13 — [Seam file per sibling, `Owns:` lines, owns-overlap lint, HUB_MODULE (BH-6384)](2026-10-13-BH-6384-seam-files.md)
- 2026-10-10 — [Design collisions at PLAN, and the caller list after the main merge (BH-5791)](2026-10-10-BH-5791-design-collisions.md)
- 2026-10-08 — [Conflict discipline in the builder prompts, the hotspot list in the primer, and the Shared-files report (BH-5269)](2026-10-08-BH-5269-conflict-discipline-prompts.md)

## PR-OWNERSHIP

- 2026-10-16 — [BH-6717: close-duplicate counts only a merge after the PR was opened](2026-10-16-BH-6717-close-duplicate-later-part.md)
- 2026-10-15 — [The duplicate-close guard (BH-6929)](2026-10-15-BH-6929-dup-guard.md)
- 2026-10-07 — [pr-owner-sweep stops trusting a stale local conductor file (BH-5124)](2026-10-07-BH-5124-pr-owner-conductor-read.md)
- 2026-10-05 — [BH-4668: the fix round on an external PR (BH-4664.1)](2026-10-05-BH-4668-external-pr-fix-round.md)
- 2026-10-05 — [BH-4664: external PRs in the blocked-resolver (BH-4667 is the tracer)](2026-10-05-BH-4664-external-pr-fix-rounds.md)
- 2026-10-05 — [BH-3933: every open PR gets an owner (BH-3929.1)](2026-10-05-BH-3933-pr-owner-enroll.md)
- 2026-10-03 — [BH-3936: superseded close for every class, and the PR-health digest line (BH-3929 asks 4 and 6)](2026-10-03-BH-3936-superseded-health.md)
- 2026-10-03 — [BH-3935: the PR-owner age ladder (BH-3929.3)](2026-10-03-BH-3935-pr-stale-ladder.md)
- 2026-10-03 — [BH-3932: the PR-owner sweep's hook seams (BH-3929.0)](2026-10-03-BH-3932-pr-owner-seams.md)
- 2026-09-26 — [pr-owner-sweep's hand-back is the row, and only the row (BH-2530.3, BH-2673)](2026-09-26-BH-2673-pr-owner-handback-no-ssh.md)
- 2026-09-25 — [The once-only comment markers and the resolver's counters are D1 rows](2026-09-25-BH-2317-comment-marks-db.md)
- 2026-09-19 — [Four small ledger bugs: a stamp, a cursor, a stamp that outlived its rows, and a stale map](2026-09-19-BH-1042-small-ledger-bugs.md)

## PROJECT-LANES

- 2026-10-15 — [Lane-run machines: name the head-read error, check fleet repos at start, refuse unreadable repos at claim (BH-6942)](2026-10-15-BH-6942-lane-run-repo-check.md)
- 2026-10-15 — [pr-url-reconcile runs per project, with a manifest pair (BH-6894)](2026-10-15-BH-6894-pr-url-reconcile-per-project.md)
- 2026-10-15 — [review-rescue runs per project (BH-6893, BH-6881.11)](2026-10-15-BH-6893-review-rescue-per-project.md)
- 2026-10-15 — [Lane runs: one batch enqueue per tick (BH-6886, BH-6881.8)](2026-10-15-BH-6886-lane-runs-batch.md)
- 2026-10-15 — [Lane-run fleet: several starts per tick, and claims that prefer warm clones (BH-6885)](2026-10-15-BH-6885-lane-fleet-multistart.md)
- 2026-10-15 — [Lane-run machines run current code; a non-zero run is `failed` (BH-6817)](2026-10-15-BH-6817-lane-run-fresh-code.md)
- 2026-10-14 — [The rest of #5938's lanes stay on the hub for now (BH-6721, BH-6047.8, C8)](2026-10-14-BH-6721-lanes-offhub.md)
- 2026-10-14 — [The LLM alert lanes have input manifests (BH-6720, BH-6047.7)](2026-10-14-BH-6720-llm-alert-lanes-offhub.md)
- 2026-10-14 — [Lane-run inputs are per-lane manifests (BH-6719, BH-6047.6)](2026-10-14-BH-6719-lane-run-inputs-manifests.md)
- 2026-10-14 — [Merge-conductor per-PR workers on lane-run machines (BH-6495, BH-6047.5)](2026-10-14-BH-6495-conductor-fly.md)
- 2026-10-14 — [blocked-resolver is placed on Fly (BH-6260)](2026-10-14-BH-6260-blocked-resolver-flip.md)
- 2026-10-12 — [blocked-resolver runs on Fly lane machines (BH-6128, BH-6047 part 5 of 5)](2026-10-12-BH-6128-blocked-resolver-offhub.md)
- 2026-10-12 — [Lane-run metrics on Mission Control and the queue-wait alert (BH-6127, BH-6047 part 4 of 5)](2026-10-12-BH-6127-lane-run-metrics.md)
- 2026-10-12 — [Lane-run Fly fleet: the autoscaler (BH-6126, BH-6047 part 3 of 5)](2026-10-12-BH-6126-lane-fleet.md)
- 2026-10-12 — [Lane runs: the lease heartbeat and the death count (BH-6125, BH-6047 part 2 of 5)](2026-10-12-BH-6125-lane-run-lease.md)
- 2026-10-12 — [Lane runs on Fly: the queue contract (BH-6124, BH-6047 part 1 of 5)](2026-10-12-BH-6124-lane-runs.md)

## PROMPT-EVALS

- 2026-09-24 — [BH-128 trap evals](2026-09-24-BH-128-trap-evals.md)
- 2026-09-23 — [Prompt evals cover five more projects, and the env scrub covers database keys](2026-09-23-BH-122-prompt-eval-fleet-fixtures.md)

## PUBLISH-CROMFORD

- 2026-10-07 — [Port merged changes to cromford-ai/cromford as a PR (BH-5227, part of BH-5218)](2026-10-07-BH-5218-port-tool.md)

## READINESS

- 2026-10-15 — [Spec trace: plans and reviews check a slice against the spec it came from (BH-6485)](2026-10-15-BH-6485-spec-trace.md)
- 2026-10-13 — [Box merge queue re-checks CI, reviewed sha and park state before every merge (BH-6428)](2026-10-13-BH-6428-merge-queue-red-guard.md)
- 2026-10-03 — [Onboarding study pass: `bin/onboard-study.sh` (BH-4074, slice C0)](2026-10-03-BH-4074-onboard-study-pass.md)

## README

- 2026-10-07 — [Operating lessons, defaults and builder rules written down (BH-5289)](2026-10-07-BH-5289-operating-lessons.md)

## REMOTE-GATE

- 2026-10-11 — [testhost-tick finds flyctl under cron, and alerts on an unknown streak (BH-6061)](2026-10-11-BH-6061-testhost-flyctl-path.md)
- 2026-10-07 — [One bounded entry point for a test-host cert by hand](2026-10-07-BH-5210-testhost-cert-wrapper.md)
- 2026-09-24 — [The flaky F1d was a real lock leak in remote-gate's mkdir lock, not a test race](2026-09-24-BH-2049-remote-gate-lock-leak.md)
- 2026-09-24 — [The remote-gate mkdir lock exits on a signal, keeps a torn owner, and reclaims one at a time](2026-09-24-BH-1918-remote-gate-lock-signals.md)
- 2026-09-24 — [The remote-gate cert reissue is locked on a Mac too, and its watchdog kills the group](2026-09-24-BH-1854-remote-gate-cert-lock-mkdir.md)
- 2026-09-24 — [The remote-gate cert reissue is bounded, off the live key, and locked](2026-09-24-BH-1836-remote-gate-cert-reissue.md)
- 2026-09-23 — [PyYAML is on every machine the corpus runs on, and missing it is red in CI](2026-09-23-BH-1741-pyyaml-ci.md)
- 2026-09-23 — [Test hosts run node 22 from the bake.node.version row](2026-09-23-BH-1617-testhost-node.md)
- 2026-09-22 — [2026-09-22 — BH-1539: the remote gate's nested excludes, its HEAD line, and its stderr](2026-09-22-BH-1539-remote-gate-followups.md)
- 2026-09-22 — [BH-1250 — the test host's red suites were a PATH order and a SIGPIPE race, not a /root/harness leak](2026-09-22-BH-1250-testhost-path-order-and-cred-helper-sigpipe.md)
- 2026-09-22 — [The busy probe stops counting the run roots, and the six-hour sweep spares live work](2026-09-22-BH-1221-testhost-followups.md)
- 2026-09-22 — [BH-1193: bin/run-tests-in-docker.sh can run against a remote docker host](2026-09-22-BH-1193-remote-docker-host.md)

## RESOLVER-MODULES

- 2026-09-22 — [One suite per module: `tests/blocked-resolver-test.sh` split seven ways, one shared fixture lib](2026-09-22-BH-1196-one-suite-per-module.md)

## RESTORE

- 2026-10-12 — [State backup runs at idle priority, compresses at zstd -1 and skips unchanged inputs (BH-6173)](2026-10-12-BH-6173-state-backup-idle-priority.md)
- 2026-10-11 — [The fleet reads the D1 registry; fleet.conf is an export (BH-5651, wave 3 of BH-5633)](2026-10-11-BH-5651-registry-switch.md)
- 2026-09-27 — [Standby box side: heartbeat POST and verify lane (BH-2640, part of #2519)](2026-09-27-BH-2640-standby-box-side.md)

## REVIEW-PRS

- 2026-09-28 — [review-prs: REVIEW_D1_HOLD_MAX_H is 0-168, and two D1-hold nits](2026-09-28-BH-2492-review-prs-d1-nits.md)
- 2026-09-25 — [review-prs: the D1 hold has a time limit, then subscription runners only](2026-09-25-BH-2457-review-prs-d1-hold-fallback.md)
- 2026-09-25 — [review-prs holds a paid review when the D1 verdict ledger cannot be read](2026-09-25-BH-2315-review-prs-d1-first.md)

## ROUTE-RULES

- 2026-09-25 — [P4: plan-driven model routing, recorded in shadow](2026-09-25-P4-route-rules-shadow.md)

## RUNNER-CLIS

- 2026-10-14 — [2026-10-14 — BH-6742: flyctl and gh stay current; security updates are provisioned](2026-10-14-BH-6742-runner-tools-current.md)

## SCALE-PLAN-2

- 2026-10-09 — [One command launches an Orgo box (BH-5748)](2026-10-09-BH-5748-box-launch.md)

## SCHEDULER

- 2026-10-13 — [BH-6374: sibling parts of one split ticket run one at a time when they share a file](2026-10-13-BH-6374-sibling-serial.md)
- 2026-10-13 — [BH-6374 C1: sibling parts by board key, pool stacking, squash-base merge, replay](2026-10-13-BH-6374-sibling-parts-c1.md)
- 2026-10-12 — [Overlap schedule: read-mostly paths are not collisions (BH-6299)](2026-10-12-BH-6299-read-mostly-paths.md)
- 2026-10-08 — [BH-4988: sequence rollout siblings on any shared file, seams in the .0 contract](2026-10-08-BH-4988-sibling-sequencing.md)
- 2026-10-07 — [The plan-time overlap gate counts a hotspot a plan names only lightly (BH-5268)](2026-10-07-BH-5268-plan-overlap-hotspots.md)
- 2026-10-07 — [BH-4988: plan-time fragment exemption and the After: hold](2026-10-07-BH-4988-plan-after-hold.md)
- 2026-10-03 — [The overlap schedule releases a dead claim from another harness (BH-3951, slice 4 of BH-3943)](2026-10-03-BH-3951-overlap-claim-ttl.md)
- 2026-09-28 — [The overlap schedule stacks instead of deferring (BH-1174)](2026-09-28-BH-1174-overlap-stack.md)
- 2026-09-25 — [flags/ config files read as settings rows (BH-2411, BH-2320.C5)](2026-09-25-BH-2411-conf-rows.md)
- 2026-09-25 — [BH-2359 (BH-2319.4): lane-down writers stamp fleet rows, reprobe reseeds from them](2026-09-25-BH-2359-lane-down-fleet-rows.md)
- 2026-09-24 — [DEAD column holds back build rows whose GitHub issue is closed](2026-09-24-BH-938-dead-closed-issues.md)
- 2026-09-24 — [Kanban reads the whole issue_state ledger, not just its newest 1000 rows](2026-09-24-BH-2206-closed-issue-paging.md)
- 2026-09-23 — [2026-09-23 — BH-1687 (BH-1674 part 2): a down runner lane is re-probed and clears itself](2026-09-23-BH-1674-lane-reprobe.md)

## SELF-HOST

- 2026-10-17 — [Cromford release commits carry bullet release notes (BH-7185)](2026-10-17-BH-7185-cromford-release-notes.md)
- 2026-10-15 — [The registry guard maps repo slugs by exact rows (BH-6797)](2026-10-15-BH-6797-registry-repo-rows.md)
- 2026-10-13 — [The Cromford seed filters move into the publisher, and a registry guard (BH-6494)](2026-10-13-BH-6494-cromford-filters.md)
- 2026-10-09 — [The self-host installer runs under macOS bash 3.2 (BH-5732)](2026-10-09-BH-5732-selfhost-install-bash32.md)
- 2026-10-07 — [Operating lessons, defaults and builder rules written down (BH-5289)](2026-10-07-BH-5289-operating-lessons.md)
- 2026-10-07 — [The share publisher drops `.harness/`, the build records (BH-5055)](2026-10-07-BH-5055-share-drops-harness-dir.md)
- 2026-10-06 — [The public repo appends releases and reads as Cromford (BH-4901)](2026-10-06-BH-4901-cromford-append-branding.md)
- 2026-10-05 — [The public copy, cromford-ai/cromford, is built and armed by a secret (BH-4083)](2026-10-05-BH-4083-public-release.md)

## SKILL

- 2026-10-03 — [Rollout refusals: the documented heading parses, refusals reach the master, and the pool stops calling them deaths (BH-4061)](2026-10-03-BH-4061-rollout-refusals.md)

## TEST-DETERMINISM

- 2026-10-15 — [CI blocks on factory checks and reached suites; the corpus and hygiene lints run nightly (BH-6838)](2026-10-15-BH-6838-ci-nightly-split.md)
- 2026-10-13 — [race-wall-bound: a test asserts the order of events, not elapsed seconds](2026-10-13-BH-6508-race-wall-bound.md)
- 2026-10-12 — [2026-10-12 — BH-6109: race-sigpipe-echo, a printf/echo pipe into grep -q or head](2026-10-12-BH-6109-sigpipe-echo-rule.md)
- 2026-10-11 — [Suites that read a UTC day stamp wait out 00:00Z (BH-6052)](2026-10-11-BH-6052-day-boundary-guard.md)
- 2026-10-08 — [The share suites read one mirror build per tree (BH-5543)](2026-10-08-BH-5543-share-mirror-cache.md)
- 2026-09-24 — [date-empty-stamp: a null quota poll reads stale, not fresh since midnight](2026-09-24-BH-1898-date-empty-stamp-account-pick.md)
- 2026-09-24 — [date-empty-stamp: an empty `date -d` argument is today's midnight](2026-09-24-BH-1897-date-empty-stamp.md)
- 2026-09-24 — [date-empty-stamp is an error, and only a real test on the variable guards it](2026-09-24-BH-1816-date-empty-stamp.md)
- 2026-09-22 — [The main-red detector can see a red main during a merge burst, and a PR pair can now hold merges](2026-09-22-BH-1451-main-red-burst-backwalk.md)
- 2026-09-22 — [BH-1281: the main-red STREAK arm no longer re-raises a freeze on top of a re-test](2026-09-22-BH-1281-streak-inflight-hold.md)
- 2026-09-22 — [A "this branch must not touch X" arm must gate on its own slice](2026-09-22-BH-1261-branch-arm-gate.md)
- 2026-09-22 — [BH-1250 — the test host's red suites were a PATH order and a SIGPIPE race, not a /root/harness leak](2026-09-22-BH-1250-testhost-path-order-and-cred-helper-sigpipe.md)
- 2026-09-22 — [2026-09-22 — BH-1248: race-sigpipe reaches bin/, and reads a continued pipe](2026-09-22-BH-1248-race-sigpipe-bin-scope.md)
- 2026-09-20 — [Both main-red `--explain` arms are read-only](2026-09-20-BH-997-explain-read-only.md)
- 2026-09-19 — [The main-red test-only exemption no longer depends on the cwd, and a landing pass re-reads the flag](2026-09-19-BH-987-main-red-gate-cwd-and-landing-memo.md)
- 2026-09-19 — [The main-red freeze reaches every merge lane, from the shared flag store](2026-09-19-BH-945-main-red-every-lane.md)

## TESTING

- 2026-10-17 — [A new bin/agent-call.sh call must turn tools off or say why (BH-7276)](2026-10-17-BH-7276-agent-call-no-tools-lint.md)
- 2026-10-17 — [Hub project-loop ratchet, cron staggers, lead-review lock measure (BH-5945)](2026-10-17-BH-5945-ratchet-and-staggers.md)
- 2026-10-16 — [bin/lead-review.sh split into bin/lib/lead-review/ modules, with a growth lint (BH-6293)](2026-10-16-BH-6293-lead-review-split.md)
- 2026-10-14 — [Tests get no GitHub credential, and build files carry no token shape (BH-6672)](2026-10-14-BH-6672-test-credential-isolation.md)
- 2026-10-13 — [The SQL identifier ratchet and `sqlIdent` (BH-6514, slice BH-6521)](2026-10-13-BH-6514-sql-ident-lint.md)
- 2026-10-13 — [Learned impact edges expire after N clean passes (BH-6460, slice C3 of BH-6390)](2026-10-13-BH-6460-impact-edge-expiry.md)
- 2026-10-13 — [The builder gate runs the whole-repo suites on HEAD merged with fresh main, and ranks a learned edge above closure (BH-6459, slice C2 of BH-6390)](2026-10-13-BH-6459-gate-fresh-main.md)
- 2026-10-13 — [A hub lane opens the learned-edge PR (BH-6458, slice C1 of BH-6390)](2026-10-13-BH-6458-impact-learn-lane.md)
- 2026-10-13 — [A merge-queue failure can add the impact-map edge it missed (BH-6390, slice C0)](2026-10-13-BH-6390-impact-learned-edges.md)
- 2026-10-11 — [Three flaky tests made deterministic (BH-5544)](2026-10-11-BH-5544-flaky-tests-deterministic.md)
- 2026-10-11 — [Share-mirror leak check on every PR diff (BH-5542)](2026-10-11-BH-5542-share-diff-leakcheck.md)
- 2026-10-09 — [Tests assert the fields they own: a warn-mode lint and a prompt rule (BH-5792)](2026-10-09-BH-5792-payload-pin-lint.md)

## TRIAGE

- 2026-09-26 — [The daily full triage sweep comes back: only a full tick stamps the clock (BH-2751 part 2, BH-2753)](2026-09-26-BH-2751-full-sweep-clock.md)

## TRIAGE-STATE

- 2026-10-11 — [The three LLM alert lanes run per project (BH-5942)](2026-10-11-BH-5942-llm-lanes-per-project.md)
- 2026-10-07 — [Direction is not a take-over, and a resolver hand-off acts, says why not, or pages (BH-5125)](2026-10-07-BH-5125-direction-handoff.md)
- 2026-10-03 — [In-app text dependencies: the contract slice (BH-3962, part 0 of BH-3946)](2026-10-03-BH-3962-inapp-deps-contract.md)
- 2026-10-03 — [The results sweep reads the newest result first, and a held sweep keeps no stamp (BH-3953)](2026-10-03-BH-3953-results-sweep-unswept-key.md)
- 2026-10-03 — [A ticket the call-guard keeps refusing is parked, and an open PR skips the paid session (BH-3949, part 2 of BH-3943)](2026-10-03-BH-3949-triage-park.md)
- 2026-10-03 — [Every triage tick counts what it paid for unchanged input (BH-3926)](2026-10-03-BH-3926-triage-paid-unchanged.md)
- 2026-10-03 — [The triage-state fetch cap rotates, defers instead of dropping, and a silent session is held (BH-3920)](2026-10-03-BH-3920-triage-fetch-cap.md)
- 2026-10-01 — [Triage state: in-app queue and close-out work is the session's, in enforce and in the scorecard (BH-3774)](2026-10-01-BH-3774-triage-state-inapp-work.md)
- 2026-09-29 — [The waiting-on-human hold: the marker, the lane skip lines, the real placer (BH-3443)](2026-09-29-BH-3443-needs-human-hold.md)
- 2026-09-29 — [TRIAGE-STATE for PRs: a PR shard records its verdict (BH-3417 slice 3)](2026-09-29-BH-3420-pr-shard-record.md)
- 2026-09-29 — [TRIAGE-STATE for PRs: the pre-check body (BH-3417 slice 2)](2026-09-29-BH-3419-pr-precheck-body.md)
- 2026-09-29 — [TRIAGE-STATE for PRs: the contract and the inert seams (BH-3417 slice 1)](2026-09-29-BH-3417-pr-triage-state.md)

## TRUST-PROGRAM

- 2026-09-30 — [Rule adopt: the hub lane that lands lint-backed rules PRs (BH-3715, BH-3692.2)](2026-09-30-BH-3715-rule-adopt.md)
- 2026-09-30 — [Rule-miner auto-adopt: the evidence contract and the rule-recur stub (BH-3713, BH-3692.0)](2026-09-30-BH-3692-rule-miner-auto-adopt.md)
- 2026-09-30 — [The lookback lane can be turned on: a dry week in the digest, then live (BH-3691)](2026-09-30-BH-3691-lookback-live.md)
- 2026-09-28 — [The lookback lane now has a collector: one week of repeat failures in one bundle](2026-09-28-BH-1795-lookback-lane.md)
- 2026-09-24 — [BH-128 trap evals](2026-09-24-BH-128-trap-evals.md)
- 2026-09-23 — [A reviewed, green tier-2 PR on a Mergify repo enqueues itself](2026-09-23-BH-1668-tier2-autoenqueue.md)

## VERIFICATION-MAP

- 2026-10-16 — [BH-7117: the triage pass takes hotfix tickets first](2026-10-16-BH-7117-hotfix-intake-first.md)
- 2026-10-15 — [The verdict routes answer 503 when the D1 retry gives up (BH-6807)](2026-10-15-BH-6807-verdict-overload-503.md)
- 2026-10-14 — [harness-jobs retries a D1 overload (BH-6690)](2026-10-14-BH-6690-d1-overload-retry.md)
- 2026-10-14 — [The worker deploy snapshot carries agent-core/ (BH-6687)](2026-10-14-BH-6687-worker-snapshot-agent-core.md)
- 2026-10-14 — [BH-5788: key-named fragments, and three lints for shared append points](2026-10-14-BH-5788-fragment-append-points.md)
- 2026-10-14 — [The main-red lanes keep their records as rows (BH-4156, child C2)](2026-10-14-BH-4156-main-red-state-tables.md)
- 2026-10-13 — [Main-red: re-check flagged repos every 5 minutes (BH-6502)](2026-10-13-BH-6502-main-red-recheck.md)
- 2026-10-13 — [Main-red pass: flagged repos first, and no silent skip (BH-6352)](2026-10-13-BH-6352-main-red-pass-order.md)
- 2026-10-13 — [Dispatch mode per project: normal, hotfix-only with an allow-list, paused (BH-6350)](2026-10-13-BH-6350-dispatch-mode.md)
- 2026-10-12 — [A comment holds only on its first line, and every lane reads it one way (BH-6297)](2026-10-12-BH-6297-hold-first-line.md)
- 2026-10-12 — [Lane-run metrics on Mission Control and the queue-wait alert (BH-6127, BH-6047 part 4 of 5)](2026-10-12-BH-6127-lane-run-metrics.md)
- 2026-10-09 — [BH-5781: D1 overload relief](2026-10-09-BH-5781-d1-overload.md)
- 2026-10-05 — [BH-4662 (BH-4656 part 5): a sliced plan never closes its parent, and "children own the rest" only when a child exists](2026-10-05-BH-4662-slice-closeout-children.md)
- 2026-10-05 — [BH-4660 (BH-4656 part 3): stuck-work reads CI and comment threads only on change](2026-10-05-BH-4660-stuck-work-reads.md)
- 2026-10-05 — [BH-4659 (BH-4656.1): the conductor and batch-resolve read the PR snapshot; branch tips from one refs read](2026-10-05-BH-4659-pr-snapshot-lanes.md)
- 2026-10-05 — [BH-4658 (BH-4656 part 1): the PR snapshot, and lead-review-enqueue reads heads through it](2026-10-05-BH-4656-pr-snapshot.md)
- 2026-10-03 — [pr-attribution: who built each merged PR (BH-4016, child of BH-3987)](2026-10-03-BH-4016-pr-attribution.md)
- 2026-10-03 — [utilization: the daily went-quiet alert (BH-4012, BH-3988.4)](2026-10-03-BH-3988-went-quiet-alert.md)
- 2026-10-03 — [utilization: the hourly snapshot tracer (BH-4008, slice 1 of BH-3988)](2026-10-03-BH-3988-utilization-tracer.md)
- 2026-10-03 — [utilization: the Mission Control screen (BH-4011, slice 4 of BH-3988)](2026-10-03-BH-3988-utilization-screen.md)
- 2026-10-03 — [utilization: pauses and PR-queue sections (BH-4010, slice 3 of BH-3988)](2026-10-03-BH-3988-utilization-pauses-prs.md)
- 2026-10-03 — [utilization: ticket buckets and the real verdict (BH-4009, slice 2 of BH-3988)](2026-10-03-BH-3988-ticket-buckets.md)
- 2026-09-28 — [The queue-rows merge gate lists live statuses, not the whole table (BH-3221)](2026-09-28-BH-3221-qrf-merge-live-statuses.md)
- 2026-09-28 — [Merge-queue HOLD / RESUME / DROP and held-page RELEASE in the console (BH-3159)](2026-09-28-BH-2325-merge-queue-actions.md)
- 2026-09-27 — [Sweeper and metrics kill switches read through lane_switch (BH-2444)](2026-09-27-BH-2444-sweeper-switches.md)
- 2026-09-27 — [Five sourced-lib kill switches read as settings rows (BH-2429, BH-2409.3)](2026-09-27-BH-2429-switches-libs.md)
- 2026-09-25 — [Kill switches a-f: the contract (BH-2407, built as BH-2431)](2026-09-25-BH-2407-switches-a-f.md)

## WORKER-JOBS

- 2026-09-24 — [The worker route-table fixture is one fragment per route family](2026-09-24-LANE-E-route-table-fragments.md)

## [docs/verification-map/BH-6975.md](../verification-map/BH-6975.md)

- 2026-10-16 — [BH-6975: the merge conductor acts on PR and check wakes within a minute](2026-10-16-BH-6975-mc-wake.md)

## `docs/AUTH.md`

- 2026-09-22 — [BH-1424: route close-out issue reads through the App token over REST](2026-09-22-BH-1424-issue-reads-app-token.md)

## `docs/verification-map/closed-issue-hygiene.md`.

- 2026-09-22 — [BH-1424: route close-out issue reads through the App token over REST](2026-09-22-BH-1424-issue-reads-app-token.md)

## backup-freshness

- 2026-09-22 — [The backup-freshness "flake" was a 35-minute window after midnight UTC](2026-09-22-BH-1308-undatable-row-midnight.md)

## bin/ci-shellcheck.sh

- 2026-09-22 — [BH-1246 — ci-shellcheck follow-ups from the #1240 review](2026-09-22-BH-1246-ci-shellcheck-followups.md)

## bin/console-preview-deploy.sh

- 2026-10-15 — [Console preview: the lane strips preview bindings, and QA reports a binding gap (BH-6923)](2026-10-15-BH-6923-console-preview-bindings.md)
- 2026-10-13 — [Console preview: nothing a build starts outlives it (BH-6073)](2026-10-13-BH-6073-console-preview-build-iso.md)
- 2026-10-12 — [Console preview: the streak head and its retry (BH-6270)](2026-10-12-BH-6270-console-preview-streak-retry.md)

## bin/console-qa-run.mjs

- 2026-10-15 — [Console preview: the lane strips preview bindings, and QA reports a binding gap (BH-6923)](2026-10-15-BH-6923-console-preview-bindings.md)

## bin/lib/br/opt/README.md

- 2026-10-10 — [The blocked resolver profiles its run and cuts repeat reads (BH-5946)](2026-10-10-BH-5946-resolver-repeat-cuts.md)

## bin/lib/console-preview.sh

- 2026-10-13 — [Console preview: nothing a build starts outlives it (BH-6073)](2026-10-13-BH-6073-console-preview-build-iso.md)

## block-gate

- 2026-10-03 — [A BLOCK that only says "CI did not run" clears itself when CI is green (BH-3934)](2026-10-03-BH-3934-block-ci-clear.md)

## board-dependencies

- 2026-09-23 — [BH-1655 — a merged split child wakes the next sibling on a polling board](2026-09-23-BH-1655-split-chain-advance.md)

## box-console-commands

- 2026-09-27 — [Box console commands lane: bin/box-console-commands.sh (BH-2655, BH-2528.2)](2026-09-27-BH-2655-box-console-commands-lane.md)

## checks/README.md

- 2026-10-04 — [sql-command-injection stops parking constant and ?N-placeholder interpolations (BH-4501)](2026-10-04-BH-4501-sql-check-allowlist.md)
- 2026-09-20 — [A GitHub token is a length, not a prefix: `secret-literals` stops parking every gh-shim PR](2026-09-20-BH-1124-secret-literals-token-length.md)

## ci-durations

- 2026-10-15 — [CI shard count by measured time; a workflow edit selects its readers; a 35-minute shard page (BH-6876)](2026-10-15-BH-6876-ci-shard-sizing.md)
- 2026-10-09 — [CI suite durations go to a jobs worker table (BH-5653)](2026-10-09-BH-5653-ci-durations-db.md)

## ci-test-tiers

- 2026-10-15 — [CI shard count by measured time; a workflow edit selects its readers; a 35-minute shard page (BH-6876)](2026-10-15-BH-6876-ci-shard-sizing.md)
- 2026-10-15 — [CI blocks on factory checks and reached suites; the corpus and hygiene lints run nightly (BH-6838)](2026-10-15-BH-6838-ci-nightly-split.md)

## config-inventory

- 2026-10-08 — [The config-inventory renders leave git (BH-5518, slice C0)](2026-10-08-BH-5518-config-inventory-untracked.md)
- 2026-10-04 — [Self-host install: the dry-run planner (BH-4081 slice C0, #3979 wave 7)](2026-10-04-BH-4081-selfhost-install.md)
- 2026-10-04 — [Deployment defaults and the deployment lint (BH-4080, #3979 wave 6)](2026-10-04-BH-4080-deployment-defaults.md)
- 2026-09-22 — [The config inventory answers five questions differently, and its slices no longer share files](2026-09-22-BH-1530-inventory-residuals.md)

## console-ui

- 2026-10-11 — [Mission Control phone floor: 44px tap targets and 11px text (BH-6001)](2026-10-11-BH-6001-phone-tap-floor.md)

## console-ui/README.md

- 2026-10-17 — [Mission Control shows components, their open alerts and the watcher's decisions (BH-6973)](2026-10-17-BH-6973-components-screen.md)
- 2026-10-14 — [A new coord write route is a fragment file, not a row in WRITES (BH-6487)](2026-10-14-BH-6487-coord-write-fragments.md)
- 2026-10-10 — [Mission Control catches a failed screen and reports it to Sentry (BH-5619)](2026-10-10-BH-5619-console-error-boundary.md)

## deploy-queue-rows

- 2026-10-06 — [A deploy-train revert reopens the ticket it rolled back (BH-4915)](2026-10-06-BH-4915-deploy-rollback-reopens-ticket.md)
- 2026-09-28 — [Deploy queue HOLD / UNHOLD (BH-3154, BH-2510.4)](2026-09-28-BH-3154-deploy-hold.md)

## disk-clean-hygiene

- 2026-10-04 — [BH-4440: box housekeeping for session ledgers and /tmp, and a disk alert that says where the space went](2026-10-04-BH-4440-box-housekeeping.md)
- 2026-09-22 — [BH-1363: the fix round's worktree gets an owner on every exit, and disk-clean gets the backstop](2026-09-22-BH-1363-brfix-worktree-cleanup.md)

## disk-guard

- 2026-10-04 — [BH-4440: box housekeeping for session ledgers and /tmp, and a disk alert that says where the space went](2026-10-04-BH-4440-box-housekeeping.md)

## docs/CONTEXT-COMPOSITION.md

- 2026-10-14 — [BH-6487: catalog/context-budgets.json is composed from catalog/context-budgets.d/](2026-10-14-BH-6487-context-budgets-fragments.md)

## docs/OPERATING.md

- 2026-10-13 — [BH-4987: a new lane knob is its own file, catalog/lanes.d/<owner>.knobs.d/<ENV>.json](2026-10-13-BH-4987-lane-knob-fragments.md)

## docs/OUTSIDE-DEADMAN.md

- 2026-10-16 — [BH-7164: three harness-jobs read shapes under 5,000 rows a call](2026-10-16-BH-7164-d1-read-shapes.md)

## docs/REVIEW_SEVERITY_AUDIT_2026-10-16.html

- 2026-10-16 — [BH-7123 wave B: the cowboy dial, no follow-up chains, the ratchet floor](2026-10-16-BH-7123-wave-b-cowboy-dial.md)

## docs/verification-map/entries/BH-5064.md

- 2026-10-07 — [Blocked-resolver fix rounds run the scratch-closure lint before they push (BH-5064)](2026-10-07-BH-5064-fixround-closure-lint.md)

## docs/verification-map/entries/BH-5946.md

- 2026-10-10 — [The blocked resolver profiles its run and cuts repeat reads (BH-5946)](2026-10-10-BH-5946-resolver-repeat-cuts.md)

## docs/verification-map/entries/BH-5962.md

- 2026-10-11 — [A throwaway Postgres for the pool suite run (BH-5962)](2026-10-11-BH-5962-pool-test-postgres.md)

## docs/verification-map/entries/BH-5965.md

- 2026-10-10 — [The overlap guard claims only the files a plan declares (BH-5965)](2026-10-10-BH-5965-declared-touch-set.md)

## docs/verification-map/lane-heartbeat.md

- 2026-10-05 — [BH-4721 (BH-4717.1): cron lanes judged by their last completed tick](2026-10-05-BH-4721-cron-lane-heartbeat.md)

## docs/verification-map/lead-review.md

- 2026-10-10 — [The lead review lane reads the needs-review worklist (BH-4956)](2026-10-10-BH-4956-lead-review-worklist.md)

## docs/verification-map/llm-choke-point.md

- 2026-10-12 — [BH-4987: catalog/llm-sites.json is composed from catalog/llm-sites.d/](2026-10-12-BH-4987-llm-sites-fragments.md)

## fc-board

- 2026-10-04 — [Tracker contract: one verb set, two adapters, the adapter chosen by a settings row (BH-4075)](2026-10-04-BH-4075-tracker-contract.md)

## fc-issues

- 2026-10-04 — [Tracker contract: one verb set, two adapters, the adapter chosen by a settings row (BH-4075)](2026-10-04-BH-4075-tracker-contract.md)

## fixround-preflight

- 2026-09-24 — [The fix-round preflight is capped per head, never truncates a PR body, and trusts only verdict authors](2026-09-24-BH-1992-preflight-followups.md)

## fleet-pauses

- 2026-10-13 — [The pause_flags mirror is retired, and a lint freezes new flags/ writes (BH-4154, slice C0)](2026-10-13-BH-4154-mirror-retired.md)
- 2026-10-03 — [Flags in the DB: paused-*, automerge-disabled* and lanedown-* are rows (BH-4153)](2026-10-03-BH-4153-flags-in-db.md)
- 2026-09-30 — [Factory stop: the CLI, the Fleet button, the poll-commands handler](2026-09-30-BH-3687-factory-stop.md)
- 2026-09-26 — [Fleet-scope PAUSE from Mission Control, and every pause says why, who and when](2026-09-26-BH-2509-fleet-pause.md)

## fleet-registry

- 2026-10-09 — [Audited registry writes and the add-box command (BH-5650)](2026-10-09-BH-5650-registry-writes.md)

## fly-machines

- 2026-09-26 — [Machines screen box-op buttons and BOX COMMANDS history (BH-2518.4, BH-2662)](2026-09-26-BH-2518-box-ops.md)

## fly-pool-sweep

- 2026-09-19 — [Pool writes Fly machine registry rows (observe, put, close, advisory)](2026-09-19-BH-1056-fly-pool-machine-rows.md)

## generated-files-train

- 2026-09-22 — [BH-1336: the committed rules render gets a direct CI check and a regenerate row](2026-09-22-BH-1336-render-rules-guards.md)

## gh-pr-list-rest

- 2026-09-20 — [2026-09-20 — BH-782: launch gates read REST; an UNKNOWN answer skips the tick](2026-09-20-BH-782-launch-gates-rest.md)

## gh-quota

- 2026-10-15 — [Who spends the GitHub REST budget (BH-6974, wave 1 of 3 of #6545)](2026-10-15-BH-6974-gh-budget-report.md)

## gh-rest

- 2026-09-20 — [2026-09-20 — BH-782: launch gates read REST; an UNKNOWN answer skips the tick](2026-09-20-BH-782-launch-gates-rest.md)

## harness-control-plane

- 2026-09-30 — [Factory stop: the CLI, the Fleet button, the poll-commands handler](2026-09-30-BH-3687-factory-stop.md)
- 2026-09-28 — [The coord proxy admits the merge-queue PATCH and the held-page release (BH-3157)](2026-09-28-BH-3157-proxy-writes.md)
- 2026-09-25 — [The coord proxy stamps `actor` and allowlists fields on every write](2026-09-25-BH-2405-coord-write-allowlist.md)
- 2026-09-24 — [The main-red label has one settable row, alerts name it, and project knobs reach the console](2026-09-24-BH-1985-main-red-one-knob-and-project-knobs.md)
- 2026-09-22 — [2026-09-22 — BH-1465: the five hub lanes honour the per-project hold](2026-09-22-BH-1465-hub-lanes-project-hold.md)
- 2026-09-22 — [2026-09-22 — BH-1464: `harness-ctl.sh off|on <hub lane> --project <p>`](2026-09-22-BH-1464-harness-ctl-project-hold.md)
- 2026-09-22 — [2026-09-22 — BH-1463: `lane_project_held`, the per-project hold contract](2026-09-22-BH-1463-lane-project-held.md)

## hotfix-lane

- 2026-09-22 — [BH-1363: the fix round's worktree gets an owner on every exit, and disk-clean gets the backstop](2026-09-22-BH-1363-brfix-worktree-cleanup.md)

## jobs-client

- 2026-10-03 — [Flags in the DB: paused-*, automerge-disabled* and lanedown-* are rows (BH-4153)](2026-10-03-BH-4153-flags-in-db.md)

## lane-cron-render

- 2026-09-22 — [2026-09-22 — BH-1185: the watchdog name comes from the registry, and three more render refusals](2026-09-22-BH-1185-render-cron-refusals.md)

## lane-volume-caps

- 2026-09-22 — [BH-1168: the alert-triage lane now stops on a noise budget, not only on a dollar cap](2026-09-22-BH-1168-noise-budget.md)

## lanes-status-contract

- 2026-09-22 — [2026-09-22 — BH-1466: a hub lane on a project tab](2026-09-22-BH-1466-hub-lane-chip.md)

## launch-gates-rest

- 2026-09-20 — [2026-09-20 — BH-782: launch gates read REST; an UNKNOWN answer skips the tick](2026-09-20-BH-782-launch-gates-rest.md)

## lead-authority

- 2026-10-03 — [Lead authority mode: a protected path no longer waits on a human (BH-4145, slice 1 of BH-4140)](2026-10-03-BH-4140-lead-authority-mode.md)

## lead-review

- 2026-09-24 — [A lead review retry replays the report on disk instead of paying again](2026-09-24-BH-2202-lead-review-no-rebill.md)

## lead-verdict

- 2026-10-03 — [Lead authority mode: a protected path no longer waits on a human (BH-4145, slice 1 of BH-4140)](2026-10-03-BH-4140-lead-authority-mode.md)

## llm-choke-point

- 2026-09-26 — [Per-stage runner allow-list for build calls (LLM_RUNNER_ALLOWED_<STAGE>)](2026-09-26-BH-2581-per-stage-runner-allow-list.md)
- 2026-09-26 — [Cost rows gain guard_fp, column 26 (BH-2537 slice 1, BH-2665)](2026-09-26-BH-2537-cost-row-identity.md)

## main-red-freeze

- 2026-09-24 — [An infra-only red on main is re-run once, not raised as main-red](2026-09-24-BH-2165-main-red-infra-rerun.md)
- 2026-09-22 — [The main-red re-test hold ends when main runs away from the sha it is holding](2026-09-22-BH-1475-main-red-hold-overrun.md)

## main-red-pr-pair

- 2026-10-11 — [main-red-pr-pair: a step header is not the first error (BH-5988)](2026-10-11-BH-5988-pr-pair-first-error.md)

## main-red-tip

- 2026-09-22 — [The main-red re-test hold ends when main runs away from the sha it is holding](2026-09-22-BH-1475-main-red-hold-overrun.md)

## merge-rest

- 2026-09-22 — [BH-1483: the branch delete retargets a stacked child instead of closing it](2026-09-22-BH-1483-stacked-child-retarget.md)

## merge-trains

- 2026-09-22 — [A merge train that is BEHIND the tip is re-verified there, or it is closed](2026-09-22-BH-1306-reform-when-behind.md)

## migration-ledger

- 2026-10-06 — [The resolver parks a data-lane block as DATA_LANE, never on the abandon ladder (BH-4926)](2026-10-06-BH-4926-resolver-data-lane-park.md)
- 2026-10-06 — [The appliability gate reads a scripts/migrate-*.ts migration (BH-4924)](2026-10-06-BH-4924-migrate-ts-lint.md)
- 2026-10-06 — [The data lane's first slice: a DATA_LANE: review line, and a head-bound pre-merge apply (BH-4923)](2026-10-06-BH-4923-data-lane-contract.md)
- 2026-10-06 — [The data lane proves its apply: probe, evidence file, evidence comment (BH-4925)](2026-10-06-BH-4920-data-lane.md)
- 2026-09-26 — [Migration autopilot ledger is DB only (BH-2532.1, BH-2623)](2026-09-26-BH-2623-migration-ledger-db-only.md)

## mission-control-settings

- 2026-09-26 — [CONTROLS: one console screen for the editable config kinds (BH-2513.4, BH-2621)](2026-09-26-BH-2513-config-editors.md)
- 2026-09-25 — [The coord proxy stamps `actor` and allowlists fields on every write](2026-09-25-BH-2405-coord-write-allowlist.md)
- 2026-09-24 — [The main-red label has one settable row, alerts name it, and project knobs reach the console](2026-09-24-BH-1985-main-red-one-knob-and-project-knobs.md)
- 2026-09-22 — [2026-09-22 — BH-1466: a hub lane on a project tab](2026-09-22-BH-1466-hub-lane-chip.md)

## model-prices

- 2026-09-24 — [The deploy price hook runs detached, refuses an empty table read, and a catalog POST only inserts](2026-09-24-BH-1890-model-prices-hook-detached.md)
- 2026-09-23 — [The vendor-direct price moves into D1, and a failed marks read stops the refresh](2026-09-23-BH-1754-vendor-price-in-d1.md)
- 2026-09-23 — [A per-model price source: vendor-direct models keep the catalog rate](2026-09-23-BH-1613-price-source.md)

## none

- 2026-10-16 — [BH-7122: a hub sync killed after the code copy is not "OLD harness"](2026-10-16-BH-7122-hub-sync-post-copy-timeout.md)
- 2026-10-16 — [BH-7119: one helper writes the worker catalogs for a suite](2026-10-16-BH-7119-worker-catalogs-helper.md)
- 2026-10-16 — [BH-7118: the lead-review enqueue carries a verdict across a schema restamp](2026-10-16-BH-7118-lead-carry-restamp-enqueue.md)
- 2026-10-16 — [BH-7059 slice C1: GET /api/metrics/cost-rows reads the archive](2026-10-16-BH-7059-cost-rows-reader.md)
- 2026-10-16 — [BH-7059 slice C0: the routes/cost.js history readers read the archive](2026-10-16-BH-7059-cost-readers.md)
- 2026-10-16 — [BH-6523 site record: the 66 marked SQL sites, the 2 real findings, the fractional-limit reads](2026-10-16-BH-7058-sql-ident-site-record.md)
- 2026-10-16 — [BH-7035 slice C0: the remaining wide history readers read the archive](2026-10-16-BH-7035-archive-readers-c0.md)
- 2026-10-16 — [BH-7027: a PR select narrows catalog/ paths through their reader rows](2026-10-16-BH-7027-pr-catalog-select.md)
- 2026-10-16 — [BH-6976 (BH-6545.3): three pollers read wakes, their full poll is a backstop](2026-10-16-BH-6976-wake-backstops.md)
- 2026-10-16 — [BH-5934: box switches on /flags, and the long dated latch pin](2026-10-16-BH-5934-box-switches-and-long-latches.md)
- 2026-10-15 — [History readers read the archive store too (BH-6779, slice C0)](2026-10-15-BH-6779-archive-readers.md)
- 2026-10-02 — [Fast always-lints: the before number, why, and the after number we still owe (BH-3860, BH-3865)](2026-10-02-BH-3860-fast-always-lints.md)

## none (no contract doc changes; `bin/nightly-ticket.sh`'s header carries the label behaviour)

- 2026-09-29 — [Nightly red: two suite fixtures, and the nightly ticket opens labelled ai-build (BH-3411)](2026-09-29-BH-3411-nightly-red-fixtures-and-label.md)

## onboarding-a-repo

- 2026-10-12 — [Onboarding checks browser-QA wiring, and a daily lane alerts until it is wired (BH-6254)](2026-10-12-BH-6254-qa-wiring.md)

## pr-rows-contract

- 2026-10-07 — [What writes PR gate facts, and the sweep that heals them (BH-4954)](2026-10-07-BH-4954-pr-gate-writers.md)

## queue-panel

- 2026-09-28 — [Deploy queue HOLD / UNHOLD (BH-3154, BH-2510.4)](2026-09-28-BH-3154-deploy-hold.md)

## remote-result-relay-once

- 2026-09-22 — [BH-1301: a staged result is consumed only on positive proof, and a rescue keeps the provenance that supplies it](2026-09-22-BH-1301-staging-identity.md)

## render-rules

- 2026-09-22 — [BH-1336: the committed rules render gets a direct CI check and a regenerate row](2026-09-22-BH-1336-render-rules-guards.md)

## repro-gate

- 2026-09-24 — [BH-2133: the harness's own comments are not the board moving](2026-09-24-BH-2133-own-comments-not-input.md)
- 2026-09-24 — [Pre-build repro gate: the PR-body URL line is a capped code span](2026-09-24-BH-2123-repro-url.md)
- 2026-09-24 — [Pre-build repro gate: the plan brief line and the PR-body section render](2026-09-24-BH-2042-repro-render.md)

## resolver-family-adjudication

- 2026-09-22 — [One iron-law ruling now covers a whole family of PRs](2026-09-22-BH-1471-family-adjudication.md)

## resolver-hold

- 2026-09-29 — [A lift word opening a comment lifts a hold; an ambiguous comment on a held ticket alerts (BH-3435)](2026-09-29-BH-3435-hold-lift-words.md)
- 2026-09-22 — [2026-09-22 — BH-1465: the five hub lanes honour the per-project hold](2026-09-22-BH-1465-hub-lanes-project-hold.md)

## resolver-mechanical-rungs

- 2026-09-22 — [BH-1470: the resolver answers two parks with git instead of a model call](2026-09-22-BH-1470-mechanical-rungs.md)

## resolver-opt-hooks

- 2026-09-22 — [One iron-law ruling now covers a whole family of PRs](2026-09-22-BH-1471-family-adjudication.md)
- 2026-09-22 — [BH-1470: the resolver answers two parks with git instead of a model call](2026-09-22-BH-1470-mechanical-rungs.md)

## resolver-prepass

- 2026-09-22 — [BH-1512: a zero-byte resolver record is counted and named, not dropped](2026-09-22-BH-1512-empty-record-loud.md)

## review-record-integrity

- 2026-09-22 — [BH-1320 — hb_post keeps the `.json` envelope when the review `.md` is missing](2026-09-22-BH-1320-hb-post-envelope.md)

## review-tier

- 2026-09-24 — [Schema-risk patterns match Prisma's folder layout](2026-09-24-BH-1974-prisma-schema-folder-risk.md)

## run-rollout

- 2026-10-03 — [Rollout refusals: the documented heading parses, refusals reach the master, and the pool stops calling them deaths (BH-4061)](2026-10-03-BH-4061-rollout-refusals.md)

## sentry-report

- 2026-10-12 — [review-prs reports a /tmp cap once per cap change (BH-6132)](2026-10-12-BH-6132-review-prs-tmp-cap-change.md)

## settings-knobs

- 2026-10-04 — [Linear adapter on the tracker contract (BH-4077)](2026-10-04-BH-4077-linear-adapter.md)
- 2026-10-04 — [Jira Cloud adapter on the tracker contract, behind a sandbox guard (BH-4076)](2026-10-04-BH-4076-jira-adapter.md)
- 2026-10-04 — [Tracker contract: one verb set, two adapters, the adapter chosen by a settings row (BH-4075)](2026-10-04-BH-4075-tracker-contract.md)

## skills/console-deploy/SKILL.md

- 2026-10-15 — [Console preview: the lane strips preview bindings, and QA reports a binding gap (BH-6923)](2026-10-15-BH-6923-console-preview-bindings.md)

## spending-caps

- 2026-10-09 — [The self-host installer runs under macOS bash 3.2 (BH-5732)](2026-10-09-BH-5732-selfhost-install-bash32.md)

## standby-hub

- 2026-09-26 — [STANDBY panel on /hub (BH-2641, BH-2519.3)](2026-09-26-BH-2641-standby-panel.md)

## test-impact

- 2026-09-29 — [The rules pack engine: local runner and built-in checks (BH-3510, BH-3477.1)](2026-09-29-BH-3510-rules-pack.md)
- 2026-09-23 — [2026-09-23 — BH-1554: the impact gate's budget is 450 s, and four smaller fixes from the #1541 round-2 review](2026-09-23-BH-1554-impact-gate-budget-450.md)
- 2026-09-22 — [A build of cromford runs the suites its diff can reach before it pushes](2026-09-22-BH-1524-builder-impact-gate.md)
- 2026-09-22 — [BH-1253: test-impact runs under mawk, follows unbraced `$VAR/` source lines, refuses an empty tree, and stops counting comment citations for the orphan ratchet](2026-09-22-BH-1253-test-impact-mawk-and-comment-citations.md)

## tests/README.md

- 2026-10-07 — [Closure lint sees edited hand lists; a sweep converts old ones (BH-5263, BH-5235.3)](2026-10-07-BH-5235-closure-sweep.md)
- 2026-10-06 — [The scratch-closure lint runs at PR time and in the builder gate (BH-4869)](2026-10-06-BH-4869-scratch-closure-pr-lint.md)
- 2026-10-05 — [The scratch-closure lint graces branches cut before it landed (BH-4632)](2026-10-05-BH-4632-scratch-closure-grace.md)
- 2026-10-05 — [Scratch trees copy a script's source closure, not a hand list (BH-4552)](2026-10-05-BH-4552-scratch-install-closure.md)

## ticket-identity

- 2026-09-22 — [BH-1169 — triage-gate keymap: derive `<PREFIX>-<number>` when a board row has no `key`](2026-09-22-BH-1169-keymap-derived-key.md)

## tmp-sweep

- 2026-10-11 — [Lead reviews ran 1 at a time: /tmp leftovers and a 4 GB tmpfs (BH-6041)](2026-10-11-BH-6041-review-tmp-capacity.md)
- 2026-10-08 — [The /tmp sweep removes builder and reviewer checkouts, every 15 min (BH-5608)](2026-10-08-BH-5608-tmp-sweep-15min.md)

## tracker-adapter

- 2026-10-06 — [A deploy-train revert reopens the ticket it rolled back (BH-4915)](2026-10-06-BH-4915-deploy-rollback-reopens-ticket.md)
- 2026-10-04 — [Linear adapter on the tracker contract (BH-4077)](2026-10-04-BH-4077-linear-adapter.md)
- 2026-10-04 — [Jira Cloud adapter on the tracker contract, behind a sandbox guard (BH-4076)](2026-10-04-BH-4076-jira-adapter.md)
- 2026-10-04 — [Tracker contract: one verb set, two adapters, the adapter chosen by a settings row (BH-4075)](2026-10-04-BH-4075-tracker-contract.md)

## tracker-jira

- 2026-10-04 — [Jira Cloud adapter on the tracker contract, behind a sandbox guard (BH-4076)](2026-10-04-BH-4076-jira-adapter.md)

## verification-map

- 2026-10-13 — [The pause_flags mirror is retired, and a lint freezes new flags/ writes (BH-4154, slice C0)](2026-10-13-BH-4154-mirror-retired.md)
- 2026-10-09 — [No tracked file is git-ignored or says "do not commit" (BH-5518, slice C2)](2026-10-09-BH-5518-generated-not-tracked.md)
- 2026-10-04 — [Review rescue finds REVIEW_BLOCKED builds whose pool box was reaped (BH-4437)](2026-10-04-BH-4437-review-rescue-reaped-box.md)
- 2026-10-04 — [The cost rollup's checkpoints live in the DB (BH-4158)](2026-10-04-BH-4158-cost-checkpoints-db.md)
- 2026-10-04 — [Cost and lane caps as settings seed rows (BH-4155)](2026-10-04-BH-4155-caps-seed-rows.md)
- 2026-10-03 — [Flags in the DB: paused-*, automerge-disabled* and lanedown-* are rows (BH-4153)](2026-10-03-BH-4153-flags-in-db.md)
- 2026-09-24 — [run-build.sh runs its stages from bin/lib/rb/](2026-09-24-BH-572-run-build-cut.md)

## watchdog-spec

- 2026-10-11 — [The three LLM alert lanes run per project (BH-5942)](2026-10-11-BH-5942-llm-lanes-per-project.md)
- 2026-09-26 — [The watchdog responder settles two known conditions without a model call](2026-09-26-BH-2548-responder-scripted-fixes.md)
- 2026-09-24 — [Watchdog hub failover: failoverTick promotes the one healthy standby](2026-09-24-BH-401-warm-standby-hub.md)
- 2026-09-24 — [Watchdog warm-standby contract: KV shape, failoverTick stub, node test runner](2026-09-24-BH-1920-watchdog-standby-contract.md)

## worker/jobs/README.md

- 2026-10-13 — [Jobs-worker route families register through their fragment (BH-4607)](2026-10-13-BH-4607-routes-from-fragments.md)
- 2026-10-09 — [Lead reviews no longer get stuck on a failed request, a silent skip or a stale running row (BH-5779)](2026-10-09-BH-5779-lead-review-stuck.md)
- 2026-10-09 — [Lead review claims: heartbeat, reclaim, participants, separation of duties (BH-5351)](2026-10-09-BH-5351-participant-lead-review-claims.md)
- 2026-10-08 — [Mission Control participants screen (BH-5353, BH-5348.4)](2026-10-08-BH-5353-participants-screen.md)
- 2026-10-07 — [BH-4987: worker/jobs/schema.sql is composed from schema.d/ fragments](2026-10-07-BH-4987-schema-fragments.md)
- 2026-10-06 — [BH-4846: custom themes on /settings/appearance](2026-10-06-BH-4846-custom-themes.md)
- 2026-09-25 — [Alert row actions: the worker route and the proxy (BH-2369, BH-2324 child 2)](2026-09-25-BH-2324-alert-row-actions.md)
- 2026-09-23 — [2026-09-23 — BH-1610 (BH-1595.3): reconcile-prs remembered answers move to D1](2026-09-23-BH-1595-reconcile-d1-memory.md)

## zero-means-off

- 2026-09-22 — [BH-1168: the alert-triage lane now stops on a noise budget, not only on a dollar cap](2026-09-22-BH-1168-noise-budget.md)

## untagged

- 2026-10-17 — [BH-7252 C0: hub lane CPU rank (CPU seconds per hour per lane)](2026-10-17-BH-7252-lane-cpu-rank.md)
- 2026-10-17 — [BH-7229: the stale-stamp rule judges dependency, not stamp age](2026-10-17-BH-7229-stamp-order.md)
- 2026-10-16 — [BH-7029: each prequeue call is named, timed and bounded](2026-10-16-BH-7029-prequeue-call-bound.md)
- 2026-10-16 — [2026-10-16 — BH-6657: race-sigpipe-echo scans bin/](2026-10-16-BH-6657-sigpipe-echo-bin-scope.md)
- 2026-10-15 — [Pool supervisor off the hub: measured inventory and plan (BH-6896, part of #6881)](2026-10-15-BH-6896-fly-pool-offhub.md)
- 2026-10-09 — [BH-5793: an environment failure never writes a BLOCK](2026-10-09-BH-5793-env-failures-never-block.md)
- 2026-10-09 — [BH-4991: the ticket page (2026-10-09)](2026-10-09-BH-4991-ticket-detail.md)
- 2026-10-09 — [BH-4883: flags worker route + D1 table only (split from #4332)](2026-10-09-BH-4883-flags-route-split.md)
- 2026-10-08 — [2026-10-08: model-id-delta reads schema.sql and schema.d/ as one file (BH-4987)](2026-10-08-BH-4987-model-id-delta-schema-d.md)
- 2026-09-23 — [2026-09-23 — BH-1608 (BH-1595.1): reconcile-prs owner heartbeat + watchdog page](2026-09-23-BH-1595-reconcile-owner-beat.md)
- 2026-09-22 — [BH-1456 — an account in overage has headroom, and `default` is judged by the account it bills](2026-09-22-BH-1456-overage-headroom.md)
- 2026-09-22 — [BH-1201 — the conductor HOLDS its age pages while it is paused, and flushes them when the mode returns](2026-09-22-BH-1201-conductor-paused-hold.md)
- 2026-09-20 — [BH-1175 — the verification-map index is generated, not committed](2026-09-20-BH-1175-vmap-readme-not-committed.md)
- 2026-09-20 — [BH-1131 — the two defects that deadlocked PR #728, and the silence around them](2026-09-20-BH-1131-block-gate-clear-and-rest.md)
- 2026-09-19 — [BH-947: the rebuild rung holds on a live build and caps on the job ledger](2026-09-19-BH-947-rebuild-wait.md)
- 2026-09-19 — [BH-1090: per-account lane-down markers and additive ACCOUNT_EXHAUST_REGEX](2026-09-19-BH-1090-lane-down-per-account.md)
