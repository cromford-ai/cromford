# Multi-Machine Rollout — machine-per-OS board watchers

> **STATUS: EXECUTED 2026-07-24.** All four boxes live: hub — RENAMED `box-hub`
> (project-1 watcher/builds + Telegram orchestrator + cross-repo guards, 8GB/100GB),
> box-project-2-1 (8GB/40GB), box-project-3-1 (8GB/40GB), box-project-4-1
> (8GB/40GB). Cutover complete; per-box crontabs verified; E2E ticket test passed on the
> pilot (create → cron-detected new=1 rc=0 → deleted). Deviations from spec below: RAM 8GB
> not 16GB (account cap 32GB; measured use ~1GB/box — live-resized hub+pilot down, no
> downtime), disk 40GB not 60GB (quota; +60GB purchased 2026-07-24, 20GB spare unallocated).
> Step 4.4 hub↔worker SSH: DONE 2026-07-24 — all 4 boxes on the operator's tailnet (userspace tailscaled
> under supervisord, no /dev/net/tun on these images; hub ssh's via SOCKS5 :1055 ProxyCommand in
> ~/.ssh/config — plain `ssh root@<tailnet-ip>` works). Worker addresses in hub's env/fleet.env.
> Remaining step-4 decisions (hub env retention, session caps) pending the operator.

Executor: the operator's LOCAL Claude Code (has Orgo API access + the operator's GitHub). The hub box
(`box-hub`, Orgo) already runs everything today; its orchestrator (Telegram) stays
available for questions and can execute hub-side commands if you message it.

## Target topology

| Machine | Project | Runs |
|---|---|---|
| box-hub (the hub, ex box-hub) | project-1 | project-1 watcher + builds, orchestrator (Telegram), cross-repo guards (check-migration-prs, poll-commands, orchestrate) |
| box-project-2-1 (new) | project-2 | its watcher + builds + preplan + reconcile |
| box-project-3-1 (new) | project-3 | same |
| box-project-4-1 (new) | project-4 | same |

Each box: 4 vCPU (Orgo max) / 16GB / **60GB disk**, build-slots=2 → 8 build lanes fleet-wide.
No shared queue: each box owns its project's READY-QUEUE/state/logs. Beats from all boxes
flow to the same console (CONSOLE_URL) → the operator's Telegram, unchanged.

## Hard facts the executor needs

- Repo slugs: `example-org/project-1`, `example-org/project-2` (**typo is real**),
  `example-org/project-3`, `example-org/project-4`. Harness repo (step 0): `example-org/cromford`.
- Hub secrets live at `/root/harness/env/` on box-hub: `global.env`
  (CONSOLE_URL, HARNESS_SECRET, CLAUDE_CODE_OAUTH_TOKEN, VERCEL_PLUGIN_TELEMETRY) and
  `<project>.env` per project. project-2's env also has `PROJECT_2_DATABASE_URL*` (read-only psql).
- Orgo 4-vCPU cap per machine is confirmed; don't try bigger.
- Cron cadence per project: minutes offset,{+10..}: project-1=2, project-2=4, project-3=6, project-4=8.
- The harness repo content is staged ON THE HUB at `/root/harness-repo` (committed, no
  remote yet). It contains `bin/bootstrap-machine.sh` — the per-box installer — and all
  pipeline scripts/prompts. `.gitignore` excludes env/logs/state/locks/flags/builds/plans.

## Step 0 — publish the harness repo (once)

1. From local: `gh repo create example-org/cromford --private` (empty, no README).
2. Via Orgo API exec on box-hub:
   `cd /root/harness-repo && git remote add origin https://github.com/example-org/cromford.git && git push -u origin main`
   (hub's stored gh credentials may lack access to the NEW repo — if push 403s, grant the
   hub's PAT access to cromford in GitHub settings, or push with a temporary token.)
3. Sanity: repo shows bin/ (11 scripts incl. bootstrap-machine.sh), prompts/ (4 files),
   README.md, this file.

## Step 1 — per-box GitHub tokens (the operator, manual, GitHub UI)

For EACH new box create a fine-grained PAT scoped to ONLY that box's repos:
- project-2 box → `example-org/project-2` + `example-org/cromford`
- project-3 box → `example-org/project-3` + `example-org/cromford`
- project-4 box → `example-org/project-4` + `example-org/cromford`
Permissions: Contents RW, Pull requests RW, Metadata R. This is the isolation payoff:
a compromised box can only reach its own project.

## Step 2 — pilot: box-project-2-1

1. **Create machine** via Orgo API: 4 vCPU / 16GB / 60GB, name `box-project-2-1`.
2. **Provision secrets** (Orgo exec on the NEW box; never echo values into logs):
   - `mkdir -p /root/harness/env && chmod 700 /root/harness/env`
   - Write `/root/harness/env/global.env` — copy the 4 values from hub's global.env
     (read them on the hub via Orgo exec, write on the new box; do not route through chat).
   - Write `/root/harness/env/project-2.env` — copy hub's file verbatim.
   - `chmod 600 /root/harness/env/*.env`
3. **Auth**: `gh auth login --with-token` using the project-2 PAT from step 1. Confirm
   `claude --version` works; if claude isn't preinstalled on the Orgo image, install it the
   same way box-hub has it (check `which claude` on hub and mirror).
4. **Harness**: `git clone https://github.com/example-org/cromford.git /root/harness-checkout
   && cp -r /root/harness-checkout/bin /root/harness-checkout/prompts /root/harness/`
   (or clone directly to /root/harness before creating env/ — either way bin/ + prompts/ land in /root/harness).
5. **Bootstrap**: `/root/harness/bin/bootstrap-machine.sh project-2`
   — installs bun/unzip/vercel-plugin, clones the app repo + preplan checkout, npm install,
   writes the cron block, runs a board-reachability + claude smoke test. It FAILS LOUDLY on
   missing preconditions; read its output.
6. **Verify end-to-end** (watch, don't force): within 10 min a triage cron fires. Check
   `/root/harness/logs/project-2.log` for a clean `tickets=… rc=0` line. If a ticket is
   buildable, let the pipeline run to a PR and confirm the board comment posts as the
   project-2 system actor.
7. **Cutover** (Orgo exec on HUB): `crontab -l | grep -v "run-triage.sh project-2" | crontab -`
   Then confirm hub crontab no longer fires project-2, and new box's log shows the next 2
   cycles clean.
8. **Rollback if needed**: re-add the cron line on hub
   (`4,14,24,34,44,54 * * * * /root/harness/bin/run-triage.sh project-2`), disable the
   new box's cron. Nothing else to undo — state files are per-box.

## Step 3 — project-3 + project-4

Repeat step 2 with their names/offsets. Note project-4 repo is small (~125MB); project-3 is largest
(~1.4GB) — npm install ~1-2 min each.

## Step 4 — hub cleanup + guards (DECISIONS for the operator)

1. Remove migrated projects' env files from hub? Strict isolation says yes; BUT the hub
   orchestrator (Telegram) then loses cross-board read/comment ability it uses daily
   (status answers, incident traces, out-of-band tickets). RECOMMENDATION: keep the three
   internal-token env files on hub (they're app-scoped tokens, hub is the most trusted box);
   remove the project-2 PROJECT_2_DATABASE_URL from hub for strictness.
2. check-migration-prs.sh keeps running on HUB for ALL four repos (hub PAT already reads
   all of them). Do NOT duplicate it per box (double pings).
3. Session caps: 4 boxes × (triage every 10 min + builds) share one Anthropic account cap —
   we hit it twice on 2026-07-22 with ONE box. Decide: accept deferrals, or API-key billing
   for the fleet. If switching, set the key in each box's global.env and drop
   CLAUDE_CODE_OAUTH_TOKEN.
4. Optional: hub↔worker SSH for the orchestrator to supervise workers directly (paste hub's
   pubkey into each worker's authorized_keys). Without it, supervision = console beats +
   your local CC via Orgo API. RECOMMENDATION: do it — one line per box, big debuggability win.

## Post-rollout sanity checklist

- [ ] 4 boxes each show ONLY their project's cron lines (`crontab -l`)
- [ ] Hub crontab: project-1 triage + poll-commands + preplan + reconcile + check-migration-prs only
- [ ] A test beat from each new box reaches Telegram (`beat.sh` smoke: kind "ticket_new"-style test — or just wait for a real one)
- [ ] Each box's `/root/harness/env/` contains ONLY its own project env + global.env, chmod 600
- [ ] Worktrees dir exists per box; build-slots=2
- [ ] ALERTS.log empty on all boxes after 1 hour of cycles

## Known sharp edges (learned the hard way, 2026-07-23/24)

- **Newer Orgo images ship WITHOUT cron** — bootstrap-machine.sh now installs it + a
  supervisord `[program:cron]` (autorestart) mirroring the hub. Also: a fresh box's EMPTY
  crontab used to kill bootstrap under `set -e` (grep -v exits 1 on empty input) — fixed
  with `|| true` in the cron-block writer.
- **Orgo exec-API (`/bash`) blips are NOT box failures.** ECONNREFUSED on the sidecar for
  ~20 min while the box (and cron, and a triage run) kept working fine. NEVER freeze/restart
  on an exec blip — wait it out, then read the logs. A freeze→start is what actually breaks
  things: it can strip /etc/resolv.conf (DNS dead) and duplicate supervisord (cron FATAL on
  pidfile race). project-4 box paid this cost so nobody else has to.
- **`pgrep -f run-build.sh` self-matches** claude watcher sessions (the prompt text contains
  the script name in argv) and the caller's own shell. Both the hub watcher and the rollout
  hit this independently ("3 phantom builds"). Detect completion by grepping LOG markers,
  never pgrep. FIXED 2026-07-26: slot-counting now uses `bin/count-builds.sh <project>`
  (argv-anchored pattern immune to prompt-text self-match) after project-3 starved every slot.
  FIXED AGAIN 2026-09-11: it counted PROCESSES, and run-build.sh forks a subshell with the
  same argv, so one build read as two and a box with `build-slots=2` refused to start a
  second (project-5, TK-268/269/270). The unit is now the argv tuple. The launch rules read
  `bin/free-slots.sh <project>`, which also subtracts against the BOX-wide slot count the
  flock actually enforces (the prose everywhere said per-project) and answers `unlimited`
  for a Fly-routed project, whose launch is enqueued to the pool and takes no local slot.
- **Orgo resize is genuinely live** (`PATCH /api/computers/<id>/resize`, body `{"mem_gb":N}` /
  `{"disk_size_gb":N}` — NOT `{"ram":N}`): RAM 16→8 and disk 20→40 applied with zero downtime,
  processes untouched, filesystem auto-grown. Machine create caps: cpu max 4; quota errors
  name the exact ceiling.
- **On the shared console, cross-box dedup rides `akey`** — reconcile-prs runs on every box
  against the same console; merged-PR "shipped" beats dedupe by `akey shipped:<bkey>` and a
  worker's scoped PAT can't even see other projects' PRs. Don't "fix" the overlap.

- Never edit `/root/harness/bin/*.sh` in place while pipelines run — temp file + `mv`.
- A merged PR containing `scripts/migrations/*` needs its SQL applied to prod BY A HUMAN
  before/at deploy — the hub guard pings Telegram, do not ignore it (3 outages in one night).
- `.vercel.app` URLs are fine for the board APIs with internal tokens; the apps' custom
  domains are the client-facing links.
- Quoted identifiers in Supabase SQL: paste migrations EXACTLY (unquoted camelCase silently
  lowercases and the app 500s).

## review-autopilot (hub, hourly) — aging PRs get a review, not just an alert

`bin/review-autopilot.sh` covers the gap `review-prs.sh` deliberately leaves: harness-built
(operator, pipeline-marked) PRs, which `review-prs.sh` skips and which therefore pile up until
pipeline-health check 7 (`stalepr:*`) starts reporting them. Once a non-draft harness PR is
open more than 12h, this lane dispatches ONE adversarial Fable review per head sha and posts
the verdict on the PR.

Install on the HUB only (one line, `crontab -e`):

```
# review-autopilot: PRs aging >12h get an automatic adversarial review
17 * * * * /root/harness/bin/review-autopilot.sh
```

**Trust posture: review auto, merge human.** The lane only ever calls `gh pr comment` — it
never merges, approves, closes, or pushes, and it holds no merge-queue entry. The verdict
line (`VERDICT: MERGE|MERGE-WITH-NOTES|BLOCK — <reason>`) is advice for whoever merges.

Everything except the review text is deterministic:

- **Selection** — `gh pr list --author operator --state open`, non-draft, `createdAt` older
  than 12h, per fleet.conf project (comments and `redirect*` skipped, like pipeline-health).
- **Dedup** — `state/review-autopilot/<slug>-<pr>-<headsha12>`; a new head makes the PR
  eligible again. It also stands down (no spend) when `state/<project>.pr-reviews.json`
  shows `review-prs.sh` already reviewed the same sha, so one sha never buys two reviews.
- **Cost cap** — max 3 dispatched reviews per project per UTC day
  (`state/review-autopilot/count-<project>-<yyyymmdd>`, override `REVIEW_AUTOPILOT_DAILY_CAP`).
  The counter increments on DISPATCH, not on success: an unparseable or unpostable review
  still cost money and still counts against the cap.
- **State after the post, never before** — a failed `gh pr comment` leaves no state file, so
  the next hour retries instead of silently dropping the PR.
- **Fail-open and quiet** — any gh/network error logs to `logs/review-autopilot.log` and the
  loop continues; the lane raises no alerts and sends ONE consolidated beat per run
  (akey `review-autopilot:<yyyymmdd-hh>`) listing `<slug>#<n> -> <verdict>`.

Diffs over ~300KB are reviewed as file list + first 300KB, and the review is instructed to
say so rather than verdict on a partial read.
