# The main-red detector can see a red main during a merge burst, and a PR pair can now hold merges

Doc: TEST-DETERMINISM, MERGE-CONDUCTOR

## What changed

**`bin/main-red-detector.sh`** gained a THIRD arm and a per-tick verdict file.

The arm: when the streak arm and the tip arm both find nothing AND the head
still has required runs in flight, the detector walks BACK through the main shas
its runs page holds and decides from the newest COMPLETED required run within
`MAIN_RED_BURST_DEPTH` (5) distinct shas of the head. A red there writes
`flags/main-red-<owner>-<repo>` with `reason=burst`, `sha=` the run it JUDGED,
`head=` the tip it is behind and `depth=` how far, pages once, and logs which
sha decided. The python block that builds the verdict table moved into
`mr_verdicts` and grew three columns — depth, pending-on-a-strictly-newer-sha,
and the tip sha — all of them out of the page already in hand.

If the first page holds no completed required run at all and something required
is still pending, the page is re-read ONCE at `MAIN_RED_BURST_PER_PAGE` (100)
and recomputed. That is the incident's own shape: twenty runs on main, every one
of them started in the last few minutes. A page with nothing pending is never
re-read, and a re-read that fails leaves the first page's (empty) verdicts
standing — never mapped to green.

The arm has no green side. A green run that predates two pushes is no claim
about the head, so the back-walk can raise a freeze and never clears one.

The verdict file, `state/main-red/<owner>-<repo>.verdict`
(`decision=red|green|held|none`, `reason=`, `sha=`, `at=`), is written on EVERY
exit path of the per-repo loop, including the ones that decide nothing: repo
invisible, unreadable runs page, no required workflow completed, below the
streak with nothing green. `held` is the fourth word, added when this build was
rebased onto BH-1281: a tick whose streak arm is holding for a re-test HAS
looked, and `none` there is read by the lane below as "nobody has". `--explain` writes none of it. It is a last-write
cell keyed on the slug, nothing dedupes on it, and a missing one is read as
"do not act".

**`bin/main-red-pr-pair.sh`** now raises one freeze, and only one. When a pair
fires AND that verdict file says `decision=none`, it writes the SAME
`flags/main-red-<slug>` every merge lane already reads, marked
`reason=pr-pair-suspected` (first, so it survives
`bin/merge-conductor.sh`'s `head -c 200`) and `owner=main-red-pr-pair`,
publishes the `pause_flags` row, and adds one sentence to its alert naming the
freeze and `fix-main-red`. It raises nothing against `decision=red` (already
frozen), nothing against `decision=green` (the detector has looked, and a pair
can be one shared flake), nothing when the verdict file is ABSENT — fail-open,
so a hub running an older detector or the minutes between a deploy and the next
detector tick cannot freeze a repo — nothing under `--explain`, and nothing when
`MAIN_RED_PAIR_FREEZE=0`. It clears only a flag whose body says it raised it,
and only on a tick that saw no pair at all with a COMPLETE look (no unknown
head, no cap biting): the same evidence bar the marker resolve already had.

**The handover.** A suspected freeze carries no `sha=`, because that lane judged
no run on main. So when the detector later turns red on the same repo it reads
that absence as "no detector verdict here yet" and takes its FIRST-red path: the
`--critical` "main is RED" page, with its own ISO `since=`, and it rewrites the
body so it owns the flag from then on (the pair lane clears only what still says
`owner=main-red-pr-pair`). Without that read the detector would have taken its
flag-already-there branch and sent the non-critical "main is STILL RED on a new
sha — something landed on main and it did not fix this", which is false in both
halves: nothing landed, and nobody had called this repo red. The one page a
human gets when a suspicion is confirmed by main's own history is not the place
to be wrong about what happened.

`bin/lib/main-red-gate.sh` is NOT touched. Both new paths raise the flag name
that gate already returns, so `bin/merge-conductor.sh`, `bin/merge-sweep.sh`,
`bin/merge-queue.sh`, `bin/review-prs.sh`, `bin/tier2-merge-sweep.sh`, the
tier-1 gate in `bin/run-build.sh` and `bin/batch-resolve.sh` hold on either of
them with zero change, and `fix-main-red` / an all-test-files diff remain the
only two ways through. `mrt_main_red_fixed` (`bin/lib/mc/train.sh`) reads the
flag's MTIME only, so the new body fields cannot confuse it and a merged green
`fix-main-red` PR lifts either owner's freeze.

## Why

2026-09-22, 12:28-12:45Z. Main went red when #1394 merged. The hub's merge lanes
then merged five more PRs onto that red main while the detector logged, every
tick for 15+ minutes: `no completed run of a REQUIRED workflow on main — nothing
decided`. During a merge burst main advances every minute or two, so all twenty
runs in the page were `in_progress`: the streak arm needs two completed reds and
the tip arm needs a completed red on the TIP, and a burst removes both kinds of
evidence from the page. The freeze that exists for exactly this case never
engaged. `bin/main-red-pr-pair.sh` DID know — it raised the pair alert at 12:40Z
— but by design wrote no flag, so its knowledge could not stop a merge.

## The knobs

`MAIN_RED_BURST_BACKWALK` (1), `MAIN_RED_BURST_DEPTH` (5),
`MAIN_RED_BURST_PER_PAGE` (100) and `MAIN_RED_PAIR_FREEZE` (1), all documented
in `env-templates/lanes/355-main-red-burst-and-suspected-freeze.env.example`;
`MAIN_RED_PAIR_FREEZE` is registered in `catalog/lanes.d/main-red-pr-pair.json`
and settable from the control plane. Only the literal `0` disarms either switch.
The first three are read by the detector, which is not a registered lane (the
merge conductor runs it), so only `env/global.env` moves them.

## What this costs, and what it counts as

The new arm adds at most ONE extra GitHub read per repo per tick, only on a tick
whose page holds no completed required run, so the conductor's `gh_budget_low`
guard is not newly pressured. `bin/fleet-slo.sh` counts a pr-pair freeze as a
`main_red` incident, which is the honest reading: merges are held for that repo
and the reason is a red main, suspected rather than proven.

## This branch cannot go green on the determinism lint, and did not break it

`bin/test-determinism-lint.sh` exits 1 on main AND on this branch, on six
findings in `worker/jobs/test/routes/burn.test.js` (5) and `wakes.test.js` (1).
Both files are byte-identical to main here, and this diff contributes zero
findings (`bin/test-determinism-lint.sh | grep -c bh-1451` → 0). Those findings
are the CAUSE of the red main this ticket describes, not the blindness it fixes,
and the ticket scopes them out. The consequence, said plainly rather than left
for whoever merges: this PR's CI is red on that step, so it lands behind a
`fix-main-red` PR or through the merge gate's own exemption — not on its own
green.

## The two things it deliberately does not do

The ticket asks to "dispatch the repair lane (main-red-detect/fix)". No lane by
that name exists in this repo. The repair path this harness has is
`bin/lane-alert.sh`, whose `--severity critical` send already posts a
`fleet_alert` beat that the `*/10` `bin/alert-triage.sh` medic session reads and
fixes, carrying the shared job and the shared first error into that queue. This
build makes that alert also say merges are now held and how to land a fix; it
does not add a new lane that files GitHub issues on a red repo unattended.

And the burst arm fires immediately rather than waiting the way the tip arm
waits `MAIN_RED_TIP_MIN_AGE_MIN`. In a burst the alternative to freezing is
merging onto a proven red, which is what cost five merges on 2026-09-22, and the
freeze self-clears on the next green tick. The two guards that stand in for the
wait are not optional: a run whose `created_at` does not parse decides nothing,
and "in flight" means a required run on a STRICTLY NEWER sha — so a re-run in
flight on the SAME sha still holds the arm.
