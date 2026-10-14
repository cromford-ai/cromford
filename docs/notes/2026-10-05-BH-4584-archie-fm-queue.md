# Archie, queue doctor: batch culprits, unqueued approvals, stale conductor rows (BH-4584, wave 2 of #4574)

Doc: MERGE-CONDUCTOR, MERGIFY, DB-COORDINATION-SPEC

## What changed

A new hub lane, `archie-fm-queue` (`bin/archie-fm-queue.sh`, playbooks in
`bin/lib/archie-fm-queue/`, registry `catalog/lanes.d/archie-fm-queue.json`,
cron `cron/lanes/726-archie-fm-queue.cron`, `*/10` behind `hub-lease.sh
check`). Each tick reads, per project, the conductor's rows (`pr-state.tsv`),
one open-PR list and at most one closed-PR list, and runs three playbooks in
this order: reconcile, culprit, enqueue. Reconcile goes first so a PR GitHub
merged is never enqueued or verdicted on a stale row.

**queue-reconcile** corrects a conductor row that GitHub disagrees with:

- *merged but logged ejected*: a row that is not MERGED/CLOSED/ABANDONED,
  carries an `ejected <key> <head>` attempts line or a reason that still reads
  `queue-ejected*`, and whose PR GitHub says MERGED. It is settled with
  BH-4562's own sequence (`conductor_settle … CLEAN` with `MERGES=1`, then
  `mc_handoff_release <key> merged`) under the conductor's PR lock. BH-4562
  only reads rows whose reason is still `queue-ejected*`; a row whose reason
  moved on (a resolver rung) was never re-read.
- *a dependency hold whose dependency landed*: a READY row with `depwaithold`
  and no `depwaitrelease` on its head, older than
  `archie.queue.dep_hold_stale_s`. Its dependencies are re-read with the gate's
  own parsers (`_pdg_deps`, `pdg_ticket_deps`, `_pdg_order_of`,
  `_pdg_order_hold`). A dependency that is genuinely open, or unreadable, is no
  action. An Order sibling whose row is READY/QUEUED while GitHub says its PR
  merged or closed has that row corrected (settled MERGED, or moved to CLOSED),
  and the held PR's next conductor tick passes the gate by itself. An open
  issue whose closing PR merged is reported, never closed: one `requested` row
  and one ALERTS line naming `gh issue close <n>` or dropping the dependency (a
  decomposed parent stays open on purpose after one slice merges).
- *stale WAIT_CI with every check green*: a WAIT_CI row older than
  `archie.queue.wait_ci_stale_s`, GitHub's head equal to the row's, every
  check-run completed success/neutral/skipped, combined status success,
  mergeable `clean`/`unstable`. It gets ONE keyed conductor run per head,
  `MC_ONLY_PR=<key> bin/merge-conductor.sh` under `ARCHIE_FMQ_KICK_TIMEOUT_S`,
  skipped while the conductor holds that PR's lock. There is no backstop
  lock: `bin/merge-conductor-backstop.sh` takes none, so its keyed run and
  this one can start on the same PR at once, and the conductor's PR lock
  inside each run serializes them.

**queue-culprit** finds a failed Mergify batch (a closed, unmerged
`mergify/merge-queue/*` draft with a `failure` run on its head, within
`ARCHIE_FMQ_BATCH_WINDOW_S`), reads its failing suites with
`flaky_run_tests_strict` (only `tests/(mc/)?<x>.sh` paths; job names or test
titles are "suites unknown" and nothing runs), and solo-runs each member merged
alone onto one main with only those suites, on the CI pool, through
the fp-keyed `pq_dispatch` (`prequeue-gate.yml`, `suites=`). Results land in the
conductor's shared pre-queue store under #4550's key (`pq_key … <fp>`, fp = the
sha1 of the sorted suites), so a run either lane paid for is never paid for
twice, and they are read back on later ticks with `pq_read_run`. The main is
pinned per batch: the main of the batch's earliest entry in that store for the
same fp (within `ARCHIE_FMQ_BATCH_WINDOW_S`), and the current tip only when
there is none. So main moving between ticks (Mergify landing the innocents of
its own split) neither orphans a pending run nor pays for it again. Once no
member is pending and at least one is green (#4550's witness rule: a red main
fails every member; a member Mergify already merged passed CI on main and
counts as green), each red member gets `bin/lead-verdict.sh post <slug> <n> <head>
BLOCK --source lead`, which stops every merge lane on that head and fails the
`lead-verdict` queue condition, and only then one PR comment naming the suite,
the main sha, the batch and the solo run. Innocent members are counted and
nothing is written on them.

The playbook switches on with **#4550**, not #4548. #4548's `pq_dispatch`
drops the fp and writes the plain pre-queue gate's key, where the conductor
would read a suite-subset run as the full gate's verdict. So it needs
`pq_dispatch`, `pq_read_run`, `pq_run_title` AND #4550's `bs_batch`
(`bin/lib/mc-prequeue.d/batch-solo.sh`) or `PQ_DISPATCH_FP=1`; until then it
logs one line a tick and does nothing. After each dispatch the fp key must read
`pending`. If it does not, the row closes `failed`, one ALERTS line names the
PR and the plain key to clean up, and nothing else is dispatched that tick.

**queue-enqueue** enqueues, once per head, an open PR on a Mergify repo that
carries a standing head-bound MERGE / MERGE-WITH-NOTES verdict (`vd_standing`,
the precondition every other `mc_enqueue_mergify` caller has) with no
reviewer's CHANGES_REQUESTED standing, green on the checks
`_ae_required_checks` names, `clean`, not labelled or witnessed in the queue,
not in the tier-2 ledger, not main-red frozen, and that the conductor does not
own: no row at all, or a READY row older than `archie.queue.ready_unqueued_s`
with no Mergify ask on the head and no hold the conductor recorded on that head
(its `ready-why` note; only `merges-off` is not a hold). A GitHub APPROVED
review is never the approval: `mc_enqueue_mergify` publishes `lead-verdict`
success, and any login can submit one.

Before enqueueing it asks the conductor READY arm's own gates live, each
failing closed: `to_lane_hold` (a ticket or thread HOLD), `pdg_hold` (the
PR-dependency gate), `to_lane_lead_fence` (a cleared lead PR is never
label-enqueued, BH-1606) and `bg_scan` (a human BLOCK, BH-762). If any of the
four is not loaded on the box, the playbook enqueues nothing. External authors
are included (the conductor enumerates only harness PRs until #4572), on the
same verdict. The lever is `mc_enqueue_mergify`, so its lead-authority gate
still decides; a refusal closes the row failed with its text and is not
retried on that head.

## Ledger, caps, knobs

Every action is an `archie_actions` row claimed before any write, keyed on its
inputs (head, batch, main tip, suites), under four new playbooks:
`queue-reconcile`, `queue-culprit`, `queue-enqueue` and `queue-solo` (the solo
runs, so their CI minutes have their own cap). Action words: `settle_merged`,
`release_dep_hold`, `report_dep_hold`, `kick_ci`, `enqueue`, `solo_run`,
`block_verdict`, each with a `would_` twin for observe mode. A `started` row a
dead tick left behind is closed `failed` with one alert after
`ARCHIE_FMQ_RETRY_S` and never reclaimed. Each tick sweeps today's and
yesterday's `started` rows of the four playbooks for this, so a row whose key
is never claimed again (a moved head, a settled row) is closed too.

Settings rows seeded in `worker/jobs/schema.sql`: `archie.cap.queue-culprit`
10, `archie.cap.queue-enqueue` 20, `archie.cap.queue-reconcile` 30,
`archie.cap.queue-solo` 40, `archie.queue.wait_ci_stale_s` 2700,
`archie.queue.dep_hold_stale_s` 1800, `archie.queue.ready_unqueued_s` 1800. The
mode is wave 1's `archie.manage[.<project>]`. Lane knobs:
`ARCHIE_FMQ_ENABLED`, `ARCHIE_FMQ_RETRY_S`, `ARCHIE_FMQ_PROJECTS_PER_TICK`,
`ARCHIE_FMQ_KICK_TIMEOUT_S`, `ARCHIE_FMQ_SOLO_TIMEOUT_S`,
`ARCHIE_FMQ_BATCH_WINDOW_S`.

A settle or a sibling settle with merges off or paused writes no row and waits
for merges to come back (deferred, never burned on a key). A settle is proven
by reading the conductor row back (`conductor_settle` ignores
`mc_transition`'s rc): a row that did not move closes `failed` with one alert,
never `done`.

## Not changed

`.mergify.yml`, `config/mergify/**`, the conductor, wave 1's lane and library,
`bin/lib/mc-prequeue.sh`, `bin/dequeue-watch.sh`, `bin/lib/autoenqueue.sh`.

## Probes

`tail /root/harness/logs/archie-fm-queue.log`, and
`GET /api/archie/actions?day=<today>&playbook=queue-enqueue` (and the other
three playbooks) on the jobs worker. Suite:
`tests/archie-fm-queue.bh-4584-test.sh`; worker:
`worker/jobs/test/archie-actions.bh-4584.test.js`.
