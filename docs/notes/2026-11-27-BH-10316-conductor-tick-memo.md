# BH-10316: the conductor keeps its review list and pulls/<n> reads for one tick

Doc: MERGE-CONDUCTOR, GH-REST

## Why

Hub, 2026-11-27 00:00-00:30Z: 489 PR visits, about 3,800 conductor GitHub calls (7.7 per visit). `GET pulls/{n}/reviews` 1,864 (3.8 per visit), `GET pulls/{n}` 928 (about 2 per visit). Several steps of one visit read the same review list and the same PR object.

## What changed

- New lib `bin/lib/mc/tick-memo.sh`, loaded by the new fragment `bin/merge-conductor.d/bh-10316-tick-memo.sh`. The memo wraps `gh_rest` and `gh`, and a fragment may not define those names, so the code is in the lib. The driver calls `mc_tm_arm` before the fan-out. It makes a temp dir (`${TMPDIR:-/tmp}/mc-tick-memo.XXXXXX`) and the EXIT trap removes it. The dir variable is not exported: every subshell and `$( )` of the tick sees it, and no child process does.
- `mc_tm_reviews` keeps the review list of a PR (all pages) for the tick, keyed by repo, PR and head. `mc_tm_pull` keeps the `pulls/{n}` body, keyed by repo and PR.
- The memo is files, not shell variables, because most reads run inside `$( )`.
- Only an rc 0 read with a parseable body is kept. A failed or rate-limited read is asked again by the next step.
- Callers that read through the memo when it is armed: `bg_read` (review list) and `bg_cr_standing` (list and base) in `bin/lib/block-gate.sh`, `_mc_bci_head_review_body`, `mc_rest_pr_json` (so `mc_pr_view`), `_hpl_pr_get` and `_pdg_rest_get`. In every other lane the memo is not armed and these read as before.
- Each conductor write clears entries. `mc_tm_arm` wraps `gh_rest` and `gh`: a write to a PR clears that PR, another repo path clears that repo, and a write it cannot bind clears all. A push clears the PR (`bin/lib/mc/rebase.sh`). A `pulls/{n}` answer at a new head, or a live head read at a new head (`mc_pr_live_head`, still live), clears the PR.
- A step that decides a merge, an enqueue or an un-park reads live: `mc_tm_forget` runs at the pre-merge state guard (so the guard and the block gate after it read GitHub), before the re-queue CHANGES_REQUESTED check of a dequeued READY row, and before the self-enqueue's block gate (`bin/lib/autoenqueue.sh`).
- A forget that lands while a read is in flight (another worker writes to the PR) keeps that answer out of the memo: each forget bumps a generation counter, and a read stores its answer only when the counter did not move.
- One review entry per head (`reviews.<head>`, one file, written by rename). A list cut at the paged reader's 1000-row stop is unreadable (rc 75), never a whole list.
- `gh` is wrapped only when it is already a function (`bin/lib/gh-limit-logger.sh`), so `gh_rest`'s `GH_REST_TIMEOUT_S` bound holds. A memo hit sets 200/memo and clears the quota globals.
- One line per tick: `TICK-MEMO tick=<id> hits=<n> misses=<n>`.

In the test world (one keyed tick, one READY PR), the visit before the merge went from 2 review-list reads to 1, and from 3 `pulls/{n}` reads to 2 (the list's read, then the live state guard).

## Known limits

- A write by a child process (a detached lane runs a new bash) does not clear the memo of the tick that started it. Such a write is the same as a write by another actor.
- A review or a push by another actor is not seen by the steps of the same tick that only read. The steps that write (merge, enqueue, re-queue) read live.
- The memo dir is under TMPDIR, not under `state/` (`MC_TICK_DIR`), because the build rule for this ticket keeps it out of `state/` and `flags/`. A dir that a SIGKILL leaves is removed by the next `mc_tm_arm` after one day.

## Rollback

`MC_TICK_MEMO=0` (settings row `lane.merge-conductor.mc_tick_memo`).

## Check after deploy

```
grep -c 'TICK-MEMO' /root/harness/logs/merge-conductor.log
awk '$2=="merge-conductor.sh"' /root/harness/logs/gh-calls/$(date -u +%Y%m%d%H).log | sed -E 's#/[0-9]+#/N#g' | awk '{print $4, $5}' | sort | uniq -c | sort -rn | head
```

Target: reviews reads per PR visit from 3.8 to about 1.
