# Mergify requires a head-bound `lead-verdict` status (BH-3348)

Doc: MERGE-CONDUCTOR, MERGIFY

## Why

#3307 merged at `4f4b3f914`. Its only lead verdict, #176 (MERGE-WITH-NOTES),
was posted on `af9842fb1`, a commit that never reached GitHub. Nothing in
`.mergify.yml` asked for a verdict. So anyone who added `merge-queue` and
posted `@Mergifyio queue` could land a head nobody reviewed.

## What changed

- **The status.** `bin/lib/verdict-status.sh` `vs_publish <owner/repo> <sha>
  <success|failure> <description> [<https url>]` POSTs
  `repos/<slug>/statuses/<sha>` with context `lead-verdict` (override:
  `LEAD_VERDICT_CONTEXT`). rc 0 on a 2xx, rc 1 otherwise with one stderr line,
  and rc 2 on a bad argument. It uses the App token where the box mints one,
  and otherwise the caller's own gh auth.
- **Two publishers.** Both already hold a head-bound verdict:
  - `bin/lead-verdict.sh post`: for lead|human rows only, after the worker has
    recorded the row. MERGE / MERGE-WITH-NOTES publish success, BLOCK publishes
    failure. Box rows never stand, so they never publish.
  - `mc_enqueue_mergify` (`bin/lib/mc/queue.sh`): publishes success on the head
    it is about to enqueue, before the label and the command. Every caller
    (conductor READY, requeue, batch-resolve trains, console Merge button)
    reaches it only after its own head-bound check. A refused publish leaves
    the rc alone, but it is never silent. Every refusal writes vs_publish's
    line to stderr and to `logs/merge-conductor.log`, and
    `mc_status_unpublished_alert` raises one alert per repo per UTC day.
    Mergify witnessing the PR (rc 0) does not mean it will merge a head that
    has no status. If Mergify stays silent, the rc 3 reason starts with
    "the lead-verdict status could not be published on <head> (HTTP n)".
- **The gate.** The new `bin/mergify-template.sh` conf key
  `status_check=<name>` (repeatable) renders `check-success=<name>` into both
  queues' `queue_conditions`, after the queue checks. It never goes into
  `merge_conditions`, because Mergify evaluates those on the batch draft and the
  draft's sha never carries a status posted on the PR head. A `status_check`
  that is also a `check=` / `queue_check=` is refused, and so is a duplicate.
  `config/mergify/repos/cromford.conf` sets `status_check=lead-verdict`.
  project-5's render does not change.
- **The head check.** `bin/lead-verdict.sh post` reads `pulls/<n>` `.head.sha`
  over REST (`GH_ETAG=0`) before it writes anything:
  - exit 3 when the sha is not the head (nothing written)
  - exit 1 when the head cannot be read (rc 44/75)
  - exit 4 when the row is recorded but the status is not published

  There is no bypass flag. It applies to every source.
- **`bin/lead-review-land.sh`** reads the new codes. rc 3 logs "head moved" and
  stamps the request promoted, so a verdict on a dead head is not retried every
  5 minutes forever. rc 4 counts as promoted, logs the status failure, and stamps.
- **Check-run readers skip the status.** tier2-autoenqueue G4
  (`_ae_required_checks`) and the stuck-batch refresh
  (`mc_mergify_required_checks`) look for check RUNS. A commit status never
  appears there, so both drop the `lead-verdict` name. Without that, G4 would
  refuse every cromford row as "absent", and no batch draft would ever
  be refreshed.

## Operating it

- A head with no verdict gets no status, so Mergify does not queue it. A push
  leaves the new head with none.
- A lead BLOCK after the conductor published success on the same head wins on
  GitHub (newest status per context), and the PR is dequeued.
- Expected, not yet observed: a PR already queued when this lands has no status,
  so it stops matching queue_conditions and Mergify drops it. The conductor's
  requeue path (`mc_requeue_mergify`) then asks again, and that ask now
  publishes the status first.
- tier2-autoenqueue can post its `@Mergifyio queue` on a head nothing has
  published on yet. `ae_mark ready` (`bin/merge-conductor.sh`) runs before
  returns that come ahead of `mc_enqueue` (lead-cleared, the MERGE_HELD re-ask
  skip, the merge budget), and the ae ledger then marks that head `enqueued`.
  That delays the PR but opens no hole: Mergify waits on queue_conditions, and
  the conductor's next `mc_enqueue_mergify` on that head publishes the status.
- Probed live on the hub (the BH-1000 rule). Pool boxes hold no hub App key
  and got HTTP 403 "Resource not accessible by integration" writing the status
  as `cromford-builders[bot]`, which is expected. On 2026-09-29 at 16:43Z
  the lead ran r2's `bin/lib/verdict-status.sh` on the hub with the hub App
  token: `LEAD_VERDICT_CONTEXT=lead-verdict-probe vs_publish
  example-org/cromford 2db147170d2b... success ...` gave rc 0, and
  `commits/2db1471.../statuses` showed `lead-verdict-probe=success
  creator=cromford[bot]`. Full block:
  https://github.com/example-org/cromford/issues/3348#issuecomment-5894578662.
  That probe covers this PR only while `bin/lib/verdict-status.sh` stays
  byte-identical to r2's (`git diff origin/ticket/bh-3348-r2 --
  bin/lib/verdict-status.sh` is empty).
- Suites: `tests/lead-verdict-status.bh-3348-test.sh` and
  `tests/mergify-status-check.bh-3348-test.sh`.
