# A human step done on a REVIEW_BLOCKED ticket re-reviews the built branch (BH-6536)

Doc: OPERATING, MERGE-CONDUCTOR

## Why

TK-232 (project-6-os, 2026-10-13) ended `REVIEW_BLOCKED` at 19:08Z. Its only
BLOCK was "migration 0020 not applied in prod". The migration was applied and a
person posted `HUMAN-STEP-DONE:` on #232 at 19:34Z. Nothing happened next:

- `bin/review-rescue.sh` skips every record whose review.md has a verdict,
  except a test-tamper block.
- The release reader (`nh_release_evidence`) looks for evidence only below a
  `NEEDS-HUMAN:` marker. TK-232 had none: project-6-os writes migrations to
  `prisma/sql/`, which `DL_PATH_RE` refuses, and the reviewer wrote no
  `NEEDS_HUMAN:` line.
- Triage answered `buildable=0` in free text, the pool never listed the ticket,
  and the kanban showed it in no column. A person opened PR #289 by hand.

## What changed

### `bin/lib/needs-human/step-done.sh` (new, loaded by `bin/lib/needs-human.sh`)

- `nh_sd_human_only <review.md>`: rc 0 when the last VERDICT is BLOCK, the final
  round names a human step, and every blocking finding line (`DL_BLOCK_RE`) is
  itself a human-step line. A human-step line is a structured `NEEDS_HUMAN:`
  value, any `DATA_LANE:` path (any directory), a `NH_RE_*` shape, or a
  migration "not applied" line (`NH_SD_RE_MIGRATION`). `NH_RE_NEG` cancels a
  line. A code finding next to the human step answers rc 1.
- `nh_sd_done_after <comments-json> <since-iso>`: the newest non-Bot comment
  after the RESULT whose first line starts `HUMAN-STEP-DONE:`, or a
  `## Hub probe … PASS` with no FAIL. No `NEEDS-HUMAN:` marker is needed.
- `nh_sd_pending <record>`: the record waits for the rescue lane's re-review.
- `nh_sd_stage_put` / `nh_sd_stage_lines`: the one reason row per ticket. The
  hub-local copy is `state/ticket-stage/<project>.tsv`
  (`KEY<TAB>column<TAB>state<TAB>iso<TAB>reason`). The ledger row is kind
  `ticket_stage`, key `<project>#<issue>`, status = the kanban column
  (`review`), detail `<state> by <lane> at <iso>: <reason>`. Tokens in the
  reason are masked.

States: `human-step-waiting`, `human-step-done`, `rereview-approve`,
`rereview-block`, `rereview-gave-up`, `handed-to-resolver`.

### `bin/review-rescue.sh` shape D

A REVIEW_BLOCKED record whose review is a human-step-only BLOCK is collected on
its own list. Up to `RESCUE_HUMAN_STEP_PER_TICK` of them are offered per tick,
the one checked longest ago first (`.human-step-checked`). A newer build of the
same ticket on the hub takes the record out of the list.

1. No person's `HUMAN-STEP-DONE:` after the RESULT: stage
   `human-step-waiting`. No attempt, no marker, no model call.
2. The thread cannot be read: one log line. No attempt, no stage write.
3. A done comment: stage `human-step-done`. The shared path finds the PR or the
   branch, merges main, and opens the PR. The PR body has a
   `## Human step evidence` section. The lane appends
   `=== human-step re-review <sha8> …` to review.md and the agent appends its
   round below it, with the person's evidence in the prompt.
4. APPROVE: RESULT becomes `PR_CREATED <url>`, stage `rereview-approve`.
5. BLOCK: the new round is posted on the PR as a COMMENT review with
   `VERDICT: REQUEST_CHANGES` and the footer
   `_Automated harness review (Fable) of <40-hex sha>. …_`. That is the shape
   `br_from_reviews` reads as `review-changes-requested`, which `br_action`
   sends to `fix-round`. RESULT becomes `PR_CREATED <url>`, stage
   `rereview-block`. If the review and the comment fallback both fail, RESULT
   stays `REVIEW_BLOCKED`, one ALERTS line is written, stage
   `handed-to-resolver`, and `bin/blocked-resolver.sh` owns the record.
6. No verdict: the attempt is counted, and the stage reason says so. The
   empty round stays under its header, and `nh_sd_human_only` reads the newest
   round that holds a verdict, so the record is shape D again on the next tick.
   No verdict twice: the existing GIVING UP alert, stage `rereview-gave-up`.
7. No branch, or a conflict with main: the existing paths, stage
   `handed-to-resolver`.

Shape D never enqueues a build. Shapes A, B and C do not change.

### `bin/blocked-resolver.sh`

When a needs-human park is released (`br_needs_human_park` rc 4) and
`nh_sd_pending <record> <project>` says the rescue lane owns the re-review,
the resolver returns rc 3 and says so once per record (`.human-step-said`). It
does not rebuild. A record the rescue lane is done with (`.review-rescued`)
rebuilds as before. So does a record when shape D is off for the project
(`nh_sd_rescue_on`): `RESCUE_HUMAN_STEP` resolves to 0, or the review-rescue
lane is off (`lane-off-review-rescue`, its project form, or `all-off`).

### Triage, the pool list and the kanban

- `bin/lib/triage-state.sh` `ts_precheck`: on a GitHub-issues project, a ticket
  whose cached thread has a `HUMAN-STEP-DONE:` comment is decided
  `skip human-step:<state>` from its `ticket_stage` row, or
  `skip human-step:done-unclaimed` from its REVIEW_BLOCKED build of record.
  The reason reaches `triage_state.last_decision` and one `skip ::` log line.
  Both need the label's newest record to be that REVIEW_BLOCKED record, with
  no `.blocked-resolver-superseded` or `.blocked-resolver-abandoned` marker on
  a local copy. A newer record (a rebuild's result) ends the skip.
  `done-unclaimed` is not used when a local review.md is not a human-step
  BLOCK. With no local review.md, the stage reason says this box cannot read
  the review.
- `bin/fly-pool.sh`: one `pool <p>: <KEY> not queued :: <state>: <reason>` line
  per hub-local stage row with no queue file this tick.
- `console-ui/functions/api/dash/kanban/pipeline.js`: a read-time join of the
  `ticket_stage` rows. A card for the ticket keeps its own `stage` and gets
  `stage_state` (the row's state) and `stage_why`. With no card, a synthetic
  card is added in the row's column, and that column's `counts` entry goes up
  by one, so the ticket is never in no column. `Kanban.js` shows the reason on the card and the list row.

## Knobs (catalog/lanes.d/review-rescue.knobs.d/)

- `RESCUE_HUMAN_STEP` (default 1). 0 is the kill switch: the walk is the A/B/C
  walk again, and `nh_sd_pending` answers "not pending" in the resolver. The
  knob belongs to the review-rescue lane, and lane-gate exports it only into
  that lane, so the resolver reads it with `lane_knob review-rescue
  RESCUE_HUMAN_STEP <project>` (settings row first, then env, then the
  default) in `nh_sd_rescue_on`.
- `RESCUE_HUMAN_STEP_PER_TICK` (default 5).
- `NH_SD_STAGE_MAX_AGE_S` (default 604800): the window of the pool list's
  stage lines.

## Known limits

- A record with no done comment keeps a shape D slot in rotation until the
  resolver's 6-hour `rescue-giving-up` backstop rebuilds it (today's
  behaviour), or until a held needs-human park is released.
- In-app (non-GitHub-issues) boards are out of scope: shape D says so once
  and offers nothing.
