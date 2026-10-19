# Timers on stuck PR states: CI never started, a failed rebase, red twice (BH-7241)

Doc: MERGE-CONDUCTOR

## Why

On 2026-10-17 the last 30 merged project-6 PRs showed that harness PRs took a median 110 min (p90 538 min) from open to merge. Mac-session PRs took 27 min. Most of that time was idle, in states that nothing restarted:

- #930 waited 8.7 h. CI never started on its head.
- #990 sat 2 h after its rebase failed, before it reached a person.
- #991 stayed red for 1.5 h.

the operator cleared all three by hand.

## What changed

1. **CI never started** (`mst_ci_nostart`, `bin/lib/mc-stuck-timers.sh`). `pr_worker` calls it for every open PR, in every state, just before the WAIT_CI catch-all.
   - The clock is a first-seen mark, `cinone <key> <head> <epoch>`. It is written the first tick a head reads `ci=none` (no run at all, not a cancelled-only head). The first tick after a deploy alerts on nothing.
   - At `MC_CI_NOSTART_MIN` minutes (default 15), once per head (`cinostart`), the timer dispatches the head branch's CI with `workflow_dispatch`. It picks a workflow whose file at the head branch declares both `pull_request` and `workflow_dispatch`, `ci.yml` first, at most 5 file reads. A deploy workflow (no `pull_request`) is never dispatched.
   - A dispatch that returns 2xx writes `cikick`, so the close/reopen arms stay quiet on that head. A failed read or POST writes no `cikick`, and the alert says what failed.
   - It sends one alert, `CI_NEVER_STARTED`, and writes `cikickalert`, so `ci_absent_escalate` does not send a second alert on the same head. No alert text asks for an empty commit.
   - It does not act on a DIRTY or CONFLICTING head, an identity-blocked head, a held PR, or a PR that is not on the project base.
   - `MC_STUCK_TIMERS_MAX_PER_TICK` (default 5) caps the actions per project per tick. A head over the cap acts on the next tick.
2. **A failed rebase or main merge starts the resolver in the same tick.** `mc_transition` calls `mst_fix_now_on_park` after a state change. A `BLOCKED_HUMAN conflict-unresolvable*` or `rebase-gate-red*` park starts `bin/blocked-resolver.sh <project>` detached, with `BR_ONLY_PR=<key>`. This is the `mc_eject_fix_now` launch shape. A `fixnow <key> <head> rebase` mark, written before the launch, makes it once per park. The hand-off file is still written.
3. **Red on two consecutive settled heads.** The tick records each settled answer as `cihead <key> <head> <green|red>`, one line per outcome. When the current head is red at rung 0, the known-flake rerun did not fire, and the newest answer of the previous settled head is red, the tick skips the one-rerun rung. `mc_classify` returns `RED_TWICE` with `red-twice: red on consecutive heads <prev8> and <head8>; failing checks: <names>`.
   - The names come from one `commits/<head>/check-runs?filter=latest` read (failure, timed_out, startup_failure; at most 10). A failed read gives `unread`, and the hand-off still happens.
   - The names are kept in `state/merge-conductor/red-checks/<pr>`. The resolver's fix-round brief prints them under `RED ON THIS HEAD AND ON THE HEAD BEFORE IT. THE CHECKS THAT FAILED ON THIS HEAD:`. A later tick on the same head reuses the file and reads nothing.
   - Every `RED_TWICE` (this one and the same-head rung 2) starts the resolver in the same tick, with a `fixnow <key> <head> red` mark.
4. **One alert per stuck PR per state.** The timer alerts once per (PR, head). The hand-offs in 2 and 3 send no alert: the launch is the action. The park's own `STUCK` page stays the backstop.
5. **The `full-ci` label at PR open** (`fcl_apply`, `bin/lib/rb-full-ci-label.sh`, called from the `full-ci label` block of `bin/lib/rb/pr.sh`). When the project's `FULL_CI_LABEL` row is set, it runs the repo's own lane classifier (`node scripts/ci/lane.mjs --base <merge-base> --head HEAD --github-output <file> --summary /dev/null`, 60 s bound). It adds the label unless the lane is `frontend`. A missing, failed or slow classifier adds it. A failed write is one `pipeline.log` line and never fails the build.

## Knobs

| Knob | Settings key | Default |
|---|---|---|
| `MC_STUCK_TIMERS` | `lane.merge-conductor.mc_stuck_timers` | 1 (0 = the old paths, no timer mark) |
| `MC_CI_NOSTART_MIN` | `lane.merge-conductor.<project>.mc_ci_nostart_min` | 15 |
| `MC_STUCK_TIMERS_MAX_PER_TICK` | `lane.merge-conductor.mc_stuck_timers_max_per_tick` | 5 |
| `MC_RED_CHECKS_KEEP_D` | `lane.merge-conductor.mc_red_checks_keep_d` | 14 |
| `FULL_CI_LABEL` | `lib.rb-full-ci-label.<project>.full_ci_label` | empty (off); seeded `full-ci` for project-6-os |
| `FULL_CI_LANE_SCRIPT` | env only | `scripts/ci/lane.mjs` |
| `FULL_CI_LANE_TIMEOUT_S` | `lib.rb-full-ci-label.full_ci_lane_timeout_s` | 60 |

Observe mode (`ACTIONS!=1`) logs one `would …` line per action and writes no action mark. The `cinone` and `cihead` record marks are written in every mode while the switch is on.

## Retention

The red-checks files are bounded by open PRs. `mst_prune` deletes files older than `MC_RED_CHECKS_KEEP_D` days, at most once an hour per box. The new attempt kinds ride the existing attempts and pr-rows retention.

## Out of scope

- `rebase_result` rc 3, 4, 5, 7 and 8 (lease rejected, setup failure, rebind failed, pool refused, tmp full) stay `NEEDS_REBASE` retries.
- A run that is `queued` and never starts reads `pending`, not `none`. The WAIT_CI TTL page owns it.
- A `workflow_dispatch` run is not a `pull_request` run. A job gated on `github.event_name == 'pull_request'` skips. If the head is still run-less, the WAIT_CI TTL page is the backstop.
- The fleet measurement (no project-6-os harness PR more than 30 min in any of the three states over a day) is owed after deploy.
