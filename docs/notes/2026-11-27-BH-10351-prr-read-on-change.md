# BH-10351: PR reads only after a PR change (third round of #9926)

In step `record`, five read classes of four lanes now read GitHub only after a change:

- `tsp_ref_states` (`bin/lib/prr-shadow.d/tickets-snapshot-push.sh`) asks `/api/pr-record-refs` in chunks of the worker's `max` after a 400 `too_many`. Before, a repo with more branch-only tickets than `pr_records.ref_read_max` (50) was `unreadable` on every tick, and every branch read `pulls?state=closed&head=`.
- The scheduler's stack-parent lookup keeps GitHub's answer for a branch with no open PR in `state/prr-memo/scheduler-parents.tsv`, with the fingerprint of the record's closed and merged rows of the branch. A changed fingerprint or an open record row is a change; nothing ages out on a clock.
- The conductor writes a whole GitHub open list back to the record (`pr_record_list_sync`) after a list-stamp miss (`stale`, `no-sync`, `unknown`), so the list stays trusted between prr-sweep runs.
- The conductor's flake read: a check entry not yet completed is no flake evidence.
- `wck_sha_prs` (wake-loop, merge-conductor-wake) reads through `prr_read wake-loop`: open record rows at the head, or "none" for a base-branch tip of the PR snapshot.

Count after deploy: `grep -c 'PRR_MISS lane=scheduler' logs/prr-shadow.log` per hour, `awk -F'\t' '$2=="wake-loop.sh" && $5 ~ /commits\/.*\/pulls/ && $6==200' state/gh-rest-ledger/<hour>.tsv | wc -l`, and `grep -a 'pr-record-refs' logs/jobs-client.log | grep -c too_many` (0 expected).
