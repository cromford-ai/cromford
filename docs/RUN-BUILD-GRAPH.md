# run-build.sh — transition table

<!-- changes:begin -->
> **What changed since this doc was written lives in [`docs/notes/`](notes/INDEX.md)**, one dated note per change. Add a note there instead of appending here; guardrail `doc-monolith-edit` checks it once it is armed in CI (the adoption PR that `guardrails/README.md` prescribes; not yet opened).
<!-- changes:end -->

Every stage of the build pipeline with its **enumerated, disjoint exits**. Each
exit names either the next stage or a typed terminal, with the bound that stops
it looping.

This documents **reality, not aspiration**. Where the script can leave a stage
without writing a next state or a terminal, that is recorded as a FINDING rather
than quietly fixed — a table that describes what we wish the script did would be
worse than no table.

Why it exists: the 232 abandoned ledger rows swept on 2026-08-24 were all builds
that died in a stage without ever writing a terminal. Nothing downstream could
close them because nothing downstream knew they had stopped. This is the
at-the-source audit of that class.

Two vocabularies, deliberately separate — conflating them is its own bug:

- **RESULT terminals** (`$BUILD/RESULT`, first line) — consumed by the triage
  sweep SOP, the jobs watchdog's resume pass (`bin/lib/resume-dead.sh`,
  formerly `resume-dead-builds.sh`), `review-rescue.sh`, `merge-sweep.sh`.
- **Beat stages** (`BB <stage>`) — consumed by the console kanban's
  `BUILDING_STAGES` / `DEAD_STAGES`. A stage name the console does not know makes
  a live build stop looking live.

---

## Transitions

| # | From | To | Guard | Bound |
|---|---|---|---|---|
| 1 | entry | **exit 2**, no RESULT | `RESUME_BUILD` set but the dir is gone | — · **FINDING F1** |
| 2 | entry | context-gate | always | — |
| 3 | context-gate | `BUILD_REFUSED` | rules/checkout drift the gate cannot heal | one attempt |
| 4 | context-gate | fly-dispatch | pool enabled for the project | — |
| 5 | fly-dispatch | `QUEUED_FLY` | job enqueued (or already queued/active) | queue dedup on KEY |
| 6 | fly-dispatch | slot-claim | no pool for this project | — |
| 7 | slot-claim | `BUILD_DEFERRED wip-limit` | WIP cap reached | retried next tick |
| 8 | slot-claim | `BUILD_DEFERRED all slots busy` | every slot held — only reachable when `BUILD_SLOTS > 0`; with the default 0 no slot lock is opened at all | retried next tick |
| 9 | slot-claim | `BUILD_DEFERRED already building` | per-KEY flock held — a SAME-BOX fast path since 2026-09-14, no longer the dedupe of record | retried next tick |
| 9a | queue-claim | `BUILD_DEFERRED <KEY> claimed by another builder` | the `build_queue` CAS answered 409: another machine took this row while it was still `queued`. Armed only with `BUILDER_DIRECT` on; off, this is logged and built through exactly as before | retried next tick; the row stays `queued` for whoever won it |
| 10 | slot-claim | `BUILD_REFUSED` | `/root/repos/<project>` missing on this box | one attempt · **was FINDING F2** |
| 11 | slot-claim | worktree-setup | slot acquired | — |
| 11a | slot-claim | **stack-base resolution** | `STACK_BASE` set, stacked builds on, the name is a safe ref, and `git fetch origin +refs/heads/<parent>:…` succeeds | `$BASE` becomes the parent branch; `$BASE_MAIN` keeps the real one. Unsafe name, `STACK_BASE == $BASE`, a branch gone from origin, or the kill flag -> one pipeline.log line and the ordinary base (never a failure) |
| 12 | worktree-setup | `BUILD_DEFERRED worktree setup failed` | checkout/pull/worktree-add failed | retried next tick |
| 13 | worktree-setup | `BUILD_DEFERRED cannot check out origin/<branch>` | `origin/<branch>` unfetchable on resume | retried by the next resume (`bin/lib/resume-dead.sh` refunds the attempt) · **was FINDING F3** |
| 14 | worktree-setup | `BUILD_DEFERRED branch unavailable` | branch held by a stale worktree | retried next tick · **was FINDING F4** |
| 15 | worktree-setup | `BUILD_DEFERRED resume branch locked` | resume branch held elsewhere | retried next tick |
| 16 | worktree-setup | `BUILD_DEFERRED target branch not fetchable` | `TARGET_BRANCH` has no ref | retried next tick |
| 17 | worktree-setup | PLAN | branch ready | — |
| 18 | PLAN | `BUILD_DEFERRED plan session produced no output` | empty plan (model cap/outage) | resume cap |
| 19 | PLAN | `PLAN_BLOCKED` | plan.md line 1 OPENS with the parked marker (`PLAN_IS_BLOCKED`, BH-387); a ticket title that merely contains the word is not a park | terminal |
| 20 | PLAN | `PLAN_STALE` | board thread moved during planning | re-run |
| 20a | PLAN | `PLAN_STALE` | RESUMED build: the thread moved since `ticket-fp`, the snapshot the reused plan was written against | re-run |
| 20b | PLAN | `PLAN_MALFORMED` | tasks still carry no `VALIDATE:` / `SATISFIES:` after the one repair pass | relaunched once by the sweep, then held |
| 20c | PLAN | `PLAN_MALFORMED` | the size gate found no readable plan (no `plan.md`, or an empty one) and size enforcement is on. A plan with no `## Size` section is NOT this row since BH-5292: it gets a `SIZE WARNING`, an estimate from its file list, and builds (it splits only when the estimate is past 2x the threshold) | same ledger as 20b: relaunched once, then held |
| 20d | PLAN | `PLAN_MALFORMED` | the ticket is ALREADY `held` / `skipped` in the plan-malformed ledger (2 of 2 malformed plans) — refused BEFORE the planner, BH-657 | **no plan session spent**; one ALERTS line on the first skip, log-only after it; left by a `released` row |
| 21 | PLAN | `DECOMPOSED` | plan says XL (always), **or** the size gate says over threshold and enforcement is on (**the default since 2026-09-14**) — children filed, parent parked, split comment posted | terminal |
| 22 | PLAN | `DECOMPOSE_FAILED` | split attempted, children not filed | terminal |
| 23 | PLAN | overlap wait | plan valid, within the size threshold (or the gate disarmed), every task traced | checkpoint: valid plan.md skips PLAN, never the plan gate |
| 23a | overlap wait | `BUILD_DEFERRED file overlap` | a running sibling still claims a planned file after `OVERLAP_WAIT_SECS` (**0** since 2026-09-13 — the first check defers), and `OVERLAP_DEFER_ENFORCE=1` (the shipped default) | retried next tick; the RESULT names the wake condition |
| 23b | overlap wait | EXECUTE | no sibling claims a planned file, or the cap fired with the `OVERLAP_DEFER_ENFORCE=0` kill switch set | no waiting at all by default; one of these two immediately |
| 23c | overlap wait | **plan-overlap** | this box's own `builds/` said disjoint | one hook point, right after PLAN — the file list exists and nothing has been edited yet |
| 23d | plan-overlap | `BUILD_DEFERRED OVERLAP_DEFER …` | `bin/plan-overlap.sh` finds a file this plan names claimed by something in flight FLEET-wide (the claims ledger + the queue's `claimed` rows), and `OVERLAP_SCHED` is not `0` | ledger row back to `queued`, a 10-minute not-before in `state/overlap-defer/<project>/<KEY>`, re-offered to any free box |
| 23e | slot-claim | `BUILD_DEFERRED plan overlap not-before` | this KEY stood down on 23d less than `OVERLAP_DEFER_NOTBEFORE_SECS` (600) ago | deferred BEFORE the plan is bought; the marker is consumed the moment it expires |
| 23f | plan-overlap | EXECUTE | nothing in flight claims a file this plan names, no plan data to judge, or `OVERLAP_SCHED=0` / `flags/plan-overlap-off` | the kill flag makes 23c-23e a no-op |
| 24 | EXECUTE | `EXECUTE_EMPTY` | no diff vs base after the session | terminal |
| 25 | EXECUTE | **test-tamper gate** | diff present | checkpoint: existing commits skip EXECUTE |
| 26 | test-tamper gate | `REVIEW_BLOCKED test-tamper:` | tests weakened, no `TEST-CHANGE:` block | terminal to run-build · re-enterable by `review-rescue.sh` (see below) |
| 27 | test-tamper gate | reproduction gate | clean (0), justified (2), or scan_failed (3) | 3 alerts, never blocks |
| 28 | reproduction gate | `REVIEW_BLOCKED reproduction-gate:` | new tests pass at the merge base | terminal |
| 29 | reproduction gate | SEMGREP | proven (0), no tests (2), unavailable (3), head-red (4) | 10 min run cap |
| 30 | SEMGREP | REVIEW | always — fail-open, findings feed the prompt | 300 s |
| 30a | SEMGREP | **E2E read-only lane** | `GATES_PARALLEL=1` (the default): the preview smoke is launched BESIDE the lenses instead of in front of them, and joined before the fix round | path-gated before the push (a diff with no UI paths pushes nothing and waits for nothing); the join is capped at `E2E_JOIN_MAX_S` (default 600 s); past the cap the build carries on and the verdict is late-settled before the tier decision, then appended to the PR as a comment |
| 31 | the lenses | fix-round | a lens's verdict is not APPROVE | one fix round per refusing lens (default), or one merged round for all of them under `LENSES_PARALLEL=1` |
| 32 | fix-round | `REVIEW_BLOCKED` | the general lens still does not APPROVE | terminal |
| 33 | REVIEW / SEMGREP | security-review | the diff touches schema/auth/money | after the general lens (default), or launched WITH it under `LENSES_PARALLEL=1` |
| 34 | the lenses | PR-open | every lens this diff earned APPROVEs | checkpoint: an APPROVE from every one of them on this exact head stands |
| 35 | fix-round | `SECURITY_BLOCKED` | the security lens still does not APPROVE | terminal |
| 36 | security-review / SEMGREP | refute-review | the diff touches schema/migrations/money | after the security lens (default), or launched WITH the other two under `LENSES_PARALLEL=1` |
| 37 | fix-round | `REFUTE_BLOCKED` | the refutation lens still does not APPROVE | terminal |
| 38 | the lenses | PR-open | APPROVE | — |
| 39 | PR-open | `BUILD_DEFERRED push rejected` | `git push` refused | retried next tick |
| 40 | PR-open | `PR_CREATED` | PR opened, tier 2 or gates deferred | terminal |
| 41 | PR-open | merge-lane | PR opened, tier 1, auto-merge armed, approval bound to THIS head | — |
| 42 | merge-lane | `PR_MERGED` | squash-merge succeeded | terminal |
| 43 | merge-lane | `PR_CREATED` | merge deferred (QA / migration / rebase note) | terminal |
| 43a | any terminal | the same terminal **+ `\| CLOSED-OUT:`** | builder only (`BUILDER_EXEC`), `BUILDER_DIRECT` on, and the RESULT is `PR_CREATED`/`PR_MERGED` **and** `bin/board-closeout.sh` really posted | terminal; the note is the only thing that changes, and only after a POST that landed |

### Stacked child builds (transition 11a, 2026-09-14)

**The hour this removes.** A child ticket carrying `Blocked-by: #N` waited for #N to
*close*. On project-5 that is a full chain level — plan 7-10 min, execute 20-33 min, the
push-to-review dead gap 6-8 min, review 4-9 min, post-review size/scope ~10 min, then the
conductor's `*/5` tick and triage's `*/20`: **60-75 minutes per level**. Tonight TK-563
through TK-567 all sat behind #611's open PR, and TK-558/559 behind 555/557. The parent's
work already existed on its branch the whole time.

**What happens instead.** `bin/unblocked-children.sh` emits a second class of line beside
`UNBLOCKED`:

```
board issues: STACKABLE 563 "TK-563 child one" base=ticket/TK-611 parent-pr=https://github.com/example-org/project-5/pull/900 (…launchable NOW on top of that branch…)
```

A child is STACKABLE when it has **exactly one** still-open blocker (a child can only be cut
from one base), that blocker has an OPEN non-draft harness PR (branch `ticket/*-<N>` or title
`<KEY>-<N>:`), every other blocker is closed, and **the child has no open PR of its own**.
The triage tick treats the line exactly like `UNBLOCKED` and launches
`STACK_BASE=<base> setsid run-build.sh …`.

**Which ticks emit it.** Every tick whose gate is `board-changed` or `event-wake`
(the dominant one since the wake loop was armed), and the `ALSO` section of a
queue or sweep tick. STACKABLE has **no board trigger** — the fact it acts on is
"the parent's PR is open", which no board diff mentions — so the pass runs
whether or not the board moved. Both of those were true only on paper until
2026-09-14: docs/EVENTS.md §5.3.

**How the base travels.** `STACK_BASE` is one variable end to end: run-build's enqueue writes
it into the queue entry AND the row's `meta`; `bin/fly-dispatch.sh` materialises it back out
of the meta; `bin/fly-pool.sh` pushes the job file verbatim and carries the field through the
machine json so a requeue after a death keeps it; `fly/builder-runner.sh` reads `.stack_base`
and hands it to run-build.sh.

**What it changes inside run-build.sh.** Exactly one thing: `$BASE`. The ~30 sites that cut
the branch, diff the tree, prompt the three review lenses, rebase before the PR and open the
PR already read that one variable, so the child's branch comes off `origin/<parent>`, the
reviewers see ONLY the child's change, the pre-PR rebase rebases onto the parent, and
`gh pr create --base <parent>` points the PR there. Two places still need the real base and
read `$BASE_MAIN`: the "retargets to main" sentence, and the tier-1 merge hold.

Three details that are not obvious:

- **The base is made resolvable with `git update-ref`, never a checkout.** The parent's own
  build leaves `ticket/<parent-key>` checked out in its persistent worktree; a
  `git checkout -B` of the same name here would move that branch under a live worktree, and
  the shared checkout's HEAD has no business sitting on a feature branch either.
- **The fetch happens OUTSIDE the repo lock**, and it doubles as the existence probe. The
  lock is for the checkout mutation, not for a network round trip — and a parent branch that
  has vanished because its PR merged is the *good* outcome, so the build falls back to the
  ordinary base with a pipeline.log line rather than deferring.
- **A stacked PR is never merged from the build**, at any tier: `gh pr merge` would land the
  child INTO the parent. The tier-1 gate hands it to the conductor, which holds it in
  `STACKED_WAIT` until GitHub (or the conductor itself) retargets it to `$BASE_MAIN` —
  docs/MERGE-CONDUCTOR.md section 3.

**Kill flag:** `STACKED_BUILDS=0` in `env/global.env`, or `flags/stacked-builds-off`. Either
one stops `unblocked-children.sh` emitting a STACKABLE line, stops the enqueue carrying the
field, and makes run-build ignore an inherited `STACK_BASE` — the build is then byte-for-byte
the one today's harness would have run. Default ON. Tests:
`tests/stacked-child-builds-test.sh`.

### Rescue of blocked pool builds (transition 26, 2026-09-13)

`REVIEW_BLOCKED test-tamper:` is terminal **to run-build.sh** and no longer
terminal to the fleet. `bin/review-rescue.sh` (hub cron `7,37`) re-enters it.

Why: on 2026-09-13, 39 pool builds fleet-wide (23 on project-5) held this
terminal because the scanner counted a RETITLED or SPLIT test case as a
deletion. Each had its branch pushed to origin and **no PR**, and the ledger row
said `failed`. Four of them also carried a real `VERDICT: APPROVE` from the same
run — the gate can fire after the review on a resumed build — so they were not
waiting for a review at all, they were waiting for a pull request.

What the lane now does with one of these, per candidate (oldest first,
`RESCUE_PER_TICK` per tick, default 3, two attempts each):

1. **Parses the dir name through the registry**, stripping the hub's `pool-`
   copy marker first (`pool-<project>-<KEY>-<stamp>`). Before this, every
   relayed build answered "cannot parse project/key" and was marked
   `.review-rescued` — the one state from which a dir is never looked at again.
2. **Candidate even with a verdict** — for `test-tamper` blocks only. An
   ordinary died-mid-review orphan that reached a verdict is still skipped.
3. **Re-runs `bin/test-tamper-scan.sh`** on the pushed head inside the throwaway
   worktree, report saved to `<build>/test-tamper-rescan.txt`. rc 1 (a test
   really was deleted, unjustified) → ALERTS + `.review-rescued`, a human's
   problem. rc 0/2 → continue, report pasted into the review prompt. Any other
   rc → "could not verify", logged, never blocking (the same degrade run-build
   applies).
4. **Opens the PR** when only a branch exists (`gh pr create`), so the APPROVE
   path can never write `PR_CREATED` with an empty url again. A creation failure
   leaves the dir un-rescued for the next tick and counts as an attempt.
5. **Reuses a standing `VERDICT: APPROVE`** rather than re-buying the review;
   otherwise re-runs the adversarial review as before.
6. Writes `PR_CREATED <url>` + the `TIER:` line + a `RESCUED:` line. The ledger
   is never touched — the merge lanes read RESULT.

### The size gate (2026-09-12, armed 2026-09-14)

Rows 20c and 21 are one gate. `bin/size-gate.sh` reads the plan's `## Size`
section (`FILES:` and product `LINES:`), judges it against the per-project
threshold from `bin/size-threshold.sh` (settings rows `size_gate.<axis>.<project>`
→ `size_gate.<axis>`, editable on /config → box flag → `catalog/size-thresholds.conf`
→ 700 lines / 20 files; BH-4985). A ticket labelled `hotfix` (the `HOTFIX` that
`# >>> hotfix detect` settled) is sized against its own tier first:
`size_gate.<axis>.hotfix.<project>` → `size_gate.<axis>.hotfix` (seeded 1500 / 30),
then the chain above, so an emergency builds as one PR; its src reads `row:hotfix`
and a split comment says "hotfix budget" (2026-10-07). **The file axis is the plan's DECLARED `FILES:`, and
only that** (BH-612, 2026-09-16). It used to be checked against the plan's own
file list, `planned-files.txt`, so the number could not be shaded down — but
`bin/planned-files.sh` builds that list as a deliberate over-listing of every
path the plan MENTIONS (the callers it read, the `## Out of scope` list, the
"do NOT edit src/x.ts" line), because over-listing costs a serialization and
under-listing costs a conflict. Judged on it, project-5 #1906 declared
`files=2 lines=45` and was decomposed into TK-1921/TK-1922 on 18 mentions, and
#1907 declared `files=2 lines=140` and was decomposed into TK-1919/TK-1920 on
16 — in one night, while #1912's honest `files=17 lines=780` split correctly.
So: the superset still serializes builds (`bin/conflict-check.sh`,
`bin/plan-overlap.sh`, `state/claims/<project>/<KEY>`) and never gates size. The
gate still prints `SIZE_FILES_PLANNED: n`, and adds
`SIZE_FILES_MENTIONED: n (not gating)` when that count is over the tolerated
file limit, so a reviewer can see a prose-heavy plan without the number
withholding a build. A plan that UNDER-declares is caught AFTER execute against
the diff that actually shipped — see the post-hoc paragraph below. **A 15% tolerance
band sits above the nominal limits** (the operator, 2026-09-16, after BH-594 sized
itself 310 against 300 and was split into serial children for ten lines of
slack): up to 345 lines / 13 files builds whole with a `SIZE_TOLERATED` line
on the record; `SIZE_GATE_TOLERANCE_PCT` in `env/global.env` moves the band,
`0` removes it. Children of a split are still budgeted against the NOMINAL
limit, so tolerance never compounds. **A self-reported `SIZE: XL` no longer
splits a plan the gate measured `within`** (same day, after BH-597 declared 210
lines and was split on its T-shirt line alone): measured beats self-reported,
and XL keeps its old power only when the gate could not measure or agrees.
PRODUCT lines:
`bin/size-scope.sh` owns the exclusion list (tests, docs, specs, lockfiles,
generated code, Prisma migration snapshots) and the post-hoc guard calls the
same helper, so the two sides cannot disagree about what they measured.

**Enforcement is ON by default since 2026-09-14** (the operator). The gate shipped
warn-only on 2026-09-12 and warn-only did exactly what it promised: it measured
TK-552 at 1,900 product lines across 18 files and watched it build whole in one
33-minute execute, and flagged TK-556 decomposable the same night with the same
non-consequence. Two or three parallel 15-minute children would have been
faster to build and reviewable at the end.

One switch, resolved once per build by `SG_SWITCH_RESOLVE` (`# >>> size enforce
switch` in `bin/run-build.sh`) and read by BOTH halves of the gate — the
plan-time split here and the post-hoc demotion at PR-open — so a build cannot
split at plan time and then print "enforcement off" in its own PR body. First
hit wins:

| Lever | Effect |
|---|---|
| `flags/size-gate-enforce-off` | the fleet kill flag. Outranks everything, no deploy and no env edit, and while it is there every path below is byte-for-byte what it was before 2026-09-14 |
| `SIZE_GATE_ENFORCE_<project>=0` | one project opts out, in `env/<project>.env`. Also read uppercased with dashes as underscores (`SIZE_GATE_ENFORCE_project-3_OS`), because `project-3` is not a shell identifier |
| `SIZE_GATE_ENFORCE=0` | the global switch, unchanged in meaning |
| nothing set | **armed** |

A junk value is not a switch value: it is ignored, the next source is read, and
it raises one ALERTS line naming the flag that actually turns the gate off. That
reasoning inverted with the default — while the gate was off a typo must not ARM
something that withholds a build; now that it is on, a typo must not silently
disarm the fleet's only defence against a 1,900-line PR.

Disarmed, rows 20c and the over-threshold half of 21 are inert: the verdict is
logged, written to `$BUILD/size-gate.txt` and recorded as a `size_gate` ledger
artifact, and the build proceeds. `SIZE: XL` still splits either way — it was
the only decomposition trigger this pipeline had. A gate that could not run is
`not-recorded` and splits nothing.

**Depth 1, and only depth 1.** `bin/run-decompose.sh` titles every child
`<PARENT KEY>.<n>: <slice>` on both lanes, so a split child says out loud that
it is already a slice of something (the guard reads `$BUILD/ticket-meta.json`,
which run-build writes before PLAN). A child that STILL sizes over the threshold
is built whole, with one line in `pipeline.log` as the note (a build whose
`ticket-meta.json` never arrived is not treated as a child — not-read and
top-level are different facts). Re-splitting it
buys another Fable call, another ticket and another push-to-review dead gap
against the narrowest scope anyone has written down yet, and the guard is also
the only thing between one bad estimate and a split loop that files tickets
forever. Armed-only, so the kill flag leaves the XL path exactly as it was.

The post-hoc half has no row here because it is not a stage: at PR-open the
shipped diff is measured in product lines, and over **2×** the threshold the
build carries a `SIZE:` note into the PR body, the verdict row and the RESULT
line (always), plus a tier-2 demotion (only when armed). It never blocks — the
code is already written by then. The same render also compares the plan's
declared `FILES:` with the product files the diff actually carries and prints a
`size declaration` row in the evidence block — `SIZE_DECLARATION_EXCEEDED`
(`bin/evidence-summary.sh`) when a plan that declared itself inside the file
limit shipped past it, which is where an under-declaration is caught now that
the mention superset no longer gates the file axis. Warn only, on the PR page
and in the ledger row; it changes no tier and writes no RESULT.

### Row 21 in detail: what a split actually files (2026-09-14)

`bin/run-decompose.sh` costs one Fable call, booked to the ledger as
`stage=decompose` (it rode as `stage=plan` until 2026-09-14, which priced a
split inside planning and made "what has decomposition cost us" unanswerable;
the runner and its failover are still inherited from the plan stage). It splits
into 2-5 file-disjoint children — **a contract chunk and then a parallel wave of
siblings on top of it** (below) — each sibling carrying the same per-child budget
the parent was judged against, and it has one lane per board kind:

| | in-app board (`fleet.conf` prefix is a path) | GitHub Issues (prefix `-`) |
|---|---|---|
| who files the children | the model, through `POST .../boards/{id}/tickets` | **this script**, through `gh issue create` |
| child title | `<PARENT KEY>.0: contract — <slice>`, then `<PARENT KEY>.<n>: <slice>` | same |
| ordering | `Order: <n> of <total>` + "build after `<sibling key>`" in the body | `Order: <n> of <total>` + `Blocked-by: #<contract> (hard)` on every sibling and nothing else unless the spec declares an import from a sibling, which is then a hard blocker on the same line, the exact line `bin/unblocked-children.sh` parses |
| handoff | the board's own status | the `ai-build` label, on every child |
| parent parked as | `in_progress` (master of the split) | the `ai-build` label is REMOVED; the issue stays OPEN |
| split comment | the model posts it | this script posts it, with the child links and the size numbers |

### Interface first: one contract child, then one parallel wave (BH-481, 2026-09-16)

The first child is the **contract**: the smallest change every sibling imports —
types, the schema or migration, route and function signatures, stubs that
compile and do nothing useful yet. It is filed first as `<KEY>.0: contract —
<slice>` with a `CONTRACT:` line naming what it exports, and it is held to
`CONTRACT_MAX_LINES` (60) product lines rather than the per-child budget, because
every sibling is blocked on it and what it costs is paid by the whole wave.

Every sibling then carries `Blocked-by: #<the contract> (hard)` **and nothing
else** — unless its spec declares that it imports a sibling's code, which is
added to the same line as a second hard blocker, because in this harness
`Blocked-by` means "needs that chunk's code" and a declared import is exactly
that. The chain cap below bounds that at two levels, so it cannot grow back into
a chain. Two separate things were wrong with the chains this replaces. The obvious
one: 30 of one project's 46 open children arrived as 3-5 level `Blocked-by`
chains and a level is ~50 minutes of build, so a four-part split spent four
sequential hours on a pool that was otherwise idle. The expensive one: children
strand because **parents get rebuilt**, and parents get rebuilt because they are
big and collide (one night, 9 of 31 merged PRs were r2+ and the superseded
parents were 40-90 commits behind main). A twenty-line contract chunk almost
never conflicts, so the wave hanging off it almost never strands.

The siblings do not wait for the contract to **merge** either: it is `(hard)`, so
`bin/dep-verify.sh` takes the author's word and `bin/unblocked-children.sh`
emits them as `STACKABLE` the minute the contract's PR opens, and they build on
its branch (`STACK_BASE`). That is the expected path and the decompose prompt
says so.

Relationships between siblings are also **declared**: the filer writes
`DEPENDS: #<n> hard — <symbol>` when the spec says one sibling imports another's
code and `DEPENDS: #<n> soft — …` otherwise, in the shape
`prompts/plan-contract.md` §7 asks the child's own plan to carry. The `hard` ones
are the links that also become blockers; the `soft` ones are the wave. Only siblings
already filed can be named, since GitHub hands out the numbers as the loop runs.
**More than 2 chain levels beyond the contract is `DECOMPOSE_FAILED`** before
anything is filed: a third level means the symbol it waits on belongs in the
contract, which is a decomposition failure and not a dependency.

**Shared files are named, not left to be discovered (BH-579.4).** The contract
owns the paths it moves, so a sibling that names one of them is about to work on
a file that changes under it. The filer computes both path sets with
`bin/planned-files.sh` — the one extractor every other reader of a planned-files
list runs — over the contract's `CONTRACT:` string and its body together, and
for every sibling whose own body names one of those paths it writes
`CONTESTED: <path> -> #<contract>` into that sibling's body directly after the
`Blocked-by:` line, one line per shared path, sorted and deduped. The same set,
deduped across siblings, goes in the split comment under one sentence, and only
when there is at least one line. The line adds no blocker: the contract's `(hard)`
blocker above already orders the work. What it buys is that
`bin/planned-files-cheap.sh`'s tier-1 body scrape and the contested-hold gate can
see the shared path without planning the child first. Matching is exact string
matching on the extractor's output, so `src/x.tsx` is not `src/x.ts`; a sibling
that shares nothing gets no line and stays in the wave untouched; and a path the
extractor's prefix list does not cover (this repo's own `bin/`, for one) produces
no line at all. The extractor's own bare 3+-segment directory scopes are not
filtered out here, so two bodies that touch different files under the same
deep directory (`src/lib/scan/types.ts` and `src/lib/scan/store.ts`, say) can
produce a `CONTESTED: src/lib/scan -> #<contract>` line naming the directory,
not a file — read it the same way `bin/plan-overlap.sh` reads that scope: as
"working in the same area," not "the same file." Every silence — no extractor
on the box, a contract that names no extractable path, or the extractor
running and failing on one body — says so in `pipeline.log`, because "nothing
shared" and "nothing looked at" must not read the same from the outside.

The issues lane is deterministic on purpose. The model writes a SPEC
(`$BUILD/children.json`: `contract` on the first object, `title`, `after` as
1-based positions in the array written `"<position>: <symbol>"`, `body`) and files nothing itself, because the conventions the rest of the
pipeline parses are exact and a model free-handing them breaks the ordering
silently — a child filed without the label is invisible to every watcher, and a
child whose ordering line is phrased differently launches immediately and
collides with the sibling it was meant to follow. `after` naming a later sibling
is dropped with a line in `pipeline.log` rather than obeyed: the sibling has no
issue number yet. Parking by removing the label is the issues-lane spelling of
the same rule that parks a board parent `in_progress` (prompts/project-5.md,
"the label IS the handoff"); closing it instead would tell the operator the work
shipped before any of it has.

`DECOMPOSE_DRY_RUN=1` prints every `gh` command instead of running it and reuses
an existing `children.json` instead of buying a Fable call — the mode
`tests/run-decompose-issues-test.sh` drives, and the honest way to inspect a
real split before it touches a client's repo. Every command it would run is also
written to `$BUILD/decompose-gh.log`, dry run or not. A re-entered build whose
`children.txt` is already populated re-files nothing.

Rows 20a/20b/20c and 23a/23b carry letters instead of renumbering 21-46: half this document and
three sibling scripts refer to transitions by number ("transition 41", "40-43"),
and shifting them all to insert two PLAN exits would rewrite those references to
buy nothing.

### Conflict-aware scheduling, fleet-wide (rows 23c-23f, W2-D, 2026-09-14)

Row 23a is `bin/conflict-check.sh` and it is unchanged: it asks whether a build
**on this box** claims a file this plan names, and its switches
(`OVERLAP_WAIT_SECS`, `OVERLAP_DEFER_ENFORCE`) keep doing exactly what they did.
Row 23c is the same question asked of the fleet.

`bin/plan-overlap.sh <project> <plan.md>` is called from ONE hook point, right
after PLAN — the first moment the file list exists and the last moment before a
line is edited. It reads `planned-files.txt` (deriving it with
`bin/planned-files.sh` if the size gate has not already) and compares it with
three sources: this box's live `builds/<project>-*` dirs, the claims ledger at
`state/claims/<project>/<KEY>`, and the queue's `claimed` rows through
`queue_list`. The queue is what makes it fleet-aware — with a pool, the build
about to conflict with this plan is usually on another machine — and it is also
what retires a dead claim, which the 4h mtime heuristic could only guess at. A
key claimed on a box whose plan never reached this one is written to
`pipeline.log` as `OVERLAP_UNJUDGED`, never counted as disjoint and never counted
as an overlap.

On a hit the build ends `BUILD_DEFERRED` with the line
`OVERLAP_DEFER <KEY> vs <KEY2> files=[…]`, which returns the ledger row to
`queued` and writes a **not-before** ten minutes out into
`state/overlap-defer/<project>/<KEY>`. Row 23e is where that marker is read: at
the top of the script, right after `env/global.env` is sourced, so a key inside
its window defers for free instead of buying another PLAN session and standing
down against the same sibling. The marker is consumed the moment it expires, and
the build that follows re-runs the whole overlap test — by then the sibling has
usually finished.

Kill flag: `OVERLAP_SCHED=0` (or `flags/plan-overlap-off`). With it set the helper
exits 0 before reading anything and the not-before gate is skipped, so rows
23c-23e do not exist and the pipeline is byte-for-byte what it was before this
change. Why this is worth a gate at all — one merge into one main costing every
other open PR a rebase and a re-review — is
`docs/BUILD-CONCURRENCY.md`, "The ceiling at the other end: one line into main".

### The three lenses run at once, and share one fix round (2026-09-12)

Rows 31-38 used to describe three lenses in a queue: the general REVIEW ran to
completion, then the SECURITY lens, then the adversarial REFUTER, each with its
own fix round and its own re-review, and each of those fix rounds committed past
`review-head` and re-triggered the head-bound gate below. Three read-only passes
over one immutable diff were serialised for no reason but the order the code was
written in, and a build spent 40-60 minutes in that section.

`LENSES_PARALLEL=1` launches the lens REVIEWS
concurrently — background `CC` calls into their own run files, waited on **by
pid**, never with a bare `wait`, because the shell already owns `job_beat_start`'s
heartbeat child and a bare wait would block on it until the claim timed out.
Whichever lenses refused are then answered by ONE fix round that is handed every
one of their findings files at once (two lenses can name the same line, and a fix
for one can reopen another), the repo suite is re-run once on the fixed head into
`harness-suite-fix.txt`, and ONE re-review reads the merged fix and writes a
`VERDICT-REVIEW:` / `VERDICT-SECURITY:` / `VERDICT-REFUTE:` line per lens into
`merged-review2.md`. Those verdicts are fanned back onto each lens's own artifact
as its final `VERDICT:` line, so every consumer that has ever read "the last line
of `security-review.md`" reads a verdict about the head that is going to merge —
including a lens that approved BEFORE the fix round and is overturned after it.

Two silences, on purpose. If the re-review says nothing about the general lens,
or about a lens that REFUSED, that is a `BLOCK`: this re-review *is* the general
lens's pass over the new head, and nothing lifts a refusal by saying nothing. If
it says nothing about a lens that APPROVED, that lens's own verdict stands —
the same residual the head-bound gate settles with one general re-review, and
defaulting it to `BLOCK` would turn a sloppy re-review into a terminal that does
not requeue.

**Unchanged on purpose**: the artifact names, `review.md`'s `TIER: n` /
`VERDICT: …` last-two-lines contract, the `VERDICT: …` last line on the other
two, the lens-selection conditions (`RISKY` file names for the security lens,
schema/money names for the refuter, plus the reopen-armed knob), the per-lens
agent-call budgets, and the three terminals with their no-requeue close-out rule.
They are still written as literals in `bin/run-build.sh` so this document's own
terminal audit can see them.

**Changed for a project that opts in, and worth knowing.** `review-head` is
written once, after every lens has approved, instead of after the general fix
round — so the head-bound gate below sees drift only from preview QA, which is
what it was for. `repair-count.sh` sees one `review2-run.txt` where the
sequential flow could produce three, which is the honest number: the build was
sent back once. And the saving the old order had is gone — sequentially a
general BLOCK exits before the other two lenses are bought, where in parallel a
refused diff pays for every lens its file names earned, and the box carries
three model sessions where it carried one.

**It ships OFF (`LENSES_PARALLEL` default 0) and is enabled per project.** The
sequential flow — the one every build in this fleet has taken — stays the
default, because nothing about the parallel flow has been exercised against a
real model: no real build has yet produced the `VERDICT-<LENS>` lines the
fan-back parses, and no box has carried three agent sessions and three
concurrent calls on one vendor account. A `harness-sync` that silently switched
every project to that is the change shape this repo keeps writing gates against.
So:

```
env/<project>.env   ->   LENSES_PARALLEL=1
```

`run-build.sh` sources that file itself (`set -a`, near the top) on a watcher
box, and it rides to a pool machine unchanged: `bin/fly-envbundle.sh` copies the
project env file WHOLE into the bundle (`cat env/<project>.env`, not a key
whitelist — the whitelist governs only `global.env`), `bin/fly-pool.sh` pushes it
to `/run/harness-env/<project>.env`, and `fly/builder-runner.sh` sources it
`set -a`. No allowlist entry is needed for this knob or any other project knob.

**project-5 is the pilot.** The default flips only after N real parallel builds
show the per-lens verdict lines parsing and no rate-limit failures out of the
three concurrent calls. Anything that is not exactly `1` — including a typo —
takes the sequential path: the fallback of a knob this new has to be the proven
flow.

`LENSES_PARALLEL=0` is that sequential flow verbatim, including the early exit.
Both paths make the per-lens call through the same function and read the same
per-lens table, so a prompt cannot be edited in one and missed in the other.
`tests/parallel-lenses-test.sh` drives the block with stubbed agents and pins
the overlap, the single fix round, each terminal, the rollback call order, and
that an UNSET variable runs sequentially.

`bin/fly-pool.sh`'s relay list gains `merged-review2.md` and
`harness-suite-fix.txt` for the same reason the head-bound evidence was added to
it: everything downstream reads HUB build dirs, so reasoning left on a pool
machine is reasoning the merge gate and the operator never see.

### The dead gap before the review: the E2E smoke runs BESIDE it (2026-09-14)

Row 30a. Measured on real builds, the pipeline spent between the execute push
and the first lens launch: **2m36s** (project-4 TK-1273), **3m15s** (project-3 TK-131),
**5m01s** (project-3 TK-53). Almost all of it was one stage — the preview E2E smoke
pushing a branch, waiting for Vercel to finish building a preview of it, and
loading routes in a browser. The lenses waited through every second of that
while reading nothing.

Nothing in the review depends on that verdict. The smoke **never blocks** (its
only consequence is the tier demoter at settle time), it **never writes to the
tree**, and the diff it reads is immutable from the execute push until the first
fix round. So under `GATES_PARALLEL=1` — **the default** — it is launched as a
read-only LANE right after the gates that CAN block, and joined before the fix
round:

```
execute push -> tamper | repro | intent     (the three that can BLOCK: still serial, still first)
             -> scope | KIND | semgrep | mined checks   (still serial — see below)
             -> [ E2E lane ]  ||  [ harness suite -> the review lenses ]
             -> JOIN -> fix round -> rebase -> tier -> PR
```

**What stays serial, and why each one does.** The rule is not "everything that
can run at once should": three of the four stages this could have moved cost
*milliseconds*, and moving them would take the reviewer's evidence away for
nothing. Measured on a real project-5 tree, 2026-09-14:

| stage | cost | serial because |
|---|---|---|
| test-tamper / reproduction / intent | — | they can end the build in `REVIEW_BLOCKED`. A diff about to be refused must never buy a preview deployment, and the lane is only legal because the diff above it is immutable |
| scope gate | **0.002 s** | its counts are the reviewer's scope evidence, and `GATES_NOTE` is read by `REVIEW_PROMPT` and nothing else — a note that lands after the lenses launch is a note no lens ever reads |
| size threshold | **0.007 s** | same |
| mined checks | **0.028 s** | its HIT list is evidence the reviewer ADJUDICATES; deferring it moves those hits from the lens prompt to the fix round, which is a worse review for no time saved |
| semgrep | ≤ 300 s, usually ~20 s | `REVIEW_PROMPT` hands the reviewer `$BUILD/semgrep.txt` BY PATH. A scan still writing that file while a lens reads it is a half-written file presented as evidence |
| the repo suite (`harness-suite.txt`) | minutes | it is the ground truth the review prompt tells the reviewer to read FIRST. It has to be complete before a lens opens it |
| the pre-PR rebase | up to 900 s of `tsc` | it REWRITES the worktree. Nothing that reads the tree may run beside it — which is why the backstop join sits on the line above it |

**Where the join is, and why there.** `GATES_JOIN` is reached from three places
and is idempotent, so only the first pays the wait: the sequential lens path
(after that lens's review, before its fix round), the parallel lens path (after
every lens has read the diff, before the merged fix round), and a backstop
immediately after the block, for a build whose lenses all hit their checkpoint
and touched neither. It **waits on the lane's pid, never a bare `wait`** — the
same reason the lens block spells out: this shell owns `job_beat_start`'s
heartbeat child, which never exits.

**And the wait is CAPPED.** `E2E_JOIN_MAX_S` (default 600 s, `0` = uncapped)
bounds it, because "joined before the fix round" must not quietly become "the
fix round waits for Vercel". Past the cap the build moves on with no verdict and
the note says `STILL RUNNING at the join cap`, which nothing downstream can read
as a pass. The answer is collected later: `E2E_LATE_SETTLE`, one line above the
tier demoter, settles whatever the lane produced in the meantime — a late FAIL
demotes the build to tier 2 exactly as an on-time one does, and gets a PR
comment naming the sha the smoke drove and the head the branch is on now. A lane
that still has no answer by then is stopped — its child first, so the smoke
cannot finish later and write over the record — and recorded as a SKIP.

A lane that lands INSIDE the cap produces the same records in the same order as
it always did. Not quite the same clock: the bounded wait polls `kill -0` every
2 s instead of blocking in `wait`, so the join can be up to 2 s later than
before.

**Nothing UI-less pays for any of this.** The stage is path-gated by
`bin/lib/e2e-ui-paths.sh` BEFORE the push: a diff that cannot change a rendered
route pushes no branch, waits for no preview and drives no browser. `E2E_PATHS`
replaces the default glob list per project.

**The findings ride into the fix round the lenses already share.** A failed
smoke is the one answer this lane has that somebody must act on. Under the old
order it reached the reviewer's prompt; under this one it reaches the session
that is about to edit the code, appended to the merged fix prompt (and, in the
sequential flow, to the per-lens one). A smoke that passed, skipped or could not
run adds nothing there — it is already in the tier and the record.

**What the reviewer loses, stated rather than hidden.** Under the old order a
lens could read `E2E SMOKE: FAILED` and BLOCK on it. It cannot now, because the
verdict does not exist yet. Two things stand in its place: the prompt SAYS the
smoke is running, that its absence is not a pass, and not to wait for it; and
every mechanical consequence is unchanged — `E2E_VERDICT` still reaches the
evidence block and still forces tier 2 on a failure, through the same variable
in the same parent shell. No terminal moved: this lane could not write one
before and cannot write one now.

**`GATES_PARALLEL=0` is today's order verbatim** — the smoke runs to completion
in front of the lenses, its real note is in `REVIEW_PROMPT`, and nothing is
appended to any fix prompt. The switch is read in the shapes people write in an
env file (`1|true|yes|on` / `0|false|no|off`) with one difference from
`INTENT_GATE_ENFORCE` and its siblings: it **defaults ON**, so an unrecognised
value falls back to ON and alerts. The fallback of a knob is its documented
default, and silently taking the old path on a typo would be a fleet that
believes it is saving minutes it is not.

Unchanged on purpose, and asserted: every artifact name (`e2e.md`,
`semgrep.txt`, `checks.txt`, `scope-gate.txt`), the `E2E: PASS|FAIL|SKIP` last
line `bin/merge-sweep.sh` refuses to merge over, every terminal, and the order
in which the lens verdicts are adjudicated. The lane's one new file is
`$BUILD/e2e-rc`, which exists because a background subshell cannot hand its
caller a variable; it is written LAST, so a lane killed mid-flight leaves no
file and that reads as "could not run", never as a verdict nobody reached.

### STAGE-TIMING: every section says how long it took (2026-09-14)

A reorder sold on measured minutes owes a way to see whether it delivered them.
Each section now writes one line to `pipeline.log`:

```
STAGE-TIMING <stage> start=<epoch> end=<epoch> secs=<n>
```

for `kind`, `gates`, `gates.tamper`, `gates.repro`, `gates.intent`,
`gates.scope`, `semgrep`, `checks`, `suite`, `e2e`, `lenses`, `suite-fix`,
`rebase`, `tier`, `pr-open`, `qa`, `suite-head` and `settle`. The four `gates.*`
lines are the sub-steps INSIDE `gates`, so a four-minute gate stage now says
which gate spent them; the three `suite*` lines are the three phases of
`HARNESS_SUITE_RUN` (`lenses`, `fix`, `head`). No global "current stage"
variable: the caller holds its own `t0`, so nested and overlapping stages (the
lane runs INSIDE the lens stage) record honestly instead of clobbering each
other.

`STAGE_TIMING=0` silences it. It is a **separate knob from `GATES_PARALLEL` on
purpose**: the timing is what proves or disproves the reorder, so turning the
reorder off must not also blind the comparison. Both set together is today's
`pipeline.log` byte for byte.

**Box-side test selection (the `suite*` rows).** `HARNESS_SUITE_RUN <outfile>
<phase>` is the one place this harness runs the repo's own suite. It writes
`$BUILD/harness-suite.txt` (phase `lenses`), `harness-suite-fix.txt` (`fix`) or
`harness-suite-head.txt` (`head`), and the FIRST line of that file is
`HARNESS_SUITE: <mode> — npm run <script>`, where the mode is either `selected
<n> of the suite` or `full (<reason>)`. The same mode string lands in
`pipeline.log` as `HARNESS-VERIFY <phase> (npm run <script>) <mode>`, written
from the same variable, so the record in the build dir and the record in the log
cannot disagree. `HARNESS_EXIT: <rc>` is appended last, after the run returns
and unpiped, so 124 (timeout) and 127 (no npm) land as the numbers they are; a
repo with no test script is recorded as `HARNESS_EXIT: no-test-script` and never
read as green. Which tests run is decided by `bin/lib/test-select.sh <repo>
<base> <head>`, whose stdout is kept at `$BUILD/test-select-<phase>.txt` and
stderr at `$BUILD/test-select-<phase>.err`. Only rc 0 with a non-empty list
narrows the run. A selector that is missing (rc 127 during a harness-sync
window), crashes, or declines on purpose (rc 2 with `FULL: <reason>`, rc 3 with
`UNAVAILABLE: <reason>`) falls back to the whole suite and carries its reason
into the mode string, so a degraded run can never be read as a selected one. The
shipped selector is still a stub that answers `FULL: selector not implemented`
for every diff, so today every one of these runs is a full one.

`TEST_SELECT` is the operator knob. It takes `1|true|yes|on` or
`0|false|no|off`; any other value is treated as OFF and writes one ALERTS line,
so a typo in an env file cannot quietly turn selection on. Unset, it defaults ON
only for a GitHub-Issues project (fleet.conf board prefix `-`) whose checkout
carries `tests/impact-map.json`, `tests/static-guards.txt` or
`tests/static-guards/`, and OFF for everything else. `env/<project>.env` is
sourced after `env/global.env`, so a per-project value wins over the fleet one.
The resolution is logged the first time a build runs the suite, as `TEST-SELECT
effective=<0|1> (<why>)`.

This is also the honest answer to the SECOND gap that was reported — "~10
minutes of post-review size/scope work". It is not size or scope work:
`bin/size-scope.sh --diff` is **0.16 s** on a real project-5 tree,
`bin/size-threshold.sh` 0.007 s and `bin/scope-gate.sh` 0.002 s, all measured
before anything here was touched. Backgrounding a 0.16 s measurement would have
bought nothing and put a git read next to the rebase that rewrites the worktree.
Whatever holds those minutes is one of `rebase`, `pr-open`, `qa` or `settle`,
and the lines above now name it on the next real build — which is the input the
next pass needs, instead of a second lane aimed at the two scripts whose names
happened to be nearest.

### Head-bound approval (the tier demoters, SDLC item 1, 2026-09-06)

The tier a build settles at is not a stage, so the demoters have no rows of their
own here — but one of them decides whether transition 41 can fire at all, and it
is about the SHA rather than about the build.

`review-head` is written once, after every lens has approved. Under
`LENSES_PARALLEL=0` that is after the general review and its fix round, and the
security fix round, the refuter fix round and the preview-QA fix round all commit
after it without re-running the suite or the general reviewer; under the parallel
default the merged fix round commits *before* the line is written, so the only
mover left after it is preview QA. Either way, before the tier settles the
pipeline compares HEAD to `review-head` (the `head-bound approval` block in
`bin/run-build.sh`): a moved head buys a re-run of the repo suite plus ONE
general re-review, and APPROVE rebinds the approval to that head. Anything else
forces tier 2 and says so in RESULT.

**Who rebinds and who does not.** Four movers touch a branch head after the
approval, and the rule is whether the code on the new head is code a reviewer
already read:

| mover | rebinds? | why |
|---|---|---|
| `run-build.sh` pre-PR rebase | yes | the reviewed tree onto a newer base, typechecked. Mapped across by the reviewed head's *distance* from the old head — a fix round already commits above it, so matching on equality alone orphaned the sha, and the gate then counted main's own merged history as this build's drift |
| `rebase-train.sh` verified push | yes, unless the BH-5791 caller check of the rebased head finds a gone or unexplained caller, or could not run (BH-6718) | union-resolved to two deterministic conflict classes, typechecked against main's baseline, unit-tested. A train that pushed without rebinding would hand the sweep a mismatch on every PR it fixed — the starvation class the train exists to kill |
| the merge queue's own rebase | yes | same shape, same lane, typecheck-gated before the force-push |
| fix rounds (the merged lens round under `LENSES_PARALLEL=1`) | yes | it is followed by a suite re-run and a re-review inside the lens block itself, and `review-head` is written after that — so the gate sees no drift because there is none |
| fix rounds (security / refuter under `LENSES_PARALLEL=0`, and preview QA in either mode) | no | that is the code nobody read; it is what the gate exists to catch |
| `lander.sh` conflict resolution | no | agent-*written* code. A head-bound PR skips the lander entirely rather than spending a model call on a head the next pass would block anyway |

The two ledger-side rebinds go through `job_verdict_rebind` in
`bin/jobs-client.sh`, which re-puts the verdict artifact with the rest of its
detail (tier, provenance, record, note) intact. It **moves a claim, never makes
one**: a row with no `reviewed_sha` returns rc 2 and is left alone, so a train
run cannot gate a build that predates this feature.

The settled sha rides into the verdict artifact as `reviewed_sha`, and both merge
paths refuse a PR whose `headRefOid` differs from it. The per-box queue checks on
BOTH of its landing paths — the union merge train and the serial loop — and moves
the entry aside. The hub's sweep parks the PR and alerts once per head; it does
**not** ledger the park, because a head-bound park is reversible (a human
re-review, a train rebind, or the kill switch all undo it) and a ledger row would
mark it handled forever.

Absence is never a mismatch: a verdict row without a reviewed sha, or a build
record without a `reviewed-sha` file, leaves every one of those paths behaving
exactly as it did. The fallback file is `reviewed-sha`, written by the gate
itself — deliberately not `review-head`, which the old pipeline wrote at
general-review time and then let fix rounds commit past, so it never meant "this
is what merges".

Switches: `HEADBOUND_REREVIEW=0` skips the re-review and goes straight to the
demotion; `HEADBOUND_ENFORCE=0` is the warn-only kill switch, and all four
scripts read the same name.

### The evidence block (SDLC item 2, 2026-09-06)

Transitions 40-43 all end with a PR a human may have to read. What that human
used to get for "verification evidence" was `validate.txt (4812B)` — a byte
count of a file only the build box can open.

`bin/evidence-summary.sh` renders the facts instead, deterministically and with
no model call: the repo suite's own `HARNESS_EXIT`, each mechanical gate's
verdict, the QA verdict with screens claimed against screenshots counted ON
DISK, the declared INTENT line, which fix rounds fired, planned-vs-changed
files, and the tier the build settled at with the reason. It reads only files
the pipeline already wrote (`gates.json` and `changed-files.txt` are written at
PR time for exactly this), so an operator can re-render an archived record and
get the same block.

It renders TWICE and that is the point: at PR-open the tier is not settled (QA,
the E2E / red / VALIDATE / reopen demoters and the head-bound gate all run
after), so the first block says so, and the settle pass rewrites the body with
the real one. The same render lands in `<record>/evidence.md` (the file
fallback) and, through `job_evidence_put`, as the `evidence` artifact row — one
render, three readers, no way for them to disagree. `EVIDENCE_BLOCK=0` is the
kill switch: no block, no file, no row, everything else byte-identical, and
`EVIDENCE_MAX_UNPLANNED` (default 8) bounds how many unplanned paths the files
row names before it says "+N more" — the counts themselves are never truncated.

**The acceptance-claim verdicts (#527, 2026-09-17).** Two blocks in the script
carry them. `# >>> evidence verdicts` sits INSIDE the review-lens block, right
after HARNESS-VERIFY: it sources `bin/lib/evidence.sh`, calls `evidence_score`
once, tees the scorer's stdout to `<record>/evidence-verdicts.txt` and appends
the `CLAIM n: <CONFIRMED|REFUTED|INCONCLUSIVE>` rows to `GATES_NOTE`, so they
ride into `REVIEW_PROMPT` beside the mechanical gates — where the prompt now
tells the reviewer to open each CONFIRMED row's artifact and treat a mismatch as
a verification-integrity finding. `# >>> evidence demoter` sits after
`# <<< head-bound approval` and before `# >>> evidence settle`: it re-scores the
head that actually merges (fix rounds commit past the reviewed one, same reason
the scope gate re-scores there), writes one
`EVIDENCE confirmed=C refuted=R inconclusive=I total=T` line to `pipeline.log`,
and when `refuted + inconclusive > 0` notes that in `QA_NOTE`. The execute
prompt asks the session for `<record>/evidence-proposed.txt` — it PROPOSES a
verdict per acceptance claim, the scorer decides. Three files per record, then:
`evidence-proposed.txt` (model-written), `evidence-verdicts.txt` (the scorer's
stdout, what the reviewer read) and `evidence.json` (the structured counts,
written tmp+mv). `EVIDENCE_GATE_ENFORCE` is the knob, read exactly like
`SCOPE_GATE_ENFORCE` (`1|true|yes|on` arms it; anything unrecognised is OFF plus
one ALERTS line) and warn-first at the default `0`: the note is written and the
tier is untouched until it is armed in `env/global.env`. Both blocks FAIL OPEN
and say which way — no `bin/lib/evidence.sh` (a box mid-sync) logs
`could not run (lib absent)`, a scorer that cannot run (no `jq`, unwritable
record dir) logs its own line and leaves no `evidence.json`, and `not-recorded`
counts never demote. An unscored build is not a build that passed, and neither
block can exit, write a RESULT or block a build at any setting. Stated plainly:
as of this wiring `evidence_score` is the contract's INTERFACE — it writes the
zero-claim `evidence.json` and says so — so every build scores `total=0` and
nothing is demoted until the scorer slice of #527 lands. The wiring is what is
shipped here; the verdicts it carries are only as good as that scorer.

No terminal and no transition changes here; the PR body is the payload of
transitions 40-43, not a state of its own.

### Repair cycles as a risk signal (SDLC item 3, 2026-09-06)

Another tier demoter with no row of its own, for the same reason as the
head-bound gate: the tier a build settles at is not a stage. This one is not
about the diff or the head at all — it is about how many times this build had to
be sent back before it got here.

`bin/repair-count.sh` counts six facts out of the build dir: the four re-review
runs a fix round produces (`review2-run.txt`, `security-review2-run.txt`,
`refute-review2-run.txt`, `qa2-run.txt`) and the two mechanical-gate codes that
are recorded rather than blocking (`tamper=2`, a deletion the diff justified;
`repro=4`, tests red on the head they arrived on). Presence, not size: a
re-review session that died still means code went back for repair.

Transitions 31, 36-38 and the QA fix round already exist above; what is new is
that the pipeline now REMEMBERS how many of them fired. On a project that has
opted into `LENSES_PARALLEL=1` the three lens fix rounds are one merged round
writing a single `review2-run.txt`, so the ceiling there is 2 (the merged round
and QA) rather than 4 — the count is still "how many times this build was sent
back", which is what the threshold means, but `REPAIR_TIER_MAX` is calibrated
against the default flow and a mixed fleet will read low for the opted-in
projects until the default flips. The count rides into
three places at settle time — the verdict artifact (`repairs`, always written,
including as 0), `logs/findings.log` (an optional `repairs=` field on every row a
lens produced — the count as of that lens's HARVEST, not at settle time, so the
QA round appears only in the verdict and outcome rows: `bin/findings-log.sh`
runs before preview QA), and, through `bin/outcome-metrics.sh`, the
`outcome_metrics` row for a PR that later gets reverted or reopened. That last hop is the point:
`bin/review-tighten.sh` can then tune the threshold from measured outcomes
instead of from the guess it ships with.

**It warns before it demotes.** `REPAIR_TIER_MAX=2` is the threshold and
`REPAIR_TIER_ENFORCE=0` is the shipped default, so today a build at or above it
gets a note in `QA_NOTE` (and therefore in RESULT, the PR's evidence block and
the verdict row) and keeps its tier. `REPAIR_TIER_ENFORCE=1` arms the demotion to
tier 2. Deliberate: the number 2 is a guess until the correlation above has data,
and a guess that withholds tier-1 merges costs throughput on no evidence — where
the same guess costs nothing at all as a recorded measurement.

No terminal and no transition changes here.

### Scope gate: the diff against the plan (SDLC item 4, 2026-09-06)

`prompts/plan-contract.md` has always carried the bounce rule — "needing a file
outside scope = stop and report, never improvise" — as prose nothing checked.
`bin/scope-gate.sh` checks it: `git diff --name-only` against the
`planned-files.txt` that `bin/planned-files.sh` wrote at PLAN time, before an
edit was made.

It runs in the mechanical-gates block, after the intent gate, and like that gate
it has **no row of its own in the table above** — because neither can change the
next stage. Whatever it finds, the diff goes to SEMGREP and then to REVIEW; the
counts ride into `GATES_NOTE` as evidence for the reviewer, and the only
consequence is a tier demotion, which is not a stage.

Every unplanned file is classified, first match wins, and the classes exist
because most unplanned files are fine:

| class | what it is | consequence |
|---|---|---|
| `protected` | unplanned AND in the set where a surprise is expensive: `.github/workflows/`, package manifests and lockfiles (except under a test/fixture directory, where a manifest is a fixture), `prisma/`, env files, and `scripts/migrations/` **only when the plan named no migration** | the tier demoter; reported as a SUBSET of `foreign`, never a fifth bucket |
| `test` | a test file | counted and named, nothing more — this is the shape the repro gate exists to encourage, and plans rarely name tests in advance |
| `spec` | docs, markdown, README | counted and named — "update the docs in the same PR" is a standing rule |
| `adjacent` | an unplanned file in a directory the plan DID name | counted and named — `planned-files.sh` scrapes paths out of markdown, so a sibling is usually the plan being imprecise |
| `foreign` | a file in a part of the repo the plan never mentioned | counted and named; the number a reviewer should actually read, since work nobody asked for is the scope-creep fraud class |

`planned-files.sh` keeps only paths under
`src|prisma|scripts|e2e|tests|app|lib|components|pages|public|docs|content|middleware`,
so `package.json`, `pnpm-lock.yaml`, `.github/workflows/*.yml` and `.env*` never
reach `planned-files.txt` — no matter what the plan says. Widening that scraper
would be worse than the bug: `bin/conflict-check.sh` DEFERS a build whose
planned files overlap a live sibling's, and every build that mentions a manifest
would be sent back to the queue behind every other one. So the gate re-scrapes `plan.md` for those
families alone and adds them to its own plan set. Without it, three of the five
protected families could never test as *planned*, "unplanned AND protected"
would collapse to "protected", and a dependency or CI ticket would be demoted —
and told "the plan named none of them" — for doing what it was asked.

That re-scrape is a **positive-mention reader**, and has to be:
`prompts/plan-contract.md` REQUIRES every sub-ticket to carry non-goals, so
"non-goals: do not modify `package.json` or the CI workflows" is the shape the
contract asks for. A context-free grep read that sentence as the plan *naming*
those files and reported `in-scope` for the exact class the gate exists to
catch. So SENTENCES that read as an exclusion (`non-goals`, `do not`, `never`,
`must not`, `not touched`, `out of scope`, …) are dropped before the scrape —
sentences, not lines, because "`package.json` — append the runner. Never delete
an entry" is one line that plans the manifest, and the hard-wrapped
continuation lines a plan writes are folded back onto the line they continue
first, so a non-goal that wraps still governs the paths on its own second and
third lines. The exclusion words are matched as WORDS: "whenever" is not
"never". Matches are
anchored at both ends, so `mypackage.json` is not the manifest and
`.env-loader.js` is not `.env`; and a bare `.github/workflows` with no filename
is NOT a scope, because a directory mention would plan every workflow at once.
The same anchoring runs in the classifier: `.env` and `.env.production` are
`protected`, `.envrc` and `.environment.ts` are ordinary code.

The evidence block's "files" row counts planned-vs-changed with the same
matcher and is deliberately a separate implementation: it renders from
`changed-files.txt` with no repo access, so an archived record still produces
the same block months later. The two counts legitimately differ by two things —
the spec artifact (the gate excludes `.harness/specs/` from `changed`,
the block counts every line of `changed-files.txt`) and the `plan.md` re-scrape
above, which only the gate is positioned to read. The fix rounds' own files used
to be a third difference; the settle-time re-score below closed it. The MATCHER — "listed, or
under a listed directory" — is what must not drift.

`SCOPE_VERDICT:` is `in-scope` (rc 0), `unplanned` (rc 2), `protected` (rc 1) or
`unavailable` (rc 3). The gate NEVER blocks: rc 3 is the honest answer when the
plan named no files at all, when the base will not resolve, when there is no
diff, or when the diff carries nothing but the pipeline's own `.harness/specs/`
commit — every changed file would score as unplanned in the first case, and in
the last there is no builder file to judge at all. Demoting a build for the
PLANNER's silence is the false-reason failure the other gates already learned,
and `changed=0` is not a pass. A gate that could not run is reported as not-run,
never as in-scope.

**The verdict describes the head that merges.** The gate runs before SEMGREP,
and the review, security, refutation and QA fix rounds all commit after it. So
it writes a `SCOPE_HEAD:` line naming the sha it scored, and the settle-time
demoter re-runs it when `git rev-parse HEAD` no longer matches — one
`git diff --name-only`, no model call. Without that, a fix round adding
`package.json` was invisible to the demoter and the ledger's `scope` field rode
to the merge sweep describing a diff that no longer existed. Same principle as
item 1's head-bound approval. A report with no `SCOPE_HEAD:` line (any record
written before this shipped) is read as-is and never re-scored.

**It warns before it demotes.** `SCOPE_GATE_ENFORCE=0` is the shipped default:
the classification reaches the reviewer, the note reaches `QA_NOTE` (and so
RESULT, the PR's evidence block and the verdict row), the tier is untouched.
`SCOPE_GATE_ENFORCE=1` in `env/global.env` arms the demotion to tier 2 for the
`protected` verdict only. `SCOPE_GATE_MAX_LIST=12` bounds the listing, never the
counts. `EVIDENCE_GATE_ENFORCE` is its sibling — same case arms, same
warn-first default, same "unrecognised value is OFF plus one ALERTS line" —
for the acceptance-claim verdicts described under the evidence block above. The verdict and its counts line ride into the ledger's verdict artifact
as `scope` / `scope_counts` (surfaced by `/api/verdict` and `job_pr_facts`), with
`$BUILD/scope-gate.txt` as the documented file fallback; absence there means NOT
MEASURED, which is never the same fact as in-scope.

No terminal and no transition changes here.

### The plan gate that refuses (SDLC item 5, 2026-09-06)

Unlike the three sections above this one, item 5 adds real rows: `PLAN_MALFORMED`
is a new terminal (transition 20b) and the resume path grows a second
`PLAN_STALE` exit (20a). Both are about the PLAN stage refusing work that used
to go through with a log line.

**Every task, not the file.** Since 2026-08-14 the plan prompt has demanded two
lines per task — `VALIDATE:` (the exact command that proves the task is done)
and `SATISFIES:` (the ticket criterion it delivers). What checked it was
`grep -q VALIDATE && grep -q SATISFIES` over the whole file, so one traced task
in a ten-task plan passed, and a plan that failed got one repair pass and then
went to EXECUTE anyway. `bin/plan-gate.sh` scores each task block and
`PLAN_TRACE:` is `ok` / `untraced` / `unavailable`.

That old grep was also wrong in a way worth recording: `^[[:space:]]*VALIDATE:`
does not match `- VALIDATE:`, the bullet form 27 of the last 150 plans use. It
spent a repair session on each of them. The floor now lives inside the gate,
with one definition of what a trace line looks like.

**It refuses, where every other new gate warns first.** `PLAN_GATE_ENFORCE=1` is
the shipped default, `PLAN_GATE_ENFORCE=0` is the kill switch, and
`PLAN_GATE_MAX_LIST=8` bounds how many offending blocks the report names (never
the counts). Two reasons
for the exception: the SDLC review specified this one as the gate that refuses,
and the cost of being wrong is one re-plan against a whole execute + review wave
spent on an untraced plan. It was measured before it was armed — of the 637
plans on this box, every plan written after the contract shipped on 2026-08-14
passes, and every refusal is a plan that predates it. The parser is forgiving on
purpose in five documented places (fences, the contract's own sections, mentions
that are not trace lines, the bare keyword once a block IS a task, and "cannot
see any tasks" reported as `unavailable` rather than as a fault).

**No repair pass, and no terminal, for a missing `## Size` heading (BH-5292,
2026-10-07).** BH-657 bought one planner session here so a plan with no heading
would not die at row 20c. Since BH-5292 a missing heading is a report, not a
gate: `bin/size-gate.sh` prints `SIZE_GATE_WARNING`, estimates the size from the
plan's file list (`SIZE_ESTIMATED`, verdict `estimated`), and the build goes on.
The estimate splits only past 2x the threshold, because the file list is a
deliberate over-listing (BH-612). The repair session is gone with the terminal:
a model call to write a number nobody is blocked on is pure spend. See
`docs/GATES-VS-REPORTS.md`.

**Requeued once, then held — and the requeue is the SWEEP's job, not a wish.**
The first `PLAN_MALFORMED` for a ticket ends with `requeued once`: nothing is
posted to the board, and the results sweep that closes the dir out relaunches
the build (re-verify the thread, the ordinary detached launch if a slot is
free; the `READY-QUEUE.log` line if not). That relaunch had to be spelled out in
the SOPs, because nothing else would have done it: `run-build.sh` writes the
RESULT and exits, and `run-triage.sh` scopes its ticks off board movement or
RESULT dirs — a refused plan moves neither once the dir is `COMMENTED`, so the
"requeue" would have been a wait for the daily unscoped sweep. `PLAN_STALE`
gets away with softer wording only because the thing that made it stale IS a
board change the next tick diffs. A second one ends with `held for a human`
plus an ALERTS line. The
counter is per TICKET and lives in the D1 ledger (kind `plan_malformed`, key
`<project> <key>`) with `state/plan-malformed.txt` as the offline fallback,
because the requeue is a NEW build in a new dir — a marker in the build dir
could never be read by the attempt that needs it. It is deliberately never
cleared: a ticket that has produced two untraced plans wants a human, not a
third session.

**And the hold is now a GATE, not a label (row 20d, BH-657).** Until 2026-09-17
nothing read those rows BEFORE a plan was bought, so "held for a human" was a
RESULT string and a ledger row and nothing else: the sweep's relaunch, an unscoped
tick that still saw the handoff label, and `bin/blocked-resolver.sh`'s
rebuild-fresh rung each paid for a full Fable plan that died at the same gate.
HC-10 bought three of them 30 minutes apart — the triage cadence, not the
resolver's 90-minute floor, which is what proved the choke point was
`run-build.sh` itself rather than one launcher. The fresh-plan branch
(`# >>> plan malformed hold` inside `# >>> plan launch`) now reads the ticket's
last status first: `held` or `skipped` and the launch is refused before the
`PLAN (` line is even written — one `pipeline.log` line, **no plan session
spent**, `RESULT "PLAN_MALFORMED held for a human: …"` and exit 4, the same code
the held terminal and `PLAN_BLOCKED` use, so every consumer still reads it as
parked. The cap of 2 needs no counter: the terminal writes `requeued` then `held`,
and the guard refuses the third launch and every one after it. Exactly ONE ALERTS
line per held ticket, on the `held` → `skipped` transition, and it names the
ticket and the artifact the planner failed at (rows carry it in field 5 now;
legacy four-field rows read as `no artifact recorded`). Later skips are log-only.
Fail-open on spend: an unreadable file, a ledger outage (rc 1), an honest "no row"
(rc 2) or an unrecognised status all launch, because a wrong hold costs a ticket
that never ships while a wrong launch costs one plan session. Which half is the
record depends on the `no-twin-ledgers` flag (BH-1036): with it DOWN the box's
own file is its word and the ledger is asked only when the file has no row at
all — a local `requeued` row outranks a ledger `held`; with it UP the order
flips, the ROW is the record and the file is the cache behind it, so a wiped
`state/` cannot un-hold a ticket two malformed plans already parked.

**Releasing a held ticket** (the state has to be one an operator can leave, and
this is it — last row wins, so a later `held` holds again). Write BOTH halves:
the file line alone releases nothing once the flag is up, and the row alone is
not what a box with the flag down reads.

```sh
echo "<project> <KEY> released $(date -u +%Y-%m-%dT%H:%M:%SZ)" >> /root/harness/state/plan-malformed.txt
# and — the half that actually releases it with no-twin-ledgers up, and what
# makes another box or a Fly machine agree either way:
job_ledger_put plan_malformed "<project> <KEY>" released "released by <who>, <why>"
```

The resolver keeps re-offering a held ticket every ≥90 minutes until
`MAX_REBUILDS`, each attempt landing on the free skip and then recording
ABANDONED — bounded, no model call, and the the operator 2026-09-13 rule that nothing in
this harness waits on a human review.

**The resume half.** `FP_BEFORE` used to live only in the process that computed
it, so the checkpoint that reuses `plan.md` said in its own comment that the
stale gate "cannot re-arm". It is now written to `$BUILD/ticket-fp` next to the
planner, on every re-plan, and a resume compares the thread against THAT — the
TK-143 #517 window (a comment superseded ten minutes into planning) widened to
however long the build was dead. The snapshot describes THE PLAN, not the
directory: a build that died mid-PLAN re-plans against the current thread and
re-snapshots it, so the next resume is not failed as stale against a thread that
never moved. A REUSE never rewrites it. Absence is never a mismatch: a record
from before this shipped has no `ticket-fp` and behaves exactly as it did, and a
boardless project or a board outage writes no snapshot at all rather than a
stale one. "Moved" means the fingerprint (`lastActivityAt|updatedAt|turnChangedAt|comment
count`) differs, and that INCLUDES the harness's own writes: a sweep moving the
status, a triage-posted comment or a turn flip all bump `updatedAt`, and across
a resume window measured in hours that is likely. Wrong in the safe direction —
the cost is one deferral and a re-plan from current state — but if you are
asking "why did my resume defer when nobody touched the ticket", this is why.

**The ledger learns the verdict even when nothing is wrong.** A `PLAN_MALFORMED`
build never reaches the verdict artifact — it stops before the PR — so plan time
is the only time this fact exists, and a row written only on failure would make
"no row" mean both "clean" and "old box". Every build with a job row writes a
`plan_gate` artifact (verdict, task count, untraced count) through
`job_artifact_put`; `$BUILD/plan-gate.txt` is the documented file fallback.

### Every stop has an owner (SDLC item 6, 2026-09-06)

The 232 abandoned rows were builds that stopped without saying so. Item 6 is the
same audit applied to the stops this table already knew about but nobody was
told to close: four exits that vanished without a RESULT (F1-F4), five terminals
the sweep SOPs had no rule for (F5), and one timeout that quietly did the
opposite of what the wait was built for.

**The four silent exits now name themselves.** F2 writes `BUILD_REFUSED` (a
missing `/root/repos/<project>` is not "not now" — every tick repeats it until a
human loads the project onto the box), F3 and F4 write `BUILD_DEFERRED` (a
branch or a fetch held by something transient; F4 is retried by the next triage
tick, and F3 only happens on a resume, so its retrier is `bin/lib/resume-dead.sh`
refunding the attempt — a remote branch deleted with no PR will cycle refunds up
to `TOTAL_CAP` and then close `BUILD_DEAD`), and all three
now exit 3 like every other deferral and refusal in the script rather than the
bare `exit 1` they used to. F1 cannot write a RESULT — the directory it was told
to re-enter IS `$BUILD` — so it writes the ALERTS line instead, which is the
only owner a stop with no build dir can have.

**The five orphan terminals have close-out rules.** `SECURITY_BLOCKED`,
`REFUTE_BLOCKED`, `BUILD_REFUSED`, `PLAN_STALE` and `QUEUED_FLY` are now in the
results-sweep section of every SOP (`prompts/TEMPLATE.md`, `TEMPLATE-GH.md` and
each `prompts/<project>.md`), with the two that matter most carrying an ALERTS
line plus a "held for a human read" comment and NO requeue: a lens refusing a
diff the general review approved is exactly the case where relaunching the build
is the wrong reflex. `PLAN_STALE` closes quietly (the next tick re-plans it),
`QUEUED_FLY` closes quietly (it is not a stop — the Fly builder is still running
and writes its own RESULT), and `BUILD_REFUSED` gets an ALERTS line with no
board comment, because the client has nothing to read about our checkout. The
same pass closed the two gaps beside them: `DECOMPOSED` / `DECOMPOSE_FAILED` in
the seven SOPs that never had them, and `BUILD_DEFERRED` in the one that did
not.

**The 45-minute overlap timeout stops proceeding into the collision.** The wait
exists to kill the union-merge class; at the cap it used to build the same files
concurrently anyway, log one line into the build dir, and leave the PR-time
rebase to find out. It now records the timeout as a fact — `overlap-defer.txt`
and an `overlap_defer` artifact row (verdict `deferred` / `proceeded`, the
conflicting build, seconds waited, the wake condition) — and, when armed, ends
in `BUILD_DEFERRED` whose RESULT line NAMES what it is waiting for: the sibling
releasing its claim (a RESULT, or the 4h age-out of `state/claims/<project>/`)
and the next triage tick re-offering the ticket. LESSONS item 2 of the scaling
week — every skip path enumerates its wake reasons — is the rule this was
missing.

Switches: `OVERLAP_DEFER_ENFORCE=1` is the shipped default (the timeout defers)
and `=0` is the kill switch (record the timeout, proceed exactly as before); an
unrecognized value is treated as ON and alerts. `OVERLAP_WAIT_SECS=0` is the cap
since 2026-09-13 (the operator: "we never lock and serialize" — a build may not wait in
line behind another build, so the first failing conflict check defers), and a
non-numeric value alerts and falls back to 0 rather than removing the cap. A box
that would rather pay the wait than the re-plan sets a positive number. Refuse-first and not warn-first because the union-merge class this wait
exists to kill is the more expensive side of the trade: a deferral costs a fresh
PLAN session on the requeue, proceeding costs whatever the concurrent edit does
to the merge. Disarm it with `=0` if the recorded `deferred` rows show the
requeue is the dearer half.

### KIND: the bug flow (SDLC item 7, 2026-09-06)

Every row in the table above describes ONE pipeline, and until this item there
was only one: a copy tweak, a schema migration and a defect all got the same
plan prompt, the same "implement the acceptance tests first" execute prompt, and
the same lens routing. The defect is the one that suffered. What proves a bug
fix is not a feature test — it is a REPRODUCTION that fails on the code as it
stands — and no stage asked for one. TK-44 (a fail-closed 404 read as missing
code, and a replacement route shipped over a working one) and TK-113 (five
pre-existing failures blamed on a PR that did not cause them) are both that gap;
LESSONS item 9, "prove innocence on main", is a bug-flow STEP that had to be
written as doctrine because the pipeline had nowhere to put it.

**No new terminal and no new transition.** KIND changes which PROMPT a stage
sends and which optional lenses run, plus one tier demoter — and a tier is not a
stage, the same reason items 1, 3 and 4 have no rows either. Transitions 17-23
(PLAN), 24-25 (EXECUTE) and 33-38 (the lenses) are the rows this section
qualifies.

**Where the kind comes from, in order.** `bin/kind-gate.sh` reads the board's
own evidence first — a ticket `type` field, a GitHub label, a title PREFIX
(`fix:`, `[bug]`, `chore:`) — from `$BUILD/ticket-meta.json`, which
`run-build.sh` fetches once before PLAN and a resume reuses. That deterministic
hint OUTRANKS the `KIND:` line the planner writes beside `SIZE:`, and the
disagreement is printed rather than resolved silently: a model may not
reclassify its way out of the bug flow, and a reviewer can read the thread and
say who is right. Only the COLON-anchored prefix of a title counts — "Fix the
header copy" is a request about copy, "fix: header overlaps at 375px" is a defect
someone typed as one, and a keyword anywhere in the title would route the first
through the bug flow. The dash and slash separators were tried and dropped for
the same reason ("Fix - header copy" is the copy request again), and `build` and
`data` are off the vocabulary because they are ordinary English about the work
("Build: new client dashboard" is a feature). The title hint is also the one the
plan prompt phrases as a question rather than an instruction: a type field or a
label is the board SAYING the kind, a prefix is the gate reading one off how
somebody typed a sentence. Precedence is unchanged either way — the disagreement
still prints. When neither source speaks, KIND is `unknown`: not-measured, never
`feature`, and every consequence below is skipped exactly as it was before this
shipped.

**What `bug` buys.** The plan must carry a `## Reproduction` section with five
colon-anchored lines — `REPRO:` (the command or test that fails on the code as
it stands), `OBSERVED:`, `EXPECTED:`, `ROOT CAUSE:` with a real `file:line`, and
`BLAST RADIUS:` — and EXECUTE is told to run that command BEFORE its first edit
and save the failure verbatim as `red.txt`, which is exactly the artifact
`bin/repro-gate.sh` (transitions 27-29) re-runs at the merge base. A REPRO that
does not fail today stops for a human instead of being fixed around. The five
labels are deliberately NOT `VALIDATE:`/`SATISFIES:`: `bin/plan-gate.sh` scores
any block carrying those as a task, and a reproduction is evidence about the
defect, not a task that delivers a criterion.

**What `copy` skips**, and the narrowing it ships with. A copy ticket skips the
preview E2E smoke and the reopen-armed extra security lens. It does NOT skip the
lens the DIFF earns: `RISKY` counts files named auth / billing / migration /
webhook, and a diff touching those is not a copy change whatever the board's
label says — the file names are the stronger evidence, so the classification
loses and the disagreement is logged. The E2E skip says in `e2e.md` that it was
skipped BY ROUTING, because a reader must never have to guess whether a SKIP
means "no UI in the diff" or "we chose not to look".

**It warns before it demotes.** `KIND_GATE_ENFORCE=0` is the shipped default:
the classification reaches the planner, the executor, the reviewer's
`GATES_NOTE`, `QA_NOTE` (and so RESULT, the PR's evidence block and the verdict
row), `logs/findings.log` and the ledger — and nothing is withheld. `=1` arms
the two consequences: a bug whose plan carries no complete reproduction demotes
to tier 2, and the copy skips above take effect. The bug flow's EXECUTE prompt
is deliberately NOT behind the flag — adapting how a defect is built withholds
nothing, and a prompt that only fires when a flag is on is a prompt nobody
measures.

**Recorded in three places, one implementation.** `$BUILD/kind.txt` is the file
fallback; a `build_kind` artifact row is written at PLAN time (a build that
stops before the PR never reaches the verdict artifact, and a row written only
for bugs would make "no row" mean both "not a bug" and "old box"); and the
verdict row carries `kind` / `kind_repro` beside `scope` and `repairs`. It is
its OWN artifact kind rather than the `jobs.kind` column, which is a different
vocabulary entirely (`triage | build | fix | qa | migration` — which pipeline
this is, not what the ticket is) — conflating the two would be F6 in a new
place. `bin/findings-log.sh` imports the same gate for its optional `kind=`
field, so "which findings come from bug fixes" is answerable without a second
definition of what a bug is.

### The act-time fence on the non-claude lanes (SDLC item 8, 2026-09-06)

`bin/iron-law-guard.sh` is a Claude Code PreToolUse hook, so it fences claude
sessions and nothing else. `bin/agent-call.sh` runs EXECUTE on **codex** for
project-4 and project-1, with `--dangerously-bypass-approvals-and-sandbox`: on those
two projects the five irreversible families — merging a PR, moving main, prisma
pointed at a live database, a raw client writing prod, a deploy or promote on
Vercel — were PROMPT-ONLY at the exact stage that writes code. The guard's own
header says it is not a sandbox; on those lanes it was not even a guard.

**No new terminal and no new transition.** Nothing here changes what a stage
writes or where it can go, for the same reason items 1, 3, 4 and 7 have no rows:
a refused command fails inside the session, and the session's own outcome
(`EXECUTE_EMPTY`, a review verdict, a `BUILD_DEFERRED`) is unchanged. It is
documented here because the fence sits inside transitions 23-25 and 31-38, and a
reader who finds a blocked command in `logs/findings.log` needs the table to say
where it came from.

**Two mechanisms, ONE classifier.** `bin/lane-shims/` goes on the front of PATH
for the fenced non-claude stages: one shim per binary the classifier knows (`gh`,
`git`, the Vercel CLI, `prisma`, the raw db clients, and the `npx`/`npm`/`pnpm`/
`yarn`/`bun` wrappers that reach the other two), each of which hands the
reconstructed command line to `bin/iron-law-guard.sh` — the same script, the
same payload shape, the same five rules — and then execs the real binary
untouched. A rule added for the claude lane is live on the codex lane the same
hour; there is no second, weaker copy of the iron laws to drift. The finding the
classifier files carries `PATH-shim(<name>)` where the hook writes `PreToolUse`,
and deliberately keeps the SAME `family=actguard-<rule>`: one iron law reached
for by two runners is one recurrence, not two.

**And a pre-push hook, because a PATH shim has a hole.** A shim only sees a
binary invoked by NAME; an absolute path, a python subprocess or a wrapper the
session writes itself all walk past it. `bin/lane-fence.sh hooks-env` installs a
per-repo hooks directory and points git at it through `GIT_CONFIG_*` in the
lane's environment (never a `git config` write to a shared checkout), so git
itself calls the fence on every push however git was reached. It FORWARDS every
hook the repo already had and CHAINS its own pre-push to the repo's — project-4, one
of the two projects this exists for, has a `.husky` pre-push, and a fence that
silently switched a project's own checks off would take more than it gave.

**Switches:** `LANE_FENCE=1` is the shipped default and it REFUSES — item 8 asks
for a fence that denies, and a warn-only iron law is exactly the prose that
already existed. `warn` classifies, files the finding, prints the reason and runs
the command anyway; `0` is the kill switch and the shim directory never reaches
PATH. Those three are the ONLY values — `off` is not a synonym for `0`, because
`bin/agent-call.sh` and the pre-push hook both read anything-but-`0` as armed
and a shim that disagreed would leave a half-disarmed box. An unrecognized value
is treated as 1 and alerts, the same rule as `OVERLAP_DEFER_ENFORCE`.
`IRON_LAW_LANES` picks the fenced stages for both halves, so the two mechanisms
cannot be armed for different lanes.

**The refusal does not leak what it refused.** The hook sees the command as the
model typed it (`"$DATABASE_URL"`); a PATH shim sees argv AFTER the shell
expanded it, so an expanded connection string arrives in the fence's hands and
would otherwise be written to `logs/findings.log` — which `bin/rule-miner.sh`
bundles into a GitHub PR body — and to the `state/lane-fence/` ledger. The shim
redacts userinfo and password flags ONCE, before it classifies and before it
records, so no unredacted path exists. The HOST survives, because the host is
what the classifier decides on.

**It fails open, loudly.** No classifier on the box, no jq, an unreadable
verdict: the command RUNS and one ALERTS line says the lane is unguarded — once
per cause per day, because this shim also stands in front of `npm` and `git` and
a per-command alert would drown the log. Same trade as the hook, same reason: an
inert fence is visible within a tick, a fence that fails closed takes every build
lane on the box down with it. `bin/agent-call.sh` writes the same alert when the
fence is missing from the box entirely, and still runs the stage.

**What it does NOT cover.** The harness's own merge lanes are invoked by path
(`/root/harness/bin/merge-sweep.sh`), and no PATH shim can intercept a path — the
hook catches that shape, the shims cannot. Nothing here is a process sandbox:
`codex --sandbox workspace-write` for EXECUTE is the follow-up the review names,
and until it is evaluated this is a guardrail against reaching for the obvious
command, which is the failure that actually happens. The canary the review asks
for — a real codex call attempting each verb — is a live-run check, not
something `tests/lane-fence-test.sh` can do offline — `tests/lane-fence-canary.sh`
is that live check, opt-in behind `LANE_FENCE_CANARY=1` because it spends a real
codex call, and it SKIPS IN RED rather than passing when codex is absent.

**What the canary actually settled** (hub, 2026-09-06). It reports three tiers,
because they are worth different amounts. (a) MECHANISM: a real codex session's
shell tool does inherit the shim directory ahead of `/usr/bin`, `HARNESS_LANE`
and the `GIT_CONFIG_*` hooks pointer — codex prepends its own vendored dirs, so
the fence is not FIRST on PATH but is reached before any system binary. This is
the part no offline test can see and the part whose failure would void the whole
mechanism silently. (b) REPLAY: the five verbs run in exactly that captured
environment are all refused with exit 2, each files its `family=actguard-*`
finding, and no stub binary is reached — deterministic, no model cooperation
needed. (c) LIVE: codex itself attempting the five. It did, once, refused on all
five through `PATH-shim(gh|git|npx|psql|vercel)`; on other runs the PROSE rules
`agent-call.sh` prepends make the session decline before the fence is reached.
That is the right outcome in production and a useless one here, so the canary
reports INCONCLUSIVE in red rather than calling it either a pass or a fence
failure. Those are three different facts and the log keeps them apart.

**The attempt is a fact.** Every block (deny or warn) appends to
`state/lane-fence/<job-or-ticket>.log` and upserts one `lane_fence` artifact row
on the job — count, lane, mode, which verbs, and the path of that file as the
documented fallback. The DB write is bounded and fail-open: the refusal is
already decided and printed before it is attempted.

### GitHub auth for a build: one resolution, one rollback (2026-09-14)

`bin/run-build.sh` resolves `GH_TOKEN` **once**, immediately after it sources
`env/global.env` and before any stage runs. That one line covers every `gh` call
and every `git push` in the pipeline, because `gh auth setup-git`'s credential
helper answers with `GH_TOKEN` when it is set, so `git` and `gh` read the same
resolution.

```
[ -r "$HARNESS/bin/lib/gh-app-auth.sh" ] && . "$HARNESS/bin/lib/gh-app-auth.sh"
gh_auth_for "$GH_AUTH_SLUG" || true     # slug: REPO_SLUG, else origin's url, else fleet.conf
```

`gh_auth_for` mints a GitHub App **installation token scoped to that one repo** via
`bin/gh-token.sh`, cached under `state/gh-app-tokens/` until 5 minutes before it expires. The
build therefore pushes and opens its PR with a credential that dies in an hour, against a
rate-limit bucket that belongs to the installation instead of to the one PAT the whole fleet
shares. At 4000 builders, 5000 requests/hour shared by everything is the throughput ceiling,
and it is also one never-expiring credential copied onto every machine that ever built.

**No transition changes, and the unarmed path is byte-for-byte today.** `gh_auth_for` returns
1 *without forking a process* when `env/github-app.env` is absent, `GH_APP_TOKENS=0`, or
`flags/gh-app-tokens-off` exists, and `GH_TOKEN` keeps exactly what `global.env` set. The
whole rollback is `touch flags/gh-app-tokens-off`.

**Fly pool builders get their own.** `bin/fly-pool.sh` replaces the `GH_TOKEN=` line in each
machine's env bundle (`bin/fly-envbundle.sh` writes the owning box's PAT there) with a
freshly minted repo-scoped token before pushing the bundle. The line is *replaced*, not
appended, because the builder's `set -a; . global.env` would otherwise take the later value.
A machine that is destroyed leaves behind an hour of one repo, not the fleet's GitHub
identity.

### The builder finishes its own job (transition 43a, 2026-09-14)

A build that ran on a pool machine used to hand its result to the HUB, which
handed it to the owning box, which staged it for a paid session that read the
RESULT out of a text file and posted the client's comment. Three clocks, two
machines, and the hub in the middle of every hop (docs/HUB-THINNING-PLAN.md,
"LANDED: the hub out of the DATA path").

After the tier-1 gate, and **only on a builder**, `run-build.sh` does four
things — none of which can fail the build, all of which say so in `pipeline.log`:

1. `job_result_put` — the terminal facts as the job's final PATCH:
   `{result, pr_url, sha, tier, verdict, cost_usd}`, composed by
   `bin/lib/builder-direct.sh:bd_facts` from the record itself. The EXIT trap
   still closes the row's **status**; it reads `BUILDER_DIRECT_META` so it
   cannot overwrite the facts with its one-line summary.
2. `merge_queue_put` for a tier-1 APPROVE this machine is structurally forbidden
   to merge (`BUILDER_NO_MERGE`). Idempotent on `(project, pr)`, so the hub
   writing the same row is a duplicate and never a second merge. **Never for a
   stacked PR** — the box queue would land the child into its parent's branch.
3. `bin/board-closeout.sh` — the what-shipped comment and the status move
   (`PR_CREATED` → `review`, `PR_MERGED` → `done`, per
   docs/BOARD-API-CONTRACT.md). It words **only** a build that ended with a PR;
   a deferral or a `PLAN_BLOCKED` needs a sentence about *why* and still goes to
   a triage session on the owning box.
4. `wake_put <slug> pr <n>` — the doorbell (docs/EVENTS.md §5.1). Inert until
   the worker route lands; GitHub's own PR webhook already rings the conductor.

**The marker is the hand-off, and it is the one thing worth being careful
about.** Only a close-out that actually POSTed appends
`| CLOSED-OUT: …` to the first line of `RESULT` — the only identity the relay
json, the ledger artifact feed and the hub's ingest all spell identically. The
hub's `bin/fly-results-ingest.sh` reads it as "already delivered" and relays
nothing; `bin/run-triage.sh`'s staging marks such a dir `COMMENTED` instead of
handing it to a session. A second comment lands on a CLIENT's ticket and there
is no taking it back, so it gets both guards — and a POST that was refused
leaves the line unmarked, which puts the close-out straight back on the path it
travels today.

**Kill flag:** `BUILDER_DIRECT=0` (`env/global.env` or the environment) or
`flags/builder-direct-off`. Then the block never runs, transition 43a does not
exist, and 9a is logged-and-built-through. Watcher builds never enter it at all.
Driven by `tests/builder-direct-test.sh`.

### Stages outside run-build.sh that write into the same vocabulary

| # | From | To | Guard | Bound |
|---|---|---|---|---|
| 44 | fly-pool reap | `RESULT_UNVERIFIED <rline>` | RESULT claims `PR_CREATED` and a REST read affirmatively answers 404 (with the repo itself visible to the same token) or CLOSED | 2 REST reads; an unreadable API is UNKNOWN, never a state (BH-709) |
| 45 | watchdog resume pass | `BUILD_DEAD` | resume cap exhausted without completing | attempts + total cap |
| 46 | watchdog resume pass | `PR_CREATED (recovered)` | pipeline died after the PR was opened | — |

---

## Findings

Written down when found, whether or not they were fixed the same day. F1-F5 were
closed by SDLC item 6 on 2026-09-06 and are kept here, marked CLOSED, with what
each one writes now — a finding deleted on the day it is fixed takes the reason
the fix exists with it. F6 and F7 remain open by choice, and say so.

### F1–F4: exits that died without writing a terminal — CLOSED 2026-09-06 (SDLC item 6)

Four paths used to leave `run-build.sh` with a bare `exit` and no `RESULT`. Each
one now writes its own owner before it goes:

| id | condition | owner it writes now |
|---|---|---|
| F1 | `RESUME_BUILD` points at a dir that no longer exists | an ALERTS line (there is no build dir to hold a RESULT) |
| F2 | `/root/repos/<project>` missing | `BUILD_REFUSED`, plus the ALERTS line it already wrote |
| F3 | `origin/<branch>` cannot be checked out on resume | `BUILD_DEFERRED cannot check out origin/<branch>` (retried by the next resume) |
| F4 | branch unavailable, held by a stale worktree | `BUILD_DEFERRED branch unavailable` |

F2–F4 were the leak shape exactly: the build dir already exists (it is created
at line 30), the ticket has been claimed, and the pipeline vanished leaving a
directory with no RESULT. The watchdog's resume pass would re-launch each one up to
the cap and then write `BUILD_DEAD`, so it was never a *permanent* leak — it
burned the full resume budget rediscovering a condition the script already knew
at the point it gave up. Now the sweep closes them on the first pass, and the
job row closes `parked` (deferral) or `failed` (refusal) instead of hanging
open.

F1 is the one that cannot be fixed the same way: `$BUILD` IS the missing
directory, so there is nowhere to write a RESULT and no job row to close. It
writes the ALERTS line instead, which is the only owner available to it — and
the reason the finding stays in this list rather than disappearing: a reader who
finds `exit 2` with no RESULT there should find the reason beside it.

The line numbers this table used to carry are deliberately gone. They were wrong
within two waves, and the conditions are greppable.

### F5: five terminals had no close-out rule in the sweep SOP — CLOSED 2026-09-06 (SDLC item 6)

`run-build.sh` writes fourteen distinct terminals. The per-project sweep SOPs
(`prompts/<project>.md`, plus both templates) used to enumerate nine of them and
`BUILD_DEAD`; the five below wrote a RESULT the sweep had no instruction for,
and a security block landed somewhere between silent and improvised:

| terminal | rule it has now |
|---|---|
| `PR_MERGED` `PR_CREATED` `PLAN_BLOCKED` `REVIEW_BLOCKED` `EXECUTE_EMPTY` `BUILD_DEFERRED` `DECOMPOSED` `DECOMPOSE_FAILED` `PLAN_MALFORMED` | unchanged, as they shipped |
| `SECURITY_BLOCKED` `REFUTE_BLOCKED` | ALERTS line naming the ticket and the lens's own review file, a short "held for a human read" comment, and NO requeue |
| `BUILD_REFUSED` | ALERTS line with the RESULT's reason, no comment — a re-run repeats it |
| `PLAN_STALE` | closed quietly; the next tick re-plans against the newer thread |
| `QUEUED_FLY` | closed quietly; not a stop, the Fly builder is still running and writes its own RESULT |

`tests/run-build-graph-test.sh` now asserts the whole matrix — every terminal the
script writes appears in every sweep SOP — so this list cannot silently regrow.
That check replaced the one that used to assert F5 was still TRUE.

This finding is also why the mechanical gates added in an earlier wave reuse
`REVIEW_BLOCKED` rather than introducing `TAMPER_BLOCKED` / `REPRO_BLOCKED`: a
new terminal without an SOP rule joined this list rather than being handled.
`PLAN_MALFORMED` (item 5) was the counter-example and is now the standard — it
shipped with its close-out rule in all eleven SOPs, its beat stage in the
console's `DEAD_STAGES` / `PARKED_STAGES`, and a test that fails if either
drifts.

Note the resume pass (`bin/lib/resume-dead.sh`) is vocabulary-agnostic (any RESULT except
`BUILD_DEFERRED` is terminal to it), so F5 was an SOP gap, not a resume gap.

### F7: the added-vs-modified split has a known evasion path

The reproduction gate treats only **pure-ADDED** test files as blocking
evidence (exit 1). A test appended to an **existing** file is `modified`, so the
gate returns exit 2 — recorded, not blocked.

That means a vacuous always-passing test appended to an existing suite is not
mechanically caught, where the same test as a new file would be.

**This is accepted by design, not an oversight.** The alternative — blocking on
modified test files — false-blocks the ordinary shapes: a comment edit, a
rename, a coverage backfill on behaviour that already shipped. All of those
legitimately PASS at base, and a gate that fails honest builds gets disabled
rather than obeyed. Blocking them while a diff with NO tests merely warned was
also backwards on its own terms.

It degrades to LLM adjudication rather than to nothing: the gate reports the
modified-file count into the review prompt (`MODNOTE`), so the reviewer is told
that modified tests exist and were not used as evidence, and can read them.

Same class as the `TEST-CHANGE:` escape hatch — a deliberate soft spot,
documented so nobody rediscovers it as a surprise. If it is ever abused in
practice, the fix is not to block modified files wholesale but to diff the
appended cases and run only those at base.

### F6: two vocabularies, one easy conflation

The console's `BUILDING_STAGES` / `DEAD_STAGES` are **beat stage** names
(`planning`, `executing`, `reviewing`, `qa`, `pool_*`, `fly_*`), not RESULT
terminals. `DEAD_STAGES` contains `plan_blocked`, `plan_stale`, `plan_deferred`,
`plan_malformed` — lowercase beat stages that happen to mirror terminal names. Adding a beat
stage the console does not know makes a live build fall out of `building`
without appearing anywhere else: invisible, which is the 232-row shape again.

---

## Keeping this honest

`tests/run-build-graph-test.sh` fails if the table and the script drift: every
terminal in the table must be one the script writes, every terminal the script
writes must appear in the table, every stage named here must exist, and — since
item 6 closed F5 — every terminal the script writes must have a close-out rule
in every sweep SOP. `tests/stop-owners-test.sh` drives the behaviour behind that
last row: the four exits that used to vanish, and the overlap timeout.
`tests/kind-flow-test.sh` drives the section above it — the classifier (including
the titles that must NOT read as defects), the five-fact bug contract, the
warn-first switch, and the four readers the kind reaches. `tests/lane-fence-test.sh`
drives the item-8 fence the same way its claude sibling
(`tests/iron-law-guard-test.sh`) drives the hook: real shims in front of real
fake binaries, a real push to a real bare remote, and the wiring read out of the
environment `bin/agent-call.sh` actually handed the runner, plus the two things
only a shim can get wrong: that a refusal redacts the credentials the shell just
expanded into argv, and that a doubled shim dir on PATH stays a fence instead of
127-ing every command. `tests/lane-fence-canary.sh` is the live half, opt-in
behind `LANE_FENCE_CANARY=1`, and the only place the fleet learns whether the
codex CLI still hands its shells the environment the whole mechanism rests on.
`tests/pipeline-gaps-test.sh` drives row 30a the same way its lens sibling
drives the lenses: a real repo with a real remote, a stubbed smoke that records
when it started and finished, and the three properties no grep can see — that an
instant existed when the smoke and the review were both running, that the lane
was joined before the first stage that writes to the tree, and that
`GATES_PARALLEL=0` puts the smoke back in front of the review with its real note
in the reviewer's prompt. It also reads the call ORDER out of `bin/run-build.sh`
itself, so a join that drifts below the fix round or the rebase fails here.
A transition table nobody checks becomes fiction within a month.

### Where each row's code lives (BH-478)

Since the BH-572 cut, `bin/run-build.sh` keeps only its head (the resume guard,
`RESULT`, the stage-module source loop), the per-key dedupe lock with the env
load, and the EXIT trap. Every stage body runs from a module under `bin/lib/rb/`
as a bare `rb_<entry>` call, in this order. To read one row's code, open the
entry named here, or flatten the whole pipeline with `tests/lib/rb-all.sh`.

| Transition rows | Stage | Code |
|---|---|---|
| 1 | resume guard | `bin/run-build.sh` (kept head) |
| 2-8, 10 | context-gate, fly-dispatch, WIP cap, build slots, repo check | `bin/lib/rb/gates.sh:rb_gate_prelude` |
| 9 | per-KEY dedupe | `bin/run-build.sh` (kept dedupe block) |
| 9a, 11, 11a, 12-17, 23e | queue claim, overlap not-before, stack base, worktree and branch setup | `bin/lib/rb/gates.sh:rb_gate_claim_and_workspace` |
| 18-22, 20a-20d, 23 | PLAN and the size gate | `bin/lib/rb/plan.sh:rb_plan` |
| 23a-23d, 23f | overlap wait, plan-overlap | `bin/lib/rb/gates.sh:rb_gate_overlap` |
| 24, 25 | EXECUTE | `bin/lib/rb/execute.sh:rb_execute` |
| — | spec artifact (no transition row) | `bin/lib/rb/spec.sh:rb_spec_artifact` |
| 26-29, 30 | test-tamper gate, reproduction gate, SEMGREP | `bin/lib/rb/execute.sh:rb_execute_gates` |
| 30a, 31-38 | E2E lane, the lenses, fix rounds | `bin/lib/rb/review.sh:rb_review` |
| 39-41 | rebase, PR-open, QA | `bin/lib/rb/pr.sh:rb_pr` |
| — | evidence settle (no transition row) | `bin/lib/rb/result.sh:rb_settle` |
| 42, 43, 43a | merge-lane, builder-direct close-out | `bin/lib/rb/result.sh:rb_close_out` |
