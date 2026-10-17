# Merge origin/main into a PR branch only on a real conflict (BH-7042)

Doc: MERGE-CONDUCTOR, MERGIFY

## What changed

A new check, `pr_needs_main_merge` in `bin/lib/main-merge-need.sh`, answers
"does this PR branch need a merge of main?":

- rc 0, merge: `gate-off`, `conflict-github` (GitHub `mergeable=false` or
  `mergeable_state=dirty`), `conflict-merge-tree` (a local `git merge-tree`
  conflicts), `schema-stamp` (a PR-added `worker/*/schema.d/` stamp is not
  later than main's newest, `sr_plan` in `bin/lib/schema-restamp.sh`).
- rc 1, skip: `queued` (label `queued` or `checking`: the PR is in a Mergify
  batch; this wins over dirty), `clean`.
- rc 2, cannot tell: `unknown`. Every caller merges, as before.

Three lanes ask it before they merge main:

- `bin/review-rescue.sh` (`rescue_one`, a branch with no PR): on skip the PR
  opens on the pushed head, with no merge and no push.
- `bin/lander.sh`: on skip it logs `main merge skipped: …` and exits 1 (not
  resolved). It buys no session.
- `bin/blocked-resolver.sh` mechanical rung, main base only, through
  `bin/lib/br-main-merge.sh` (`br_main_merge_gate`):
  - queued: record `queued-skip`, no counter spent.
  - clean on a `conflict-unresolvable` park: record `conflict-cleared`, no
    counter spent. The rung returns 0, so the dispatch releases the conductor
    hand-off and the conductor judges the PR again.
  - a `rebase-gate-red` park: merge as before. Its merge of main is clean by
    definition (mc_rebase writes it when the clean merge fails the hub gate),
    so a clean tree is not a cleared park. It keeps its path to the fix round.
  - clean on any other park: the existing "nothing to merge, re-run the
    failed CI" arm.

The execute prompt (`bin/lib/rb/execute.sh`) and the fix-round prompt say: do
not merge origin/main into the branch unless it conflicts with main.

Each skip writes one log line, `main merge skipped: clean against main` or
`main merge skipped: in the merge queue (queued label)`.

## Why

A merge of main makes a new head. The new head loses its lead verdict, stops a
running Mac gate as STALE and runs CI again. Mergify already tests every PR on
current main, so a clean merge buys nothing. On 2026-10-16 #6988 lost about 50
minutes this way at 01:17Z, and again at 03:14Z while it was in batch #7040.

## Knob

`MAIN_MERGE_GATE` (default 1; `catalog/lanes.d/blocked-resolver.knobs.d/`).
`0` makes the check answer `gate-off`, so every lane merges main as before.
`bin/review-rescue.sh` and `bin/lander.sh` read the same env from
`env/global.env`.

## Not changed

The fix round's own harness merge of main (`br_fix_round`), the regenerate
rung, and the conductor, train and repair-on-push `mc_rebase` callers.
