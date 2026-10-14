# A lead BLOCK gets a fix round; the same finding twice, or a needs-human finding, holds the ticket (BH-3780)

Doc: MERGE-CONDUCTOR, RUN-BUILD-GRAPH

## Why nothing acted on #3722

`bin/lead-review-land.sh` posts a lead BLOCK as a `REQUEST_CHANGES` review whose
body opens with `<!-- lead-review:<id> -->` (BH-3547). It posts under the hub's
default gh identity, which is the App: `cromford[bot]`, `user.type` Bot,
`author_association` NONE. The only thing that turns a lead review into a fix
round is `br_lead_pick` in `bin/blocked-resolver.sh`, and it dropped every Bot
row and every NONE association. So the review was posted every time and briefed
nothing every time. The 2026-09-29 BH-3479 land-block note says the review "is
the shape `br_lead_pick` briefs a fix round from"; that was true only in its
test fixture, which posted as `operator`/OWNER. This note corrects it.

## What changed

### The picker hears the land lane (`br_lead_pick`)

- A row that is a bot (`user.type` Bot or a `[bot]` login) AND whose body starts
  with `<!-- lead-review:` is the lead lane's review. It is grouped as its own
  reviewer, `<login>#lead-review`, so the App's review-lane APPROVE or DISMISS
  on another review never lifts a standing lead BLOCK.
- It is trusted on `harness_verdict_author_match` (the BH-1668 verdict set), not
  on the association. The builders App or an outsider pasting the marker is
  never a brief. A lifted copy of the function with no trust set skips the row.
- A marker row with a `- [BLOCK needs-human]` line never briefs a round.
- A person's review (including a marker review posted on a PAT as `operator`)
  takes the association path exactly as before. The head rule (same head, or an
  older head followed only by merges) is unchanged.

With the picker able to see it, the existing ladder does the rest: one round per
(PR, head) through `review_fix_heads`, `noop_heads`, the preflight,
`BR_REVIEW_FIX_ROUNDS` (default 2) and then `br_escalate_review`. The pushed head
is re-reviewed by `bin/lead-review-enqueue.sh`; `lrl_dismiss` dismisses the old
marker review on a later lead MERGE. The MERGE → enqueue step is BH-3778.

A side effect, intended (BH-2200, "the lead's word outranks"): a CI or rebuild
round on a head with a standing lead marker review now has those findings lead
its brief through `br_findings`.

### The land lane routes a BLOCK before it posts it (`lrl_block_route`)

Inside `lrl_findings`, after the live-head check and before the POST. The ticket
is the `fleet-conf.sh --projects` entry whose repo is the PR's repo, on an issues
board (`board_prefix` `-`), and the issue number in the PR branch
`ticket/<KEY>-<n>` (`lrl_pr_head` now also reads `.head.ref`).

- **needs-human.** The prompt (`prompts/lead-review.md`) has a new findings form,
  `- [BLOCK needs-human] path:line: …`. A report carrying one places the BH-3443
  hold: `bin/needs-human-hold.sh <p> <n> <fp> "lead review of <repo>#<pr> @<head12>: <action>" lead-review`.
  With no ticket to hold (a product board, a branch that names none), ONE warn
  `bin/alert-line.sh --id lead-nh-<id>` says no round will run and a person must
  read the PR. Flag: `state/lead-review-land/nh-<id>`. The tripwire is skipped.
- **The same-finding tripwire.** Otherwise the sorted `- [BLOCK]` lines go
  through `nh_fingerprint` (digits and shas dropped, so moved line numbers keep
  the print; `[NOTE]` lines are not in it) and `nh_trip_note` counts the head in
  the `review_block_fp` ledger, id `lead:<repo>#<pr>@<head>`, so a rerun of the
  same head never counts twice. At `lib.needs-human.needs_human_trip_count`
  (default 2) the placer runs with
  `pause-and-diagnose: the same lead finding blocked <N> heads of <repo>#<pr>: <first BLOCK line>`.
  Its step-8 ask is the one Telegram line, carrying the finding; the lane sends
  no second one. Flag: `state/lead-review-land/trip-<id>`.

Order: verdict row, then the hold, then the review, then the flag, then the
stamp. With the hold on the issue first, `br_rung_hold_gate` stops the round on
every tick that can see the review.

Failure handling:
- placer rc 75 (thread unreadable): nothing posted, nothing stamped, the next
  tick retries. rc 1 (could not place; the placer already alerted): the review is
  posted, and the picker still refuses a needs-human review.
- an unreadable ledger is not counted and never trips; the review is posted.
- no `[BLOCK]` lines (the `Full report: <ref>` fallback): `fp:none`, not counted.
- `bin/lib/needs-human.sh` missing: logged, the review is posted with no route.
- `needs-human-hold-off` on: the placer places nothing and answers 0; rounds
  continue to the existing cap, and a needs-human review still briefs nothing.

### Protected-path PRs

Nothing new. A BLOCK is never withheld (`bin/lead-verdict.sh` asks `la_decide`
only for MERGE / MERGE-WITH-NOTES), so its findings are posted and now brief a
round. The MERGE after the fix is still withheld (post rc 5) and asks for the
human verdict through `la_human_needed`.

## Log lines (`logs/lead-review-land.log`)

`needs-human hold placed on <p>#<n>`, `needs-human finding, no hold possible`,
`needs-human lib missing; findings posted with no hold route`,
`tripwire fp <fp> count <n>/<at> on <p>#<n>, no trip`, `tripwire TRIPPED`,
`fp:none; tripwire not counted`, `tripwire ledger unreadable; not counted, not tripped`,
`tripwire not counted (<why>)`. In `logs/blocked-resolver.log`:
`[reviews/review-changes-requested] -> fix-round` for a lead-blocked PR.

## What usually lies

- The fingerprint is over the BLOCK lines' words. A model that rewords the same
  finding on the next head under-trips; the fix-round cap and escalation still
  bound it.
- The lead-review and build-review tripwires share the `review_block_fp` key
  space and the threshold knob. The same words from both on one ticket count
  together.

Tests: `tests/lead-block-fix-round.bh-3780-test.sh`.
