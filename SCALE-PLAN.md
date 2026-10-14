# SCALE-PLAN — from 8 build lanes to an engineering org

> Commissioned by the operator 2026-07-28 ("I plan to scale"). Six pillars, built in waves.
> Executors: the hub orchestrator builds harness-side pieces (waves 1, 2, 4a, 6a);
> the operator's LOCAL Claude Code + the operator handle infra/credential decisions (waves 3, 5, and
> the GitHub/console pieces marked LOCAL). Status per item tracked here.

## The thesis
Compute is not the ceiling; coordination is. Parallelism comes from (a) small disjoint
tickets, (b) never running overlapping work concurrently, (c) landing merges serially
against fresh main, (d) elastic build muscle, (e) money instead of caps, (f) WIP limits
with visibility. Everything this week's failure classes taught (union merges, lock
fights, stale worktrees, timeout squeezes) is a coordination bug, not a capacity bug.

## Wave 1 — Conflict-aware scheduling (pillar 2) — LIVE 2026-07-28
The plan stage already writes "files to touch". Use it:
1. `bin/planned-files.sh <build-dir>` — extract the plan's touched-file list into
   `<build-dir>/planned-files.txt` (glob-normalized, one path per line). Written at
   plan-complete time by run-build.sh.
2. `bin/conflict-check.sh <project> <candidate-build-dir>` — compare the candidate's
   planned files against planned-files.txt of every RUNNING build for that project
   (and open harness PRs' changed files via gh). Exit 0 = disjoint (launch), exit 1 =
   overlap (defer with reason "conflicts with <KEY> on <file>").
3. Watcher prompts: before any launch, run conflict-check; on overlap, keep the ticket
   queued (do NOT consume it) and note the serialization in the run summary.
4. run-build.sh: if EXECUTE ends up touching files materially outside plan (diff vs
   planned-files), note it in the PR body (honesty + future scheduler accuracy).
Acceptance: two tickets touching the same module never build concurrently; two
disjoint tickets always do. The build lock stays as a CPU throttle only.

## Wave 2 — Tech-lead decomposer (pillar 1) — LIVE 2026-07-28 (TK-7→104-106, TK-52→107-110)
New stage `bin/run-decompose.sh <project> <ticket-id> <KEY>` (fable):
- Triggered by watchers when a READY ticket's plan would exceed ~1 session of work
  (plan stage returns a SIZE: S/M/L/XL marker — add to plan prompt) or when a ticket
  bundles multiple independent asks.
- Fable splits it into child tickets on the SAME board via the internal ticket-create
  API: each child small, independently shippable, with explicit non-overlapping
  file-scope hints; parent gets a comment listing children and moves to `decomposed`
  (or stays open as the epic umbrella — per-board convention).
- Children flow through the normal pipeline; the conflict scheduler (wave 1) is what
  makes their parallelism safe.
Acceptance: an XL ticket becomes 3+ children that build in parallel lanes without
conflict deferrals; the parent thread narrates the split for the client.

**2026-09-12 — decomposition becomes the DEFAULT above a size, not an XL-only path.**
For six weeks the only trigger was a planner writing `SIZE: XL` on its own plan:
self-reported, all-or-nothing, unmeasured. Measured motivation: the MEDIAN diff
across 381 merged harness PRs is 1,268 lines changed, against the 100-300 large
orgs sustain. So the plan now declares `## Size` (`FILES:` + PRODUCT `LINES:`,
`bin/size-scope.sh` owns what "product" excludes), `bin/size-gate.sh` judges it
against a per-project threshold (`bin/size-threshold.sh`:
`flags/size-gate-<project>` → `catalog/size-thresholds.conf` → 300/12), and over
either limit the ticket is split into ORDERED children each under the same
budget. A plan that declares no size is `PLAN_MALFORMED`. At PR-open the shipped
diff is measured the same way and over 2x the threshold carries a `SIZE:` note
plus a tier-2 demotion — never a block. Shipped with `SIZE_GATE_ENFORCE=0`
(warn-only); `SIZE: XL` still splits either way. Tests: `tests/size-gate-test.sh`.

**2026-09-14 — armed, and the split works on a GitHub-Issues board.** Warn-only
ran for two days and measured TK-552 at 1,900 product lines across 18 files
while it built whole in one 33-minute execute. Enforcement is now the default
(`flags/size-gate-enforce-off` is the fleet kill flag,
`SIZE_GATE_ENFORCE_<project>=0` the per-project one), and `run-decompose.sh`
files children as `ai-build` issues with `Part of #N` / `Blocked-by: #<sibling>`
on projects whose board is the repo's issues, parking the parent by removing its
label. A split child is never split again (depth 1), and the Fable call is
booked as `stage=decompose`. Tests: `tests/run-decompose-issues-test.sh`.

## Wave 3 — Ephemeral build runners (pillar 3) — LOCAL + decisions
Replace per-box slots with a queue + cattle runners once demand exceeds ~8 lanes:
- Queue: `state/build-queue/` on each box (or console-hosted) — buildable tickets in,
  runners claim atomically.
- Runner: a fresh VM/container per build (candidates: more Orgo boxes API-spawned
  on demand; Fly.io machines; Vercel Sandbox). Runner bootstraps: clone repo shallow,
  npm ci (warm cache via a nightly-baked base image per repo), run plan→execute→
  review→PR, push artifacts (build dir) back to the box, die.
- DECIDED (the operator, 2026-07-28): ORGO on-demand — proven substrate, same image and
  tooling as the fleet. Budget set when wave 3 starts.
- Secrets: runner gets ONLY that project's PAT + internal token, injected at spawn,
  never baked into the image. Same isolation philosophy as the fleet split.
Acceptance: 10 concurrent builds on one project with zero shared-lock interactions;
box fleet stays at 4 persistent brains.

## Wave 4 — Merge queue + deploy train (pillar 4) — 4a LIVE 2026-07-28 (merge-queue.sh, fleet cron); 4b LIVE on project-3 (deploy-train.sh + auto-rollback via revert-PR-through-queue; activates per project as VERSION_URL lands: TK-15 building, TK-95/TK-44 queued)
4a HARNESS: serialize landings — a `bin/merge-queue.sh` per project: approved PRs
   enter a FIFO; each is rebased onto current main (or re-merged), CI-verified
   (typecheck+unit at minimum — repos already have workflows), squash-merged, next.
   Kills the union-merge class at any volume. Our review guard + tier gate feed it.
4b HARNESS: deploy train — batch merges; at most one production deploy per project
   per ~15 min window (deploy hooks), verified by version endpoints (TK-95/TK-44/
   TK-25/TK-15) + healthcheck smoke; auto-rollback = redeploy previous known-good
   deployment via hook/API on failed verify.
   DECIDED (the operator, 2026-07-28): AUTOMATIC rollback on failed verify, all apps.
Acceptance: N approved PRs land serially with green CI each; a bad deploy reverts
inside one window without a human.

## Wave 5 — API billing (pillar 5) — DETECTOR LIVE 2026-07-28 (cap-loss-detector.sh, daily 06:20Z; recommends discounted usage bundles first — 10-30% below API rates — per 2026-07-28 pricing finding)
- When sustained demand outgrows per-box subscription caps: Anthropic API key with a
  monthly budget + alerts (console usage panel already tracks per-stage cost.csv).
- Harness change is one line per box: set ANTHROPIC_API_KEY in global.env, drop
  CLAUDE_CODE_OAUTH_TOKEN; agent-call/cost.csv already runner-agnostic.
- Keep per-box subscriptions as the cheap base load; API key is burst capacity.
  DECIDED (the operator, 2026-07-28): flip ANY box to API billing once it loses too much
  time to caps — operationalized as >2h/day of cap-deferred work. The harness
  will DETECT this (daily counter over failovers/cost logs) and alert with the
  flip instruction; the flip itself is one env line per box.

## Wave 6 — WIP limits + org dashboard (pillar 6) — 6a LIVE 2026-07-28 (wip-limit flag honored by run-build; metrics-collect.sh hourly → logs/metrics.csv); 6b = local CC console page
6a HARNESS: `flags/wip-limit-<project>` (default 4 once runners exist); scheduler
   refuses launches beyond it. Cycle-time + outcome metrics appended per build to
   `logs/metrics.csv` (queued_at, started, pr_at, merged_at, deployed_at, verdict,
   fix_rounds, conflict_defers).
6b LOCAL (console): org view — lanes in flight per project, queue depth, cycle time
   p50/p90, review pass rate, deploy train status, spend/day. The console already
   ingests beats; add a `metrics` beat kind + a page.
Acceptance: you can glance at one screen and know throughput, quality, and cost of
the whole org; the system refuses to over-commit itself.

## Order & effort (AI sessions, not human time)
- Wave 1: ~1 session (scripts + prompt wiring + tests). START IMMEDIATELY.
- Wave 2: ~2 sessions (decompose stage + per-board conventions + E2E on a real epic).
- Wave 4a: ~1 session; 4b: ~1 session (after version endpoints land fleet-wide).
- Wave 6a: ~1 session; 6b: local CC ~1 session.
- Wave 3: ~3-4 sessions + the operator decisions; only when demand demands it.
- Wave 5: minutes, when triggered.

## Standing guardrails (unchanged by scale)
Tier discipline, adversarial review before any merge, additive-only schema, no DB
creds on boxes, migrations via endpoints, deploy verification before "live" claims,
De-AI voice, one kill switch: flags/automerge-disabled halts all automated landing.
