# BH-10158: lane `unblock` reads the PR record (BH-9926 wave 5, slice C2 of #9937)

## What changed

The unblock lane (`bin/unblock.sh tick`) now reads its PR facts from the PR record
(`bin/lib/pr-record.sh`) in three steps. The settings row `lane.unblock.gh_source`
(knob `GH_SOURCE`, `catalog/lanes.d/unblock.knobs.d/GH_SOURCE.json`) selects the step.
The tick reads the step ONCE, right after `lane_env_apply unblock`, and exports it.

| Step | Reads | The lane acts on |
|---|---|---|
| `off` | GitHub only (the reads before BH-10158) | GitHub |
| `shadow` (default) | GitHub and the PR record; a difference writes one `PRR_SHADOW` line | GitHub |
| `record` | the PR record; a miss reads GitHub and writes one `PRR_MISS` line; the gated cache below | the record |

A bad row value is `shadow` plus one `PRR_STEP lane=unblock bad=<value>` line per tick.

## The read sites

| Site | File | Read | In step record |
|---|---|---|---|
| S1 | `bin/lib/unblock/ticket-pr.sh` | `pulls/<n>` (ledger PR) | record row (`pr_record_peek`) |
| S2 | `bin/lib/unblock/ticket-pr.sh` | `pulls?state=open&head=<owner>:ticket/<key>` | record open list, exact `head_ref` |
| S3 | `collectors/lifecycle.sh` | `pulls/<pr>` (ejected ticket) | record row; a MERGED PR is a miss (the record holds no merge commit; U14-MERGED needs it) |
| S4, S5 | `collectors/infra.sh` | `pulls?state=open&head=...` (parent, reach) | record open list, exact `head_ref` |
| S6, S14 | `collectors/review.sh`, `queue.sh` | `pulls?state=open&per_page=100` | record open list, newest 100 by `created_at` |
| S7 | `collectors/review.sh` | search `review:changes_requested` | record open list: a login's latest stored review is `CHANGES_REQUESTED` |
| S8, S10, S17 | `review.sh`, `queue.sh` | `pulls/<n>/reviews` | gated cache, kind `reviews` |
| S9 | `review.sh` | `issues/<n>/comments` | gated cache, kind `comments` |
| S11 | `queue.sh` | `pulls?state=closed...` (batch drafts) | gated cache, repo-wide key |
| S12, S13, S15, S20 | `queue.sh` | `pulls/<n>` | record row (need `labels`, `mergeable_state` where read) |
| S16 | `queue.sh` | `commits/<head>/check-runs` | `prr_ci_state` (pending is `running`) |
| S18 | `queue.sh` | `pulls/<n>/files` | `pr_record_files` (step record only) |
| S19 | `queue.sh` | `commits/<head>` | `pr_record_head_commit_time` (step record only) |

These stay on GitHub in every step: the files WITH patches of `_ubq_owners`, the
`batch_failure` MCP tool, the parent issue read (tracker seam), and every read in
`act.sh` and `override.sh` (they re-check live state just before a write).

## The gated cache (step record only)

`ubp_cached` (`bin/lib/unblock/prr.sh`) keeps the last GitHub answer of a read the
record cannot serve in `state/unblock-prr/<owner>_<repo>/<n|repo>-<kind>.json`
(meta `<head>\t<read start epoch>`). It serves the answer only when all hold:

- the head is the same, byte for byte;
- no `pr` wake for that PR (any PR, for the repo-wide closed list) came after the read started;
- the wake feed is complete and fresh;
- the answer is younger than `UNBLOCK_PRR_BACKSTOP_S` (default 1800 s; 0 = always read).

A failed or non-JSON read writes no cache file. A quiet PR still gets its records every
tick (U4 and U13-RESTAMP are time rules), from the cached answer. `ubp_gc` deletes cache
files older than 3 days once per tick (retention).

## The 48-hour count (owed after the deploy)

After 48 hours in `shadow`, count the mismatches on the hub and post the number on #9937:

```bash
grep -c 'PRR_SHADOW lane=unblock' /root/harness/logs/prr-shadow.log
```

Set `lane.unblock.gh_source=record` only when that count is 0. The keys name the site:
`<repo>#open@review`, `<repo>#open@queue`, `<repo>#cr`, `<repo>#<n>@pull:<site>`,
`<repo>#branch:<ref>@<site>`, `<repo>#<n>@ci`.

## Tests

- `tests/unblock-prr-seam.bh-10158-test.sh`: the seam's record and norm functions and the gate's decision table.
- `tests/unblock-record.bh-10158-test.sh`: the production tick with the real collectors, in each step.
