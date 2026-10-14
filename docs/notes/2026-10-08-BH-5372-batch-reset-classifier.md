# The conductor names every Mergify batch reset and whether it was avoidable (BH-5372)

Doc: MERGE-CONDUCTOR

## What changed

- New `bin/lib/mc-batch-reset.sh`, sourced optionally by `bin/merge-conductor.sh`
  next to `mc-stale-dequeue.sh`. On every Mergify-provider tick (not a
  `MC_ONLY_KEYS` tick), right after the stuck-batch pass, the conductor calls
  `bres_tick <slug>`.
- `bres_tick` reads the merge-queue batch drafts (`mergify/merge-queue/*`) that
  closed inside the lookback window. A draft that closed with none of its members
  merged, while another PR's `Merge pull request #N` commit landed on the base
  during the draft's life, is a reset. For each one it writes one line to
  `logs/merge-conductor.log`:

  ```
  <owner/repo> BATCH_RESET draft=<n> cause=<sha12> verdict=<overlap|disjoint|unknown>
  ```

  `cause` is the earliest such merge commit. The verdict compares the impact
  scopes (`qp_impact` / `qp_scopes_json`, the partitioned queue's own map) of
  ALL the merges in the window against the draft's members:
  - `disjoint`: no shared suite. Partitioning would have kept that batch alive.
  - `overlap`: a shared suite, either side on the serial lane (`all_scopes`),
    or both only `_inert`.
  - `unknown`: a file list could not be read, or a side had no scopes. Never
    read it as `disjoint`.
- One line per `(draft, cause)`: the dedupe is the conductor's attempt mark
  `bres <owner/repo>#<draft> <cause12>`, checked before any file read.
- A failed or rate-limited read writes no verdict line and one
  `<owner/repo> BATCH_RESET_UNREAD rc=<n>` line instead; the tick goes on and the
  next tick retries while the draft is still in the window.

## Observe only

No label, comment, queue call or other write. Every GitHub call is a GET. It
runs in every conductor mode for that reason.

## Scope and knobs

- Runs only for a repo whose `config/mergify/repos/<repo>.conf` names the slug
  and carries `queue_mode=` (today: cromford), the same opt-in as
  `qp_enqueue_step`. The impact map is the harness's own tree.
- Settings rows, code default as fallback: `batch_reset.lookback_s` (3600) and
  `batch_reset.max_drafts` (10, oldest first; the rest wait for the next tick).
- Blind spot: a direct push to the base is not a `Merge pull request` commit, so
  it is never named as a cause.
- `bres_drafts <slug>` prints the TSV
  `draft outcome(merged|closed) head_sha created_at closed_at members` that the
  queue-waste ledger (a sibling child of #5356) reads. Its format is a contract.

## Checking it on the hub

```
grep 'BATCH_RESET' /root/harness/logs/merge-conductor.log
```
