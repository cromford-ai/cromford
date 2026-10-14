# 2026-09-22 — BH-1465: the five hub lanes honour the per-project hold

Doc: harness-control-plane, resolver-hold

BH-1463 shipped `lane_project_held <id> <project>` and marked five hub lanes
`per_project_hold` in `catalog/lanes.d/`, and nothing called it. This is the
half that stops work: each of those five lanes now asks the question per
project, BEFORE its first spend for that project, and says so in its own log.

The case that bought it: a local Mac drain holds an unpushed force-with-lease
commit on a project-5 branch, and a hub fix round would collide. The ask was to
pause fix rounds and re-reviews on project-5 alone, keep project-5 BUILDS on,
and keep every other project's fix rounds on. `run-build`, `run-triage` and
`fly-pool` are untouched here, and BH-1463 already pinned that no build lane
carries `per_project_hold`.

## Where each block sits

Every one of them is wrapped in `# >>> project hold` / `# <<< project hold`,
guarded with `command -v lane_project_held` so a box mid-sync that carries the
lane without the library runs exactly as it does today, and names
`flags/$LANE_HELD_FLAG` in the line it writes.

**`bin/blocked-resolver.sh`** — in the dispatch loop, immediately after the
candidate row is read and ABOVE both the budget break and the `DONE_KEYS` mark.
A held candidate was never looked at: no rung (`N`/`NP` untouched), no visit
stamp in `.last-visited.tsv`, no `DONE_KEYS` entry, no `hb_tick`, no per-key
lock, no `br_one`. It calls `br_note_untouched` and `continue`s, so the tick's
`oldest_untouched=` still tells the truth. One `say` line per (tick, project),
kept to one by a `HELD_PROJECTS` substring set in `DONE_KEYS`' own shape. That
set is also read by the skiplist walk, so a held project is in neither
`skipped=[…]` nor the STARVED walk nor `br_saturated_alert` — paging that a
project somebody just stopped has waited an hour is the pager crying about the
switch being off.

**`bin/review-autopilot.sh`** — top of `for P in $PROJECTS`, after the slug
resolution and above `gh_budget_low`, `gh_repo_use_token` and
`harness_pr_list`. A held project costs no GitHub budget and buys no review.

**`bin/merge-conductor.sh`** — top of `tick_project()`, below `hb_tick` and
above everything that costs: no lock, no `mc_tick_budget_take`, no `use_token`,
no GitHub read. Deliberately no `mc_tick_metrics` either — it rewrites
`tick-<p>.json.started_at`, which BH-1486's cadence hold measures from, so a
hold that stamped it would hold the project for ever. `hb_tick` fires first, so
the heartbeat and `bin/lane-reaper.sh` still see a live lane.

**`bin/merge-sweep.sh`** — in the record loop, below the RESULT/`PR_CREATED`
filters (a record that is not a PR record costs no gate lookup) and above
`sweep_seen`. The record is neither tallied as evaluated — `_ITER_PROJ` is still
empty, so the next iteration's `sweep_tally_prev` banks nothing — nor counted as
unseen: unseen means "the walk ran out of budget before reaching it", and a
record an operator stopped on purpose is neither. The `tick TOTAL:` line gains a
trailing `held=[…]`; every existing reader of that line matches it by prefix.

**`bin/main-red-pr-pair.sh`** — in `for SLUG in $REPOS`, above `pr_pair_signal`.
The loop walks repository slugs, so the project is resolved first with
`bin/project-of.sh --repo` (a local `fleet.conf` read, no GitHub call). A slug
no project claims runs unchanged: "we could not tell" is never read as "held".

## What a hold does NOT do

No liveness row, no `.paused` stamp, no flag sighting (that is BH-1463's
decision, and the lane RAN this tick — it skipped one project). No alert, no
lock, no queue row, no budget take. Exactly one log line per (tick, project,
lane), written next to the `continue` that skips the work, and the D1 mutation
check below proves that `continue` is load-bearing. A tick where a held project
happened to have no candidates or records writes nothing at all.

A hold flipped mid-tick is seen on the NEXT tick — the 60s `LANE_GATE_CACHE_S`
plus BH-1463's per-process memo — and in-flight rounds finish, which is the
contract `all-off` already has.

## One thing the plan asked for that is NOT here

The plan mirrored merge-sweep's `held=[…]` field onto the resolver's own `tick:`
line. It is not there. Four assertions in
`tests/blocked-resolver.bh-1122-test.sh` and two in
`tests/blocked-resolver.bh-980-test.sh` compare that line with `=` or anchor its
last character, the ticket asks for the field on the sweep's line only, and the
per-(tick, project) `held` line already answers "what did this tick hold".
Adding it would have meant rewriting six assertions in two regression suites for
a field nobody asked for.

## Verified

`tests/hub-lanes-project-hold.bh-1465-test.sh` — 48 assertions. Section 1 runs
the REAL `bin/blocked-resolver.sh` against a scratch `$HARNESS` with the real
gate library: one park per project, `flags/lane-off-blocked-resolver-projb` set,
`BR_PER_TICK=4` so the budget can never be the reason. proja is dispatched,
projb is not, exactly one log line names the flag, no alert names projb, the
ledger carries no projb row, the tick line does not name it — and with the flag
removed the next tick dispatches it. A `lane-off-blocked-resolver-proja-x` file
stands through the whole section, so BH-1463's prefix negative is re-proved
through the production lane. Sections 2-5 paste each lane's block in verbatim by
its markers. Section 6 proves the holds are independent in both directions
against the real library. Section 7 is the marker ratchet. Five deliberate
mutations — the `continue` (or `return 0`) deleted from one lane's block at a
time — were each confirmed red on that lane's section before the tree was
restored.
