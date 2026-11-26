# BH-9938 slice C1: the merge conductor reads the PR record

Doc: EVENTS, GH-REST

Slice C1 of BH-9926 wave 6. Slice C0 (PR #10154) moved dequeue-watch, pipeline-health and the pr-lead wake class.

## The C0 review notes (part A)

- The step does not leak. `prr_step <lane>` trusts `GH_SOURCE` only when `GH_SOURCE_LANE` is empty or is `<lane>`. `prr_pin` exports both. `bin/wake-loop.sh` `launch()` starts a lane with neither.
- A status record with no `lead-verdict` entry for the head is a miss.
- The Mergify payload epoch is the comment's `updated_at` on both sides. The worker stores it in `mergify_queue.updated_at`.
- A record open list needs the default-branch memo (`state/prr-default-branch/<owner>_<repo>`) to say `main`.
- The worker's Mergify parse follows `dqw_parse_payload_md`.
- The pr-lead wake class reads its step once per drain.
- The payload, status and head-commit reads miss with `stale` past `PR_RECORD_MAX_AGE_S`.

## What moved (part B)

- The open-list page under `harness_pr_list` (`prs_open_list`, when the conductor exports `PRS_OPEN_PRR=merge-conductor`).
- The external-PR list (`bin/lib/mc/external-enqueue.sh`).
- The flake read (`mc_ci_flake_runs`): the record serves only "no flake evidence".

A record row needs the cross-repo memo (`<memo>.cross`). A PR that the memo does not know is a miss.

## Reads that stay on GitHub

| Read | Reason |
|---|---|
| Combined status (`mc_vs_success_on`, `mc_vs_state_on`, landing step 7, `settle.sh` rebind) | Each gates a write: the nhv unqueue, the lead-verdict republish, the optimistic-landing merge, the rebind. |
| Mergify payload and head commit time in `sdq_arm`, `queue.sh` commit read | They decide the requeue and the crdequeue unqueue. |
| `pulls/<n>` in `mc_enrolled_rows`, the hold check in `rebase.sh` | The first settles a PR MERGED or CLOSED and needs `mergeable` and the repo full names. The second is the hold gate before a rebase. |
| `mc_pr_live_head` | The readback right before a write. |
| Reviews (`block-gate.sh`, `review-block-park.sh`) | They need review ids, association, user type and body markers. |
| Comment bodies (hotfix proof, autopilot verdict, crdequeue, block marker) | The record never stores comment bodies. |
| The closed list (`train.sh`) | The record's merged list is a window ordered by `created`. |
| Lead-authority files and the head re-read | The protected-paths gate needs `previous_filename` and a live head. |

## The 48-hour count

After deploy, wait 48 hours, then post on #9938:

```
grep -c 'PRR_SHADOW lane=merge-conductor' /root/harness/logs/prr-shadow.log
grep -c 'PRR_MISS lane=merge-conductor' /root/harness/logs/prr-shadow.log
```
