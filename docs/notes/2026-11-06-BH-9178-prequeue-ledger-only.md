# BH-9178 (C2 of #9063): the pre-queue impact step reads the suite ledger only

Doc: MERGE-CONDUCTOR, CI-RUNNERS

## What changed

1. **Ledger mode for the pre-queue gate.** `.github/workflows/prequeue-gate.yml`
   and `.github/workflows/prequeue-group-gate.yml` take a new optional input
   `impact`. With `impact=ledger`, the verdict step runs the invariants as
   before (`bin/prequeue-invariants.sh`, main's catalog). Then it runs
   `bin/prequeue-ledger.sh` instead of `bin/test-impact-gate.sh --runner local`.
   - The script gets the same run list the gate would run:
     `bin/test-impact-gate.sh --runner plan --list` (cap, `--skip-suites` from
     the invariants, learned `--also`). The plan runner runs no suite.
   - It asks the ledger about that list through `bin/suite-reuse.sh plan`
     (class ci, the batch's ctx, fingerprints at the merge). It passes
     `--reds`. It never passes `--rerun-red`.
   - It runs no suite and writes no ledger row.
2. **Hub knob.** `pq_impact_args` (`bin/lib/mc-prequeue.d/impact-ledger.sh`)
   adds `-f impact=ledger` to the `pq_dispatch` argv (empty suites only) and
   the `pq_group_flush` argv. It does this when `MC_PREQUEUE_IMPACT_LEDGER` is
   not 0 (default 1) and the hub carries `bin/prequeue-ledger.sh`.
   `MC_PREQUEUE_GATE` and its default 1 are unchanged.
3. **The inline prune.** `PUT /api/suite-results` deleted rows older than 30
   days (500 a call) on every write. Now it does that only while the scheduled
   rule `suite_results.age` (14 days, BH-9063 C0) does not delete. The rule
   deletes when `retention.dry_run` = 0 AND `retention.suite_results.days` > 0
   (`pruneOwnedByRule`). The PUT reads both rows in one statement. A failed
   read keeps the prune on. The 30-day and 500-row values are unchanged and
   apply only while the prune runs.

## The verdict in ledger mode

| Invariants | Ledger answer | Verdict |
|---|---|---|
| red | any | `red ... why=invariant:<ids>` (the invariant leads) |
| green | a red row for a selected suite | `red suites=<reds> why=ledger-red` |
| green | greens, or no row | `green` (no row = unverified, the batch runs it) |
| green | ledger off (no credential, unreachable, server knob off) | `green`, notice says `ledger=off:<why>` |
| any | empty selection (plan rc 2) | `no-selection` |
| any | plan runner failed | `could-not-run ... why=rc-125` |
| any | no `bin/prequeue-ledger.sh` in the merged tree | `could-not-run ... why=no-ledger-script` |

`impact` other than `''` or `ledger` is `could-not-run ... why=bad-impact`,
before the fetch. A named `suites` input still wins: those suites run.

One notice per ledger-mode job carries the counts:
`::notice title=prequeue-ledger::selected=N green=G red=R unverified=U ledger=on|off:<why> reds=on|unsupported reds_bad=B`.
A green verdict never says a suite ran. `green` counts ledger hits only.

## Red rows

The red list comes from `bin/suite-reuse.sh plan --reds OUT` (slice C1,
#9177). Today's helper rejects `--reds` (rc 2, `unknown argument --reds`).
The script then asks once more without it, and the notice says
`reds=unsupported`. Until C1 merges, ledger mode can make no `ledger-red`
verdict: every suite with no green row is unverified, and the batch runs it.
A reds line counts only when its first tab-separated column is a
`tests/[mc/]*.sh` in the run list. A line of another shape is counted in
`reds_bad`.

Suites the fingerprint never reuses (the always set and the fast-lint set,
`bin/lib/suite-fingerprint.sh`) are always unverified in ledger mode.

## Rollback

- Set the settings row `lane.merge-conductor.mc_prequeue_impact_ledger` to 0.
  The hub then sends no `impact`, and the gate runs the suites as before.
- The prune follows `retention.dry_run`. While it is 1 (the seed), the PUT
  prunes as before.

## Owed steps

1. Read the `suite_results.age` dry-run rows in `retention_runs` on prod.
   Then set `retention.dry_run` to 0. That flip stops the inline prune.
   This box cannot read prod, so the flip is not part of this PR.
2. The 24 h count, 24 h after the hub syncs this merge. For each
   cromford PR merged in the window, count the runs of each selected
   suite:
   - builder gate: `impact-gate: done <suite>` lines in each build's gate log;
   - selection gate: its gate log, the same lines;
   - pre-queue: 0 in ledger mode (the `prequeue-ledger` notice); a run-mode
     pre-queue counts its suites;
   - merge-queue batch: one run per suite it ran.
   Take the median per PR. The target is at most 2 runs per suite. BEFORE
   (the #9063 audit, as the BH-9178 plan quotes it; not re-measured by this
   build): 4 to 6 runs per suite per PR.

## Not changed

`bin/impact-learn-lane.sh` step 7b still asks for passes since 30 days back.
With the 14-day rule deleting, it gets 14 days of rows. An edge then expires
later, not sooner, which is the safe direction.
