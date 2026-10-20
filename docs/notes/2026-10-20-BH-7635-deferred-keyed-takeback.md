# A deferred step is a keyed hub tick, not a full one (BH-7635, slice C0)

Doc: MERGE-CONDUCTOR, PROJECT-LANES

## Problem

With `lane_placement.merge-conductor.<project>=fly`, a Fly project run that
left a step to the hub (`deferred=rebase`, `deferred=rereview`, ...) made
`mc_proj_gate` answer rc 2 (`fallback=machine-deferred`). The hub then ran one
FULL tick of the whole project. On 2026-10-19 22:30Z-23:30Z that gave 38
`a hub tick of project-6-os still runs` lines in one hour.

## What changed

1. The machine records the PR of each deferred step. `mc_defer_word <word>
   <key>` (`bin/lib/mc/log.sh`) appends the word to `MC_PR_DEFERRED_FILE` as
   before. When `MC_PR_DEFERRED_KEYS_FILE` is set and `<key>` is
   `owner/repo#n`, it also appends `<word> <key>`. The writers that call it:
   `mc_rereview_spawn` and `mc_rebase_spawn` (`rebase.sh`), `_mc_remote_defer`
   (`spawn-remote.sh`), `conductor_settle` (`settle.sh`, 2 lines) and the land
   arm of `bin/merge-conductor.sh`. The words file keeps its format, so the
   per-PR lane (`bin/merge-conductor-pr.sh`) does not change.
2. `bin/merge-conductor-project.sh` sets `MC_PR_DEFERRED_KEYS_FILE` and adds a
   last field to its PROF line:
   `deferred_prs=<count>:<word>/<n>,...` (sorted, unique), `-` for none, or
   `overflow` past 360 bytes (`MC_PROJ_DEFER_FIELD_MAX`; the worker keeps 512
   bytes of the line). The writer is `mc_proj_defer_field`.
3. The hub gate reads the field with `mc_proj_defer_keys`. When it names a PR
   for every word of `deferred=`, the first take-back of the row answers
   **rc 4** with `MC_PROJ_TAKEBACK_KEYS=<slug>#<n>,...`. `tick_project`
   then runs `mc_proj_takeback_keyed`: ONE keyed tick (`MC_ONLY_PR=<keys>`,
   `MC_PROJ_TAKEBACK=1`) in the foreground, on a full or a keyed tick. It
   takes no full-tick lock, as every keyed tick. The next tick enqueues a new
   row, as before.
4. Each deferred take-back logs ONE route line in `logs/merge-conductor.log`:
   - `<p> project-fly: deferred row <id>: rebase -> hub keyed o/r#14; rereview -> hub keyed o/r#12 — no full hub tick`
   - `<p> project-fly: deferred row <id>: settle -> hub full tick (<why>)`

## When the hub still runs the full tick

- A failed row (`fallback=machine-failed`): no change.
- A deferred row with no usable field: no field (a machine on older code),
  `-`, `overflow`, a count that does not match the list (a cut line), a bad
  token, a step that is not in `deferred=`, or a word with no PR (an unkeyed
  writer such as `dv`, `merge`, `enqueue`). The route line names the reason.
  The step still runs, so this is the safe answer.
- No `fleet.conf` repo for the project on the hub.

The write-back apply rule, the hub mark, `.taken`, the fallback `off` path and
the streak counters do not change.

## Not in this slice (C1)

A deferred `rereview` as a queued pool job (a `kind=rereview` build_queue
row, a pool runner, the result carried back and consumed on the next Fly
tick). After C0 a deferred rereview costs the hub one short keyed tick of one
PR, and `mc_rereview_spawn` on the hub keeps its dedup.

## Check on the hub

`grep 'project-fly: deferred row' logs/merge-conductor.log` shows the route
lines; `-> hub keyed` lines replace `fallback=machine-deferred` full ticks.

Verified by `tests/merge-conductor-project.bh-7635-test.sh`.
