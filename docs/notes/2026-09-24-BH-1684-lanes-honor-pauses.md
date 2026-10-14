# The lanes honour pauses

Doc: HARNESS-COORDINATION, MERGE-CONDUCTOR

## What changed

BH-1684 (BH-1672.3, order 4 of 5). BH-1681 shipped the pause contract: the
`pauses` table, the box cache `state/pauses.json` and the read-only lib
`bin/lib/pause.sh`. Nothing called it. Now five lanes do, and each one reads
the same two functions, `pause_active <project> <what>` and
`pause_label <project>`, so no two lanes can disagree about whether a pause is
live. A row is live while `ended_at` is null and `expires_at` is in the future,
judged on every read, so a pause stops blocking the moment it expires, with no
refresh and no restart.

| what | lane | what the pause does |
|---|---|---|
| `merges` | `bin/merge-conductor.sh` | `MERGES=0`. A fleet row sets it process-wide, before MODE is derived, and logs `PAUSED(merges) fleet — …` once. A project row sets it inside that project's `tick_project` subshell, before any `pr_worker` forks, so other projects still merge. Every merge and enqueue path reads `MERGES` (the merge arm, the requeue, the tier-2 enqueue, the settle and the stacked merge). |
| `merges` | the merge sweep | one guard after every gate and before `sweep_claim`: `<PR> skipped: PAUSED(merges) … re-offered next tick`. Nothing is recorded or ledgered and nothing goes into the terminal cache, so the next unpaused tick merges it. |
| `reviews` | `bin/review-autopilot.sh` | the project is skipped before the PR list and before any model call, with one `TICK <p> PAUSED(reviews) reason=… age=…` line. |
| `triage` | `bin/run-triage.sh` → `rt_pause_triage` (`bin/lib/rt/gate.sh`) | exits 0 like the `paused-<project>` flag, with one `PAUSED(triage) reason=… age=… — skipping` line, before the job claim and the agent call. |
| `builds` | `bin/run-triage.sh` → `rt_pause_builds` (`bin/lib/rt/gate.sh`) | triage still runs. One `PAUSED(builds) … — triage runs; run-build launches withheld by prompt directive (not enforced at run-build.sh)` line, and a `BUILDS PAUSED` directive appended to the triage prompt (the single session and every shard) telling the agent to launch no `run-build.sh` this tick. |

**The builds pause is a prompt directive, not a deterministic block.** Every
`run-build.sh` launch on this path is made by the triage agent itself, so
there is no launch site in `run-triage.sh` to guard. A queue tick, a Fly pool
launch or a hand launch does not read the pause. A hard stop in
`bin/run-build.sh` (`pause_active "$P" builds` → `BUILD_DEFERRED`) is a
follow-up; until it lands, neither the log line nor the directive claims
more than the prompt does.

Both triage functions live in the gate stage file because the driver is capped
at 380 lines (`tests/rt-split-layout-test.sh`); the driver makes one call each.
`tests/hotfix-seen-test.sh` now counts three `hotfix-seen.sh` calls in the tick
(flag pause, row pause, plain), not two.

## The `PAUSED(merges)` TICK prefix, and how it relates to `automerge-disabled`

`mc_tick_metrics` (`bin/lib/mc/locks.sh`) and the two held TICK lines in
`tick_project` now start with `pause_label <p>`, for example
`PAUSED(merges) TICK demo-os tick=… merges=0 …`. The label lists every live
what for that project, so a reviews pause shows `PAUSED(reviews) TICK …` on a
conductor line too. The JSON in `tick-<p>.json` is unchanged.

A merges pause is not the kill switch. `automerge-disabled` still owns `KILL`,
and a pause never sets it. Under a pause, rebases, re-reviews and every other
action go on; only merges stop. MODE is derived from the lowered `MERGES`, so it
reads `actions`, never `kill-switch`, and the BH-1201 page hold (which holds on
`kill-switch` and `observe` only) is not engaged. BH-1201's word `PAUSED` in
held-page text is that hold; `PAUSED(<what>)` with a parenthesis is this.

## `pause_refresh`, once per lane run

Each lane calls `pause_refresh || true` once per run: the conductor after
`mc_init`, the sweep under its lock, the autopilot before its project loop,
triage in `rt_pause_triage` after its console flag check and the digest in its pauses block. The
cache is per box and triage runs on builder boxes where the conductor never
ticks, so every lane refreshes its own. On this branch `pause_refresh` is still
the contract's no-op stub; the body is sibling BH-1683.

## The digest

`bin/alert-digest.sh` has a `# >>> standing pauses (BH-1672)` block after the
PARKED block. It adds one line per live row,
`PAUSED merges · fleet · 2d 3h · "runaway fix" · by operator · expires in 21h`,
(a `created_at` that does not parse shows `age unknown` in the age slot),
and one per env-shaped pause `pause_env_shapes` prints,
`PAUSED env:review-cap=1 · env (reported only, no row)`. The beat is sent when
a pause is live even if the triage log is empty. No pause and no entries still
sends nothing, and `--warn-batch` is unchanged. The display fields come from
`bin/lib/pause-rows.sh`, which re-confirms each row with `pause_active`.

No cache, a garbage cache, or no lib at all reads as "not paused" in every lane,
which is each lane's behaviour before BH-1672.
