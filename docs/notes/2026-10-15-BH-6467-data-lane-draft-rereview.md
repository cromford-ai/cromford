# A data-lane-only review BLOCK keeps its branch as a draft PR (BH-6467)

Doc: OPERATING, MERGE-CONDUCTOR

## What was wrong

TK-165, TK-166 and TK-52 (project-6-os) ended `REVIEW_BLOCKED`. The only
BLOCK was `DATA_LANE: prisma/sql/<file>.sql`: a migration not yet applied in
prod. `LENS_REFUSE` opened no PR. The ticket then had no owner, so
`bin/orphan-reconcile.sh` launched a fresh full build after its grace, and
`bin/blocked-resolver.sh` offered the record as `rescue-giving-up`, which
rebuilds.

## What changed

1. Block time (`bin/lib/rb/review.sh`, `LENS_REFUSE`). When the review round
   blocks only on one `DATA_LANE:` path, and every other lens approved,
   `dlp_block_draft` (`bin/lib/data-lane-pending.sh`) opens the PR as a draft
   and adds the label `data-lane-pending`. An open PR on the branch is adopted
   as it is. The build writes `<build>/data-lane-pending` (`url=`, `file=`,
   `head=`). `RESULT` and exit 6 do not change. The open draft is the ticket's
   owner (reconcile class (b)).
2. The draft opens only when all of these are true:
   - the board is a GitHub-issues board (fleet.conf board prefix `-`);
   - `RESCUE_HUMAN_STEP` is on (shape D runs);
   - the reviewed head is on origin;
   - the path is not one of BH-4926's own paths (`scripts/migrations/*.sql`,
     `scripts/migrate-*.ts`). Those keep `bin/data-lane-apply.sh`.
   Any other BLOCK, or a `NEEDS_HUMAN:` step beside it, keeps today's
   `REVIEW_BLOCKED`.
3. Release (`bin/review-rescue.sh`, shape D). After a person's
   `HUMAN-STEP-DONE:` comment:
   - The comment must name the file (its path or its basename). If it does
     not, the stage row says so and nothing is spent.
   - `dlp_probe` reads `GET <DATA_LANE_APP_BASE>/api/internal/migrations/status`
     with `MIGRATION_TOKEN` from `env/<project>.env`. Confirmed means an
     `applied[]` row with the file's basename and the sha256 of the file at
     the draft's head.
   - Confirmed: the re-review runs on that same head. No build runs.
   - Missing: one comment on the ticket names what the ledger lacks (deduped
     by a hidden `dlp-missing:<fp>` tag). No review, no attempt spent.
   - Unknown (non-2xx, HTML, 401/403): no action this tick. The log line
     is written once per answer, not every tick.
   - Not configured (no base or token): the re-review runs on the person's
     word, as BH-6536 does, and the prompt and stage row say "prod probe not
     configured".
4. After the verdict: on APPROVE, and on a BLOCK posted for the fix round,
   `dlp_finish` runs `gh pr ready` and deletes the label. A failure writes one
   ALERTS line with the command to run.
5. Neighbours:
   - `bin/pr-owner-sweep.sh` reads the label as a park: no hand-back, no close.
   - `bin/blocked-resolver.sh` holds the record (rc 3, no rung) while
     `dlp_pending` is true.
6. Wait alert. A draft that waits longer than `RESCUE_DATA_LANE_WAIT_ALERT_H`
   hours (review-rescue knob, default 24, 0 = off) with no done comment gets
   one ALERTS line (`.dlp-wait-alerted` per record).
7. Probe alert. After HUMAN-STEP-DONE the resolver holds the record and the
   draft keeps reconcile away, so a probe that never confirms pages once
   (`.dlp-probe-alerted` per record). A refused token (401/403) pages at
   once. Any other unknown answer, or a missing row, pages when the done
   comment is older than `RESCUE_DATA_LANE_WAIT_ALERT_H` hours.

## Operator steps

- Set `DATA_LANE_APP_BASE` and `MIGRATION_TOKEN` in the hub's
  `env/<project>.env` for each project that uses this flow. Without them the
  probe answers `not-configured`.
- Post `HUMAN-STEP-DONE: <path>` on the ticket after the apply. Name the file.

## Metric

`bin/data-lane-rereview-report.sh [--last N] [--keys K1,K2]` is read-only.
Part 1 counts the last N data-lane BLOCKs: the re-review path against the
fallback (another BLOCK too). Part 2 prints, per key, build minutes and
dollars from the first data-lane-only block on. Run it on the hub, where the
build records are.

## Not in this change

- The probe reads the migration ledger only. It does not check prod tables
  and functions: no app exposes that read to the hub yet.
- Records blocked before this change get no draft.
- A failed label POST is logged, not retried.
- The probe checksums the file at the marker's head (the head at block
  time). The re-review runs on `origin/<branch>`. A push to the draft after
  the block can make the probe confirm the old file. The merge stays bound
  to the reviewed sha. Follow-up item: probe at the head the re-review uses.
