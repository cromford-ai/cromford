# Two corrections to the wake classes: the reconcile-prs window and per-job check rows

Doc: EVENTS

**What changed.** Two head-bound review findings on PR #1101 (BH-1060), both
fixed where the BH-1034 contract already has a knob. Two product lines.

- **`bin/reconcile-prs.sh` passes an explicit `300` to `wake_backstop_skip`.**
  The wake launch fires 15-45s after a `pull_request.closed` row. That run
  stamps `state/wake-ran/reconcile-prs-fleet` and then refuses the closure it
  was woken for, because a closure younger than `MC_CLOSED_SETTLE` (180s,
  `bin/lib/mc/settle.sh`) may be a merge-conductor kick mid-flight. With the
  lib's 1800s default every `*/10` cron tick for the next half hour then stood
  down on a stamp that asserted work nobody had done, so a closed-UNMERGED row
  cleared after up to ~30 minutes. 300s is past the settle window with margin
  for the wake latency and inside the 600s cron period, so the first tick after
  the window both runs and finds the closure settled. Worst case is now ~16
  minutes (stamp + 300 + one cron period), against ~13 before wakes existed.
  Same shape as `bin/fleet-propagate.sh` (60) and `bin/flaky-detect.sh` (43200):
  a per-call argument, not a new env or settings name. `WAKE_BACKSTOP_S` stays
  the fleet dial for every paste that passes no window — and no longer applies
  to this lane, which is the point of the override.
- **`bin/lib/wake-class-pr-ci.sh` counts only `check_suite.completed`.** The
  receiver stores a `checks` wake for `check_run.completed` as well as
  `check_suite.completed`, deduped only per `(repo, kind, key, minute)`. A CI
  run whose jobs finish across N minutes is therefore N rows for one sha, and
  `wc_pr_ci_row` counted every one of them, so `bin/review-prs.sh` could be
  launched once per 120s cooldown per project for the length of a run. Only a
  completed check SUITE — one per run per sha — adds the project now, exactly
  as `bin/lib/wake-class-flaky.sh` has always done. The 120s cooldown is
  unchanged, so a genuine suite completion still reviews promptly.

**Not changed.** The `pr` arm of the pr-ci class (`opened`/`synchronize`/
`reopened`/`ready_for_review` still drive review-prs), the snapshot bit, the
cooldown values, `review-prs.sh`'s own CI debounce, the legacy conductor launch
on `pr|checks` rows (it still fires on per-job rows), the worker receiver, and
the `check-migration-prs`/`alerts-groom` pastes — neither reads the settle
window, so neither has this bug.

**Watch when the flags flip.** These only bite once an operator runs
`bin/jobs-client.sh flag-set wake-lanes-pr-ci on` and
`flag-set wake-lanes-pr-closed on`. After the pr-ci flip, `logs/wake-loop.log`
should show at most one `review-prs[<project>]` launch per completed suite
rather than a line per finished job, and `logs/gh-rate.log` should show no new
`gh-limit` lines for `review-prs` (this change only ever reduces that lane's GitHub
call volume). After the pr-closed flip, `logs/wake-backstop.log` lines for this
lane read `reconcile-prs[fleet]: ... (backstop 300s)`; a `1800s` there means a
box is still running the old copy.

**Corrects** the two rows of the table in
`docs/notes/2026-09-19-BH-1034-pr-classes.md` that describe the pr-ci `checks`
arm and the reconcile-prs backstop window. That note is merged and is not
edited; this is the later note.

**Tests.** `tests/wake-pr-ci-suite-only.bh-1292-test.sh` and
`tests/reconcile-prs-backstop-window.bh-1292-test.sh`, both through the real
`bin/wake-loop.sh` / `bin/reconcile-prs.sh`. Case 6 of
`tests/wake-pr-closed-drives-lanes.bh-1034-test.sh` moved its fixture stamp from
`NOW-300` to `NOW-120`: at a 300s window a 300s-old stamp is no longer fresh.
