# BH-1470: the resolver answers two parks with git instead of a model call

Doc: resolver-mechanical-rungs, resolver-opt-hooks

## What changed

One new file, `bin/lib/br/opt/mechanical.sh`, the first module of the optional
seam BH-1468 shipped. It defines the two hooks `bin/blocked-resolver.sh` already
calls inside `br_one` under `command -v` guards, plus the classifier they share.
Nothing else is touched: `bin/blocked-resolver.sh`, `bin/batch-resolve.sh` and
every file under `bin/lib/mc/` are unchanged, and no new knob is added — the seam
already declares `BR_OPT_OFF` in `catalog/lanes.d/blocked-resolver.json`.

**`br_opt_carry_rung`** is offered for `reason = head-not-reapproved` only. It
reads the approved sha from `<rec>/reviewed-sha`, falling back to field 5 of the
conductor row so a park whose build record is gone still carries, and the live
head from one `br_pr_field` read. `mrt_carry_ok` (`bin/lib/mc/train.sh`) then
compares the two patches' own added and removed lines, each against its own merge
base, with the repo's declared generated files excluded — those are a function of
the tree and are rebuilt on both sides. Identical means the APPROVE a reviewer
bound to the old sha binds to the new one.

**`br_opt_conflict_rung`** is offered for `reason = conflict-unresolvable` with
`br_ladder_class = rebase-conflict`. `br_conflict_kind` runs
`git merge-tree --write-tree --name-only` and tests every conflicting path
against the repo's generated-files table and `git check-attr merge`. `derived`
goes to `mrt_rebase_pure`, which decides everything in its own worktree and
pushes only on success. `source` writes the sorted path set and a 12-hex sha1 of
it on the record — the declared input the cross-ticket cluster round needs — and
returns non-zero so today's ladder runs.

## Why it is shaped this way

- **The ledger rebind is asked FIRST and its rc is read.** `mrt_carry_verdict`
  calls `job_verdict_rebind` with `|| true`, so a module that only called it
  through there could stamp a record `carry`, transition the conductor row to
  `WAIT_REVIEW` and count a carry over a ledger that never moved. The rc 1 (no
  row, an outage) and rc 2 (a row that makes no reviewed-sha claim to move) arms
  now record nothing at all. `bin/lib/mc/rebase.sh:1097` is the precedent.
- **`unknown` is never `clean`.** Every unread answer — no git on PATH, a
  `merge-tree` rc 2, a path list that will not parse — is its own branch and
  declines. An empty generated-files table allows NOTHING, so a repo that
  declares no table degrades to today's path rather than to "allow all". This
  classifier gates a force push to somebody's PR branch, which is the reason the
  suite carries eight adversarial negatives for it.
- **The push is inside `mrt_rebase_pure` and the record is written after it.**
  There is no path that records `mechanical-regen` without a push, and a rebind
  that did not take after the push is NAMED in the record detail rather than
  quietly read as carried: the push cannot be unsent.
- **Nothing is serialized.** Both hooks release the lane-wide scan lock
  (`br_cron_unlock`, idempotent) before any git work, the fetch goes through
  `mc_git_bounded 180`, `mc_unshallow_once` heals the hub's shallow clone first,
  and `mrt_rebase_pure` works in its own worktree with a
  `--force-with-lease`, so a race with `bin/batch-resolve.sh`'s merge train loses
  the lease and answers rc 1 instead of clobbering.
- **`TMPDIR` points at `$HARNESS/tmp/brmech`** for the rebase worktree. `/tmp` on
  the hub is a tmpfs sized at half of RAM and three worktrees filled it to 99%;
  `br_fix_round` moved off it in 2026-09-16 for the same reason.

## What it does NOT do

The parent ticket's R14 — one agent round that rebases a whole cluster of
tickets onto main — is **not** built here. It crosses the per-key lock, the
contested-hold design and the per-ticket rebuild caps. This slice ships the
classification, the derived-only mechanical path and the cluster key; #1457 does
not close on it.

## How to see it on a box

```
grep 'EVENT carried\|EVENT mechanical\|EVENT conflict-clustered' /root/harness/logs/blocked-resolver.log
tail -1 /root/harness/logs/blocked-resolver.log          # carried= and mechanical=
jq '.attempts[-1], .conflict_cluster, .conflict_cluster_key' \
   /root/harness/state/blocked-resolver/<project>/<cap-key>.json
```

`bin/harness-sync.sh` rsyncs `bin/` recursively, so the module reaches every box
on the next sync and `bin/blocked-resolver.sh` picks it up on the next tick. No
env var, no migration, no cron change.

## Tests

`tests/blocked-resolver-carry.bh-1470-test.sh` and
`tests/blocked-resolver-conflict-class.bh-1470-test.sh`. Both drive the real
`bin/blocked-resolver.sh` against a scratch `$HARNESS` and a REAL bare git
origin, because every claim here is about what `git rebase`, `git merge-tree` and
`git diff` actually do to a patch. They assert on artifacts only: the origin's
own ref and its reflog depth, the recorded `jobs-client.sh` argv, the conductor
row, the record json and the `tick:` line.

The fixtures seed that bare origin with `git -C "$T/origin.git" fetch -q "$S"
main:main` rather than `git -C "$S" push -q origin main`. Same ref write, no push
at all — and it matters because a build lane's act-time iron-law fence refuses any
`git push` whose refspec is `main`, scratch origin or not, so a fixture that seeds
itself by pushing cannot run in the lane that wrote it. Case 1's no-ALERTS
assertion filters `lane fence` lines for the same reason: inside a scratch
`$HARNESS` the fence reports itself inert because the fixture ships no classifier,
and that line is the harness's, not the resolver's.
