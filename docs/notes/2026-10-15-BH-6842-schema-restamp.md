# The conductor restamps stale schema fragments at queue time (BH-6842)

Doc: MERGE-CONDUCTOR

## Why

The rules pack's `schema-fragment-name` check wants a new stamp-form fragment
`worker/<w>/schema.d/<yyyymmddhhmm>-<key>-<name>.sql` to sort after every stamp
fragment of that worker at the base. A builder takes the stamp at build time.
When another schema PR merges first, the stamp is stale. On 2026-10-15 #6785
(BH-5563) paid two fix rounds and two lead reviews for this alone. Each round
renamed files and changed no SQL.

## What changed

- New lib `bin/lib/schema-restamp.sh`. It is pure git plus `python3 -I`, with no
  model and no network.
  - `sr_plan <git-dir> <main> <head>` lists the renames. Per
    `worker/<w>/schema.d/`: when any PR-added stamp fragment is not later than
    main's newest (equal minute included, as the rules pack uses a strict `>`),
    all PR-added stamp fragments of that dir get consecutive minutes from
    `max(now, newest + 1 minute)`, in their old `LC_ALL=C` order. NNNN
    fragments are never renamed. A new name that exists at main or at the head,
    or that equals another old name, is rc 2.
  - `sr_apply <worktree> <main>` runs `git mv`, rewrites each old basename to
    the new one (fixed strings) in every tracked text file `git grep` finds
    outside `worker/*/schema.d/`, and commits one commit
    `restamp schema fragments (no SQL change)` with one
    `Restamped: <old> -> <new>` body line per rename. A fragment's bytes never
    change. A SQL comment in another fragment that names the old file stays as
    it is.
  - `sr_commit_only` and `restamp_same` prove the shape from the tree diff, not
    from the message (see Carry below).
- New pre-queue hook `bin/lib/mc-prequeue.d/restamp.sh`, `pq_restamp`.
  `pq_gate` (`bin/lib/mc-prequeue.sh`) calls it after it reads the main tip.
  First, with no credential, lock or fetch, it reads the conductor's existing
  clone (`/root/repos/<project>`, else `tmp/conductor/<owner_repo>`). No clone,
  or no stamp fragment at that clone's `origin/main`, is `none`: every repo
  without `worker/*/schema.d` stops there. Otherwise, on the conductor's clone
  (`mc_funnel_repo`) and under the project's git lock, it fetches main and the
  head and asks `sr_plan`. An empty plan is `none` and the gate goes on as
  before. Otherwise it runs `sr_apply` in a temp worktree and pushes through
  `hold_push` (`bin/lib/hold-push.sh`), which re-reads the ticket's HOLD and
  leases on the head. The gate then answers `hold` for this tick. The next
  tick sees the new head.
- `lead_carry` (`bin/lib/lead-carry.sh`): when `patch_same` refuses, it asks
  `restamp_same`. A yes carries the lead MERGE with `how=restamp`.
- `bin/lead-review.sh`: on a red rules pack, a stamp-order line is split off
  with `sr_stamp_split`. Only stamp-order lines: the state is
  `clean except schema stamp order (NOTE, the merge conductor restamps before
  queueing)`, the lines go to the prompt as NOTEs, and the review goes on to
  the model. Stamp-order lines beside other findings: the BLOCK names the other
  findings, and each stamp line is `- [NOTE] stamp order, the merge path
  restamps: …`. The NNNN-taken and malformed-name lines are still BLOCKs.

## Carry

`restamp_same <git-dir> <main> <reviewed> <head>` answers `restamp` when
`<reviewed>` is an ancestor of `<head>` and every commit in
`head ^reviewed ^main` is a clean main merge (`_ps_clean_merge`) or a
restamp-only commit, with at least one restamp. A restamp-only commit has one
parent, and its `git diff-tree -M100%` holds only:

- R100 renames inside one `worker/<w>/schema.d/`, between two stamp names with
  the same `-<key>-<name>.sql` suffix and the same mode;
- M lines outside `schema.d` whose parent blob, with each old basename replaced
  by its new one, is byte-equal to the child blob.

Anything else refuses the carry: an added or deleted file, a fragment byte
change, a rename out of `schema.d`, a suffix change, a mode change, a binary
file, or one more edited line. `patch_same` and its other callers are not
changed.

## Outcomes and state

One conductor log line per decision:

```
<key> SCHEMA_RESTAMP <pushed|held|refused> head=<h12> new=<n12|-> main=<m12> renames=<n> reason=<text>
```

- `pushed`: `hold_push` returned 0 and `ls-remote` shows the new sha.
- `refused` (an `sr_plan` or `sr_apply` refusal, a refused push) and `held` for
  no branch name or `REBASE_ON_POOL`: terminal. The attempts line
  `restampfail <key> <head> <main's newest stamp>` is written, one warn
  `mc_alert` is sent, and the head holds on every later tick with no new line.
  A new head or a newer fragment on main is a new key.
- `held` for a busy git lock, a failed fetch, a failed `mc_funnel_repo` (no
  credential) or a HOLD: not terminal.
  One line a head (attempts line `restampheld <key> <head>`), asked again next
  tick.

## Knob

`MC_SCHEMA_RESTAMP` on the `merge-conductor` lane, default 1. 0 turns the
restamp off: no git read, no hold, the gate proceeds as before.

## Decisions

- Only the conductor's pre-queue step restamps. `bin/rebase-train.sh` handles
  DIRTY PRs, and a stale stamp is not a conflict.
- A restamp that cannot run holds the head. The lead review no longer blocks a
  stale stamp, so the queue must not take one: the composed schema could apply
  a table before a table it reads.
- A failed fetch is transient, not terminal: a network failure must not hold a
  head for good.
- `prompts/lead-review*.md` is not edited. The model gets the instruction in
  the rules-pack section of its prompt.
