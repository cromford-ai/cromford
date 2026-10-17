# Hotfix dispatch lane (a `hotfix` ticket plans first, builds first, and may take one machine past the cap)

**What it is:** the dispatch half of the hotfix lane (#368). One label —
`hotfix` beside `ai-build` on a GitHub issue — puts that ticket at the head of
the pre-plan list, in front of the pool's spawn order and the hub dispatcher's
one-job-per-project pick, and lets it take **one machine per queued hotfix past
the pool's cap — only when the pool is already at cap**. Below cap it simply
spends a free budget slot like anything else. The machine it lands on carries
the answer with it (`HOTFIX=1` on the `run-build.sh` exec line), so nothing on
the machine asks GitHub a second time and nothing can get a different answer
than the watcher did.

The merge half of the same label is a separate entry:
[hotfix-merge-lane.md](hotfix-merge-lane.md).

**How an operator reaches it:** there is no UI and no command to run by hand.

| lane | where it lives | when it acts |
|---|---|---|
| plan first | `bin/preplan-candidates.sh` (hotfix rows at the head of the output) | `cron/hub.cron` `*/2 * * * * bin/preplan-tick.sh` |
| spawn first + the cap exemption + the flag riding every requeue | `bin/fly-pool.sh` | `cron/hub.cron` `*/10 * * * * bin/fly-pool-tick.sh` |
| the one-job-per-project pick, and the DB row → queue file materialise | `bin/fly-dispatch.sh` | `cron/hub.cron` `*/10 * * * * bin/fly-dispatch.sh` |
| `HOTFIX=1` onto the builder | `fly/builder-runner.sh` | on the Fly machine, once per job |
| the resolver's park order, the fix-round slot cap and the cooperative yield | `bin/blocked-resolver.sh` (`br_rank_rows`, the slot gate in `br_fix_round`, `br_yield_request` / `br_yield_take`) | `cron/hub.cron` `*/10 * * * * bin/blocked-resolver.sh` |

**How to drive it** — every slice of the lane, by dry run:

| what | how |
|---|---|
| the label vocabulary and the announce marker (BH-414) | `bash tests/hotfix-lib-test.sh` |
| the labels read and the hotfix listing over REST, and a 403 answering UNKNOWN rather than "not a hotfix" (BH-781) | `bash tests/closeout-retry.bh-781-test.sh` |
| the first-seen announcement and the paused-project line (BH-415) | `bash tests/hotfix-seen-test.sh` |
| hotfix-first ordering against a real `bin/preplan-candidates.sh`, and a blocked hotfix never being emitted (BH-416) | `bash tests/hotfix-dispatch-order-test.sh` |
| the build's WIP gate, the PR label and the `pr_open` announcement (BH-417) | `bash tests/hotfix-wip-gate-test.sh`, `bash tests/hotfix-pr-label-test.sh` |
| **this entry's half**: the pool budget and the exemption at cap, hotfix-first spawn and machine reuse, the flag surviving every requeue and the DB materialise, the dispatcher pick under the kill flag, a pause getting no exemption (BH-418) | `bash tests/hotfix-cap-exempt-test.sh` |
| the pool's own cap ladder and autoscale line, unchanged by this lane | `bash tests/pool-cap-test.sh`, `bash tests/pool-autoscale-test.sh` |
| the priority rank vocabulary (`hotfix` 0, `fix-main-red` 1, everything else 2) and the lane declaration fields in `$BUILD/job.json` (BH-644) | `bash tests/priority-rank-test.sh` |
| the resolver's candidate order — a `hotfix` park is picked first and `BR_PER_TICK` can never cut it off (BH-646) | `bash tests/resolver-hotfix-order-test.sh` |
| the resolver's fix-round slots, the hotfix reserve and the cooperative yield (BH-646) | `bash tests/resolver-hotfix-slot-test.sh` |
| the triage tick's `[HOTFIX] ` prefix and hotfix-first sort of the READY-QUEUE and launchable-board slices, and the four ways it renders today's prompt instead (BH-645) | `bash tests/triage-hotfix-order-test.sh` |
| the same prefix and sort on the TICK SCOPE slice, and the label reaching the REST query `@uri`-encoded so a space or an `&` in `HOTFIX_LABEL` cannot degrade the tick to FIFO or widen the filter (BH-1349) | `bash tests/triage-hotfix-label.bh-1349-test.sh` |
| the triage hotfix intake: the first step of every pass (a SKIP or held tick included) offers the open hotfix issues to `bin/launch-fastpath.sh` oldest first, a builds pause withholds it, `hotfix-intake-off` turns it off, and the full-sweep prompt leads with `HOTFIX FIRST:` (BH-7117) | `bash tests/hotfix-intake.bh-7117-test.sh` |
| fastpath condition 11 (the spec headings) waived for an issue with the hotfix label only, every other condition unchanged, and the intake launching through the real fastpath (BH-7117) | `bash tests/launch-fastpath-hotfix-spec.bh-7117-test.sh` |
| hotfix-first in the worker's unkeyed `POST /api/queue/claim`, against real SQLite (BH-645) | `cd worker/jobs && node --test test/queue-priority.test.js` |

**Preconditions:** the `hotfix` label does **not** exist in
`example-org/cromford` yet. A human runs
`gh label create hotfix -R example-org/cromford --color B60205` before the
first issue can be labelled. Nothing in this lane creates it, and an unlabelled
issue is simply an ordinary ticket.

**Files it writes on a live box:**

- `logs/fly-pool.log` — the per-tick line gains ` hotfix=N` when any hotfix file
  is queued: `pool <p>: queued=2 running=1 spawning=0 cap=1 hotfix=1`. With no
  hotfix queued the line is byte-identical to what it has always been.
- `logs/fly-pool.log` — `hotfix <KEY>: pool at cap N (budget spent) —
  exceeding it by one machine`, once per hotfix that actually spends the
  exemption. A hotfix that rode a free budget slot writes no such line, because
  it exceeded nothing.
- `logs/fly-pool.log` — `N hotfix job(s) queued but flags/paused-<p> is set —
  exemption not applied, waiting on the pause (a pause is a human decision)`,
  one line per tick while the pause holds.
- `logs/fly-dispatch.log` — the existing `queued job <KEY> taken from the
  coordination DB (no ssh hop)` line; the pick itself logs nothing extra.
- `state/build-queue/<p>/<KEY>.json` — carries `"hotfix":true`, written by the
  DB materialise and rewritten by both requeue paths (deferral and death).
- `state/fly-pool/<p>/<machine-id>.json` — carries `"hotfix":true` for a spawned
  machine and for a machine reused onto a hotfix job.
  A hotfix that defers on a machine whose json carries `reused_from` is
  requeued with `"fresh_spawn":true` in its queue file and row meta; the reuse
  handoff skips it, `logs/fly-pool.log` logs `<KEY>: hotfix deferred on a reused
  machine last time — left for a fresh spawn`, and the next tick spawns it
  fresh (knob `POOL_HOTFIX_FRESH_AFTER_DEFER`, default 1; BH-5025.2).
- `state/blocked-resolver/rounds/<project>-<cap-key>.json` — one row per running
  fix round (`{pid,started_at,hotfix,project,ck,rkey}`), removed on every exit
  path; empty again when the lane is idle. A sibling `.yield` file beside a row
  is a pending yield request, and it names the hotfix that asked.
- `logs/blocked-resolver.log` — the `->` lines in rank order, plus (only with
  `BR_FIX_SLOTS` set) `deferred: N of M slots busy, R reserved for hotfix` and
  `EVENT resolver_yield`.
- the triage tick's rendered prompt (BH-645; the TICK SCOPE block added by
  BH-1349) — on a GitHub-Issues lane the `READY-QUEUE lines:` block, the
  `ALSO launchable right now` block and the `TICK SCOPE (deterministic — …)`
  block of a `board-changed` / `event-wake` tick carry
  `[HOTFIX] ` on any line whose key is an open `ai-build` + `hotfix` issue, those
  lines sorted to the front of their own slice BEFORE the 40-line cap, plus one
  sentence: `Lines marked [HOTFIX] are launched before any other line.` Nothing
  is written to disk. With no hotfix — or the lane off, the `gh` read failing,
  the shared API budget low, or an in-app board — the prompt is byte-identical to
  what it has always been and the sentence is absent. The marker is stripped
  again before the shard dispatcher reads a line, so `locks/triage-key-*.lock`
  and the key canonicalisation see exactly the text they see today.

- `logs/<project>.log` — the triage hotfix intake (BH-7117): one
  `HOTFIX-INTAKE offered #<n>[,#<n>]; declined <keys|none|rc N>` line per pass
  with an open hotfix, or `HOTFIX-INTAKE withheld #<n>: builds pause (...)`
  under a live builds pause. Fastpath writes its own `FASTPATH` /
  `FASTPATH-DECLINED` line per key next to it. No line when no hotfix is open.
  Probe: `grep -E 'HOTFIX-INTAKE|FASTPATH' logs/<project>.log | tail`.

**The resolver half (BH-646).** `bin/blocked-resolver.sh` ranks every candidate
row by the build record's own `ticket-meta.json` (no GitHub call) and sorts on
that rank, so a `hotfix` park is taken before ordinary ones and can never fall
past `BR_PER_TICK`. It stays a sort key: every other candidate is still offered,
in discovery order, behind it. `BR_FIX_SLOTS` then caps concurrent fix rounds
(`0`, the default, is unlimited and is exactly the pre-BH-646 behaviour) and
`BR_HOTFIX_RESERVE` holds slots back for rank-0 work — a plain round is refused
at `running >= BR_FIX_SLOTS - BR_HOTFIX_RESERVE`, a hotfix round only at
`running >= BR_FIX_SLOTS`. When every slot is held by plain work a hotfix writes
`state/blocked-resolver/rounds/<oldest>.yield` and returns; the round that holds
the slot reads that marker at two checkpoints (immediately before its agent call
and immediately after it returns), drops its worktree, keeps `brfix/<ck>`, and
logs one `EVENT resolver_yield`. Nothing waits and no process is ever signalled.

**Knobs:** `HOTFIX_LABEL` (the label name, `env/global.env` or the environment,
default `hotfix`; the triage tick `@uri`-encodes it into its
`issues?labels=ai-build,<label>` read, so a name carrying a space or an `&` —
only reachable through the environment, since the `env/global.env` reader strips
spaces — selects the label it names rather than nothing or a superset);
`HOTFIX_LANE=0` or `flags/hotfix-lane-off` (the kill switch:
no reordering, no exemption, no extra log field — this half of the fleet is
exactly what it was before #368). `flags/fly-pool-<p>` and `fly/pool-caps.conf`
are the pool cap itself and are untouched by this lane.

**What must never regress:**

- **A pause is not a cap.** `flags/paused-<p>` is a human saying stop. The
  exemption is withheld there and the wait is logged; overriding it is out of
  scope.
- **The exemption is only ever spent AT cap,** and is one machine per queued
  hotfix. Below cap a hotfix takes a free budget slot, and the tick must not end
  with more machines than the cap the project was never at (review fix F1).
- **The exemption adds no slot for anyone else.** Plain builds behind a hotfix
  still wait on the budget.
- **`flags/pool-halt-<p>`, `BUILD_SLOTS`, the per-key dedupe lock and the
  file-overlap deferral are untouched.** `pool-halt` sits after the exit
  condition, so a hotfix at cap is still halted by a health stop.
- **The flag is JSON `true` and nothing else.** `"hotfix":"true"` (a string) is
  not a hotfix, and a `*.failed.json` park is never counted, picked or spawned.
- **The label is never re-read on the machine.** `fly/builder-runner.sh` reads
  `.hotfix` off the job file only; no GitHub call is made from the pool, the
  dispatcher or the runner.
- **The kill switch restores the old pick; it never stops the pick.**
  `bin/fly-dispatch.sh` runs under `set -u` and `dispatch_project` runs in a
  `( ... ) &` subshell, so `local next_job` without an initialiser aborts that
  subshell the moment `flags/hotfix-lane-off` is set — before the alphabetical
  fallback and before the `|| say` — and a persistent-builder project silently
  stops receiving jobs. The declaration stays `local next_job=""`, and
  `tests/hotfix-cap-exempt-test.sh` drives the whole dispatcher with the kill
  flag set rather than presetting the variable for it.
- **A deferred or yielded resolver round spends nothing.** No counter bump, no
  `attempts` entry, no state write, no push, no PR comment, no `gh pr close` —
  the park is byte-identically as pending as it was and is re-offered on the
  next `*/10` tick. A cap that looked like a rung would walk a park toward
  REBUILD FRESH for a reason that was never about the PR.
- **A yield keeps the work and never signals the agent.** `brfix/<ck>` is left
  in place so the next round reuses the commit (the tokens are bought once), the
  marker is only ever read between calls, and `BR_FIX_SLOTS=0` skips the whole
  mechanism.
- **A hotfix never preempts a hotfix,** and a row whose pid is dead is pruned
  from `state/blocked-resolver/rounds/` on read — nothing sweeps it later.
- **The round's worktree goes on every exit; `brfix/<ck>` never does** (BH-1363).
  Every removal runs through `br_wt_drop`, which escalates
  `worktree remove --force` → `-f -f` (the locked case) → an anchored `rm -rf` +
  `worktree prune`, and writes one line to `logs/blocked-resolver.log`:
  `removed the fix-round worktree <path> (<why>)`, or
  `could NOT remove the fix-round worktree <path> ... left for bin/disk-clean.sh`
  when the directory survived all three. The per-key subshell traps `TERM`,
  `INT` and `HUP` as well as `EXIT`, so a round killed by a reboot or an
  operator cleans up too, and cleans up AFTER its agent rather than under it
  (bash does run the EXIT trap when a signal kills it, but at once — abandoning
  the wait on an agent that `timeout` has put in a process group of its own). A
  cleanup failure never rewrites the round's own verdict, and the checkpoint
  branch is untouched on every one of these paths: it is the work the round
  already paid for. What a SIGKILL leaves is swept by
  [disk-clean-hygiene.md](disk-clean-hygiene.md) stage 8.
- **`next_job_or_destroy` stays sourceable alone.** `tests/pool-account-routing-test.sh`
  extracts that function by itself; a hard dependency on a helper defined 250
  lines up makes the reuse loop find no jobs and destroy a machine that had work
  waiting, so every helper call there is `command -v`-guarded.

**Manual-only / not automatable:** creating the repo label (above), and
watching a real emergency go through on a live box — the fixtures stub `flyctl`,
`ssh` and `curl` and never touch a real machine or a real ledger.
