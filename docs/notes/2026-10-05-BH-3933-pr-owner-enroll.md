# BH-3933: every open PR gets an owner (BH-3929.1)

Doc: PR-OWNERSHIP, MERGE-CONDUCTOR

**What changed.** `bin/pr-owner-sweep.sh` is a hub lane now
(`cron/lanes/412-pr-owner-sweep.cron`, every 30 minutes, behind
`bin/hub-lease.sh check`). Its `po_enroll` hook gives an ownerless ORPHAN, and
an ownerless EXTERNAL PR while the D1 settings row `pr_owner.enroll_external`
is `1`, a merge-conductor row: READY when the head is APPROVEd, CI green,
`mergeable_state` clean and not a draft (the `enrolled` pr_attempts row is
written first), WAIT_CI otherwise. Every READY key of a tick goes to ONE keyed
conductor run. In a keyed run the conductor fetches an outside key by number
(`mc_enrolled_rows`), and `pr_worker` accepts an enrolled PR in any tick,
keyed or not, only while the `enrolled` row is on its current head. The check
is `mc_enrolled_pr`, a pre-check in front of the unchanged harness pr probe: it
reads the row only when the PR has no build record and is not on a `ticket/*`
or `main-red-revert/*` branch, and any miss falls through to the probe. An ORPHAN of ours on a feature branch is
in the open list, so the ordinary 5-minute tick drives it.

**External PRs can now merge through the conductor.** That is the point of the
slice, and it still goes through every conductor gate. The kill switch is the
settings row `pr_owner.enroll_external=0`: EXTERNAL PRs are then recorded only,
as before (`enroll-recorded-only` in the log). The switch is about OUTSIDE
authors only. The conductor reads it where the author is known, in
`mc_enrolled_rows`, so a keyed run stops injecting an external PR enrolled
earlier (`external enrollment off`), and the next sweep withdraws that PR's
READY row to `WAIT_CI enroll-withdrawn`, reviewed `-`, which takes it out of the
backstop. An enrolled ORPHAN of ours is not affected. In the conductor a
settings outage reads the switch as off.

**Ownerless.** What is still unowned after the hooks is counted on the lane tick
(`hb_tick pr-owner-sweep "repos= open= owned= external= enrolled= ownerless=
superseded= stale_rungs="`). A repo whose count stays above zero for
`pr_owner.ownerless_alert_hours` (default 24) sends ONE alert, `--id
pr-owner-ownerless:<slug>`. The clock is a settings row
(`streak.pr-owner-ownerless.<slug>`, `ph_streak`), never a file. The alert is
stamped `:fired` only after it was sent, and resolved when the count is 0.

**Owner source.** The conductor's ownership comes from the D1 `pr_state` view,
filtered by repo and paged by id, when the `pr-state-rows` flag is up (the
ticket named `job_ledger_list pr_state`, which has no repo filter and stops at
1000 rows, so a live idle row could drop off it and its PR be enrolled twice).
`state/merge-conductor/pr-state.tsv` is read only when the flag is down. An
unreadable view sweeps nothing for that repo.

**Writes.** The sweep's comment, close and label are REST now
(`gh_rest_comment`, `gh_rest_close`, `gh_rest … /labels`). A comment GitHub
refused stops the close or label, and the PR is held `write-failed`.

**Decided here.** Only a fleet-wide run enrolls, spawns or moves the ownerless
clock; `bin/orphan-reconcile.sh`'s `--repo` run records only. Enrollments have
their own per-repo counter capped at `PR_OWNER_MAX_ACTIONS`. EXTERNAL under
knob `0` counts in `external=`, not `ownerless=`. An ORPHAN enrolled this tick is
not also handed back to its box (it would rebuild a ticket being landed).

**The re-check set (rebuild of #4127, review findings 1 and 2).** A READY or
WAIT_CI row the sweep wrote, and one stranded on an old head past the grace
window on an EXTERNAL PR or a non-`ticket/*` branch, is re-decided every sweep
on the current head. So a READY row never stays on a head that is not the PR's,
and the backstop (which picks READY/WAIT_CI rows with head = reviewed from
`pr-state.tsv`) never selects an old head. A `ticket/*` or `main-red-revert/*`
row is the conductor's own and is never rewritten on a head mismatch; neither
is a row in any other state (BLOCKED_HUMAN, REBASING and the other hand-offs).
Rebase and fix rounds for external PRs are a follow-on ticket.

**Gate probe (BH-1000), as run by build 2 on 2026-10-05.** The new lane sits behind `bin/hub-lease.sh check &&`,
so the lease it gates on must already answer in prod. This build ran on pool box
`pool-cromford-d8d0ed9b5d9298`, where `bin/hub-lease.sh check` answers
`rc=1`, which is right for a box that is not the hub. The probe below is the
same `GET /api/hub-lease?holder=` request `check` makes, sent read-only through
`jobs-client.sh` for the hub's own name (`hub_box_name`), at 2026-10-05T17:41:04Z:

```
rc=0
{"lease":{"holder":"box-hub","epoch":2,"expires_at":"2026-10-05T17:43:25Z","updated_at":"2026-10-05T17:40:25Z","expired":false,"remaining_s":141},"as_of":"2026-10-05T17:41:04Z"}
```

The worker answers, the `hub_lease` row exists, and `box-hub` holds an
unexpired lease it renewed 39 seconds earlier, so `check` on the hub takes its
held branch. This is not `bin/hub-lease.sh check` run on the hub itself. That
literal command has not been run, because this box cannot run it.

**Rebuild 3 (2026-10-07).** Build 2 (#4708) was approved and then ejected twice
from the merge queue, and every red suite came from its own diff. This build is
build 2's code plus four fixes:

- **F4, the clock seam.** The sweep took `PR_OWNER_NOW` only under
  `HARNESS_TEST_SANDBOX=1`, and CI's traced shards never set that flag (only the
  two root guards read it). In CI the sweep read the wall clock against rows
  pinned weeks earlier, so a 23h streak paged and a head that moved a minute
  ago was rewritten. `PR_OWNER_NOW` is now honoured whenever it is all digits,
  like `HUB_LEASE_NOW` and `TRIAGE_NOW`; anything else reads the real clock.
  The enroll suite runs every sweep with the flag unset.
- **F5, the probe block.** Build 2 added the enrolled test to the line inside
  the `# >>> harness pr probe` markers, which
  `tests/pr-dep-gate-rest.bh-994-test.sh` extracts verbatim and runs with no
  `HEAD` in scope. The block is byte-identical to main again, and
  `mc_enrolled_pr` wraps it.
- **F6, the source order.** `bin/lib/pr-health.sh` is sourced after
  `mc-ci-timeout.sh`, not between `tier2-autoenqueue.sh` and
  `mc-hold-comment.sh`, whose adjacency
  `tests/mc-hold-comment-contract.bh-3452-test.sh` pins.
- **F7, the scratch installs.** The suites that run the sweep install its libs
  with `scratch_install_closure` instead of hand `cp` lines
  (`tests/scratch-closure-lint.bh-4552-test.sh`).

The gate probe above is build 2's and is not current. Build 3 ran on pool box
`pool-cromford-784750ec010448`, where `bin/hub-lease.sh check` answers
`rc=1` (not the hub) and a read-only `GET /api/hub-lease?holder=box-hub`
through `jobs-client.sh` failed in transport at 2026-10-07T00:30:10Z: this box
has no route to the jobs worker. The live probe on the hub is still owed.

