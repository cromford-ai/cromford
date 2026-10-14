# Archie, factory manager: one stuck-PR playbook (BH-4583, wave 1 of #4574)

Doc: MERGE-CONDUCTOR, DB-COORDINATION-SPEC

## What changed

A new hub lane, `archie-fm` (`bin/archie-fm.sh`, playbooks in
`bin/lib/archie-fm.sh`, registry `catalog/lanes.d/archie-fm.json`, cron
`cron/lanes/725-archie-fm.cron`, `*/10` behind `hub-lease.sh check`). Every tick
reads each project's open PRs (one REST list, 100 a page) and the conductor's
row for each (`pr-state.tsv`), classifies them, and runs one playbook per stuck
PR. Wave 1 knows one class:

**stacked-parent-merged**: the PR's base is not the project's base branch, and
the PR whose head is that base has merged. The conductor already restacks the
children of parents it merged itself (`mc_stack_follow`, BH-1670;
`_gpm_owe_restack`, BH-1715). A parent merged by anyone else (the Mergify queue,
the console, a hand merge) left the child on the merged branch carrying the
parent's pre-squash commits, and nothing owed it a restack.

The playbook, in mode `on`:

1. a worktree of `origin/<child>` on the hub clone (else the conductor's scratch
   clone, as `mc_restack`); the head must still be the one the list read;
2. the parent's pre-merge head must be in the child's history and the child
   must have commits of its own, else the row is `done` / `noop` and nothing is
   written (this also covers a child someone restacked by hand);
3. `git rebase --onto origin/<target> <parent pre-merge head>`, where `<target>`
   is the parent's own base (a doubly stacked child goes to its grandparent
   branch, never flattened onto main);
4. the repo's selected suites on the replayed tree, picked the way
   `HARNESS_SUITE_RUN` picks them (npm `typecheck` + `test:unit`, else `test`,
   else `bin/test-impact-gate.sh --base origin/<target> --head HEAD`, else none).
   They are the child PR's own code and unreviewed, so they never run as the
   lane: the GitHub token is disarmed first, and `afm_isolated` runs them in a
   snapshot of the replayed tree (origin/<target> and HEAD as two commits in a
   fresh repo) owned by `nobody`, through `setpriv`, under `env -i` with only
   PATH/HOME/TMPDIR/LANG and `HARNESS_TEST_SANDBOX=1`, the shape of
   `bin/test-impact-gate.sh`'s `isolated_run`. A hub `node_modules` is copied
   in, never linked. A box that cannot switch to `nobody` gets "could not run"
   (deferred), never a root run;
5. green: retarget the PR first (`mc_retarget_base`, REST), then `hold_push`
   with the lease on the listed head. The retarget goes first on purpose, which
   is the opposite of the ticket's sentence: the push is the `synchronize` CI runs
   on, so it must land on a PR that already has its final base (BH-1670's lesson).
   If the push is then refused (lease moved, or a hold), the base is PUT BACK on
   the parent branch and the row is `deferred`: a PR on main is invisible to the
   classifier, so leaving the retarget would strand it with no retry and no
   alert. A base that cannot be put back closes the row `failed` at once, with
   ONE ALERTS line;
6. a conflict or red suites: retarget (best effort), no push, and the
   conductor park `bin/blocked-resolver.sh` drains:
   `conflict-unresolvable: stacked child of parent=#P (...) — rebase --onto <target> conflicts in: <files> (archie-fm)`
   or `rebase-gate-red: stacked child of parent=#P replayed onto <target>, suites red: <names> (archie-fm)`.
   Both are `mc_handoff_owns` hand-offs, so the resolver's own capped ladder
   (mechanical rung, fix round, rebuild) spends the money, once.

In mode `observe` the row closes `would` / `would_restack` with what it would run
(onto, upstream, retarget target). No git write, no fetch, no PATCH, no push, no
conductor write.

Skipped with one log line and no row: a fork head, a HOLD on the ticket, a
conductor stack-follow record for the child (the conductor owns it), the
conductor's PR lock held (`flock -n`, never a wait; the lock is held for the
whole action, so the conductor's worker skips the PR meanwhile), a parent that
could not be read (unreadable is not "not merged").

## Every action is a row

Table `archie_actions` in the jobs DB (`worker/jobs/schema.sql`, BH-4583 block,
applied by `bin/harness-sync.sh` before the worker deploy). Routes in
`worker/jobs/src/routes/archie-actions.js`:

| route | what |
|---|---|
| `POST /api/archie/actions` | claim, idempotent on `dedupe_key`: 201 new, 200 existing (same project/repo/pr/playbook/mode), 409 different |
| `POST /api/archie/actions/outcome` | CAS on `(id, dedupe_key, updated_at, outcome)`; `started` to done/requested/would/deferred/failed, `deferred` to started (attempts+1) or failed |
| `GET /api/archie/actions?day=` | rows newest first + uncapped counts; `&summary=1` counts only (the digest); `&dedupe_key=` one row |

The key is `stacked-parent-merged:<owner/repo>#<n>:<child head>:<parent head>:<mode>`
and the row is claimed BEFORE any git or GitHub write. A second tick on the same
state finds its own row and does nothing; no row, no action (a 404 from the
worker is one log line and nothing done). A `deferred` row older than
`ARCHIE_FM_RETRY_S` is reclaimed; at `ARCHIE_FM_MAX_ATTEMPTS` it closes `failed`
with ONE ALERTS line naming the `git rebase --onto` to run by hand. A `started`
row a dead tick left behind is closed `deferred` once it is stale.

The tick's time: the deadline is start + `ARCHIE_FM_SUITE_TIMEOUT_S` + 600 s.
An on-mode action starts only while a whole suite bound plus 300 s is left
(else the PR waits for the next tick, with no row), and each suite is bounded
by the knob or the time left, whichever is less. The outer `timeout` (4320 s,
above the deadline at the knob's maximum) is only a hang backstop. Its TERM
reaches a trap (`afm_on_term`) that kills the suite runner, removes the
snapshot and the worktree, puts back a retarget whose push did not land, and
closes the row `deferred`.

## Settings and knobs

| what | where | default |
|---|---|---|
| mode, fleet-wide | settings `archie.manage` (seeded) | `on` |
| mode, one project | settings `archie.manage.<project>` (not seeded; absent = inherit) | — |
| day cap, mode on, outcome done or requested | settings `archie.cap.stacked-parent-merged` (seeded; 0 = playbook off) | 20 |
| lane on/off, suite timeout, retry spacing, attempts, projects per tick | registry knobs in `catalog/lanes.d/archie-fm.json` | 1, 900 s, 1800 s, 3, all |

A mode value that is none of `on|observe|off` is one warn line and `observe`:
acting needs an explicit `on` or no row at all. An unreadable settings read
skips the project for the tick. No env var is introduced.

## Daily digest

`bin/daily-digest.sh` step 7c reads `GET /api/archie/actions?day=<D>&summary=1`
and merges it as `.factory_manager` (404 = left out with one note; any other
failure renders `n/a`). `dd_render` prints ONE line when the key is present:
`Factory manager: <n> actions (<r> restacked, <f> fix rounds asked, <w> would-do in observe, <d> deferred, <x> failed) <console>/`,
or `Factory manager: no actions <console>/`. Observe rows count as would-do,
never as restacked. It links the console root until the Factory screen (wave 6)
exists.

## State and known gaps

- Built, not live: the worker needs its deploy (schema first, through
  harness-sync) before the lane does anything; until then every tick logs
  `archie_actions route absent` and acts on nothing.
- Not detected: a child GitHub already retargeted to the project base (repos
  with `delete_branch_on_merge=true`). Its base is main, so it does not look
  stacked. cromford keeps merged branches (`delete_branch_on_merge=false`).
- The wake on conductor STUCK/PARK alerts (#4063) is not on main;
  `bin/archie-fm.sh tick --pr <owner/repo#n>` is the entrypoint it can call.
- The lane writes no state file of its own: the log, the flock, and the rows.
- Default mode is `on` fleet-wide (seeded and the code fallback), so the merge
  turns on force-with-lease pushes to stacked PR branches on every project at
  once. For a staged rollout, set the one settings row `archie.manage=observe`
  before the worker deploy and move projects to `on` one at a time with
  `archie.manage.<project>=on`.
- The day cap and the digest count a row on its CREATION day (`day` is set at
  insert). A row deferred on one UTC day and finished the next counts toward
  the first day. The cap counts `done` rows of mode `on`, which includes the
  `noop` closes, so a no-op spends cap. Both are small. They are left as they
  are for wave 1.
- A child cut from the parent before the parent's final head (the parent head
  is not in its history) closes `done` / `noop` for that head pair with no
  alert, as the conductor's `mc_restack` does.
- A SIGKILL or a box crash between the retarget and the push skips the trap.
  The PR is then left on the target base, still carrying the parent's commits, with the
  row `started`, so the lane cannot see it again. The TERM path (the backstop,
  `kill`) is covered; only a hard kill gets through.

Tests: `tests/archie-fm-tracer.bh-4583-test.sh` (the ticket's
`tests/archie-fm-tracer-test.sh`, keyed to the ticket) and
`worker/jobs/test/archie-actions.bh-4583.test.js`.
