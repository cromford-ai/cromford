# pipeline-health merge alerts close when their PRs merge, close or get queued (BH-3997)

Doc: ALERTS-GROOMING-SPEC

## What changed

Three pipeline-health alerts used to stay open on the console after every PR
they named had merged:

| family | line | condition key (console akey `alert:<key>`) |
|---|---|---|
| awaiting merge | `<P>: harness PR(s) #a,#b open >12h awaiting merge — … prs=<owner/repo>#a,<owner/repo>#b` | `ph-awaitmerge-<owner>-<repo>` |
| lead-cleared, not queued | `<owner/repo> #N has lead-verdict success … (labels: …); prs=<owner/repo>#N; …` | `ph-leadunqueued-<owner>-<repo>-<N>` |
| APPROVE + CLEAN, not queued | `https://github.com/<owner/repo>/pull/N is APPROVE … not in the merge queue: prs=<owner/repo>#N; …` | `ph-approveunqueued-<owner>-<repo>-<N>` |

- **`prs=` token.** `bin/pipeline-health.sh` writes each line's PRs as
  `prs=<owner/repo>#<n>[,…]`. Dedupe keys, TTLs and the retraction epilogue are
  unchanged.
- **Condition keys.** Three builtin `collapse` rules in `bin/lib/alert-state.sh`
  (documented in `env-templates/alerts.conf.example`). Before, the key was
  `auto-<row_key>`, a hash over the PR list, labels and age, so a shorter list
  or a new label opened a sibling row. Awaiting merge keys per repo, as the
  ticket asked. The two not-in-queue families say one PR per line, so they key
  per PR: keyed per repo, two PRs stuck at once would overwrite one row, and
  the first one queued would close an alert the other still needs.
- **`bin/alerts-merge-resolve.sh`.** Runs on every `bin/alerts-groom.sh` pass,
  before `alerts-supersede.py`. It reads `/api/alerts/open`, picks out the rows
  of the three families by line shape (so legacy rows without `prs=` are
  covered too: the repo comes from `fleet.conf`), and reads each named PR once
  via `gh_rest GET repos/<slug>/pulls/<n>` (ETag-cached, `GH_REST_OPTIONAL`). For
  the not-in-queue rows it also reads the worker's `merge_queue` once.
  - every PR settled → `POST /api/alerts/resolve {ids, reason}` plus
    `alert_state_resolve` on the akey's id. Reasons:
    `condition cleared: all PRs merged`, `… all PRs merged or closed`,
    `… PR enqueued (queued label)`, `… PR enqueued (merge_queue row)`,
    `… PR closed (webhook)`, `… PR enqueued (queued label, webhook)`.
  - some settled → awaiting-merge only: the console line is re-posted to
    `/api/beat` on the same akey with no `alertstate`, listing only the PRs
    still open.
  - a PR that could not be read (404, 403/429, quota reserve, bad JSON) is never
    settled.
  - A queued label or `merge_queue` row settles only the two not-in-queue
    families. A queued PR is still awaiting merge.
  - `--dry` prints the decisions and posts nothing.
- **Event path.** The jobs worker's `wakeOf` now stores `pull_request.labeled`
  when the label is `queued` (every other label is still dropped).
  `bin/lib/wake-class-pr-closed.sh` collects closed PRs and queued PRs and runs
  `alerts-merge-resolve.sh --closed … --queued …` once per drain, with no GitHub
  call. A label is not a closure: it launches nothing else.

## Operating it

- Log: `logs/alerts-groom.log`, prefix `merge-resolve`. Each run ends with
  `merge-resolve <pass|event> done: rows= resolved= rewritten= kept= unknown= gh_reads=`.
- By hand on the hub: `HARNESS=/root/harness /root/harness/bin/alerts-merge-resolve.sh --dry`.
- The event path needs the worker deploy (for `queued`) and the
  `wake-lanes-pr-closed` class flag. Without them the groom pass is the only
  closer.

## Known limits

- The `alerts` table row's `line` is not rewritten on a partial settle (the
  table has no line-only route). It refreshes on the emitter's next re-fire.
- The worker dedupes wakes per (repo, kind, key, minute). A `queued` label and
  a close on the same PR in the same minute store one wake, which is
  pre-existing behaviour for any two pr events. The groom pass still closes it.
- `leadunqueued` keeps its 7-day pipeline-health TTL. A PR queued and dequeued
  inside one 10-minute tick on the same head may not re-page. `staledequeue`
  pages that dequeue on its own key.
