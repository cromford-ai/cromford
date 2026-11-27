# BH-10349: pipeline-health GitHub calls are counted and cut (2026-11-27)

## Problem

- The GitHub App installation (limit 7,100 calls an hour) was empty before each hourly reset. Pools skipped tickets with `hold check unreadable`.
- `bin/pipeline-health.sh` made about 1,200 calls an hour on the hub (state/gh-rest-ledger, hours 05 and 06). `logs/gh-calls/` had no line for it.

## Cause

- `logs/gh-calls/` was written only by the `gh()` function of `bin/lib/gh-limit-logger.sh`. A lane that does not source that file was not counted. `timeout N gh` also skipped the function in every lane.

## Fix

- The PATH shim `bin/gh-ledger/gh` now writes the `logs/gh-calls/` line for each call by name (not `auth`, `config` and the other local commands).
- The `gh()` function runs the binary with `GH_CALLS_COUNTED=1`. The shim does not count those calls again.
- Lanes that are now counted for the first time include `pipeline-health.sh`, `unblock.sh`, `ticket-status-comment.sh`, and every `timeout ... gh` call and bounded gh_rest call.
- Read-through cache hits of the shim are counted as calls, the same as the function counted them. A count is a call, not a charge.

## Cuts in section 13d (leadunqueued)

- `bin/lib/ph-lu-memo.sh` keeps the last status and reviews answer per PR and head in `state/ph-lu-memo/`.
- A stored answer is used only when the wake mirror shows no `checks` wake (status) or `pr` wake (reviews) since the read started, and only inside `PH_LU_MEMO_BACKSTOP_S` (default 1800, 0 = off).
- A verdict post and a review change make a wake, so the next run reads them. No alert is lost or delayed by the cache.
- A `--sections` run reads live. A run with the snapshot off (`PR_SNAPSHOT=0`) reads live and writes nothing under `state/pr-snapshot/`.

## Cut of the visibility probe

- With the snapshot on, pipeline-health now arms `bin/lib/repo-meta.sh` (BH-10218). The `repos/<slug> -q .id` probe answers from the memo until a push or repository wake, or the backstop.
- Limit: a repo removed from the App installation makes no repository wake. The next token mint for that repo fails and the ladder probes again. Until then (at most the token life, about one hour), the lane uses the memo.

## Check after the merge

- On the hub: `grep -c ' pipeline-health.sh ' logs/gh-calls/<hour>.log`, and the ledger rows with caller `pipeline-health.sh` per hour (before: about 1,200).
