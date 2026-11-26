# BH-9938: dequeue-watch, pipeline-health and the pr-lead wake class read the PR record

Doc: EVENTS, GH-REST

Wave 6 of 7 of BH-9926 (move lane reads from GitHub onto the PR record), slice
C0. Slice C1 (the next plan of #9938) moves the merge conductor's reads.

## What changed

Each lane reads through `prr_read <lane>` (bin/lib/prr-shadow.sh). The step is
the knob `GH_SOURCE`, settings row `lane.<lane>.gh_source`, default `shadow`:

- `off`: GitHub only, the reads as they were.
- `shadow`: the record and GitHub. The lane acts on GitHub. A difference writes
  one `PRR_SHADOW lane=<lane>` line in `logs/prr-shadow.log`.
- `record`: the record only, 0 GitHub calls on a hit. A miss writes one
  `PRR_MISS ... fallback=github` line and reads GitHub.

The reads moved, each in the lane's seam file `bin/lib/prr-shadow.d/<lane>.sh`:

| Lane | Read | Record side |
|---|---|---|
| dequeue-watch | the `merge-queue` and `dequeued` label lists | `pr_record_label_list` (both lists must hit) |
| dequeue-watch | the newest Mergify payload: state, comment id, draft, run id, left sha, failing checks | `pr_record_mergify` |
| dequeue-watch | a MERGE verdict's `lead-verdict` status of the head | `pr_record_statuses` |
| pipeline-health | the open-PR list (`ph_open_list`, `ph_open_rows`) | `pr_record_list` with a window |
| pipeline-health | 13c stale dequeue: the `merge-queue` list, the payload, the head commit time | `pr_record_label_list`, `pr_record_mergify`, `pr_record_peek` `head_commit` |
| pipeline-health | 13d lead merge unqueued: the head's combined status | `pr_record_statuses` |
| wake-loop (pr-lead class) | `pulls/<n>`: state, draft, head sha | `pr_record_peek`, fresh within `PR_RECORD_MAX_AGE_S` |

Other changes:

- The worker stores `run_id` in `pr_records.mergify_queue`: the payload
  comment's first `/actions/runs/<id>` link, or null. That is the link
  dequeue-watch's own parse takes. A row written before this change has no
  `run_id` key. dequeue-watch keys its event row on the run, so such a row is a
  `field:run_id` miss for a dequeued payload and is read from GitHub.
- `pr_record_mergify` and `pr_record_statuses` also set `PRR_MISS_WHY` to their
  miss word, so a seam can report it. stdout is unchanged.
- The record's `draft` is the worker's integer 0/1. pipeline-health's open
  list and the pr-lead class map it to the REST boolean.
- dequeue-watch `--dispatch` makes ONE `gh_budget_low` call and exports
  `DQW_GH_BUDGET_RC` and `DQW_GH_BUDGET_AT`. A project run takes that answer
  when both are digits, the rc is 0..2 and its age is 0 or more and below
  `GH_BUDGET_RATE_LIMIT_MIN_INTERVAL_S` (the BH-8334 memo knob; 0 = every
  process reads). Else it reads its own, as before. This replaces one
  `rate_limit` call per project process (209 in 1 hour on 2026-11-23). The
  dispatch judges the identity it runs with. A project run re-arms its own App
  token (`pl_token`), so the judgment is the box identity's bucket.
- dequeue-watch and pipeline-health resolve `GH_SOURCE` once after
  `lane_env_apply` when no row exists, so a `prr_read` makes no settings read.

## Reads left on GitHub

These run only for a PR that changed, or they are data the record does not
hold. Wave 7 (#9939) writes the final list in docs/EVENTS.md section 8.

- dequeue-watch: `actions/runs?event=push`, `gh run view --log-failed`,
  `contents/<suite>`, `pulls/<m>/files` of batch members. They run only after
  the already-owned skip, so only for a new dequeue.
- pipeline-health: `issues?labels=ai-build` (an issue list), the HOLD search,
  `actions/runs` (perma-red, deploy-workers), the stale-parent `git fetch` and
  diff reads, and 13d's `pulls/<n>/reviews` (left for slice C1).

## Operator steps

1. Wait 48 hours on `shadow` after the deploy.
2. Count each lane:
   `grep -c 'PRR_SHADOW lane=dequeue-watch' /root/harness/logs/prr-shadow.log`,
   and the same for `pipeline-health` and `wake-loop`, and for `PRR_MISS lane=<lane>`.
3. Post the counts on #9938.
4. If a lane shows 0 `PRR_SHADOW` lines, set its row:
   `PUT /api/settings` key `lane.<lane>.gh_source` value `record`.
5. To go back, set the row to `off` or `shadow`.
