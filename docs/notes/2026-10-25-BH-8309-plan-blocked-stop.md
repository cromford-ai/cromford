# The pool stops relaunching a PLAN_BLOCKED key (BH-8309)

Doc: FLY-BUILDER-TRIAL

On 2026-10-25, 12 cromford tickets looped plan -> PLAN_BLOCKED -> queued
again by a board watcher -> plan again. Each one reached the per-key spawn cap
(12 in 24 h). BH-7405, BH-7864 and BH-7865 stopped 20 times each in 2 days.
That was 100 Fly runs in one day, plus a plan session for each run. The reap
said "not requeued", but no spawn gate read the PLAN_BLOCKED record.

## What changed

- New spawn gate `pbs_stop_check <project> <key> <ticket> [job-file]` in
  `bin/lib/plan-blocked-stop.sh`. `pool_spawn_decision` (`bin/fly-pool.sh`,
  block `# >>> plan-blocked stop (BH-8309)`) calls it after
  `pool_gates_applicable` and before `pool_after_gate`, the HOLD gate and the
  spawn cap. A refusal keeps the row queued: no QROW write, no deferral count,
  no spawn-cap count.
- The gate acts only on a GitHub-Issues project (`fleet-conf.sh <p>
  board_prefix` is `-`) with a numeric ticket id, and only when the key's
  newest hub record with a RESULT (`builds/pool-<p>-<key>-*/RESULT`, by mtime)
  starts `PLAN_BLOCKED`. It classifies that record once and caches the class
  in `<record>/plan-blocked.class`.

## The three classes

1. `done <sha>`: plan.md line 1 is a BLOCKED marker followed by `already done
   on main by <sha>`, and GitHub's compare `<sha>...<base>` answers `ahead` or
   `identical`. The gate posts one comment with the plan's sentence, then
   closes the issue with `state_reason=completed`. It writes
   `plan-blocked.closed` only after a re-read says `closed`. The next tick
   passes, and the HOLD gate parks the row (`held closed`). A non-ancestor sha,
   a 404 or an unreadable compare does not close. If a record of the key in
   the window already carries `plan-blocked.closed` (a person reopened the
   ticket), a new `done` record is class `other`: there is never a second
   auto-close.
2. `after <KEY...>`: a line of the blocked excerpt (`pb_excerpt`) has a
   prerequisite phrase ("merged first", "blocked by", "waits for", "on hold
   until ... merges" and similar) and 1 to 5 tokens `#N` or `<PREFIX>-N` (the
   key's own prefix; never the ticket itself, never a child key `N.M`). The
   gate writes one `plan-blocked.after` file (`After: <KEY>` per line). It
   refuses while any named issue is open. When all are closed, or when a
   person commented on the ticket after the RESULT, it writes
   `plan-blocked.released` and the row spawns. An unreadable issue read
   refuses this tick.
3. `other`: every other PLAN_BLOCKED. At `POOL_PLAN_BLOCKED_MAX` records of
   class `other` inside `POOL_PLAN_BLOCKED_WINDOW_S` (and newer than the newest
   `plan-blocked.lifted`), the gate refuses and places one NEEDS_HUMAN hold
   through `bin/needs-human-hold.sh <p> <n> <fp> <action> plan-blocked`
   (marker `plan-blocked.asked`). A RESUME after the ask (`_ee_lift_epoch`)
   writes `plan-blocked.lifted`, and the key may spawn again. A hold that
   cannot be placed is one alert line, and it is retried next tick.

## Marker files (per record, never shared)

`plan-blocked.class`, `.after`, `.closed`, `.close-commented` (written before
the comment POST, so a comment is never sent twice), `.released`, `.asked`,
`.lifted` (epochs), `.alerted` (one alert per record). They follow the
existing `builds/` retention (docs/notes/2026-10-19-BH-7437-builds-retention.md).

## Knobs (catalog/lanes.d/fly-pool.knobs.d)

- `POOL_PLAN_BLOCKED_STOP` (1): 0 turns the gate off.
- `POOL_PLAN_BLOCKED_MAX` (2): the `other` cap; 0 turns the cap off.
- `POOL_PLAN_BLOCKED_WINDOW_S` (86400): the window for the cap and for the
  no-second-close rule.

## Owed fleet measure

One day after the deploy, this must print nothing (no key with more than 2
PLAN_BLOCKED reaps in 24 h):

```
since=$(date -u -d '24 hours ago' '+%Y-%m-%d %H:%M:%S')
awk -v s="$since" 'substr($0,1,19) >= s && match($0, /reaped [A-Z]+-[0-9.]+ from [^ ]+: PLAN_BLOCKED/) { split(substr($0,RSTART,RLENGTH),a," "); n[a[2]]++ } END { for (k in n) if (n[k] > 2) print n[k], k }' /root/harness/logs/fly-pool.log
```

Test: `tests/plan-blocked-stop.bh-8309-test.sh`.
