# Lead review claims: heartbeat, reclaim, participants, separation of duties (BH-5351)

Doc: ADD-YOUR-OWN-MACHINE, worker/jobs/README.md

## What changed

- New route `POST /api/lead-reviews/:id/heartbeat {job_id}` (bearer).
  - It stamps `heartbeat_at` on a running row for the job that holds the row.
  - Any other job gets 409, and the error names the status and the holder. An
    unknown id gets 404 `no such lead review request`.
  - It does not write `updated_at`. The list order and the BH-5151 cursor do
    not change.
- `POST /api/lead-reviews/:id/claim` stamps `heartbeat_at`.
  - It also takes a `running` row of another job when
    `COALESCE(heartbeat_at, updated_at)` is older than the stale window.
  - The stale window is the settings row `lead_review_claim_stale_s`. No row,
    or a value that is not a positive integer, gives 900 s. The read is
    `staleWindow` in `participants.js`, now exported and used by both files.
  - A reclaim answers 200 with `reclaimed_from: {job_id, box, participant}`.
  - The old job's `/result` and `/heartbeat` get 409 through the job binding.
  - A reclaim of a running row is not a BH-5400 reset: `reset_count` and
    `reset_at` do not change.
- `POST /api/lead-reviews/start` stamps `heartbeat_at` too. A request with the
  `x-participant-token` header gets 403 `participant claims go through /claim`.
- A claim with the `x-participant-token` header (even blank) is a participant
  claim.
  - The worker calls `participantAuth(req, env, 'lead-review')` (BH-5349). A
    refusal answers its 401 or 403 and `why`, with no row change.
  - Success binds `participant=<name>` and `box=participant:<name>`. The body
    `box` is ignored.
  - A claim without the header is the bearer box claim. It still needs `box`,
    and it writes `participant` NULL.
- Separation of duties runs after auth and before the claim. It compares the
  claimer to the row's `head_authors` only. The worker reads no fix-round
  table.
  - A participant matches as `<name>` or `participant:<name>`. Both sides are
    trimmed and lowercased.
  - A participant named in `head_authors` gets 409 `self-review refused`.
  - A participant on a row with no readable `head_authors` gets 409
    `authorship unknown`.
  - A box claim is checked only when the settings row `lead_review_sod_boxes`
    is `1`. No row means off. A box on a row with no `head_authors` claims as
    before.
- Each participant or SoD refusal tries to write one `stage_events` row:
  stage `lead-review`, verdict `participant_refused` or `sod_refused`, the
  claimer's job_id, and a JSON detail. The answer carries `event_logged`
  (`event_error` when false). It is never a 200.
- `POST /api/lead-reviews` takes `head_authors`: an array of 1..16 strings,
  each 1..128 chars, stored lowercased and de-duplicated. Anything else is a
  400. A replay fills a row that has none, and never overwrites a value.
- `bin/lead-review-enqueue.sh` sends `head_authors` (`head_authors_json`).
  - The build identity: `GET /api/verdict?pr=`, `.job.box` and
    `.job.participant`.
  - The fix-round identities: `box` and `claimed_by` from
    `GET /api/fix-rounds?project=<p>&cap_key=<p>-<KEY>&limit=500` and
    `GET /api/fix-rounds?project=<p>&limit=500`. KEY comes from the
    `ticket/<key>` head ref. The rows kept are those whose `cap_key` names KEY
    (BH-12 never matches BH-123), whose `cap_key` starts `dqw-<pr>-`, or whose
    `args[3]` is the PR url. The fix-rounds route is not changed.
  - A failed or truncated read is one log line, and the rest is still sent.
    With no identity at all, the request goes without `head_authors`, so a
    participant cannot claim it.
- `bin/lib/lead-reviews.sh`: `lr_heartbeat`, `lr_beat_start` (stop it with
  `job_beat_stop`), `lr_whoami` and `lr_report_title`. When
  `HARNESS_PARTICIPANT_TOKEN_FILE` is readable and not empty, `lr_post` and
  `lr_whoami` send the bearer and `x-participant-token` from a 0600 header
  file. The token is never on argv.
- `bin/lead-review.sh`:
  - Every claimed review beats every `stale_s/3` s, with a floor of
    `LR_BEAT_MIN_S` (default 10). `cleanup` stops the beat.
  - Participant mode starts the tick with whoami. A failure is one log line
    and no claim. The machine takes requests for every fleet.conf project it
    has a clone of.
  - A whoami knob `LEAD_REVIEW_CONCURRENCY`, `LEAD_REVIEW_MAX_PER_TICK` or
    `LEAD_REVIEW_DEADLINE_S` with a positive integer value replaces the lane
    value. Any other value is skipped.
  - A participant report has `Reviewer: <name> (enrolled machine)` on line 1
    and the `# Lead review ...` title on line 2. A box report does not change.
  - The readers that match the title line now use `lr_report_title`, which
    skips that one line: the two replay guards and the delta-prior check in
    `bin/lead-review.sh`, and the findings post in `bin/lead-review-land.sh`.
    Without it, a retried participant review would pay for a second model
    call, and land would not post its findings.

## Why

BH-5348: an approved machine takes part in lead review like any lane. A claim
that outlives its holder must come back. A machine must not review a head that
it built or fix-rounded.

## Knobs

- settings `lead_review_claim_stale_s` (seeded 900 by BH-5349).
- settings `lead_review_sod_boxes`: `1` turns on box separation of duties. It
  is off when the row is absent. The lane runs on the box that also builds the
  project, so an always-on box check would refuse every local build.
- env `LR_BEAT_MIN_S` (optional) and `HARNESS_PARTICIPANT_TOKEN_FILE` (an
  enrolled machine only).

## Rollout

The worker and the lanes land in one merge. Until fleet-propagate updates a
box (5 min at most), its old lane does not beat. A non-owner claimer could
take its row after 900 s in that window. Spillover is off by default and no
participant is enrolled yet, so no claimer exists in practice.

The `schema.sql` comments on `heartbeat_at`, `participant`, `head_authors` and
the `lead_review_claim_stale_s` row still say "no reader yet". This change is
that reader. The comments are not edited here, because `schema.sql` is a shared
file.
