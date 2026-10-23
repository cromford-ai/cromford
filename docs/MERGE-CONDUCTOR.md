# Merge conductor: one owner for every harness PR from open to merged

<!-- changes:begin -->
> **What changed since this doc was written lives in [`docs/notes/`](notes/INDEX.md)**, one dated note per change. Add a note there instead of appending here; guardrail `doc-monolith-edit` checks it once it is armed in CI (the adoption PR that `guardrails/README.md` prescribes; not yet opened).
> BH-1201 (2026-09-22): under `kill-switch`/`observe` the two AGE pagers HOLD instead of paging, and the first `merge`/`actions` tick flushes them — [`notes/2026-09-22-BH-1201-conductor-paused-hold.md`](notes/2026-09-22-BH-1201-conductor-paused-hold.md).
> BH-1670 (2026-09-23): when the conductor settles a parent MERGED it retargets each open child (base.ref == parent branch) to the base, THEN rebases it `--onto` the base from the parent's pre-merge head and pushes once; a conflict parks `conflict-unresolvable … parent=#N` — [`notes/2026-09-23-BH-1670-stacked-child-restack.md`](notes/2026-09-23-BH-1670-stacked-child-restack.md).
> BH-1715 (2026-09-23): the restack give-up limits are registry knobs (`MC_STACK_FOLLOW_TRIES`, `MC_STACK_FOLLOW_GIVEUP_S`); a child that merge-sweep or poll-commands retargets off a parent they merged is recorded as owed a restack and `pr_worker` follows it; every branch delete lists and PATCHes open children first — [`notes/2026-09-23-BH-1715-stack-follow-followups.md`](notes/2026-09-23-BH-1715-stack-follow-followups.md).
> BH-3776 (2026-10-01): the BH-636 re-entry arm counts a head that is UNSTABLE only through Mergify's own check runs as clean, attributes the batch failure before re-queueing (`own` vetoes, `foreign` re-queues once with one `REQUEUE_ATTRIBUTED` line and one PR comment) — [`notes/2026-10-01-BH-3776-foreign-red-requeue.md`](notes/2026-10-01-BH-3776-foreign-red-requeue.md).
> BH-1672.3 (2026-09-24): a merges pause sets `MERGES=0` (never KILL), so MODE reads `actions` and rebases continue, and TICK lines carry a `PAUSED(merges) ` prefix; `automerge-disabled` still owns the kill switch — [`notes/2026-09-24-BH-1684-lanes-honor-pauses.md`](notes/2026-09-24-BH-1684-lanes-honor-pauses.md).
> BH-3775 (2026-10-01): the BH-636 flake ladder calls `cit_assess` (`bin/lib/mc-ci-timeout.sh`) first and runs its rungs on `CIT_RUNS_LEFT`; the contract slice (BH-3784) ships fail-open stubs only, so the ladder is unchanged until the scan/rekick/budget slices land — [`notes/2026-10-01-BH-3775-ci-timeout-budget.md`](notes/2026-10-01-BH-3775-ci-timeout-budget.md).
> BH-3849 (2026-10-02): under `human_verdict_mode=enforce` a lead-token `source=human` row stops standing on GET `&head=`; an unreadable mode is 503 for human posts and `&head=` reads; operator step 1 uses `printf` — [`notes/2026-10-02-BH-3849-enforce-standing-fail-closed.md`](notes/2026-10-02-BH-3849-enforce-standing-fail-closed.md).
> BH-4428 (2026-10-04): the BH-636 re-entry arm reads Mergify's own dequeue verdict first (`bej_reentry_gate`, `bin/lib/mc-batch-eject.sh`): an unnamed member of a multi-PR draft, or one of `MC_BATCH_EJECT_SHARED_MIN`+ PRs tested alone on the same red main base, is re-queued once per head; the named PR gets one comment naming the failing checks — [`notes/2026-10-04-BH-4428-batch-eject-bystander.md`](notes/2026-10-04-BH-4428-batch-eject-bystander.md).
> BH-4562 (2026-10-05): before the queue settle counts an ejection it asks `mc_queue_left_why`: a PR GitHub (fresh read) reports merged settles `MERGED`, a Mergify check titled merged waits a tick, a dequeue with no stated reason is held one tick per head; a row already parked `queue-ejected-twice`/`queue-ejected` whose PR merged is settled and its hand-off released — [`notes/2026-10-05-BH-4562-merged-not-ejected.md`](notes/2026-10-05-BH-4562-merged-not-ejected.md).
> BH-4596 (2026-10-05): both approval rebinds (patch-id/patch-same and NO_OVERLAP) carry `lead-verdict` success onto the new head on a Mergify repo, once per head, when the row is QUEUED or the old head already had it; a failed publish (or merges off) is owed in `state/merge-conductor/vs-owed/` and retried next tick; the QUEUED TTL re-kick republishes from a standing verdict when the head has none — [`notes/2026-10-05-BH-4596-rebind-publishes-status.md`](notes/2026-10-05-BH-4596-rebind-publishes-status.md).
> BH-5234 (2026-10-07): when the parent was REWRITTEN after the child was cut (its pre-merge head is not in the child's history), `mc_restack` finds the child's fork point by patch-id (`bin/lib/stale-parent.sh`) and replays only the child's own commits, else rc 6 as before; every restack reads the child's own open children first and owes each a restack from its old head (the grandchild cascade), and `hold_push` refuses any other rewrite of a branch with open children (rc 5) — [`notes/2026-10-07-BH-5234-stale-parent.md`](notes/2026-10-07-BH-5234-stale-parent.md).
> BH-6351 (2026-10-13): a worker step past `MC_STEP_TIMEOUT_S` (default 240, only when under the worker deadline; `enqueue`/`merge` floor `max(MC_MERGE_LOCK_WAIT, MC_MERGIFY_WAIT_S) + 10`; `lock-probe` adds `MC_PR_LOCK_WAIT_S`, the READY re-kick's lock wait) ends the worker with one `STEP_TIMEOUT` line and `killed:step-timeout`, the row left for the next tick; a READY-path worker logs `STEP_START`/`STEP_END` per step, a step past `MC_STEP_SLOW_S` logs `STEP_SLOW`, and the `WORKER_DEADLINE` Sentry title names the step instead of a log line — [`notes/2026-10-13-BH-6351-step-timeout.md`](notes/2026-10-13-BH-6351-step-timeout.md).
<!-- changes:end -->

Asked by the operator 2026-09-12 ("go" on the orchestrator's proposal, Telegram 15:5xZ) after the
project-5 postmortem of the same day. Status: DESIGN + IMPLEMENTATION on one branch
(`orc/merge-conductor-20260912`). Observe-only by default; every action is behind a flag
(section 8). Companion: the postmortem PR #262 (`79bbf38`, merged 2026-09-12: the token lib
`bin/lib/gh-repo-token.sh`, the pipeline-health detectors, the issue close after merge,
`bin/lane-alert.sh --critical`). This doc reuses those and never re-implements them; the
implementation on this branch is built on top of #262's merged code.

## 1. The postmortem in one table: six mergers, zero owners

project-5 lost ten hours on 2026-09-12 because a PR has no owner between "open" and
"merged". Every actor below can merge, every one has a legitimate reason to say "not mine
right now", and none of them comes back. What each one does today, from the code:

| Actor | Where | Merges when | Walks away when |
|---|---|---|---|
| Build tier-1 gate | `bin/run-build.sh` (`gh pr merge --squash`, then verifies `state=MERGED`) | its OWN fresh PR: mechanical tier-1 AND `TIER: 1` from Fable, primary-lane provenance, QA proof, head-bound gate passed, `flags/automerge-disabled` absent | merge fails: `touch state/merge-queue/<project>/<n>` and hands off. Never looks again. |
| Hub merge sweep | `bin/merge-sweep.sh`, hub cron `6,16,26,36,46,56` | a build record with `PR_CREATED` + APPROVE (ledger `job_verdict`, else `review.md`), head == reviewed sha, `mergeStateStatus CLEAN` (plus the project-4 and green-run UNSTABLE discounts), iron-law added-lines scan clean, `pre-arm-guards.sh` not red, kill switch absent | `DIRTY`/`UNKNOWN`: "skipped (will retry)" forever. `BLOCKED` the same, EXCEPT where the base requires no check and no review and this identity is not on its push allow-list — that is `IDENTITY_NOT_PERMITTED <slug> <identity>`, one ALERT per (repo, identity, day), and no ledger row (BH-800). Head moved: parks with ONE alert per head, never re-reviews (#393 sat 10h). Token 404: silent empty loop until #254. Merge failure: "leaving for retry/human". |
| Box merge queue | `bin/merge-queue.sh`, per-project cron every 20 min at a per-project minute (`bin/lib/cron-lines.sh`; offset 0 is `6,26,46`), fed by `bin/tier2-merge-sweep.sh` (`3,13,…`), run-build's tier-1 failure path, `bin/review-prs.sh`, and `bin/fly-results-ingest.sh` over ssh | queue file exists, PR OPEN, head == reviewed sha; rebases a `CONFLICTING` PR itself (typecheck gate, `git push -qf`, then `job_verdict_rebind`), one `bin/lander.sh` attempt | conflict the lander declines, union typecheck red, or head-bound mismatch: `<n>.blocked` + one beat. Nothing un-blocks it. `gh pr merge` fails: "retrying next pass" with no age limit. |
| External-PR reviewer | `bin/review-prs.sh`, per-project cron every 30 min at a per-project minute (offset 0 is `7,37`) | Fable APPROVE on a non-harness PR, primary lane, kill switch absent — **and, since 2026-09-14, again on every later tick** while the recorded APPROVE is still bound to the head and the PR is OPEN + `CLEAN` (`merge_retry`, capped at 6 attempts per head then one ALERT; `REVIEW_MERGE_RETRY=0` turns it off) | merge fails: enqueues on the box queue (see above). Skips harness PRs by design. Before the retry existed, an APPROVE that was held on its first tick (`flags/automerge-disabled` on for a minute) was never re-offered by anything — project-2 #294/#488/#489 sat approved and open for days, since the sweep and the conductor both list harness PRs only. |
| Rebase train | `bin/rebase-train.sh`, hub cron for project-4/project-2/project-3 only | rebases record-backed DIRTY APPROVE PRs (two deterministic conflict classes), rebinds the approval when the caller check passes (BH-6718) | two strikes: `state/rebase-train-skip.txt` + one alert, forever. Not wired for project-5, project-6, project-8. |
| Humans and the orchestrator | `gh pr merge` by hand | judgement | the harness only learns via `bin/reconcile-prs.sh` (console row) and `merge-sweep`'s `sweep_record` on the next tick. |

Detectors exist but none of them acts: `pipeline-health` check 7 (`stalepr`, >12h),
`review-autopilot` (a review at 12h, "MERGING IS STILL HUMAN"), and, from #262,
`sweepstall` (APPROVE + CLEAN unmerged >30m) and `starved`. They page; they do not own.

The conductor replaces "walk away" with "own it": every harness PR is in exactly one named
state, that state has an age budget, and the conductor is the only thing that moves it
forward (or names the human who must).

## 1b. Where the code lives now (BH-477, 2026-09-19)

`bin/lib/merge-conductor-lib.sh` is a SHIM. It sources the six modules below,
in this order, and its sibling libs with one guarded source line each — nothing
else. A sibling's file name stays literal on its own line, because
`scratch_closure_list` (tests/lib/scratch.sh) reads it statically to install the
shim's closure (`tests/mc/lib-complete-test.sh` check 5). The shim is held to a
line GRAMMAR, not a line count (BH-5228, check 1): one statement per line, only
assignments and guarded sources, no loops, no functions, no logic. The modules load through one guarded source of `mc/load.sh`, which calls `mm_load` (`docs/MODULE-MAP.md`). The path is kept because 14 production scripts and 30 test suites source
it by name; every function it used to define now lives in `bin/lib/mc/`, and
`tests/mc/expected-map.d/` is the binding map of which one holds which: one
`<TICKET-KEY>.tsv` fragment per change, never an append to a shared file.

| module | what it holds | lines | functions |
|---|---|---|---|
| `bin/lib/mc/log.sh` | every `MC_*` global and tunable, the fail-open stubs, `mc_log`, `mc_alert` / `mc_state_note_only` (BH-979), `mc_budget_check` | 352 | 10 |
| `bin/lib/mc/locks.sh` | PR/merge/git locks, per-tick counters and spend budgets, the attempts ledger, the land trigger | 603 | 40 |
| `bin/lib/mc/classify.sh` | enumeration, verdict, CI state, the iron-law scan, provenance/hand-off holds, the red ladder, `mc_classify` | 1676 | 66 |
| `bin/lib/mc/queue.sh` | batch trains, the two merge-queue providers, `mc_merge` / `mc_enqueue` | 653 | 26 |
| `bin/lib/mc/rebase.sh` | stacked bases, git auth, `mc_rebase` / `mc_restack`, generated-path resolution, the contested-hold store and the conflict-size sidecar (BH-587/BH-588), `mc_rereview`, the detached lanes, the merge funnel | 2558 | 84 |
| `bin/lib/mc/settle.sh` | closed-settled, the row file + ledger + rehydrate, patch-id rebind, `mc_settle_merged` | 394 | 12 |

The suites split the same way: `tests/mc/classify-test.sh`,
`tests/mc/rebase-test.sh`, `tests/mc/queue-test.sh`, `tests/mc/settle-test.sh`,
with `tests/merge-conductor-test.sh` keeping the end-to-end tick and the
observe-only contract. `tests/mc-split-layout-test.sh` pins the layout and
`tests/mc/lib-complete-test.sh` pins that nothing was lost on the way out.

A box that receives the shim WITHOUT `bin/lib/mc/` has a dead conductor, a dead
merge queue and a dead sweep. `bin/harness-sync.sh` rsyncs `bin/` as a tree
(`rsync -a "$CHECKOUT/bin/" "$HARNESS/bin/"`) and enumerates no file list, so
the two always travel together; the shim's source loop is unguarded on purpose,
so a half-synced box fails loudly instead of classifying with half a classifier.


## 2. Shape

- **One script, one cadence, a lock PER PR.** `bin/merge-conductor.sh`, hub cron `*/30`.
  Each project's tick body runs in its own background subshell (2026-09-14), and inside it
  each PR runs in its own background subshell under its own `flock -n` on
  `locks/merge-conductor-<project>-<pr>.lock` (2026-09-15, section 2.1). The tick waits for
  its PR workers with their explicit pids and then finishes. Shared state stays
  safe: `pr-state.tsv` is the only file a tick rewrites whole and `mc_row_put` does it under
  its own `flock`; `attempts.txt`, the re-review cap file and the log are append-only, and
  everything else is keyed by project, repo or PR. Pure
  logic in `bin/lib/merge-conductor-lib.sh` (sourced), so `tests/` fixtures can stub `gh`
  and the jobs client exactly the way `tests/head-bound-approval-test.sh` and
  `tests/run-build-gates-test.sh` stub theirs (scratch `$HARNESS`, fake binaries on `PATH`).
- **Enumeration.** Every row of `fleet.conf` (`bin/fleet-conf.sh --projects`, slug via
  `fleet-conf.sh <p> repo`). Per repo: `harness_pr_list <slug> open …`
  (`bin/lib/gh-pr-list.sh`) on the token `bin/lib/gh-repo-token.sh` picks (section 7), plus
  `--state closed` PRs closed in the last 7 days that are NOT merged. **A harness PR is
  recognised by the AUTHOR SET `HARNESS_PR_AUTHORS`, never by one login** — default
  `operator app/cromford`, which is the PAT's owner plus the GitHub App that opens PRs
  when a lane runs on an installation token (`bin/gh-token.sh`). The helper lists once per
  author and unions the results by number; one author's list failing keeps the other's and
  is logged. A PR is a **harness PR** when its author is in that set AND any of: a build
  record under `builds/*/RESULT` names its URL (the sweep's test), its head branch starts
  with `ticket/` (every pool build, e.g. project-5 `ticket/TK-289`), or its body carries the
  run-build pipeline marker ("harness build", the test `review-prs.sh` uses to skip them).
  One of ours that matches none of these (`fix/team-synthesis-budget`,
  `feat/bt-byok-mode-rebate` on project-5 today) is a hand PR: logged once as
  `not-harness`, never touched.
  *2026-09-14:* the hardcoded `--author operator` this replaced went blind the day App tokens
  shipped — project-5 #696/#697 (`author: app/cromford`, APPROVE on record, CI green)
  sat unmerged with not one conductor log line while PAT-authored #737 was enqueued normally.
- **A closed-unmerged harness PR whose ticket is still open** (the #319 shape) gets state
  `CLOSED` with `reason=closed-unmerged-issue-open` and one alert. For issue-driven projects
  (fleet.conf board prefix `-`) "still open" is `gh issue view <n>` on the number in the
  branch/key; for board projects it is the board ticket's status via `bin/board-fetch.sh`.
  The conductor never reopens a PR; it names it.

### 2.1 The lock shard, and what a tick now says about itself (2026-09-15)

**The 102 skips.** Until this change the tick took ONE `flock -n` per project for the whole
of that project's tick and skipped the entire project when it was held. Measured on the hub
between 21:00 and 23:00Z on 2026-09-15, that produced **102** `an earlier conductor tick
still holds this project's lock — skipped` lines in two hours — cromford 30, project-5
21, project-7 15, project-2 9, project-8 9, project-4 6, the rest 3 each. One PR being
slow (a rebase result to read, a queue settle, a long list) cost its repo the next one to
three ticks ENTIRELY, and cost every other PR on that repo with it — even though the
projects themselves already ran concurrently.

**The topology now.** Four locks, each held for exactly what it protects (the last was
already there):

| Lock | Who takes it | Held for | On contention |
|---|---|---|---|
| `locks/merge-conductor-<project>-<pr>.lock` | `pr_worker`, fd 9 | one PR's whole tick: classify, rebase spawn, re-review dispatch, deploy-verify read, the merge | `flock -n` → skip THAT PR, carry on with the next |
| `locks/merge-conductor-<project>-merge.lock` | `mc_merge_locked`, fd 8 | ONE `gh` merge / merge-queue-enqueue call, and nothing else | `flock -w MC_MERGE_LOCK_WAIT` → rc 99 = nothing written, next tick (never a merge-failure strike) |
| `locks/merge-conductor-<project>-git.lock` | `mc_git_locked`, fd 7 | ONE funnel read in the project's SHARED checkout: `mc_merge_tree`, `mc_patch_id`, `mc_no_overlap` | `flock -w MC_GIT_LOCK_WAIT` → rc 99 = not answered this tick (never a negative answer) |
| `<state>/pr-state.tsv.lock` | `mc_row_put`, fd 9 | one `awk` rewrite of the row file | blocking, microseconds |

The git lock is the one the shard made necessary: each of those three reads does
`remote set-url` (with a token) + `fetch` + read + `mc_git_auth_clear` in `/root/repos/<project>`
or the conductor's own clone, and two of them at once means one worker clearing the remote's
credentials out from under the other's fetch — which would read as "the patch changed" and
buy a re-review nobody needed. It covers the TICK's short reads only: the detached rebase
lane fetches in the same clone and works in a `git worktree` of its own, which is what it
did before the shard and is deliberately not serialised against them (a rebase is minutes
long, and holding the git lock for it would stall every classifier on the repo).
There is no project-wide lock and no global lock. Two overlapping ticks of one project are
fine by construction: they meet on a PR, not on a repo, and the one that arrives second
skips that PR and does all the others. Everything else the tick writes is append-only
(`attempts.txt`, the re-review cap file, the log) or keyed by project/repo/PR.

**Budgets are files now.** `MC_REBASE_BUDGET` / `MC_REREVIEW_BUDGET` / `MC_MERGE_BUDGET`
were bash variables, which was exactly right while a project was one sequential loop. A PR
worker is a subshell and gets a COPY of every variable, so five workers would each spend
"the last" rebase. Each budget is a counter under `state/merge-conductor/tick/<tick-id>.<project>`
— one file per (tick, project), a `<name> <value>` line per counter, rewritten in place
under a `flock` on the file itself — keyed by TICK ID so it starts at zero every tick with no
reset step (`mc_tick_budget_take` / `_give` / `_left`; `mc_tick_gc` drops yesterday's). A
unit is taken BEFORE the action and handed back when the action did not happen — a spawn
refused at `MC_REBASE_PARALLEL`, a merge lock that timed out — so a refusal never costs the
project a rebase it never ran. Two overlapping ticks have different tick ids and therefore
separate budgets: each tick may spend its own.

**`MC_PR_PARALLEL`** (default `0` = unlimited, the `MC_REREVIEW_PARALLEL` /
`MC_REBASE_PARALLEL` convention) caps how many PR workers of ONE project run at once. The
dispatcher forks a worker per PR and, above the cap, waits for one to finish before forking
the next; nothing is dropped, it is only paced. Set it in `env/global.env`.

**The fd-inheritance trap, which is the only way a PR lock can wedge.** The lock is an fd;
the kernel releases it when the worker exits, however it exits, so there is nothing to
expire and no timestamp to trust. The one way to hold it past your own life is to FORK A
DAEMON INSIDE THE SECTION: a child inherits the fd and keeps the lock for its entire life.
That is not hypothetical — a deploy verifier did it on project-5 on 2026-09-14 and held the
project lock from 03:54 to 04:02Z while every tick in between skipped the project. So:

> **Every detached lane is spawned with the lock fds closed — `9>&- 8>&- 7>&-` on the
> `setsid` lines in `mc_rereview_spawn`, `mc_rebase_spawn` and `mc_dv_spawn` — and any lane
> added later must close them too.** `mc_merge_locked` is called as `$(mc_merge_locked …)` so fd 8
> exists only for that one command substitution, and the merge's consequences (the settle,
> the issue close, the deploy-verify lane) all run after it is closed.

`tests/merge-conductor-shard-test.sh` drives both directions of this with real processes: a
child WITHOUT `9>&-` must still hold the lock after its parent dies (or the test proves
nothing), and a child WITH it must not.

**The lock files themselves are collected.** One empty file per PR the conductor has ever
seen would otherwise live in `locks/` for ever. `mc_pr_lock_gc` (end of the tick, beside the
other GCs) removes a PR lock file untouched for `MC_PR_LOCK_TTL_DAYS` (14) — and removes it
UNDER ITS OWN LOCK, which is the only safe way to unlink one: a worker that opened that path
a moment ago holds the same inode, so taking the lock first means the name never disappears
mid-tick, and `-n` means the GC never waits on a live worker. The per-project merge and git
locks do not match the pattern and are never collected.

**Tick metrics.** Every project logs ONE structured line per tick beside the human lines,
and writes the same numbers to `state/merge-conductor/tick-<project>.json` (last tick only)
for an SLO/DORA reader:

```
2026-09-15 23:05:12Z TICK project-5 tick=20260915T230501Z-4412 secs=11 prs=9 locked=1 merges=1 rebases=2 rereviews=1 budget_exhausted=0
```

```json
{"tick":"20260915T230501Z-4412","project":"project-5","started_at":1789514701,"finished_at":1789514712,
 "duration_secs":11,"prs_seen":9,"prs_locked":1,"merges":1,"rebases":2,"rereviews":1,"budget_exhausted":0}
```

- `prs` / `prs_seen` — PRs of this project the tick looked at.
- `locked` / `prs_locked` — of those, skipped because another worker holds that PR. This is
  the number that was invisible before: it used to be a whole project, silently.
- `merges` — merged outright or handed to the repo's merge queue by this tick.
- `rebases`, `rereviews` — detached lanes spawned.
- `budget_exhausted` — actions refused because the project's per-tick budget was spent.
  `merges=0 budget_exhausted=4` says the flags were on and the cap was the thing in the way.
- `secs` — how long that project's tick took. It is the number the shard exists to stop
  mattering: a long tick now costs one PR its turn, not a repo.


## 3. The state machine (persisted in the jobs ledger)

**Ledger row.** `ledgers` already has the shape (`worker/jobs/schema.sql`: `kind, key,
status, job_id, actor, detail(≤4000), created_at, updated_at`, PK `(kind,key)`; `GET
/api/ledger?kind=` lists whole rows newest first). No schema change. New kind, additive:

```
kind    = pr_state
key     = <owner/repo>#<number>              e.g. example-org/project-5#303
status  = <STATE>                            one of the states below
detail  = {"since":"<iso>","head_sha":"…","reviewed_sha":"…","verdict":"APPROVE|BLOCK|-",
           "merge_state":"CLEAN|DIRTY|BLOCKED|UNSTABLE|UNKNOWN","reason":"…",
           "record":"<build dir or ->","url":"https://github.com/…/pull/N",
           "alerted":"<STATE>@<since>"}      # written by job_ledger_put via bin/jobs-client.sh
```

`since` resets on every transition, so `age = now - since` is the console's column. Written
through `job_ledger_put pr_state <key> <STATE> <detail>`; read back with
`job_ledger_list pr_state` / `job_ledger_get`. The sweep's write-through file pattern is kept:
`state/merge-conductor/pr-state.tsv` mirrors the rows so a worker outage neither loses the
clock nor double-alerts (fail-open both ways, as every jobs-client reader is).

And it reads back: `mc_rows_rehydrate`, at the end of `mc_init`, rebuilds an **empty**
`pr-state.tsv` from `ledgers(kind=pr_state)` — the `detail` of each row becomes one TSV line,
terminal rows and their `alerted` marks included, which is what stops a rebuilt hub paging
again about every closed-unmerged PR the old box already paged about. A non-empty file never
asks, so the every-five-minutes tick costs nothing; the walk is bounded to `MC_REHYDRATE_PAGES`
pages of 1000 rows (default 5) and says `truncated=true` in its log line when it hits the cap.
It is whole-or-nothing — any failed page leaves the file empty for the next tick to retry — and
it writes through the same `pr-state.tsv.lock` `mc_row_put` takes, only if the file is still
empty inside the lock, so the conductor and `bin/blocked-resolver.sh` cannot double-write.
`MC_REHYDRATE=0` disables it. Driven in `tests/pr-state-rehydrate-test.sh`.

**States and what decides them** (evaluated in this order every tick, from fresh `gh pr view
--json state,mergeStateStatus,headRefOid,mergeable,isDraft,closedAt,mergedAt` plus the
verdict lookup the sweep uses: `job_verdict` first, `review.md` + `reviewed-sha` second):

| State | Meaning | Entered when | TTL |
|---|---|---|---|
| `WAIT_CI` | checks on the head are pending, red once, **or a killed runner away from an answer** (`reason=checks flake`, BH-636), **or the identity this lane runs as may not push to the base at all** (`reason=IDENTITY_NOT_PERMITTED <identity>: …`, BH-800), **on a head that is not conflicted** | actions/runs on `headRefOid` has a run not concluded, or exactly one red run and no green rerun yet (`review-prs.sh`'s CI read: `repos/<slug>/actions/runs?head_sha=`; the checks API is 403 for our PATs). **A `mergeStateStatus BLOCKED` whose base gates nothing — no required status check, no required review, no required conversation resolution, no branch lock — is not a check at all (BH-800)**: it is GitHub refusing the push, because the token this lane runs as is not in the branch's push allow-list. `bin/lib/gh-push-identity.sh` classifies that from one `branches/<base>/protection` read per repo per tick (the workers are concurrent subshells, so the per-tick cache file is written and read under a `flock` on itself), the reason names the identity, the flake ladder and BOTH close/reopen CI kicks — the stuck detector's and the one for a head GitHub has never run a workflow on — are skipped (none of them can add a push permission) and ONE ALERT per (repo, identity, UTC day) names what is needed and from whom. `unexplained` — nothing gated and no `restrictions` block at all, or an identity we could not name — is annotated on the bare line and NEVER paged, and so is every protection read that failed; see `docs/verification-map/push-identity-not-permitted.md`. Since 2026-09-14 the box-side copies of that read go through `bin/lib/gh-ci-read.sh`, which retries once on a read-only App token when the box's own PAT 403s on actions/runs too — the project-2 box, where "CI status unavailable" deferred three reviews indefinitely. **Also (BH-370.2)** `reason=hotfix migration proof missing|stale`: a `hotfix` PR that ADDS migration SQL is held here until the stage posts an accepted proof for exactly that SQL (section 6) | **90m** (`MC_TTL_WAIT_CI`) |
| `WAIT_REVIEW` | a head the conductor's own re-review just APPROVED, parked for one tick so the next one classifies from the bound head | written by the `HEAD_MOVED` re-approval path (`headbound_review`) and by `bin/blocked-resolver.sh`. **`mc_classify` no longer answers it at all (2026-09-14).** It used to mean "no verdict bound to this head AND the PR is DIRTY", and that was a dead end twice over: nothing in the harness reviews a `WAIT_REVIEW` row and nothing rebases one either, so a conflicted PR with no verdict sat in it for ever. A DIRTY head is `NEEDS_REBASE` now whatever its verdict says — the rebase comes first, and the fresh head-bound review is bought on the head the rebase pushes, which is the head that can actually merge | **90m** |
| `HEAD_MOVED` | there IS a reviewed sha (ledger `reviewed_sha` or record `reviewed-sha`) and it is not `headRefOid` — **or (2026-09-14) no verdict is bound to the head at all** (reviewed sha absent, or equal to the head with an empty verdict: an old BLOCK cleared by a migration apply, a resolver hand-off that set none) on a non-DIRTY PR, `reason=no verdict bound to head <sha8> — fresh detached review` | the sweep's park condition, made a state instead of a dead end. Both shapes are the same fact — nobody has adjudicated the code sitting here — and both buy the same detached head-bound review (section 4), behind the same CI-green debounce and the same one-review-per-(PR, head) rule. With no previous reviewed sha the prompt and the PR comment say *fresh head-bound review*, not *re-review*. **From BH-764 the row has three more ways out instead of sitting past its TTL**: a verdict `bin/review-autopilot.sh` has ALREADY posted for this exact head is consumed rather than paid for again (below); a head whose every run was cancelled/timed out and whose one flake-ladder rerun died the same way buys its read WITHOUT CI, once, with the verdict comment saying so; and a verdict consumed on an earlier tick while the ledger's reviewed sha never moved is re-applied once instead of returning in silence | **90m** |
| `NEEDS_REBASE` | `mergeStateStatus DIRTY` (or `mergeable CONFLICTING`) — **whatever CI says and whatever verdict is bound to the head (2026-09-14); `dirty-under-provenance` when provenance also set (BH-491, 2026-09-16)** | the rebase train's condition, for every repo. **The order is the fix for project-5 #799/#826/#838/#863**: this test used to sit BELOW the CI case, and GitHub runs no `pull_request` workflow on a PR it cannot merge, so `ci=none` is the NORMAL state of a conflicted PR — every one of them answered `WAIT_CI reason=checks none` and waited for a run GitHub was never going to start. #799 was in that row for four hours with no rebase line and no resolver line ever written. CI has nothing to say about a head that conflicts: the rebase produces a new head and that head gets its own CI, its own strikes and its own review. The red-twice park is unchanged for every PR that is not DIRTY | **30m** |
| `REBASING` | the conductor holds a rebase in progress (scratch worktree exists, lease taken) | set at the start of a rebase action; a tick that finds it older than 20m treats it as a crashed action and goes back to `NEEDS_REBASE` with `reason=rebase-crashed` | **30m** |
| `BLOCKED_HUMAN` (displayed **`BLOCKED_AGENT`** for the reasons the resolver owns — `mc_state_display`) | the conductor itself cannot move it. `reason` is one of `test-tamper`, `iron-law`, `migration-gated`, `conflict-unresolvable`, `rebase-gate-red`, `red-ci-twice`, `verdict-contradiction`, `provenance`, `tightened`, `head-not-reapproved`, `no-verdict`, `queue-ejected-twice`, `merge-failed-twice`, `queue-enqueue-failed-twice`, `parent-closed`, `orphaned-child`, `hotfix-migration-hold`, `contested:<path> (winner <KEY>)` | the sweep's park causes (verdict contradiction, iron-law hit, static guards red, non-primary provenance, review gate tightened), the queue's blocked causes (conflict the lander declined), two red CI rounds on the same PR, a re-review that BLOCKs. **`head-not-reapproved` means the CONDUCTOR'S OWN head-bound read refused this head from 2026-09-16** — the build gate's `blocked@<head>` buys that read first and no longer parks on sight (section 4, `MC_REREVIEW_ON_MOVE`). **The state word is kept for compatibility; the meaning changed on 2026-09-13** — `bin/blocked-resolver.sh` drains all but `migration-gated`, `verdict-contradiction`, `provenance`, `tightened` and `hotfix-migration-hold` on an agent ladder (section 11). Those five still page; the rest log and do not. **The eight hand-off reasons are STICKY from 2026-09-14** (`mc_handoff_owns`, section 4; `orphaned-child` joined them on 2026-09-16): the tick leaves the row where it is and takes no action on the PR until the head moves, the PR settles, or the resolver releases it. **`contested:<path> (winner <KEY>)` (BH-579, 2026-09-17; the conductor's half, BH-589)** is a loser of a contested path, parked by `bin/blocked-resolver.sh` and — from BH-589 — by the conductor's own `pr_worker`, which checks `mc_contested_loser` after the batch-train check and BEFORE the verdict read, so a parked loser buys no re-review, no rebase and no merge. Another ticket won the file and is landing it; the hold is released to `NEEDS_REBASE` when the winner merges (`conductor_settle`, no alert — a winner landing is the good outcome), when the winner is abandoned, or when the hold expires (section 12), and it is never paged by `mc_stuck_check` — the hold has its own clock. It is NOT a hand-off reason (`mc_handoff_owns` excludes it, deliberately): the row goes back into ordinary classification the moment it is released, and a hold that vanishes without a release lets the next tick reclassify it from GitHub. **The hold now binds BOTH lanes**: the resolver spends no rung, no rebuild and no API call on a held PR, and the conductor neither rebases nor merges one 
| **2h** |
| `RED_TWICE` | the red ladder ran out: this head was red, its failed runs were re-run once (`mc_red_rerun`), and CI came back red on the SAME head | **2026-09-15, project-5 #1045.** `WAIT_CI checks red once` had no next transition — the `red-ci-twice` park counts reds on two DIFFERENT heads, so a PR that goes red and is never pushed to again sits in `WAIT_CI` for ever (#1045/TK-989 went red at 02:04Z, was logged once, and was untouched for ten hours until it was closed by hand at 12:52Z). The ladder is per HEAD: rung 0 dispatches ONE `gh run rerun --failed` of the failing runs — the flake path's mechanics (`mc_flake_rerun`) applied to ANY red, with its forgiveness untouched: a red that is not an all-known-flake red still takes its strike — rung 1 is that rerun in flight (`MC_RED_RERUN_SETTLE_SECS`, 300s, so the old conclusion is never read as a second red), rung 2 is red again and lands here. A pushed head resets the ladder, because the mark is keyed on the head. `mc_resolver_owns` covers reason `red-twice`, so it never pages by age; `bin/blocked-resolver.sh` reads the row like any `BLOCKED_AGENT` park and, since 2026-09-15, climbs its ladder rather than rebuilding on sight: merge main / re-run the failed jobs, then an agent fix round briefed with the failing job's own log, then a fresh rebuild (section 12). NOT sticky, for the same reason `red-ci-twice` is not: it is re-derived from CI every tick and a rerun that goes green underneath us must move the row | **2h** |
| `NEEDS_HUMAN_VERDICT` | a clean, approved PR on a Mergify repo whose `lead-verdict` status BH-3683 withholds (`la_decide` rc 1: a protected path, or revoked lane authority). Nothing labels it or asks `@mergifyio queue`; `reason` names the path and the exact `bin/lead-verdict.sh post <slug> <pr> <head> MERGE --source human` | the BH-3777 gate (`mc_nhv_gate`) on a READY row before the arm; an enqueue that answers rc 4 (`mc_enqueue_mergify`, BH-3806); or a row QUEUED with our `merge-queue` label, no `lead-verdict` success on its head and la_decide rc 1, whose label `mc_nhv_unqueue` takes off once per (PR, head) (BH-3806). Leaves to `READY` on the first tick after a human verdict on the head (then `QUEUED`). rc 2 is never this state: it is the BH-2199 hold | **60m** (`mc_ttl` 3600) |
| `ABANDONED` | the resolver's ladder ran out: rebuilt fresh up to 3 times, or the fix round and the adjudication both failed | terminal. The PR is closed, `mc_classify` pins the row so no later tick walks it back in, the budget is -1 so it never pages by age, and ONE alert (the resolver's, not the conductor's) lists every attempt. It is an outcome record, not a review request | none (terminal) |
| `READY` | APPROVE bound to head, checks green, `CLEAN` (or a sweep discount applies), iron-law scan clean, pre-arm guards not red, kill switch absent, **and `mc_base_guard` passes** — a PR whose base is known and is not the project's never leaves this state through a merge (BH-410) | all of the sweep's merge conditions | **20m** |
| `QUEUED` | the conductor put it in the repo's **merge queue** (GitHub's native one, or Mergify — section 6) and the queue has not landed it yet | `isInMergeQueue == true` for provider `github`; the `merge-queue` label for provider `mergify`. There is no merge-state word for either: `mergeStateStatus`'s enum is `DIRTY UNKNOWN BLOCKED BEHIND UNSTABLE HAS_HOOKS CLEAN` and a queued PR still reports one of those, so the witness is read from the PR itself and passed to `mc_classify` as `MC_INQUEUE`. Budget 3600s. Leaves to `MERGED` (the settle pass), to `WAIT_CI reason=queue-ejected` (the queue dropped the entry because its batch build went red), or, on a second ejection, to `BLOCKED_HUMAN reason=queue-ejected-twice`. **From BH-636 it is also ENTERED from an ejection**: a Mergify PR whose head is still green, still approved at that sha and still `CLEAN` is re-queued once per (PR, sha) with `reason=requeued on <sha8> after a flake ejection` (section 6) | **60m** |
| `STACKED_WAIT` | the PR's `baseRefName` is **not** the project's base — it was built on another PR's branch (stacked child builds, 2026-09-14) | the child of a `Blocked-by:` parent whose PR was still open when the child built. Evaluated FIRST, ahead of every other clause except GitHub's own terminals: a stacked PR must never be merged (that would land the child INTO the parent) and must never be rebased either, because `mc_rebase` merges `origin/main` into the branch and the child's diff is supposed to show one ticket. Leaves the state by itself: GitHub retargets the PR to the project base when the parent merges and its branch is deleted, and on a repo that keeps merged branches the conductor does the retarget with `gh api -X PATCH repos/O/R/pulls/N -f base=<base>` (`gh pr edit --base` reports success and changes nothing). **A retarget fires no CI**, so the conductor closes and reopens the PR straight after it (`mc_kick_ci`, section 4) — without that the retargeted head has no workflow run at all and the row simply moves from `STACKED_WAIT` into a permanent `WAIT_CI checks none`. Parent CLOSED without merging (a resolver rebuild, a hand close) is an EVENT from 2026-09-16, not a dead end, and it is answered in TWO steps. First the rebuild is resolved: `mc_retry_pr` looks for the PR on `ticket/<key>-rN` and, if one is live, `mc_restack` rebases the child onto it and PATCHes its base there (BH-458, section 14). Only when NOTHING has replaced the dead branch is the child's own branch read — `mc_orphan_clean`, locally and read-only — and a child that carries **no** commit of the dead parent beyond the base and merges into the base cleanly is retargeted to the base (and kicked) exactly like the merged case — it keeps its number and its CI, and since BH-3950 it owes a head-bound re-review before it can merge (`MC_RETARGET_REREVIEW=0` restores keeping its review). A parent with NO PR at all (`NONE`, BH-3950) takes the same orphan path once the list read is verified empty and the base branch is gone (404) or has sat PR-less past the `STACKED_WAIT` TTL; an unreadable read, an open parent ticket (`open_pr_for_key`) or an open `ticket/<key>-rN` rebuild (`mc_retry_pr`) keeps it waiting. For a NONE parent whose branch is gone, `mc_orphan_clean` decides on the conflict half alone (`carry=0`: there is no parent ref to intersect, and the owed re-review reads whatever the child carries) — but only while `MC_RETARGET_REREVIEW` is on; with it off, the full check runs and the gone branch parks `orphaned-child`. A child of a CLOSED parent that still carries the parent's commits, that conflicts with the base, or whose parent branch is gone from origin parks on `BLOCKED_HUMAN reason=orphaned-child`, which `mc_resolver_owns` — `bin/blocked-resolver.sh` gives it a fix round on the same branch (class `orphaned-parent`: no rung-1 merge, no `origin/main` merge, the brief is "rebase off the dead parent") and a fresh rebuild after that. A tick that cannot read the branch at all (no checkout, no token, git older than 2.38) says so once per head and leaves the row on `parent-closed`. Nothing on this path closes a PR and nothing on it is on a timer. Kill flag `MC_ORPHAN_RETARGET=0`. Budget 4h. **It was inert from the day it shipped until 2026-09-14** — not the lookup and not the flag, but the empty tsv field above: `BASEREF` was empty on every PR, so the block's own guard turned it off | **6h** |
| `MERGED` | GitHub says `MERGED` | terminal; who merged it is recorded (`by:conductor|tier1|sweep|queue|human`, from `mergedBy.login` and whether the conductor did it) | none (terminal) |
| `CLOSED` | GitHub says `CLOSED`, not merged | terminal; alert only in the issue-still-open case | none (terminal) |

**THE `TTL` COLUMN IS THE STUCK DETECTOR (2026-09-15), NOT THE AGE BUDGET.** The budget in
section 5 is the ordinary "this has been in `READY` for 15m" alert, and several states
deliberately never page on it — a park `mc_resolver_owns`, an `ABANDONED` outcome. The TTL is
the backstop *under* all of that: whatever the state and whatever its budget, a PR that has
not moved in longer than this is stuck, and `mc_stuck_check` raises ONE alert per
**(PR, state, head)** naming what it is waiting on, then `stuck_rekick` does the deterministic
re-kick for that state if one exists. project-5 #1045 sat ten hours inside `WAIT_CI`'s budget
after its single 30m alert, and #1124/#1136 sat hours in parks that page never; neither was
reachable from the budget table. Each default is overridable per state from `env/global.env`
as `MC_TTL_<STATE>` (seconds; `-1` turns one off).

**`provenance` IS A REVIEW REQUEST, NOT A PARK (2026-09-14, project-5 #864/#865/#866/#867).** It says a NON-PRIMARY runner authored the build's own APPROVE — a fact about who read the code — and the conductor can buy the read that answers it: the detached head-bound claude review it already buys for a moved head. Until today it did buy one and then threw the answer away (#864: `BLOCKED_HUMAN reason=provenance` at 20:25:41Z, `detached re-review finished: APPROVE on 71d1e161` at 20:34:21Z, merged by the orchestrator by hand at 20:45Z; #867 identical), because `mc_classify` returns `provenance` ahead of the drift branch and the done-job handling lived only in the `HEAD_MOVED` arm. A returning APPROVE bound to the CURRENT head is now CONSUMED (`re-review APPROVE consumed on a provenance hold`), recorded as `provcleared <key> <head>` in `MC_ATTEMPTS`, and handed to `mc_classify` as `MC_PROV_CLEARED=1`, which classifies the row normally on that same tick. A returning BLOCK parks it on `head-not-reapproved`, which the resolver owns, instead of `provenance`, which nothing does. **It does not page while it is being fixed (2026-09-15, project-5 #1058/#1071, project-4 #1478):** with `flags/merge-conductor-actions` on and the hold younger than `MC_PROV_AUTO_SECS` (3600) `mc_budget_check` logs `auto-resolving, not paged` (naming whether the claude read is running, finished, or still to be bought) under a marker that is not the day mark, so the hold pages exactly as before the moment the window runs out, the read fails, or the flag is off (`mc_prov_autoresolving`). The clearance is bound to ONE head — a push is unread code again — and the ledger's provenance is NOT rewritten: the build's own review really was served by the runner the row names

**JUDGE PROVENANCE IS THE (RUNNER, MODEL) PAIR, NOT THE RUNNER WORD (2026-09-16, project-5
#1621/#1624 — `bin/lib/review-provenance.sh`).** The rule has always been that an APPROVE
which auto-merges must have been authored by Claude: the judge node is the one place a
cheaper lane costs everything. It was written everywhere as a string compare against the
RUNNER word (`[ "$runner" = claude ]`, `[ "$LEDGER_PROV" != claude ]`, `grep -qx claude`),
and the runner names the CLI that made the call, not the model that answered it.
`bin/agent-call.sh`'s tier-3 survival lane deliberately keeps the stage's own model (the operator,
2026-08-02: "never substitute deepseek — keep the phase model"), so a review served there is
`runner=openrouter, model=anthropic/claude-fable-5.1` — Claude, reading the diff, writing the
verdict — and the fleet was filing it as a cheap fallback: parking PRs on `provenance`, and
in the conductor's own re-review rewriting its APPROVE into a BLOCK.

| served by | recorded word | merge gates |
| --- | --- | --- |
| the `claude` lane | `claude` | primary |
| `openrouter` + an `anthropic/…` (or `~anthropic/…`) slug | **`claude-via-openrouter`** | primary — a Claude read, reached through tier-3 |
| `openrouter` on its deepseek floor, `grok`, `codex`, `fireworks`, `gemini` | that lane's own word | gates the build, never auto-merges |
| nothing recorded (`-`, empty, a record older than the marker) | `-` | "the ledger said nothing" — never a hold, and never a claim either |

The word is **honest, never laundered**: a tier-3 review records as
`claude-via-openrouter`, not as plain `claude`, so the ledger keeps saying which lane carried
it AND any reader in the fleet that has not been taught the new word treats it as
non-primary — i.e. it holds the PR. Every direction an un-updated box can be wrong in is the
safe one. `mc_prov_held`, `mc_classify`, `bin/merge-sweep.sh`, `bin/review-prs.sh` and
`bin/run-build.sh`'s tier gate all read it through `rp_prov_is_claude`.

**THE MODEL IS ONLY EVIDENCE FOR AN ALLOWLISTED RUNNER**, which is load-bearing rather than
tidy. `$OUT.model` used to be written by the claude branch alone, so a stage that laddered
down left the CLAUDE attempt's model beside the FALLBACK's runner word — project-5 #1624's
grok review carried `claude-opus-5` in its model file. A rule that read the model alone would
have called that a Claude read. `bin/agent-call.sh` now writes `.runner` and `.model`
together, for every lane, under one last-attempt-wins rule.

`BLOCKED`, `UNSTABLE`, `UNKNOWN` merge states map onto the above: `BLOCKED` with a required
check missing is `WAIT_CI`; `UNSTABLE` with every run green is `READY` via the sweep's
green-run discount (project-4 keeps its stricter substance-runs rule); `UNKNOWN` (GitHub still
computing) keeps the previous state and is retried, never a transition.

**THE ORDER IS PART OF THE CONTRACT (2026-09-14).** Three of the four ways a PR got stranded
this week were order or plumbing, not missing code, so the sequence `mc_classify` evaluates
is written down here and pinned by `tests/merge-conductor-test.sh`:
GitHub terminals (`MERGED`/`CLOSED`) → `ABANDONED` → `MC_STACK` → tightened → contradiction →
BLOCK → **`DIRTY`/`CONFLICTING`** → provenance (unless `MC_PROV_CLEARED`) → head drift →
`MC_INQUEUE` → no verdict bound to the head → CI → iron-law → pre-arm → merge
state. The one that moved is `DIRTY`: it used to sit after CI and after the no-verdict
branch, which is why no conflicted PR on the fleet ever reached `mc_rebase`.

**BH-491 (2026-09-16): a DIRTY head is not parked for provenance at all.** A DIRTY PR with a
non-primary provenance (`codex`, etc.) was stuck on `BLOCKED_HUMAN provenance` — the
provenance arm fired first, CI was `none` (GitHub runs no workflow on a conflicted head),
the auto-resolving window ticked but could not clear, and the PR was stuck forever.
The guard is a **fall-through on the provenance arm itself**, not a copy of the DIRTY test
hoisted above it: hoisting shadowed the head-drift branch, so a conflicted PR whose head had
moved answered `NEEDS_REBASE` instead of `HEAD_MOVED` and stopped buying the head-bound
re-review that binds an approval to the sha it read (#506). The ordering is unchanged; a
DIRTY PR simply falls past the provenance park to the DIRTY arm below, which emits
`dirty-under-provenance` so the conductor rebases. A bound claude re-review no longer buys a
headbound read on a DIRTY head either, because the new head the rebase pushes gets its own
review. "Non-primary" is `mc_prov_held`, not a literal word list — `claude-via-openrouter`
is a Claude read and is never held (2026-09-16).

**AND THE ROW HAS TO SURVIVE THE PIPE.** `bin/merge-conductor.sh` reads the PR list as a tsv
and `IFS=$'\t' read` COLLAPSES a run of tabs, because tab is an IFS *whitespace* character in
bash — so a PR with no labels emitted `…\tfalse\t\tticket/TK-763` and `baseRefName` slid into
the labels variable, leaving `BASEREF` empty on every harness PR (harness PRs carry no labels
on any repo without Mergify). The stacked-child block tests `[ -n "$BASEREF" ]`, so it never
fired ONCE: project-5 #868 sat an hour after its parent #831 merged with no retarget, and
#848/#850/#852 were never `STACKED_WAIT` at all. Every column of that tsv now emits `-`
rather than an empty string and the loop strips the placeholder back off. The rule for
anything added to it: **a tsv column read positionally may never be empty.**

**AND THE TSV IS THE BELT, NOT THE WHOLE ANSWER (BH-410, 2026-09-17).** The rule above is
one column away from being lost again — a positional column appended without its `-`
placeholder, a field-list edit, a REST-fallback of a different shape — and when it IS lost
the stacked-child clause abstains (it tests `[ -n "$BASEREF" ]`), the row classifies `READY`,
and the only thing left between it and `gh pr merge` used to be nothing at all. So the base
is now checked AT THE MERGE ACTION as well, by `mc_base_guard` (`bin/lib/merge-conductor-lib.sh`),
from two sources: the list's `BASEREF`, and a `baseRefName` that rides along on the
pre-action `gh pr view` the `READY` arm already makes (one more field, no extra API call).
**A base that is KNOWN and is not the project's base never merges and never enqueues** — both
direct-merge sites and `mc_enqueue` are behind it — whatever labels the PR carries and
whether or not the list still has the column. The row parks `STACKED_WAIT` with
`reason=merge refused: based on <branch>, not <base>` and one `MERGE_REFUSED` log line, and
the refusal writes nothing to GitHub and spends no unit of the tick's merge budget. A source
that knows NOTHING abstains rather than refusing: `-` and an empty fresh read are not
evidence that a base is wrong, and GitHub never answers a null `baseRefName` for a real PR.
The fresh read outranks the list, because the list was read at the top of the tick — and for
the same reason, the two retarget sites that clear the stacked park set `BASEREF="$PBASE"`
straight after the PATCH lands, so a child retargeted earlier in the same tick is not refused
for a base GitHub no longer has.

The list-side half of that check is deliberately **redundant** with the `STACKED_WAIT` clause
in `mc_classify`, which today parks every PR it could fire on; it reads no label and depends
on no clause ordering, so a reordering of the classifier cannot turn into a merge into a
feature branch (BH-491 hoisted one clause on 2026-09-16 and shadowed two branches that had
nothing to do with it). Its unit behaviour is pinned in section 1 of
`tests/merge-conductor-stacked-base-test.sh`; the fresh-read half is what the driven repro in
section 4 of that file exercises.

The `enhancement` labels put on `example-org/project-7` #445 and #447 as a stopgap were a
GitHub-side way of keeping those PRs out of a merge. Nothing in the conductor has ever read
them — `RAWLBL` is consumed only by `main_red_exempt` (`fix-main-red`) and
`mc_mergify_inqueue` (`merge-queue`) — and with `mc_base_guard` in place the guard is
label-independent by construction, so those labels may be removed.

**Every transition logs one line** to `logs/merge-conductor.log`:
`<stamp> <key> <FROM> -> <TO> head=<sha8> reviewed=<sha8|-> merge=<state> reason=<…>` and
puts the row. No transition, no line (a quiet tick is quiet). A `job_event` is not opened
per tick for the same reason the sweep's claim is lazy: the row opens only around an action.

## 4. Actions per state

Actions run only with `flags/merge-conductor-actions` (rebase, re-review) and
`flags/merge-conductor-merge` (merge) present. Absent flags = observe-only: states and alerts
still update, nothing is written to GitHub or a branch. `flags/automerge-disabled` (the fleet
kill switch, reconciled through `flag_active`) pauses merges AND rebases; states keep updating.

**`NEEDS_REBASE` → the conductor rebases.** Merge `origin/main` INTO the branch (merge, not
rebase: the reviewed commits keep their shas, so `reviewed_sha` stays an ancestor and the
HEAD-BOUND prompt's "commits since" range stays honest) in a scratch worktree:
`/root/repos/<project>` when the hub has the clone (project-4, project-1, project-3, project-2 today),
else a cached `git clone --filter=blob:none` under `tmp/conductor/<slug>`. Conflicts: the
rebase train's three deterministic resolvers (package.json test-script token union,
vercel.json crons union, markdown both-sides-append) are lifted into the lib and applied;
anything else aborts, and the PR goes `BLOCKED_HUMAN reason=conflict-unresolvable` with the
`git diff --name-only --diff-filter=U` list in the alert. One attempt per (PR, main sha);
the pair is recorded so the next tick does not retry the same conflict. Gates before the
push: `npm run typecheck` when the script exists and `node_modules` is available (hub
clones), else `npx tsc --noEmit` against the baseline the rebase train computes
(`state/tsc-baseline-<project>.txt`), then `npm run test:unit` when present. A repo with no
gate runnable on the hub (project-5: no clone, no `node_modules`) is pushed and the
required CI check ("Build + Unit tests" on project-5's main ruleset) is the gate: the PR
goes `WAIT_CI`, which is what it is. Push form: `git push --force-with-lease=<branch>:<sha>`
with `<sha>` = the `headRefOid` the conductor READ this tick (PR #252's explicit lease; a
head that moved between read and push is rejected, never overwritten). After the push:
rebind the approval (`job_verdict_rebind <url> <newsha>` and the record's `reviewed-sha`,
exactly what `rebase-train.sh` does), so the sweep-shaped READY test sees a bound head.
Run-build's gate block is not lib-able (it is inline in a 2300-line script and depends on
build-dir state), so the conductor reuses the queue's and the train's gate forms instead and
says so.

**THE REBASE IS DETACHED TOO, AND THE TICK ONLY READS IT (2026-09-14, the operator).**
Everything in the paragraph above still happens; what changed is WHERE. A clone or fetch
plus a merge plus `npm run typecheck` plus `npm run test:unit` plus a push is MINUTES per
PR, and every one of them used to be spent inside the `*/5` tick that held the project's
own lock — so a project with three DIRTY PRs spent its whole
tick rebasing and nothing else on that project moved. The tick now SPAWNS one job per
(PR, head) (`mc_rebase_spawn`) with `setsid nohup`, a NAMED `PATH` and the tick's lock fd
CLOSED (`9>&-`), and READS the result on a later tick. The job runs `mc_rebase` unchanged —
same gates, same explicit lease, same rebind — and it sources `bin/jobs-client.sh` and
`bin/lib/gh-repo-token.sh` itself, because `job_verdict_rebind` (the approval hand-off that
actually matters for pool builds) and the admin-PAT candidate live in a SHELL, not in the
environment a child inherits.

A job is one file, `state/merge-conductor/rebase/<owner_repo>_<num>_<head>.json`:
`{status: running|done|failed, pid, started_at, finished_at, rc, head_sha, new_head,
out_file}`. `rc` is `mc_rebase`'s own exit code and `out_file` its stdout, so the tick
applies exactly the arms it always applied (`rebase_result` in `bin/merge-conductor.sh` is
the one copy of them, shared with the kill-flag path below):

| job for (PR, CURRENT head) | the tick |
| --- | --- |
| `running`, pid alive, younger than `MC_REBASE_TIMEOUT_SECS` (default 1800s) | logs `REBASING` and moves on. Nothing waits |
| `done` | applies `rc` — 0 `WAIT_CI` on the pushed head, 1 `conflict-unresolvable`, 2 `rebase-gate-red`, 3 lease rejected, 5 `rebind-failed`, anything else setup failed — once per (PR, head). **rc 4 also covers a merge that git refused for a non-conflict reason**, and since BH-517 it is never silent: the line is `<url> rebase: merge failed — <git's stderr>` (or `rebase: commit of the resolved merge failed — …`), and a SHALLOW hub clone — `.git/shallow` present, which is how a `--depth` restore leaves it — is unshallowed once under the project git lock and the merge retried in the same call before that. rc 4 never prints a conflict list of zero files; `mc_restack` classifies the same way (`restack: rebase --onto failed — …`). **rc 5 splits on whether there was an approval at all (2026-09-14)**: since a conflicted PR with NO verdict reaches this lane too, `job_verdict_rebind`'s "no claim to move" is the expected answer for it, not a failure — that row goes `WAIT_CI reason=rebased to <sha8>, no verdict to rebind` and buys its head-bound review on the new head, instead of looping in `NEEDS_REBASE` |

| `done` | applies `rc` — 0 `WAIT_CI` on the pushed head, 1 `conflict-unresolvable`, 2 `rebase-gate-red`, 3 lease rejected, 5 `rebind-failed`, anything else setup failed — once per (PR, head). **rc 5 splits on whether there was an approval at all (2026-09-14)**: since a conflicted PR with NO verdict reaches this lane too, `job_verdict_rebind`'s "no claim to move" is the expected answer for it, not a failure — that row goes `WAIT_CI reason=rebased to <sha8>, no verdict to rebind` and buys its head-bound review on the new head, instead of looping in `NEEDS_REBASE`. **The `rebasedone <key> <head>` marker that makes it once-per-head is appended AFTER the result is applied (BH-523)** — it used to be recorded on first sight, so a worker killed in between left the marker with no transition behind it and the finished rebase was dropped for ever (the hub had ~20 heads in that shape on 2026-09-16). A marker with no transition behind it — row still `NEEDS_REBASE`/`REBASING` on that head, and an rc whose application moves the row (0, 1, 2, 5) — is applied once, with `<key> finished rebase result on <head8> was never applied — applying now`. rc 3 and rc ≥4 park the row in `NEEDS_REBASE` on the same head by design, so for those a seen marker plus that row IS the applied state and is never re-read |
| `running` with a dead pid, or older than `MC_REBASE_TIMEOUT_SECS` | marked `failed`; the PR goes back to `NEEDS_REBASE` and its budget pages if it stays there |
| none | spawns one, as long as fewer than `MC_REBASE_PARALLEL` (default 4) are running fleet-wide; at the limit it logs `REBASE_QUEUED` and tries next tick — a refused spawn does NOT burn this head's one rebase |

The result is read BEFORE the classifier runs (`rebase_consume`), not in the `NEEDS_REBASE`
arm: the job pushed minutes ago and may already have moved `reviewed-sha` onto the head it
pushed, so its result is a newer fact about the PR than anything `mc_classify` can derive
from the head the job started from. Applying it and moving to the next PR is the same order
the inline rebase had, where the rebase was the last thing a tick did for a PR.

**AN EXIT THAT REBASES NOTHING NAMES ITSELF (BH-764).** Two of the arm's exits were a bare
`return 0` — the `done|failed|stale` job whose result `rebase_consume` already applied, and
the one-rebase-per-head guard — under a `merge_tree_clean` line that had just announced a
rebase. The tick summary's `rebases=` counter therefore said 0 while the log said "rebasing",
which is worse than no line at all: the row read as stranded and nothing named a reason. Each
now logs `NO_REBASE on <sha8> — <why>` through `rebase_noop_say`, once per (tag, PR, head) on
a `rebasenoop-<tag>` record, and `merge_tree_clean`'s rc 1/2/3/other lines say "this head
needs a rebase" instead of "rebasing" (the `trusting GitHub and rebasing` cap line above is
unchanged — that one really does spawn). `mc_count_inc rebases` is untouched: it moves on a
spawn and only on a spawn, so the counter and the log now agree. Both `stuck_rekick` and
`mc_handoff_human_release` clear the two `rebasenoop-*` records beside the rebase attempt they
already forget, so a re-kicked or human-released head is heard again rather than deduped into
permanent silence.

**Kill flag: `MC_DETACHED_REBASE=0`** (env, `env/global.env` or the cron line) puts the
rebase back INSIDE the tick — same `mc_attempted` line, same `REBASING` transition, same
result arms, because both paths call the same `rebase_result`. Default on.

**`NEEDS_REBASE` → ASK GIT BEFORE PAYING FOR A REBASE (the merge funnel, W2-D,
2026-09-14, the operator: "every throughput ceiling is a bug").** Every merge into main marks every
other open PR on the repo DIRTY-or-stale, and today each one of them buys the whole
paragraph above: a clone, a merge, a typecheck, a push — and a MOVED HEAD, which then buys a
re-review. At 4000 PRs a day one merge into one main is therefore a rebase storm plus a
review storm, and most of it is paid on PRs that do not conflict with what landed. So before
the rebase is spawned the conductor asks git: `git merge-tree --write-tree origin/main
<head>` in the same authed checkout the patch-id rebind uses. That merges the two in the
OBJECT STORE — no ref, no worktree, no commit, no push, nothing touched — and answers in one
local operation:

| `mc_merge_tree` | the tick |
| --- | --- |
| rc 0, clean | logs `MERGE_TREE clean`, leaves the head ALONE, keeps the row `NEEDS_REBASE` with that reason, and moves to the next PR. GitHub's merge commit is what CI and Mergify test anyway, and it is the same merge |
| rc 1, conflict | logs `MERGE_TREE conflict` with the conflicting paths and takes today's rebase path, unchanged |
| rc 2, cannot tell — no token that can read the repo, a sha the remote does not have, or git older than 2.38 (`merge-tree --write-tree` is a 2.38 feature; `mc_git_has_merge_tree` is the version guard) | logs why and takes today's rebase path, unchanged |

**It can never hold a PR forever.** `mergeStateStatus` is the field the rest of this file
steers on, and if GitHub goes on saying DIRTY while git says clean then one of the two knows
something we cannot see from here. So the skip is capped at `MC_MERGE_TREE_MAX` clean
observations per (PR, head) — default 3, i.e. fifteen minutes at `*/5`, well inside
`NEEDS_REBASE`'s 30-minute age budget. Past the cap the tick logs `trusting GitHub and
rebasing` and the rebase runs exactly as it does today. Kill flag: **`MC_MERGE_TREE=0`** —
the test never runs and every DIRTY PR is rebased, byte-for-byte the behaviour before this
change.

**`HEAD_MOVED` → a head-bound Fable re-review.** The pipeline already does this inside a
build: `bin/run-build.sh`'s `# >>> head-bound approval` block re-runs the suite on the moved
head and buys one `CC review "$REVIEW_MODEL"` with the "RE-REVIEW ON A MOVED HEAD" prompt,
and on APPROVE rebinds `review-head`. The record for pool-project-5-TK-312 shows it working
(`builds/pool-project-5-TK-312-202609111812/pipeline.log`: "HEAD-BOUND: 1 commit(s) landed
after the reviewed head (161cc032 -> 9fb6b0b9)" → "HEAD-BOUND RE-REVIEW (claude-fable-5-1)"
→ "re-review APPROVED 9fb6b0b9 — approval rebound"). Outside a build there is no worktree,
so the conductor runs the same prompt the way `bin/review-prs.sh` runs its reviews:
`bin/agent-call.sh review <project> "$REVIEW_MODEL" 1200 <out> @<promptfile>` (the model resolved by
`bin/lib/review-model.sh`: `REVIEW_MODEL` in the environment, then `env/global.env`, then its
documented fallback) with the
diff from `gh pr diff` (inlined up to `MC_RR_DIFF_INLINE_BYTES` = 96000 bytes; the complete
diff is always written to `state/merge-conductor/diffs/<repo>-<num>.diff` and named in the
prompt, and a capped read is announced in the prompt as `[DIFF TRUNCATED: … ]`) and, when the reviewed
sha is still an ancestor, `git diff <reviewed_sha>..<head>` as the "commits since" scope.
The prompt text is the run-build one, verbatim, with the file references swapped for the PR
body and the record's `review.md`. Verdict APPROVE (a Claude lane only — see **Judge
provenance** below; it is the `(runner, model)` pair now, not `.runner == claude`)
→ `job_verdict_rebind` + record `reviewed-sha` → the next tick classifies from the bound
head. BLOCK → `BLOCKED_HUMAN reason=head-not-reapproved` with the findings posted as a PR
comment (`gh pr comment`) so the human reads them where the code is. No verdict →
`BLOCKED_HUMAN reason=no-verdict`, which `bin/blocked-resolver.sh` owns. One re-review per
(PR, head), so a tick can never buy the same review twice.

**THE RE-REVIEW IS DETACHED, THE TICK ONLY READS IT (2026-09-14).** It used to run INLINE:
a ~20-minute Fable call inside a `*/5` tick that held the fleet's only conductor lock, so
every other PR in every other project waited behind it — on the night of 2026-09-13 seven
approved project-5 PRs sat in `HEAD_MOVED` for exactly that reason. Now the tick SPAWNS one
job per (PR, head) with `setsid nohup` (`mc_rereview_spawn`), so it outlives the tick and
the cron parent, and reads the result on a later tick. The job runs the same `mc_rereview`
body — same prompt, same verdict parsing — and writes NOTHING to GitHub: the PR comment, the
approval rebind and the transition stay in the tick, behind the tick's own flags.

**WHERE THE RE-REVIEW AGENT RUNS (BH-8103).** `mc_rereview` starts `bin/agent-call.sh` from
a private, empty scratch dir, one per (PR, head):
`$MC_RR_SCRATCH_ROOT/<repo>-<num>-<head12>`. `MC_RR_SCRATCH_ROOT` is a path; the default is
`$TMPDIR/mc-rereview-<uid>` (the uid keeps a root tick and a `nobody` test run apart). The dir
is made fresh before the call and removed after it. If it cannot be made, the job is a lane
failure (rc 2) and nothing is billed. On 2026-10-23 the agent started in the hub's deploy
checkout, checked out a PR branch there and ran a suite as root. `bin/iron-law-guard.sh`
family 7 is the wall against that; the scratch dir removes the default that put the agent in
a shared tree (docs/verification-map/iron-law-guard.md).

A job is one file, `state/merge-conductor/rereview/<owner_repo>_<num>_<head>.json`:
`{status: running|done|failed|lane-failed, pid, started_at, finished_at, verdict, head_sha,
reviewed_sha, out_file, reason}`. What a tick does with a `HEAD_MOVED` PR is decided by that file
alone (`mc_rr_state`):

| job for (PR, CURRENT head) | the tick |
| --- | --- |
| `running`, pid alive, younger than `MC_REREVIEW_TIMEOUT_SECS` | logs `REREVIEWING` and moves on. Nothing waits |
| `done` | consumes the verdict exactly as the inline path did: APPROVE rebinds and the next tick merges, BLOCK is `head-not-reapproved`. Consumed once per (PR, head) — and **a second visit is no longer a silent `return` (BH-764)**: if the row is still `HEAD_MOVED` because the ledger's reviewed sha never moved, an APPROVE is re-applied ONCE (`rereviewreapply`, no second PR comment — that comment is already on the PR) and anything else says so once (`rrconsumed`) and leaves the row to the stuck alert |
| `running` with a dead pid, or older than `MC_REREVIEW_TIMEOUT_SECS` (default 2700s) | marked `failed` and takes the existing no-verdict path, which `bin/blocked-resolver.sh` owns |
| `lane-failed` — **the job ran and OUR LANE died under it** (2026-09-16): `mc_review_lane_failure` saw an account error (the 429 `session limit` that closed project-5 #1621), a refusal marker (`AGENT_CALL_REFUSED` / `AGENT_CALL_NO_HEADROOM`), an `agent-call` rc≠0 (#1621's survival ladder E2BIG'd on a 136KB prompt), an empty output, or a runner that is not a Claude lane | **retried, not parked.** The job file is removed, so the next tick buys another read through the same budget, cap and CI-green debounce. No strike, no park, no verdict. Bounded by `MC_RR_LANEFAIL_MAX` (5) reads per head; past it the row parks `no-verdict` (which never closes a PR) with ONE critical alert naming what is down |
| none | **the verdict may already be paid for (BH-764).** Before the budget, a `moved` row asks `mc_autopilot_verdict`: `bin/review-autopilot.sh` posts an adversarial Fable review on every PR open more than 12h, and nothing consumed the answer — a moved head whose PR already carried `MERGE` for THIS exact sha bought a second read and a `BLOCK` one was never parked. `BLOCK` → `hb_block_park`, `head-not-reapproved`, handed to `bin/blocked-resolver.sh`. `MERGE` / `MERGE-WITH-NOTES` → `hb_approve_bind`, approval rebound, row `WAIT_REVIEW` — but **only on a head whose CI is green** (or on the without-CI path below): rebinding an approval on a head that is still building would be a weaker gate than the debounce it replaces, so a MERGE on a `pending` or `red` head records nothing and falls through to the ordinary deferral. Recorded once per (PR, head) as `apverdict`, and written ONLY after a verdict string parsed. Otherwise: spawns a review, as long as fewer than `MC_REREVIEW_PARALLEL` (default 8) are running fleet-wide; at the limit it logs `REREVIEW_QUEUED` and tries next tick. **Two debounces come first**: the head's CI must be green (a head that dies in CI is reviewed for nothing), and the PR's OWN BUILD must not still be running — see below |

Job files older than three days whose head is no longer an open PR's head are removed by the
tick (`mc_rereview_gc`).

**WHERE THE AUTOPILOT VERDICT IS READ, AND WHO IS ALLOWED TO WRITE ONE (BH-764).** The
hub-local mirror `state/review-autopilot/<owner-repo>-<num>-<head12>` first, which is free and
which `bin/review-autopilot.sh` writes only AFTER its comment posted, so it cannot claim a
verdict the PR does not carry. Only when the mirror says nothing does the conductor read the
PR — one `issues/<n>/comments` call, bounded to one per (PR, head) per
`MC_AUTOPILOT_RECHECK_SECS` (3600s) by an `apread` mark written BEFORE the read, so an API
failure is not retried every tick. **The marker alone is not a credential**: this verdict
rebinds an approval, and anyone with comment rights could otherwise paste
`<!-- harness-review-autopilot <head12> -->` plus `VERDICT: MERGE` and walk a PR to `READY`.
The comment's `.user.login`, normalised the way `bin/lib/gh-pr-list.sh` normalises it (`app/`
prefix and `[bot]` suffix stripped), must be in `harness_pr_authors_json`. If that function is
not callable in the process the comment path is skipped entirely — mirror only, fail closed.
A marker for any other head12, a `skipped …` mirror line and `verdict=UNPARSED` all read as
no verdict. `MC_AUTOPILOT_CONSUME=0` turns the whole read off and the conductor buys its own
review exactly as it did before.

**THE PR'S OWN BUILD OWNS IT UNTIL IT RECORDS A VERDICT (2026-09-14).** A pool build reviews
its own PR at the END of its pipeline and writes the verdict into the ledger; the `*/5` tick
sees the PR the moment it is opened, which is minutes earlier. With no verdict bound to the
head the tick would buy a Fable re-review of code the build's own reviewer is already
reading — two reviews of one head, the second one ours — and the verdict that lands
afterwards is how project-5 #864 ended up parked on a `provenance` its build had not even
finished writing. So before any review is bought, `mc_job_running <pr-url>` asks the ledger
(`GET /api/verdict?pr=…`, the same round trip `job_verdict` makes) and a row that is
`status=running` with NO verdict yet stops the spawn: `job still running, not buying a
review — the build's own pipeline owns this PR (job <id> stage <stage> running for <n>s)`.
It is a WAIT, not a park: the row keeps the state it had and the next tick asks again.

**It is bounded, and it fails open.** A builder that dies mid-pipeline leaves `running` in
that row for ever, so past `MC_JOB_WAIT_SECS` (default 3600s, comfortably longer than a
build) the row is treated as dead and the tick proceeds exactly as it does today. No jobs
client, no worker, or a read that fails: no wait at all — an unreachable ledger can never
hold a PR.

**ONE COPY OF THE FOUR ANSWERS, TWO CALLERS (2026-09-14).** The table above used to be the
body of the `HEAD_MOVED` arm and nothing else, which is exactly how a PR parked on
`provenance` came to be sitting on a finished APPROVE nobody read. It is
`headbound_review <mode> …` now, and `mode` changes one thing — what an APPROVE MEANS:
`moved` rebinds the approval and parks the row in `WAIT_REVIEW` for one tick;
`provenance` records the clearance (`mc_prov_clear`), sets `MC_PROV_CLEARED` and transitions
NOTHING, so `mc_classify` gives the row its real state on that same tick. A BLOCK, a dead
job, the CI debounce, the running-build wait and the spawn are identical in both modes.

**`HEAD_MOVED` → no review at all, when the patch did not change (2026-09-14, the operator: "yes
that's a good change").** After every batch merge the sibling PRs go DIRTY, each is rebased,
and each rebase moves the head — so each one used to buy a full re-review of a change that
is byte for byte the change a reviewer already approved. So the conductor records the
**patch-id** of every head an APPROVE is bound to (`git diff $(git merge-base origin/main
<sha>) <sha> | git patch-id --verbatim`, in the authed clone) beside the build record as
`<record>/patch-id.<sha>`, or under `state/merge-conductor/patch-id/` when there is no
record. When the head has moved and `mergeStateStatus` is not `DIRTY`, it computes the
patch-id of the CURRENT head the same way: identical means the approval is REBOUND to the
new sha — `reviewed-sha`, `job_verdict_rebind`, a line in `<record>/rebind.log`, a `REBOUND`
log line — with NO re-review and no PR comment, and the merge path proceeds head-bound to
the NEW sha. Different, or unknown, or an old sha the remote no longer has (`git fetch
origin <sha>` fails): the detached re-review above, exactly as before. `--verbatim` hashes the
diff CONTENT including context lines AND whitespace, so a new commit, an edited line, a
hand-resolved conflict, an indentation-only edit — anything that is not a pure rebase —
changes the id and buys the review. (It was `--stable` until BH-2310's review: that strips all
whitespace, so a Python or YAML re-indent, or `rm -rf $D/cache` -> `rm -rf $D/ cache`, kept the
approved id and was rebound unreviewed.) Iron
guardrail 1 in `rules/CLAUDE.md` carries the same exception in one clause.

**…and when the head only merged main (BH-2310).** The whole-diff patch-id is taken against
the merge-base, which a main merge MOVES. So a fix round that ran nothing but `git merge
origin/main` changed the id whenever main touched a line near one of the PR's hunks (#2131),
and bought a full re-review of an unchanged patch. When the ids differ, `mc_patch_id_rebind`
now asks `mc_patch_same`, which runs `bin/lib/patch-same.sh` in the same authed checkout. That
proves the same patch from the commits themselves with `main-merge`: the head descends from the
reviewed sha, and every commit between them that is not on `origin/main` is a two-parent merge
whose tree is exactly `git merge-tree` of its parents, with no conflict. A hand-resolved
conflict or an edit amended into a merge fails it. There is deliberately no range-diff rung:
`git range-diff` pairs a mode change and a file-to-symlink swap as `=`.

A proof rebinds exactly as a patch-id match does. The log reads `own commits unchanged
(<how>, …)` in place of `patch-id … unchanged`. Anything it cannot prove falls through to the
overlap rebind and then to the paid re-review. `bin/review-prs.sh` and
`bin/review-autopilot.sh` replay their own verdict through the same lib: no agent call, no
GitHub post, and a lead or human CHANGES_REQUESTED still stands (`bg_cr_standing`, BH-2199).

**`HEAD_MOVED` → no review at all, when nothing that landed is a file this PR touches (the
merge funnel, W2-D, 2026-09-14).** The patch-id rebind above is the strong test and it runs
first; this is the second chance, on exactly the heads it could not vouch for — a reviewed
sha the remote no longer has, a stored id that never got written, context lines that shifted
under a merge. The question is the funnel's other half: the head moved because MAIN moved,
so did main move anything this PR is about? `mc_no_overlap` answers it from git and from the
PR's own file list, and rebinds only when all three of these hold:

1. **the merge base actually moved.** `B1 = merge-base(origin/main, reviewed)`,
   `B2 = merge-base(origin/main, head)`. `B1 == B2` means the head did not move because main
   did, and this test has nothing to say about it — rc 1, today's re-review.
2. **every file that differs between the reviewed sha and the head is a file MAIN changed
   between `B1` and `B2`.** That is what tells "a merge landed underneath me" from "somebody
   pushed a commit": a new commit touches something main did not, and falls out here.
3. **the PR's own file list is disjoint from the files main changed.** The list is
   `gh pr view --json files`, CACHED per (PR, head) under `state/merge-conductor/pr-files/`
   — a head's file list cannot change without the head changing, and at 4000 PRs a day the
   same list would otherwise be bought on every five-minute tick. Files older than three
   days are swept by `mc_pr_files_gc` at the end of the tick.

All three: `NO_OVERLAP rebound` — `reviewed-sha`, `job_verdict_rebind`, a line in
`<record>/rebind.log`, one log line naming what landed — and NO re-review, exactly the
consequence and exactly the principle of the patch-id rebind next door: an approval binds to
CODE, and no code a reviewer read has moved. Any doubt at all — an unreadable file list, a
sha the remote no longer has, a base that did not move — is rc 1 and today's detached
re-review, unchanged.

**Why the main-side list is computed from two merge-bases and not from `gh pr view --json
files` of the merged PR.** Merges into main arrive from four places — this conductor, the
hub's merge sweep, a Mergify batch, and the operator from the console — so a bookkeeping table of
"what we merged" would be missing exactly the merges we did not make, and a missing merge
would read as no merge at all and rebind an approval it should not. Two merge-bases and a
diff ask the same question of the only witness that sees every merge. Kill flag:
**`MC_OVERLAP_REREVIEW=0`** — the arm is removed and every moved head the patch-id rebind
missed buys the re-review, byte-for-byte as before.

**`HEAD_MOVED` → the conductor's own read BEFORE any park, even when the build's gate
already refused the head (2026-09-16, the operator's project-5 acceleration, lever 2).** A moved
head that neither rebind could vouch for used to have two fates, decided by who had already
spoken. With no head-bound word it was `HEAD_MOVED` and bought the detached Claude
re-review above. With `blocked@<this head>` — `bin/run-build.sh`'s own head-bound gate,
`HB_OUTCOME`, running on whatever runner that build's survival ladder reached —
`mc_classify` answered `BLOCKED_HUMAN reason=head-not-reapproved` on sight and
`bin/blocked-resolver.sh` owed it a **full agent fix round**: 61 of those on project-5 on
2026-09-16 alone, every one of them a lane, a branch and a park bought to settle a question
one detached read settles in minutes.

Both fates are one now. `blocked@<this head>` keeps the row in `HEAD_MOVED`, the arm buys
the head-bound Claude re-review through the same budget, daily cap, CI-green debounce and
one-read-per-(PR, head) rule as every other moved head, and the PR waits there — the tick
itself waits for nothing — until **our own** verdict lands:

| our read says | what happens |
| --- | --- |
| `APPROVE` | `reviewed-sha` and the ledger verdict are rebound to this head, the review is posted on the PR, the row goes `WAIT_REVIEW` and the next tick classifies it `READY`. No fix round, no park |
| `BLOCK` | **now** the `BLOCKED_HUMAN reason=head-not-reapproved` hand-off, findings posted on the PR, byte-for-byte as it reads today. The refusal is recorded as `hbrefused <key> <head>` in `MC_ATTEMPTS` (`mc_hb_refuse`) and handed back to `mc_classify` as `MC_HB_REFUSED=1`, so every later tick of that head agrees and the row cannot oscillate between the park and another read. A PUSH is a new head, which is unread code again and buys its own read, exactly as before |
| nothing (`failed`/`stale`) | a **lane** failure, not a verdict: the job file is forgotten and ONE more read is bought (`rereview_lane_retry`), and only a second dead job takes today's `no-verdict` park. Both are EVENTS — a job that is not coming back, then a second one — never an elapsed-time rule, which may never close or abandon a PR here (the operator, 2026-09-16) |

Kill flag: **`MC_REREVIEW_ON_MOVE=0`** — `blocked@<this head>` parks immediately again and
the lane-failure retry is gone, byte-for-byte as before. **A `DIRTY`/`CONFLICTING` head
parks on sight whatever the knob says**, because GitHub runs no workflow on a head that
cannot merge, so the CI-green debounce would defer that read for ever (BH-491) — a PR that
can be neither read nor parked is the silent strand this file exists to prevent. The
`provenance` path is untouched: its hold has its own auto-resolve window and its own alert,
and a read bought from the lane-failure retry would move when that window says
"auto-resolving, not paged".

**`READY` → merge.** Re-read `gh pr view` immediately before acting (the double-merge rule
with humans: the tick's own read may be minutes old), confirm the head is still the bound
sha, then `gh pr merge <url> --squash --match-head-commit <sha>` (squash is the only method
project-5's and project-2's rulesets allow; the others allow all three). Then, in this
order and each fail-open: `sweep_record`-equivalent `job_ledger_put merge <url> merged` so
the sweep never re-touches it; `job_artifact_put merge_sha` on the BUILD's job (the sweep's
phase-7 line); #262's issue close (`# >>> issue close after merge` block: comment +
`gh issue close` for board-prefix `-` projects, number from the build KEY, the branch's
digits as the fallback when no record names the PR — `mc_issue_of`); `deploy-request.sh`
via the fleet.conf project match; the `tier2_sweep_merged`-shaped beat (`stage:
conductor_merged`). Merge fails → stays `READY`, second failure → `BLOCKED_HUMAN
reason=merge-failed-twice` with gh's stderr line. That whole block is the lib function
`mc_settle_merged` — see the next paragraph for why it had to become one.

**`READY` → enqueue, on a repo with a merge queue.** `mc_queue_provider <slug>` (cached per
slug for one tick under `tmp/`, fail-closed to `none` on any API error) answers `github`,
`mergify` or `none` — the full table and the why are in section 6. **The repo capability is
the switch — there is no flag**, because what changes is what a merge call DOES. `mc_enqueue`
dispatches on the provider: under `github` it sends `gh pr merge --squash
--match-head-commit` (which enqueues and exits 0, leaving the PR `OPEN` with a null
`mergeCommit.oid`); under `mergify` it adds the `merge-queue` label and then waits for a
Mergify check run to acknowledge it. Either way the ANSWER is read apart: queued →
`QUEUED`; `MERGED` (a one-entry queue can land inside the tick) → settle at once; neither →
the existing two-strike path.

The consequences of a landing then belong to a LATER tick, which is why they are now
`mc_settle_merged`: a PR merged out of a queue disappears from the open list (it is merged)
and from the closed list (which selects `mergedAt == null`), so without a pass over the
`QUEUED` rows nothing would ever close its issue or hand its sha to the deploy train —
production would wait for `deploy-train.sh`'s 20-minute self-source floor on every merge.
That pass runs per repo BEFORE the open pass and reads each queued PR once: `MERGED` →
settle, `CLOSED` → `CLOSED`, `OPEN` and no longer in the queue → **ejected**. Ejections are
recorded per (PR, head) in `MC_ATTEMPTS`; one is `WAIT_CI reason=queue-ejected` (the
`merge_group` build tested `main` + the entries ahead + this PR and went red — a CI fact
about a tree the PR's own checks never saw), two is `BLOCKED_HUMAN
reason=queue-ejected-twice`. The classifier is overridden out of `READY` while that head
carries a LIVE ejection mark, which is what stops the re-enqueue-forever loop.

**An ejected head goes back in ONCE, on Mergify, when the PR was not the problem (BH-636).**
Until then "never re-enqueued" was the whole rule, and it is right for a head whose batch
build genuinely failed — but Mergify ejects the CULPRIT OF A BATCH, and a batch goes red for
a sibling's flake or a killed runner as readily as for this diff. Those PRs sat in `WAIT_CI
reason=queue-ejected` with every required check green at their own head, an approval bound to
that exact sha and a clean merge state, waiting for a push that was never coming: nothing in
the harness pushes to a finished PR. The re-entry arm runs in the open pass (no extra list
call) for a `READY` PR on a `mergify` repo whose head carries a live ejection mark **or**
Mergify's own `dequeued` label, and every clause is a guard:

| guard | why |
|---|---|
| `READY` | it already means APPROVE bound to THIS head and `mc_ci_state green` at THIS head, read from `actions/runs?head_sha=<full sha>` — never the PR's `statusCheckRollup`. `MERGEABLE` is then re-asserted by name, and the merge state through `fr_reentry_gate` (`CLEAN`, or `UNSTABLE` with Mergify's own check runs excluded, BH-3776), so a future reordering of `mc_classify` cannot become a requeue over a red or unreviewed head |
| attribution (BH-3776) | the newest dequeued Mergify comment bound to THIS head names the draft and failing runs; a failing suite that touches the PR's files (or, for cromford, its test-impact map) is `own` and is never re-queued, whatever a later batch did; `foreign` (nothing touched, and every name an untouched path or passed by a later batch on the same main) re-queues once with one `REQUEUE_ATTRIBUTED` line and one PR comment per (PR, head). Any failing run whose path, base or head cannot be read, or whose log cannot be read in full (the read fails, comes back empty, is over `FLAKY_LOG_MAX`, or names more than `FLAKY_TESTS_MAX` tests), makes the verdict `unreadable` (fail closed), and so does a failed test-impact `select`; the jobs API's `job:` names stand in only for a log that was read and named no test, and a verdict holding one, or a runner test title (by provenance: anything but a harness `--- tests/<x>.sh` line or a `FAIL <file>` token, whatever it looks like), is never lifted by a later batch (touch cannot be checked on it): it stays `unknown`. Where the test-impact map cannot be built (no tests/ under `MC_H`, as on the hub) the verdict is `nomap`: BH-636 exactly, raw `CLEAN` only, one `FOREIGN_RED_NOMAP` line per head. `unreadable` never re-queues, raw `CLEAN` included. An `always`/`full` suite is never untouched and never ledgered. A cached `unknown` is re-judged each tick on the one later-batch read. **Outside cromford, "touches" is file overlap only**: the test-impact map covers the harness's own repo, so a product PR is `own` only when the failing test file is in its diff |
| once per (PR, sha) | `requeued <key> <head> <epoch>` in `MC_ATTEMPTS`, written BEFORE the label write. A head already carrying the mark WAITS (`WAIT_CI reason=requeued on <sha8>, waiting for Mergify to acknowledge`) — and that is also what keeps it out of the `READY` arm's queue ask (which since BH-2199 never falls back to a direct merge). **This sweep never merges.** |
| two ejections | ejected AGAIN after a requeue is `reejected <key> <head>`, counted with the first, so the row goes `BLOCKED_HUMAN reason=queue-ejected-twice` and `bin/blocked-resolver.sh` owns it. A genuinely broken PR cannot loop |
| red head | never re-queued. It is NAMED once instead — `DEQUEUED_RED <key> <sha>` in the log, mark `dequeuedred` — so a reader can tell "left alone on purpose" from "nothing looked at it". The red ladder owns it |
| `MC_REQUEUE_CAP` | default 5 re-queues per project per tick, taken from the same per-tick budget file as the rebase and re-review caps. Over the cap the row logs `REQUEUE_DEFERRED` and keeps its `queue-ejected` reason — re-offered next tick, never dropped |
| observe mode | logs `would REQUEUE <key> <sha> (merge mode off)` and writes nothing |

The write itself is `mc_requeue_mergify`: `DELETE …/labels/dequeued` (a 404 is the label
already gone and is fine; any other refusal is rc 1, no label add, no comment, and the row
keeps its ejection), then `mc_enqueue_mergify` with `@mergifyio requeue`
(`MC_MERGIFY_REQUEUE_CMD`) instead of `@mergifyio queue` — Mergify keeps a dequeued PR out of
the queue on the same head until it is re-embarked, so the label alone would be a no-op. Its
return codes pass straight through: witnessed → `QUEUED` + one log line `REQUEUED <key>
<sha>`; merged meanwhile → `QUEUED` and the next settle pass lands it; label on but nothing
acknowledged → `WAIT_CI reason=requeued on <sha8>, awaiting Mergify's witness` +
`REQUEUE_UNWITNESSED`; refused → the `queue-ejected` reason kept + `REQUEUE_FAILED`.
`MC_QUEUE_REENTRY=0` removes the arm and restores "never re-enqueued" exactly.

`mc_settle_merged` is safe to run twice, because under a queue it can be. Every write in it
is idempotent except `deploy-request.sh`, which appends a timestamped file to the deploy
queue — two settles would depart two trains — so it is guarded by an `MC_ATTEMPTS` line
(`deployreq <key> <merge-sha>`), the shape `mc_attempted` already uses. A landing seen while
the merge flag is OFF records the row and **pages**, rather than silently skipping the issue
close and the deploy.

**THE DEPLOY VERIFIER IS A LANE, NOT A CHILD OF THE TICK (2026-09-14).** `mc_settle_merged`
runs with a conductor lock held (the project's until 2026-09-15, the PR's since), and the `deploy-request.sh` it calls spawns
`bin/deploy-verify.sh` for any project without a `VERSION_URL` — a poll of up to 20 minutes.
A child spawned from inside the tick inherits fd 9 and therefore HOLDS THAT LOCK for its
whole life: on 2026-09-14 a verifier spawned at 03:54Z held project-5's lock until 04:02Z,
and every tick in between logged "an earlier conductor tick still holds this project's lock"
and skipped the project. #310 closed the fd at that one spawn site; the verifier is now a
lane like the other two, with its own state dir
(`state/merge-conductor/deploy-verify/<project>_<merge-sha>.json`), its own result file and
its own fd hygiene. `mc_dv_run` calls `deploy-request.sh` with `MC_DV_INLINE=1`, which runs
the verifier in the FOREGROUND of the lane job so its exit code IS the lane's result — the
"train or verifier" routing stays in that one script. The tick only READS: `mc_dv_reap` runs
at the very bottom of `bin/merge-conductor.sh`, after every project tick has released its
lock, logs one line per finished job (once per (project, sha), through `MC_ATTEMPTS` like
everything else), and raises ONE alert for a verifier that never came back — a merged sha
nobody is watching is exactly the thing that must not wait silently. There is no parallel
cap: a verifier is a poll, not a build, and capping it would mean a deploy nobody checked.
**Kill flag: `MC_DETACHED_DEPLOY_VERIFY=0`** calls `deploy-request.sh` from the tick as
before. Default on.

`bin/pre-arm-guards.sh` is **skipped on a queue repo** at both call sites (here and
`bin/merge-sweep.sh`): the queue's own `merge_group` run asks the same question — this PR
merged into current main — with the answer binding, while pre-arm costs a
`workflow_dispatch` plus a poll of up to 1800s and has an rc-3 "main moved since" path that
is structurally unsatisfiable in a busy repo. The script is untouched for repos without the
rule.

**A red that is a KNOWN FLAKE buys one rerun instead of a strike** (2026-09-12,
`docs/FLAKY-TESTS.md`). Before the red on a head is recorded in `MC_ATTEMPTS`, `mc_flake_rerun`
asks whether EVERY failing test on that head is already in the `ci_flakes` ledger as a flake on
at least `FLAKY_MIN` other heads — a flake being a head where the same workflow concluded both
failure and success, same tree, no push between. If so it dispatches one `gh run rerun --failed`
per `(PR, head)`, guarded on `MC_ATTEMPTS` exactly like the rebase and the re-review, and the
tick records **no** red strike. One unknown failure alongside a known flake, a red whose failing
tests could not be read at all, or observe-only mode all fall back to today's behaviour: the red
counts. The second red on the same head is a real red and takes its strike, so the red-twice
budget above is unchanged — this buys a retry, never forgiveness.

**`BLOCKED_HUMAN`** → no action BY THE CONDUCTOR. For a reason `mc_resolver_owns` answers yes
to, the conductor logs and does not page: `bin/blocked-resolver.sh` owns it (section 11) and
alerts exactly once, on `ABANDONED`. For every other reason — `migration-gated`,
`verdict-contradiction`, `provenance`, `tightened`, `hotfix-migration-hold` — the old behaviour is unchanged: alert
immediately, then one reminder per UTC day. A `verdict-contradiction` parks only when it is
about the CURRENT head, and its reason quotes both verdicts; one about an older head is
`HEAD_MOVED` and buys the head-bound re-review, whose verdict then stands (BH-4585).
Anything that clears the cause (a push, a
re-review comment, a flag) is seen as a new head or new verdict on the next tick and the PR
leaves the state by the ordinary classifier.

#### A hand-off to the resolver is STICKY (2026-09-14)

The eight parks whose log line says *"handed to `bin/blocked-resolver.sh`"* —
`conflict-unresolvable`, `rebase-gate-red`, `queue-ejected-twice`, `merge-failed-twice`,
`queue-enqueue-failed-twice`, `no-verdict`, `head-not-reapproved`, and (2026-09-16)
`orphaned-child` (`mc_handoff_owns`) — do not
get re-classified on the next tick. While the hand-off is open the tick reads the row, logs at
most one line, and moves to the next PR: **no `merge-tree` test, no rebase spawn, no
re-review, no merge, and no transition at all.**

The reason is project-5 #759. At 16:29Z it went `NEEDS_REBASE -> REBASING`, the detached
rebase came back rc 1, and at 16:30:30Z the tick wrote
`REBASING -> BLOCKED_HUMAN reason=conflict-unresolvable: tests/static-guards.txt` beside
`BLOCKED_AGENT … handed to bin/blocked-resolver.sh (its ladder: merge main / re-run CI, then an
agent fix round on the branch, then a fresh rebuild)` — section 12 for the rungs.
**Twenty-two seconds later** the next tick's DIRTY branch wrote
`BLOCKED_HUMAN -> NEEDS_REBASE reason=mergeState DIRTY`. `br_from_conductor` selects rows whose
state IS `BLOCKED_HUMAN`, so the hand-off became invisible to the only lane that could move the
PR: 25 ticks over the next 45 minutes logged `MERGE_TREE conflict on 382730a5 … GitHub is
right, rebasing` and nothing else — the rebase was capped, the resolver never picked it up, and
the one-alert-per-PR-per-state rule had already fired. #749 (16:48:07Z → `WAIT_CI reason=checks
none` at 16:50:26Z) and project-7#438 (11:37Z → `HEAD_MOVED` at 11:39:56Z) are the same shape. At
wave scale — 35 decomposed project-5 children in one afternoon, siblings conflicting on shared
files — this parks a growing share of approved PRs with nothing saying so.

The park ends when something REAL changes, never on a tick:

| Release | How the conductor sees it |
|---|---|
| the PR head moved (a resolver fix round, a rebase by hand) | the head in `state/merge-conductor/handoff/<owner>_<repo>_<num>` no longer matches the PR's `headRefOid` |
| the PR merged or closed | it leaves the open list; the closed pass settles the row to `CLOSED`, a merge settles it to `MERGED` |
| the resolver took the PR | `bin/blocked-resolver.sh` writes `state/merge-conductor/handoff-released/<owner>_<repo>_<num>` (`mc_handoff_release`) once a rung has run |
| **a person applied the `conductor-release` label** (BH-292) | the label is in the PR's `labels` field of the list read the tick already makes (`mc_handoff_human_release`); the park ends ONCE per (PR, head), recorded in `state/merge-conductor/handoff-human/<owner>_<repo>_<num>_<head12>`, and in actions mode the label is taken back off the PR |

The hand-off file is written by `mc_transition` itself, so every one of the seven park sites
records it without a seventh copy of the rule; a NEW park clears any stale release marker, so a
PR the resolver released and the conductor re-parked is sticky again. What an operator sees is
one `PARKED …m in BLOCKED_AGENT (<reason>) … bin/blocked-resolver.sh owns it` line per hand-off,
repeated at most once per `MC_STICKY_LOG_SECS` (default 3600s = 12 ticks), then silence until
the park is released. `MC_STICKY_HANDOFF=0` restores the re-classify-every-tick behaviour
exactly.

**The label, in full (BH-292).** A person who has looked at a parked PR and wants the lane to
carry on puts `MC_RELEASE_LABEL` (default `conductor-release`) on the PR. The next tick logs
`RELEASED by the conductor-release label on <head>`, forgets that head's rebase and merge-tree
attempts — without which the released row lands in `NEEDS_REBASE` where `mc_attempted` refuses a
second rebase of the same head, and the label would visibly do nothing — classifies the PR like
any un-parked one, and in actions mode removes the label. A removal that FAILS is one log line
naming the by-hand command, not a silent retry. It works **once per (PR, head)**: re-applying it
after a fresh park on the same head does nothing and the `PARKED` line says
`the conductor-release label was already used on this head`, because a label that is never
removed (observe mode, a failed removal) would otherwise release every re-park on that head and
rebuild the exact oscillation this section exists to stop. A new head honours it again. Observe
mode releases the park locally and leaves the label alone — classifying a row is not a GitHub
write. `MC_RELEASE_LABEL=` (empty) turns the whole path off. **Operator step:** the label has to
exist in each project repo — `gh label create conductor-release -R <owner/repo>` — exactly like
the hotfix label; nothing here creates it.

**The conflict park names the next move, and it is an agent's.** `conflict-unresolvable` has three
surfaces: the hand-off line, the `PARKED` line and the stuck detector's "waiting on" text (which
feeds the ALERTS line). Each ends with `next step: an agent fix round (bin/blocked-resolver.sh)
merges main into this branch and resolves the conflict, or re-plans the ticket with the
conflicting files in scope; no person rebases`, beside the conflicting files `git merge-tree` named
(`mc_park_human_action`). Every other reason's lines are byte-for-byte what they were. Until
BH-5967 the text asked for a human rebase; there are no human reviews (the operator, 2026-10-10).

**A stacked child whose parent merged is merged, not parked (BH-5967).** When the replay
`rebase --onto main` conflicts, `mc_stack_follow` merges main INTO the child (`mc_rebase`) and
pushes. The push re-runs CI. When the merge-main rule does not rebind the approval, the
moved-head path re-requests the review. Only a merge that still conflicts, or a red gate, parks
`conflict-unresolvable` for the resolver's fix round.

**Parks that need a person are untouched**: `iron-law` and `red-ci-twice` are
re-derived from the diff and from CI every tick and must stay able to clear on their own, and
`migration-gated`, `verdict-contradiction`, `provenance` and `tightened` page exactly as before.

**A KILLED RUNNER IS NOT A CODE FAILURE (the flake ladder, BH-636).** `cancelled` stopped
being a verdict in 2026-09-14 (project-5 #586); `timed_out` did not, and it is the same fact
told differently — a runner that ran out of its limit, or was OOM-killed (GitHub reports that
as a timeout), says nothing whatever about the diff. It cost a red strike, then the red
ladder's one rerun, then `RED_TWICE`, which buys a fresh rebuild of a ticket that was never
broken. So `mc_ci_state` drops `timed_out` with `cancelled`/`skipped`/`neutral`, and
`completed|failure` is the only conclusion left that answers `red`.

Dropping it alone would leave those heads sitting in `checks none` waiting for a run nobody
is going to start, so the tick reads `mc_ci_flake_runs` — the SAME endpoint and the same
latest-per-workflow reduction, naming the runs that died as `<id>|<name>` — in exactly two
shapes, and never on a DIRTY/CONFLICTING head:

* `ci=none` — every run we can see was cancelled or timed out;
* `ci=green` + `mergeStateStatus BLOCKED|UNSTABLE` — every run we can SEE passed, but a
  required context is not green, i.e. the run that would have reported it was the one killed.

It is a side read and NOT a fifth `mc_ci_state` word, because half the fleet compares that
answer with `= green` / `= none` and #586 pinned both. The ladder then uses the red ladder's
own `cirerun` mark, so a head gets ONE rerun whoever buys it: rung 0 dispatches
`mc_flake_kick` — a FULL `gh run rerun <id>`, not `--failed`, because a cancelled run may have
no failed job to name — and logs `CI_FLAKE_RERUN <key> <sha> (<n> run(s): <names>)`; rung 1
says the rerun is in flight; rung 2 is **not** `RED_TWICE` (rebuilding a ticket because a
runner was OOM-killed twice is the waste this exists to stop) but ONE ALERTS line
`CI_FLAKE_TWICE`, once per (PR, head) on the `flakealert` mark, with the row left in
`WAIT_CI`. No red strike is written on this path, ever, and the catch-all CI kick stands down
on a flaky head so it is re-run rather than also close/reopened.

**`WAIT_CI` on a RED head → one rerun, then the resolver (the red ladder, 2026-09-15).**
`mc_red_rerun` dispatches `gh run rerun --failed` for every failed run on the head, once per
`(PR, head)`, recorded in `MC_ATTEMPTS` as `cirerun <key> <head> <epoch>`. Actions mode only —
it is a GitHub write, so observe-only counts a red exactly as it did before. The epoch is what
`mc_red_rung` ages against: inside `MC_RED_RERUN_SETTLE_SECS` (300s, one tick) the red the tick
is looking at is the SAME red, because the rerun has not flipped the run yet; past it, red on
that head is the second red and the row goes `RED_TWICE`. The flake path (`mc_flake_rerun`,
docs/FLAKY-TESTS.md) runs FIRST and is unchanged — it is the one that can skip the red strike —
and both share the one mark, so a head gets one rerun whichever bought it. A tree with no
`bin/lib/flaky.sh` cannot name the failed runs *at all*: it logs that, records the mark anyway,
and the next red is `RED_TWICE`, because a rung that cannot act must still have an owner. A
read that comes back EMPTY is the opposite case and does **not** spend the rung — `mc_ci_state`
has just said `red` off the same `actions/runs` endpoint, so an empty answer is the API
refusing us, and putting the PR one tick from a fresh rebuild of the ticket on the strength of
one flaky GET is not a trade worth making. The rung stays 0, the next tick asks again, and a
red that is permanently unreadable is caught by the `WAIT_CI` TTL, which alerts rather than
spends.

**`RED_TWICE`** → no action BY THE CONDUCTOR, and one hand-off line
(`<key> RED_TWICE red-twice: … — handed to bin/blocked-resolver.sh …: <url>`) the moment the
row enters the state, in the shape `br_handoff_lines` reads. The resolver's row source accepts
the state and `br_action` answers `ladder` — `ci-red` class, so the rungs are merge main /
re-run the failed jobs, then an agent fix round briefed with that job's log, then a fresh
rebuild (section 12).

**`ABANDONED`** → no action, ever. Terminal.

### A retarget fires no CI, so the conductor kicks it (2026-09-15)

**project-5 #913, #943, #1011, #1020, #1021.** Each was a stacked child that got retargeted to
`main` when its parent merged — by `mc_retarget_base` above, or by GitHub itself when the
parent's branch was deleted. A `pull_request` workflow's DEFAULT activity types are
`opened | synchronize | reopened`; a base change is `edited`, and nothing about it touches the
head. So every one of those PRs kept exactly the runs its head already had, which for a branch
cut from a feature branch is **none**: `mc_ci_state` answered `none`, `mc_classify` parked the
row at `WAIT_CI reason=checks none`, the required check ("Build + Unit tests" on project-5's
main ruleset) never reported, the merge-queue label was never added, and the PR never merged.
All five carried a `base_ref_changed` timeline event by `cromford[bot]` and zero runs on
their head, while sibling PRs opened straight against `main` merged within the hour. Closing
and reopening each one fired CI immediately and unstuck it. The conductor does that now, in
two layers:

| Layer | Where | When |
|---|---|---|
| fast path | the `MERGED` arm of the stacked-child block, right after `mc_retarget_base` returns 0 | every retarget the conductor makes itself. Logs `… retargeted to <base> and CI kicked (close/reopen)`. A kick that FAILS does not undo the retarget: it is logged and layer 2 picks the PR up on a later tick |
| catch-all | after `mc_classify`, before the transition is written | any PR that would classify `WAIT_CI` / `checks none`, whose `mergeable` is `MERGEABLE`, whose base IS the project base, and whose row has been in `WAIT_CI` for at least `MC_CI_KICK_MIN_AGE` (default 600s). This is what covers GitHub's own auto-retarget, and anything else that leaves a head with no run |

`mc_kick_ci <owner/repo> <num>` is the mechanism: `gh api -X PATCH repos/O/R/pulls/N -f
state=closed` then `-f state=open`, the REST pair and not `gh pr close/reopen`, for the reason
`mc_retarget_base` is REST — gh's high-level edit commands have reported success and changed
nothing on this exact object before. **The close is never left standing**: a failed reopen is
retried `MC_KICK_REOPEN_TRIES` times (default 3, clamped to at least 1, `MC_KICK_REOPEN_SLEEP`
seconds apart) and a PR still closed after the last attempt is logged **and alerted
`--critical`** as `<key> LEFT CLOSED — … REOPEN IT BY HAND` with the exact command. It pages
rather than only logging because nothing in the fleet reads `merge-conductor.log` for that
line, and because the conductor's own closed-unmerged pass would otherwise tell the reader on
the next tick to "rebuild or close the issue" — buying a duplicate PR for a change that is one
reopen away. `mc_kick_ci` returns 0 only when the PR is open again; a close that was REFUSED
changes nothing and returns nonzero without attempting a reopen.

**A kick is for a head with NO run, on both layers.** Not every repo leaves a stacked child
unbuilt: project-2 (`migration-sql-gate.yml`, `verification-map-freshness.yml`) and project-4
(`typecheck.yml`) trigger on a bare `pull_request`, so their children already have runs on the
head when the parent merges. Closing and reopening one of those cancels whatever is in flight
through the repo's own `cancel-in-progress` concurrency group and buys a duplicate build, so
the fast path asks `mc_ci_state` (already read this iteration) and kicks only on `none` —
which is the same condition the catch-all's `checks none` reason is. Note `none` also covers a
head whose every run was CANCELLED; a kick is the right answer there too.

**And a closed PR is not an outcome until it has settled.** The kick makes the PR CLOSED for
the width of one REST call. `pr_worker` holds `locks/merge-conductor-<project>-<pr>.lock`
across the pair, so no other conductor worker can see the gap — but two lanes on the same box read the
same PRs on the same `*/10` cron and take no such lock: `bin/reconcile-prs.sh` clears the
build's console row on `state == CLOSED` (permanently), and `bin/merge-sweep.sh` writes
`sweep_record <pr> closed`, which `sweep_seen` then reads as terminal for ever. Either one
landing inside the window retires a PR that is about to be open again. So both now ask
`mc_closed_settled <closed_at>` first: a closure younger than **`MC_CLOSED_SETTLE`** (default
180s) is skipped with a log line and re-read on the next pass, by which time the PR is either
genuinely closed or open again. It fails OPEN in every ambiguous case — no `closedAt`, an unparseable one, a window of 0 — so it can never park a real closure for ever.

GitHub API reads are also rate-limit budgeted. `bin/lib/gh-budget.sh` is sourced in `bin/merge-conductor.sh`; when `gh_budget_low merge-conductor` returns budget low, the closed-unmerged settle pass is skipped for that tick while the merge-queue settle pass and the open-PR pass continue. The low signal resolves against `setting_get gh_budget_min_remaining`, then `GH_BUDGET_MIN_REMAINING`, default 800.

**Three guards, and each one is load-bearing.** `ci=none` is the NORMAL state of a
`CONFLICTING` PR — GitHub runs no workflow on a tree it cannot merge, which is the whole point
of the DIRTY clause in section 3 — so a conflicted head is never kicked. A PR still based on a
feature branch is `STACKED_WAIT` and belongs to the block above, not to this one. And below ten
minutes, a head with no run is a run that has not APPEARED yet, not one that is never coming.
The kick is recorded as `cikick <key> <head>` in `state/merge-conductor/attempts.txt`, beside
`rebase`, `red`, `cirerun`, `ejected` and (BH-636) `requeued <key> <head> <epoch>`,
`reejected`, `dequeuedred`, `flakealert` and `cikickalert` — every once-per-(PR, head)
decision in this lane is an exact line in that append-only file, so a retried tick re-reads
them and does nothing twice. A second tick over the same head never closes the PR again; a
push produces a new head, which gets its own CI from `synchronize` and needs no kick at all.
Both layers are `ACTIONS`-only, like every other gh write in this lane: an observe-only tick
logs `would kick CI on <head8> …` and writes nothing.

**Layer 3: the re-review path, and the silence after the kick (BH-636).** The two layers above
only ever fired for a row that classified `WAIT_CI checks none`. A head that MOVED takes a
different path — `headbound_review` — whose re-review is debounced on CI going green, and a
head GitHub never built never goes green, so `re-review deferred — CI none` was the whole of
what #1827 and #1645 got, every five minutes, for ever. That deferral now tells the three
silences apart by name and acts on each:

| word | what it is | what happens |
|---|---|---|
| `CI pending` | a run is in flight | wait (byte for byte the line it always was — kicking it would CANCEL the run through the repo's concurrency group) |
| `ci=flake` | the latest runs were cancelled/timed_out | **rung 0/1**: nothing here — the flake ladder above re-runs them once, on the shared `cirerun` mark, and this line is byte for byte what it was. **Rung 2 (BH-764)**: the one rerun ended cancelled/timed_out too, the ladder is spent and `CI_FLAKE_TWICE` has already alerted — so the read is bought WITHOUT CI rather than deferred for ever. Recorded once per (PR, head) as `rrnoci` BEFORE the spawn (a spawn refused by the cap, the budget or a running job keeps the record and retries only the spawn), logged once, and every verdict comment on that head carries `mc_rr_noci_why`'s *Judged WITHOUT CI* footer. **Nothing merges on it**: the row reaches `WAIT_REVIEW` and `READY` still requires green. No second rerun and no second rerun ledger — the ladder stays BH-636's |
| `ci=absent` | no run on this head at all | `ci_absent_kick` — the same `mc_kick_ci` close/reopen, the same guards (not DIRTY, row at least `MC_CI_KICK_MIN_AGE` old, once per head on the `cikick` mark, actions only), logged `CI_KICKED <key> <sha>`. The base guard is not repeated: a PR not on the project base classifies `STACKED_WAIT` ahead of the drift branch, so a `HEAD_MOVED` row is on the project base by construction |

And a kick that did not work now has an owner. A head still run-less at **twice**
`MC_CI_KICK_MIN_AGE` after its one kick is a workflow that is never going to fire for it — a
`pull_request` branches filter that does not match this base, a workflow file that does not
exist on it — and no amount of waiting fixes that, so `ci_absent_escalate` writes ONE
`CI_ABSENT_TWICE` ALERTS line naming both things to check, once per (PR, head) on the
`cikickalert` mark (written BEFORE the send, so a failed send costs one alert and not a
storm), and then goes quiet again. Both the re-review path and the WAIT_CI catch-all escalate
through it: #1827/#1645 sat in `HEAD_MOVED`, but #913-#1021's shape sits in `WAIT_CI`, and it
is the same silence.

### A reviewed, green tier-2 PR enqueues itself on a Mergify repo (BH-1668, 2026-09-23)

After every PR worker of a project has answered, `ae_project` (`bin/lib/autoenqueue.sh`)
walks the rows the tick already listed. It acts only on a row whose worker reached the READY
arm's enqueue point THIS tick and marked that head (`ae_mark <project> ready`, a file under
`MC_TICK_DIR` keyed by `MC_TICK_ID`). That point is past every conductor hold: the classifier's
provenance, iron-law, tightened, pre-arm and red-twice parks, the unread-diff refusal, the
main-red freeze and the PR-dependency gate. `@mergifyio queue` is a merge on a Mergify repo, so
the step never re-decides on a smaller set of gates. A worker whose own enqueue was witnessed
(or that landed the PR) marks `asked`, and the step leaves that row alone. On a `mergify` repo,
a marked row gets ONE `@mergifyio queue` comment per (PR, head) when all of these hold: not a draft, not `train/*`, not already
`queued`/`isInMergeQueue`, based on the project base, no `MC_AUTOENQUEUE_HOLD_LABELS` label;
no `autoenqueue` ledger row for `<url>@<head>` (worker down and no line in
`state/tier2-autoenqueue.txt` = skip the tick); an APPROVE bound to THIS head or a standing
MERGE/MERGE-WITH-NOTES on it, and no other standing word; every required check completed/success
on the head (latest run) — `MC_AUTOENQUEUE_CHECK` when an operator set it, otherwise the
`check-success` names in the repo's own `.mergify.yml` (Lane D, `docs/notes/2026-09-24-LANE-D-merge-flow-enqueue.md`,
which also moved the Mergify enqueue out of the project merge lock and added the keyed wake); a REST re-read saying open, same head, same base and
`mergeable_state` exactly `clean`; and the lead fence, ticket hold, a `HOLD` on the PR itself (bin/lib/hold.sh hold_check_thread: a comment LINE starting `HOLD`/`HOLD:` holds and one starting `RESUME`/`UNHOLD` lifts, newest human instruction wins, mid-line prose is neither, an unreadable thread refuses), main-red freeze, block gate
and hotfix migration proof all clear. Under `automerge-disabled`, `paused-<project>`, any
MODE but `merge` or the conductor's merge switch off (`MERGES=0`) it writes one `WOULD enqueue` line per (PR, head) and nothing else.

The comment goes out under a PAT (`gh_repo_use_pat`: the default PAT, then the admin PAT, never
the App token, which Mergify refuses). The ledger row is `posting` before the POST and `enqueued`
after the 201 (`enqueued_at`, `enqueued_head`, `comment_id`); when the verdict names a job, the
build row gets an `enqueued` artifact. A crash leaves `posting`, and the next tick reads the thread before it re-sends.
A failed POST is recorded `failed-<n>` and retried up to 3 times per head, then alerts. No PAT sees the repo: the row is
`not-configured`, with one ALERTS line per repo per day. It never merges, labels or pushes;
Mergify's queue conditions stay the gate, and ejection/re-entry stay as above. A new head is a new
key. Rationale and incident: `docs/notes/2026-09-23-BH-1668-tier2-autoenqueue.md`.

## 5. Age budgets and alerts

One alert per (PR, state) — the row's `alerted` field holds `<STATE>@<since>`, so a PR
that re-enters a state after leaving it can page again, and a PR sitting in one state pages
once. Alerts go through `bin/lane-alert.sh` (#262; ALERTS.log line + `fleet_alert`
beat, `--critical` DMs when the monitor is off) and fall back to `beat.sh` + ALERTS.log when
that file is absent. akey `conductor:<slug>#<n>:<STATE>`. Every line names the PR URL and
the state.

| State | Budget | Alert line (what a reader can do) |
|---|---|---|
| `WAIT_CI` | 30m | "checks pending/red on <head8> for Nm — <run url>" |
| `WAIT_REVIEW` | 60m | "no Fable verdict for this head in Nm — is the build's verdict artifact missing? record <dir>" |
| `HEAD_MOVED` | 30m | "head moved after the approval Nm ago and no re-review landed (actions flag off / re-review failed)" |
| `NEEDS_REBASE` | 30m | "DIRTY for Nm and not rebased (actions flag off / rebase attempt failed: <reason>)" |
| `BLOCKED_HUMAN`, resolver-owned | never pages | one conductor-log line naming the reason and the resolver; the alert, if any, comes from `bin/blocked-resolver.sh` on `ABANDONED` |
| `BLOCKED_HUMAN`, a hand-off (`mc_handoff_owns`) | never pages, and never re-classified | one `PARKED …m in BLOCKED_AGENT (<reason>)` line per hand-off, repeated at most once per `MC_STICKY_LOG_SECS`; the row does not age, because the state it is ageing in is frozen on purpose |
| `BLOCKED_HUMAN`, not resolver-owned | 0 (immediate), daily reminder | "<reason> — <files or findings>" `--critical` |
| `RED_TWICE` | never pages by age (`mc_resolver_owns` covers `red-twice`) | one conductor-log line handing it to `bin/blocked-resolver.sh`; the stuck detector below pages if the resolver has not drained it in 2h |
| `ABANDONED` | never (budget -1) | the resolver already alerted once with the full attempt list |
| `READY` | 15m | "READY for Nm and not merged" — and the `STUCK … READY` page names the hold the READY arm recorded for that head (`mc_ready_why`: ticket HOLD, merge switch off, lead fence, or a MERGE_HELD / dependency-gate line), or says the conductor logged none (2026-09-27) |
| `STACKED_WAIT` | 4h | "based on <parent branch> for Nm — the parent PR has not merged (or GitHub has not retargeted this one)". Four hours because the wait is LEGITIMATE: one chain level is 60-75 min on project-5 plus the parent's own review. Shorter would page on every healthy stack |
| `CLOSED` (issue open) | 0, once | "closed without merging and its ticket/issue #n is still open — rebuild or close the issue" |

A budget alert is not a transition: the state and `since` are untouched. **And a budget is
only ever an alert**: no age in this table, and no TTL in §5.1, closes, abandons or rebuilds a
PR — see §12's "No time kills" for the audit and for the two edges that used to do it anyway.

### 5.1 The stuck-state detector (2026-09-15)

**The evidence.** project-5 #1045 (TK-989) went red at 02:04Z on 2026-09-15. The conductor
classified it `WAIT_CI checks red once`, logged that once, paged once at 30m — and then never
touched the PR again. Ten hours later the operator closed it by hand and enqueued a fresh build.
#1124 and #1136 were the other half of the same hole: parked, owned by nobody, for hours,
with no line anywhere saying so. Neither shape is reachable from the budget table above: one
was inside its budget forever, the others were in a state that pages never by design.

**The rule.** Every state has a TTL (`mc_ttl`, the `TTL` column in section 3, overridable as
`MC_TTL_<STATE>` in `env/global.env`). A PR past its state's TTL gets:

1. **ONE alert per (PR, state, head)** — `conductor: <key> <STATE> — STUCK: Nm in one state
   (TTL Mm) on <head8> — waiting on <what>`. The dedupe key is the triple, not `(PR, state)`
   like the budget's `alerted` field: a row that re-enters a state on the same head is the
   same stuck PR, and a row on a new head is a PR somebody moved and gets its own one alert.
   The marker is a file under `state/merge-conductor/stuck/`, GC'd on the hand-off markers'
   two-week rule (`mc_stuck_gc`).
2. **The deterministic re-kick for that state, in the same tick** (`stuck_rekick`):

| State | TTL | Re-kick |
|---|---|---|
| `WAIT_CI` | 90m | close/reopen to fire the `pull_request` workflows (`mc_kick_ci`) — **only** on a head with no run at all, MERGEABLE, on the project base, and only once per head (the `cikick` record). A kick on a *pending* run cancels it through the repo's own concurrency group; a *red* head belongs to the red ladder |
| `NEEDS_REBASE`, `REBASING` | 30m | forget this head's `rebase` and `mergetree` attempts **and its `rebasedone`/`rebasefailed` consumed-result markers (BH-523 — a marker left behind makes `rebase_consume` drop the respawned rebase's result, so the forget did not actually forget)**, and drop its detached job file, so the next tick re-reads the merge state and may spawn a fresh rebase. This is the silent strand: the attempt is recorded, the job file is gone (a lost spawn, a GC'd result), and the `NEEDS_REBASE` arm's `*)` case `continue`s for ever. Local state only — nothing is written to GitHub |
| `BLOCKED_HUMAN`, `RED_TWICE` | 2h | re-offer the park to `bin/blocked-resolver.sh`: a fresh `mc_handoff_record` (which clears the stale release marker) plus the hand-off log line its recovery path reads. Only for a reason `mc_resolver_owns` — re-handing `tightened` or `migration-gated` would hand it to a lane with no rung for it |
| `QUEUED` 60m | — | on a Mergify repo, republish `lead-verdict` from the standing verdict when the head carries none (BH-4596, `mc_vs_ttl_republish`): once per (PR, head), only when an APPROVE is bound to this head, never over a `failure`/`error`, nothing on an unread status. Every other repo, or a head that already has the status: no re-kick, the alert is the action |
| `HEAD_MOVED` 90m, `WAIT_REVIEW` 90m, `READY` 20m, `STACKED_WAIT` 6h | — | no re-kick that is not somebody else's decision (a review that has to finish, a merge flag, a parent PR). READY stays here on purpose (BH-4596): the conductor may be the one holding it, and a republished status would clear it for Mergify ahead of that hold. The alert is the action, and the log says that in as many words rather than leaving silence |
| `MERGED`, `CLOSED`, `ABANDONED` | none | terminal, and each is an outcome record with its own alert path |

**No state without an owner.** The enumeration behind that table, which is the point of the
whole change: `WAIT_CI` → the red ladder, the CI kick, or the TTL alert; `WAIT_REVIEW` /
`HEAD_MOVED` → the detached head-bound review, whose every outcome (APPROVE, BLOCK, no
verdict, dead job) transitions the row; `NEEDS_REBASE` / `REBASING` → the detached rebase,
whose every rc transitions the row, plus the TTL's forget-and-retry; `RED_TWICE` and the
`BLOCKED_HUMAN` reasons `mc_resolver_owns` → `bin/blocked-resolver.sh`, which ends at
`ABANDONED` if its ladder runs out; the four `BLOCKED_HUMAN` reasons nobody owns
(`migration-gated`, `verdict-contradiction`, `provenance`, `tightened`) → they page at minute
zero, daily, and now again on the TTL; `READY` → the merge or the enqueue, both of which park
on a second failure; `QUEUED` → the settle pass or the ejection path; `STACKED_WAIT` → the
parent's merge and the retarget, or — when the parent CLOSED — the restack onto whatever rebuild
replaced it, else the same retarget if the branch is clean of the dead parent and
`orphaned-child` (the resolver's) if it is not; `MERGED` / `CLOSED` / `ABANDONED` →
terminal.

## 6. GitHub auto-merge, and what protection actually exists

Probed 2026-09-12 16:00Z (`gh api repos/O/R/rules/branches/main`; the legacy
`branches/main/protection` endpoint answers 403 on the default PAT and "Branch not
protected" 404 on the admin token — protection here is rulesets, not classic protection):

| Repo | Rules on main | Required checks | Reviews | Merge methods | `allow_auto_merge` |
|---|---|---|---|---|---|
| example-org/project-5 | deletion, non_fast_forward, pull_request, required_status_checks | Build + Unit tests | 0 | squash | false |
| example-org/project-2 | deletion, pull_request | none | 0 | squash | false |
| example-org/project-4 | deletion, non_fast_forward, pull_request | none | 0 | merge, squash, rebase | false |
| example-org/project-1 | same as project-4 | none | 0 | merge, squash, rebase | false |
| example-org/project-3 | same as project-4 | none | 0 | merge, squash, rebase | false |
| project-6-runtime, project-8 | default PAT 403; not probed further | ? | ? | ? | ? |

`allow_auto_merge` is off everywhere, so `gh pr merge --auto` cannot be enabled today.
Phase C may flip it per repo (a repo setting; admin token) and then the conductor calls
`gh pr merge --auto --squash --match-head-commit <sha>` on `READY` as belt-and-braces: GitHub
lands it the moment the required check passes even if the hub is down. Until the setting is
on, the conductor's own merge is the only path and the doc says so rather than pretending.

### The native merge queue, and why `--auto` is still not passed

A `merge_queue` rule on a ruleset changes the meaning of the conductor's merge call, so the
capability is probed per repo (`mc_queue_enabled`, section 4) rather than configured.
Two facts decide the command form, and both were probed rather than assumed:

- **`--auto` is not passed, deliberately.** `--auto` maps to `enablePullRequestAutoMerge`,
  which requires `allow_auto_merge: true` on the repo — `false` on every row of the table
  above. `gh` 2.100 already ENQUEUES on a merge-queue branch without it (its own
  `gh pr merge --help` says so), so `gh pr merge <url> --squash --match-head-commit <sha>`
  is ONE command form for the whole fleet: it enqueues where there is a queue and merges
  where there is not. Adding `--auto` would need a repo-settings change first, and that is
  a decision, not a flag.
- **Not available on this plan, today (2026-09-12).** example-org is GitHub **Team**, and the
  rulesets API rejects a `merge_queue` rule on a private repo with
  `422 Invalid rule 'merge_queue'`; GitHub's docs limit merge queues on private repos to
  organizations on **Enterprise Cloud**. So every path described in section 4 for a
  `github`-provider repo is **inert across the fleet right now**: the probe answers `none`
  for every repo, and every actor takes the code path it took before. It is written, tested
  and waiting for an Enterprise Cloud upgrade — and it is why the `mergify` provider below
  exists.

`--match-head-commit` on the ENQUEUE path is the one piece that could not be verified: the
GraphQL `enqueuePullRequest` input has `expectedHeadOid`, but whether `gh` plumbs the flag
through to it is unconfirmed, and it cannot be confirmed without a repo that has a queue.
The re-read immediately before acting (section 4) is the fallback, and it is a TOCTOU
window, not a guarantee.

### Two providers: `github`, `mergify`, `none`

Because the native queue is unavailable on Team (above), the operator's decision on 2026-09-12 was
to adopt **Mergify** — a GitHub App, free at ≤ 5 active contributors — as the fleet's merge
queue, starting with `example-org/project-5`. The conductor therefore probes a *provider*
rather than a boolean:

| `mc_queue_provider <slug>` | Detected by | What entry into the queue IS | What `gh pr merge` does there |
|---|---|---|---|
| `github` | an ACTIVE ruleset on the default branch carrying a `merge_queue` rule | `gh pr merge --squash --match-head-commit` | **enqueues** (exits 0, PR stays OPEN) |
| `mergify` | `.mergify.yml` on the default branch containing `queue_rules:` | **adding the `merge-queue` label** | **merges outright — BYPASSES the queue** |
| `none` | neither, or any API error (fail-closed) | n/a | merges, as it always has |

The provider word is cached per slug for `MC_QUEUE_TTL` (one tick) in
`tmp/merge-queue-<slug>.provider`, fail-closed to `none`. Since BH-1586 the probe's own
reads (rulesets, `.mergify.yml`) go through gh_rest behind `bin/lib/gh-policy-cache.sh`.
That cache keeps only **positive** answers, for `GH_POLICY_TTL_SECS` (a lib knob, default
3600), under `state/gh-policy-cache/<repo>/`. A 404 is never cached, because `none` is
the direction that merges around a Mergify queue. Deleting the provider file drops the
repo's policy entries too, so "delete the file" still means "ask GitHub now"
(docs/MERGIFY.md §4). `mc_queue_enabled` is true for **either** provider, which is what makes every
stand-down and skip written for the native queue apply to a Mergify repo unchanged: the
`pre-arm-guards.sh` skips, `bin/merge-queue.sh`'s early exit, `bin/tier2-merge-sweep.sh`'s
per-PR skip, and `pipeline-health`'s `sweepstall` exemption.

**The one thing that is not shared is who may call `gh pr merge`.** That is the whole
difference between the two providers, and it gets its own predicate,
`mc_queue_conductor_only <slug>` (true only for `mergify`). Under Mergify a direct
`gh pr merge` lands the PR on main with none of the batch verification the queue exists
for, so on a mergify repo these three stand down and leave the PR to the conductor, which
is the only actor that knows how to label it: `bin/merge-sweep.sh` (before its merge call),
`bin/review-prs.sh` (its APPROVE arm), and `bin/run-build.sh`'s tier-1 gate (which exits
through `PR_CREATED`, exactly as `flags/conductor-owns-merges` already makes it do).
`bin/poll-commands.sh`'s `merge_pr` is deliberately NOT stood down — it is an explicit human
merge from Mission Control — but what it reports back goes through the provider-aware
reader, so a queued PR is reported as queued rather than as merged.

**The label contract.** `MC_MERGIFY_LABEL` (default `merge-queue`) is one name in one place,
and the repo's `.mergify.yml` keys its `queue` action on it. It serves three jobs at once:
entry (`gh pr edit --add-label`, idempotent — a comment would not be), the cheap read (the
conductor's open pass gets `labels` in the same `gh pr list` call it already makes, so
"is this queued" costs no extra API call per PR), and retraction (`mc_dequeue_label` on an
ejection). Creating the label in a repo is an **ops step, not code** — see `docs/MERGIFY.md`.

**The witness is Mergify's, not ours.** A label is what we asked for; a check run is what
Mergify did. So `mc_enqueue_mergify` polls for a *Mergify* signal before reporting the
enqueue: a check run on the head whose name starts `Mergify` / `Queue:` or contains
`(queue)` **and is not Mergify's idle line** — with the Merge Queue product live Mergify
posts a neutral check titled "Merge queue is ready" on every PR it evaluates, queued or not
(project-5 #546/#547, 2026-09-13), and `mc_mergify_check_live` drops it — or one of
Mergify's own `queued`/`checking` labels. Without that, a repo whose
`.mergify.yml` has `queue_rules` but whose **app was never installed** would sit in `QUEUED`
forever with the label as its own proof.

**"No witness" is its own outcome (rc 3), and the lane falls back rather than stalling.**
The live test on `project-5` #510 (2026-09-12) answered this precisely: `@mergifyio queue`
came back with **"The product Merge Queue needs to be activated"**. App installed, config
right, label right — the queue *product* was simply off. That is a standing condition on the
**repo**, fixed in a dashboard, and it says nothing about any PR.

Sending it into the two-strike `mergefail` path would park **every** `READY` PR on the repo in
`BLOCKED_HUMAN` for one toggle, to be cleared by hand one at a time, so rc 3 is never a strike.

**And since BH-2199 (2026-09-24) it is a HOLD, never a direct merge.** Until then rc 3 fell
back to `mc_merge`, bypassing the queue (the operator, 2026-09-12). On 2026-09-24 #2196 landed that way
at 21:09Z over a lead CHANGES_REQUESTED while Mergify was running batches and was only slow to
acknowledge. rc 3 only ever comes from Mergify, and the provider is `mergify` only when the
repo's `.mergify.yml` declares `queue_rules` — the repo chose a queue to keep main green. So on
rc 3 the conductor:

- **merges nothing** and records no strike; the merge budget unit goes back;
- **keeps the row `READY` and our label on**, so the queue can still pick the PR up
  (`mc_mergify_inqueue` then classifies it `QUEUED` as usual) and logs
  `<pr> MERGE_HELD: the mergify queue acknowledged nothing … A direct merge here is a lead action`;
- raises **one alert per repo per UTC day** (`mc_queue_inactive_alert`, deduped through
  `MC_ATTEMPTS` under a lock so parallel PR workers of one tick page once):
  `mergify queue not answering for <slug> — READY PRs are held, NOT merged …`;
- **asks the queue again every `MC_MERGIFY_REASK_TICKS` held ticks** (registry default 6,
  about 30 minutes; `mergifyhold <key> <head>` lines in `MC_ATTEMPTS` count them), so a repo
  whose queue product is off is not sent `@mergifyio queue` every five minutes.

A direct merge in this state is an **explicit lead action** (the lead merges by hand). A
`hotfix` PR is held like any other; it still heads the tick's order, so it is asked first.

Because our label goes on *before* the witness poll, **our own label cannot be what makes a
row `QUEUED`** — a PR can carry it while the queue has never heard of it (during the rc-3
tick itself, and afterwards on every held tick). `mc_mergify_inqueue`
therefore requires one of: Mergify's own `queued`/`checking` label (free, already in the list
row), a row that is *already* `QUEUED` (a witnessed enqueue put it there), or a check run
(one call, and only for the rare PR that carries the label without being queued — normally
none). Otherwise such a PR would move to `QUEUED`, the settle pass would find it neither
merged nor ejected, and it would sit there until its 3600s budget paged — a stall invented
out of our own request.

**Verified against the docs vs assumed.** Verified: the config keys (`queue_rules` with
`queue_conditions` / `merge_conditions` / `batch_size` / `batch_max_wait_time` /
`merge_method` / `max_checks_retries`), entry by the `queue` action on a label condition or
the `@mergifyio queue` comment, the single consolidated **`Mergify Merge Queue`** check run,
the `queued` (default) / `checking` (unset by default) / `dequeued` (default) labels, and
that a failing batch is bisected until the culprit is **removed from the queue**. NOT
verified, because the docs do not state it: the *conclusion* a dequeued PR's check run
carries. The code therefore treats GitHub's standard failure conclusions as ejection and
keeps the labels as an independent second witness — and the whole thing needs one live
Mergify install to prove.

**No head pinning.** `--match-head-commit` has no Mergify equivalent: a label is not
head-bound, and Mergify queues whatever the head is when it picks the PR up. The guard is
the conductor's own re-read of `state,headRefOid` immediately before labelling, which is a
TOCTOU window, not a guarantee — the same honest limitation the native path has, one step
wider. A push landing inside it is caught one tick later as `HEAD_MOVED`.

### A hotfix PR with migration files needs its proof before entry (BH-370.2)

A migration PR is always tier 2 — `bin/run-build.sh` forces `TIER=2` on any diff matching
`migrations?/|\.sql$` (its own tier line, and `RT_RISKY_RE` in `bin/lib/review-tier.sh`), so
run-build's gated tier-1 merge never lands one and this lane is the only merger left.
That is what makes this the gate deciding whether unapplied SQL reaches main. A `hotfix` PR that
**adds** migration SQL does not enter the queue, is not merged directly, and does not ride a
batch train until `bin/hotfix-migrate.sh` has posted an accepted proof for exactly that SQL.

`mc_hotfix_proof <slug> <num> <labels-csv> [record-dir]` answers it in one word, and the
guard in `pr_worker` runs on a `READY` row before the `case "$STATE"` that owns both of this
script's writes (the Mergify label add and the degraded `gh pr merge`), so neither exit is
reachable without a proof:

| word | what it means | what the conductor does |
|---|---|---|
| `n/a` | not a hotfix PR (`hotfix_pr_is`), or it adds no migration file | nothing: the ordinary path, and nothing is logged |
| `ok` | an accepted proof for this SQL | nothing: the ordinary `READY` path, with every existing gate |
| `missing` | no proof comment, or GitHub would not answer | `WAIT_CI reason=hotfix migration proof missing: …` |
| `stale` | a proof for other SQL, or a marker nobody can read | `WAIT_CI reason=hotfix migration proof stale: …` |
| `hold` | `decision=hold`, `flagged` or `no-path` — the stage deliberately did not apply it | `BLOCKED_HUMAN reason=hotfix-migration-hold: …` |

**The contract it reads** (shared with every BH-370 child): migration files are files with
git status `added` (never `modified`, never `renamed`) matching `scripts/migrations/*.sql` or
`prisma/migrations/manual/*.sql`, plus `$HOTFIX_MIGRATE_GLOB` when set — the same definition
as `check-migration-appliable.sh`'s `--diff-filter=A`. The fingerprint `FP` is the sha256 of
the sorted `"<path> <git blob sha>"` lines over those files, so a rebase that leaves the SQL
untouched keeps the proof and any edit to the SQL invalidates it. The proof is a PR comment
whose FIRST LINE is exactly
`<!-- hotfix-migrate-proof fp=<FP> decision=<applied|deferred-to-deploy|hold|flagged|no-path> -->`;
`applied` and `deferred-to-deploy` with a matching FP are accepted, everything else is not.
The NEWEST marker decides, and a comment that merely quotes the marker is not one.

**FP before decision.** A marker whose FP does not match reads `stale` even when it says
`hold`: a hold about different SQL says nothing about the SQL this head carries, and another
stage run is the cheaper, reversible answer.

**`hotfix-migration-hold` is deliberately NOT in `mc_resolver_owns`.** A held migration is
somebody's decision about a database, and `bin/blocked-resolver.sh`'s ladder (fix round,
rebuild fresh) cannot change it — so the park pages at once, like `migration-gated`, and the
row says to read the proof comment. It is not sticky either: the row is re-derived every
tick, so the tick after the stage posts an accepted proof takes the ordinary `READY` path
with no un-parking by hand.

**The batch train is the THIRD exit, and it asks the same question.** A train
(`bin/batch-resolve.sh`, section 15) is a new PR of its own: it carries no `hotfix` label, it
never goes through `pr_worker`, and it is landed by `mc_enqueue` or the box queue — so the
guard above does not see it, and a hotfix held in `WAIT_CI hotfix migration proof missing`
would otherwise ride into main inside a union branch. The lane's candidate loop therefore
calls `hotfix_pr_is` + `mc_hotfix_proof` after its verdict and tier gates and drops any member
whose proof is not `ok`/`n/a`, with a log line naming the word it got. Same reads, same
fail-closed answers, and nothing at all for a PR that is not a labelled hotfix. Driven by
`tests/batch-resolve-test.sh` (section F0).

**Cost and failure.** Two `gh` reads per hotfix-labelled `READY` PR per tick and ZERO for
every other PR — the labels are already in the tick's own PR list (the batch lane now asks for
`labels` in its own list for the same reason). Both reads fail CLOSED: a
read that errors is `missing` (hold and retry), never `n/a` (merge it), because an expired
token answering "this PR has no migrations" for the whole fleet is the exact failure this
gate exists to prevent. This half only READS; nothing here posts a proof or runs
`bin/hotfix-migrate.sh`. `flags/hotfix-lane-off` (or `HOTFIX_LANE=0`) takes this gate off
with the rest of the lane, because the PR is then not a hotfix for any purpose in this
harness. Driven by `tests/hotfix-merge-requires-proof-test.sh`.

## 7. Tokens

Every `gh` call goes through `bin/lib/gh-repo-token.sh` (#262): `gh_repo_use_token
<slug>` before the first call for a repo, `gh_repo_token_reset` after; a repo no token can
see is `gh_repo_invisible_alert conductor <slug> …` (one page per repo per day), never an
empty loop. project-5 and project-7 need the admin token (`env/github-admin.env`, chmod 600,
read by name only). No token value reaches a log, a comment or the ledger: only the words
`default`/`admin`.

### 7.1 App installation tokens first (2026-09-14)

`use_token <slug>` now asks `gh_auth_for <slug>` (`bin/lib/gh-app-auth.sh`) **before** the
PAT probe. When this box has a GitHub App configured that returns a token scoped to that one
repo which expires in an hour, minted and cached by `bin/gh-token.sh`; the conductor's `gh`
calls for that repo then run on it. `reset_token` calls `gh_auth_reset` and
`gh_repo_token_reset`, in that order, so the process's original `GH_TOKEN` is restored either
way.

Why: one PAT is one 5000-requests/hour bucket for the whole fleet, which is the ceiling the
conductor hits first when 4000 builders are opening PRs, and it is one credential whose leak
is fleet-wide and permanent. An installation token is rate-limited per installation.

A token that minted can see the repo by construction, so the invisible-repo probe and
`gh_repo_invisible_alert` are **not** run on that path. They are untouched on the PAT path,
which is what an unarmed box takes — no `env/github-app.env`, `GH_APP_TOKENS=0`, or
`flags/gh-app-tokens-off` and §7 above is exactly what happens, with no extra process forked.

**The App is also an AUTHOR, not just a credential.** A PR opened on an installation token
is authored by the App — `app/cromford` to `gh pr list --json author`,
`cromford[bot]` to the REST API — so every consumer that discovers harness PRs reads the
author set in `bin/lib/gh-pr-list.sh` (`HARNESS_PR_AUTHORS`, section 2) rather than a login.
A box that names its App something else sets `GH_APP_SLUG` in `env/github-app.env` or
`HARNESS_PR_AUTHORS` in `env/global.env`; the default already covers the fleet's App.

**Known boundary.** `mc_git_auth` (`bin/lib/merge-conductor-lib.sh`) re-asks
`gh_repo_use_token` and then picks the credential `git` can actually *fetch* with by
`ls-remote` probe, so the conductor's rebase fetch/push still runs on a PAT even when its
`gh` calls run on an App token. That is today's behaviour, unchanged and not a regression;
moving the rebase credential onto the App token is the follow-up, and it needs the App's
`contents: write` grant proved by the same `ls-remote` probe rather than assumed.

### 7.2 The merge path arms through the lib (BH-438, 2026-09-17)

`bin/lib/merge-conductor-lib.sh` makes real `gh` calls of its own and had no way to arm
anything, so `bin/merge-queue.sh` and `bin/blocked-resolver.sh` — the other two scripts on
the merge path — ran every one of their reads and merges on the shared PAT. The lib now
sources `bin/lib/gh-app-auth.sh` (guarded, and skipped when the caller already sourced it)
and exports two wrappers:

- `mc_use_token <slug>` arms the per-repo App token and **nothing else**. No PAT fallback, no
  invisible-repo alert, no new skip path: those stay in `bin/merge-conductor.sh`'s own
  `use_token` (§7.1), where a lane opts into them by name. A shared lib that paged would page
  under the wrong lane's name and share the conductor's once-a-day dedupe flag.
- `mc_reset_token` puts back the `GH_TOKEN` the process started with. The lib never calls it
  itself — only a caller does, at the end of its own run. A sourced file that un-arms the
  shell out from under a lane is a bug nobody sees until a later call goes out on the wrong
  identity.

Both are `command -v` guarded and neither ever returns nonzero, so a box whose harness sync
has not landed `gh-app-auth.sh` yet runs exactly as it did before.

`bin/merge-queue.sh` calls `mc_use_token "$SLUG"` immediately after it sources the lib, which
is above every `gh` call it makes, and `mc_reset_token` on its last line before `exit 0`. Its
early `exit 0` paths do not reset; there is nothing to reset to, because the exported token
dies with the process. `bin/blocked-resolver.sh` keeps its own pair: `br_use_token` tries
`gh_auth_for` first and falls to today's `gh_repo_use_token` probe when the App token is not
available, and `br_reset_token` runs both resets, App first. Its call sites are unchanged.

`bin/lib/gh-app-auth.sh` gained two things for this: a `_GHAA_LOADED` re-source guard (the
conductor sources the helper and then the lib, which would otherwise source it a second time
and save the ARMED token as "the default"), and `gh_auth_for_url <url>`, for a lane that holds
a PR URL rather than a slug.

**The ratchet.** `tests/gh-app-ratchet-test.sh` walks `bin/**/*.sh` and fails on any raw
`gh pr|issue|api|repo|run|workflow` call in a file that is neither armed nor DECLARED. Since
BH-1177 the declaration lives in the script's own header, one line under the shebang:
`# gh-identity: app-token` (it arms one), `# gh-identity: raw-pat (BH-<n>) — <why>` (still on
the PAT, and the ticket names the slice that converts it) or
`# gh-identity: raw-by-design — <why>` (converting it would be wrong rather than merely
undone). `app-token` is optional today and no file carries it yet; the rule is that every file
calling `gh` RAW declares.

Two registries keep the raw set from growing, both ONE FILE PER SCRIPT rather than a list with
a pinned count: `tests/gh-app-ratchet-baseline/<path>.txt` for a script queued for conversion,
`tests/gh-app-ratchet-by-design/<path>.txt` for one exempt forever. A script is in exactly one
of them, and the suite fails either way round. The second directory is the reviewed artifact
the old `ALLOW_COUNT -eq 6` pin stood for: without it a new raw caller ships on one self-written
comment line. Converting a script edits that script's header and deletes that script's registry
file, so two conversions in flight never touch the same path. The suite also fails a marker the
scanner disagrees with — an `app-token` line over a file that arms nothing, or a raw marker on a
file that no longer makes a raw call — and reads the state of the ticket a `raw-pat` marker cites,
advisory and fail-open, so a marker cannot name a shipped ticket as its owner. The three merge-path files
are not trusted to the scanner: its armed rule is textual, so blocks 5, 6 and 7 of that suite
run the lib, the resolver's extracted `br-token` block and the real queue script, and read the
token their `gh` calls actually go out on.

### 7.3 Every lane names its credential (BH-597, 2026-09-18 → rebased 2026-09-21)

`gh pr view --json` and `gh pr list --json` are GraphQL calls. Every PAT in the fleet belongs
to the same GitHub user (operator, id 2220366), so all of them draw on **one** 5000/hour GraphQL
budget — and on 2026-09-16 it ran out twice (17:05–18:05Z, then 22:03Z). Every PR-state read
in the conductor, the sweep, the resolver and this lib answered an empty string while
`gh api rate_limit` still showed 5000/5000 core; the lanes went blind, and clean PRs were sent
to REBUILD FRESH because "this PR has no branch". BH-597's original fix moved every one of those
reads onto a single new reader, `mc_pr_read`, added to `bin/lib/merge-conductor-lib.sh`.

**`mc_pr_read` did not survive the rebase onto current main.** Between BH-597's review and this
rebase, main independently converted the same four lanes onto REST through a different, more
complete reader — `mc_pr_view <pr-url> <jq-expr>` (`bin/lib/mc/classify.sh`), built on
`gh_rest`/`gh_rest_pr_state`/`gh_rest_pr_list`/`gh_rest_comment`/`gh_rest_close`
(`bin/lib/gh-rest.sh`, BH-783/BH-784, #966/#1157) — with a three-way `0`/`44`/`75`
ok/absent/unverifiable contract that `mc_pr_read`'s two-way rc `0`/`1` (collapsing absent and
unverifiable into one "could not read") did not carry. Landing `mc_pr_read` on top of that would
put two live per-PR REST readers with different failure contracts in the same lanes — the exact
regression the BH-597 operator HOLD (ticket #597) existed to prevent — so the rebase drops
`mc_pr_read` and every call site this ticket moved onto it, in `bin/blocked-resolver.sh`,
`bin/lib/mc/queue.sh`, `bin/lib/mc/rebase.sh` and `bin/merge-conductor.sh`, and keeps main's
`mc_pr_view`/`gh_rest_*` reads as-is. `bin/lib/merge-conductor-lib.sh` is itself now a pure shim
(BH-477.3, #1191) that sources `bin/lib/mc/{log,locks,classify,queue,rebase,settle}.sh` — it
carries no function bodies of its own to swap a reader into.

**What survives from the ticket is item 2: every lane names its credential**, once per tick per
repo, in the words `App installation token` / `default PAT` / `admin PAT` and never a token
value:

- `bin/merge-conductor.sh`'s `use_token` logs after `gh_default_auth_for_slug` (#469, the
  App-first-then-PAT identity helper — §7.1) returns, reading its own `GH_LIMIT_IDENTITY` tag
  (`app:<slug>` / `pat:<slug>`) rather than re-deriving the credential; its pre-#469-lib fallback
  (`gh_auth_for` then `gh_repo_use_token`) logs the same way it always would have.
  `<slug>: github auth: …` in `logs/merge-conductor.log`, once per tick because `tick_project`
  arms once per project.
- `bin/merge-sweep.sh`'s `sweep_use_token_for` logs the same way around its own
  `gh_default_auth_for_slug`-first ladder (#469) and its `_sweep_probe`
  default/admin/app/transient fallback. `github auth: … for <slug>` in `logs/merge-sweep.log`.
- `bin/blocked-resolver.sh`'s `br_use_token` (the `# >>> br-token` / `# <<< br-token` block) logs
  through `br_auth_log`, deduped per RUN via `_BR_AUTH_SAID` (not per tick, because the resolver
  touches one repo many times in a single pass) — including the `none` case, which says
  "no credential" rather than naming `none` as if it were a PAT.
  `<slug>: github auth: …` in `logs/blocked-resolver.log`.

**And the tick's lock dies with the tick — asserted here, shipped by BH-651.** `bin/run-triage.sh`
holds `locks/<project>.lock` on fd 9 and `bin/triage-shard.sh` holds
`locks/triage-key-<project>-<KEY>.lock` on fd 8. Neither passes `9>&-` / `8>&-` on its own
`agent-call.sh` line: both launch the session through `lock_run_unheld` (or `lock_spawn_unheld`
for a detached one) from `bin/lib/lock-hygiene.sh`, which closes both descriptors in a subshell
and execs, so the session — and every build it detaches — does not inherit them while the caller
keeps its own lock. Without that the lock was held for the build's whole life and later ticks
logged "previous run still active, skipping" (2026-09-16 21:53Z and 22:03Z, which is what blocked
BH-594's re-offer). Not `flock -u`: each script keeps the lock for its own remaining lines, and
the shard's key DEDUPE has to go on refusing a second shard while it runs. **This change ships no
part of that mechanism.** It adds the regression assertion (block E of the suite named just below), which runs the real
`run-triage.sh` and `triage-shard.sh` against a detached agent session and fails if either lock
is still held after the tick exits — with a negative control first, so a box that cannot
demonstrate the trap at all fails loudly instead of passing vacuously.

Driven by `tests/gh-budget-rest-test.sh`: block B drives the real `bin/merge-sweep.sh` (its
credential ladder and log lines, over main's `mc_pr_view` reads); blocks C and D extract
`bin/merge-conductor.sh`'s `use_token`/`reset_token` and `bin/blocked-resolver.sh`'s `br-token`
block by name; block E is the lock-hygiene regression above. The resolver's and the conductor's
and the sweep's own PR-state REST reads are covered where they are exercised in production —
`tests/blocked-resolver-test.sh` and its `bh-*` siblings, `tests/merge-conductor-test.sh` and
`tests/merge-rest-test.sh` — not duplicated here.

## 8. Flags: the truth table

| `flags/merge-conductor-observe` | `flags/merge-conductor-actions` | `flags/merge-conductor-merge` | `flags/automerge-disabled` | Behaviour |
|---|---|---|---|---|
| absent or present | absent | absent | any | **observe-only**: classify, ledger rows, alerts. No `gh` write, no push. |
| any | present | absent | absent | + rebases, detached re-reviews and the two approval rebinds — patch-id and no-overlap (branch pushes, PR comments, verdict rebinds; the patch-id of an approved head is only ever computed and stored here, and the `merge-tree` conflict test only runs on the way into a rebase this flag authorises). No merges. |
| any | present | present | absent | + merges. |
| any | any | any | present | states and alerts only; every action is refused with one log line per tick. |
| any | absent | present | absent | merges are refused (merge without actions is not a supported mode); logged once per tick. |

The four `flags/` files above are the GitHub-write switches. The three detached lanes have
env kill flags instead, because what they change is WHERE work runs, not whether GitHub is
written to — all default ON, and with each set to `0` the behaviour is exactly what it was
before that lane shipped:

| env var | default | `0` means |
| --- | --- | --- |
| `MC_DETACHED_REBASE` | 1 | the tick rebases inline, as before 2026-09-14 |
| `MC_MERGE_TREE` | 1 | no `git merge-tree` conflict test — every DIRTY PR is rebased, as before 2026-09-14 |
| `MC_MERGE_TREE_MAX` | 3 | (not a kill flag) clean merge-tree answers one head may spend before the rebase runs anyway |
| `MC_OVERLAP_REREVIEW` | 1 | no overlap rebind — every moved head the patch-id rebind missed buys the re-review, as before |
| `MC_AUTOPILOT_CONSUME` | 1 | the >12h review-autopilot verdict on a moved head is never read; the conductor buys its own re-review, as before 2026-09-18 (section 4) |
| `MC_AUTOPILOT_RECHECK_SECS` | 3600 | (not a kill flag) how often ONE (PR, head) may re-read the PR's comments looking for that verdict. The hub-local mirror is free and is read every tick regardless |
| `MC_REREVIEW_ON_MOVE` | 1 | a `blocked@<this head>` from the build's own head-bound gate parks on `head-not-reapproved` on sight again, instead of buying the conductor's own read first, and a dead re-review job takes the `no-verdict` park without its one retry (section 4) |
| `MC_DETACHED_DEPLOY_VERIFY` | 1 | `mc_settle_merged` calls `deploy-request.sh` from the tick, as before |
| `MC_REBASE_PARALLEL` | 4 | (not a kill flag) detached rebases running at once, fleet-wide |
| `MC_REBASE_TIMEOUT_SECS` | 1800 | a running rebase older than this is failed |
| `MC_REREVIEW_PARALLEL` | 8 | detached re-reviews running at once, fleet-wide |
| `MC_RR_DIFF_INLINE_BYTES` | 96000 | (not a kill flag) bytes of `gh pr diff` inlined in the re-review prompt. Above it the prompt carries the head of the diff plus a `[DIFF TRUNCATED: …]` notice pointing at the complete diff file; raise it and the prompt grows with the PR (BH-495) |
| `MC_PR_PARALLEL` | 0 | (not a kill flag) PR workers of ONE project running at once; 0 = unlimited (section 2.1) |
| `MC_MERGE_LOCK_WAIT` | 120 | (not a kill flag) seconds a PR worker waits for its project's merge lock before answering rc 99 = nothing written, next tick |
| `MC_GIT_LOCK_WAIT` | 180 | (not a kill flag) seconds it waits for the project's shared git checkout before answering rc 99 = not asked this tick |
| `MC_PR_LOCK_TTL_DAYS` | 14 | (not a kill flag) how long an untouched per-PR lock FILE survives `mc_pr_lock_gc` |
| `MC_DV_TIMEOUT_SECS` | 2400 | a verifier older than this is failed and alerted |
| `MC_STICKY_HANDOFF` | 1 | a `BLOCKED_HUMAN` row handed to `bin/blocked-resolver.sh` is re-classified every tick, as before 2026-09-14 (section 4) |
| `MC_STICKY_LOG_SECS` | 3600 | (not a kill flag) how often a sticky park may re-state itself in the log |
| `MC_RELEASE_LABEL` | `conductor-release` | the PR label a person applies to end a hand-off park, once per (PR, head); empty = no label ends a park, as before BH-292 (section 4) |
| `MC_JOB_WAIT_SECS` | 3600 | (not a kill flag) how long a `status=running` ledger row with no verdict may hold a PR back from a review before it is treated as a dead builder (section 4) |
| `MC_QUEUE_REENTRY` | 1 | an ejected Mergify head is never re-queued, as before BH-636 (section 6) |
| `MC_EJECT_REBASE` | 1 | a base-conflict ejection would count as a strike and buy no out-of-budget rebase, as before BH-1669. **Reserved: nothing reads it until BH-1669's ejection-rebase child lands, so today 0 and 1 behave identically** (`bin/lib/mc/log.sh`) |
| `PR_DEP_GATE_TICKET` | 1 | only the PR-body `Depends on #N` gate would hold, as before BH-1669. **Reserved in the same way: `pdg_ticket_enabled` in `bin/lib/pr-dep-gate.sh` reads it and no lane calls that yet, so today 0 and 1 behave identically** |
| `MC_REQUEUE_CAP` | 5 | (not a kill flag) re-queues one project may spend in one tick; over it the row logs `REQUEUE_DEFERRED` and is re-offered next tick |
| `MC_MERGIFY_REQUEUE_CMD` | `@mergifyio requeue` | (not a kill flag) the comment the re-entry posts. `@mergifyio queue` is the other reading of "re-add the label" and is one env value away |
| `MC_AUTOENQUEUE` | 1 | no tier-2 self-enqueue: an approved, green, clean Mergify PR waits for the conductor's own READY enqueue or a person, as before BH-1668 (section 4). `MC_AUTOENQUEUE_CAP` (10, posts per project per tick, over it `DEFERRED`), `MC_AUTOENQUEUE_CHECK` (`Build + Unit tests`) and `MC_AUTOENQUEUE_HOLD_LABELS` (`hold,do-not-merge`) are its settings rows |
| `MC_MAIN_RED_DETECT` | 1 | the tick does not run `bin/main-red-detector.sh` at all (section 4). The detector's own `MAIN_RED_DETECT=0` / `flags/main-red-detector-off` still turn the detector itself off |
| `BR_HANDOFF_MAX_AGE_SECS` | 172800 | (bin/blocked-resolver.sh, not a kill flag) how far back the hand-off log is read when recovering a park whose row already moved on |
| `flags/batch-resolve-off` | absent | the merge-time batch train is not built; a train already pushed is still settled (section 15) |
| `BATCH_RESOLVE` | 1 | the same, per project (`env/<project>.env`) |
| `flags/hotfix-lane-off` / `HOTFIX_LANE` | absent / 1 | **this one removes a MERGE GATE as well as the ordering.** With the lane off `hotfix_pr_is` answers no to every PR, so the hotfix queue-ordering of section 6 stops AND the migration-proof gate above stops with it: a `hotfix` PR that adds migration SQL is then an ordinary PR and merges without a proof. That is deliberate — with the lane off the label means nothing anywhere in this harness — but it is not a switch to flip because ordering misbehaves on a busy repo. Turn the ORDERING off and leave the gate on by unsetting the label on that one PR instead |

`merge-conductor-observe` exists so a human can pin observe-only explicitly during a phase
where the action flags are on; its presence wins over both action flags. All flags are read
through `flag_active` (DB row reconciled to the file) so the console can flip them.

### Reserved vocabulary: ejection rebase and ticket-order hold (BH-1669)

No code on this branch emits or reads any of the words below yet. BH-1676 only
reserves them so BH-1669's children share one vocabulary; each child that starts
writing or reading one owns it from then on.

- Log lines: `EJECTED_CONFLICT <key> <head>` (a Mergify ejection whose reason is a
  base-branch conflict), `EJECT_REBASE_SPAWNED` (the out-of-budget rebase for it was
  launched) and `EJECT_REBASED` (that rebase pushed a new head).
- `MC_ATTEMPTS` marks: `ejectconflict <key> <head>` and `ejectrebase <key> <head>`,
  meant to be written once per (PR, head).
- Ledger detail: `rebased_after_ejection=1 from=<oldhead8>` on the row of the new head.

The two functions the children build on exist as stubs: `mc_dequeue_conflict` in
`bin/lib/mc/queue.sh` (answers `""` today) and `pdg_ticket_deps` in
`bin/lib/pr-dep-gate.sh` (prints nothing today). Their header comments carry the
contract they will answer.

## 9. Retiring the other mergers

**What a merge queue retires, per repo** (inert until a repo actually has one — a
`merge_queue` ruleset rule, or a `.mergify.yml` with `queue_rules`; see section 6). The repo
capability is the switch everywhere the conductor itself calls;
`flags/conductor-owns-merges` is the switch for the scripts that run on a different box and
cannot cheaply probe:

| Retired on a queue repo | How | Why |
|---|---|---|
| `bin/pre-arm-guards.sh` dispatch (conductor + sweep) | `mc_queue_enabled` at both call sites | the queue's own batch run asks the same question with a binding answer, without the 1800s poll or the unsatisfiable rc-3 path |
| `bin/merge-queue.sh` (box) | early exit | `gh pr merge` there only enqueues (native) or bypasses the queue (Mergify), so the entry file is never dropped and the cron re-enqueues the same PR forever |
| `bin/tier2-merge-sweep.sh` enqueue | skip per PR | a queued PR is still OPEN, so it would be fed to the box queue every ten minutes |
| `bin/merge-sweep.sh` consequence block | state verification | it would otherwise record the merge, close the issue and beat for a PR that only queued |
| `bin/merge-sweep.sh`, `bin/review-prs.sh`, `bin/run-build.sh` tier-1 — their merge CALLS | `mc_queue_conductor_only`, **mergify only** | under Mergify `gh pr merge` bypasses the queue entirely; under the native queue that same call IS the enqueue, so it stays |
| `bin/pipeline-health.sh` `sweepstall` | reads `pr-state.tsv`, never `logs/merge-sweep.log` (2026-09-27): pages only for no row, or `READY` with no hold recorded for the head in `SWEEPSTALL_HOLD_TICKS` ticks | OPEN + CLEAN is a queued PR's NORMAL shape; `STACKED_WAIT`, `BLOCKED_HUMAN` and every other state are the conductor's, paged by its own TTL; a held `READY` row says why through `mc_ready_why` |
| `bin/rebase-train.sh` | nothing to retire | it is not wired for the queue pilot's repo at all — do not wire it |

| Actor | Phase A (observe) | Phase B (actions) | Phase C (merges) |
|---|---|---|---|
| `bin/merge-sweep.sh` | unchanged; the conductor reads the same records and reports what the sweep will do | **one correctness fix, unconditional**: it no longer treats `gh pr merge`'s EXIT CODE as a landing. After the call it re-reads the PR — `MERGED` takes today's consequence block; still open and `isInMergeQueue` is one log line and nothing else (no ledger row, no issue close, no beat: the conductor owns that settle); neither is the existing failure path. `--delete-branch` is dropped on a queue repo, where the branch is what the queue is about to build | **its hub cron line is NOT removed — `cron/hub.cron` still runs it at `6,16,26,36,46,56` every hour, alongside the conductor** (removing it is the phase-C step in section 9, and the rollback there restores it; until someone takes it, both lanes read the same PRs and the conductor is not the only merger). The conductor's READY test is the sweep's merge test (same readers: `job_verdict`, `review.md`, `reviewed-sha`, the iron-law scan block, `pre-arm-guards.sh`, the discounts), and `job_ledger_put merge` keeps the sweep's ledger kind so `pipeline-health`'s `sweepstall` and `reconcile-prs` keep working |
| `bin/review-prs.sh` | unchanged | unchanged | **shipped, behind `flags/conductor-owns-merges`**: with the flag on it stays a REVIEWER — it posts the verdict, merges nothing, and enqueues nothing on the box queue. NOTE before flipping it: the conductor lists the `HARNESS_PR_AUTHORS` set's PRs, so an EXTERNAL author's approved PR then waits for a human until the scope extension below ships. Design as written: on APPROVE it enqueues nothing and the conductor (which lists all harness-authored PRs) does not see external PRs, so review-prs writes `pr_state` rows for external PRs it approved and the conductor merges from those rows (scope extension, its own PR) |
| box `bin/merge-queue.sh` + `bin/tier2-merge-sweep.sh` | unchanged | unchanged | **shipped**: both exit 0 when `flags/conductor-owns-merges` is present (reconciled via `flag_active`, so a console flip reaches every box). A stood-down queue KEEPS its entries — removing the flag hands the work straight back. `fly-results-ingest.sh`'s ssh touch becomes a no-op the conductor supersedes |
| `bin/rebase-train.sh` | unchanged | its three hub cron lines are removed once the conductor's rebase (which lifts its resolvers) has landed one rebase per project with a green gate | gone |
| `bin/run-build.sh` tier-1 gate | unchanged | unchanged | **shipped, behind `flags/conductor-owns-merges`**: with the flag on a tier-1 build exits through the `PR_CREATED` path exactly as `BUILDER_NO_MERGE=1` already makes the pool builders do, and the conductor classifies the reviewed, approved, open PR `READY` on its next tick. With the flag off it merges its own fresh PR as it always has and the conductor records that as `MERGED by:tier1` |
| `bin/review-autopilot.sh` | unchanged | unchanged | unchanged (reviewer, never merged) |
| humans | unchanged | unchanged | unchanged; the conductor records `MERGED by:human` |

**Rollout.**
- Phase A, 24h: cron line live, observe-only. Exit criterion: every open harness PR across
  the fleet has a row, no state flaps (a PR alternating states without a head change), and
  the alert volume is one line per PR per state. Rollback: delete the cron line.
- Phase B: `bin/jobs-client.sh flag-set merge-conductor-actions on "<reason>"`. Exit: one
  conductor rebase and one conductor re-review each landed with a green gate and a rebound
  approval. Rollback: `bin/jobs-client.sh flag-set merge-conductor-actions off "<reason>"`
  or the console Flags toggle (in-flight `REBASING` rows fall back to `NEEDS_REBASE` on the
  next tick; a pushed branch is left as pushed, never reverted).
- Phase C: `bin/jobs-client.sh flag-set merge-conductor-merge on "<reason>"`, remove the
  sweep line from `cron/hub.cron` (rendered onto the hub by `update-runners.sh`),
  `bin/jobs-client.sh flag-set conductor-owns-merges on "<reason>"`.
  Rollback: `bin/jobs-client.sh flag-set merge-conductor-merge off "<reason>"` and
  `bin/jobs-client.sh flag-set conductor-owns-merges off "<reason>"` (or the console Flags
  toggles), and restore the sweep line.
- Why `flag-set`, not `touch`/`rm`: both it and the console write the `pause_flags` row,
  and since #1580 (BH-1370) an active row recreates a missing `flags/<name>` file on the
  next `flag_active` read, so a hand `rm` does not last. `tests/flag-row-kill-switch.bh-1629-test.sh`
  pins the same row-over-file rule for the `automerge-disabled` readers.

## 10. Non-goals and risks

- **Rebasing a branch a human hand-edited.** The conductor only rebases PRs whose approval
  is bound to the current head (a hand edit after the approval is `HEAD_MOVED`, which buys a
  re-review, not a rebase), and the explicit lease refuses to push over a head it did not
  read. A branch someone is actively pushing to will simply fail the lease and be retried.
- **Double-merge with a human.** Every merge re-reads the PR immediately before the call
  and uses `--match-head-commit`; a PR merged by a human between the read and the call
  fails the call, and the next tick records `MERGED by:human`.
- **Two conductors.** The lock, plus phase A/B running alongside the sweep by design (the
  sweep still merges; the conductor observes and, in B, only rebases and re-reviews,
  rebinding so the sweep's head-bound check passes).
- **Cost.** One Fable re-review per `HEAD_MOVED`. From `logs/cost.csv`, stage `review` on the
  claude lane over the last 14 days: n=63, mean $4.14, p50 $4.02, p90 $6.10. At today's rate
  of moved heads (the sweep's `state/headbound-alerted.txt` holds 2 (PR, head) pairs and
  its log 6 head-bound parks in total, as of 2026-09-12) that is well under $30/day
  fleet-wide, bounded by the one-review-per-(PR, head) rule, by the patch-id rebind (a rebase
  now costs nothing at all) and by `MC_REREVIEW_PARALLEL` (8 jobs at once, fleet-wide).
  `MC_REREVIEW_DAILY_CAP` defaults to **0 = unlimited** since 2026-09-14: a per-project cap
  of 6 was a spend guard from when one re-review blocked the whole tick, and it is what left
  seven approved project-5 PRs waiting overnight. An operator who sets it still gets exactly
  the old behaviour.
- **Not in scope:** external PRs (review-prs keeps them until phase C's scope extension);
  merges on projects with a tightened review gate (`review_tighten_active` → `BLOCKED_HUMAN
  reason=tightened`, same as the sweep's skip but visible); anything that writes to a
  product database; **reopening a PR the conductor did not close itself** — the ONLY
  reopen in this lane is the second half of `mc_kick_ci`, which reopens the PR it closed
  microseconds earlier to fire CI (section 4), and nothing anywhere reopens a PR closed by
  a human, by `bin/blocked-resolver.sh`'s `ABANDONED` rung, or by GitHub; migration apply (`MIGRATION GATE` records go
  `BLOCKED_HUMAN reason=migration-gated` only when the SQL is classifier-flagged, exactly
  the sweep's split — allowlisted SQL merges and `migration-autopilot.sh` applies it).
- **Console change owed** (source in `console-ui/`): a PRs screen (or a section of Kanban)
  reading `GET /api/ledger?kind=pr_state`, one row per key with `status`, `updated_at`
  (age), and from `detail`: `url` (link), `head_sha`, `reviewed_sha`, `verdict`,
  `merge_state`, `reason`, `record`. Sort by age desc; `BLOCKED_HUMAN` rows first. No worker
  change: the endpoint already lists whole rows by kind.

## 11. What is on this branch (phase A shipped, B/C code behind flags)

1. `bin/lib/merge-conductor-lib.sh`: the pure classifier `mc_classify` (thirteen words in,
   `STATE<TAB>reason` out), `mc_verdict` (the sweep's lookup order), `mc_ci_state` (the
   review-prs actions/runs read), `mc_discount` (the sweep's green-run discount, project-4
   excluded), `mc_iron_law_scan` (the sweep's block, lifted verbatim), rows
   (`state/merge-conductor/pr-state.tsv` mirror + `job_ledger_put pr_state`), transitions
   (one log line per change), budgets (one alert per (PR, state entry); BLOCKED_HUMAN
   daily), and the three actions: `mc_rebase` (merge main into the branch, the train's
   package.json/markdown resolvers, typecheck + unit when the hub clone has `node_modules`,
   `--force-with-lease=<branch>:<sha-read>`, rebind), `mc_rereview` (the run-build HEAD-BOUND
   prompt through `bin/agent-call.sh review <project> "$REVIEW_MODEL"`, file-backed diff,
   fallback-lane APPROVE never rebinds), `mc_merge` (`--squash --match-head-commit`, verified
   by re-reading `state`). Since 2026-09-14 also the detached re-review job machinery
   (`mc_rereview_spawn` / `mc_rereview_run` / `mc_rr_state` / `mc_rr_running` /
   `mc_rereview_gc`) and the patch-id rebind (`mc_patch_id`, `mc_patch_id_remember`,
   `mc_patch_id_rebind`); `mc_row_put` writes the row file under its own `flock` because
   projects now tick in parallel.
   Since W2-D (2026-09-14) also the merge funnel's two read-only tests, both of which touch
   nothing and both of which answer "take today's expensive path" on any doubt:
   `mc_merge_tree` (+ `mc_git_has_merge_tree`, the git-2.38 guard) and `mc_no_overlap`
   (+ `mc_pr_files` / `mc_pr_files_gc`, the per-head file-list cache), over the shared
   authed-checkout chooser `mc_funnel_repo`.
2. `bin/merge-conductor.sh`: lock, the flag truth table, `fleet.conf` enumeration on the
   `gh-repo-token` token, the open-PR pass, the closed-unmerged pass, actions behind flags
   with per-tick-per-project budgets (`MC_REBASE_BUDGET` 2, `MC_REREVIEW_BUDGET` 2,
   `MC_MERGE_BUDGET` 5), the detached re-review knobs (`MC_REREVIEW_PARALLEL` 8,
   `MC_REREVIEW_TIMEOUT_SECS` 2700, `MC_REREVIEW_DAILY_CAP` 0 = unlimited) and the patch-id
   rebind before the classifier. The merge funnel's two callers live here too:
   `merge_tree_clean` (the `NEEDS_REBASE` arm, capped at `MC_MERGE_TREE_MAX`) and
   `rebind_no_overlap` (the elif after `rebind_patch_id`). Each project ticks in its own background subshell, and each PR of it in a
   worker under `locks/merge-conductor-<project>-<pr>.lock` (section 2.1). The scan and the
   pre-arm dispatch run only once everything cheaper says READY, and pre-arm only in merge
   mode (it dispatches a workflow). `FLEET_CONF` is pointed at `$HARNESS/fleet.conf` so a
   scratch tree drives a scratch fleet.
3. `cron/hub.cron`: the `*/5` line beside the sweep's (an operator line: the hub has no
   fleet-managed block because it owns no fleet.conf project; `tests/cron-fleet-parity-test.sh`
   renders the hub byte-identical to its base). `bin/harness-sync.sh` rsyncs `bin/` wholesale,
   so `bin/lib/` rides along; the live hub crontab is re-rendered by `update-runners.sh`.
4. `tests/merge-conductor-test.sh` (111 assertions): every state reachable from words; the
   issue-number rule (record KEY first, branch fallback); the
   sweep discount; one log line per transition and none on a quiet tick; a budget alert once
   per entry, none inside budget, naming the URL; the scan skips test files; then the whole
   script against a stubbed `gh`/`curl`/`agent-call`: READY, HEAD_MOVED, WAIT_REVIEW, a hand
   PR ignored, closed-unmerged rows (issue-open alerts, board project does not), ledger PUTs
   as `kind=pr_state` with `owner/repo#N` keys, a second tick logs nothing new, and NO write
   verb under observe-only, under the kill switch with both flags on, under the observe pin,
   and with merge-without-actions; finally merge mode lands the READY PR with exactly
   `--squash --match-head-commit <head>`, marks MERGED and writes the sweep's done-file.
   Section 4 drives the 2026-09-14 change with a stubbed `git`: a moved head whose patch-id
   is unchanged is REBOUND and merged with no job spawned; a changed patch spawns a detached
   job and the tick returns in under 15s while the (sleeping) review is still running; a
   `done` job with APPROVE is consumed once, never twice; a job past
   `MC_REREVIEW_TIMEOUT_SECS` is failed and takes the no-verdict path; an unset
   `MC_REREVIEW_DAILY_CAP` spawns the 7th re-review of the day and a set one still holds it
   back; and a held per-project lock skips that project only.
5. `tests/merge-funnel-test.sh` (46 assertions, W2-D 2026-09-14) — the funnel, driven
   against a REAL bare origin with a clean branch and a conflicting one (the fake remote url
   is pointed at it with `url.<path>.insteadOf`, so it is real git and no network). A
   stubbed git would only have proved the shell around `merge-tree` is spelled right, which
   was never the half in doubt. It covers: `mc_merge_tree` clean / conflict (naming the
   path) / rc-2 on an unknown sha, the git-2.38 guard refusing 2.30; a whole tick leaving a
   clean head alone and spawning nothing, `MC_MERGE_TREE=0` rebasing it exactly as before, a
   genuinely conflicting head still rebased, and the `MC_MERGE_TREE_MAX` cap firing on the
   third clean observation; `mc_no_overlap` rebinding a docs-only merge, refusing one that
   touched a file the PR edits, refusing a head that carries a NEW commit, and caching the
   file list to one API call per head; the same answers through a tick, including
   `MC_OVERLAP_REREVIEW=0`; and `bin/plan-overlap.sh` plus `run-build.sh`'s not-before gate
   (section 4 of `docs/BUILD-CONCURRENCY.md`).
6. This doc, the **merge** row of `README.md`'s stage table.

Not yet exercised against a real repo: `mc_rebase` and `mc_rereview` (phase B code, flags
off). Their first live run is phase B's exit criterion, not a claim this branch makes.


## 12. The blocked-resolver: no work waits on a human review (2026-09-13)

> the operator, 2026-09-13 22:54Z: *"Can we change all these definitions that require a human / the
> reality is I will never do a human review."*

Every lane in this harness had the same escape hatch, and every one of them used the same
words: park the work, write a line asking somebody to look. Nobody was ever going to. So the
park was the terminal — the ticket did not ship, and nothing said so out loud. That is not a
staffing problem, it is a design defect: a state machine with a state nothing transitions out
of is a state machine with a leak.

`bin/blocked-resolver.sh` (hub cron, minute 4,14,24,34,44,54 — offset from the conductor's
`*/5` and the sweep's `6,16,...`) is the transition out. It drains, per project:

| Source | What it reads |
|---|---|
| the conductor | `state/merge-conductor/pr-state.tsv` rows in `BLOCKED_HUMAN` whose reason `mc_resolver_owns` (this is also where the merge sweep's iron-law park arrives, because the conductor classifies the same PR) |
| the conductor's hand-off LOG | `logs/merge-conductor.log` lines reading `<key> BLOCKED_AGENT <reason> … handed to bin/blocked-resolver.sh … <url>`, for a PR still OPEN on the head the hand-off named whose row has since moved off `BLOCKED_HUMAN`. The row is no longer the only record (2026-09-14): a hand-off the conductor used to re-classify away 22 seconds later was invisible to this lane, and rows parked before `mc_handoff_sticky` shipped still need recovering. Deduped against the row source by `(slug, num, head)`, bounded to the last `BR_HANDOFF_MAX_AGE_SECS` (48h), and the already-merged guard runs on it like every other candidate. The budget line "…handed to bin/blocked-resolver.sh, **not paged**: <url>" is deliberately not matched — it is an age report on a row that is still parked, which the row source already sees |
| the pool | `build_queue` rows closed `failed` with "died N times" / "deferred N times", plus the `state/build-queue/<p>/<key>.failed.json` fallback for when the worker is down |
| build records | `RESULT` starting `REVIEW_BLOCKED` (test-tamper, reproduction-gate, intent-gate), `PLAN_MALFORMED`, `BUILD_DEAD`, and `PLAN_BLOCKED` **on GitHub-Issues lanes only** |
| review-rescue | records it retired: `.review-rescued` on a still-blocked record, and a re-scan that found a real deletion |
| **the rebuild this lane started** (`br_from_rebuilds`, 2026-09-16) | `state/blocked-resolver/<p>/<cap-key>.json` records with no outcome whose LAST attempt is `rebuild-fresh` — the answer is whichever `RESULT` arrived after that attempt, read from the hub build dir (`pool-…`, `fly-…`, `<project>-<KEY>-…` including the relayed `-remote…` copy) or, with no dir at all, from the pool queue row bin/fly-pool.sh closed `done` with the RESULT line as its reason |
| **the review lane's own verdict** (`br_from_reviews`, BH-872, 2026-09-18) | GitHub itself: for every open harness-authored PR (`harness_pr_list`) updated within `BR_REVIEW_LOOKBACK_SECS` (172800 = 48h), the NEWEST row in `repos/<slug>/pulls/<n>/reviews` that is by a harness author AND carries bin/review-prs.sh's footer (`Automated harness review (Fable) of `) AND whose `commit_id` is the PR's CURRENT head — and only when that body's own `VERDICT:` line reads `REQUEST_CHANGES`. Behind `gh_budget_low` and LAST in `br_candidates`, so review candidates never starve the other four out of `PER_TICK`. A draft PR, an external author, a review without the footer (that is a HUMAN's changes-requested, and it is for a human), a footer review at an OLDER commit, and an `APPROVE` posted after the block are all non-candidates; an unreadable reviews list is logged and consumed as nothing, never read as "no review" |

A `REVIEW_BLOCKED` record is `bin/review-rescue.sh`'s first — it re-runs the gate and can re-open
the PR for a build that was only ever blocked by a scanner bug, which is cheaper than any rung
here. So this lane waits for that lane's `.review-rescued` marker, with a 6-hour floor for the
case where `flags/review-rescue-disabled` means the marker will never arrive. Everything else
waits 90 minutes, which is the same floor review-rescue uses.

### The ladder

**The rungs, in order (2026-09-15).** 24 hours of `logs/blocked-resolver.log` before this:
**121 rebuild-fresh outcomes, ZERO fix rounds, one ABANDONED.** A rebuild is plan + execute +
review — $20-40, the most expensive thing this lane can buy — and it was the DEFAULT answer to
a rebase conflict and to red CI, which are the two cheapest things in the harness to actually
fix. So a park that is about a BRANCH now climbs:

| Rung | What runs | Cost | When it is skipped |
|---|---|---|---|
| **1 MECHANICAL** (`br_mechanical`) | `mc_rebase`: merge current `main` into the branch in the authed clone, deterministic conflict resolution, the hub's typecheck/unit gate, push under an explicit lease, rebind the approval. Nothing to merge → one `gh run rerun --failed` of every failing run on the head | no model, no tokens | a `review-blocked` park (merging main answers nothing a reviewer asked) and an `orphaned-parent` one (merging main does not take the dead parent's commits out) — `br_skips_mechanical` |
| **2 FIX ROUND** (`br_fix_round`) | one execute-stage agent call in a worktree **of the existing branch**, briefed with whatever evidence exists — the reviewer's posted findings, the conflict `origin/main` leaves in the tree (markers and all, left in place rather than aborted), and the failing job's log (`br_ci_log`), and for an `orphaned-parent` park the dead base branch plus the commits of it this branch still carries (that class merges no `origin/main` at all: `origin/main` arrives with the rebase the brief asks for) — then the repo's own typecheck + unit **in the foreground** and `--force-with-lease` | one execute call | when there is genuinely nothing to brief with: no findings, no conflict, no readable failing job. A rung that cannot START (no clone, no branch, a failed `worktree add`) is `br_setup_blocked` — no counter, no rebuild, no close, retried next tick || **3 REBUILD FRESH** (`br_rebuild_fresh`) | close the stale PR, mark the record superseded, enqueue the same ticket at attempt 0 against current `main` | a whole build | never — it is the last rung, capped at `BR_MAX_REBUILDS` (3), then `ABANDONED` |

#### Rung 1 resolves the conflicts nobody wrote (2026-09-16)

On 2026-09-16 seven of project-5's fourteen open PRs were `DIRTY`, and the conductor's own
`MERGE_TREE conflict` lines said what over:

```
#1634 MERGE_TREE conflict on fc70dd46 (Auto-merging .harness/specs/TK-1561/plan.md
  CONFLICT (add/add): Merge conflict in .harness/specs/TK-1561/plan.md
  Auto-merging docs/build-log/waves/TK-1251.md  CONFLICT (add/add) ...
#1645 MERGE_TREE conflict on 64b4d2d3 (Auto-merging docs/build-log/waves/TK-1605.md
  CONFLICT (add/add): Merge conflict in docs/build-log/waves/TK-1605.md ...
```

#1634's branch is `ticket/TK-1602`. Neither of those files is TK-1602's. They are **harness
output** — one wave doc and one plan per ticket, written by the build, never hand-edited — and
the branch was cut from a base that predates TK-1251 and TK-1561 landing. It carries a fossil
copy of THEIR artefacts; the siblings merged first; git saw two unrelated additions at one path.
There is nothing to reconcile. Left alone, each of these walked the ladder to a fresh rebuild
($20-30 and an hour), and **TK-1529 was ABANDONED after three rebuilds that each hit the same
fossil again**.

So `mc_rebase`'s conflict pass (now `mc_resolve_conflicts`, extracted so the fixture can drive
it against a real merge) resolves a conflicted path whose glob is in
**`config/generated-paths.conf`**:

| The file's ticket key | Side taken | Why |
|---|---|---|
| **this PR's own ticket** | `--ours` (the branch) | the file is the output of the commits under review |
| **another ticket** | `--theirs` (`main`) | the branch's copy is a fossil from a stale base |
| **no ticket key in the path** | neither — a real conflict | a hand-written file under one of these prefixes is safe |

The allowlist ships with exactly two entries, and they are documented in the file itself:

```
docs/build-log/waves/*.md
.harness/specs/*/
```

**One guard on top of that rule, and it is not optional.** Not every file under these globs is
strictly one ticket's: `docs/build-log/waves/TK-1251.md` is a PARENT wave's narrative and each
of its five children appends its own section. If the BRANCH's copy mentions this PR's ticket
and `main`'s does not, the branch is carrying work that exists nowhere else, and taking main's
copy would silently delete this build's output — worse than the conflict it was avoiding. That
case stays a real conflict. On all six of the DIRTY project-5 branches the guard is a no-op
(none of their fossil copies mention their own ticket), which is what a guard on the dangerous
case should look like.

Four things keep this narrow:

* **It is tried before the `*.md` union resolver**, which is the whole point. Wave docs *are*
  `.md`, and the union would have glued two unrelated tickets' documents into one file and
  called it merged.
* **Every path outside the conf stays a real conflict** and goes to rung 2 with the FULL
  conflict list as its brief — `src/lib/engine/*.ts`, `prisma/schema.prisma` and the rest are
  untouched by any of this.
* **The PR's ticket key comes from its branch** (`ticket/<key>` with an optional `-rN`), so a
  branch that is not a build branch — `design/…`, `mergify/…` — yields no key and turns the
  mechanism off entirely for that PR.
* **The conf is the allowlist.** `bin/lib/merge-conductor-lib.sh` carries the same two entries
  as `MC_GENERATED_PATHS_DEFAULT` so a pool image (which bakes `bin/` and not `config/`)
  behaves the same, and `bin/harness-sync.sh` + `bin/fleet-propagate.sh` carry `config/` to
  every box. Change the conf and the default together.

**The one generated file that needs a REBUILD and not a side (BH-868).**
`docs/verification-map/README.md` is generated by `bin/verification-map-build.sh` from
`docs/verification-map/index/*` and `docs/verification-map/entries/<KEY>.md`, so neither
`--ours`, `--theirs` nor the union is a correct answer for it: union glues main's generated
table onto a PR's hand-edited one and pushes a head on which the CI `--check` step exits 1.
`mc_resolve_vmap_readme` is tried for that exact path before the `*.md` union case; it moves
the rows the PR APPENDED into `entries/<TICKET>.md`, takes main's README, rebuilds it and
asserts `--check`. Anything but a pure row append — an edited or removed row, an added header
or prose line, a duplicate entry target — DECLINES, and a decline falls straight through to
today's union resolver rather than failing the rung, so a repo without the build script or a
branch with no ticket key behaves exactly as it did before. A decline also RESTORES the tree
it found — the README with its conflict markers, and no `entries/<KEY>.md` left behind for the
reused scratch clone to sweep into the next PR — which is what makes that fall-through
actually possible. `logs/merge-conductor.log` names which happened, with the core's own rc and
reason on a decline.

`.gitattributes` on main used to union that same path (BH-865), so most merges of main did not
CONFLICT on the README at all: the union driver glued the two tables and the merge was clean,
below the conflict resolver entirely. `mc_rebase` therefore also calls
`mc_resolve_vmap_clean_merge` on the clean-merge path. It does nothing unless
`bin/verification-map-build.sh --check-committed` is already out of sync, and otherwise runs the
same core against `origin/main` and commits the repair before the push; a decline leaves the
merge exactly as git made it. Entry: `docs/verification-map/verification-map-retrofit.md`; the
operator CLI for the same core is `bin/verification-map-retrofit.sh`.

**BH-1175 retired all of this FOR THIS REPO, and kept it for the others.**
`docs/verification-map/README.md` is no longer committed here, so it cannot conflict, the union
attribute is gone from `.gitattributes`, and both repair paths disarm on their own first guard
(no README in the tree). They stay in the library because a target repo that copies the BH-798
layout still commits its index and still needs them — which is why their trigger moved from
`--check` to `--check-committed`: plain `--check` now grades the SOURCES, and would answer "in
sync" for a glued README and retire both repairs silently. Entry:
`docs/verification-map/verification-map-no-commit.md`.

`tests/generated-path-conflicts-test.sh` builds a real repository, makes the real add/add
merge, and asserts on the bytes left in the tree — including that a conflict in real code is
still a conflict and that removing a glob from the conf switches the rule off.

**What this does and does not buy, measured on the six DIRTY branches of 2026-09-16.** Driven
against a real clone of `example-org/project-5`:

| Branch | Auto-resolved | Real conflicts left |
|---|---|---|
| `ticket/TK-1602` | `.harness/specs/TK-1561/plan.md`, `docs/build-log/waves/TK-1251.md` | 5 (two `src/app/credits/*`, two tests, `tasks/platform/waves/TK-1251.md`) |
| `ticket/TK-1601` | the same two | the same 5 |
| `ticket/TK-1608` | `docs/build-log/waves/TK-1605.md` | 1 (`tests/level2-unit/org-blueprint.test.ts`) |
| `ticket/TK-1606` | `docs/build-log/waves/TK-1605.md` | 1 (the same test) |
| `ticket/TK-1610` | none | 2 (`src/lib/engine/org-blueprint.ts` + its test) |
| `ticket/TK-1529-r2` | none | 1 (`src/lib/engine/analysis-config.ts`) |

**None of the six is unblocked by this rule alone** — every one of them also carries a genuine
code conflict, so rung 1 still returns rc 1 and rung 2 still gets them. What it removes is the
generated-path noise from the merge and from the fix round's brief, and it fully resolves the
PRs whose ONLY conflicts are these paths: #1592's `MERGE_TREE` line was
`docs/build-log/waves/TK-1251.md` and `tasks/platform/waves/TK-1251.md` and nothing else. That
second glob is the documented, not-yet-enabled candidate in the conf — only project-5 has the
directory and nobody has confirmed the harness is its only writer.

#### The slug was always in the URL (2026-09-16)

The same day, both branch rungs were unreachable for a different reason. Each asked
`fleet-conf.sh <project> repo` for the slug and gave up on an empty answer — printing, in the
same line, the URL that contains it:

```
project-5/example-org-project-5-1645 [conflict-unresolvable]: no repo/branch/head for
  https://github.com/example-org/project-5/pull/1645 — nothing mechanical to try, FIX ROUND
project-5/example-org-project-5-1645: no repo/branch for
  https://github.com/example-org/project-5/pull/1645 — REBUILD FRESH instead
```

One second apart, on #1542 #1556 #1526 #1592 #1630 #1634 #1645. Rung 1 could not run and rung 2
could not run, so **REBUILD FRESH was the only rung that ever fired.**

`br_slug_of_url` takes the owner/repo out of the URL (refusing anything that is not a PR URL —
`mc_slug_of_url`'s sed echoes its input unchanged on no match), and `br_pr_ref` returns
`<slug> <branch> <head>` for both rungs. The empty read is **re-tried under the repo's own
token**, because that is the other half of the same bug: `gh-repo-token.sh` exists precisely
because the hub's default PAT 404s on `example-org/project-5`, and `gh pr view` with it answers
an empty string and rc 0 — which the old code read as "this PR has no branch". The head is
optional: rung 1 needs it for its push lease and checks for one itself, rung 2 reads its own
lease off `origin/<branch>`, so a sha that will not read must not cost rung 2 the branch it can
have. A park that genuinely has no branch still cascades exactly as before, and the line it
writes now names the slug it derived and re-read under.

`br_ladder_class` decides which parks climb, and it is a pure function the fixture drives:

| Class | Reasons | Ladder |
|---|---|---|
| `rebase-conflict` | `conflict-unresolvable`, `rebase-gate-red` | mechanical → fix round → rebuild |
| `ci-red` | `red-ci-twice`, `red-twice`, `queue-ejected-twice` | mechanical → fix round → rebuild |
| `review-blocked` | `head-not-reapproved` | fix round → rebuild |
| `orphaned-parent` | `orphaned-child` | fix round → rebuild |
| *(no class)* | `merge-failed-twice`, `queue-enqueue-failed-twice`, `reproduction-gate`, `intent-gate`, pool died-twice, pool deferred-max, rescue giving-up, `plan-malformed`, `plan-blocked` (issues lanes), **`build-dead`** | rebuild fresh, directly |

`build-dead` is the one that must NOT climb: the machine went away with the work, so there is
no branch to merge main into, no findings to fix and nothing to brief an agent with — a ladder
entry for it would buy two empty rungs before doing the only thing that can work.

`ci-red` is non-flaky **by construction**: the conductor forgives a red whose every failing
test is a known flake (`mc_flake_rerun`) and re-runs any other red once (`mc_red_rerun`) before
it parks the head `RED_TWICE`, so a red that reaches this lane has already survived both.

#### The rung finishes: a rebuild's own outcome is consumed, and the ticket is told (BH-530, 2026-09-16)

Rung 3 closed a PR and enqueued a fresh build, and then nothing ever asked how that build
ended. project-5 #1645: rebuild enqueued 14:24Z, the fresh build ended `DECOMPOSE_FAILED` at
14:39Z, and the ticket sat untouched for hours — no rebuild 2, no abandon, and a board whose
last word was still "Built and opened for review". #1642 (`PLAN_BLOCKED`) and #1626
(`REVIEW_BLOCKED`) are the same shape. The other sources could not see it either: the original
record is marked superseded before the enqueue precisely so it is not re-offered, and
`br_from_builds` waits 90 minutes, reads `PLAN_BLOCKED` only on an issues lane, and
`DECOMPOSE_FAILED` never.

So the rebuild's terminal is its own source (`br_from_rebuilds`, first in `br_candidates`) and
`br_rebuild_outcome` is the pure classifier the fixture drives:

| The rebuild's `RESULT` | Reason | Action |
|---|---|---|
| `PR_CREATED` / `RESULT_UNVERIFIED PR_CREATED` / `PR_MERGED` | `rebuild-landed` | recorded and remembered, nothing spent, nothing sent — the conductor owns the new PR |
| `BUILD_DEAD` | `rebuild-build-dead` | `rebuild-fresh`: the machine went away, so it spends the NEXT rebuild counter |
| `DECOMPOSE_FAILED` | `rebuild-decompose-failed` | **`abandon-rebuild`** |
| `PLAN_BLOCKED` | `rebuild-plan-blocked` | **`abandon-rebuild`** |
| `REVIEW_BLOCKED` | `rebuild-review-blocked` | **`abandon-rebuild`**, but only once `.review-rescued` exists, `flags/review-rescue-disabled` is on, or the RESULT is 6 hours old — the same floor `br_from_builds` uses, because `bin/review-rescue.sh` can still rewrite that record to `PR_CREATED` and abandoning under a live rescue would throw a PR away |
| anything else (`BUILD_DEFERRED`, `DECOMPOSED`, `PLAN_MALFORMED`, …) | — | not consumed: those belong to the lanes that own them today |

`abandon-rebuild` (`br_abandon_rebuild`) is `br_abandon` with a why that names the real outcome
and the artifact — "the fresh rebuild ended DECOMPOSE_FAILED (…/decompose-run.txt) — that is a
ticket-level stop, another rebuild would end the same way" — so the parked PR is closed if it
is somehow still open, its conductor row moves to `ABANDONED`, the queue row closes `failed`,
one ALERTS line is written, and then **the ticket itself is told, once**
(`br_ticket_comment`: a `gh issue comment` on an issues lane, the same `POST
…/tickets/<id>/comments` `bin/board-closeout.sh` makes on a product board). The marker
`state/blocked-resolver/<p>/<ck>.rebuild-commented` is written BEFORE the post and never
retried: a client ticket commented twice about one stop is the worse failure, so a refused post
is a log line plus one lane alert naming the ticket and the artifact.

**And a `nokey` refusal is a spent attempt, not a free one.** project-5 #1634 answered
"no ticket key — cannot enqueue a fresh build" at 14:04Z and then answered it identically every
ten minutes for three hours. The branch, the title and the record are all read before that
refusal, so nothing about the next tick changes the answer: `br_enqueue_fresh` returns rc **2**
(deterministic refusal) rather than rc 1 (an enqueue that failed THIS time — no ticket id, a box
that would not answer, still free and still retried), and rc 2 spends a rebuild counter. The
third one is the cap, and the `ABANDONED` line says why: no ticket key could be derived from the
PR branch, its title, or a build record.

**And an enqueue that FAILED (rc 1) is really retried (BH-488).** "Retried next tick" was a
sentence, not a mechanism. Rung 3 closes the PR, marks the record superseded and releases the
conductor's hand-off BEFORE it enqueues, so when the enqueue answered rc 1 the ticket landed in
a state no source could see: the conductor row was CLOSED, the record was marked, the queue
never got a row, and `br_from_rebuilds` only re-offered a last attempt of `rebuild-fresh`.
project-5 #1315/#1383 sat seven hours that way. Now:

- `parked_url` and `parked_rec` are written on the record **before** the enqueue, because
  everything above that line is already irreversible and those two fields are the only way back
  to the ticket.
- a state file whose last non-hold attempt is `rebuild-fresh-failed` (outcome `""` or `HELD`) is
  re-offered by `br_from_rebuilds` as reason **`rebuild-enqueue-failed`** → action
  **`rebuild-retry`** (`br_rebuild_retry`), which re-tries the ENQUEUE only: same MERGED guard,
  same hold gate, same `BR_MAX_REBUILDS` cap, and it never closes a PR or re-marks a record that
  rung 3 already did.
- `br_rebuild_settle` is the one place that reads what an enqueue answered, for both rungs.
  rc 0 spends the rebuild counter, resets `enqueue_failures` and removes the page marker; rc 1
  spends nothing, appends `rebuild-fresh-failed` **once per episode** (the `hold-unreadable`
  precedent — 144 identical entries a day would bury the attempt list) and climbs
  `enqueue_failures` every tick.
- at `BR_ENQUEUE_ALERT_AFTER` consecutive failures (default 6 = one hour of ticks) the lane
  pages ONCE, guarded by `state/blocked-resolver/<p>/<ck>.enqueue-alerted`, naming the ticket,
  the closed PR, the count and the real reason (`BR_ENQUEUE_WHY`). It is not a cap: an enqueue
  that cannot be made is a machine problem, so it is retried for free for as long as it takes
  and never turns into `ABANDONED` on its own.
- **one enqueue per ticket per tick.** The drain dedupes on the rkey, and a retry row keys on
  the cap key (`tproj-TK-9`) while a conductor row for the same PR keys on the number
  (`o-tproj-9`). `br_one` now also dedupes on `<project>/<cap-key>` through a tick-scoped
  `TICK_DONE` file: the second row for a ticket already acted on this tick answers rc 3 — no
  rung, no `PER_TICK` slot, one log line. The key is written AFTER the dispatch and only when a
  rung really ran, so observe mode (which takes none) mutes nothing, and the check sits after
  the `-> <action>` candidate line, so a muted row is never hidden from the log.

**Caps are per TICKET** (`br_cap_key`), never per PR number: a rebuild produces a NEW PR, so a
ladder counted on the number restarts at zero on every rung and never ends.
`BR_MAX_MECHANICAL` (1), `BR_MAX_FIXROUNDS` (1), `BR_MAX_REBUILDS` (3), and `BR_LADDER=0`
restores exactly the pre-ladder behaviour — every branch reason straight to a rebuild.
The fix-round cap is read per REASON through `br_fix_cap`, so the review verdict gets its own
(the settings row `review.fix_rounds_max[.<project>]`, seeded 2, BH-7123 wave B; `BR_REVIEW_FIX_ROUNDS`
is the fallback when no row answers) while every other reason keeps `BR_MAX_FIXROUNDS`. **Every one of
these is a knob with a documented code default, never a constant** — set them in
`env/global.env`, which is the file the lane sources `set -a`:

| Knob | Default | What it bounds |
|---|---|---|
| `BR_REVIEW_FIX_ROUNDS` | 2 | fix rounds per TICKET for a `review-changes-requested` park (BH-4149). The second round exists because the reviewer's next verdict is about what the FIRST round pushed. **Since BH-7123 wave B** the settings row `review.fix_rounds_max[.<project>]` outranks it (`br_review_fix_cap`), `review.mode` cowboy/off reads 0, and at the cap the terminal is `br_cap_notes` — outcome `CAP_NOTES`: the stale harness `REQUEST_CHANGES` is dismissed, ONE notes-only lead re-review of the head is requested (scope token `review-level:cap-reached`, ledger row `review_cap <slug>#<pr>@<head>` = cap-reached; bin/lead-review.sh runs its demoter in cowboy mode for that one review, so it lands MERGE-WITH-NOTES) and ONE warn alert names the ticket. `br_abandon` is the terminal only when a standing finding is on the ALWAYS-BLOCK floor (`rl_line_blocks`), or a PERSON's `CHANGES_REQUESTED` stands |
| `BR_REVIEW_LOOKBACK_SECS` | 172800 (48h) | how recently an open harness PR must have been updated for `br_from_reviews` to read its reviews at all — the bound on that source's extra REST reads, alongside `gh_budget_low` |

#### Two shapes, and a contested path holds its losers (BH-579, 2026-09-17)

**The caps come in two shapes now, and the shape is a MEASUREMENT.** A two-line disagreement and
a 900-line one were walking the same ladder: one round of an agent and then three rebuilds. The
small one is worth a second round (the agent was close) and is not worth three rebuilds (a
two-line conflict that survived one rebuild will survive the next two); the big one is worth
exactly what it was.

| shape | `conflict_lines` | mechanical | fix rounds | rebuilds |
|---|---|---|---|---|
| **large** | unknown, **0**, or > `RESOLVER_SMALL_CONFLICT_LINES` | 1 | 1 (`BR_MAX_FIXROUNDS`) | 3 (`BR_MAX_REBUILDS`) |
| **small** | ≤ `RESOLVER_SMALL_CONFLICT_LINES` (300) | 1 | 2 (`BR_MAX_FIXROUNDS_SMALL`) | 1 (`BR_MAX_REBUILDS_SMALL`) |

`conflict_lines` is written by two measurements and kept as a MAX: the conductor's sidecar for
the parked PR (`mc_conflict_size_file`, written by `mc_rebase` when it hands back rc 1) and the
fix round's own tree (`mc_conflict_lines`). **Unknown is large** — the small shape has to be
earned, so nothing that was never measured changes behaviour. A stale small measure can only be
raised by a later large one, never lowered, which is the conservative side of a wrong answer.

**And a measured 0 is unknown, not tiny.** `mc_conflict_lines` counts `<<<<<<<`-bounded lines,
and a delete/modify conflict (`UD` — a sibling deleted or renamed a file this ticket edits) has
no markers at all, so an honest measurement of one of the *hardest* conflicts there is answers 0.
Reading that as a nought-line conflict would put exactly those tickets on the short ladder: one
rebuild instead of three, then `ABANDONED`. A 0 is therefore not recorded as a measurement
either (`br_note_conflict_lines`), so no record ever reads `conflict_lines: 0`.

**A failed fix round with rounds REMAINING ends the tick.** It logs `fix round N of M did not
land — fix round N+1 next tick`, keeps the `brfix/<ticket>` checkpoint branch (the next round
starts from what this one got done rather than buying the same tokens twice) and takes no other
rung. With no rounds remaining it cascades to the rebuild exactly as it always has.

**And a conflict that keeps coming back is CONTESTED.** TK-1529 was rebuilt three times and then
ABANDONED, and every rebuild hit the same conflict on the same file: siblings kept landing edits
to it while that ticket walked its ladder. Rebuilding against a path somebody else is still
moving buys the same conflict at full price.

So `bin/blocked-resolver.sh` remembers what it conflicts on. Every park records
`{at, pr, head, paths}` on the ticket (`.conflicts`), from three writers that already hold the
paths: the conductor row's raw reason (`conflict-unresolvable: a.txt`, parsed by
`br_paths_of_reason` — `CONFLICT`, `(content):`, `Merge`, `in` and `Auto-merging` never parse as
paths), `br_mechanical`'s rc 1 stdout, and the fix round's `--diff-filter=U`. One entry per
(pr, head): **the same PR on the same head re-offered is the same occurrence**, not a recurrence.

A hold is written when ALL of these hold: class `rebase-conflict`, reason
`conflict-unresolvable`, the next rung would be the rebuild, the ticket has no `.contested` mark
yet, and a path in this park also appears under a DIFFERENT (pr, head) of the same ticket (exact
match — `src/a.ts` and `src/a.tsx` are two files). Then, in this order:

1. the open-PR list is read ONCE for the whole hold creation — `harness_pr_list <slug> open` —
   and the competitor set is then computed **per recurring path**: `mc_pr_files` per candidate
   (cached per (PR, head), so the second path costs no API call), capped at
   `CONTESTED_PR_SCAN_MAX`; plus the tickets whose `plans/<project>-<KEY>/planned-files.txt`
   claims that path or a directory containing it. Per path is the point: a sibling touching only
   the SECOND contested file is a loser of that file's hold and of no other, and stamping the
   first path's losers onto every hold both missed it and parked PRs on a path they never touch.
   The winner itself and the winner's own rebuild (`ticket/<key>-rN`) are never losers, and a PR
   this harness did not author is not in the list at all. A scan that hits the cap says so in the
   log (naming the PRs it did NOT read, which are therefore NOT parked) and in the hold's own
   `why` — `scan capped at N of M` — so a partial hold is never read as a complete one;
2. `mc_contested_write` writes one hold per recurring path that HAS a competitor (§ the store,
   above); a recurring path nobody else touches gets no hold and one log line;
3. ONE record write marks the ticket `.contested` and grants `.fixround_bonus += 1` — the bonus
   is persisted BEFORE the round runs, so a crash cannot grant it twice;
4. each loser PR that HAS a conductor row moves to `BLOCKED_HUMAN contested:<path> (winner
   <KEY>)` — `<path>` being the first hold that named it — keeping its reviewed sha (a loser with
   no row is logged and left to the conductor);
5. `EVENT resolver_contested`, and the ticket takes the bonus fix round instead of the rebuild.

**Every failure here keeps today's rung**, with one log line each and nothing recorded as
contested: the PR list unreadable, nobody touching ANY of the recurring paths (no hold is written
for an empty competitor set — an empty hold protects nobody), a hold that will not write (any hold
written in that call is released again), or a park with no ticket key to name a winner. Observe mode and
`flags/automerge-disabled` write `WOULD` lines and touch nothing.

**The skip.** `br_one` asks `mc_contested_loser` for its PR before anything else and, on a hit,
answers with one line — `held: contested <path> (winner <KEY>)` — and nothing else: no rung, no
counter, no record, no hand-off release, and no GitHub call of its own (discovery's one
`repos/<slug>/pulls/<num>` head-branch read is paid by every candidate before `br_one` sees it).

**The release.** `br_contested_sweep` runs once per tick before the drain, takes no lock (every
write is a contract-atomic file op or a row transition the conductor's writer already
serialises) and is bounded by the number of holds:

| condition | why | alert |
|---|---|---|
| winner row `MERGED`, or no row and REST says merged | the path landed | no |
| winner row `ABANDONED` (also released by `br_abandon` in the same tick it abandons) | held for nothing | yes |
| no row and REST says closed-not-merged | same shape as abandoned | yes |
| `now - created >= ttl` (the hold's OWN `ttl`, stamped from `CONTESTED_TTL`, 21600) | the window ran out | yes |
| no row and the read did not answer (`br_pr_state` rc 75/44) | unknown is not an ending | no — one `UNVERIFIABLE (HTTP …)` line, retried next tick |

The no-row arm is the only one that asks GitHub, and it asks through `br_pr_state` — the
resolver's own REST read (`repos/<slug>/pulls/<num>`, merged read off `merged_at`), never
`gh pr view --json state`: that is GraphQL, and the GraphQL bucket is the one that empties first
on these accounts — a sweep that cannot read the winner would leave every loser parked until the
TTL. Going through `br_pr_state` rather than a raw `gh api -q` also buys the three-answer
contract: only an rc 0 `merged`/`closed` ends a hold, and a 5xx or a rate limit leaves it in place
with the `UNVERIFIABLE (HTTP …)` line the rest of the file writes, instead of reading as
"not merged" in silence. The same rule is why
`mc_pr_files` pages `repos/<slug>/pulls/<num>/files` for the competitor scan, which buys up to
`CONTESTED_PR_SCAN_MAX` file lists for a single hold.

**A loser that lost TWICE is released by the LAST hold that named it.** One PR touching two
contested files is a loser on two holds while its row carries only one of the paths, so a release
moves a row only when no OTHER live hold still names that PR (`mc_contested_loser`, asked with the
hold being released excluded). Unparking it any earlier hands the conductor a PR that rebases
straight back into a path somebody else is still landing.

A hold whose `created`/`ttl` do not parse is **malformed, not expired**: it is not live (so it
holds nobody), it is left on disk as the evidence of a bad write, and it pages nobody. **A TTL
release is not a time kill** — it moves the losers back to `NEEDS_REBASE` and nothing in this
lane closes a PR on a clock. The next conductor tick reclassifies those rows.

Knobs, environment like every other cap: `RESOLVER_SMALL_CONFLICT_LINES` (300),
`BR_MAX_FIXROUNDS_SMALL` (2), `BR_MAX_REBUILDS_SMALL` (1), `CONTESTED_TTL` (21600),
`CONTESTED_PR_SCAN_MAX` (40).

**Cascading, and the cases that do not.** A rung that fails with EVIDENCE falls to the
next rung in the same tick: a real conflict, a red gate, an unverified fix round. A mechanical
rung that could not run AT ALL (`mc_rebase` rc 4 — no credential, a clone that would not clone,
a merge fatal such as `refusing to merge unrelated histories` off a shallow hub clone)
does **not** cascade: the fix round needs the same clone, so falling through would walk a
machine problem down to a fresh rebuild in one go. **And since 2026-09-16 it spends nothing
either** — rc 4 is `br_setup_blocked`, the same as a fix round that could not start, and the
next tick is offered the same free rung rather than the paid one. See the next subsection.

### No time kills, and a setup failure is not an event (2026-09-16)

**The order.** the operator, 2026-09-16: *"We shouldn't have rules that kill PRs because of time; it
should be event based."* No rule in this pipeline may close, abandon or rebuild a PR because of
elapsed time. Time may **page** — an overdue alert costs nothing and is read by a person — and
that is all it may do.

**What the audit found.** `grep -nE 'minutes|_MIN|MAX_AGE|budget|stale|cutoff|older than|age'`
over `bin/merge-conductor.sh`, `bin/blocked-resolver.sh`, `bin/merge-sweep.sh`,
`bin/jobs-watchdog.sh`, `bin/pipeline-health.sh`, `bin/unblocked-children.sh`: the only two
places in the fleet that close a PR are `br_close_pr`'s two callers in
`bin/blocked-resolver.sh` — the rebuild rung and `ABANDONED` — and **neither is reached by a
clock**. `NEEDS_REBASE`'s "30 minutes" is two clocks and both are alerts: `mc_budget`
(§5, one page per state entry) and `mc_ttl` (§5.1, one page per (PR, state, head) plus
`stuck_rekick`'s forget-the-attempt-and-rebase-again). `jobs-watchdog`'s `_MIN` thresholds
release ledger claims and close `pr-*` rows; `pipeline-health`'s `CLOSEOUT_AGE_OUT_H` stops
nagging about a board close-out. None of them touches a PR.

The one `close` a clock can reach is `mc_kick_ci` — the `WAIT_CI` stuck re-kick closes and
REOPENS a PR through the REST API to fire the repo's `pull_request` workflows, on a head with
no run at all. That is a retry spelled with two API calls, not a terminal: the PR is open again
in the same call, the row is untouched, and it happens once per head.

**What actually killed two finished PRs.** `cromford#489` at 12:04:57Z and
`cromford#465` at 01:44:26Z on 2026-09-16, both closed by the rebuild rung, and the log
lines are the whole story:

```
12:04:51Z ... mechanical rung still conflicts (bin/lib/merge-conductor-lib.sh) — FIX ROUND with the conflict in its prompt
          fatal: cannot change to '/root/repos/cromford': No such file or directory
12:04:53Z ... worktree add failed for origin/ticket/bh-438 — REBUILD FRESH instead
12:04:57Z closed https://github.com/example-org/cromford/pull/489 (Superseded by a fresh build …)
```

The hub has no `/root/repos/cromford` clone, so rung 2 could never run there. `worktree
add failed` and `no repo/branch` are facts about the **box**, not events about the **PR**, and
treating them as a failed fix round escalated straight to the rung that closes PRs. #465 took
the same two edges twice (01:44:26Z `worktree add failed`, 02:25:43Z `no repo/branch`) and
burned two of its three rebuilds.

**The rule.** `br_setup_blocked` owns everything that stops rung 2 before the agent runs:

| Edge | Before | Now |
|---|---|---|
| rung 1: `mc_rebase` rc 4 (no credential, no clone, a fetch that would not run) | the mechanical rung was **spent**, so the next tick took the paid rung | `br_setup_blocked` (rung 1 is still there when the box is fixed) |
| no repo/branch, after `fleet.conf`, the PR URL and the repo's own token have all been tried (`br_pr_ref`, §the slug was never missing) | REBUILD FRESH (close) | `br_setup_blocked` |
| no local clone at `$REPOS/<project>/.git` | *(fell through to `worktree add`)* → REBUILD FRESH | `br_setup_blocked`, named explicitly |
| `origin/<branch>` will not resolve after the fetch | REBUILD FRESH (close) | `br_setup_blocked` |
| `git worktree add` failed | REBUILD FRESH (close) | `br_setup_blocked` |

`br_setup_blocked` takes the rung it is blocking (`mechanical` or `fix-round`, which is the
word in its log line, its `EVENT resolver_setup_blocked` line and its
`mechanical-blocked` / `fix-round-blocked` attempt record). It spends **no** counter
(`br_record` with no bump field), closes nothing,
enqueues nothing, writes one `EVENT resolver_setup_blocked` line plus a `fleet_event` beat, and
pages **once per park** through `bin/lane-alert.sh` (the `br_nokey_alert` pattern — this lane
re-offers the same park every ten minutes, and a 144-a-day alert is one nobody reads). The
marker is `state/blocked-resolver/<project>/<ticket>.setup-alerted`, deleted the moment a rung
actually runs, so a later setup failure on the same park pages again. The next tick tries the
**same rung on the same branch**.

So the only ways to rung 3 are events, all of them about the PR: the agent RAN and produced no
verified commit (`agent rc`, a red typecheck/unit, an unresolved conflicted path), the push lost
its `--force-with-lease` (the head moved), there is genuinely nothing to brief with (no
findings, no conflict, no readable failing job), or `BR_MAX_FIXROUNDS` is spent. `ABANDONED` is
`BR_MAX_REBUILDS` spent. And the `NEEDS_REBASE` path into all of this is the conductor's own
rebase **result**: `merge_tree_clean` → stay put, the detached job's rc → `WAIT_CI` (pushed),
`conflict-unresolvable` (rc 1) or `rebase-gate-red` (rc 2) → this ladder, which fixes the
EXISTING branch first.

**Checkpoint branches are reused.** A fix round killed mid-flight leaves its work on
`brfix/<ticket>`; the next round takes that branch as its starting tree whenever it still
contains the PR head, rather than buying the same tokens twice. The push lease is the PR head
either way, and a round that finishes deletes its branch.

**Every rung transition is an event**: `EVENT resolver_rung <project>/<ticket> [<reason>] rung
N <name>` in `logs/blocked-resolver.log`, plus a `fleet_event` beat (`event: resolver_rung`,
and `resolver_abandoned` for the terminal). A ladder whose transitions are only prose is a
ladder nobody can count, and counting them is how the next "121 rebuilds, zero fix rounds" is
noticed in a day rather than in a month.

| Reason | Action | What it does |
|---|---|---|
| `iron-law`, `test-tamper`, rescue real-deletion | **ADJUDICATE** | one review-stage (Fable) call over the flagged lines with 30 lines of context, the plan, and the iron laws. Last line exactly `ACCEPT` or `REJECT`; the reasoning is posted on the PR or issue. One per key. `REJECT` on an iron-law hit drops into the fix round |
| `review-changes-requested` (BH-872, BH-4149) | **FIX ROUND, THEN ABANDON** | the review lane's verdict is an event with a consumer. Not a ladder class on purpose: rung 1 (merge main / re-run CI) answers nothing a reviewer asked for, and rung 3 (close the PR, rebuild the ticket) is the wrong shape for "change these three lines" — a hand-made harness PR may have no ticket to rebuild at all. So it is one fix round with the review BODY as the brief (`br_findings` reads the review, not the head-bound comment), keyed on **(PR, head sha)** in the record's `review_fix_heads[]` and appended BEFORE the agent runs, so a standing verdict re-offered every ten minutes buys exactly one round per head. `BR_REVIEW_FIX_ROUNDS` (2) rounds, a round that produced no verified commit, or a lead-blocked round that ended `fix-round-noop`, and the terminal is `br_abandon` through `br_fix_terminal`: the PR is closed with a comment listing what was tried, one `abandoned` attempt and outcome `ABANDONED` go on the cap-key record, one ABANDONED ALERTS line and one `blocked-resolver-abandoned:<project>:<cap-key>` beat go out, and the ticket is re-filed through the board. Nothing asks a person to push. The close comes before the stamp, so a refused close returns 75, records nothing, and is retried next tick. A head frozen in `noop_heads` is a candidate again, and `br_fix_round`'s frozen-head gate (above the (PR, head) dedupe, before any review read) sends it to the same terminal. Two edges from the #891 review still hold: a `DISMISSED` review row is skipped when the newest verdict is picked (rp_dismiss_own retracts the lane's own legacy block on a PR whose head it approved, and a round briefed off it would eject the queued PR); and an `ESCALATED` record written before BH-4149 stays terminal, skipped by `br_from_reviews` before the reviews read and by `br_one` as the backstop. Those records are not backfilled |
| `no-verdict` | **RE-ASK, AND NEVER CLOSE** | `mc_rereview` again, because nobody answered is not the same fact as somebody said no. APPROVE rebinds and unparks; BLOCK reclassifies to `head-not-reapproved` (the fix round next tick); **silence asks again on the next tick, up to `BR_NOVERDICT_MAX` (5) reads, and then stops spending and writes ONE `REVIEW LANE DOWN` ALERTS line. The PR is never closed and never rebuilt for it** (2026-09-16 — see below). A read that failed because the LANE failed (`mc_rereview` rc 2) spends no counter at all |

**SILENCE FROM OUR OWN REVIEWER NEVER CLOSES A PR (the operator, 2026-09-16; project-5 #1621).**
This rung used to buy ONE more re-review and, if that was silent too, hand the PR to
`br_rebuild_fresh` — which CLOSES the PR (`br_close_pr`) and enqueues a rebuild. On
2026-09-16 that is what happened to a finished, green, approved project-5 build: the box's
claude account was 429 `You've hit your session limit · resets 8am` for the hour, both reads
came back empty, and a full pipeline's work was closed and started again from scratch at
12:35:50Z. the operator's standing order is that no rule may close a PR on anything but a concrete
failed EVENT, and a review we never got is not an event of that PR. The rung therefore
re-asks, bounded by `BR_NOVERDICT_MAX`, and then says out loud (`br_lane_down_alert`) that
the REVIEW LANE is the broken thing, that the PR was left OPEN, and that clearing the lane
clears the park. `mc_rereview` rc 2 (the lane failed: account quota, dead ladder, a
non-Claude runner) spends no counter — a read we never bought must not count as one. It is
bounded on its OWN axis (`BR_LANEFAIL_MAX`, 5) so that "no counter spent" cannot become an
attempt bought every tick forever, and when the lane comes back the PR still has every one of
its `BR_NOVERDICT_MAX` reads waiting for it.

**`red-twice` reads rows in state `RED_TWICE`, not `BLOCKED_HUMAN` (2026-09-15).**
`br_from_conductor` accepts both words, `br_reason_of` maps the reason, and the hand-off log
recovery (`br_handoff_lines`) matches the `RED_TWICE` line shape as well as `BLOCKED_AGENT`.
It is a `ci-red` park, so it climbs the ladder above: merge main / re-run the failed jobs
first, then a fix round briefed with the failing job's own log — which is what made the rung
possible at all, since a red CI run posts no review findings for `br_findings` to read.

**ADJUDICATE outcomes.** `ACCEPT` on an iron-law hit writes `<record>/iron-law-accepted-<sha>`,
which both `bin/merge-sweep.sh` and `bin/merge-conductor.sh` honor — bound to the sha it judged,
for the same reason the head-bound approval is: a push after the ruling is code nobody
adjudicated. `ACCEPT` on a test-tamper block writes the `TEST-CHANGE:` justification the gate
reads: into the record's `plan.md` and resumes the build where the record is resumable, and
into `state/build-notes/<project>/<key>.md` otherwise — a pool record cannot be resumed (its
machine is gone; the hub holds only the relayed artifacts), so the ruling is carried into the
NEXT build, where `bin/run-build.sh`'s plan stage consumes it once. `REJECT` drops to the fix
round (iron-law) or a fresh rebuild with an explicit comment that tests are not removed to make
a build pass (test-tamper).

### The ticket key a rebuild needs (2026-09-15)

REBUILD FRESH enqueues a TICKET, so it needs that ticket's key — and a rebuild
that closes the stale PR and then cannot name the key leaves the ticket with no
owner at all. On 2026-09-15 that happened twice: project-5 #1124 (TK-775) at
06:14Z and #1136 (TK-1109) at 07:34Z were both closed, both logged *"no ticket
key — cannot enqueue a fresh build"*, and neither was rebuilt until the box
relaunched them by luck.

The key was never missing. Discovery (`br_conductor_emit`) asks `gh` for the
PR's head branch — `ticket/TK-775` — but it asks BEFORE `br_one` installs the
repo's own installation token, and `gh` with the default token answers *"Could
not resolve to a Repository"*: an empty branch, silently. The build record was
no help either, because `mc_record_for` only matches a `RESULT` whose first line
STARTS with `PR_CREATED`, and both of those read `RESULT_UNVERIFIED PR_CREATED …`.

So the key is derived a second time, in `br_one`, **inside the token**, before
any rung runs — the cap counts on it, the already-merged guard asks the board
with it, and the enqueue needs it.

**One resolver, and it names the source that won (BH-488).** There used to be
two orders: discovery read record → branch, the rebuild rung read branch →
title → record, and neither said which source had answered, so `derived TK-9
from the PR/record` left an operator with three places to look. `br_ticket_key
<project> <record> <branch> [title]` is now the single derivation — it prints
`<KEY><TAB><source>` and rc 1 when nothing carries a key — and
`br_derive_ticket_key` is the wrapper that FETCHES the branch and the title from
a PR `gh` can finally see, leaving the source word in `BR_KEY_SOURCE`. Sources,
in order:

| Source | word | Shapes read |
|---|---|---|
| the build record — the pipeline's own ledger | `record` | `ticket-meta.json` `.key` / `.ticket_key` first, then the dir name it wrote: `pool-<project>-<KEY>-<stamp>` / `<project>-<KEY>-<stamp>` |
| the PR's `headRefName` | `branch` | `ticket/TK-775` (what `bin/run-build.sh` cuts), `ticket/TK-716-r2`, `TK-1109-report-nav`, `TK-775`, `feat/TK-1617-fee-toggle` — only the segment after the last `/`, so the prefix never has to be enumerated |
| the PR title | `title` | `TK-775: …`, `[TK-1617] …`, `(TK-88) …` — at the FRONT only; a key mid-sentence ("supersedes TK-700") is a reference to another ticket, never this one |

The record is first because it is the one artifact written by the process that
KNOWS which ticket this is; a branch and a title are names somebody chose. The
winning source is logged both times it is asked: `tproj/o-tproj-9: ticket key
TK-9 from the build record` at discovery, and `discovery carried no ticket key —
derived TK-9 from the PR branch` in `br_one`. Discovery asks for no title — it
runs before the token is installed, so a second `gh` call there buys an answer
this box may not be able to read anyway.

All three read the same shape — 2-8 letters, a dash, digits, upper-cased — and
anything that does not match answers NOTHING rather than a guess: an invented
key buys a `bin/fly-pool.sh` quarantine or builds the wrong ticket. When all
three genuinely carry no key the enqueue is still refused, but it is no longer
silent: one `bin/lane-alert.sh` page per key (once, not every ten minutes)
naming the PR url and saying the ticket has no owner.

### ABANDONED

The terminal, and — apart from the no-key give-up above — the **only** thing in
this lane that alerts. It closes the PR, moves the
conductor row and the queue row to their terminals, marks the record, and sends one
`fleet_alert` listing every attempt with its reason and why it failed. It never says *human*,
*by hand*, or *for the operator*, because it is not asking for anything: it is the record of what an
agent tried.

### Idempotence and locking

Attempt counters live in `state/blocked-resolver/<project>/<ticket>.json` (`mechanicals`,
`fixrounds`, `rebuilds`, `adjudications`, `rereviews`, `outcome`, and the `attempts` list the
ABANDONED alert prints). One action per key per tick, taken under a **per-key** `flock` —
`locks/blocked-resolver-<project>-<rkey>.lock`. Never one global lock: a fix round holds its
lock for up to 90 minutes, and a global one would put the whole fleet's drain behind one slow
build, which is the same "nothing is moving and nothing says so" this lane exists to end.

The **scan** is single-flighted on its own lock, `locks/blocked-resolver-cron.lock`, taken with
`flock -n` at startup: cron ticks were stacking, several live at once rediscovering the same
parks, so an overlapping tick now prints one line to the cron log and exits without scanning —
dedupe, never a queue. That lock is released (and its fd closed, so no child inherits it)
*before the first rung runs*, which is why it does not become the global lock the paragraph
above refuses: it covers discovery and classification only, and the rungs still own themselves
through the per-key locks. (The other half of BH-642, the ~33k
`printf: write error: Broken pipe` lines in `logs/blocked-resolver-cron.log`, was the
`done < <(br_candidates)` process substitution the loop `break`ed out of; BH-980 already reads
the candidate list once into an array, so there is no pipe left to close early.)

Once a rung has run for a candidate that came from the conductor, this lane writes
`state/merge-conductor/handoff-released/<owner>_<repo>_<num>` (`mc_handoff_release`). That is
the third of the conductor's three release conditions (section 4): the PR is this lane's now,
so the conductor may classify it again on its next tick. Observe mode writes nothing — it took
no rung, and releasing a park it is not draining would put the PR straight back in the loop.

### The deterministic pre-pass, and the two bounds on a tick (BH-1457, 2026-09-22)

On 2026-09-22 this lane reported `candidates=785` and `reason=budget` on every tick. Of its
586 state records, **98 `RESOLVED_MERGED` and 79 `ABANDONED` were finished rows still being
offered** — an ABANDONED row is terminal inside `br_one` but is still discovered, counted and
read every ten minutes, and a RESOLVED_MERGED row spent a whole `BR_PER_TICK` slot plus a
handful of REST reads before `br_already_merged` answered what this lane had already written
down. Rungs ran in source order, so REBUILD FRESH was as likely to go first as a one-call
adjudication. And after `BR_PER_TICK` was raised 4 → 50, the 14:04Z tick ran 12 rungs in
**53 minutes** while every ten-minute cron exited on "another tick is live".

**`br_prepass` runs between `br_candidates` and `br_round_robin` and reads nothing but this
lane's own state files** — no model, no gh, no git, no jobs client, and ONE `jq` pass over the
whole record tree rather than four forks per candidate. It drops a candidate whose record is
ABANDONED, or RESOLVED_MERGED for this candidate's own url, announces each retirement ONCE as
`EVENT resolver_retired`, and gives every survivor a cost band: free (`mechanical`, `regen`) →
one call (`adjudicate`, `re-review`) → one agent round (`fix-round`) → a whole pool build
(`rebuild-fresh`, `rebuild-retry`). The band comes from `br_ladder_rung` over the TICKET's own
counters, so a conflict whose mechanical rung is spent sorts as the fix round it is. The cost
is a WITHIN-PROJECT key applied BEFORE the interleave: a global sort would undo BH-980, pinning
the tick to one project for ever and then paging STARVED for the project it parked.

**RESOLVED_MERGED retires exactly one thing: the park on the PR the resolve was about.** A
record whose `resolved_url` names a DIFFERENT PR does not retire, because a ticket can acquire
a new pull request. Neither does a candidate carrying NO url — `br_from_builds` always emits
`-` — nor a `rebuild-*` reason, which IS the rebuild reporting how it finished and whose only
consumer is `br_abandon_rebuild`. Nor does a `rebuild-landed` attempt: a finished attempt is
not a finished ticket. `resolved_url` is written by `br_resolve_merged`; a record from before
BH-1457 carries none, and the url is read off its own `resolved-merged` attempt instead.

**Every candidate row is eight fields wide.** Until this ticket's review only `br_conductor_emit`
filled the eighth, so a ninth column appended to a queue, build, rebuild or reviews row put the
COST in `parked`: `oldest_untouched` read ~29,000,000m and the cost sort keyed those rows 0,
running the whole-pool-machine rungs first.

**`BR_REBUILDS_PER_TICK`** (default 4, today's default rung budget) caps how many pool builds
one tick may buy fleet-wide, enforced at the dispatch in `br_one` and counted on builds
actually BOUGHT — both rebuild rungs return 0 on paths that enqueue nothing, so counting the
dispatch let four refusals exhaust the budget. A capped park answers rc 3 and writes no ladder
record: no rung slot, no project share, no PR closed, and its hand-off is NOT released. It does
not yet age `oldest_untouched`; #1477 carries the seam for that.

**`BR_TICK_MAX_SECS`** (default 1800 — three cron periods) stops a tick from STARTING new
rungs once its wall clock is gone, and the rungs it was allowed but never bought are carried
into the next tick through `state/blocked-resolver/.tick-budget`, clamped to `BR_PER_TICK`. It
can only stop the tick BETWEEN rows — a fix round is never interrupted — and **a tick always
looks at at least one row**, because `TICK_START` is taken when the tick takes its lock and a
small cap can be spent inside discovery alone. The gate counts rows LOOKED at rather than rungs
run: every terminal, held, stalled and cap-refused row answers rc 3, so a rung-gated bound could
not fire on a tick made of them, and those rows read GitHub. `tick-budget` advances the SATURATED
streak alongside `budget` — they are one condition in two words — and the alert names the ending
it saw, because telling an operator to raise `BR_PER_TICK` on a time-bound lane is the action
that produced the 53-minute tick.

Concurrent rungs were the other half of the ask and are refused for now, on ONE sufficient
reason: `br_cron_unlock` releases the lane-wide scan lock from inside the first rung's dispatch,
and flock lives on the open file description, so the unlock in one subshell releases the
parent's — the first rung to reach the dispatch would drop the tick's single-flight guard while
others are still scanning. A second reason is real but not a blocker: `NP`, `CAPSAID` and
`VISITED` are parent-shell ledgers a background subshell cannot write, so a pool's parent would
have to update them after `wait`, the way `mc_count_inc` already does for the conductor's
concurrent workers. Two reasons an earlier draft gave are struck as WRONG: an exported
`GH_TOKEN` is per process, so two rungs in two subshells cannot clobber one another; and
`mc_row_put` does take a flock — what is unlocked is the get/put PAIR inside `mc_transition`, a
lost-update window only for two rungs on the same key, which the per-key lock already prevents.
Long form: `docs/verification-map/resolver-prepass.md`.

The tick line carries all of it:

```
tick: candidates=785 retired=177 projects=8 visited=[…] skipped=[…] rungs=12/50 reason=tick-budget secs=1803 rebuilds=4/4 budget_carry=38 oldest_untouched=2552m
```

### The fix round runs on the owning box, and a refusal is not a rung (BH-594, 2026-09-24)

**What broke.** From BH-393 (2026-09-16 20:05Z) the hub's `bin/agent-call.sh` refuses the
`execute` stage: rc **77**, `AGENT_CALL_REFUSED hub-no-build …` in the outfile, nothing
billed. The resolver's fix round runs `agent-call.sh execute` on the hub, read that rc as a
round that ran and produced nothing, spent the park's fix round and fell to REBUILD FRESH,
which closed project-5 #1740 (20:24Z) and #1813 (20:54Z). The stopgap since then has been
`execute` dropped from the hub's `HUB_NO_BUILD_LANES`.

**A refusal is a setup block.** `br_fix_round` answers agent-call rc **77** (hub-no-build)
and rc **78** (the no-tools contract) through `br_setup_blocked`, the same path as a missing
clone: no `fixrounds` bump, nothing closed, nothing rebuilt, one `resolver_setup_blocked`
event and one alert per episode, retried next tick. A review park's `review_fix_heads` mark,
written before the spend, is taken back, because the spend never happened. Every other rc
takes today's path.

**The hub hops the round to the owning box.** After admission (the cap, observe mode, the
slot gate, all still on the hub), `br_fix_round` asks `hub_box_builds_here`
(`bin/lib/hub-box.sh`). On the hub it calls `br_fix_remote`, which works like
`bin/up10-lane.sh`: `bin/box-for.sh <project>`, refusing an owner that is `local` or any of
the hub's names; `fleet-conf.sh --tailnet-ip-of-box`, refusing an empty address; then
`ssh root@<ip>` with a remote command that sets its own `PATH`, mints its own `GH_TOKEN` on
the far side, and runs `bin/blocked-resolver.sh --fix-here <project> <rkey> <reason> <url>
<record> <tkey>`. The ssh is bounded by `timeout -k 60 $BR_FIX_LANE_TIMEOUT` and goes
through the existing `BR_SSH`. Every refusal is a setup block. Nothing is ssh'd blind.

**The protocol.** The hub sends its record for the park on stdin and stays the only writer
of it. On the box, `--fix-here` skips the lane gate, the cron single-flight lock and the
heartbeat (it is one admitted round, not a tick) and runs the unchanged `br_fix_round`:
worktree, merge, brief, agent-call, verify, guard-silence gate, push, PR comment. What
belongs to the hub turns into lines on stdout:

| line | the hub does |
|---|---|
| `FIX_RECORD <base64 json>` | writes it as the park's record, but only if it parses as a record for this project. Garbage never overwrites the hub's copy |
| `FIX_RESULT done` | logs `fix round ran on <box>: <the last attempt>`, which is `pushed <sha> to <branch>` or the no-commit rc |
| `FIX_RESULT setup-blocked <base64 what>` | `br_setup_blocked "on <box>: <what>"`. The episode marker, alert and event are the hub's |
| `FIX_RESULT terminal` / `rebuild-fresh` | runs `br_fix_terminal` / `br_rebuild_fresh` itself. A close or a rebuild is only ever the hub's |
| no `FIX_RESULT` at all | setup-blocked, naming the box and the ssh rc. Covers unreachable, timed out, the lane disabled there, or a box whose `bin/` predates `--fix-here` |

The box writes no alert and beats no event. The hub owns both. The fix-run and verify
evidence files stay on the box, under its `state/blocked-resolver/`. Known gap: the hotfix
yield checkpoints are not honoured for a remote round, because the box cannot see the hub's
slot ledger.

**Which box runs it.** The hop keys on identity alone: `HUB_BUILD_OK=1`, or a box that is
not the hub, runs the round where it is. **`HUB_NO_BUILD_LANES` is not read by the hop.**
That knob only decides which stages `agent-call.sh` refuses. So once this is deployed, the
09-16 stopgap on the hub (`execute` removed from `HUB_NO_BUILD_LANES` in `env/global.env`)
should be removed, putting `execute` back into the refused list. A box without
`bin/lib/hub-box.sh` runs every round locally, as before.

**The resolver waits while the conductor re-reviews.** `br_from_conductor` skips a PR, in
both its row loop and its hand-off recovery loop, while `br_rereview_inflight` says the
conductor is judging it: the row is `HEAD_MOVED`, or the head-bound job for that head
(`state/merge-conductor/rereview/<owner_repo>_<num>_<head>.json`) is `running`, or its
`.out.prompt` exists before the job file does. The log line is `re-review in flight on
<sha8>, resolver waits`. A `done`, `failed` or `stale` job does not hold the park.

**A provenance park re-reasoned onto a hand-off is a hand-off.** `hb_block_park` moves a
`BLOCKED_HUMAN provenance` row to `BLOCKED_HUMAN head-not-reapproved` (shown as
BLOCKED_AGENT). The state does not change, so `mc_transition` used to rewrite the reason and
write no hand-off record. It now records the hand-off when a BLOCKED_HUMAN row's reason goes
from one no lane owns to one `mc_handoff_owns`, and logs `re-reasoned <old> -> <new> … a
hand-off: recorded for bin/blocked-resolver.sh`. Owned→owned (the resolver's own
`no-verdict` → `head-not-reapproved`) is left alone, so the release marker is not cleared
every tick.

Driven by `tests/blocked-resolver.bh-594-test.sh` and `tests/merge-conductor.bh-594-test.sh`.

### What still stops on a person, and why that is different

A production DB migration apply where the app has **no** `/api/internal/migrations` endpoint.
No box in this fleet holds production database credentials (the operator, 2026-07-24), so there is no
agent path to hand it to. Those messages now say *"needs the app's migrations endpoint
(orchestrator judged apply)"* rather than *"needs a human"* — the distinction is the whole
point of this change: one is a missing capability, the other was a missing owner.

Two policy parks are also deliberately out of scope, and neither is a defect in a PR:
`bin/review-tighten.sh`'s repo-level park (a rebuild does not move a revert rate) and the rule
miner / guardrail promotion PRs (adopting a mined rule is a decision about how the fleet
works, not a build that failed).

### Kill switches

`flags/blocked-resolver-disabled` stops the lane. `flags/blocked-resolver-observe` classifies
and logs every decision without taking any of them — the way to read what a tick WOULD do.
`flags/automerge-disabled`, the fleet kill switch, forces observe mode here too.

### Pool rebase (`REBASE_ON_POOL`)

A rebase costs the hub a clone, a worktree, a typecheck and a unit run, on the
one box that also runs every tick. `REBASE_ON_POOL` moves that work to a pool
machine and leaves the hub what it must own: the lease on the sha this tick
read, the approval rebind, and the merge.

The flag is per project: `REBASE_ON_POOL=1` in `env/<project>.env` (an
environment value wins when it is set), and `flags/fly-pool-app-<project>` must
exist, since `bin/fly-pool.sh` spawns nothing for a project without it. `1`
without that flag rebases on the hub and writes one line per call to
`logs/merge-conductor.log` — a fallback, not an alert. Anything other than `1`
is off, silently.

`mc_rebase` gains two rc values for this path: **6** queued on the pool (nothing
cloned) and **7** the pool queue is unreachable — retry next tick, nothing
spent. The machine writes back a RESULT file whose first line is one of
`REBASED <new-sha>`, `CONFLICT <path>...`, `GATE_RED typecheck|unit`,
`REBASE_LEASE_REJECTED <why>` or `REBASE_SETUP_FAILED <why>`; the shape is
documented in `bin/lib/rebase-job.sh` and gated by `bin/result-prefix-ok.sh`.

**The flag ships OFF, and only the contract is built** (#540, BH-486.0): the
enqueue is a stub that answers rc 7, so a project that turns it on today gets
its PRs parked by the existing default arms until BH-486.2 lands. See
`docs/verification-map/rebase-on-pool.md`.

## 13. Conductor hygiene (2026-09-15)

### 13.1 `isInMergeQueue` is asked once, remembered, and read only where it can matter

`mergeStateStatus` has no `QUEUED` value, so `isInMergeQueue` is the only witness of GitHub's
native merge queue. gh's `--json` allowlist is a separate thing from the GraphQL type, and
**this gh refuses the field in LIST mode** — so the open pass asked for it, got nothing, retried
without it, and logged a line. Every repo. Every tick. **411 lines in 24 hours**, a wasted list
call behind each one, and then one `gh pr view` per open PR to learn `false` about PRs nothing
was going to merge.

A refusal is a fact about gh, not about the repo, so it is now **remembered**:

| | |
|---|---|
| `MC_LIST_INQUEUE` | `auto` (default) — ask unless the marker is fresh; `1` always ask; `0` never |
| marker | `state/merge-conductor/gh-no-inqueue-<owner>_<repo>`, one per repo (BH-1585), written **only** when the mergeQueue read was REFUSED (`harness_pr_list` rc 65, a GraphQL `errors` answer) and the plain list then succeeded; a read that did not complete (44/75) is never remembered |
| `MC_INQUEUE_PROBE_TTL_SECS` | `86400` — the marker ages out, so a gh that learns the field is picked up on its own. A capability cache that can never expire is wrong after the next `npm i -g` |
| `MC_INQUEUE_STATES` | `CLEAN QUEUED` — the merge states in which the per-PR read can change what the tick does. Our own row already saying `QUEUED` also counts |

A repo with **no** queue is never asked at all, in the list or per PR. On a normal tick the
refusal line count is **zero**, and the per-PR read happens for the handful of PRs that are
actually mergeable rather than for every open PR on the repo.

### 13.2 The main-red freeze

`bin/main-red-detector.sh` raises `flags/main-red-<slug>` when a repo's own `main` is red (the
flag body carries the content sha, the workflow and since when).

**AND THE TICK IS WHAT RUNS IT (BH-636).** From the day it shipped until BH-636 that script
was invoked by NOTHING — no cron line, no caller, only comments — so the freeze below could
never engage: cromford's own `main` was red for two runs on 2026-09-17 and no flag was
ever raised. The conductor now runs it once at the top of every tick, BEFORE the first project
tick forks, so the flag each of them reads is at most one tick old. It is a `flock -n` DEDUPE
on `locks/main-red-detect-tick.lock` — held means another tick is already doing it and this
one simply does not, never a wait — and its own file, not the detector's own
`locks/main-red-detector.lock`, because taking that one here would make every invocation skip.
Output goes to `logs/main-red-detector.log`; a detector that fails, or is absent (every
conductor fixture copies the script into a scratch `bin/` without it), never touches the tick.
`MC_MAIN_RED_DETECT=0` turns the call off.

**One alert per NEW red sha, not one per episode (BH-636).** The flag's job is to stop the
same red paging every five minutes, and it did that by going silent for the whole episode — so
a main that stayed red across three different shas, with a different job failing each time and
two attempted fixes that did not land, said nothing after the first line. A new sha is new
information: somebody pushed and main is still red. The detector rewrites the flag's
`sha`/`workflow`/`job`/`run`/`detected` (keeping the ORIGINAL `since` — the question a reader
has is how long main has been broken) and sends ONE **non-critical** line naming the new sha
and the failing job. The same sha on the next tick is still the one log line and no alert.
Cancelled/skipped/neutral runs are not evidence here either, so they never move the watermark.

While that flag is up the
conductor **merges nothing in that repo** — a merge into a red main is a merge whose CI signal
is worthless, and on a queue repo it ejects everything behind it as well — with exactly two
exceptions, which are the way OUT of a red main:

* a PR carrying the fix label (`MC_MAIN_RED_LABEL`, default `fix-main-red`);
* a PR whose **whole** diff is test files (`MC_MAIN_RED_TEST_PATHS`, default
  `tests/* worker/*/test/*`), which cannot be what broke main and is frequently the quarantine
  that unblocks it.

The flag is read under both spellings a detector might use — the project name (`main-red-project-3`)
and the owner-repo slug (`main-red-example-org-project-3`) — because a flag name cannot contain a
slash. It is read through `flag_active`, so the DB row and the file agree like every other flag.

**It is a freeze, not a park.** The row stays `READY`, nothing is re-reviewed, nothing is
rebased, no reason is written, and the PR merges on the first tick after the flag goes. The
log says so once per tick per repo (`MAIN_RED_FREEZE in force …`) and once per held
`(PR, head)` — the freeze line is what tells the operator it is still on; the held line is not
repeated every five minutes.

**It fails closed.** A PR whose file list GitHub will not hand over is not exempt: treating an
unreadable diff as tests-only would be a merge into a red main on a guess.

## 14. A stranded stacked child is retargeted, not thrown away (BH-458, 2026-09-16)

**The evidence.** On 2026-09-15, between 08:11Z and 14:11Z, eleven PRs on one repo were closed
unmerged. Five of them were fully built, APPROVED, CI-green stacked children, discarded for one
reason only: the parent PR they sat on had been closed for a rebuild. Each was about 50 minutes
of build and about $20 that had already been paid for.

**Why nothing moved them.** The stacked block (section 3, `STACKED_WAIT`) asks `mc_stack_parent`
for the PR whose head is the child's base branch. When a ticket is rebuilt, that PR is the
parent's FIRST attempt — CLOSED, unmerged, its branch dead — so the block parked the child
`BLOCKED_HUMAN reason=parent-closed` and stopped. The rebuild landed from `ticket/<key>-rN`,
a branch the child has never heard of, so GitHub's own retarget (which fires when the MERGED
branch is deleted) never touched it either, and the box triage answered "PR already covers this
ticket" on every tick.

**The decision (the operator, 2026-09-16): stacking stays ON and the fix is to RETARGET, never to
close.** Roughly three of four stacked children land an hour earlier than they would have, so
the expected value of stacking is positive and the loss was purely the missing retarget.

The `CLOSED` arm now resolves the rebuild before it parks. `mc_retry_pr <slug> <dead-base>`
asks for the PR on `ticket/<key>-rN` by name, highest generation first, starting ABOVE the
generation the dead base already carries (a child on `-r2` is never handed `-r2` back), and
stops at the first hit — one API call in the common case, `MC_RETRY_MAX - 1` (default 6) at
worst, and only for a child whose parent PR is closed.

| The rebuild | What happens |
|---|---|
| **OPEN** | `mc_restack` rebases the child onto the retry branch, its base is PATCHed there, CI is kicked. It then waits on its new parent like any healthy stack |
| **MERGED** | the parent's work is in the project base now, so the child is rebased and retargeted onto that |
| **none** | nothing has replaced the dead branch, so there is nothing to move the child ONTO — and from 2026-09-16 that is where the orphan read takes over rather than where the child stops: `mc_orphan_clean` asks whether the child needs the dead parent at all, and a child that carries none of it is retargeted straight to the project base while one that does is handed to `bin/blocked-resolver.sh` on `orphaned-child` (section 16) |

`mc_restack` is `git rebase --onto <new-base> <old-base>`, not a merge: it replays only the
commits the child added on top of the dead parent, so the child's diff stays one ticket's work
and none of the abandoned parent's commits ride along. That is why it is not `mc_rebase`, which
merges `origin/main` INTO the branch and on a stacked child would pull the dead parent's tree
in with it. It takes the same push lease on the head the tick read, runs no local gate (CI runs
on the new head and the head-bound re-review reads it before anything merges), and does **not**
rebind the approval — the rewritten head goes through the ordinary moved-head path, which
re-reviews it, or rebinds for free when the patch-id turns out identical, which after a clean
rebase it usually is.

**The one path that still throws a build away** is a rebase that CONFLICTS, which means the
child's own commits do not apply on the branch that replaced its parent. Then
`mc_close_for_rebuild` posts a comment NAMING the conflicting files and closes the PR by REST
(comment first: a PR closed without an explanation tells the next reader nothing). The ticket
stays open, so the next triage tick builds it fresh.

Everything here is `ACTIONS`-only; an observe tick logs `would restack onto <branch> …` and
writes nothing, not even the attempt marker. The marker is `restack <key> <head>` in
`state/merge-conductor/attempts.txt`, written only on the outcomes that mean something (pushed,
or closed for rebuild) and never on a setup failure or a refused lease — a token outage must
not strand a child for the life of its head. Each action writes ONE log line naming the child,
the dead base and the rebuild PR. The row stays `STACKED_WAIT` for the tick that restacks it,
because every field the tick read (head, base, CI) is about the PR as it was before the push.

Driven by `tests/mc-stranded-child-test.sh`.

## 15. Approved siblings that conflict only on registry files land as ONE train (BH-498, 2026-09-16)

**The policy first, because everything below is downstream of it: one ticket, one PR, one
review, always; batching is a merge-time optimization, never a review-time one.**

PRs are never combined before review. A `BLOCK` on one would hold its siblings hostage, the
review prompt would blow the 128 KB argv limit on every batch, and the per-ticket ledger — cost
per PR, iron-law attribution, close-out comment, deploy-train per-merge verify, revert unit —
would lose its key. `bin/batch-resolve.sh` only ever sees PRs that already carry their own
head-bound `APPROVE`, and the union branch it builds is reviewed by nothing: it is a merge
artifact, not a change.

**The evidence.** One night's conflict tail on one repo was almost entirely registry and doc
files — a generated import set, a generated guard list, wave docs, migration directories — and
the conductor cleared it ONE PR every fifteen minutes: a rebase, a full CI run, and, where the
push moved the head, a paid re-review, per PR. Mergify's batch queue already runs CI once over a
combined tree (`docs/MERGIFY.md`), but it only accepts PRs that are already CLEAN; a set of
approved siblings that are DIRTY against each other never reaches it. This is the step that
makes them clean, once, together.

### What is a candidate

A PR of one project, in PR-age order, that is **approved** (`VERDICT: APPROVE` bound to the
current head, provenance not held), **tier-eligible** (the review states tier 1 or 2 — an
approval with no tier is never batched), based on the project's own base branch, and whose ONLY
conflicts — with the base branch AND with each other sibling, asked with
`git merge-tree --write-tree` — are in files **the repo itself declares machine-written**:

| declaration | where | effect |
|---|---|---|
| `merge=union` | the repo's `.gitattributes` | allowed as a conflicting path |
| a "generated files" table, `<file> \| <regenerate command>` | `AGENT_ARCHITECTURE.md`, else `docs/verification-map/README.md`, else `docs/verification-map/index/tail.md` | allowed, and the command is what resolves it |

Any other conflicting file and that PR is not a candidate, with a log line naming the file. That
is the whole safety property: a source conflict still takes today's one-PR-at-a-time path.

**And a `hotfix` PR whose added migration SQL has no accepted proof is not a candidate either**
(BH-370.2, section 6): the train would carry its commits into main past the conductor's own
guard, which only runs in `pr_worker`. The candidate loop asks `mc_hotfix_proof` after the
verdict and tier gates and logs the word it got. This costs nothing for a PR without the
`hotfix` label.
Fewer than two candidates, or two candidates with no conflict at all between them, is not a
train — a set that merges cleanly today saves nothing by being batched.

**The lane is OFF by default on a repo that declares no regenerate table**, and exits 0 having
done nothing: without that list every conflict is a source conflict and there is nothing here to
do. cromford declares its table (`docs/verification-map/README.md` →
`bin/verification-map-build.sh`, under the `## Generated files` heading) and union-merges its
two env templates, so this repo is the first one where the lane is armed. Since BH-1175 that
table is read from `docs/verification-map/index/tail.md`, the file it was always generated
from: the README it used to be read from is not committed any more, `git show <ref>:<path>`
answers nothing for a path that is not in the tree, and an empty table is how this lane
switches itself off without saying anything.

**What `merge=union` actually does**, since the design turns on it: git honours the attribute in
BOTH `git merge` and `git merge-tree --write-tree` (probed on git 2.55), so a union-marked
registry file is concatenated silently and never surfaces as a conflict at all. There is
therefore no union resolver in `bin/batch-resolve.sh` — writing one would be dead code. The
union paths are read anyway and kept in the allow-list, which is what makes the rule true on a
box whose git does not apply the attribute; and a union path that DOES conflict (a
modify/delete, which the union driver cannot answer) drops its PR out of the batch like any
other unhandled conflict.

### The train

`batch/<project>/<UTC stamp>`, cut from the base branch in a scratch worktree, on the same
credential path `mc_rebase` takes (`mc_git_auth` — the token that can FETCH is not always the
one that can read the repo's metadata). Each member's approved head is merged in, oldest PR
first. A conflict in a regenerable file takes THEIRS and records the command; anything else
drops that member out with a log line.

**The regenerate is deferred on purpose.** Every distinct command runs ONCE, over the finished
union, after the last merge — a command whose whole job is to be a pure function of the final
tree gains nothing from running per conflict, and the intermediate answers would all be thrown
away. Then the repo's `## Verification Contract` command (the first line of the first fenced
block; `npm test` when the repo states none) runs ONCE over the union. Then the branch is
pushed, a train PR is opened whose body lists every member, and that ONE PR is enqueued through
the existing queue path — `merge_queue_put` for the ledger, then **either** the box queue's entry
file **or** the provider's own enqueue, never both. The box queue is fed only where it is the
lander (`QPROV = none`): on a Mergify or native-queue repo an entry there would let
`bin/merge-queue.sh` squash the train directly and bypass the batch verification the queue exists
for, which is the one thing a merge-time batch must never do. **`bin/batch-resolve.sh` merges
nothing itself.**

The train PR is deliberately not a harness PR: no `ticket/` branch, no build record, no
`harness build` marker, so `mc_is_harness_pr` is false and this conductor ignores it entirely.
Which is why the lane refuses to build a train at all on a repo that has no provider queue while
`flags/conductor-owns-merges` is on — the box merge queue stands down there, and a train nothing
can land would be an orphan PR on a client's repo.

**The one thing a train genuinely costs, stated plainly: the revert unit.** Every landing path
in this fleet squashes, so a train lands as ONE commit and reverting it reverts every member
together — where today each ticket lands as its own revertable commit. That is the trade the
policy note at the top of this section draws the line around: it is acceptable at MERGE time,
where the members have already been reviewed separately and each still has its own PR, its own
ledger row and its own close-out naming the train's sha; it is not acceptable at review time,
which is why PRs are never combined before review. When the per-ticket revert matters more than
the CI run, `flags/batch-resolve-off` is the switch.

### While a train is in flight, its members are HELD

`mc_batch_hold` / `mc_batch_held` / `mc_batch_release`, markers under
`state/merge-conductor/batch-hold/`. Without the hold a lane would merge a member on its own —
the member is `READY` and approved, after all — landing the same work twice and re-dirtying
every sibling in the train, which is the exact tail the train exists to end. The hold is keyed
on the HEAD, so a push to the member's branch ends it by construction.

**The invariant: a PR in a train is landed BY the train, and only by it.** Three lanes can land
or feed a landing, and all three read the same marker (BH-576 — a hold honoured by one of them
is not a hold):

| lane | where it asks | what it does |
|---|---|---|
| `bin/merge-conductor.sh` `pr_worker` | before it classifies the PR | returns, one log line per (PR, head) |
| `bin/merge-queue.sh` `bh_held` | on BOTH landing paths — the union merge train's member loop and the serial loop, after the not-OPEN dequeue and before `hb_blocked` and the rebase | skips the entry and KEEPS it: never dropped, never `.blocked`, never paged, so the train's landing or a push hands it straight back |
| `bin/tier2-merge-sweep.sh` | before the enqueue (it never merges itself; enqueuing a held member would hand the queue a PR it must refuse every pass) | skips the record |

Each skip writes one line per pass naming the train's URL, in `pr_worker`'s wording. All three
fail OPEN on absence — no marker, or a box whose lib predates `mc_batch_held`, and each lane
behaves exactly as it did. A marker whose head is OLDER than the PR's current head is not a hold
(the head the train was built from is gone). A marker present while the head cannot be READ is
held: a train owns the PR and nothing proves the head moved, and skipping is reversible next
pass where merging is not.

`tests/tier2-merge-sweep-test.sh` drives the queue (both paths) and the sweep against markers
written by the real `mc_batch_hold`, including the head-keyed, empty-marker, other-PR, other-repo
and unreadable-head cases; `tests/batch-resolve-test.sh` covers `pr_worker`'s side.

### Red union: binary split, at most two levels — and at most ONE train per pass

A union that fails the verification contract is split in half (the older half takes the extra
member on an odd count) and each half is tried again, to `BATCH_SPLIT_MAX` levels. A half that
stays red is **handed back**: nothing was pushed to any of its branches and no approval was
touched, so the ordinary conductor path — and `bin/blocked-resolver.sh` behind it — owns those
PRs again exactly as before this lane looked at them. That hand-back is recorded per (PR, head)
in `state/batch-resolve/<project>/red.txt` so the next tick does not rebuild the same red union
for ever; a push to the PR clears it by construction.

**Only the FIRST green half is pushed.** A red union whose two halves are both green used to push
both, and that is a foot-gun with no upside: two branches cut from the same base, each
regenerating the same registry, so the second is permanently dirty the moment the first lands —
and the in-flight guard below then blocks every future batch for that project for ever. The
second half is not red and has done nothing wrong, so it is **deferred**, not handed back red: it
is simply the next pass's candidate set. Nothing that was merely deferred — a half that waited
its turn, a refused push, a train PR that would not open — ever reaches `red.txt`; marking an
untested PR red would exclude it from every batch until its head moved.

### Landing

A train lands minutes to hours later, out of a queue this lane does not watch, so the landing is
read on a LATER invocation — the same shape the `QUEUED` pass has, and for the same reason. When
the train PR reads `MERGED`, every member gets, in order: a comment naming the train and its
merge sha, a REST close, a ledger row (`pr_merged`, `merged_via=batch:<sha>`), its
`merge-sweep-done` line, and its ticket close-out — the issue commented and closed on
issue-driven projects, exactly as `mc_settle_merged` does it for a normal merge. A train that is
CLOSED without merging releases its members untouched.

Four rules make that settle safe to run twice, which it will be:

- **Idempotent per MEMBER.** A `<pr> <head>` line in `state/batch-resolve/<project>/landed.txt`
  is written after a member is fully settled and checked before anything is written for it. A
  kill part-way through used to leave the train `open` with no per-member record, so the next
  pass re-commented on already-closed PRs and wrote a second ledger row each.
- **The comment gates the close, and an unsettled member keeps the train OPEN.** A PR closed with
  no explanation tells the next reader nothing, so a failed comment means the PR really is left
  open and retried — which is what the log always said and the code did not do, because it
  flipped the train to `landed` regardless and the next pass returned at the status check.
- **The head is RE-READ at settle.** The conductor side of the hold is keyed on the head; this
  side was not, so anything that pushed to a member branch while the train was in flight had its
  commits closed away in silence. A member whose head has moved is **not** closed: it gets a
  comment saying the train landed the older head, its hold is released and its issue stays open,
  because the delta needs a rebase and a review.
- **No gh error body is swallowed.** Every failing call logs the vendor's own first line.

**A train that never merges is abandoned, not left in flight.** Past `BATCH_TRAIN_TTL` (6h) a
train that is still open on GitHub has its PR closed, its branch deleted, its members released
and one alert raised. Without that deadline a queue that never took the train — or a red batch
build — would hold its members until `mc_batch_gc`'s seven days AND keep the in-flight guard on,
which disables this lane for the whole project in the meantime.

**A train that ends WITHOUT merging — abandoned on the budget, or closed by a human — excludes
its members at the heads it carried**, in `state/batch-resolve/<project>/abandoned.txt`, on the
same (PR, head) key as everything else here. Releasing the holds alone was not enough: the very
same pass rebuilt an identical train from the same PRs, so a train that can *never* merge — a
required check the queue never satisfies, a paused queue, branch protection the token cannot meet
— meant a new train PR, a new branch and a fresh alert every six hours, for ever, on somebody's
repo, under a log line claiming the members had gone back to the ordinary path. They genuinely do
now, and a push to any member makes it a candidate again the moment something has actually
changed. A member that has not changed stays out of the batch lane and merges the ordinary way,
which is where the abandon released it to.

**The record is written BEFORE the PR is opened**, as `status: creating`, and rewritten to `open`
with the url once `gh pr create` answers. A crash in that window would otherwise leave a train PR
on a client's repo that nothing on this box knows about: nothing settles it, nothing closes it.
A `creating` record is reconciled on the next pass by asking GitHub what exists for the branch —
a PR means the create did land and is adopted; no PR means the branch is an orphan and is
deleted.

The conductor's own row for a settled member is later rewritten to `CLOSED` by the
closed-unmerged pass, which is literally true of the member PR: it was closed, not merged. Where
the WORK landed is what the ledger row says, and the ledger outlives every file mirror here.

### Flags

| flag / env var | default | `0` / present means |
| --- | --- | --- |
| `flags/batch-resolve-off` | absent | no new batch; a train already pushed is still settled |
| `BATCH_RESOLVE` (per project env) | 1 | the same, for one project |
| `flags/automerge-disabled` | absent | nothing at all, settle included (it is a GitHub write) |
| `BATCH_SPLIT_MAX` | 2 | levels of binary split a red union may buy |
| `BATCH_MAX_MEMBERS` | 8 | members one train may carry |
| `BATCH_TRAIN_TTL` | 21600 | seconds a train may sit in flight before it is closed, its members released and one alert raised |
| `BATCH_EXCLUDE_KEEP` | 2000 | lines kept in `landed.txt` / `red.txt` / `abandoned.txt` (all keyed on a head, so only the tail can match) |

The conductor spawns the lane DETACHED at the end of a project's tick, through
`mc_batch_should_spawn`, which says yes on **either** of two counts: the tick classified two or
more approved PRs into `READY`/`NEEDS_REBASE` (the `batchable` counter, which a held member is
added to before its early return), **or** that project has a train still in flight.

That second clause is load-bearing and was missing. The counter is of PRs the tick *classified*,
and a member of a live train returns before it is classified — so once a train carried every
approved PR of a repo the count read zero, the lane was never spawned, and nothing ever read the
train's landing: the train merged, its members stayed open and held, and the holds only expired
after `mc_batch_gc`'s seven days. This conductor is the lane's only invoker — there is no cron
line for it — so "is there a train to settle" has to be one of the reasons to run it.

Detached for the reason the rebase and the deploy verifier are: it clones, merges, regenerates
and runs a whole verification contract, which is minutes, and a lane that can hold a tick is the
stall this conductor was rebuilt to make impossible. `batch-resolve.sh` takes its own `flock -n`,
so a second spawn while one is working is a no-op — and it closes that lock's fd (`9>&-`) around
the repo's own regenerate and verification commands, so a suite that leaves a process behind
cannot hold the lane's lock for that process's lifetime.

Driven by `tests/batch-resolve-test.sh`, against a real git repository (four branches, a real
`merge=union` attribute, a real regenerate command) and a stubbed `gh`.

## 16. A parent that closed with nothing to replace it (2026-09-16)

Section 14 answers the parent that was closed **for a rebuild**, because a rebuild is a branch
to move onto. The other ending has no replacement at all, and until today it had no event
either. On 2026-09-16 at 09:35Z `bin/blocked-resolver.sh` closed project-5 #1556 to rebuild
TK-1529 fresh. Its three children — #1586, #1585, #1587, all cut from `ticket/TK-1529` — were
parked `BLOCKED_HUMAN reason=parent-closed`, which is a word **no lane owns**: the resolver
does not claim it, the conductor cannot move it, and the age budget does not close it. They
stopped moving and nothing was ever going to start them again.

So when `mc_retry_pr` finds no live rebuild, the child's own branch is READ before it is parked.
`mc_orphan_clean <slug> <project> <base> <parent-branch> <head>` is local, read-only and
ref-free — it fetches into the funnel's checkout, writes no ref, pushes nothing, comments
nothing — and answers two halves, **both** of which must hold:

| Half | The question | How |
|---|---|---|
| **carries** | does this head still hold any commit of the dead parent? | the commits the head has beyond the base, intersected with the commits the PARENT branch has beyond the base, must be EMPTY — `rebase --onto <base> <parent>` asked as a set difference, because a rebase that would drop commits is a branch that is carrying them and a base PATCH drops nothing |
| **conflict** | does it still merge into the base? | `git merge-tree --write-tree` against the base, the same worktree-free conflict test the merge funnel uses |

| Verdict | What happens |
|---|---|
| **rc 0 clean** | `mc_retarget_base` points the PR at the project base and `mc_kick_ci` gives the head a run (a base change is an `edited` event and fires no `pull_request` workflow) — exactly the MERGED arm's treatment, including the "already has runs → no kick" rule, because closing a PR with runs in flight cancels them. The PR keeps its number and its CI. Its review does not carry (BH-3950): the conductor records `rtreview <key> <head>` and holds the row on `WAIT_REVIEW retargeted off closed parent - re-review owed` until a head-bound re-review (`headbound_review`, the detached `mc_rereview`) bought AFTER the retarget APPROVES that head, which writes `rtcleared <key> <head>`. A retarget does not move the head, so a `provcleared` row or a lead/human MERGE already on it judged the diff against the dead parent and does not release the hold. A head that already had a read when it was retargeted (`rtpreread`) cannot buy another — the job is one per (PR, head) — so it stays held, and pages on the `WAIT_REVIEW` TTL, until a push. `MC_RETARGET_REREVIEW=0` restores keeping the review, and with it a NONE parent's gone branch parks `orphaned-child` rather than skipping the carried-commit check |
| **rc 1 not clean** | it still carries the parent's commits, it conflicts with the base, or the parent branch is gone from origin so the question cannot be asked at all (except a NONE parent with `MC_RETARGET_REREVIEW` on, which passes `carry=0` and is judged on the conflict half alone). The row parks `BLOCKED_HUMAN reason=orphaned-child`, which `mc_resolver_owns` and `mc_handoff_owns` (sticky) — `bin/blocked-resolver.sh` takes it on class `orphaned-parent`: **no rung-1 mechanical** (merging main does not take the dead parent's commits out) and a fix round briefed with the dead base and the commits of it this branch still carries, then a fresh rebuild |
| **rc 2 unknown** | no authed checkout, no token, git older than 2.38, the head gone from origin. ONE log line per head and the row stays exactly where it was, on `parent-closed`, re-read next tick |

Retargeting a child that DOES carry the parent's commits would open the abandoned parent's whole
diff against main under the child's number — worse than the park — which is why the carries half
is not optional and why rc 1 goes to an agent rather than to a PATCH.

**Nothing on this path closes a PR and nothing on it is on a timer** (the operator, 2026-09-16: "we
shouldn't have rules that kill PRs because of time; it should be event based"). The event is the
parent's close; the answers are a retarget or a hand-off; a tick that cannot read the branch says
so and reads it again next tick. Everything is `ACTIONS`-only, the log lines are deduped per head
through `state/merge-conductor/attempts.txt` (`orphan <key> <head>`, `orphanunknown <key> <head>`),
and `MC_ORPHAN_RETARGET=0` restores the 2026-09-14 behaviour byte for byte.

Driven by `tests/merge-conductor-test.sh` and `tests/merge-funnel-test.sh`.

## 17. A human BLOCK gates every merge path (BH-762, 2026-09-18)

On 2026-09-17 a review landed **BLOCK** on harness-console issue #20 at 18:47Z, and at 18:55Z
the conductor rebased PR #25 and squash-merged the same two commits it had already approved. No
r2 had been pushed. The stated contract is that a human review gates a tier-2 merge; the
mechanism did not implement it, because **nothing between READY and `gh pr merge` had ever read
a comment** — the pre-action re-read asks GitHub for `state,headRefOid,baseRefName` and stops
there. The asymmetry is what makes it expensive: nothing can push an r2 onto a merged PR, so a
merge-over-block turns a fixable review into a new ticket and a second review cycle, every time.

`bin/lib/block-gate.sh` is the gate, and it is ONE gate called from every lane: it is sourced by
`bin/lib/merge-conductor-lib.sh`, which every automatic merge path already sources, so no lane
carries its own copy of "is this PR blocked".

### What gates a merge

Three things, all of them, in this order: the ledger's **APPROVE bound to the head that is about
to merge** (section 3), **CI green on that head**, and **this gate**. The first two are claims
made at review time. This one is re-asked immediately before every merge attempt, on every tick,
which is the whole point — THREAD RECENCY IS LAW governs the build side already, and the merge
side now obeys the same law.

| lane | where | gated |
|---|---|---|
| merge conductor | `bin/merge-conductor.sh`, the `READY` arm (`# >>> block gate`) | yes — after the base guard, BEFORE the merge budget, so a refusal spends nothing |
| tier-2 merge sweep | `bin/merge-sweep.sh` (`# >>> block gate`) | yes — right before `sweep_claim` |
| box merge queue | `bin/merge-queue.sh` `bg_queue_hold`, called on BOTH landing paths | yes — and on the train path TWICE: once where the batch is assembled, once in the landing loop, because the union fetch and typecheck between them take minutes |
| union merge train | `bin/batch-resolve.sh` `bg_batch_hold`, in the candidate loop (`# >>> batch candidates`) | yes — a blocked PR never becomes a train member |
| tier-1 gate inside a build | `bin/run-build.sh` (`# >>> tier-1 merge gate`) | yes — a block stands the build down to `PR_CREATED`, the same exit `flags/conductor-owns-merges` produces |
| reviewer | `bin/review-prs.sh` `bg_review_hold` | yes — asked after the `automerge-disabled` kill switch, which already stops the merge without spending a read |
| console `merge_pr` | `bin/poll-commands.sh` | **no** — an explicit order typed by a human at Mission Control, who is the authority this gate exists to protect |

The union train needs its own call and cannot inherit the conductor's: while a train is in flight
the conductor HOLDS its members and never reaches their `READY` arm, and the train itself is a new
PR whose own thread is empty, so a gate on the other lanes would still put a blocked member's code
on main. A member blocked AFTER its train is already in flight rides that train — the same
seconds-to-minutes window every lane has between its read and its merge, and the next tick refuses
it everywhere else.

### Who can block, and how

Any login, on any of three sources: the **PR conversation** (`issues/<pr>/comments`), the PR's
**review bodies** (`pulls/<pr>/reviews`), and — on an Issues-board project (`fleet.conf` board
prefix `-`) — the **ticket thread** (`issues/<issue>/comments`). Inline diff comments are not
read: a verdict is posted on the conversation or as a review body. Board-API threads are not read
either; on those projects the PR conversation is the record.

A comment BLOCKS when a line of it matches the marker, **case-sensitive, at the start of a line**
after markdown noise (`#`, `*`, `_`, backtick, space) only:

```
BLOCK          BLOCK, one blocking finding          **BLOCK**
VERDICT: BLOCK          ## BLOCK          BLOCK: the channel adoption is wrong
```

and these are deliberately NOT blocks: `BLOCKED`, `BLOCKER`, `BLOCKED_HUMAN`, `PLAN_BLOCKED`,
`REVIEW_BLOCKED`, `Blocked-by: #12`, `BLOCK_GATE_ENFORCE=0`, `the BLOCK gate is on`, `unblock`,
`block`, and `> BLOCK` — a quoted line is somebody repeating a block, not posting one. The gate's
own refusal comment matches neither marker, and `tests/block-gate-lib-test.sh` pins that so it
cannot feed itself.

### How a block is cleared

Four ways:

1. **A newer commit.** The head's time is the newest `author` date across the PR's commits (read
   over REST), never `committedDate` — the conductor's own mechanical rebase and the rebase train
   rewrite committer dates, and "rebased, then merged 8 minutes after the BLOCK" is exactly how
   the incident happened. Author dates survive a rebase, so a real r2 clears its own block and a
   rebase does not. A block whose time is not strictly newer than the head's is ignored entirely.
2. **A later comment from the SAME login** matching `UNBLOCK`, `UNBLOCKED`, `CLEARED` or
   `BLOCK CLEARED`. A clear from a different login clears nothing.
3. **A later comment from the SAME MACHINE login carrying a TERMINAL VERDICT LINE that NAMES THIS
   HEAD** — `VERDICT: APPROVE`, `VERDICT: MERGE-WITH-NOTES` or `VERDICT: MERGE` (BH-1131). Three
   conditions, and all three are load-bearing:
   - **the verdict line**, which is the review lane's machine vocabulary (`bin/review-autopilot.sh`
     writes exactly one of MERGE | MERGE-WITH-NOTES | BLOCK; the build's reviewers write APPROVE or
     BLOCK) and so is a deliberate adjudication rather than prose. A BARE approval (`LGTM`,
     `APPROVED`, the word `APPROVE` on its own, any lowercase spelling of the verdict word) is NOT
     a clear;
   - **a machine author** — a `<name>[bot]` or `app/<name>` login. `bin/review-prs.sh` posts its
     `VERDICT: APPROVE` on whatever token the lane armed, and the fleet PAT's login is `operator`:
     every machine APPROVE on the OS repos today is authored by it (project-3 #355, project-1 #691,
     project-2 #525/#526). Without this condition the review lane would clear a BLOCK a PERSON
     typed, minutes after they typed it. GitHub refuses `[`, `]` and `/` in a user name, so a
     machine login cannot be worn by a person, and a human's BLOCK therefore has no machine twin
     whose verdict could drop it (the drop is per login);
   - **this head, named in the body** — every lane that posts a terminal verdict writes the head
     into its own footer (`<!-- harness-review-autopilot <head12> -->`, `… re-review (Fable) of
     <sha>: APPROVE`, `Automated harness review (Fable) of <sha>`), and the gate matches the SHA,
     not those sentences. A verdict is a fact about one sha; a bot comment that merely ends in the
     vocabulary, or one bound to a head that has since moved, clears nothing. A head the caller
     could not read (empty, or not a sha) fails closed: nothing clears.

   A verdict from a different login clears nothing; a later `VERDICT: BLOCK` blocks again, because
   the newest verdict wins; and a comment that carries a BLOCK marker ANYWHERE blocks whatever its
   last line says — an ambiguous comment is read the fail-closed way.

   Why this exists: PR #728 sat 7h40m with CI green, `mergeState=CLEAN` and a head-bound
   `VERDICT: APPROVE` on the PR, because the review autopilot had BLOCKed that head at 04:33Z and
   the autopilot never writes the word UNBLOCK. Only a new commit could free it, and a new commit
   buys another review — a deadlock the pipeline enters on its own, with no human in the loop.

   What is still open, named so nobody reads more into the rule than it says: the harness's lanes
   share ONE App login, so a head-bound verdict from any of them clears a machine BLOCK from any
   other. Today the autopilot (harness-authored PRs) and `review-prs.sh` (external authors) are
   disjoint, and the conductor's own head-bound re-review is handed the earlier review to
   re-adjudicate — which is the #728 path — so this is the intended escalation and not a bypass.
   A per-lane credential would narrow it further if that ever stops being true.
4. **A lead/human MERGE or MERGE-WITH-NOTES verdict ROW standing on the live head, for a MACHINE
   login's block only** (BH-4468). After the time-ordered walk, `bg_bot_lift` drops every pending
   block whose author passes `bg_bot_login` (`<name>[bot]` or `app/<name>`) when `vd_standing`
   answers a `lead` or `human` MERGE or MERGE-WITH-NOTES row for this exact head. There is no time
   ordering between the row and the block: a push is a new head with no row, and a person who
   disagrees posts a BLOCK of their own or a BLOCK row. Each lift writes one line to
   `logs/block-gate.log`: `block-gate: bot BLOCK <comment id> lifted by human verdict #<row id>
   (<slug>#<num> head <sha8>, <source> <verdict>, @<login>)`. Fail-closed throughout: no row, a
   row on another head, a `box` row, or a read that fails lifts nothing, and the table is asked at
   most once per scan and only when a machine block is still pending.
   - **A person's block is never lifted this way.** Only that person's own UNBLOCK (2) or a newer
     head (1) clears it. When a bot block and a person's block are both pending, the bot's is
     lifted and the answer names the person.
   - Why this exists: PR #4175 (2026-10-04). `cromford[bot]` BLOCKed it at 12:27Z over the
     body saying `Closes #4060`; the body was fixed without a commit, the operator's MERGE row #576 stood on
     that head and `lead-verdict` went green, and the conductor still logged `MERGE_REFUSED
     block-gate` at 20:04Z. The autopilot never re-reviews a head it already answered, so only an
     empty re-head commit (458eceb5) freed it.

### What a refusal looks like

- One log line in the lane's own log (`logs/merge-conductor.log`, `logs/merge-sweep.log`,
  `logs/merge-queue.log`, `logs/pr-reviews.log`, the build's `pipeline.log`), naming the blocking
  comment's URL, its author and its time: `… MERGE_REFUSED block-gate: <url> by @<login> at
  <time> blocks head <sha8> …`. Every tick logs it; a hold nobody can see is the thing this fixes.
- **One** comment on the PR, per (PR, head, blocking comment), across the whole fleet. Two things
  say "already said it": the per-box ledger `state/block-gate/posted.txt` (`<slug>#<num> <head>
  <comment-id>`, append-only), and the PR itself — every refusal carries an invisible marker
  `<!-- block-gate refused <sha8> <comment-id> -->`, which a lane on a DIFFERENT box looks for
  before posting. Six lanes across three machines can refuse the same head (a tier-1 build stands
  down and the hub conductor picks the PR up minutes later with an empty ledger), and without the
  marker each would post its own copy of the same sentence. The ledger line is written AFTER the
  comment posts — a crash between the two costs a duplicate comment and never a silent hold — and
  a marker read that itself fails posts anyway: a duplicate is noise, a silence is a hold.
- **One alert, once, when the same refusal repeats** (BH-1131). `bg_streak_note` counts the
  CONSECUTIVE non-zero answers for one `(PR, head, reason)` in
  `state/block-gate/streak/<slug>-<num>`; at `BLOCK_GATE_STREAK_K` (default 6) it raises ONE
  `bin/lane-alert.sh` line, id `block-gate-stuck:<slug>#<num>:<head12>:<reason>`, naming the PR,
  the head, the reason and the count. It does not repeat until the head or the reason changes, and
  a clean scan deletes the counter. 81 identical "could not read head-time" lines in one day's
  `logs/merge-conductor.log` raised nothing at all; a per-tick log line is not an alert.
  - **The counter is per (box, PR), not per lane**, and on the hub the conductor (`*/5`) and the
    merge sweep (`6,16,…`) share it — so on a PR both lanes refuse, six ticks is about **20
    minutes**, not 30, and the `printf > "$f"` rewrite is not atomic between the two cron lanes.
    The cost of that race is at worst one alert a few minutes early or one extra, which is the
    right way round for a counter whose whole job is to break a silence.
  - **It is `--severity warn`, which `bin/lane-alert.sh` routes to the batched digest, not to a
    Telegram page.** A PR going nowhere for ~20 minutes with CI green is a thing to read in the
    next digest, not to be woken for; if that ever needs to page, the severity is the one-word
    change.
- Nothing else. No state transition, no ledger row, no beat, no hand-off: the conductor row stays
  `READY`, the queue entry stays queued, and the ordinary READY TTL alert is what fires if a block
  stands for a long time. A `BLOCKED_*` transition would hand the PR to the blocked-resolver's fix
  ladder, which is the opposite of "wait for the human's clear".

**A read that fails is not a clear.** If any source read fails (`gh` nonzero, or an answer that is
not the agreed shape), the gate answers "cannot judge": the lane logs which read failed, posts
nothing, merges nothing, and asks again next tick.

**Every read is REST.** The head's time comes from `repos/<slug>/pulls/<num>/commits`, not the
CLI's GraphQL `--json commits`: the App token's GraphQL budget is capped and invisible in
`rate_limit`, so an exhausted one turned every tick into rc 2 `head-time` on PRs that were
otherwise mergeable. The max is taken in the shell rather than in jq, because `gh api --paginate
-q` runs the jq program once per page and a jq-side `| max` would answer one line per page.

One exception, and only one: **an HTTP 404 on the TICKET thread is an empty thread, not a failed
read.** The issue number comes from `mc_issue_of`, which falls back to the first number in the
branch name, so a harness PR on `hotfix/rotate-2026-keys` asks for issue 2026 and gets a 404 — "no
such thread" is the truth there, and fail-closed on it would refuse that PR's merge on every tick
for ever. A 404 on the PR's OWN comments or reviews stays fail-closed: that one means the token
cannot see the repo, which is precisely when not to merge.

**A verdict ROW blocks too (BH-1525).** Before reading any thread, `bg_scan_read` asks
`bin/lib/verdicts.sh` whether a `lead` or `human` BLOCK row stands on this exact head in the jobs
DB's `verdicts` table (`POST/GET /api/verdicts`, append-only, written by `bin/lead-verdict.sh`
from any machine holding `HARNESS_SECRET`). If one does, the answer is rc 1 with the row as the
"comment" (`<report-url> lead-verdict <time> verdict-<id>`), so every lane above refuses the merge
exactly as it would for a thread BLOCK, even when the box review said APPROVE, and posts one
comment that names the row instead of asking for an UNBLOCK. The row is bound to its head: a push
is a new sha with no row and merges normally, and a newer lead/human MERGE row on the same head
lifts it. That same standing MERGE row also lifts a MACHINE login's comment BLOCK on the head
(clear 4 above, BH-4468), never a person's. A `box` row is history only and never stands. **An unreadable table fails CLOSED for the
merge decision**: worker down, no `HARNESS_SECRET`, or a head that is not a full sha makes the gate
answer rc 2 `verdicts`, so the lane skips this tick's merge (no park, no relabel, no dequeue),
logs one line, and asks again next tick, the gh-rest rc-75 rule; a sustained outage raises ONE
alert per box and lane (`block-gate-verdicts-unreadable:<box>:<lane>`, re-armed by the next clean
scan), not one per READY PR, and `bin/review-prs.sh` does not count such a tick as a merge attempt.
**The worker's own 404 is the exception**: the route never answers 404 itself, so the jobs
worker's unknown-endpoint answer (body exactly `{"error":"unknown endpoint"}`, or that plus
`"worker":"harness-jobs"`, which every worker since BH-1525 adds) means the worker has no
`/api/verdicts` (bin/ ships ahead of the worker since #1548, and after a failed deploy or a
rollback). Any OTHER 404 — a deleted or mistyped `JOBS_URL` host behind Cloudflare
(`error code: 1042`), a proxy, an HTML page — proves nothing and is unreadable like any other
failure: skip the tick. The worker's own 404 is "no standing verdict": the merge proceeds on its other gates, and one line per
lane per hour in `logs/verdicts.log` names the missing route. `BLOCK_GATE_ENFORCE=0` downgrades a
lead/human BLOCK row to warn-only along with every thread BLOCK. The same rows answer the conductor's two lead-clearance reads:
`mc_prov_cleared` and `mc_autopilot_verdict` accept a standing lead/human MERGE / MERGE-WITH-NOTES
row first and keep the hub files (`provcleared` line, `state/review-autopilot/…`) as the fallback;
those reads stay fail-open to the files, which is already the no-merge direction. A moved head
with a lead/human BLOCK standing on it buys no box re-review (`leadblock` in attempts.txt).

**Who may write a standing row.** `HARNESS_SECRET` is on every box, so on its own it writes only
`source=box`. A `lead` or `human` row also needs the `x-lead-verdict-token` header matching the
worker secret `LEAD_VERDICT_TOKEN` (403 otherwise; unset on the worker = every lead/human write
refused). Its value lives only on the lead's Mac and the hub, in the file `bin/lead-verdict.sh`
reads (`LEAD_VERDICT_TOKEN_FILE`, default `~/.config/cromford/lead-verdict-token`), and never
in `env/global.env` or any bundle synced to builders. That makes it the LEAD credential: the hub's
lead lane posts `source=lead` with it, so on its own it cannot prove a `source=human` row came from
a person (BH-3831). A human row is proven only by a second header, `x-human-verdict-token`, matching
the worker secret `HUMAN_VERDICT_TOKEN`. Its value lives only on the operator's Mac
(`HUMAN_VERDICT_TOKEN_FILE`, default `~/.config/cromford/human-verdict-token`, mode 600), never
on the hub or a box. Every row records the credential that wrote it in `verdicts.auth`
(`secret` | `lead-token` | `human-token`; `NULL` = written before BH-3831). The settings row
`human_verdict_mode` decides what happens to a human row without the human token: `shadow` (the
seed, and what a missing or junk value reads as) records it with `auth='lead-token'` and logs it;
`enforce` refuses it 403 and writes nothing, BLOCKs included (the lead lane can still post a `lead`
BLOCK). `PUT /api/settings` refuses a change to `human_verdict_mode` without the human token, so
`bin/jobs-client.sh setting-set` cannot flip it; the flip is a curl from the Mac carrying the bearer
and `x-human-verdict-token`. `SELECT … FROM verdicts WHERE source='human' AND auth IS NOT
'human-token'` lists every unproven human row. Under `enforce`, GET `&head=` no longer counts a
`source='human' AND auth='lead-token'` row as `standing` (`auth` NULL and `human-token` rows still
stand); under `shadow` such a row still stands. A `human_verdict_mode` read that throws is not shadow:
a `source=human` POST is 503 and writes nothing, and GET `&head=` is 503, which `vd_standing` reads as
rc 2, a hold (BH-3849).

**The lead override.** `mc_hv_override` (`bin/lib/mc/classify.sh`) lets a `lead` MERGE override
the conductor's re-review BLOCK (BH-3814) only where `la_decide <slug> <pr> <head> lead` returns rc 0
(rc 1 = no override, rc 2 = hold). The lead token is readable on the hub, so a hub process can post
`source=lead`; that is why `lead` never gets the human waiver.

**The knob.** `BLOCK_GATE_ENFORCE` in `env/global.env`, default on. `0` is warn-only — the lane
logs the block it found, with the URL, and merges as it did before the gate. It is a rollback
switch, not a tuning knob.

### Two decisions this section records

**No quiet period between "reviewed green" and "merge".** The ticket asked for one to be
considered. The gate re-reads the thread immediately before every merge attempt, so a review that
has been POSTED lands, including one posted seconds earlier; the only window left is the
read-to-merge gap inside one tick, which is seconds. A quiet period would help only a review that
is being WRITTEN and not yet posted, which the machine cannot see, and it would project-2 every tier-2
merge on the fleet (the operator, 2026-09-13: nothing in this harness waits on a human). If one is wanted
later it is its own knob and its own ticket.

**An r2 on a merged PR does not exist.** Nothing can be pushed onto a merged PR, and this harness
never force-pushes or reverts on its own. Findings on a PR that has already landed become a NEW
ticket on the same board, referencing the original. That is the rule; it is not automated here.

Driven by `tests/conductor-block-gate-test.sh` (the conductor and the tier-2 sweep, both run
whole), `tests/block-gate-lanes-test.sh` (the box queue including both train loops, the union
train's candidate selection, the tier-1 gate, the reviewer) and `tests/block-gate-lib-test.sh`
(the marker vocabulary, the dates, the sources, the cross-box dedupe, the ledger).


### A standing CHANGES_REQUESTED is a BLOCK by its STATE (BH-2199, 2026-09-24)

#2158 merged over the lead's CHANGES_REQUESTED: the review body said `## BLOCKING`, which the
marker regex does not read, and the only commits after it were `Merge origin/main`, whose author
dates are newer than the review, so the text walk read even a real marker as "fixed since".
#2196 merged at the very head the review named. `bg_cr_standing` (called first in
`bg_scan_read`, so on every lane) reads the reviews' STATE instead:

- **whose:** not a Bot / App login, `author_association` OWNER / MEMBER / COLLABORATOR, and not
  the harness review lane's own footer-bearing review (that lane dismisses its own);
- **standing:** the reviewer's latest APPROVED / CHANGES_REQUESTED / DISMISSED review is
  CHANGES_REQUESTED, not lifted by a later same-login PR comment with a line-anchored
  `RESUME`, `MERGE`, `MERGE-WITH-NOTES`, `UNBLOCK` or `CLEARED`, nor by a lead MERGE verdict row
  on the live head;
- **on which head:** the live head, or an older one whose **own diff** the live head still
  carries — `compare/<base>...<sha>` fingerprinted per file on (name, status, +/- lines), so a
  head that only merged main (or was rebased without change) keeps the block. An unreadable,
  truncated (300 files) or patch-less compare cannot tell, and the block stands.

The refusal reads `MERGE_REFUSED block-gate: standing CHANGES_REQUESTED (lead/human BLOCK) <url>
by @<login> at <time> on <blocked-head> blocks head <head> (every head since only merged main …)`;
the row stays `READY`. Unreadable reviews are rc 2 `review-states`: no merge this tick.
