# File-overlap scheduling — the guard and the targeted rebase train

**Scripts:** `bin/overlap-guard.sh`, `bin/rebase-train-ahead.sh`,
`bin/lib/scheduler-conf.sh`
**Tests:** `tests/overlap-guard-test.sh`, `tests/rebase-train-test.sh`
**Config:** `flags/scheduler.conf` (machine-local; defaults below and in
`bin/lib/scheduler-conf.sh`)
**Kill flags:** `flags/overlap-guard-off`, `flags/rebase-train-off`
**Logs:** `logs/overlap-guard.log`, `logs/rebase-train-ahead.log`

---

## 1. The problem these two share

Parallel builds on one hot repo keep being handed the same files. Each one
writes a correct diff. The second to reach main pays for it — a rebase, a moved
head, a re-review the head-bound approval rule then requires, and often a
rebuild from scratch. All of that is bought **after** the money was spent on the
build.

The hub's own numbers, one 24h window read on 2026-09-15 ~16:30Z
(`logs/merge-conductor.log`, `logs/blocked-resolver.log`, project-5 rows):

| what | count |
| --- | --- |
| DIRTY / conflict lines | 282 |
| rebase lines | 317 |
| merge lines | 329 |
| blocked-resolver rebuild lines (all projects) | 145 |

Roughly one conflict event per merge. Almost none of them had to happen: in
every case the collision was knowable either **before the build started** or
**one tick after the merge that caused it**. That is the whole design.

- `bin/overlap-guard.sh` closes the first gap — at the LAUNCH decision.
- `bin/rebase-train-ahead.sh` closes the second — at the MERGE event.

Neither of them queues anything. Locks and deferrals in this harness are dedupe,
never a queue (the operator, 2026-09-13); a deferred ticket is simply re-offered on the
next tick, the same `BUILD_DEFERRED` semantics `CLAUDE.md` describes.

---

## 2. `bin/overlap-guard.sh` — the launch-time guard

```
overlap-guard.sh <project> <KEY>
  rc 0   stdout: LAUNCH <KEY> <note>
  rc 1   stdout: DEFER <KEY> vs <other> jaccard=<x> files=[a,b,c]
```

### What it compares

The candidate's **files-to-touch** list — written by the pre-plan stage
(`bin/run-preplan.sh` → `plans/<project>-<KEY>/planned-files.txt`, via
`bin/planned-files.sh`), else the pre-plan row published to the coordination DB
(`preplan_planned_files`, `bin/lib/preplan-lib.sh` — the hub has no `plans/`
dir, #658/#777), falling back to the newest live build dir's own copy —
against two sets. That middle source is live only once `bin/lib/preplan-lib.sh`
carries the reader (#773); on a box whose lib predates it the guard skips
straight to the build-dir fallback, exactly as it did before.

1. **Every ticket of this project with a `running` row in the jobs ledger**
   (`bin/jobs-client.sh`, `GET /api/jobs?status=running`). Fleet-wide on
   purpose: at pool scale the sibling about to collide is usually on another
   machine, and the ledger is the only place both are visible.
2. **Every open harness-authored PR on this project's repo, and the files it
   actually changed** (`bin/lib/gh-pr-list.sh:harness_pr_list`, one
   `gh pr list --json …,files` per author rather than a `gh pr view` per PR).

(2) is the dimension nothing had before. `bin/conflict-check.sh` and
`bin/plan-overlap.sh` both ask (1) in their own way, at PLAN time, inside
`bin/run-build.sh` — but a PR that is open and unmerged still owns its files,
and a build launched onto them conflicts with a diff that is *already written*.

### The overlap rule

`bin/conflict-check.sh`'s, unchanged: two paths collide when they are equal, or
one is a path-prefix of the other (file == file, dir contains file). In front of
it sits `bin/plan-overlap.sh`'s prune — a bare directory entry that the SAME
list also names a file under is dropped, because it is where that file lives and
not a second claim.

Against an **open PR** only a file-level match counts (2026-09-28). A PR's list
is the files it really changed, so a planned directory entry such as
`tests/fixtures/root-fallback-baseline` used to be a prefix of every fixture any
PR touched under it and held the ticket against all of them. Two plans (a
running sibling) keep the prefix rule.

Jaccard is `hits / union` over the pruned sets and is reported on **every**
decision, defer or not, so an operator raising the threshold reads the same
number the guard did.

### Things it deliberately does NOT defer on

- **The auto-resolvable classes.** `package.json`, `package-lock.json` and
  `*.md` are in `OVERLAP_IGNORE` by default, because the merge conductor already
  union-resolves exactly those deterministically
  (`mc_resolve_package_json`, `mc_resolve_md_union`). Deferring on them would
  serialize a whole repo behind its most boring file.
- **The ticket's own PR.** A repair round or a resume reaches the guard with its
  own branch open; branch names carry the key, so it is skipped. Without that a
  ticket would defer against itself forever.
- **The stack parent's PR.** A stacked child (`STACK_BASE`, from the launcher's
  environment or the queue job file's `stack_base`) builds on its parent PR's
  branch, so its plan overlaps that PR by construction. The PR whose head IS
  that branch is skipped; every other PR is judged as before.
  `bin/fly-dispatch.sh` passes the picked job's `stack_base` (a rows-only job
  lives in `state/fly/.rowjob-<p>/`). With stacked builds switched off
  (`flags/stacked-builds-off`, `STACKED_BUILDS=0`) nothing is exempt.
- **Drafts.** Not in flight.

### Test-file collisions are rerouted, not deferred

Test files are the fleet's largest merge-conflict surface — 20 of 24
unresolvable conductor cases were two siblings appending cases to the same
`tests/<tier>/<area>.test.ts`. Holding a whole ticket for one of those is the
wrong trade, because the right answer is that a ticket writes its cases to its
**own** file. So when a colliding path is a shared test file, the guard renames
it out of the way instead of standing the ticket down:

1. It appends `REROUTE tests: <shared> -> <per-ticket>` to
   `state/preplan-files/<project>-<KEY>` (the contract's `th_record_add`,
   append-only and idempotent on an exact line match).
2. It swaps the path in `plans/<project>-<KEY>/planned-files.txt` when that file
   exists (`th_apply`, whole-line match only).
3. It logs `REROUTE vs <label>: <shared> -> <target>` naming the holder — a
   running key or `PR#<n>`.
4. It drops the path from the hit set. **Everything left is judged exactly as
   before** — same jaccard, same `OVERLAP_THRESHOLD`, same `OVERLAP_IGNORE`,
   same PR cache. If the remainder still defers, nothing is recorded: a deferred
   ticket must not hand its test file away for a build that never ran.

The launch line then says so: `LAUNCH <KEY> rerouted <n> test path(s) vs
<labels>; no collision above threshold …`.

What is **not** rerouted: a path that is not a test path; anybody's per-ticket
file, ours (then it is not a collision at all) or a sibling's (then it is a real
one); and a bare directory entry or any dir-contains-file hit, because the
per-ticket target would still live inside the directory the other side holds.
If `th_record_add` cannot write the record, the path **stays a hit**, the log
says `REROUTE record unwritable for <path> — deferring as today`, and the ticket
is judged as it was before this existed.

A pool machine has no hub state, so `bin/fly-pool.sh:push_reroute` `mput`s that
record to `${TEST_REROUTE_RELAY_DIR:-/run/harness}/test-reroute-<project>-<KEY>`
at both the spawn and the machine-reuse path; the reuse cleanup removes the
previous job's copy. An absent record pushes nothing and a failed push is never
fatal.

**Interim, until #585 lands:** nothing forwards the record to the executor yet,
so `bin/run-build.sh`'s in-build `conflict-check.sh` / `plan-overlap.sh` still
defer a rerouted build when its plan names the shared file. Nothing merges with
a shared-file conflict; the cost is a repeated plan call per tick until the
sibling releases its claim.

### Fail-open, always

No pre-plan, no ledger, a dead `gh`, an unparseable config, no `jq`: **LAUNCH**,
with a line in `logs/overlap-guard.log` naming the question that could not be
asked. A missed overlap costs one rebase — which is what today already costs. A
fabricated one costs a build that never runs. A running key whose file list
never reached this box is logged as `unjudged=<key>` rather than silently
counted as disjoint.

### Where it is wired in

Two call sites, both minimal:

- **`bin/fly-dispatch.sh`** — one `if` immediately before the dispatcher claims
  a queued job. A DEFER leaves the queue file exactly where it is and returns;
  the next tick re-offers it. `tests/overlap-guard-test.sh` drives the real
  dispatcher against a fixture harness and asserts on the queue file, not on a
  grep.
- **`bin/run-triage.sh`** — the launch decision on that path belongs to the
  triage agent, so the guard reaches it as one instruction appended to
  `PROMPT_TEXT` **before `SHARD_SOP` is taken**, which is why every tick type and
  every triage shard carries it from one edit. If the script is not on the box,
  no sentence is appended and the SOP is byte-for-byte what it was.

---

## 3. `bin/rebase-train-ahead.sh` — the targeted rebase train

```
rebase-train-ahead.sh [project ...]     # default: every project in fleet.conf
```

Per tick, per repo:

1. Read main's last `REBASE_TRAIN_COMMITS` shas
   (`gh api repos/<slug>/commits?sha=<base>`), stopping at the mark in
   `state/rebase-train/<owner>_<repo>.last`.
2. Union the changed files of everything since the mark.
3. List the open harness-authored PRs, and refresh **only** those whose own
   changed files intersect that union — up to `REBASE_TRAIN_MAX` pushes a tick.
4. Advance the mark.

A PR that shares no file with what just merged is left alone on purpose:
refreshing it would move its head, and a moved head costs a re-review under the
head-bound approval rule (`CLAUDE.md` guardrail 1).

### How it differs from `bin/rebase-train.sh` (which is untouched)

| | `rebase-train.sh` | `rebase-train-ahead.sh` |
| --- | --- | --- |
| trigger | a PR is **already DIRTY** | a merge landed on main |
| scope | one project, per-project cron | every repo, one hub cron |
| selection | every DIRTY record-backed PR | only PRs whose files intersect the merge |
| when it acts | after the damage | before it |

They are complementary: this one is the prevention, that one is the cure, and
the cure is still needed for whatever slips through (a PR opened against an
older base, a merge outside the window, a tick that was capped).

### The refresh itself is `mc_rebase`

Borrowed whole from `bin/lib/merge-conductor-lib.sh`: the conductor's authed
clone/worktree, its deterministic conflict classes, its typecheck+unit gate, its
`--force-with-lease` on the sha *this* tick read, and its approval rebind.
Writing a second one would mean two answers to "is this branch safe to push",
and the merge sweep is head-bound — an un-rebound push parks the PR.
`bin/merge-conductor.sh` is not touched and nothing here writes conductor state.

### What it refuses to touch

- drafts;
- PRs based on anything other than the repo's base branch;
- PRs already `DIRTY` (the conductor's lane — doing it here would race its
  lease). **Belt, not braces:** `gh pr list --json mergeStateStatus` answers
  `UNKNOWN` for most rows, because GitHub computes mergeability lazily and a
  list call does not wait for it, so this filter only fires when the value
  happens to be cached. What actually keeps the train out of the conductor's way
  is the custody check below — `NEEDS_REBASE` is the conductor's own word for
  DIRTY and is in `REBASE_TRAIN_SKIP_STATES` by default;
- PRs the conductor has custody of, read out of its `pr-state.tsv`
  (`REBASE_TRAIN_SKIP_STATES`) **read-only**;
- PRs with a detached conductor rebase job already in flight
  (`state/merge-conductor/rebase/`) — **status `running` only**. Those job files
  are not removed when they finish (35 of them, some days old, on the hub on
  2026-09-15), so testing for the file's existence would exclude every PR the
  conductor has ever rebased, permanently, and the train would quietly do less
  work over time on exactly the busiest repos.

### First tick on a repo plants the mark and refreshes nothing

With no mark there is no "since", and treating an absent mark as "everything is
new" would push every open PR on the repo in one go — on a fresh box, on a
restored `state/` dir, or the first time the lane runs at all.

### Marks are fail-safe

A tick that could not read the open-PR list **does not advance the mark**, so
those merges are compared again next tick. A mark that has fallen out of the
window takes the whole window rather than doing nothing forever.

### Alerting

One log line per refresh. A **lane alert only on a real conflict** —
`bin/lane-alert.sh --critical rebase-train-ahead "<…> <PR url>"` — because that
is a human-shaped fact the conductor's resolver ladder now owns. A red gate, a
lost lease or a setup failure is a log line: the next tick retries it, and paging
on work that retries itself is how an alert log stops being read.

---

## 4. Config — `flags/scheduler.conf`

`flags/` is machine-local and gitignored, so **the defaults below are the
shipped configuration**; the file only exists on a box that wants to differ.
Format is one `KEY=VALUE` per line, `#` comments, quotes optional. It is **read,
never sourced** — it is edited by hand from a console and a stray backtick must
not execute inside a lane holding a token. Resolution order is
**environment → settings row `conf.scheduler.<key lowercased>[.<box>]` →
`flags/scheduler.conf` → the documented default** (the row since BH-2411), and a value
that will not parse falls back to the default rather than to "unlimited"
(`bin/lib/scheduler-conf.sh`). A settings row the knob's validator refuses (a
non-number for `sched_num`, anything but a decimal ≤ 1 for `sched_frac`) falls through to
`flags/scheduler.conf`, not to the default, and `logs/lane-gate.log` names it once an hour
(BH-2478).

### `bin/overlap-guard.sh`

| key | default | meaning |
| --- | --- | --- |
| `OVERLAP_THRESHOLD` | `0` | Jaccard at or above which a pair defers. `0` = **any shared file defers**, which is `bin/conflict-check.sh`'s rule and what this fleet has always done. Raise it (e.g. `0.25`) on a repo where builds legitimately share a directory. |
| `OVERLAP_IGNORE` | `package.json package-lock.json *.md` | space-separated globs never counted as a collision, because the conductor union-resolves them. Its `*.md` token also governs `bin/plan-overlap.sh`, `bin/plan-sibling.sh` and `bin/conflict-check.sh` (BH-9096, `bin/lib/docs-overlap.sh`): an override without `*.md` makes a shared `.md` path defer in all six paths |
| `OVERLAP_PR_LIMIT` | `30` | open PRs read per author |
| `OVERLAP_PR_CACHE_SECS` | `120` | how long `state/overlap-guard/<project>-prs.json` is reused. The guard runs once per candidate ticket and the dispatcher ticks every two minutes; uncached this would be several `gh pr list` calls a minute for an answer that only changes on a merge. `0` disables the cache. |
| `OVERLAP_LEDGER_LIMIT` | `50` | running rows read from `/api/jobs` |
| `TEST_REROUTE` | `1` | the test-file reroute above. `0` turns it off and the guard defers on a shared test file exactly as it did before. **Not read from `flags/scheduler.conf`** — it is the contract's own knob (`bin/lib/test-home-lib.sh:th_enabled`), so it is the environment variable or the file form `flags/test-reroute-off`. |

Kill: `flags/overlap-guard-off`, or `OVERLAP_GUARD=0` in the environment. Either
one exits 0 having read nothing. `TEST_REROUTE=0` / `flags/test-reroute-off` is
the narrower switch: the guard still runs, it just stops rerouting.

### `bin/rebase-train-ahead.sh`

| key | default | meaning |
| --- | --- | --- |
| `REBASE_TRAIN_MAX` | `3` | pushes per tick, fleet-wide. Each one costs a typecheck+unit run in `mc_rebase`. |
| `REBASE_TRAIN_COMMITS` | `20` | how far back on main one tick looks |
| `REBASE_TRAIN_PR_LIMIT` | `40` | open PRs read per author per repo |
| `REBASE_TRAIN_REPOS` | *(empty)* | space-separated project names; empty = every project `bin/fleet-conf.sh --projects` lists |
| `REBASE_TRAIN_SKIP_STATES` | `QUEUED REBASING NEEDS_REBASE BLOCKED_HUMAN MERGED CLOSED ABANDONED` | conductor states that mean "hands off" |

Kill: `flags/rebase-train-off`, and `flags/automerge-disabled` stops it too — a
refresh exists only to keep the merge funnel moving, so a fleet that has stopped
merging must not be pushing branches around.

Example:

```
# flags/scheduler.conf — hub
OVERLAP_THRESHOLD=0
OVERLAP_IGNORE=package.json package-lock.json *.md prisma/migrations
REBASE_TRAIN_MAX=4
REBASE_TRAIN_REPOS=project-5 project-4
```

### Priority lanes (#643 family)

Every knob the priority-lane family introduces, in one place, so each child
slice adds behaviour and not another config page. **The main-red label is the
odd one out**: it is a label name, and since BH-1770 it is ONE registered knob,
`MC_MAIN_RED_LABEL` (the `main-red-label` lib in `catalog/lanes.d/_lib.json`,
settings row `lib.main-red-label.mc_main_red_label`), resolved by
`bin/lib/main-red-label.sh` for every merge lane and every build alike. Neither
it nor the reap deadline goes through `flags/scheduler.conf`. The rest resolve
through `sched_conf`/`sched_num` in the usual order (environment →
`conf.scheduler.*` row → `flags/scheduler.conf` → default).

| key | default | read by | meaning |
| --- | --- | --- | --- |
| `MC_MAIN_RED_LABEL` | `fix-main-red` | `main_red_label_resolve` in `bin/lib/main-red-label.sh`, behind `main_red_label` (`bin/lib/hotfix-lib.sh`) and the merge lanes' `MC_MAIN_RED_LABEL` (`bin/lib/main-red-gate.sh`) (**live**) | the label that makes a ticket rank 1 — between `hotfix` (0) and every ordinary ticket (2) — and lets a PR merge through the main-red freeze. Order: the settings row, then this name, then the deprecated alias, process env before `env/global.env`. |
| `MAIN_RED_LABEL` | — | the same resolver (**deprecated alias**) | still honoured, so no box that set it changes behaviour; logged once an hour to `logs/lane-gate.log`, and loses to `MC_MAIN_RED_LABEL` when both are set. Rename it. |
| `LANE_REAP_DEADLINE_SECS` | `16200` | `bin/lane-reaper.sh`, through `lane_knob lane-reaper … <project>` (**live**) | how long a build may live, from `job.json`'s `started_at`, before the reaper kills it. **Per build lane** (BH-1770): the row `lane.lane-reaper.<project>.lane_reap_deadline_secs` for one project (`bin/harness-ctl.sh set lane-reaper LANE_REAP_DEADLINE_SECS <secs> <project>`), else the lane-wide row, else the env, else 16200; a row is clamped to 1800..172800. A reaped run is relaunched by `bin/blocked-resolver.sh` only. |
| `LANE_EXPECTED_SECS` | `14400` | `bin/run-build.sh`, writing `expected_by` into `$BUILD/job.json` (**live**) | how long a build may run before it is late. 4h on purpose: the same age at which a ledger claim ages out. The reaper no longer reads it directly: a box whose `LANE_EXPECTED_SECS + LANE_REAP_GRACE_SECS` is not 16200 has that sum used as `LANE_REAP_DEADLINE_SECS`'s env tier. |
| `LANE_REAP_GRACE_SECS` | `1800` | `bin/lane-reaper.sh`, through `sched_num` (every `cron/*.cron`, \*/10) (**live**) | how long past `expected_by` a LEGACY dir (no `started_at`) is left alone; for every other dir, part of the legacy sum above |
| `LANE_REAP_MAX` | `20` | `bin/lane-reaper.sh`, through `sched_num` (every `cron/*.cron`, \*/10) (**live**) | lanes examined per tick |
| `BR_FIX_SLOTS` | `0` (unlimited) | `bin/blocked-resolver.sh` — *documented ahead of the child that reads it (BH-643 order 2-5); nothing reads it yet* | concurrent fix rounds allowed |
| `BR_HOTFIX_RESERVE` | `1` | `bin/blocked-resolver.sh` — *documented ahead of the child that reads it (BH-643 order 2-5); nothing reads it yet* | slots held back for rank-0 work |
| `PRIORITY_YIELD` | `1` | `bin/run-build.sh`, the overlap-yield child (**live**) | `0` turns the yield off; `bin/overlap-guard.sh` is unchanged because it does not implement yield |

---

## 5. Reading the logs

```
tail -c 20000 /root/harness/logs/overlap-guard.log
tail -c 20000 /root/harness/logs/rebase-train-ahead.log
```

`overlap-guard.log` carries one line per decision:

```
2026-09-15 16:40:02Z [project-5/TK-1189] DEFER vs TK-1188(building) jaccard=0.33 hits=2/6 files=[src/lib/scan.ts,src/ui/row.tsx]
2026-09-15 16:41:11Z [project-5/TK-1190] LAUNCH — no collision above threshold 0.0000 (ledger=ok unjudged=TK-1177)
```

`rebase-train-ahead.log` carries one line per refresh and one summary per repo:

```
2026-09-15 16:45:03Z [rebase-train-ahead/project-5] https://github.com/example-org/project-5/pull/912 refreshed onto main (a1b2c3d4 -> e5f6a7b8) — merged files it shares: src/lib/scan.ts
2026-09-15 16:45:04Z [rebase-train-ahead/project-5] 3 new commit(s) on main touching 14 file(s) — refreshed 1 PR(s), mark -> 9f8e7d6c
```

**If the guard is deferring too much**, read the `jaccard=` values it is
printing: raise `OVERLAP_THRESHOLD` past them, or add the offending path to
`OVERLAP_IGNORE`. Switching the guard off entirely with
`flags/overlap-guard-off` is the blunt instrument and costs the conflicts back.

## 6. Lane re-probe cadence

**Script:** `bin/lane-reprobe.sh` (hub, `cron/lanes/705-lane-reprobe.cron`)
**Test:** `tests/lane-reprobe.bh-1687-test.sh`

A runner lane (codex, openrouter, fireworks, grok) that fails its probe is
marked down in `state/lane-down/<box>-<lane>` by `bin/lib/lane-down.sh`. This
lane gives each of those records its own probe schedule, so a lane that comes
back clears itself.

**Tick and due check.** Cron fires it every 5 minutes, lease-gated like every
hub lane. A tick does not probe everything. A record is due when
`now - last_probe` has reached its interval:

| outage age (`now - since`) | interval | knob (default) |
|---|---|---|
| under `LANE_REPROBE_BACKOFF_AFTER_S` (86400) | fast | `LANE_REPROBE_FAST_S` (1800) |
| at or past it | slow | `LANE_REPROBE_SLOW_S` (21600) |

A record with no `last_probe` is due at once.

**Seeding.** Before it lists records, the tick creates one for every line of
`state/claude-auth-down.txt` shaped `<box>-<codex|openrouter|fireworks|grok>`
that has none. `since` comes from the contiguous run of `flags/lanedown-<ID>-<day>`
flags; bare box lines (the claude lanes) are never touched. Seeding stamps
`last_probe`, so a seeded lane is first probed one interval later, not on the
tick that seeded it.

**Cap and deadline.** Due records are probed oldest `last_probe` first, at most
`LANE_REPROBE_MAX_PER_RUN` (4) per tick. No probe starts once
`LANE_REPROBE_DEADLINE_S` (600) has passed since the tick began, and each probe
is bounded by `timeout 180`. Whatever is left is logged, never dropped:

```
2026-09-23 21:05:03Z deferred 2 due lane(s) to the next tick (cap 4, deadline 600s)
```

The deferred records are still due on the next tick and go first there, because
their `last_probe` is the oldest.

**Lock.** `locks/lane-reprobe.lock` is taken with `flock -n`: a tick that finds
the previous one still running exits 0 without probing. It is dedupe, not a
queue. The probes run outside `locks/lane-down-state.lock`, which the lib holds
only for its STATE-file edit.

**Outcomes and log lines** (`logs/lane-reprobe.log`):

```
2026-09-23 21:05:01Z lane grok back on hub after 2h 0m
2026-09-23 21:05:02Z lane fireworks still down on project-4 (8d 21h), next probe in 6h 0m
2026-09-23 21:05:02Z no address for zed, not probed
2026-09-23 21:05:00Z seeded project-4-grok from STATE
```

Only a probe answer that passes `ld_probe_ok` clears a lane. rc 75 ("no model
route … not probed"), empty output, an ssh timeout and a vendor error all count
as down. A box with no `addr` in its record, that is not `hub` and that
`bin/fleet-conf.sh --tailnet-ip-of-box` cannot resolve, gets the `no address`
line and its record is left exactly as it was.

## 7. Plan-time hotspots: the fragment exemption and the `After:` hold (BH-4988)

`bin/plan-overlap.sh` runs right after PLAN (`# >>> plan overlap` in
`bin/lib/rb/gates.sh`). It compares the new plan's file list with every build
in flight: claim files, live build dirs, and every box's `job_claims` row
through `fclaim_list_dir`.

**Fragment files are not held.** A colliding pair is dropped when it is on a
fragment path:

- both sides name a path the target repo's `## Generated files` table declares
  (equal, or a whole-path glob row such as `cron/*.cron`), or
- one side names a bare fragment directory and the other a path under it, or
- both sides name the bare fragment directory itself.

The same FILE inside a fragment dir on both sides (`catalog/lanes.d/x.json`)
is still an overlap. The 3-pair cap on the `OVERLAP_DEFER` line is applied
after this filter, so a real fourth pair is never hidden behind three fragment
ones. When every pair is a fragment pair the build goes on.

**Any other overlap gets `After: <OTHER>`.** The build still stands down
(`BUILD_DEFERRED`, the same 10-minute not-before as before), and
`bin/plan-after.sh record` writes `state/overlap-after/<project>/<KEY>` naming
the build it waits for. The same fact goes to the fleet: the build's
`overlap_defer` job artifact carries `choice:"after"` and `after:<OTHER>`.
Once the 10 minutes are up, the `# >>> overlap not-before` block runs
`bin/plan-after.sh check` before any plan is bought.
It holds (`BUILD_DEFERRED After: <OTHER> in flight` or `… PR #n open`) while
OTHER has a claim file, a live build dir, a `job_claims` row or an open PR. It
releases when all four are clean, so the ticket re-plans once, after OTHER
merged or was dropped. Nothing is written to the GitHub issue, and no
`Blocked-by:` line is written anywhere.

- **Where the hold is read from.** The marker file first. When the box has no
  marker, which is every re-offer on the Fly pool (a fresh machine each time),
  `check` reads the key's newest `overlap_defer` artifact back from the jobs
  ledger, within the last `PLAN_AFTER_MAX_MIN` minutes. A `deferred` row with
  `choice:"after"` is the same hold, logged `src=fleet`. A newer row for the
  key that is not an After: row (a `proceeded` verdict, a `choice:"defer"`
  defer) ends it. The fleet row cannot be removed at this gate (no job is open
  yet), so a release on it is re-judged next tick and released again. If the
  ledger does not answer and there is no file, there is no hold, and the ticket
  re-plans after the 10-minute floor as before.
- On the pool, each held re-offer is still a `BUILD_DEFERRED` stand-down, and
  `bin/fly-pool.sh` counts it toward `JOBS_QUEUE_DEFER_MAX` (default 6) like any
  other. A hold longer than that many re-offers parks the row for
  `bin/blocked-resolver.sh`, the same place six paid re-plans used to put it.
  The hold makes those stand-downs free; it does not exempt them from the cap.
- Mutual (two keys deferred against each other): the byte-smaller key is
  released. The larger one holds on the mutual while the other key's marker is
  a file on this box (the release removes it). Against a fleet row, which
  outlives the release, the larger key instead holds only while the other key
  is pending (claim, build dir, `job_claims` row, open PR).
- Unreadable open-PR answer (`open_pr_for_key` rc 2, or no slug): the marker is
  kept, the build goes on to PLAN, and plan-overlap judges it again.
- A marker older than `PLAN_AFTER_MAX_MIN` is removed.
- Kill switch: plan-overlap's own (`OVERLAP_SCHED=0`, `switch.plan-overlap-off`,
  `flags/plan-overlap-off`).

Fold (adding the waiting ticket to the in-flight build) is not built. Every
`after` line says `fold=not-offered`.

**Log lines.** Every choice is one `PLAN_HOTSPOT` line, in the build's
`pipeline.log` and appended with a timestamp to `logs/plan-hotspot.log`:

```
PLAN_HOTSPOT BH-B choice=build vs BH-A fragment-only files=[catalog/lanes.json,catalog/lanes.json]
PLAN_HOTSPOT BH-B choice=after after=BH-A fold=not-offered files=[bin/x.sh,bin/x.sh]
PLAN_HOTSPOT BH-B choice=released after=BH-A (finished, no open PR)
PLAN_HOTSPOT BH-B choice=released after=BH-A (finished, no open PR) src=fleet
PLAN_HOTSPOT BH-A choice=released after=BH-B mutual
PLAN_HOTSPOT BH-B choice=expired after=BH-A (held 361m, ceiling 360m)
PLAN_HOTSPOT BH-B choice=unjudged after=BH-A (open-PR read unavailable; plan-overlap re-judges at plan time)
```

The `overlap_defer` job artifact carries `choice` (`after`, or `defer` when the
marker was not written) and `after` (the other key). `check` reads those two
fields back when the box has no marker.

**Knobs** (`lib.plan-hotspot.*`, `catalog/lanes.d/_lib.plan-hotspot.json`;
settings row, then env, then `env/global.env`, then the default):

| Knob | Default | Meaning |
|---|---|---|
| `PLAN_OVERLAP_FRAGMENT_DIRS` | `catalog/lanes.d cron/lanes docs/verification-map/entries worker/jobs/schema.d` | fragment directories, space-separated |
| `PLAN_AFTER_MAX_MIN` | `360` | ceiling on an `After:` hold in minutes; 0 = never expire |
