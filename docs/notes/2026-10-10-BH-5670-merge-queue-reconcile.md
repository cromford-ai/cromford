# Merge-queue reconciler lane (BH-5670)

Doc: MERGIFY, MERGE-CONDUCTOR

BH-5670 is child 4 of BH-5008. It fills the reconciler seam of the BH-5667
contract.

What changed:

- `worker/jobs/src/routes/merge-queue-reconcile.js`. Two bearer routes.
  - `GET /api/merge-queue/reconcile` lists the repos with an active row and
    each active PR's current stage. Active means an open
    `merge_queue_batches` row, or a PR whose newest `state='queue'` row is not
    `merged`, `deploy_verified` or `dequeued (…)`. Both are bounded to the last
    24 h. The answer also carries `cap`: the settings row
    `merge_queue_reconcile_repos`, or 10 (`cap_source: "default"`).
  - `POST /api/merge-queue/reconcile` takes `{answers:[{repo, status}]}`, where
    `status` is Mergify's raw `merge-queue/status` JSON for that repo. Only a
    repo that is active at POST time is read; others count `skipped_inactive`.
- `bin/merge-queue-reconcile.sh`, a hub lane every 2 min
  (`catalog/lanes.d/merge-queue-reconcile.json`,
  `cron/lanes/728-merge-queue-reconcile.cron`). No active repo means zero
  Mergify calls. `MERGIFY_API_TOKEN` unset means `not-configured` and zero
  calls. At most `cap` repos are read per tick; the rest are logged by name as
  deferred, and the list rotates every 2-minute tick so they come first later.
  The token goes to curl on stdin, never on argv. No lock: the writes are
  idempotent.
- `env-templates/lanes/382-merge-queue-reconcile.env.example`:
  `MERGIFY_API_TOKEN`. Set it in `env/global.env` on the hub only. It is not
  `MERGIFY_CI_KEY`.

## The mapping

| Mergify | stage written |
|---|---|
| `waiting_pull_requests[i]` | `queued (<i+1>)` |
| batch `status.code` `running`, `bisecting` | `checking` |
| `preparing`, `waiting_for_batch`, `waiting_for_previous_batches`, `waiting_schedule`, `frozen` | `batched` |
| `waiting_for_merge`, `merging` | `merging` |
| `merged` | `merged` |
| any other code, `failed` included | nothing; the code is listed in `unknown_codes` |

A PR in a batch wins over the same PR in the waiting list. A corrective row
is `<stage> (reconcile: was <old stage word, or none>)`, `actor='reconcile'`.
A position row is `queued (<n>)` with `actor='reconcile'`, because the live
view reads the number in the brackets as the waiting position.

## The rules

- Absent is not merged. A PR that is active in the DB and missing from
  Mergify's answer gets no row. Only a batch code `merged` writes `merged`.
- A PR whose newest row is `merged` or `deploy_verified` is never walked back.
- No row when the newest stage already agrees: the same stage word, or for a
  position the same `queued (<n>)`.
- `since` is `reconcile:<id of the row it corrects>`. A repeat run reads the
  new row as newest and skips. Two overlapping runs write the same `since`,
  and the dedupe index keeps one row. The live view's `<word>@<draft>` batch
  reading never matches it.
- ETA: a batch's `estimated_time_of_merge` goes into `eta_at` of the ONE open
  batch row on that repo whose member set equals the batch's PR set. No match
  or more than one = no write, counted `eta_unmatched`.
- All writes of one POST are one `DB.batch`. `written` and `eta_set` come from
  `meta.changes`.
- A Mergify non-2xx, a curl error or a body that is not a JSON object is one
  log line (`<slug> mergify http=<code> rc=<rc>`) and no answer for that repo.

## Assumptions

- The Mergify response shape and the status codes above come from the plan,
  not from a live call. No code in this repo had called the endpoint before.
  An unknown code writes nothing and shows in the lane log as
  `unknown_codes=…`, so a wrong guess fails closed and is visible.
- Pre-queue stages (`wait_lead_review`, `ci_red`, …) count as active.
