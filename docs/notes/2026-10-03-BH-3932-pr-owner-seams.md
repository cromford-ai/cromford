# BH-3932: the PR-owner sweep's hook seams (BH-3929.0)

Doc: PR-OWNERSHIP

**What changed.** `bin/pr-owner-sweep.sh` now calls four hooks on every open PR,
in this order: `po_superseded`, `po_enroll`, `po_stale`, `po_health_add`. It
calls `po_health_flush` once per repo. The hooks live in `bin/lib/pr-owner/`
and every one is a stub that declines, so the sweep makes the same GitHub and
jobs-API writes it made before. `tests/pr-health-lib.bh-3929-test.sh` L7h diffs
those writes against main's sweep.

**The one runtime change** is the registry gate. The sweep is now the lane
`pr-owner-sweep` (`catalog/lanes.d/pr-owner-sweep.json`), so `flags/all-off`,
`lane-off-pr-owner-sweep` and its D1 pause row stop it, including when
`bin/orphan-reconcile.sh` rings it. Every run posts the gate's liveness row.
The lane has no cron line. That arrives with #3933.

**New shared helpers**, in `bin/lib/pr-health.sh`: `ph_knob` (settings row >
env > default, 0 binds), `ph_ci_only_body` (is every BLOCK finding a
CI-did-not-run one) and `ph_review_covered` (is this head already reviewed).
`ph_review_covered` has no caller yet. #3933 and #3934 read it.

**Conductor.** `bin/merge-conductor.sh` calls `mc_block_ci_step`
(`bin/lib/mc/block-ci.sh`, a stub) after a block-gate refusal and ignores its
answer. `mc_handoff_owns` and `mc_resolver_owns` accept `stale-replan*`, which
nothing writes until #3935.

**Settings seeds.** `pr_stale.rebase_hours`=24, `pr_stale.replan_days`=5,
`pr_stale.close_days`=10, `pr_owner.enroll_external`=1 and
`pr_owner.ownerless_alert_hours`=24, as `INSERT OR IGNORE` statements in
`worker/jobs/schema.sql`. `bin/harness-sync.sh` applies them.

**Decided here.** `ph_ci_only_body` is stricter than the ticket's vocabulary.
Each BLOCK line must also name CI or a workflow and name no file, because #3934
will clear a BLOCK on its answer. The parent plan file for BH-3929 was not on
disk, so `docs/PR-OWNERSHIP.md` §10 states the design without quoting its
decision numbers. It also fails closed on any BLOCK it does not check: a
`[BLOCK]` in numbered or bold form, a prose BLOCK beside `- [BLOCK]` lines, a
second BLOCK paragraph, or a list item inside the one paragraph it reads is
rc 1. A bare `VERDICT: BLOCK` line is skipped.

**Known gap.** A `- [BLOCK]` line reading "CI passed, but the migration did
not run on prod" names CI and matches the vocabulary, so `ph_ci_only_body`
answers rc 0 for it today. Nothing clears a BLOCK on that answer yet; #3934
adds the finer rule before it does.
