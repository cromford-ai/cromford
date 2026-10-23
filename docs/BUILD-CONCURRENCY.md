# Build concurrency — one readable ceiling per project

<!-- changes:begin -->
> **What changed since this doc was written lives in [`docs/notes/`](notes/INDEX.md)**, one dated note per change. Add a note there instead of appending here; guardrail `doc-monolith-edit` checks it once it is armed in CI (the adoption PR that `guardrails/README.md` prescribes; not yet opened).
<!-- changes:end -->

**The question this document exists to answer in one command:** *how many builds
may this project run at once, and which cap says so?*

```bash
bin/concurrency-plan.sh                # the whole fleet
bin/concurrency-plan.sh project-5      # one project
bin/concurrency-plan.sh --json         # the same answer, machine-readable
```

---

## Why it needed a document

On 2026-09-12 project-5 was seen running twelve builds at once. The obvious
place to check said one:

```sql
-- worker/jobs/schema.sql
INSERT OR IGNORE INTO concurrency_rules (...) VALUES
  ('repo', '*', 'build', 1, 'one build per repo at a time; raise this row ...');
```

Nothing was bypassed. The seed is `INSERT OR IGNORE` **on purpose** — the
schema's own comment says these rows are meant to be edited and a re-applied
schema that reset a hand-raised cap would be a config change nobody made — and
the live row had been raised that morning. The seed is the copy a reader finds;
the row is the one that binds, and reading the DB was the only way to know.

That prediction came true from the DELETED-row side too (BH-1279,
2026-09-20/21 — `docs/notes/2026-09-21-BH-1279-no-caps-seed.md`): the seed no
longer carries a `repo` or `box` row at all, so a re-apply can never resurrect
one an operator removed.

Then there is the second half. Even with the right row in hand, it is not the
only cap, and on some routes it is not the cap that binds:

| cap | lives in | scope |
|---|---|---|
| `concurrency_rules repo/<p>/build` | the coordination DB | fleet-wide |
| `concurrency_rules box/*/build` | the coordination DB | per box |
| `concurrency_rules ticket/*/*` | the coordination DB | per ticket |
| Fly pool cap | `bin/pool-cap.sh` → `flags/fly-pool-<p>` number, else `fly/pool-caps.conf`, else **unlimited** (trimmed by `POOL_CAP_MAX`) | per project |
| single-machine dispatcher wip | `bin/lib/build-caps.sh` `FLY_DISPATCH_WIP` | per project |
| `flags/wip-limit-<p>` | the project's own watcher box | per project, per box |
| `BUILD_SLOTS` | `env/global.env` on the project's own watcher box | per box |

Five files, no answer. `bin/concurrency-plan.sh` is the answer.

---

## Routing decides which caps apply at all

This is the half that keeps being got wrong, and getting it wrong is not a
rounding error — it is the difference between a starved lane and an unguarded
one.

`bin/run-build.sh` answers `RESULT "QUEUED_FLY $KEY"` and **exits** inside its
`flags/builder-fly-$PROJECT` enqueue gate. That happens *above* the wip gate
(`flags/wip-limit-$PROJECT`), *above* the box slot flock
(`locks/build-slot-$S.lock`), *above* the per-key flock
(`locks/build-key-$PROJECT-$KEY.lock`) and *above* `job_open`. So:

| route | set by | what binds | what does **not** |
|---|---|---|---|
| **pool** | `flags/builder-fly-<p>` **+** `flags/fly-pool-<p>` | the pool cap and `repo/<p>/build` | `wip-limit`, `BUILD_SLOTS`, and `box/*/build` (each pool machine is its own box); on the machine itself the build-slot gate is skipped (`POOL_MODE=1` + `BUILDER_EXEC=1`), so the `flags/build-slots`=1 the entrypoint writes binds nothing |
| **fly1** | `flags/builder-fly-<p>` alone | `FLY_DISPATCH_WIP` — `bin/fly-dispatch.sh` holds one `<p>-active.json` | everything else; the repo rule can only lower it |
| **local** | neither | `wip-limit`, `BUILD_SLOTS`, `box/*/build`, `repo/<p>/build` | the pool cap |

Which stages run on a Fly machine and which stay on the box or the hub is stated
once, in `docs/FLY-BUILDER-TRIAL.md` (stage map).

`bin/free-slots.sh` was written after the same mistake in the other direction: a
local slot count was applied to a Fly-routed project and held three ready
project-5 builds back from an idle pool. The plan reports `-` for a cap that
does not apply on the route, and `?` for one this machine could not read, and
neither ever enters the minimum.

**On the pool route the binding caps are fleet-wide**, so the answer for a pool
project is correct from anywhere — a laptop included. **On the local route they
are not**: `BUILD_SLOTS` and `flags/wip-limit-<p>` live on that project's
own watcher, and `flags/fly-pool-<p>` lives on the hub. Run off-box, those
columns describe the machine you ran on; the table names that box in its footer,
and a local-route number read from elsewhere is unverified, not wrong-by-a-bit.

---

## A cap is not a queue (2026-09-13)

> the operator, via Telegram: **"change the rule so we never lock and serialize."**
> Nothing in the harness may make a build wait in line behind another build.

Every number above is a **cap**: reach it and the extra work is handed back
(`BUILD_DEFERRED` + exit 3, the queue row returns to `queued`) and re-offered on
the next tick. None of them is a queue you stand in. The locks that survive do
exactly one of two jobs:

| lock | job | kept? |
|---|---|---|
| `locks/build-key-<project>-<KEY>.lock` | **same-box dedupe** — one build per ticket key on THIS machine, `flock -n`, loser says `BUILD_DEFERRED $KEY already building`. Also what `bin/review-rescue.sh` takes, so a rescue can never race a live build of the same key. **No longer the source of truth** — see "The dedupe that only saw one box" below | keep, as a fast path |
| `locks/build-slot-<N>.lock` | the box cap, and **only when `BUILD_SLOTS > 0`**. With the default 0 no slot lock is opened at all. Never taken on a pool machine (`POOL_MODE=1` + `BUILDER_EXEC=1`): one machine runs one job, and the build logs `build slots: pool machine ... slot gate skipped` instead | keep, opt-in |
| `locks/build-repo-<project>.lock` | a **short critical section**: `git checkout`/`pull --ff-only`/`worktree add` on the shared checkout, a few seconds of git, released before the pipeline does any work | keep |
| `locks/<project>.lock`, `locks/fly-pool-<p>.lock`, `locks/fly-dispatch.lock` | **tick dedupe** — `flock -n`, so a cron tick that overlaps its predecessor exits instead of doubling it | keep |
| `locks/build.lock` (box-wide, `flock -w 3600`) | told the triage agent to WAIT up to an hour so build waves took turns | **deleted** |
| `locks/review-rescue.lock` (global) | put every rescue in the fleet behind one Fable review | **deleted** |

`BUILD_SLOTS` lives in `env/global.env` (hub and every box; pool machines inherit
it from the baked image, where it is unset = unlimited):

```bash
BUILD_SLOTS=0     # default: no slot lock, builds never queue behind each other
BUILD_SLOTS=3     # this box runs at most 3 local builds; the 4th DEFERS, it does not wait
```

`flags/build-slots` is the legacy spelling. It is still read when `BUILD_SLOTS` is
unset, so a box that deliberately set 2 keeps 2 — but nothing writes it any more,
and `bin/free-slots.sh` prints `unlimited` when neither is set.

The one wait left in a build's own path is
`OVERLAP_WAIT_SECS` (file-overlap with a sibling build), and its default is now
**0**: the first failing `bin/conflict-check.sh` defers instead of polling for 45
minutes. Set it positive on a box that would rather pay the wait than the re-plan.

### No caps, anywhere, by default (2026-09-14, later the same day)

> the operator: "all the projects run unlimited parallel — build, conductor, review,
> merge — no caps."

Every number on this page is now something an operator has to WRITE to get. The
defaults are unlimited:

| lane | knob | was | now |
|---|---|---|---|
| builds, fleet-wide per repo | `concurrency_rules repo/<p>/build` | rows at 10 (project-5 20) | **no row.** `bin/jobs-client.sh rule-unset repo <p> build` removes one; `rule-unset repo '*' build` the wildcard. No row = unlimited (`checkRules`). There is no NUMBER that spells unlimited — `max_concurrent 0` is a freeze — which is why `DELETE /api/rules` exists |
| builds, per box | `concurrency_rules box/*/build` | 1 | **no row** (a pool machine is its own box; the local route keeps `BUILD_SLOTS`, default 0 = unlimited) |
| one build per ticket | `concurrency_rules ticket/*/*` | 1 | **1 — kept.** That is dedupe, not a cap: the same ticket building twice is the TK-66/67 double-build |
| conductor rebases | `MC_REBASE_PARALLEL` | 4 | **0 = unlimited** |
| conductor re-reviews | `MC_REREVIEW_PARALLEL` | 8 | **0 = unlimited** |
| review lenses inside a build | `LENSES_PARALLEL` | 0 (project-5 pilot at 1) | **1** — three lenses read the diff at once; `LENSES_PARALLEL=0` in `env/<p>.env` is the sequential opt-out |
| review rescues per tick | `RESCUE_PARALLEL` | 8 | **0 = unlimited** |
| autopilot reviews per project per day | `REVIEW_AUTOPILOT_DAILY_CAP` | 3 | **0 = unlimited** |
| legacy `flags/build-slots` | on every box | 2 | **removed** (`BUILD_SLOTS` unset = unlimited) |

What is NOT a cap and stays: the same-box per-key flock (dedupe), the tick
flocks (a cron tick never doubles itself), the short git critical section, and
the per-ticket rule above. `bin/concurrency-apply.sh` still PROPOSES a repo rule
from account capacity; it writes nothing unless someone runs it with `--apply`,
and running it now would put a ceiling back — it is the tool for the day the
account, not the fleet, is what has to be protected.

### The ceiling at the other end: one line into main (W2-D, 2026-09-14)

> the operator, 04:12Z: the harness has to behave like a 4000-person engineering team.
> Every throughput ceiling is a bug.

Every cap above is about how many builds run AT ONCE. This one is about what
happens to them afterwards, and it is a ceiling nothing on this page could see:
**every PR merges into one main.** At 4000 PRs a day, a merge into that line
marks every other open PR on the repo DIRTY-or-stale, and each of those PRs then
pays a rebase (minutes of clone + typecheck + push) and, because the rebase moves
the head, a re-review. Two storms per merge, most of it spent on PRs that do not
conflict with what landed and do not touch a line of it.

`bin/plan-overlap.sh` is the half of the answer that lives before the build; the
other two halves are the conductor's (`docs/MERGE-CONDUCTOR.md` section 4: the
`git merge-tree` conflict test, and the no-overlap approval rebind). The cheapest
merge conflict is the one two builds never create.

**What it asks, and where it looks.** `bin/conflict-check.sh` already refuses to
co-build two overlapping builds it can SEE, and what it can see is this box's own
`builds/` directory. That was the whole world when one box owned a project. It is
not the world with a pool: the sibling about to conflict with this plan is
usually on another machine, and the only place both of them are visible is the
jobs ledger. So `plan-overlap.sh` asks the same question — *does any path in this
plan's `planned-files.txt` equal, or contain, or sit inside, a path some other
in-flight plan named* — against a wider set:

| source | what it contributes |
|---|---|
| `builds/<project>-*/planned-files.txt` | this box's live build dirs (no `RESULT`, touched in the last 4h) — `conflict-check.sh`'s world |
| `state/claims/<project>/<KEY>` | the claims ledger `run-build.sh` publishes at PLAN time, keyed on the ticket KEY both sides use |
| `queue_list <project> claimed` | the QUEUE, fleet-wide. Two jobs: a claim file whose row is no longer `claimed` is a DEAD claim and is ignored (better than the 4h mtime guess), and a row claimed on a box whose file list never reached this one is reported as `OVERLAP_UNJUDGED` on stderr rather than silently counted as disjoint |

Honest gaps beat confident wrong answers here: a missed overlap costs one rebase,
and a fabricated one costs a build that never runs. A ledger outage, an empty
`planned-files.txt`, or no plan data at all all mean *build* — the answer this
pipeline gave before the gate existed.

**Deferring is not queueing.** On an overlap the hook logs one line —

```
OVERLAP_DEFER <KEY> vs <KEY2> files=[src/lib/pricing/rates.ts ~ src/lib/pricing/rates.ts]
```

— and ends the build `BUILD_DEFERRED`, which puts the ledger row back to `queued`
(`_job_finish`'s `parked` arm) and writes a **not-before** ten minutes out into
`state/overlap-defer/<project>/<KEY>`. Nobody holds a slot, a lock, or a machine
while the sibling finishes; the ticket is simply re-offered to whatever box is
free once the window closes. The not-before is read at the TOP of `run-build.sh`,
right after the env is sourced and long before the PLAN session is bought,
because the failure mode without it is a spend loop: re-offer, buy a plan, stand
down against the same sibling, repeat every tick. It is a floor and never a
ceiling — the marker is consumed the moment it expires, and the build that
arrives after it re-runs the overlap test from scratch, because by then the
sibling is usually finished.

**Switches** (both in `env/global.env`, or the environment):

```bash
OVERLAP_SCHED=1                   # default. 0 / off / false / no = the gate and the
                                  # not-before are no-ops; the pipeline is exactly
                                  # what it was before this change
OVERLAP_DEFER_NOTBEFORE_SECS=600  # how long a deferred key waits before it is planned again
```

`flags/plan-overlap-off` is the same kill switch as a file, for a fleet-wide flip
from the console. Neither one touches `OVERLAP_WAIT_SECS` /
`OVERLAP_DEFER_ENFORCE` above: `conflict-check.sh` keeps its own behaviour and its
own switches, and this gate runs after it, at the same one hook point right after
PLAN. See `docs/RUN-BUILD-GRAPH.md` rows 23c-23f and
`tests/merge-funnel-test.sh`.

### The wait a cap could not see: the chain (2026-09-14)

None of the caps above was ever what held TK-563..567. They were held by a
`Blocked-by:` line: a child ticket waited for its parent's PR to **merge**, and a
chain level on project-5 is 60-75 minutes (plan 7-10, execute 20-33, the
push-to-review dead gap 6-8, review 4-9, post-review size/scope ~10, then the
conductor's `*/5` and triage's `*/20`). Five children behind one parent is five
sequential hours of a box that was, by every number in this document, idle.

**Stacked child builds** remove that wait the same way every other rule here does
— by refusing to stand in line. A child whose one live blocker already has an
OPEN PR builds ON TOP of that PR's branch (`STACK_BASE=<parent-branch>`), so the
chain levels overlap instead of queueing; the merge stays strictly ordered
(`STACKED_WAIT` in the conductor until the parent lands and GitHub retargets the
child). Sequencing still lives in `Blocked-by:` lines — what changed is that
sequencing the MERGE no longer means sequencing the BUILD.

This is a chain concurrency change, not a machine one: every cap above still
applies to the stacked child exactly as it does to any other build, and on a
Fly-routed project each stacked child is its own pool machine. Kill flag:
`STACKED_BUILDS=0` in `env/global.env`, or `flags/stacked-builds-off`.
See docs/RUN-BUILD-GRAPH.md, "Stacked child builds".

### Verified dependencies: the chain the harness widens itself (W2-G, 2026-09-14)

Stacked builds removed the wait *inside* a declared chain. They did not question
the chain. `Blocked-by: #N` is written once, by hand, before either slice exists,
and it over-declares: tonight's project-5 wave #666-#678 declares
`667→669→{670,671}→{673,674,675,677}→{676,678}` — five levels, five sequential
hours — while children like the brain map (#674) and the lifecycle rollup (#675)
plausibly share no files with their parent and could build on `main` from the
first minute. The lever for widening that wave was a human editing issue bodies.
the operator, on being told so: **"how do we do that by default?"**

So the line became a **claim the harness checks**. `bin/dep-verify.sh <project>
<child> <blocker>` answers exactly one of `HARD` / `SOFT` / `UNKNOWN`, and a
child whose EVERY still-open blocker comes back `SOFT` is emitted by
`bin/unblocked-children.sh` as `UNBLOCKED` — build on `main`, now — instead of
waiting or stacking.

**`SOFT` needs both halves, and they are different kinds of evidence:**

| half | what it is | where it comes from |
|---|---|---|
| file | the child's `planned-files.txt` is **disjoint** from the blocker's file set | the blocker's open PR's changed files (`gh api pulls/N/files`), else its merged PR's, else the blocker's own pre-plan list. Same overlap rule as `bin/conflict-check.sh` / `bin/plan-overlap.sh`: file == file, dir contains file — with one prune in front of it (below) |
| semantic | the child's own pre-plan says so: `DEPENDS: #N soft — <reason>` | `prompts/plan-contract.md` §7, emitted by the pre-plan prompt for any ticket with `Blocked-by:` lines. `hard` = this slice imports/calls/extends/migrates on top of code the blocker adds |

**One prune before the comparison (2026-09-14).** A pre-plan's file list names
BOTH a directory and the file it adds under it — TK-667's is
`prisma/migrations/manual` *and*
`prisma/migrations/manual/2026-09-14-TK-667-team-chart-max-members.sql`, because
"I create a migration" reads as two claims to whoever wrote the plan. Left in,
the bare directory collides with every sibling's migration: `dep-verify.sh
project-5 669 667` answered `HARD … 2026-09-14-TK-669-hat-merge-knobs.sql ~
prisma/migrations/manual`, two DIFFERENT new files judged as one shared path. So
an entry that another entry **of the same list** names a file under is dropped
before comparing — the file is the claim, the directory is where it lives. A
directory that appears ALONE is untouched and still contains everything under it.
The prune lives in `bin/lib/dep-verify-lib.sh:dep_overlap` and, word for word, in
`bin/plan-overlap.sh:overlap`; `tests/merge-funnel-test.sh` drives the same two
lists through both and fails if they disagree.

Anything missing is **`UNKNOWN`**, and what `UNKNOWN` does to the child is
**`DEP_UNKNOWN_MODE`** in `env/global.env` (`bin/lib/dep-verify-lib.sh:dep_unknown_mode`):

| mode | an `UNKNOWN` pair | since |
|---|---|---|
| `soft` (default) | counts exactly like `SOFT`: the child is emitted as `UNBLOCKED` and builds on the default branch now. Its line says `dep-unverified, released` rather than `dep-verified soft`, its thread comment says the check could not run, and a real overlap the missing evidence would have caught is resolved by the merge conductor's self-rebase | 2026-09-16 |
| `hard` | counts exactly like `HARD`: `STACKABLE` on the parent's open PR, otherwise a wait | the W2-G original |

**Why the default flipped (the operator, 2026-09-16).** `UNKNOWN` was designed as the
safe answer — a wrong `HARD` costs a wait, a wrong `SOFT` costs a build against
a base that does not carry the code it needs — but it was also the commonest
answer by far: a decomposed child has no `planned-files.txt` until the pre-plan
lane reaches it, and "no pre-plan yet" is `UNKNOWN`. project-5 at 05:04Z had 22
of its 49 open tickets logged `DEP_HARD … UNKNOWN, treated as hard` while the
Fly pool cap was already 0/unlimited: the dependency check had become the
throughput ceiling the pool cap was removed to get rid of. the operator: **"There should
be no cap, let's remove the cap."** The wait was buying a certainty the conductor
already provides at merge time, so the default is now to build. Pairs the
evidence actually calls `HARD` are `HARD` under both settings. **The author's
escape hatch outranks all of it, unverified**: `Blocked-by: #N (hard)` or
`Needs: #N` in the issue body is hard, full stop.

**The evidence has to exist before the parent lands**, which is why
`bin/preplan-candidates.sh` grew a fourth class. `blocked` — a child whose
blockers are still open and not even started — is pre-planned against `main`,
bounded by the same `PREPLAN_AHEAD` number as `ahead` and sorted **last**,
because it is the most speculative thing on the list and the first that
`PREPLAN_PARALLEL` should drop. GitHub-Issues lanes only: `dep-verify` reads
`Blocked-by` lines, which in-app boards do not have.

**The verdict is cached on its evidence, not on a clock.**
`state/dep-verify/<project>/<child>-<blocker>` holds the fingerprint of the
child's blocker declarations, its `plan.md`, its file list and the blocker's
evidence source (its PR's head sha, or its own plan) — so either plan moving
re-verifies, and nothing moving costs no `pulls/N/files` call at all. **`UNKNOWN`
is never cached**: it means "could not answer", and the commonest reason is a
transient 401 or timeout this fingerprint cannot see.

Both names go into `logs/<project>.log` on every pass, whether or not anything
was widened (`DEP_SOFT <child> vs <blocker> — <why>`, `DEP_HARD …`, with
`UNKNOWN` logged as `DEP_SOFT … UNKNOWN, released (DEP_UNKNOWN_MODE=soft)` or,
under `hard`, `DEP_HARD … UNKNOWN, treated as hard`) — a wave that stays five
levels deep because every child came back `UNKNOWN` must not look like a wave
nobody checked. A child that is actually released soft gets **one** comment
on its own thread saying which blockers were verified and why, guarded by a
marker beside the cache so a later tick never repeats it.

**Filing side**: `Blocked-by:` means *needs the parent's code*. An ordering
preference is not a dependency — leave the line out, or write `After: #N`, which
is a note to a human that nothing in the harness parses and which therefore
creates no wait (`skills/harness/SKILL.md`, and `run-decompose`'s `after` field
carries the same instruction).

Kill flag: `DEP_VERIFY=0` in `env/global.env`, or `flags/dep-verify-off`. Either
one drops the soft class and the `blocked` pre-plan class, asks for no verdict,
posts no comment, and leaves both scripts byte for byte what they were before
this change. `DEP_VERIFY_DRY_RUN=1` prints a verdict and writes nothing.

### The dedupe that only saw one box (2026-09-14, W2-B)

`locks/build-key-<p>-<KEY>.lock` answers "is this ticket already building **here**",
and one pool machine was carrying 277 of those files. At 4000 builders that
question is the wrong one: the same queued key can be offered to any machine in
the pool, and not one of those 277 locks could have stopped a second machine
taking it.

So the **dedupe of record is the ledger**, in two conditional writes, and the
flock stays only because it is free:

| guard | scope | what losing it means |
|---|---|---|
| `job_open` (`jobs`, ticket-keyed) | the whole fleet | rc 9 → `BUILD_DEFERRED`, the row says which box holds it |
| `queue_claim <project> "" <KEY>` (`build_queue`) | the whole fleet | the worker takes the row **only while it is still `queued`** and answers **409** otherwise → `BUILD_DEFERRED $KEY claimed by another builder` |
| `locks/build-key-…` flock | this box | `BUILD_DEFERRED $KEY already building` — and it is still what makes the per-key worktree exclusive |

The claim endpoint contract (what 409 means, and what a client may conclude from
it) is in docs/HARNESS-COORDINATION.md, "The build-queue claim".

Losing the queue CAS used to be logged and built through — "job_open holds the
claim" — which was true when the queue row was bookkeeping. It is not a
throughput ceiling either way: a stand-down is `exit 3`, the row stays `queued`
for whoever won it, and this ticket is re-offered on the next tick. It is a cap,
not a queue, exactly like every other rule on this page. Kill flag:
`BUILDER_DIRECT=0` in `env/global.env`, or `flags/builder-direct-off` — either
restores "log it and build anyway" byte for byte.

---

## Concurrency INSIDE one build (2026-09-14)

Every cap above counts builds. A build also runs work beside itself, and none of
it takes a slot, a lock or a claim:

| what | since | what it is |
|---|---|---|
| the three review lenses | 2026-09-12 | `LENSES_PARALLEL=1`, per project — three model sessions reading one immutable diff at once, waited on BY PID |
| the E2E read-only lane | 2026-09-14 | `GATES_PARALLEL=1`, the default — the preview smoke runs beside the lenses instead of in front of them. It is path-gated before the push (no UI paths in the diff, no branch push and no preview wait at all), joined with a cap (`E2E_JOIN_MAX_S`, default 600 s, `0` = uncapped), and late-settled before the tier decision, where a verdict that landed after the cap is applied and appended to the PR as a comment. No model call, no tree write |

Neither is a queue and neither may become one. Both wait on **named pids, never
a bare `wait`**: the build's shell already owns `job_beat_start`'s heartbeat
child, which never exits, so a bare wait would hang the build until the claim
timed out — the in-build version of exactly the rule this document is about.

What a box has to carry is the cost side of it: an opted-in project with three
lenses running carries three model sessions where it carried one, and the E2E
lane adds a browser. `docs/RUN-BUILD-GRAPH.md` (row 30a) is where both live, with
the per-stage `STAGE-TIMING` lines that say what either one actually saved.
## Pre-planning runs at its own cap (2026-09-14)

**The stage that nobody consumed.** `bin/run-preplan.sh` has written plans into
`plans/<project>-<KEY>/` since 2026-07-23, and until this change **nothing read
one**. `bin/run-build.sh`'s PLAN checkpoint guards on `$BUILD/plan.md`, which a
fresh build dir never has, so every pre-plan the fleet ever paid for was thrown
away and every build re-planned from scratch. Both halves are fixed together —
there is no point pre-planning more tickets into a directory nobody opens.

**Why it is worth a cap of its own.** Measured on project-5: plan 7-10 min,
execute 20-33, 60-75 min wall per ticket. A plan is read-only and costs $1-2, so
for a ticket we can already see coming — a child whose parent PR is open, the
next ready ticket the triage tick picks up 20 minutes from now — those ten
minutes are the cheapest ones on the board. Speculation is bounded by two
numbers rather than by a lock:

```bash
PREPLAN_SPECULATIVE=1   # default. 0 restores the 2026-07-23 single next-queued pre-plan
PREPLAN_PARALLEL=3      # concurrent pre-plans box-wide (was: exactly one, always)
PREPLAN_AHEAD=2         # untouched ready tickets pre-planned per project; 0 disables that class
```

Both live in `env/global.env` or the environment, resolved by
`bin/lib/preplan-lib.sh`. `flags/preplan-speculative-off` is the file spelling of
the kill switch, for a box an operator has to quiet without editing env.

**The candidates, in the order the cap spends its slots**
(`bin/preplan-candidates.sh`, deterministic, no LLM, never launches anything):

| class | what it is |
|---|---|
| `queued` | the `READY-QUEUE.log` lines for this project — 2026-07-23 behaviour, kept at the head so the ticket about to build wins |
| `child` | blocked by a parent that is **already clearing**: the parent is closed (merged, child not yet picked up) or its PR is open. Sorted above `ahead`, because it becomes buildable the moment that PR lands |
| `ahead` | the first `PREPLAN_AHEAD` untouched ready tickets, oldest first |
| `blocked` | blocked by a parent **nobody has started**. Planned against `main` anyway, because the plan's own file list is the evidence `bin/dep-verify.sh` reads to decide whether that `Blocked-by` line is a real dependency at all. Bounded by `PREPLAN_AHEAD`, sorted last, GitHub-Issues lanes only, and gone entirely with `DEP_VERIFY=0` |

GitHub-Issues projects read the same `gh issue list --label ai-build --state all`
call and the same `Blocked-by:` line regex as `bin/unblocked-children.sh` — one
parser for "who blocks whom", because two that disagree is a ticket planned under
a live blocker. In-app boards get the same line regex over the ticket
description, widened only to accept a board KEY beside a `#N`, and the standing
board law is enforced there too: `triageVerdict=needs_clarification` with
`waitingOn=client` is **never** pre-planned (an early engagement — the plan is what
the build executes).

**It is a cap, not a queue, like everything above.** Over `PREPLAN_PARALLEL` the
tick simply launches fewer and re-offers the rest two minutes later. The
per-ticket lock went the same way the build-key lock did:

| lock | job |
|---|---|
| `locks/preplan-<project>-<KEY>.lock` | **dedupe** — one pre-plan per ticket, `flock -n`, the loser exits 0. Two ticks racing one ticket is a duplicate to drop |
| `locks/preplan.lock` (box-wide) | the 2026-07-23 "one at a time" lock. Only opened when `PREPLAN_SPECULATIVE=0` |

How many are in flight is a **lock census**, not a `pgrep`
(`bin/lib/preplan-lib.sh:preplan_held`). A cmdline match counts anything that
merely mentions the script — an agent session quoting the path is enough — and a
tick that miscounts stands down having launched nothing, which is
indistinguishable from a tick with nothing to do. Same reason the tick skips a
key whose `locks/build-key-<project>-<KEY>.lock` is held: that ticket is already
writing its own plan.

**Freshness, and why unverifiable means discard.** A pre-plan records the
`origin/<base>` sha it was written against plus its `planned-files.txt`
(`bin/planned-files.sh`, the same extractor the file-claim gate uses).
`preplan_check` discards it when main has moved **in any file the plan lists** —
not merely when main moved, which on a six-lane night is always. A plan it
cannot judge at all (no base sha, no file list, a shallow pool clone that cannot
reach the sha) is discarded too: re-planning costs 7-10 min and $1-2, executing a
stale plan costs a wrong PR and a revert. Either way the line is `PREPLAN_STALE`
— in `logs/preplan.log` when the tick drops it, in the build's `pipeline.log`
when the adopt does.

**Pool builds consume them too.** A fly builder has no hub `plans/` dir, so
`bin/fly-pool.sh:push_preplan` pushes the pre-plan to `/run/harness/preplan` on
the machine through the same console push that carries the env bundle and
`job.json` — not the queue row, whose `meta` column the worker caps at 4000
chars, an order of magnitude short of a plan. The directory's `key` file is
written **last** and is the gate: `preplan_find` refuses a relay dir whose key
does not match the job, so a half-pushed pre-plan is not adopted in pieces and a
**reused** machine cannot hand job B the plan for job A (the TK-493 shape).

**Adopting one is a copy, not a second code path.** `bin/run-build.sh` copies
`plan.md` into `$BUILD/plan.md`, where the existing PLAN checkpoint already
looks, and copies `ticket-fp` beside it — without that the adopted plan would
skip the thread-stability gate every other plan in the pipeline passes through
(TK-143 #517). From there the build is byte-identical to a resumed one: same
BLOCKED check, same resume-stale gate, same plan/size/scope gates.

**The spend is already visible.** A pre-plan runs through `bin/agent-call.sh`
with `stage=preplan`, so it appends to `logs/cost.csv` exactly like a build stage
and `bin/cost-rollup.sh` already counts it in the build family. Nothing here
writes a second cost row — a second writer would double-count.

---

## Triage shards: the tick that was a worker (2026-09-14)

> the operator, via Telegram: **"can we get multiple triagers like we have multiple
> builders? ... do that."**

Every cap above counts **builds**, and builders have fanned out since the pool
learned to autoscale: one machine per queued build, no default ceiling. The lane
that FEEDS them did not. `bin/run-triage.sh` ran **one session per project per
tick**, under one `locks/<project>.lock`, and that single agent call worked every
changed ticket, every queue line and every result dir one after another inside a
10800-second timeout. A board with thirty moved tickets waited for one reader to
read thirty threads in series, and every tick that fired while it ran exited
`previous run still active, skipping`. The builders were uncapped and starving
behind a triager that was, by construction, one.

**The tick is now a dispatcher.** Everything cheap and deterministic it already
did stays exactly where it was — the pause flags, staging finished builds off the
relay and the ledger, the gate, the scope computation, the ledger claim, the
contract check. What changed is the last step: instead of one agent call over the
whole scope, the scope is split by TICKET KEY and each key gets its own detached
`bin/triage-shard.sh` — its own out file (`logs/<project>.triage-<KEY>.out`), its
own `stage=triage` cost rows, its own beat. The dispatcher exits in seconds, so
the per-project flock now guards the DISPATCH and nothing else, and the next tick
never again bounces off a running session.

**A unit is a ticket, not a list.** The three scope lists the tick already
computes — changed board tickets, queue lines, un-commented result dirs — are
merged on the key, so a ticket whose thread moved, whose queue line is pending
and whose build just finished is ONE shard doing all three. That is one
conversation with one client. On a GitHub-Issues board the same ticket arrives
under two spellings (`563` from the board diff, `TK-563` from the queue and the
build dirs) and `triage_shard_canon` collapses them; a `board prs:` line stays its
own unit (`pr-<n>`) and is deliberately never collapsed onto the issue of the
same number.

**Dedupe, never a queue** — the rule this whole document is about, applied to
sessions instead of builds:

| lock | job |
|---|---|
| `locks/triage-key-<project>-<KEY>.lock` | **dedupe** — one triage session per ticket key, `flock -n`, taken by the shard and held for its life. A key already being triaged is SKIPPED this tick and named in the dispatch line; everything else launches immediately |
| `locks/<project>.lock` | still tick dedupe, but it now covers seconds of dispatch instead of hours of session |

```bash
TRIAGE_SHARDS=1       # default. 0 (or flags/triage-shards-off) restores the
                      # single session over the whole scope, byte for byte
TRIAGE_SHARDS_MAX=0   # default: no cap, no census, nothing withheld.
                      # >0 caps CONCURRENT shards on this box (all projects)
TRIAGE_SHARD_TIMEOUT=10800   # per-shard ceiling; a ticket that needs an hour still gets one
```

**A withheld unit is left in scope, never parked.** There is no spool here and
there must not be one. A key the cap withheld, a key whose lock is held, a claim
the ledger refused, a shard that exited nonzero: each of those has its own entry
deleted from the CONSUMED board fingerprint
(`triage_shard_rearm` → `state/<project>.gate.json`), so the next
`bin/gate-diff.sh` reports that ticket again and offers it a shard again — one
ticket re-offered, the rest of the board untouched. The fingerprint is consumed at
DISPATCH because handing a ticket to an owner is what "this board state has been
worked" now means; there is no single exit code left to wait for. When the cap is
what withheld a unit, the gate's 45-minute queue/sweep brake stamps are dropped
too, so the re-offer does not wait out a brake that was answering a different
question.

**A full-SOP tick stays one session.** When the gate asks for the enumeration —
no scope list, an inconsistent one, the daily sweep, a forced tick, or an
`event-wake` tick whose own fingerprint fetch or diff came back unusable
(docs/EVENTS.md §5.3: a wake that CAN be scoped now is, and shards like any other
board tick) — that tick IS the thing that produces the scope the shards read, so
splitting it would mean splitting a list nobody has computed yet. Same for any tick where a
scope line cannot be placed on a ticket, or where a box-global `READY-QUEUE.log`
line belongs to a lane this box cannot tell apart (`bin/project-of.sh` answers;
an unplaceable line abandons the split rather than guess). Every one of those
paths falls through to the single agent call this file has always made.

**Writes stay per-ticket.** A shard comments on its own ticket, sets its own
status and marks its own result dir. The one shared file is `READY-QUEUE.log`,
which is box-global, and a rewrite-the-whole-file edit from two shards at once
loses one of them — so the prompt sends queue edits through
`bin/queue-line-drop.sh <KEY>`, which does the read-modify-write under the file's
own sidecar lock. Not a new queue format: the same file, the same lines.

**The bill is unchanged in shape.** `logs/cost.csv` has no key column and is not
getting one — `bin/cost-rollup.sh` groups on `(runner, stage, project)` and a new
column would have to land in every reader at once. A shard's rows are ordinary
`stage=triage` rows, so the rollup sums a sharded tick exactly as it summed a
serial one. What changes is that the same work now arrives in parallel: a board
with N moved tickets buys N sessions at once rather than one long one. The
per-tick scope diet and the light-model rule that already decide what a tick
costs are resolved ONCE, for the tick, and passed to every shard — one ticket of
a tick can never route to a different model than its siblings.

**Next: shards on the pool.** Today every shard runs on the box that owns the
project, which is the same machine the old single session ran on — the fan-out is
in sessions, not in hardware. The obvious follow-up is a ledger job kind
`triage`, so a shard can be dispatched to a Fly machine the way a build is
(`bin/fly-dispatch.sh`, `bin/fly-pool.sh`). That is deliberately NOT in this
change: the ceiling being removed here is "one reader per project", and hardware
is only a ceiling once a busy box actually has more shards than cores.

---

## The ceiling nobody wrote down: the account

Every cap above counts **machines**. Machines were never the bottleneck.

> **docs/LESSONS.md #6 — MODEL CAPACITY IS THE THROUGHPUT CEILING, NOT
> HARDWARE.** 2-core boxes build fine; every stall was account weather (session
> caps, org spend caps, 429s). Parallel lanes multiply burn against one account
> (~3-4 heavy sessions max).

And the pool makes that invisible: `bin/fly-envbundle.sh` puts **one**
`CLAUDE_CODE_OAUTH_TOKEN` — the owning box's — into the bundle (its
`for v in CLAUDE_CODE_OAUTH_TOKEN …` copy loop), and it refuses a bundle
without one (`die "bundle missing CLAUDE_CODE_OAUTH_TOKEN"`). That is what the
bundle carries; what a machine ends up with depends on pool account routing
(§Pool account routing) — armed, `bin/fly-pool.sh` leases an account per
machine through `bin/lib/pool-account.sh` and replaces the token line before
the push. Unarmed, saturated or broken it answers `default` and every machine
in the pool ships the same one, so a pool cap of 20 buys twenty heavy sessions
on **one** account, not twenty accounts' worth of headroom. The extra machines
queue inside the vendor, where nothing in this
fleet can see them, and the only symptom is slowness that looks like weather.

```bash
bin/account-capacity.sh claude     # -> "4 (1 account (the implicit 'default' ...) x 4 heavy session(s) each, ...)"
```

DB-driven, code fallback, and it always says which it used:

1. `state/quota/<account>.json` (`bin/quota-poll.sh`) — accounts of the vendor
   that are enabled, off cooldown and under 100%.
2. `env/accounts.d/*.env` — the registry, when nothing has been polled.
3. the implicit `default` account alone — what every non-routed call on a box
   already uses. `ACCOUNT_ROUTING` defaults off, so an unrouted fleet has one.

...multiplied by `fly/account-capacity.conf`, a reviewed line, with the
documented LESSONS.md figure of 4 only as a last resort. Metered API vendors
(grok, openrouter, fireworks) answer `unlimited`: they bill per token and have no
session ceiling, so any number there would be invented, and their limit is a
spend cap rather than a concurrency one.

## The other ceiling nobody wrote down: one PAT, 5000 requests an hour (2026-09-14)

Model capacity is the ceiling on how much *building* the fleet can do. GitHub is the ceiling
on how much **shipping** it can do, and until this change the whole fleet shared one bucket:

- every lane on every box authenticates with `GH_TOKEN` from `env/global.env` (and
  `GH_ADMIN_TOKEN` from `env/github-admin.env` for the repos the default one cannot see);
- `bin/fly-envbundle.sh` copies that same PAT into **every** pool machine's bundle on its own
  `GH_TOKEN=` line, appended right after that copy loop rather than inside it, from the box's
  `gh auth token`, and `die "bundle missing GH_TOKEN …"` refuses a bundle without it. (Since
  2026-09-14 `bin/fly-pool.sh` replaces that line per machine when the App is armed — see the
  table below.)

A personal access token gets **5000 REST requests per hour for the whole account**. The
pollers in `docs/EVENTS.md` §8 spend a few hundred an hour between them before a single build
runs; each build adds its own pushes, `gh pr create`, comments and check reads. So 4000
builder machines share one 5000/h bucket, and the symptom is a 403 in a lane that has no idea
why — a throughput ceiling that looks like weather, which is the same failure shape as the
account ceiling above. It is also **one credential, on thousands of machines, that never
expires**.

`bin/gh-token.sh` + `bin/lib/gh-app-auth.sh` replace it with a GitHub App **installation
token**: rate-limited per installation (and scaling with the installation's repo count rather
than being a flat per-account number), scoped to one repo, dead in an hour.

| | PAT (today, and the fallback) | App installation token |
|---|---|---|
| Rate bucket | 5000/h for the whole account, shared by every box and builder | per installation |
| Lifetime | until revoked | 1 hour |
| Blast radius of a leak | the fleet's whole GitHub identity, forever | one repo, one hour |
| Where a builder gets it | `fly-envbundle.sh` copies the owning box's PAT | `fly-pool.sh` mints one per machine |

This is **not** a cap and it is not a queue. Nothing is refused, deferred or serialised on a
rate limit; the change only stops thousands of machines from drawing on one bucket.

**Off switch:** `touch flags/gh-app-tokens-off`, or `GH_APP_TOKENS=0`, or just never create
`env/github-app.env` — every lane resolves the PAT exactly as it does today, and the unarmed
path forks no extra process. Setup: `docs/OPERATOR-SETUP.md`, "GitHub App installation
tokens". Visibility: `bin/gh-token.sh --status` and `logs/gh-rate.log` (one line per mint,
counts only — no token value is ever logged).

### The lifetime nobody compared to a build (2026-09-14)

The hour an installation token lives is a **safety** property. It is also a ceiling, and
this is the one it hit: a pool build takes 40-75 minutes and its token was minted before
the machine booted.

| | length |
|---|---|
| an installation token | exactly 60 min |
| handed out of `state/gh-app-tokens/` until | 5 min before expiry |
| a pool build | 40-75 min |

13:44-14:15Z on 2026-09-14, project-5: TK-680/681/682 were spawned 13:29Z on a token minted
12:42Z. All three built cleanly and all three were rejected at the pre-PR push —
`remote: Invalid username or token. Password authentication is not supported for Git
operations.` — and requeued as `BUILD_DEFERRED push rejected` after an hour of
performance-8x each. Seven more machines were destroyed unstarted and the fleet went back
on the PAT until this landed. **A credential that expires mid-build is a throughput ceiling
wearing an auth error's clothes**, which is the same disguise the 5000/h bucket wears.

Three changes, all on by default once the App is armed, none of them a queue or a cap:

| | knob | default | what it does |
|---|---|---|---|
| spawn | `POOL_GH_TOKEN_MIN_LIFE` | 3300s (55 min) | no bundle ships a token with less life than this — `bin/gh-token.sh --min-life <sec>` re-mints instead of serving the cache |
| tick | `POOL_GH_TOKEN_ROTATE_BEFORE` | 1200s (20 min) | a live machine inside this much of expiry is pushed a fresh token at `/run/harness-env/gh-token` |
| tick | `POOL_GH_TOKEN_ROTATE_EVERY` | 1800s (30 min) | and never more often than this, per machine |

The due test costs **no GitHub call**: `bin/fly-pool.sh` records `gh_token_expires_at` on the
machine record at spawn (and carries it across a machine REUSE, which is exactly the
long-lived machine this is about), so the tick compares dates against a local file. A
replacement is pushed only when its expiry is genuinely **later** than the one it replaces —
`bin/gh-token.sh` prints the fleet PAT when a mint fails, and a PAT has no cache expiry, so
that one test is what keeps the permanent credential off a builder.

Reading it at the moment it is spent is the other half, because a running process cannot
re-source its environment: `bin/lib/gh-token-live.sh`'s `gh_token_live` is called in
`bin/run-build.sh` immediately before every push, `gh pr create` and the builder-direct
close-out (and in `bin/board-closeout.sh` before its issue comment), and
`fly/gh-credential.sh` is a git credential helper over the same file so plain `git push`
picks up a rotation too. Both are no-ops where the file does not exist, which is every box
that is not a pool machine.

```
2026-09-14 14:31:50Z [pool/project-5] rotated App token on adbff3e8db077c for example-org/project-5 (expires 15:31Z)
```

**Kill flags: two, deliberately.** `flags/gh-app-tokens-off` / `GH_APP_TOKENS=0` is the whole
App path off — no swap, no rotation, no token file, and `fly/builder-runner.sh` keeps the
`gh auth setup-git` helper it has today. `flags/gh-app-rotate-off` / `GH_APP_ROTATE=0` stops
**only** the rotation, leaving the spawn-time swap armed.

---

---

## The pool has no cap by default (2026-09-14)

> "we can launch unlimited builders with fly.io" — the operator, 2026-09-14

`bin/pool-cap.sh` used to answer **3** when nothing was configured. Nine projects
times three machines was a 27-builder fleet ceiling, and nobody had ever chosen
it: it was our default, not Fly's limit. It is gone.

| what | before | now |
|---|---|---|
| nothing configured | 3 machines | **0 = no ceiling** |
| a number in `flags/fly-pool-<p>` | hard ceiling | hard ceiling, unchanged |
| a line in `fly/pool-caps.conf` | hard ceiling | hard ceiling, unchanged |
| `POOL_CAP_MAX` (`env/global.env`) | — | fleet-wide brake, trims every project including unlimited |
| a tick's spawn budget | `cap - live` | **queue depth** (`cap - live` still binds when a cap is set) |
| `bin/fly-pool-tick.sh` | one project after another | every project's tick at once |

`0` is the value, `unlimited` is the word: `bin/concurrency-plan.sh` prints
`unlimited` in the POOL column for exactly the same reason `BUILD_SLOTS=0`
prints it there — a `0` inside `caps_min` would read as *no builds allowed* and
bind the whole row at zero.

**The machine count follows the queue.** `bin/fly-pool.sh` counts the queued jobs
in `state/build-queue/<p>` — the project's materialised `build_queue` rows, one
file per `queued` row, minus the `*.failed.json` parks — and spawns one machine
per queued build in the same tick, concurrently. Forty queued tickets get forty
machines. The old budget made 14 queued jobs take seven ticks; the old *cap*
then made them take as long again once three were running.

Every tick writes one line to `logs/fly-pool.log`, so throughput is a grep and
not a guess:

```
pool project-5: queued=40 running=6 spawning=40 cap=unlimited
```

`spawning=` is the budget the tick launched against; the `spawned <mid> for
<key>` lines below it are the machines that actually came up.

**Write a number only to spend less money than the queue would.** A cap is a
cost decision now, not a capacity one, and it still binds absolutely: the pool
sits on work rather than exceed it. `fly/pool-caps.conf` ships empty —
`project-5 20` was removed with this change, after being raised by hand
1 → 10 → 20 over two days, which is what a ceiling nobody needs looks like on
the way out.

**The legacy flag caps were retired once, by a one-shot that is gone.** Every
box's `flags/fly-pool-<p>` held a number that `bin/fly-pool-rollout.sh` wrote
(2 at wave-3, then 10, then 20 for project-5). From 2026-09-14 a one-shot in
`bin/fly-pool-tick.sh` emptied that number once per project and kept the old
value in `state/fly-pool/legacy-caps.<p>`. It ran on every project and BH-7433
removed it; the old files stay on the hub. Today `bin/fly-pool-rollout.sh`
writes an empty flag unless the operator sets `POOL_CAP`, and a number in the
flag is a cap the tick leaves alone. `fly/pool-caps.conf` is where a ceiling
you actually want belongs, because a reviewed line survives every rollout.

**Kill flag: `POOL_AUTOSCALE=0`** in `env/global.env` (or the environment)
restores every pre-2026-09-14 behaviour byte-for-byte — default 3, `cap - live`,
no per-tick line, `POOL_CAP_MAX` ignored entirely, a sequential
`bin/fly-pool-tick.sh` sweep of the projects left on the hub (a fly-placed
project is batched in both modes; `bin/lane-fleet.sh` scales its lane machines). `bin/pool-cap.sh --autoscale` is the one reader of
that knob, the same way `bin/pool-cap.sh <project>` is the one reader of the cap.

---

## Hotfix lane (2026-09-15)

One label, `hotfix`, beside `ai-build` on a GitHub issue, and the fleet treats
that ticket as the emergency it is. `bin/lib/hotfix-lib.sh` is the only place
that decides what the label means; six callers read it rather than each growing
their own answer, because a ticket that is urgent in one lane and ordinary in
the next still ships — just late, with nothing anywhere saying why.

**What the label buys.**

- **Planned first.** `bin/preplan-candidates.sh` emits hotfix rows at the head
  of its output, ahead of every class including the READY-QUEUE lines that have
  had priority since 2026-07-23. Within the hotfix half the ordinary class order
  (`child`, `ahead`, `blocked`) and oldest-number-first still hold. A hotfix
  never spends the `PREPLAN_AHEAD` budget and is never dropped by it.
- **Built first.** `bin/fly-pool.sh` launches hotfix queue files before plain
  ones, a reused machine takes a hotfix job first, and `bin/fly-dispatch.sh`'s
  one-job-per-project pick prefers one.
- **One row past the cap.** A hotfix takes a free budget slot when the pool has
  one. Only when the pool is at cap does it exceed the cap, by **one machine per
  queued hotfix**, and never as a suspension of the cap: the exemption adds no
  slot for anyone else, so plain builds behind it still wait on the budget. Both
  caps work this way — the pool's machine cap in `bin/fly-pool.sh`, and
  `flags/wip-limit-<p>` in `bin/run-build.sh`. Both exemptions log the line they
  exceeded, and only when they are actually spent: `hotfix <KEY>: pool at cap N
  (budget spent) — exceeding it by one machine` in `logs/fly-pool.log`, and
  `hotfix: wip-limit N reached, exceeding it by one for <KEY>` in the build's
  `pipeline.log`. A hotfix that took a free budget slot logs neither — it
  exceeded nothing.
- **Its PR carries the label** and opens its body with `HOTFIX:`. The label
  goes on by a follow-up `POST repos/<slug>/issues/<n>/labels`, never
  `gh pr create --label`: that flag fails the whole CREATE when the label does
  not exist in the repo, which would turn a missing label into a lost PR. A
  failed label write is one ALERTS line naming `gh label create` and never a
  failed build.
- **It announces itself three times** through the existing beat path, no new
  sink: `seen` (the triage tick, or the build as a backstop), `pr_open`, and
  `merged` (tier-1 here; the merge conductor calls the same helper for tier-2).
  The akeys are `hotfix:<project>:<KEY>:<event>` and the beats carry
  `triaged:true`, because `bin/beat.sh` quarantines an untriaged `fleet_alert`
  for the 10-minute medic and an emergency announced 10-45 minutes late is the
  wrong shape for the one lane whose whole purpose is speed. A marker under
  `state/hotfix-announced/<project>/<KEY>.<event>` makes each one happen once
  for life; it is written AFTER the beat, so a crash costs a duplicate line and
  never a missed one.

- **Its split children inherit it** (BH-637). When the size gate splits a hotfix
  parent, `bin/run-decompose.sh` files every child with the parent's labels that
  are in the harness's own vocabulary — `ai-build` plus `HOTFIX_LABEL`, plus
  anything an operator names in `DECOMPOSE_INHERIT_LABELS`. Before this, children
  were filed with the literal `--label ai-build`, so every lane above selected on
  a label the children did not have and the split silently dropped out of the
  lane its parent was in. The set applied is logged per child in the build
  record's `pipeline.log` (`child 2 labels: ai-build,hotfix (inherited from
  parent #552: hotfix)`). It is a whitelist, not a copy: `not-hotfix` and
  `hotfix-candidate` are somebody saying "no" and somebody asking, and neither
  buys a cap exemption. See
  [verification-map/closed-issue-hygiene.md](verification-map/closed-issue-hygiene.md).

**What the label does NOT buy.**

- **A live blocker still holds it.** A hotfix whose `Blocked-by: #n` (or
  `Needs: #n` — read as a hard blocker on hotfix rows only) names an issue that
  is still open and unclaimed is not emitted at all. A hotfix that needs code
  which has not landed is not ready, whatever its label says.
- **`flags/paused-<p>` still holds it.** A pause is a human decision and
  overriding it is out of scope: the pool applies no exemption and logs
  `waiting on the pause`, and the triage tick writes one line per tick naming
  the hotfix that is held.
- **`flags/pool-halt-<p>`, `BUILD_SLOTS`, the per-key dedupe lock and the
  file-overlap deferral** are all untouched. The first two are health and
  hardware decisions, and the last two are not caps at all — "already building"
  and "not now" are different answers from "the project is at its limit".
- **An issue without `ai-build` is invisible.** Every listing in the fleet
  filters on that label first, so `hotfix` alone does nothing.
- **In-app product boards have no hotfix in v1.** The label lives on a GitHub
  issue; every predicate answers "not a hotfix" for a board-prefix project and
  those lanes are byte-identical.

**Knobs.** `HOTFIX_LABEL` (`env/global.env` or the environment, default
`hotfix`) is the label name. `HOTFIX_LANE=0`, or `flags/hotfix-lane-off`, is the
kill flag: every predicate answers no, the announcements are silent, and the
fleet is what it was before this lane. Neither has to be set anywhere.

---

## Priority yield

The file-overlap deferral above breaks its tie by arrival order: whoever claimed
the file first keeps it, and the other build goes back to the queue until that
claim disappears — a `RESULT`, or the 4h ageout on `state/claims/<project>/`.
For two ordinary builds that is the right answer. For a hotfix sitting behind a
plain build it is four hours of an emergency waiting on work nobody called
urgent, and nothing anywhere said so.

So when the build that is about to defer **outranks** the sibling holding the
claim, it leaves a marker in that sibling's build dir on the way out, and the
sibling stands down at its next safe stage boundary. Ranks are
`bin/lib/hotfix-lib.sh`'s, read from each build's own `ticket-meta.json` at no
API cost: **0** hotfix, **1** main-red, **2** everything else.

**This is not a queue and nothing waits.** The deferring build still writes
`BUILD_DEFERRED` and exits at once, exactly as before; all it changes is how
long the claim takes to clear. The yielding build does not pause either — it
writes its own terminal and gets out of the way. Neither one blocks on the
other (the operator, 2026-09-13: "we never lock and serialize").

**Knobs.** `PRIORITY_YIELD=0` (`env/global.env` or the environment; `off`,
`false` and `no` mean the same), or `flags/priority-yield-off` for a switch from
the console — either one makes both halves no-ops and the pipeline byte-for-byte
what it was before. `MAIN_RED_LABEL` (default `fix-main-red`) and `HOTFIX_LABEL`
(default `hotfix`) are the two label names that decide the ranks; both are
whole-name matches, so `hotfix-candidate` and `not-hotfix` are ordinary tickets.

**Files written.**

| path | written by | says |
|---|---|---|
| `builds/<sibling>/YIELD` | the deferring build | `requested_by=<KEY> rank=<n> at=<ts>` — one line, never overwritten if it is already there |
| `builds/<self>/YIELD.honored` | the yielding build | the same line, renamed as it is consumed, so a resumed dir does not stand down for ever |
| `<build>/pipeline.log` | both | `priority yield: asked <dir> to stand down …` on the requester (naming both ranks), `PRIORITY YIELD at <stage>: …` on the recipient |
| `<build>/RESULT` | both | requester: `BUILD_DEFERRED file overlap … the sibling <KEY> yields at its next checkpoint`. Recipient: `BUILD_DEFERRED yielded to <KEY> at <stage> — <where the tree is>` |

No new RESULT terminal: both are `BUILD_DEFERRED`, which `_job_finish` already
maps to `parked` → `queued`, so `docs/RUN-BUILD-GRAPH.md`, the console stage
sets and the sweep verdict list are all unchanged. The claim itself is released
by the ordinary EXIT trap, not by the yield.

**Never.**

- Never plain vs plain, and never equal ranks. Strictly `MY_RANK < SIB_RANK`.
- Never a lower-ranked build evicting a higher one — a main-red build does not
  move a hotfix.
- Never a sibling that already wrote a `RESULT`: it is finished, it cannot
  yield, and promising that it will would be a wake condition that never fires.
- Never on an unreadable sibling `ticket-meta.json`. That is rank 2 and it is
  logged; reading "unknown" as urgent would let any pre-`ticket-meta` build dir
  evict an emergency.
- Never after the PR is open. The three boundaries are after the plan overlap
  check, after the execute-stage push, and before the review lenses — an open PR
  with no build behind it is worse than a slow emergency.
- Never a wait. The deferring build exits 3 immediately whether or not the
  marker landed.
- Never when `OVERLAP_DEFER_ENFORCE=0`: that build is proceeding into the
  overlap itself, and a build that is not standing down does not get to ask
  anybody else to.

---

## Proposing a rule set

```bash
bin/concurrency-apply.sh --dry-run     # prints the plan, writes nothing
bin/concurrency-apply.sh --apply       # writes it, via jobs-client rule-set
```

```
proposed repo/<p>/build = min( bin/pool-cap.sh <p> , bin/account-capacity.sh <vendor> )
```

- **An unlimited pool leaves the account half alone.** Since 2026-09-14 the pool
  is usually not a cap at all, so `min()` is `bin/account-capacity.sh` and the
  proposal says so. With both halves unlimited there is no number to propose and
  the row says that too — "no proposal" for a reason, not because a cap could not
  be read.

- **Pool projects only.** On the local route the repo rule is not what binds, so
  raising it would promise parallelism the box cannot deliver and lowering it
  would change nothing visible. Those rows say "no change" and why.
- **Never raw SQL.** The rule is a row behind an API whose specificity ladder the
  worker owns (`ruleFor()`: `[selector,kind]`, `[selector,*]`, `[*,kind]`,
  `[*,*]` — selector outranks kind). Every write goes through
  `bin/jobs-client.sh rule-set`, which is one `PUT /api/rules`, not a deploy.
- **Idempotent.** A project already at its proposed value is not written at all.
- **No default mode.** Run bare, it refuses. The first thing an operator does is
  run a script to see what it says; a script that writes fleet caps when run
  bare is a trap.

The pool cap and the repo rule have been raised **by hand, in lockstep**, twice
(2026-09-11 `1 → 10`, 2026-09-12 `10 → 20` for project-5). That keeps those two
agreeing with each other and neither of them agreeing with the account. The
apply script exists so the second number is derived from the first and from the
account, in one place, instead of remembered.

---

## The invariant

A cap nothing checks is a wish. `bin/pipeline-health.sh` check 14 (`overcap`,
hub cron `*/10`) compares **running `build` rows** per project against the
effective limit `bin/concurrency-plan.sh` computes, and pages when they exceed
it:

```
<project> has N build(s) RUNNING against an effective ceiling of M (<bound by>).
Either a cap is being bypassed or the caps disagree — bin/concurrency-plan.sh <p>
shows every one of them, and bin/concurrency-apply.sh --dry-run proposes the set
that would hold.
```

It **reads** the limit and never recomputes it — a second copy of that
arithmetic is the defect this lane exists to end. It is retractable
(`RETRACT_NS`), so an overshoot that clears closes its own alert. It checks pool
projects only, for the reason above: a local-route ceiling read from the hub
would be the hub's flags, and an alert from that would be a guess.

Check 14 is the mirror of check 13 (`starved`, "launchable work and nothing
running"). Between them, a lane that is doing too little and a lane that is doing
more than it may both have a deterministic voice.

---

## One constant, one home

`FLY_DISPATCH_WIP` lives in `bin/lib/build-caps.sh`. It used to be a comment in
`bin/fly-dispatch.sh` ("one job at a time (wip=1)") plus a shape in the code —
one `<p>-active.json`, so at most one claim. Nothing could report it and nothing
would have noticed if the shape changed. The dispatcher now reads the value and
counts against it before claiming; with it at 1 that is byte-for-byte today's
behaviour, and `bin/concurrency-plan.sh` reports the same number from the same
file, so the table and the dispatcher cannot come to disagree.

Same reasoning keeps `bin/pool-cap.sh` the one reader of the pool cap's
resolution order, and `bin/lib/build-caps.sh:caps_rule` a deliberate
transcription of the worker's `ruleFor()` ladder. Two ladders that disagree is
how a rule comes to bind somewhere nobody meant — which is the schema's own
warning, in its own words.

---

## Files

| path | what it is |
|---|---|
| `bin/concurrency-plan.sh` | the table: every cap, which apply, the effective limit |
| `bin/concurrency-apply.sh` | the proposal, `--dry-run` \| `--apply` |
| `bin/account-capacity.sh` | heavy sessions the paying account can serve |
| `bin/lib/build-caps.sh` | the shared ladder, minimum, route, `FLY_DISPATCH_WIP` and `build_slots` |
| `bin/lib/preplan-lib.sh` | the pre-plan vocabulary: the kill flag, `PREPLAN_PARALLEL`/`PREPLAN_AHEAD`, `preplan_find`, `preplan_check`, `preplan_held` |
| `bin/preplan-candidates.sh` | which tickets are worth a speculative plan, per project |
| `bin/preplan-tick.sh` | launches them, within `PREPLAN_PARALLEL` |
| `tests/preplan-speculative-test.sh` | candidate selection, the cap, the staleness discard, the relay guard, flag-off |
| `tests/no-serialize-test.sh` | pins the no-queueing rules: the contract text, the rescue lane, the pool spawn burst, `BUILD_SLOTS=0` |
| `bin/lib/hotfix-lib.sh` | the hotfix vocabulary: the kill flag, `HOTFIX_LABEL`, the label matchers (issue, ticket-meta, job file, KEY) and `hotfix_announce` |
| `bin/hotfix-seen.sh` | the first-seen announcement per project, and the one line a hotfix held by `flags/paused-<p>` writes each tick |
| `tests/hotfix-dispatch-order-test.sh` | the lib's predicates incl. the adversarial label names, the announcement's once-for-life marker, hotfix-first ordering against a real `preplan-candidates.sh`, and a blocked hotfix never being emitted |
| `tests/hotfix-cap-exempt-test.sh` | the pool budget and the exemption at cap, hotfix-first spawn and reuse, the flag surviving every requeue and the DB materialise, the dispatcher pick under the kill flag, and a pause getting no exemption |
| `tests/hotfix-wip-gate-test.sh` | the WIP gate driven at the cap with and without a hotfix |
| `tests/hotfix-pr-label-test.sh` | the PR-open region driven: the label write, the `HOTFIX:` first body line, the `pr_open` announcement, and a failed label write being loud and harmless |
| `bin/unblocked-children.sh` | the `UNBLOCKED` / `STACKABLE` reading-list lines: which blocked child a tick may launch, and on which base |
| `bin/orphan-reconcile.sh` | the OWNER of every open `ai-build` issue, recomputed from scratch each tick, and the enqueue for one that has none (docs/EVENTS.md §5.4); `ORPHAN_GRACE_MIN`, `ORPHAN_MAX_PER_RUN`, `ORPHAN_RECONCILE=0` |
| `tests/orphan-reconcile-test.sh` | each owner class claiming its own ticket, the orphan launching, the grace window and marker idempotence, the cap, the build-key-lock and un-swept-`RESULT` refusals, and the fail-closed answers |
| `bin/dep-verify.sh` | `HARD` / `SOFT` / `UNKNOWN` for one `(child, blocker)` pair, cached on the evidence; `DEP_VERIFY_DRY_RUN=1` to inspect one without writing |
| `bin/lib/dep-verify-lib.sh` | the dep-verify vocabulary: the kill flag, the cache paths, the repo mapping, the normalisation + overlap rule, the `DEPENDS:` and escape-hatch parsers |
| `tests/dep-verify-test.sh` | every incomplete-evidence shape coming back `UNKNOWN`, `SOFT` only with both halves, the escape hatch beating a plan that disagrees, cache invalidation on a plan edit, dry-run and both kill-flag spellings |
| `tests/unblocked-children-test.sh` | the reading-list lines themselves, plus the soft-`UNBLOCKED` line, its one-per-child thread comment and `DEP_VERIFY=0` restoring `STACKABLE`; `DEP_UNKNOWN_MODE` in both settings (an un-pre-planned child released by default, held under `hard`, a real `HARD` pair held under both); and a blocker missing from the `ai-build` list being fetched by number rather than read as closed |
| `tests/event-wake-scope-test.sh` | which TICK runs the pass: `event-wake` scopes like `board-changed`, and an unchanged board still runs it (docs/EVENTS.md §5.3) |
| `tests/stacked-child-builds-test.sh` | drives the chain-overlap path: STACKABLE emission, run-build's base selection against a real repo, the conductor's `STACKED_WAIT` |
| `fly/account-capacity.conf` | per-account session count, a reviewed line |
| `fly/pool-caps.conf` | per-project pool machine cap, a reviewed line — empty by default since 2026-09-14 |
| `tests/pool-cap-test.sh` | the cap ladder, `POOL_CAP_MAX`, and the `POOL_AUTOSCALE=0` answer for each |
| `tests/pool-autoscale-test.sh` | drives `bin/fly-pool.sh` with a stubbed flyctl: queue depth sets the machine count |
| `tests/concurrency-plan-test.sh` | drives all of it against scratch trees |
| `tests/docs-anchor-drift-test.sh` | every `file:line` citation in this doc, `bin/concurrency-plan.sh` and `bin/lib/build-caps.sh` resolves to its quoted marker or is an anchor; the named run-build / fly-dispatch / fly-envbundle markers still exist |
| `tests/pipeline-gaps-test.sh` | pins the in-build lane: the overlap, the join before the first tree write, and `GATES_PARALLEL=0` |
| `bin/lib/triage-shards-lib.sh` | the triage-shard vocabulary: the kill flag, `TRIAGE_SHARDS_MAX`, the key canon, the key lock census, the fingerprint re-arm |
| `bin/triage-shard.sh` | one triage session for one ticket: the key lock, the ticket-keyed ledger claim, the agent call, the re-arm on failure |
| `bin/queue-line-drop.sh` | the locked read-modify-write shards use to consume their own `READY-QUEUE.log` line |
| `tests/triage-shards-test.sh` | drives `bin/run-triage.sh` end to end: 3 keys -> 3 detached shards + 3 locks, a held key skipped and named, the three lists merged onto one ticket, the cap leaving units in scope, `TRIAGE_SHARDS=0` |
| `bin/conflict-check.sh` | the ORIGINAL overlap gate: this box's `builds/` only, unchanged |
| `bin/plan-overlap.sh` | the fleet-wide one: claims ledger + the queue's `claimed` rows, `OVERLAP_DEFER` on stdout, `OVERLAP_SCHED=0` to disarm |
| `tests/merge-funnel-test.sh` | drives `plan-overlap.sh` (defer, pass, dead claim, live claim, no plan data, both kill flags) and `run-build.sh`'s not-before gate, plus the conductor's two funnel tests against a real repo |

| `bin/gh-token.sh` | mints/caches the repo-scoped GitHub App installation token; `--min-life`/`--fresh`, `--expires-at`, `--status`, `--warm` |
| `bin/lib/gh-app-auth.sh` | `gh_auth_for` / `gh_auth_reset` / `gh_auth_armed` — the two lines a lane adds |
| `bin/lib/gh-token-live.sh` | `gh_token_live` — read the rotated token at the moment it is spent, or leave the environment alone |
| `fly/gh-credential.sh` | the git credential helper over the same file, so plain `git push` sees a rotation |
| `tests/gh-token-test.sh` | JWT shape + signature, repo scope, cache reuse and refresh, `--min-life`/`--fresh`/`--expires-at`, PAT fallback, mint dedupe |
| `tests/gh-token-rotate-test.sh` | drives `bin/fly-pool.sh` with a stubbed flyctl: spawn freshness, rotate-due from `gh_token_expires_at`, the 30-minute floor, the newer-only guard, `gh_token_live`, the credential helper, both kill flags |
| `bin/lib/builder-direct.sh` | the builder-direct vocabulary: the kill flag, the RESULT-line marker, `bd_facts`, `bd_result_in_ledger` |
| `bin/board-closeout.sh` | the mechanical what-shipped comment + status move a builder posts for itself |
| `tests/builder-direct-test.sh` | drives the claim stand-down, the close-out, the marker, and the hub ingest's no-op |

## Pool accounts: the reading that excluded every one of them (2026-09-16)

The account ceiling above only lifts if the pool actually leases the accounts it
holds. For most of a day it leased none of them, and said so 80 times:

```
m... ships the default project-6 token (default_saturated)
```

Nothing was saturated. `bin/quota-poll.sh` writes `status: unreadable` for a
claude account that has no `CLAUDE_CONFIG_DIR` — its header has said so since it
was written, because a setup token gets 403 on the usage endpoint and there is
nothing honest to write. Every account the pool can ship is exactly that shape:
`env/accounts.d/max1..7.env` hold shippable setup tokens and no login dir. The
pool's filter kept only `status: ok`, so it kept nothing, ranked nothing, and
shipped the one default token to every machine — which was weekly-capped that
morning, so every pool Claude call failed and the ladder fell through to the
metered vendors at roughly $140-340 an hour until someone read the log.

The hub's own picker never had this problem. `account_headroom` has always
counted an unreadable poll as "no evidence against", because refusing every
account the day the poller breaks takes the whole fleet down. **Two pickers, two
readings of the same file, and the disagreement was invisible** — each one looked
correct on its own.

So there is one classifier now, `account_reading_class` in
`bin/account-pick.sh`, and both pickers branch on its answer:

| class | what it means | hub | pool |
|---|---|---|---|
| `metered` | fresh `ok` poll under every threshold | use, rank on the pct | use, rank on the pct |
| `capped` | fresh `ok` poll at or over one | skip | skip |
| `unreadable` | poller reached it, has no numbers by design | use | **use**, empty meter |
| `stale` | `ok` poll older than `ACCOUNT_POLL_STALE_SECS`, or a poller that said so itself | use | skip |
| `none` | no file, unknown, unmetered, errored | use | skip |

The two remaining differences are deliberate and are pinned by a test. The hub
fails OPEN on stale/none because its fallback is a refused call; the pool fails
CLOSED because its fallback is a token that still works, so guessing at numbers
it has no fresh evidence for can cost a 40-minute build. `unreadable` is not one
of those cases: it is the poller answering, not the poller stopping — so an
`unreadable` reading stays `unreadable` however old its `polled_at` is.

An unreadable account ranks with an **empty meter**, which falls to the 999
default in the score — so priority number and live leases do the ranking, which
is exactly what the lease weight exists for.

And the fallback line now names its class, because `default_saturated` meant
both "every account is exhausted" and "we cannot read any account", which are a
quota problem and an instrumentation problem with nothing in common:

```
m... ships the default project-6 token (all_capped)   # a real ceiling
m... ships the default project-6 token (all_stale)    # every meter stale or missing: a poller that stopped
m... ships the default project-6 token (all_cooling)  # every account refused recently
m... ships the default project-6 token (all_leased)   # every account at its lease cap
```

There is deliberately no `all_unreadable`: `unreadable` is the class that now
RANKS, so it cannot leave the pool on the default token, and a reason naming it
would send the next operator to the wrong file.

`default_saturated` survives only for a mixed set of causes — and for the
defensive case where no candidate account existed at all.

| path | what it is |
|---|---|
| `bin/account-pick.sh` | `account_reading_class` — the one reading both pickers judge on — and `account_headroom` over it |
| `bin/lib/pool-account.sh` | `_pa_metered` (the pool's verdict on that class) and `_pa_saturated_reason` (which class left the pool on the default token) |
| `tests/pool-account-test.sh` | an all-unreadable registry still leasing, cooldown and stale still skipped, the two pickers answering the same file, and every fallback class |
| `tests/pool-account-routing-test.sh` | case 4: the saturated answer, its untouched bundle, and `reason=all_capped` in the routing log |

---

## The file half without the pre-plan (2026-09-16)

**What broke.** `bin/dep-verify.sh` needs two halves to answer `SOFT`: the
child's planned files disjoint from the blocker's, and a semantic statement that
the link is ordering-only. Both came from the same place — the speculative
pre-plan. On 2026-09-16 that lane was switched off (`flags/preplan-speculative-off`)
because 34 of 52 plans in three hours came back `PREPLAN_STALE` against a moving
`main`, at $2-6 a ticket on a frontier model. The evidence went off with it, and
every `Blocked-by:` line went back to being obeyed rather than checked:

```
DEP_HARD 1506 vs 1505 — UNKNOWN, treated as hard: no planned-files list for child
```

**Deterministic before LLM.** Most of that evidence was in the ticket body the
whole time. `bin/planned-files-cheap.sh <project> <KEY>` writes the same
`plans/<project>-<KEY>/planned-files.txt`, with a `SOURCE:` header naming the
tier that produced it:

| `SOURCE:` | how | cost |
|---|---|---|
| `ticket-body` | every repo-relative path token in the issue body, kept if it exists in the checkout or sits under a directory that does (a NEW file is the normal case, and its directory is what the overlap rule compares) | free |
| `ticket-body+codegraph` | plus each named file's DIRECT importers, one hop, from the repo's own `.codegraph/` index | free |
| `model-floor` | one call, ONLY when the two above found nothing, on the cheapest Claude-family row in `catalog/model-prices.json` — resolved, never pinned in the script | cents |

The extractor is `bin/planned-files.sh`'s, transcribed: same extensions, same
top-level prefixes, same bare-directory scopes, same fewer-than-three-segments
prune. Two spellings of "the files this ticket owns" is a child whose list means
something different from its parent's, compared against each other as though it
did not.

**The floor call is capped and pays before it spends.**
`state/preplan-files/<project>-<KEY>.called` is written BEFORE the call and
burns the window on every exit from it — success, failure, and the outcome that
costs most when it is missed, a call that succeeded and returned nothing. One
call per ticket per `PLANNED_FILES_MODEL_TTL` (default 6h). Cost rows land under
stage `preplan-files`, budgeted as its own lane in
`catalog/context-budgets.json`. A directory that already holds a real `plan.md`
is left alone: a planner that read the code beats a body scrape, and overwriting
it would downgrade the evidence silently.

**The header is never a path.** `bin/lib/dep-verify-lib.sh:dep_norm` and
`bin/overlap-guard.sh:prune` — the only two direct readers of that file — both
drop it, and that is not tidiness: the header is a line every cheap list
*shares*, so left in the comparison two unrelated children collide on
`SOURCE: ticket-body` and one of them is held. The overlap guard fails open, so
the only symptom would have been builds standing down for a reason nobody could
find.

**What `dep-verify` does with it.** The file half is unchanged — overlap is
`HARD` whatever wrote the list. What changes is the missing `DEPENDS:` line. A deterministic list
*cannot* carry one, because no model read the code, so for `ticket-body` and
`ticket-body+codegraph` the semantic half is the child body's own silence:

> disjoint files **and** no `Needs:` / `(hard)` marker anywhere in the body → `SOFT`.

Narrow on purpose. `model-floor` is excluded — a model guessing paths out of a
body that named none may say `HARD` on an overlap and never `SOFT` on a
disjoint. The marker test is body-WIDE, not per-blocker: an author who wrote
`Needs: #12` has said this slice is not free-standing, and inferring
independence from a list they never wrote is the wrong direction to be confident
in. The author's escape hatch still outranks all of it, and a headerless list
with no `DEPENDS:` line answers `UNKNOWN` exactly as it did before.

The `SOURCE:` value is part of the cached evidence fingerprint (`|v2`), so the
same paths with and without a header are two questions, not one replayed answer.

**Where it runs.** `bin/preplan-candidates.sh` runs it for every `child` and
`blocked` row when `PREPLAN_SPECULATIVE=0` — the case where those rows are
printed and then never planned. The bodies come from the `gh issue list` that
script already makes, so the pass costs zero extra GitHub requests. Kill flag:
`PLANNED_FILES_CHEAP=0` or `flags/planned-files-cheap-off`, and either one makes
it write nothing at all.

---

## Schedule by planned-file overlap (BH-475, 2026-09-16)

**The number.** In 24h the ledger showed 17 cromford builds as `planning`;
9 of them actually ended `BUILD_DEFERRED file overlap — CONFLICT with <sibling>`
after a **0-minute** wait, on the same handful of shared files
(`docs/MERGE-CONDUCTOR.md`, `docs/EVENTS.md`, `docs/BUILD-CONCURRENCY.md`,
`docs/verification-map/README.md`, `tests/arch-contract-test.sh`,
`tests/clock-sync-test.sh`). Across the last 100 merged PRs on this repo, 76
touch at least one file that 6+ other PRs also touch. Every one of those
deferrals was bought *after* a plan session was paid for, and the requeue buys a
fresh plan — so the overlap check was running in the most expensive place it
could run, given that both plans' `planned-files.txt` already existed.

**What changed.** The question moved in front of the launch. It did not replace
anything: `# >>> overlap wait` and `# >>> plan overlap` in `bin/run-build.sh`
(`bin/conflict-check.sh`, `bin/plan-overlap.sh`) are untouched and remain the
backstop for everything the schedule could not see.

```bash
bin/overlap-schedule.sh <project>                      # the whole order
bin/overlap-schedule.sh <project> --key BH-475         # one ticket's verdict
bin/overlap-schedule.sh <project> --hot-for <list> KEY # the reviewer's line
```

Output — this is a real run on box-small, 2026-09-16, against this
repo's own pre-plans and claims, trimmed to the shape. (It predates the shared
`OVERLAP_IGNORE`: the `docs/OPERATOR-SETUP.md` hold it showed then is exempt
now, and a run today would not print it.)

```
WAVE 1: BH-377 BH-441 BH-452
WAVE 2: BH-453
HELD: BH-455 overlaps in-flight BH-393 on tests/transcript-cost-test.sh
UNPLANNED: BH-454 BH-431 BH-438 BH-444 ...
HOT-FILES:
tests/claim-rules-test.sh :: BH-415 BH-416 BH-417 BH-418 BH-393
docs/verification-map/README.md :: BH-418 BH-439 BH-442 BH-393
tests/env-path-test.sh :: BH-452 BH-453 BH-455
tests/preplan-speculative-test.sh :: BH-416 BH-440 BH-475
```

...and `--hot-for`, the line the reviewer gets, from the same run:

```
this ticket touches tests/env-path-test.sh, shared with BH-452 BH-453 BH-455 — consider moving the change to a per-ticket file
```

- **WAVE n** — greedy graph colouring over the pre-plans' file lists. Wave 1 is
  an independent set: every key in it can build at the same time without any two
  of them meeting at merge. **A wave is ORDER, not a veto** (see below).
- **HELD** — the plan collides with a build running *right now*: a claim under
  `state/claims/<project>/`, a live build dir (no `RESULT`, touched inside 4h),
  or a `claimed` row in the jobs ledger. Not launchable this tick. This is the
  only hard stop the schedule produces, and it clears itself when that build
  finishes (its `RESULT`, its claim, or the 4h age-out). A claim file is only
  read as in flight while the jobs ledger still calls that key `claimed` —
  `bin/plan-overlap.sh`'s `live()` rule, so a build killed without its EXIT trap
  cannot hold its siblings for the next four hours. A killed build leaves
  **two** artifacts, its claim file and its build directory, so the claim key is
  recorded as decided *before* the liveness check and its build directory is not
  read as a second opinion — the ordering `bin/plan-overlap.sh` uses, and the
  half that makes the sentence above true (a first cut of this filtered only the
  claim file, and the leftovers put the `HELD` straight back). A build directory
  with no claim file is still judged on its own. A ledger **outage** is not an
  answer: with no reply at all the claim file is trusted exactly as before.
  **Liveness is the build-key flock first, the ledger second.** Not every build
  has a ledger row — every direct `setsid run-build.sh` launch (a triage
  session, `bin/orphan-reconcile.sh`, `bin/blocked-resolver.sh`, a medic
  relaunch) runs without one — and for those keys the ledger answers "not
  claimed" for the same reason it answers that about a corpse. So the first
  question is `locks/build-key-<project>-<KEY>.lock`, which `bin/run-build.sh`
  holds for the build's whole life and the kernel releases the moment it dies:
  a running build still holds it, a killed one does not. That is the signal that
  tells a live row-less build from a stranded one, and it is the same lock
  `bin/preplan-tick.sh` already reads through `preplan_held`. The ledger is
  asked second, because it is the only thing that can see another box.
- **UNPLANNED** — ready, but no pre-plan file list yet. It **stays launchable**:
  the standing rule for this question is "no plan data → cannot judge → allow"
  (`bin/conflict-check.sh`), and the launch-time defer still covers it.
- **HOT-FILES** — files ≥ `OVERLAP_HOT_MIN` planned tickets name, with the
  tickets. This is the only part that can actually shrink the problem: it is the
  input to "should this change live in a per-ticket file instead?"

**A wave never holds a ticket for more than the tick it was computed in.**
`HELD` names a build that is running, so it ends when that build ends. A wave
does not: the wave-1 key a wave-2 key yields to may itself never launch (a
blocking PR still open, no slot, another shard's ticket), and "not this tick",
re-derived every tick, is a ticket nobody ever builds. So the launch rule the
tick and shard prompts carry says the wave-1 key goes **first**, and **if it
does not launch this tick, the wave-2 key launches anyway** — with
`bin/overlap-guard.sh` at launch time as the gate that settles it either way.
The prompts' wording is driven, not grepped, by
`tests/overlap-schedule-test.sh` cases 11 and 11c.

**One deferral rule, shared with the launch guard.** `bin/overlap-guard.sh`
(#366, 2026-09-15 — `docs/SCHEDULER.md`) already answers "do these two touch the
same files?" at launch time, and it exempts `package.json`, `package-lock.json`
and `*.md` and honours a Jaccard threshold, because the merge conductor
union-resolves those classes deterministically. This scheduler reads
`OVERLAP_IGNORE` and `OVERLAP_THRESHOLD` from the same
`bin/lib/scheduler-conf.sh` (environment → `flags/scheduler.conf` → the
documented default), so the two rules in one tick prompt cannot disagree about
which files are worth a delay. The exemption governs **collisions only** — the
`HOT-FILES` report still counts every planned path, because "should this change
live in a per-ticket file?" is a fair question about a shared doc even when the
conductor can merge it.

**Priority is the classifier's, in one place.** `bin/preplan-candidates.sh`
emits its rows in priority order and marks a hotfix (#368) *only* by emitting it
first — the class field of a hotfix stays `ahead`. So this script sorts by the
classifier's row order and keeps no rank table of its own; re-deriving one by
(class, ticket number) discarded the hotfix signal and could hand an emergency
ticket `WAVE 2` behind an ordinary one.

**The overlap rule is not a new one.** It is `dep_overlap`'s, transcribed:
two plans conflict when any planned path of one equals, or is a path-prefix of,
a planned path of the other, with the TK-667 prune in front (an entry that
another entry *of the same list* names a file under is dropped — the bare
directory is where the file lives, not a second claim).
`tests/overlap-schedule-test.sh` case 8 pins the two implementations *equal*,
not merely similar.

**Who consumes it.**

| consumer | what it gets |
|---|---|
| `bin/lib/rt/scope.sh` (the scope stage `bin/run-triage.sh` sources), `# >>> overlap schedule feed` | one `OVERLAP SCHEDULE` section appended to the tick's prompt, plus one `HOT-FILES:` line per hot file in `logs/<project>.log` |
| `bin/lib/rt/shards.sh`, the shard loop | `--key <KEY>`, one line, in that shard's own prompt |
| `bin/run-build.sh`, `# >>> hot files` | `$BUILD/hot-files.txt` → a `HOT FILES:` paragraph in `GATES_NOTE` for the reviewer |

**Knobs** (environment, or `env/global.env`; resolved by
`bin/lib/preplan-lib.sh` like every `PREPLAN_*` knob):

| knob | default | what it does |
|---|---|---|
| `OVERLAP_SCHEDULE` / `flags/overlap-schedule-off` | on | kill switch. Off ⇒ the script prints nothing, every consumer is a no-op, and the launch-time defer is the sole gate again — byte-for-byte the behaviour before this change. |
| `OVERLAP_HOT_MIN` | `3` | how many planned tickets make a file hot |
| `OVERLAP_SNAPSHOT_MAX_AGE` | `600` (s) | how long `state/preplan-candidates/<project>.tsv` stays usable before the scheduler asks the classifier live |
| `PREPLAN_AHEAD_READY` | `10` | how many untouched READY tickets get a pre-plan while the schedule is on. The graph's input, and the one number that moves the fleet's pre-plan spend. |
| `PREPLAN_AHEAD` | `2` | bounds the `blocked` class, and still bounds the `ready` class **whenever it is set explicitly** (see below). |
| `PREPLAN_MAX_ATTEMPTS` | `3` | how many FAILED pre-plan sessions one key may cost before it is terminal (see the three outcomes below). |

Shared with `bin/overlap-guard.sh` through `bin/lib/scheduler-conf.sh`
(environment → `flags/scheduler.conf` → default):

| knob | default | what it does |
|---|---|---|
| `OVERLAP_IGNORE` | `package.json package-lock.json *.md` | paths that are never a scheduling collision (the conductor union-resolves them). Still reported in `HOT-FILES`. |
| `OVERLAP_THRESHOLD` | `0` | Jaccard below which a hit is not a collision. `0` means any shared path collides. |

**`PREPLAN_AHEAD=0` is still the ready-class kill switch.** The raise the graph
needs has its own knob, `PREPLAN_AHEAD_READY` (default `10`), and it applies
only where nobody has said otherwise: if `PREPLAN_AHEAD` is set explicitly — in
the environment or `env/global.env` — that number keeps bounding the ready class
with the schedule on, because a box that set it is controlling spend and every
pre-plan is a paid model session. Set `PREPLAN_AHEAD_READY` to override that on
purpose. `OVERLAP_SCHEDULE=0` / `flags/overlap-schedule-off` restores the
`PREPLAN_AHEAD` bound outright, and `PREPLAN_SPECULATIVE=0` stops the fan-out
altogether. **No box has to change anything before this lands.**

**A pre-plan is a billable call, so it has three outcomes and a cap.** Until
BH-475's review, `bin/run-preplan.sh`'s "produced no plan.md" path deleted the
directory and left nothing behind — so the next tick with a free slot bought the
same key again, every ~10 minutes, for as long as it stayed in the ready set.
The ledger is the pre-plan directory itself (the same one the freshness dedup
already reads), and every non-success exit now writes to it:

| outcome | what happened | what the fleet does |
|---|---|---|
| `ok` | `plan.md` was written | `preplan_check` owns the key from here; any attempt record is cleared |
| `empty` | the session exited 0 and produced no plan (a refusal, an empty completion) | it was **billed** and it answered: **terminal**, never bought again |
| `failed` | the session died (timeout, crash, non-zero exit) | retried to `PREPLAN_MAX_ATTEMPTS` (3), then terminal |
| *not an outcome* | `bin/agent-call.sh` refused **before** any model call: rc 76 (no account headroom), 77 (the hub runs no build work), 78 (a no-tools refusal), 79 (an argv-only lane refused the prompt, or a grok call was cliff-routed), 75 (documented, no producer today) **and** no new `logs/cost.csv` row | nothing was called and nothing was billed, so **no record is written and none is wiped** — the key stays buyable the moment the refusal clears |

That last row is the difference between a spend guard and an outage: counting a
dry account against the cap would make every candidate key terminal in three
ticks and leave the fleet a day without pre-plans, for calls nobody paid for.

**The rc alone cannot decide it, and that "and" is the whole reason.**
`bin/agent-call.sh` exits with the **last rung's** code, and the refusal codes
belong to particular rungs — 76 to the claude/codex account picker, 79 to the
grok cliff route. A claude session that ran, cost money and died, then descended
to a codex rung with no headroom, exits 76: the rc says "nothing was called"
about a call that was billed, and skipping the record there would re-buy that
key every tick with no cap — the runaway shape this whole section exists to
stop, one layer down. So the evidence is the ledger `agent-call.sh` writes
itself: one `logs/cost.csv` row per attempt that ran, none for a refusal. Not
billed means **both** a refusal code and a cost file that did not grow.

The check runs **before** the model call, in `bin/run-preplan.sh` itself — the
choke point every pre-plan goes through — so a lane launched by hand cannot walk
past it. `bin/preplan-tick.sh` asks the same question before launching, which
saves the `PREPLAN_PARALLEL` slot and writes one `PREPLAN_SKIP` line naming the
reason (once per key, not once every two minutes), and
`bin/preplan-candidates.sh` drops terminal keys from the **speculative** classes
so a dead key stops occupying one of the `PREPLAN_AHEAD_READY` slots. Queued and
child rows stay in the candidate list: those are tickets the fleet is actively
building, `bin/overlap-schedule.sh` needs them to place them at all, and the
tick's guard is what keeps them from costing a session.

**How terminal state ends, and when it does not.** `bin/preplan-tick.sh`'s
housekeeping deletes a `plans/` dir older than 24h **whose key is not on
`READY-QUEUE.log`**, so the terminal record ages out for a speculative key and
that ticket gets another try tomorrow. For a key that is ON the queue it does
**not**: the record stands until the queue line goes, which is usually when the
ticket builds. That is the honest shape, and it is survivable — a queued
ticket's build writes its own plan in-build, so the pre-plan it is refused is a
latency optimisation, not the plan it runs on. A deliberate re-try before then
is `rm -rf plans/<project>-<KEY>` on the box, or `PREPLAN_MAX_ATTEMPTS` raised
for a `failed` key.

Standing spend exposure, stated plainly so nobody discovers it from a bill: the
default takes the fleet from 2 pre-planned ready tickets per project to 10, the
per-*tick* cost is still bounded by `PREPLAN_PARALLEL`, and `preplan_check`
still refuses to re-buy a plan that is fresh — but nothing caps how many times
the same key is re-bought over days. A pre-plan is dropped and re-planned when
`main` moves in one of its planned files, and `bin/preplan-tick.sh`'s
housekeeping deletes any `plans/` dir older than 24h whose key is not on
`READY-QUEUE.log` — which an `ahead` key never is. So a ready backlog re-buys
itself roughly daily, and every merge that touches a hot file invalidates each
pre-plan naming it. That is bounded at `PREPLAN_AHEAD_READY` keys per project
per day, which is why the bound exists and why it is small. There is
deliberately **no per-key re-buy ledger in this change** (it is neither in
BH-475's scope nor in its tests); the knob is the control until one exists, and
raising it past ~10 is a spend decision, not a tuning one.

**The snapshot, and what it costs when it is missing.**
`bin/preplan-tick.sh` already runs `bin/preplan-candidates.sh` per project every
2 minutes, so it writes that output to
`state/preplan-candidates/<project>.tsv` (temp + `mv`, never a half file) and
the scheduler reads it while it is younger than `OVERLAP_SNAPSHOT_MAX_AGE`. In
steady state that makes the triage tick's schedule cost **zero** extra GitHub
requests. Two cases fall back to a live `preplan-candidates.sh` call, which is
the same two requests that script always makes: a snapshot older than the max
age, and a box running `PREPLAN_SPECULATIVE=0` — the legacy pre-plan path does
not write a snapshot, by design (it is byte-for-byte 2026-07-23 behaviour). A
stale snapshot is *not* read as "no candidates": that is an unanswered question,
and it is asked live rather than assumed.

**Why more of the backlog gets pre-planned now.** A graph over 2 of 30 ready
tickets cannot say which ones are independent, so with the schedule on
`preplan_ahead_ready()` raises the `ahead` class to `PREPLAN_AHEAD_READY`
(default 10, unless `PREPLAN_AHEAD` is set explicitly) while the `blocked` class
keeps `PREPLAN_AHEAD`. **The per-tick spend does not move**: `PREPLAN_PARALLEL` in
`bin/preplan-tick.sh` still bounds how many pre-plan sessions run at once, so
more candidates means more *ticks*, not more sessions in one tick — and
`preplan_check` still refuses to re-buy a plan that is already fresh.

**It is advice, not a gate.** Nothing here locks, claims, queues or waits —
locks in this harness are dedupe (the operator, 2026-09-13) and this adds none. Every
failure path prints nothing and exits 0: no candidates, no pre-plans, no
`python3`, an unreadable list. A missed overlap costs one rebase, which is what
today already costs; a fabricated one costs a client's ticket a tick of delay
for a reason nobody can see.

**This ticket is its own example.** `docs/BUILD-CONCURRENCY.md` is one of the
six files in the evidence above — 14 of the last 100 merged PRs touch it. So
BH-475's doc edit is an *appended section* and changes not one existing line,
which is exactly the move the `HOT-FILES:` report exists to prompt.
