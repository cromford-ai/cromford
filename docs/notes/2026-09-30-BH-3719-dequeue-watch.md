# The dequeue-watch lane is on (BH-3719, built in BH-3730)

Doc: MERGIFY, MERGE-CONDUCTOR

## What changed

`bin/dequeue-watch.sh` was a stub. It is now the real hub lane, on the hub
every 5 minutes (`cron/lanes/415-dequeue-watch.cron`, behind
`hub-lease.sh check` like the other hub lanes). Each tick, for every project in
`fleet.conf` whose queue provider is Mergify, it reads the open PRs labelled
`merge-queue` or `dequeued` (minus any Mergify still has `queued` or
`checking`). For each one whose newest Mergify payload says `dequeued` on the
PR's current head, it:

1. records the dequeue event (repo, pr, head, run_id) in the jobs ledger;
2. reads the batch run list, the failed log (`gh run view --log-failed`), the
   failing suite's source, and the batch members' changed files
   (`bin/lib/dequeue-watch/gather.sh`);
3. attributes it (culprit, bystander or unknown) and classifies it;
4. asks the `dequeue.classify` model only when the rules leave it
   `unclassified` and the log has FAIL lines (`DEQUEUE_WATCH_LLM=1`);
5. acts once per (pr, head, class), claim first:

| Class | Action |
|---|---|
| bystander, flake | requeue (`@mergifyio requeue`); a flake also records `metric_flake`. No standing MERGE verdict → a lead-verdict request instead |
| stale-status | lead-verdict request |
| main-red | wait; the requeue goes out once main is green |
| rule-break, scanner-fp, semantic-test, textual-conflict | a fix round, up to `DEQUEUE_WATCH_FIX_ROUNDS`, then a hold |
| unclassified | a needs-human hold and one critical line |

A head that already has a live action row is not gathered again, so a later
tick never adds a second class's action to the same dequeue. An unread GitHub
or ledger answer is never read as "none": an unread list skips the project, an
unread verdict skips the PR, and unread member files leave the attribution
`unknown`, which never requeues.

## Knobs and switches

All are `lane.dequeue-watch.*` settings rows (`catalog/lanes.d/dequeue-watch.json`):
`DEQUEUE_WATCH` (1), `DEQUEUE_WATCH_ACT` (1), `DEQUEUE_WATCH_FIX_ROUNDS` (2),
`DEQUEUE_WATCH_UNOWNED_MIN` (30), `DEQUEUE_WATCH_PR_CAP` (20),
`DEQUEUE_WATCH_LOG_BYTES` (200000), `DEQUEUE_WATCH_FAIL_LINES` (40),
`DEQUEUE_WATCH_HOLD_CLASSES` (""), `DEQUEUE_WATCH_LLM` (1),
`DEQUEUE_WATCH_LLM_USD` (0.05), `DEQUEUE_WATCH_MODEL` (""), plus the lane's
`LLM_*` gate knobs. Off: `flags/dequeue-watch-off`,
`bin/harness-ctl.sh off dequeue-watch`, or `DEQUEUE_WATCH=0`.

## The watchdog overlap

BH-3480's `staledequeue:<p>:<n>` page (pipeline-health) and this lane's
`dqw-unowned:<P>:<pr>:<head12>` can both page once for the same unowned PR.
Retiring the BH-3480 page is a follow-up once this lane has run clean for a
while; until then the double page is expected.

## Observe-day rollout

1. `bin/settings.sh set lane.dequeue-watch.dequeue_watch_act 0` (or
   `DEQUEUE_WATCH_ACT=0` in `env/global.env` on the hub).
2. Let ticks run for a day.
3. `grep -E 'WOULD_| tick ' /root/harness/logs/dequeue-watch.log`.
4. Set it back to 1 only when the WOULD_ lines match what a person would have
   done. Observe rows are taken over by `PUT state` when it flips, so nothing
   needs a new head.
