# sweepstall watches the merge conductor, and a held READY row says why

Doc: MERGE-CONDUCTOR, OPERATOR-SETUP

`bin/merge-sweep.sh` has not run since about 09-23. The sweepstall detector in `bin/pipeline-health.sh` still grepped `logs/merge-sweep.log` and exempted only the conductor state `QUEUED`, so from 09-26 every APPROVE + OPEN + CLEAN PR the conductor was holding on purpose paged "sweep never logged this PR": 816 alerts over 69 PRs.

- The detector reads `state/merge-conductor/pr-state.tsv`. No row: page. `READY`: skipped while the conductor recorded a hold for that head in the last `SWEEPSTALL_HOLD_TICKS` ticks (default 3, a settings row on the `pipeline-health` lane; a tick is `max(MC_TICK_SECS, 300)` s, the cadence read through the registry) or logged a `MERGE_HELD` / PR-dependency-gate line naming the head; otherwise it goes to the Lane D warn digest. `STACKED_WAIT` on the current head, `BLOCKED_HUMAN` and every other state (`QUEUED`, `WAIT_CI`, `HEAD_MOVED` …) are the conductor's, and its own STUCK TTL pages on them.
- The alert quotes the conductor's last `logs/merge-conductor.log` line about the PR (or says it logged none) and, for READY, the stale hold note for that head. `logs/merge-sweep.log` is no longer read.
- The READY arm of `bin/merge-conductor.sh` had three silent `return 0`s: the ticket HOLD (`to_lane_hold`), the merge switch (`MERGES != 1`), and the lead fence (`to_lane_lead_fence` rc 0 or 2). Each now calls `mc_ready_why` (`bin/lib/mc/classify.sh`). It rewrites `state/merge-conductor/ready-why/<key>` (`epoch head kind text`) every tick, and it logs one line per (PR, head, reason): `<key> READY not merged on <head8>: <text>`, deduped against the note it replaces, not the attempts ledger (an attempts row would move `read_memo_fp` and buy a PR re-read). The merges-off return keeps Lane D's own deduped line and writes the note only.
- The `STUCK … READY` page names that reason (`mc_ready_why_last`) instead of "merge flag off, kill switch, budget spent, or gh refused". When nothing was recorded, it says so.

Pinned by `tests/sweepstall-conductor-test.sh`.
