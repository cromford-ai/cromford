# The unblock lane is opt-in per project (BH-7727, UNB-5)

Doc: PR_UNBLOCK_AGENT_PLAN

## Why

The PR Unblock Agent (Tackler) starts on cromford only. Every other
project must stay untouched until an operator opts it in. The opt-in is a
settings row per project, so a project moves to shadow or to act without a
deploy, and back to off the same way.

## What changed

`bin/lib/unblock/scope.sh` is a new sourced library. It reads two settings
rows through the lane-gate settings cache (`state/settings-cache.json`, one
GET per 60 s per box):

| Key | Values | Missing |
|---|---|---|
| `unblock.project.<p>.mode` | `off`, `shadow`, `act` | `off` |
| `unblock.standing_approval.<p>` | `1` = approved | not approved |

Functions:

- `unb_scope_mode <p>` prints `off`, `shadow` or `act`.
- `unb_scope_approved <p>` is rc 0 only when the approval row is `1`.
- `unb_scope_decide <p> <needs_approval 0|1>` prints the decision for one
  action: `skip` (off), `would` or `would-escalate` (shadow), `act` or
  `escalate` (act). `*-escalate` means the action needs standing approval and
  the project has none (rule U4).
- `unb_scope_projects` prints `<p><TAB><mode>` for each fleet.conf project
  that is not off, in fleet.conf order, with one settings refresh.
- `unb_scope_lock <p>` takes `locks/unblock-<p>.lock` (fd 9) and
  `locks/unblock.lock` shared (fd 4) through `pl_lane_lock`. One slow project
  does not hold another. It never waits.

## Grammar

The keys are `unblock.project.<p>.mode` and `unblock.standing_approval.<p>`.
`<p>` must match `^[a-z0-9][a-z0-9._-]{0,63}$`. The library never lowercases
it: `Cromford` is a bad name (rc 2).

The mode grammar is the same as `act.sh` `_ub_mode` (UNB-4, gate 3). Remove
every whitespace character, then the value must be exactly `act` or `shadow`.
There is no case fold: `ACT` and `Shadow` are `off`. So the projects this
library lists are the projects `act.sh` will write for, and the suite (S7)
compares the two readers on each row value.

## Fail closed

These all read as `off`: a missing row, an empty value, any other value
(`on`, `1`, `true`, `actt`, `ACT`, `Shadow`), no settings cache, and no
harness root. A stale cache (the worker did
not answer) keeps the last known row, as `conductor_mode` does. Standing
approval is only the value `1` (whitespace removed); `true`, `yes`, `0` and
an empty value are not approved. The library never writes. `act.sh` re-reads
the mode row live before any write, so a 60 s cache lag cannot cause a write.

## Seed rows

`worker/jobs/schema.d/202610210022-bh-7727-unblock-projects.sql` seeds, with
INSERT OR IGNORE and actor `seed`:

- `unblock.project.<p>.mode = off` for the 12 fleet.conf projects other than
  cromford.
- `unblock.standing_approval.project-6-os = 1` (the operator, 2026-10-20, comment
  6294290733 item 4). Its mode stays `off`.

There is no cromford row. UNB-0 seeds cromford `shadow` and its
standing approval. An `off` row applied first would make that INSERT OR IGNORE
a no-op. A project added to fleet.conf later has no row, which is `off`.

## Flip and rollback

1. Set `unblock.project.<p>.mode` to `shadow`. `unb_scope_decide` then
   answers `would` or `would-escalate`.
2. Set it to `act`. `unb_scope_decide` then answers `act` or `escalate`.
   UNB-4 (`act.sh`) owns the `UNBLOCK_ACT` knob
   (`lane.unblock.unblock_act=1`). It AND-gates that knob with its own live
   read of the mode row before any write.
3. To roll back, set the row to `off`.

## For UNB-0

UNB-0 planned a no-op stub at `bin/lib/unblock/scope.sh`. The file now exists
and is complete. UNB-0 must call it and must not overwrite it. UNB-0 seeds the
cromford rows itself; this fragment has no cromford row.

`uo_active_projects` (`override.sh`, UNB-6) keeps its own exact-match read.
This change does not edit it.
