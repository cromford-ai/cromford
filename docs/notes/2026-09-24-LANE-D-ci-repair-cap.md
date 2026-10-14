# A red CI gets two repair rounds per branch, then a decision request

Doc: MERGE-CONDUCTOR

## What was wrong

A CI-red park (`red-ci-twice`, `red-twice`, `queue-ejected-twice`) climbed
`bin/blocked-resolver.sh`'s ladder for as long as it had rungs. The mechanical rung
merged main and pushed, the regenerate rung merged again, and the agent fix round
pushed a fix. After that came REBUILD FRESH, up to `BR_MAX_REBUILDS` (3) times.
Every rung was another push and another CI run on a change CI had already refused
twice, and nothing asked whether a third or fourth round would do better than the
first two. The existing caps (`BR_MAX_MECHANICAL`, `BR_MAX_REGEN`,
`BR_MAX_FIXROUNDS`, `BR_MAX_REBUILDS`) each count one rung kind per TICKET. No cap
counted what a branch had already been put through.

## What changed

`bin/lib/br/opt/cirepair.sh`, a new optional module on the BH-1468 seam, adds the
hook `br_opt_ci_cap_rung`. `br_one` calls it right after the carry and conflict
hooks.

- A **repair round** is a rung whose record line says it pushed a sha in answer
  to a CI-red park: `mechanical` ("… and pushed <sha>"), `regen` ("pushed <sha>
  over …"), or `fix-round` ("pushed <sha> to …"). A rung that pushed nothing the
  lane saw does not count: `mechanical-failed`, a mechanical rung that re-ran CI or
  queued a pool rebase, `regen-noop`, and a fix round with no verified commit.
- A **lineage** is the current PR. The record belongs to the ticket, so the module
  stamps the PR it counts for (`ci_lineage_url`, `ci_lineage_from`). Another PR of
  the same ticket starts at zero, and so does a `rebuild-fresh`.
- When CI is red again and the lineage already holds `BR_CI_REPAIR_ROUNDS` rounds
  (default 2), the park becomes **CI_PARKED** instead of the next round or a
  rebuild. That means one PR comment listing this PR's rounds and asking for a
  narrower re-plan or a decision, outcome `CI_PARKED` scoped to that PR
  (`ci_parked_rkey`), and one untriaged `severity:"warn"` beat, which `bin/beat.sh`
  spools for the deterministic warn digest: no page and no LLM, because a parked PR
  is a decision for later, not an emergency. It must not carry `triaged:true`:
  beat.sh routes only untriaged beats by severity and the console ignores severity,
  so a triaged warn paged at once. It is not an ALERTS.log line, because that file
  feeds the LLM triage spool. On a record with no lineage stamp yet (every record
  at rollout) only attempts whose own `url` is this PR count (`br_record` stores
  the url when the caller passes it; fix rounds do), so a second PR of the ticket
  cannot park early on the first PR's rounds. Nothing is closed
  or rebuilt. The same park on later ticks is a terminal (rc 3): no comment, no
  rung, no `PER_TICK` slot. A comment refused three times is not retried again:
  the park is recorded, and the beat says the PR could not be told.
- `BR_CI_REPAIR_ROUNDS` is a blocked-resolver lane knob (`catalog/lanes.d/blocked-resolver.json`),
  so a settings row changes it without a deploy. `0` is the old ladder, and so is
  `BR_OPT_OFF=cirepair`.

The lane diff in `bin/blocked-resolver.sh` is small (12 added, 3 removed): the
module name in `BR_OPT_MODULES`, the guarded hook call in `br_one`, and `br_record`
storing the PR url on an attempt when the caller passes one (the same change in
`bin/lib/br/record.sh`, which stays byte-identical).

Lead review round (#2222): a park whose outcome write failed is not commented again
(a `ci_park_pending` marker is written before the post, and a tick that finds it
writes the outcome only); raising `BR_CI_REPAIR_ROUNDS` above a parked PR's rounds
lifts the park on the next tick with no comment; and the park beat names the record
file, the `.outcome` edit that re-offers it, and the knob.

Rollout: restart lane (the hub's resolver cron picks the module up on its next
tick). Tests: `tests/blocked-resolver-ci-repair-cap-test.sh` drives the real lane.

## Policy: park, then auto re-plan (the operator, 2026-09-24)

Guardrail 1 says nothing in the harness waits on a human, and a ladder that runs
out records ABANDONED. CI-repair exhaustion is now the one written exception
(`rules/topics/01-iron-guardrails.md`, rendered into `rules/CLAUDE.md`). It still
needs no human:

- The PR is parked OPEN with one comment and one warn digest beat (no page).
- The failing-CI evidence (this PR's rounds and what each pushed) is written to
  `state/build-notes/<project>/<key>.md` with the first line `KIND: ci-replan`.
  `bin/run-build.sh`'s plan stage reads that note as a NARROWER re-plan brief, not
  as an adjudication ruling. `bin/fly-pool.sh` relays it to a pool machine
  (`push_build_note`, consumed on a good push).
- One fresh build of the ticket is enqueued (`br_enqueue_fresh`), once per park.
  An enqueue that fails this tick is retried without a second comment. A
  deterministic refusal (no ticket key, a board miss) parks without a re-plan and
  says so in the beat.
- `BR_CI_REPLAN_MAX` (default 1, blocked-resolver lane) caps the re-plans per
  ticket. The next CI exhaustion after that is ABANDONED (`br_abandon`: close,
  ALERTS line, page), and the earlier parked PR is closed with it. At 0, CI
  exhaustion is ABANDONED at once.

- Once the re-plan's own PR exists (its build record's RESULT names it, whether
  still open or already merged), the parked PR is closed with one "Superseded by
  #NEW (narrower re-plan)" comment. This goes through the rebuild-fresh close
  path: `br_close_pr`, the record's superseded marker, a `superseded` build-row
  beat, and the conductor row moved to CLOSED. The outcome becomes
  `CI_SUPERSEDED`, so it happens once and the ticket never has two live PRs.

Review of #2222 (lead BLOCKER and follow-ups):

- The supersede never closes a human fix. The park stores `ci_parked_head`, and
  before the close the head is re-read. If it moved, or it is not a head a
  recorded repair round of this lane pushed (`pushed <sha>` in the attempts), the
  PR is left open and one line says why, once per head.
- No ticket key means a park without a re-plan. It is not a "retried next tick"
  loop.
- `ci_replans` has a floor: the `KIND: ci-replan` notes the ticket already
  carried (relayed on the hub, or consumed into a build record), so wiping the
  record buys no extra re-plan.
- The CI_PARKED / CI_SUPERSEDED terminal matches the exact PR (`ci_parked_rkey`),
  never an empty or `-` stamp.
- Not done: if the parked PR is merged by a human fix before the re-plan's PR
  exists, the queued re-plan build is not cancelled here. This module only sees
  the parked PR while its row is still parked. The build of an already-merged
  ticket is left to the pool's existing ticket-state checks.
