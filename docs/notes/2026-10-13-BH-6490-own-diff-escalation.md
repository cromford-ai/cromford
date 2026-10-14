# A stacked merge-queue batch escalates only on its own diff (BH-6490)

Doc: MERGIFY

## Why

A Mergify draft that is stacked on a lower batch carries the lower batch's
diff. `bin/ci-plan.sh` `batch_select` scanned the whole `TI_BASE..HEAD` diff
for escalation. So one PR that touched `.mergify.yml` made every batch above it
run the full corpus. The ticket measured this on 2026-10-13 06:00–15:50Z: 8 of
36 batches ran full, and 3 of the 8 ran full only because of a lower batch
(#6474 own, #6480 and #6481 stacked).

## What changed

- `own_base` in `bin/ci-plan.sh` reads the base of the batch's own diff. On
  the plan job it is the one `checking_base_sha: <40-hex>` line of the draft
  body. That sha is the tip after the PRs queued ahead of the batch; for a
  batch that is not stacked it equals `base.sha`. On a shard it is
  `CI_PLAN_OWN_BASE`, the plan job's new `own_base` output (a shard gets no
  body).
- The escalation scan over `catalog/ci-batch-escalate.tsv` reads the own diff
  (`checking_base_sha..HEAD`). An inherited path never escalates. The lower
  batch ran its own corpus on that path, and if the lower batch fails, Mergify
  requeues this batch on a new draft.
- A `bin/test-impact.sh select` full answer on an inherited path is judged
  again on the own diff. If the own diff selects, the list is that selection
  plus a `--map-only` selection of the whole diff. Selection never shrinks to
  the own diff.
- The reason of a narrowed batch ends with `own diff: <k> of <m> paths, base
  <sha8>; inherited: <p>`.
- An inherited add-only diff of the rules file still turns its spa/worker
  job on.
- Every doubt is today's answer, `own_base=-`: no sha, two shas, a sha that is
  not between `TI_BASE` and `HEAD`, an own diff that is empty or cannot be
  read, `CI_PLAN_CHANGED_FILE` set. When the body had a sha, the run prints
  `ci-plan: own diff: off (<why>)` and a `::notice title=ci-plan own diff::`.
  That note is NOT in a full REASON: `bin/ci-batch-ledger.sh` reads the
  escalation out of a full REASON.

## Replay (acceptance 2)

`bin/ci-plan-own-diff-replay.sh --last 30` reads the last 30 drafts through
`gh api` and prints one row per batch and the summary lines
(`inherited-trigger full: X -> Y`, `narrowed by the own diff: K`, the mean
shard minutes, `full fallback still fires: Z of N`).

A first build box could not reach api.github.com (`gh api` answered
`Forbidden`). The fix round ran the replay live on 2026-10-13 before 17:59Z
(rc 0). The session's GitHub token expired during the run. So the 16 oldest
drafts (#6435-#6464) are `unreadable` rows: each read answered `401 Bad
credentials`. They are a credential failure, not a property of those batches.
The summary counts below cover the 14 readable drafts (#6466-#6503) only. A
complete 30-draft run is still owed in the PR body before merge.

```
draft	base8	own8	old_mode	old_reason	new_class	new_reason	shard_mean_min
6503	bf3f98f1	-	batch-selected	selected: 51 changed path(s); tiers: 1211 suite(s) run (2 guard(s) triggered), 87 left to the nightly run	own	full: unmapped path (bin/lib/ms/MODULES)	-
6500	627fcc02	1eb03184	batch-selected	selected: 16 changed path(s); tiers: 612 suite(s) run (2 guard(s) triggered), 34 left to the nightly run	selected	selected	20.2
6493	1b408a71	0c55bebb	batch-selected	selected: 32 changed path(s); tiers: 890 suite(s) run (3 guard(s) triggered), 65 left to the nightly run	selected	selected	21.4
6492	1b408a71	-	batch-selected	selected: 28 changed path(s); tiers: 869 suite(s) run (2 guard(s) triggered), 65 left to the nightly run	selected	selected	19.7
6489	ddf120d1	5410d1fb	batch-selected	selected: 9 changed path(s); tiers: 716 suite(s) run (1 guard(s) triggered), 42 left to the nightly run	selected	selected	20.4
6488	ddf120d1	7cea818c	batch-selected	selected: 45 changed path(s); tiers: 933 suite(s) run (2 guard(s) triggered), 73 left to the nightly run	selected	selected	21.7
6486	099aee52	896848b2	full	full: selection input: .github/workflows/prequeue-gate.yml; tiers: 2100 suite(s) run (3 guard(s) triggered), 99 left to the nightly run	inherited→selected	selected (old trigger .github/workflows/prequeue-gate.yml is not in the own diff)	35.5
6483	3761187b	d049f8f9	full	full: selection input: .github/workflows/prequeue-gate.yml; tiers: 2096 suite(s) run (3 guard(s) triggered), 99 left to the nightly run	inherited→selected	selected (old trigger .github/workflows/prequeue-gate.yml is not in the own diff)	34.9
6481	3761187b	8c174531	full	full: selection input: .github/workflows/prequeue-gate.yml; tiers: 2094 suite(s) run (3 guard(s) triggered), 99 left to the nightly run	own	selection input: .github/workflows/prequeue-gate.yml	35.3
6480	e8d7829e	0c4c0106	full	full: selection input: .mergify.yml; tiers: 2091 suite(s) run (2 guard(s) triggered), 100 left to the nightly run	inherited→selected	selected (old trigger .mergify.yml is not in the own diff)	34.3
6474	e8d7829e	-	full	full: selection input: .mergify.yml; tiers: 2091 suite(s) run (2 guard(s) triggered), 100 left to the nightly run	own	selection input: .mergify.yml	34.2
6471	e8d7829e	-	batch-selected	selected: 16 changed path(s); tiers: 863 suite(s) run (2 guard(s) triggered), 72 left to the nightly run	selected	selected	17.9
6470	e8d7829e	-	batch-selected	selected: 23 changed path(s); tiers: 868 suite(s) run (2 guard(s) triggered), 72 left to the nightly run	selected	selected	17.8
6466	4cbc1aa8	-	batch-selected	selected: 10 changed path(s); tiers: 398 suite(s) run (1 guard(s) triggered), 23 left to the nightly run	selected	selected	21.2
6464	4cbc1aa8	-	unknown	-	unreadable	the full compare could not be read	-
6457	e58443d0	-	unknown	-	unreadable	the full compare could not be read	-
6454	c7dea1f2	a94db075	unknown	-	unreadable	the full compare could not be read	-
6450	c7dea1f2	-	unknown	-	unreadable	the full compare could not be read	-
6449	c7dea1f2	28b4eb62	unknown	-	unreadable	the full compare could not be read	-
6448	c7dea1f2	2bbe29db	unknown	-	unreadable	the full compare could not be read	-
6447	c7dea1f2	-	unknown	-	unreadable	the full compare could not be read	-
6446	c7dea1f2	c4b9d1b5	unknown	-	unreadable	the full compare could not be read	-
6445	c7dea1f2	-	unknown	-	unreadable	the full compare could not be read	-
6444	d851650e	bf33e5bb	unknown	-	unreadable	the full compare could not be read	-
6443	d851650e	-	unknown	-	unreadable	the full compare could not be read	-
6440	fa0e113e	e37da3b0	unknown	-	unreadable	the full compare could not be read	-
6439	fa0e113e	831b15e4	unknown	-	unreadable	the full compare could not be read	-
6437	fa0e113e	26d293cd	unknown	-	unreadable	the full compare could not be read	-
6436	07826084	8438123f	unknown	-	unreadable	the full compare could not be read	-
6435	07826084	72e21295	unknown	-	unreadable	the full compare could not be read	-
batches read: 30 (unreadable 16)
old full: 5
inherited-trigger full: 3 -> 0
narrowed by the own diff: 3
inherited-only mean shard min (old): 34.9 over 3
batch-selected mean shard min (old, window): 20.0 over 8
full fallback still fires: 3 of 30 (own base -: 2)
selection step: approx: current map (/root/worktrees/cromford-bh-6490/bin/test-impact.sh)
```

What the 14 readable drafts show:

- Old full: 5 (#6474, #6480, #6481, #6483, #6486).
- `inherited-trigger full: 3 -> 0`. #6480 (`.mergify.yml`), #6483 and #6486
  (`.github/workflows/prequeue-gate.yml`) ran full only on an inherited path.
  Under the new rule they are batch-selected. In the ticket's words this is
  "inherited-only full: 3 -> 0".
- #6481 stays full. Its own diff touches
  `.github/workflows/prequeue-gate.yml`, so the new rule escalates on its own
  path (`own`). The plan predicted this. The ticket's three batches therefore
  go to one (#6481), not zero: #6474 is not stacked and stays full on its own
  `.mergify.yml`.
- Mean shard minutes: 34.9 for the 3 narrowed batches (old), 20.0 for the 8
  batch-selected batches in the window. That is about 15 minutes saved per
  shard on each narrowed batch.
- `full fallback still fires: 3 of 30`. Two are real (#6474, #6481). The third,
  #6503, is an artifact of `approx: current map`: its batch adds
  `bin/lib/ms/MODULES`, which is not on main, so this checkout's map has no row
  for it. The real run of #6503 selected (51 paths). So the real count is 2 of
  the 14 readable drafts.

## Re-measure (acceptance 3, owed after merge)

Six hours after the merge, run `bin/ci-plan-own-diff-replay.sh --last 30` (or
read `GET /api/ci-batches`) and post the numbers on BH-6490. On a stacked run,
open the "CI plan (what this run tests)" job: the `::notice title=ci-plan::`
line must say `mode=batch-selected` and `own diff: … base <sha8>; inherited:
<p>`.
