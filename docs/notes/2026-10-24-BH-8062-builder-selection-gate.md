# Shape B: no pre-queue gate on the CI runners; the builder runs the batch's selection first (BH-8062)

Doc: BUILD-CONCURRENCY, MERGE-CONDUCTOR, REMOTE-GATE

## What changed

The rule: **the gate predicts the batch, or it says it cannot.** The merge
conductor no longer pays CI runners to ask that question for every READY PR.
The builder asks it once, before the PR opens, on the fleet test host.

1. **No seed row ships for the pre-queue gate (review 5641193259, option 1).**
   The switch is the existing knob `MC_PREQUEUE_GATE` (lane merge-conductor).
   The row `lane.merge-conductor.mc_prequeue_gate` stays at its code fallback
   `1`, so the CI pre-queue gate (`prequeue-gate.yml`) stays on at the merge,
   and the selection gate below runs in addition. An operator sets the row to
   `0` per "Operator steps" below. With the row at 0, `pq_gate` publishes
   `prequeue-verdict` success "gate off" and answers proceed before any
   resolver runs: no dispatch, no could-not-run record, no alert. The row
   turns off only the verdict. When one of the two pre-queue migration hooks,
   `pq_restamp` (BH-6842) or `pq_mignum` (BH-7671), can act (its no-network
   `*_wanted` check), the main-tip read and both hooks still run first, and a
   push or a refusal from either one still holds the PR. When neither can
   act, no main tip is read.
   With the row at 0, `MC_REQUEUE_PREQUEUE` turns off with it. The batch-eject
   solo rerun and the archie-fm-queue culprit rerun still dispatch the
   workflow, but only after a batch went red. **Rollback is one row:** set the
   value to `1` (write `1`, not `on`; a non-number falls back to the code
   default, which is also 1).
2. **The builder runs the selection gate before the push.** `bin/lib/rb/pr.sh`
   (block `# >>> selection gate (BH-8062)`, after the prepush gate) calls
   `sg_block` in `bin/lib/selection-gate.sh`, which runs `bin/selection-gate.sh`:
   `bin/ci-plan.sh` in its batch mode over the merge-base with main (the
   batch's own selection and sizing, no builder cap), then `bin/remote-gate.sh`
   on the test host with every listed suite. Its record is `$BUILD/gate.txt`
   (`head:`, `base:`, `suites:`, `rc:`, `red:`, `noted:`, `mode:`, `why:`,
   `quarantine:`).
   - `SELECTION_GATE=0` (in a checkout that has the gate): the gate does not
     run. `sg_off_gate` writes a `gate.txt` with `rc: off`, and the PR body
     carries `<!-- selection-gate: head=<40-hex> suites=0 rc=off -->`, which the
     lead review accepts. A fix round at knob 0 writes the same record for the
     pushed head. No alert.
   - red: `RESULT GATE_RED <n> red: <suites>; see <build>/gate.txt`, exit 6.
     Nothing is pushed and no PR opens. A builder with the direct path armed
     on a GitHub-Issues board posts one comment that names the suites and
     marks the RESULT; otherwise the results sweep posts it
     (`prompts/cromford.md`).
   - green, could-not-run, no-selection: the build goes on. The PR body
     carries `<!-- selection-gate: head=<40-hex> suites=<n> rc=<rc> -->`
     (through `PREPR_SECTION`, so the settle stage's re-render keeps it).
     could-not-run and no-selection are never green; the batch stays the
     backstop.
   - A suite on the active flaky quarantine (`metric_flake_quarantine_list`,
     the rows `bin/flaky-tier.sh` projects into `CI_QUARANTINE`) that goes red
     is moved to `noted:`. An unreadable quarantine counts every red.
   - Knobs (lane fly-pool): `SELECTION_GATE` (1), `SELECTION_GATE_TIMEOUT_S`
     (2400), `SELECTION_GATE_P` (12), `SELECTION_GATE_FIX_ROUNDS` (0),
     `SELECTION_GATE_CNR_ALERT` (1), `SELECTION_GATE_CNR_KEEP_DAYS` (14).
3. **The lead review reads the record** (`bin/lib/lead-review/gate-record.sh`,
   knob `LEAD_REVIEW_GATE_RECORD` on lane lead-review: `block|note|off`, code
   default `block`, no seed row). For a `ticket/*` branch, a missing record or
   one that names another head is a deterministic `[BLOCK core-flow-broken]`
   with no model call. Other branches (`hotfix/*`, `fix/*`) get a `[NOTE]`.
   - **Where it applies.** Only when the PR's merge base with its base branch
     has `bin/selection-gate.sh` in its tree. Another project's repo has no
     gate, and a PR built on a main from before this merge had none to run:
     both answer `ok - n/a`, and the review goes on with no note. That is the
     cutover, with no date knob. This PR itself is n/a (only its head adds the
     file). A merge base this box cannot read is a `[NOTE]`, never a BLOCK.
   - **A moved head.** A record for head H is accepted on PR head S when
     `patch_same` (`bin/lib/patch-same.sh`) proves S carries H's patch:
     identical, a clean main merge, or a byte-exact rebase (patch-id). That is
     the rule that rebinds an approval. A code commit on top, or a merge with
     a hand-resolved conflict, is refused.
   - **Fix rounds refresh the record.** `br_fix_round` (bin/blocked-resolver.sh)
     pushes fix commits straight to the PR branch. Its verify step now runs
     the gate (`br_sg_verify`, fragment
     `bin/blocked-resolver.d/bh-8062-selection-gate.sh`): a red gate refuses
     the push like a red unit run (`SELECTION_GATE_EXIT: 1`). After a push
     that landed, `br_sg_after_push` rewrites the body's record for the pushed
     head (`sg_marker_replace`), when that gate.txt names the head and is not
     red. A failed refresh leaves the old record, so the review refuses that
     head, which is the right answer for a head with no record.
   - **Known gap.** A lead BLOCK whose only finding is a missing record on a
     head a person pushed by hand: the fix round changes nothing, its noop
     gate sends the PR to rebuild-fresh, and the rebuild runs the gate. That
     costs one rebuild for a rare case.
4. **A weekly red-batch rate line.** `bin/ci-batch-red-report.sh` writes
   `ci-batch-red-week: repo=<r> week=<YYYY-Www> red=<n> green=<n>
   red_rate=<pct|-> target=<CI_BATCH_RED_TARGET_PCT> met=<yes|no|no-data>`
   once per ISO week, for the last complete week, to
   `logs/ci-batch-red-week.log` (not the tick log, which keeps one line a
   tick). The target knob defaults to 15. Week markers live in
   `state/ci-batch-red/week-<YYYY-Www>` and are pruned after
   `CI_BATCH_RED_WEEK_KEEP_DAYS` (90).

## Operator steps

Turn off the CI pre-queue gate only after the pool gate shows green:

1. Give the pool builder image a test-host route (`flyctl` plus a test-host
   cert through `bin/issue-testhost-cert.sh`, see `docs/REMOTE-GATE.md`,
   "Issuing a cert by hand"). This is its own ticket.
2. Confirm 24 h of `gate.txt` with `rc: 0` on real pool builds.
3. Confirm no `SELECTION GATE COULD NOT RUN` alert in that window.
4. List the per-project rows:
   `SELECT key,value FROM settings WHERE key LIKE 'lane.merge-conductor.%mc_prequeue_gate'`.
   Set each `lane.merge-conductor.<project>.mc_prequeue_gate` row to `0`, or
   delete it. `pq_knob` reads the per-project row before the global row, so a
   per-project `1` keeps the dispatch on for that project.
5. Set the global row `lane.merge-conductor.mc_prequeue_gate` to `0`.

Rollback: set the global row to `1`.

Per-project rows, what was found: as of 2026-10-25 06:16Z, the settings cache
on pool machine `pool-cromford-080ee50ec01918` (672 rows, `fetched_at`
1792908987) holds no `lane.merge-conductor.mc_prequeue_gate` row and no
`lane.merge-conductor.<project>.mc_prequeue_gate` row.

## Rollout window

A pool box whose harness checkout predates the merge writes no marker. The
merge base of a PR built after the merge carries `bin/selection-gate.sh`, so
`lr_gate_record` refuses that PR (`refuse missing`) until the box runs
harness-sync and the ticket rebuilds once. The resolver's rebuild rung clears
it; no person is needed.

## What to expect after the merge

- With the row at its fallback 1, the CI pre-queue gate still runs, and the
  report's `gate_missed` (`bin/ci-batch-red-report.sh`,
  `bin/mc-ready-latency.sh`) keeps working. After step 5 there are no
  prequeue-gate runs, so `gate_missed` turns `?` and `case` turns `C`. That
  is expected.
- A pool builder has no `flyctl` and no test-host key yet, so its gate records
  `rc=could-not-run why=runner-rc-125` until operator step 1, and the PR opens.
  That record is a record: the lead review does not refuse it, and the batch
  and the CI pre-queue gate are the checks. The gap is loud: `sg_cnr_alert`
  writes one ALERTS line per box per UTC day,
  `SELECTION GATE COULD NOT RUN on <host>: <why>. …` (knob
  `SELECTION_GATE_CNR_ALERT`, default 1; day markers
  `state/selection-gate/cnr-<yyyymmdd>`, pruned after
  `SELECTION_GATE_CNR_KEEP_DAYS`, default 14).
- `SELECTION_GATE=0` writes an rc=off record; the lead review accepts it.
- Rollback rows: `lane.merge-conductor.mc_prequeue_gate = 1` brings the
  dispatch back; `lane.lead-review.lead_review_gate_record = note` (or `off`)
  turns the refusal into a note.
- Delete `.github/workflows/prequeue-gate.yml` one week after the global row
  is set to 0, not on a fixed date. It is kept until then for the one-row
  rollback.

## Tests

`tests/prequeue-gate-row.bh-8062-test.sh`, `tests/selection-gate.bh-8062-test.sh`,
`tests/selection-gate-build.bh-8062-test.sh`,
`tests/lead-review-gate-record.bh-8062-test.sh`,
`tests/br-selection-gate.bh-8062-test.sh`,
`tests/selection-gate-off-record.bh-8062-test.sh`,
`tests/ci-batch-red-week.bh-8062-test.sh`.
