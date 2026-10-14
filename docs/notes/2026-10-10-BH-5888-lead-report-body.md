# A lead review report is bound to the PR body it read (BH-5888)

Doc: OPERATING

## What happened

The lead review lane pays for one review per head (BH-2202). A retry replays the stored report:
the job artifact `lead_review_report` first, then `state/lead-reviews/<key>.md`. The replay checked
the head only. A body-only fix (for example, verify evidence added to the PR body) on the same head
replayed the old BLOCK, which was written against the old body. The disk replay for a request with
no start time, the artifact replay and a watchdog retake of the same claim all did this.

## What changed

1. Every report header has the line `- pr body: sha256:<16 hex>`. `lr_body_fp` in
   `bin/lib/lead-reviews.sh` computes it: sha256 over `.body` as GitHub returns it, no whitespace
   normalization. A null body hashes as the empty string. The agent report and the rules-pack BLOCK
   report both carry the line.
2. Before the artifact replay and the disk replay, `lr_report_body_ok` compares that line with the
   live body. Another body means no replay. The artifact path logs
   `artifact lead_review_report for <key> was written against another PR body; reading disk`. The
   disk path logs `report for <key> was written against another PR body; it gets a real review`
   and deletes the report. Then the lane runs a real review, and its prompt carries the new body.
3. The same body replays as before, with no agent call. A report with no `- pr body:` line was
   written before this change and is replayed as before.
4. The key `lr-<pr>-<sha12>` does not change. The `.empty` marker does not carry the body.

The per-PR-day cap (`LEAD_REVIEW_MAX_PER_PR_DAY`) still counts each new call.
No worker, schema or deploy change.
