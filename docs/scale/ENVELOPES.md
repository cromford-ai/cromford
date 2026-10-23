# Scale envelopes: the harness itself (BH-7906)

This file lists each load path of the factory: vendors, poll loops, cron lanes,
D1 tables, per-ticket fan-out and human-rate consumers. One block per path. The
audit was made on 2026-10-21 against main 8a1d9bc7c4ad.

How to read a block:

- `NOW:` is `<n> (src: <source>, <date>)`, or `not measured (needs: <what>)`.
  A number never appears without its source and date. A read that failed is
  `not measured`, never a zero.
- `NEXT: 10x` is ten times `NOW`.
- `CEILING:` is the first limit the path meets, with its source. A ceiling
  this repo does not record is said so.
- The build box for this audit (a pool machine) has no egress to the jobs
  worker or to api.github.com (`DENY harness-jobs…:443 via=proxy` in the
  build's egress log, 2026-10-21). Every live D1 count and every GitHub read is
  `not measured` for that reason. `docs/notes/2026-10-21-BH-7906-scale-audit.md`
  gives the full list.

`docs/scale/inventory.tsv` freezes the names this audit covers.
`tests/scale-audit.bh-7906-test.sh` requires each of them in this file, and
prints a `NOTE: new since audit` line (not a failure) for a lane, table or seam
added later. `docs/scale/LANDMINES.md` names the paths that break at or below
`NEXT`. `docs/scale/baseline.json` holds the same `NOW` numbers as data.

## Vendors

### GitHub REST

```text
PATH: GitHub REST API through gh_rest (bin/lib/gh-rest.sh) and the other bin/lib/gh-*.sh seams, under ONE GitHub App installation shared by every hub lane and pool machine
UNIT: API calls/hour
NOW: 5,700 calls/h (src: bin/lib/gh-rest-ledger.sh header, the rate_limit counter read 2026-09-22 17:00Z, ~95 calls/min, 2026-09-22)
NEXT: 10x = 57,000 calls/h
CEILING: 6,600 calls/h for the shared App installation bucket (bin/lib/gh-rest-ledger.sh:116, bin/lib/gh-rest-etag.sh:13). NOW is 86% of it.
BREAKS FIRST AT CEILING: GitHub rate limit. The 2026-09-22 symptom: an hourly burst of "UNVERIFIABLE (HTTP 000)" lines (203 + 93 in one hour) in merge-conductor.log and merge-sweep.log, each a skipped decision
SIGNAL: the quota ledger (bin/lib/gh-rest-ledger.sh, state/gh-rest-ledger/, pushed by the gh-ledger-push lane to /api/metrics/gh-ledger), the reserve gate _gh_quota_gate, bin/lib/gh-limit-logger.sh, the gh-pat-charge-alert lane
COST NOW/NEXT/CEILING: $0 / $0 / $0 (GitHub REST is not billed per call; the cost is skipped decisions)
BUILT FOR TODAY: one shared bucket; an ETag cache (bin/lib/gh-rest-etag.sh) and a reserve gate that refuses optional reads first
DEFER UNTIL CEILING: a second App installation per lane class, or a GitHub webhook feed in place of polls; trigger = the ledger shows the bucket below the reserve in 3 hourly windows of one day
```

### GitHub GraphQL

```text
PATH: GitHub GraphQL through `gh api graphql` (for example bin/lib/gh-ci-read.sh, bin/lib/autoenqueue.sh, bin/lib/block-gate.sh)
UNIT: API points/hour
NOW: not measured (needs: a GraphQL rate_limit read with the App token from the hub; the REST quota ledger does not count GraphQL points, and this box has no egress to api.github.com)
NEXT: 10x (not computable: NOW not measured)
CEILING: GitHub's GraphQL points bucket for the App installation; this repo records no value for it
BREAKS FIRST AT CEILING: GitHub rate limit (GraphQL)
SIGNAL: none today (no GraphQL ledger)
COST NOW/NEXT/CEILING: $0 / $0 / $0 (not billed per call)
BUILT FOR TODAY: direct `gh api graphql` calls with no ledger and no reserve
DEFER UNTIL CEILING: a GraphQL row in the quota ledger; trigger = the first GraphQL 403 or "RATE_LIMITED" error in a lane log
```

### Model runners (claude and codex CLIs)

```text
PATH: model sessions through bin/agent-call.sh (claude CLI, codex CLI), one or more per build, review, triage shard and fix round
UNIT: model USD/day
NOW: not measured (needs: the hub's state/cost/ from bin/cost-rollup.sh or the jobs cost_rows read; this pool box holds 3 rows of logs/cost.csv, its own runs only)
NEXT: 10x (not computable: NOW not measured)
CEILING: $4,000/day fleet cost ceiling (docs/notes/2026-09-24-K1-cost-containment.md, as recorded 2026-09-24); the headroom of each registered account also caps sessions (quota-poll lane, bin/account-pick.sh)
BREAKS FIRST AT CEILING: cost cap
SIGNAL: the cost breakers and bin/lib/page-critical.sh (K1), the cost-rollup and cost-reconcile lanes, quota-poll
COST NOW/NEXT/CEILING: not measured / not measured / $4,000 a day
BUILT FOR TODAY: per-lane and fleet rate breakers; no per-ticket dollar budget (the operator's rule in the K1 note)
DEFER UNTIL CEILING: per-project daily model budgets; trigger = the fleet ceiling pages twice in one week
```

### Fly API (flyctl)

```text
PATH: Fly Machines API through flyctl (bin/lib/fly-bin.sh, bin/lib/fly-token.sh) from bin/fly-pool.sh, bin/fly-dispatch.sh and the box-ops seams
UNIT: builds in flight (pool machines), and Fly USD/day
NOW: not measured (needs: the jobs pool-state or machines read, or the hub's fly-pool.log; this box has no egress to the jobs worker)
NEXT: 10x (not computable: NOW not measured)
CEILING: the pool cap per project (flags/fly-pool-<project>), the machine-hours row lane.fly-pool.<p>.pool_machine_hours_daily (cromford 700 = $314.52 a day, docs/FLY-POOL.md), and the fleet Fly spend ceiling of $2,628.39 a day, alert only (docs/FLY-POOL.md)
BREAKS FIRST AT CEILING: pool cap
SIGNAL: fly-pool.log, the pool machine-hours alert (BH-7190), the spend.ceiling.fly-pool.day_usd alert
COST NOW/NEXT/CEILING: not measured / not measured / $2,628.39 a day
BUILT FOR TODAY: a fixed pool per project, reaped every 10 min by the fly-pool lane
DEFER UNTIL CEILING: an autoscaled pool; trigger = build-queue rows wait more than one fly-pool tick at the cap on 3 days of 7
```

### Cloudflare D1 and the jobs worker

```text
PATH: the harness-jobs worker (worker/jobs/) and its D1 database, through bin/jobs-client.sh and bin/lib/jobs/req.sh _jobs_req, from every lane on every box
UNIT: D1 "overloaded" answers per 5 h
NOW: 875 overloaded answers in 5 h (src: CLAUDE.md "Iron law: indexes and retention" on #6727, and worker/jobs/src/routes/retention.js "answered overloaded on 2026-10-14", 2026-10-14)
NEXT: 10x = 8,750 overloaded answers in 5 h
CEILING: already reached at 1x on 2026-10-14: tables of 25k-206k rows read 100-160M rows an hour and one correlated subquery read 1.29M rows per call (CLAUDE.md, #6727)
BREAKS FIRST AT CEILING: D1 overload
SIGNAL: the d1-overload console line (worker/jobs/src/lib/http.js d1OverloadGuarded), a 503 with "overloaded" in logs/jobs-client.log, the retention_runs audit rows of the d1-retention lane
COST NOW/NEXT/CEILING: not measured / not measured / not measured (needs: the Cloudflare D1 usage read)
BUILT FOR TODAY: one D1 for all coordination; a bounded hourly retention run (BH-6750); one overload retry in _jobs_req; withD1Retry in the worker
DEFER UNTIL CEILING: summary tables for the hot aggregates and a second D1 for the history tables; trigger = more than 10 overloaded answers in one hour after BH-6750
```

### Telegram

```text
PATH: Telegram Bot API through bin/archie-tg-send.sh and the page path in bin/lib/page-critical.sh; inbound chat through bin/poll-commands.sh
UNIT: messages/day
NOW: not measured (needs: the hub's Telegram send log or ALERTS.log; this box holds no hub log)
NEXT: 10x (not computable: NOW not measured)
CEILING: the Telegram bot send limits; this repo records no value for them. The human reader is the lower ceiling (see Human-rate)
BREAKS FIRST AT CEILING: reviewer throughput (a person stops reading pages)
SIGNAL: none today (no count of messages sent per day)
COST NOW/NEXT/CEILING: $0 / $0 / $0
BUILT FOR TODAY: direct sends; a digest lane (alert-digest) and warn flushes (alert-warn-flush) group the non-critical lines
DEFER UNTIL CEILING: a per-day page budget; trigger = more than 50 pages in one day
TEST FAKE: none shared. tests/lib/ has no Telegram fake; each suite stubs curl inline. The scale knobs were not added for Telegram (BH-7906 A2).
```

### Slack

```text
PATH: Slack as a second chat transport of the command front door (bin/poll-commands.sh, bin/chat-media.sh, BH-618)
UNIT: messages/day
NOW: not measured (needs: the hub's lane logs)
NEXT: 10x (not computable: NOW not measured)
CEILING: Slack webhook rate limits; this repo records no value for them
BREAKS FIRST AT CEILING: vendor rate limit
SIGNAL: none today
COST NOW/NEXT/CEILING: $0 / $0 / $0
BUILT FOR TODAY: the same front door as Telegram, one message at a time
DEFER UNTIL CEILING: nothing; trigger = the first Slack 429 in a lane log
```

### Vercel

```text
PATH: Vercel API reads by the hub only (lane vercel-deploy-snapshot, bin/vercel-deploy-snapshot.sh, */4 = 360 runs/day); it pushes a snapshot to each watcher box, which holds no Vercel token
UNIT: API calls/hour
NOW: not measured (needs: the Vercel calls per run from the hub's lane log; runs/day is 360 from the lane cadence, calls/run is not known)
NEXT: 10x (not computable: NOW not measured)
CEILING: the Vercel API rate limit; this repo records no value for it
BREAKS FIRST AT CEILING: vendor rate limit
SIGNAL: none today
COST NOW/NEXT/CEILING: $0 / $0 / $0 (reads are not billed)
BUILT FOR TODAY: one hub poller and a pushed snapshot; no Vercel token on a build box
DEFER UNTIL CEILING: nothing; trigger = the first Vercel 429 in a lane log
```

### Clerk in QA

```text
PATH: Clerk calls in product QA runs (the endpoint-clerk lib; bin/qa-clerk-ban.sh, the one caller of Clerk's ban endpoints)
UNIT: sign-ins/day
NOW: not measured (needs: the QA lane logs on the product boxes)
NEXT: 10x (not computable: NOW not measured)
CEILING: the Clerk rate limits per instance; this repo records no value for them
BREAKS FIRST AT CEILING: vendor rate limit
SIGNAL: none today
COST NOW/NEXT/CEILING: $0 / $0 / $0
BUILT FOR TODAY: BH-7563 asks for test-only session routes and real sign-ins only in contract suites; the audit did not check each product
DEFER UNTIL CEILING: nothing; trigger = a Clerk 429 in a contract suite run
```

### Vendor seams in this inventory

| seam file | vendor |
|---|---|
| `bin/archie-tg-send.sh` | Telegram |
| `bin/jobs-client.sh` | jobs worker (D1) |
| `bin/lib/box-ops-fly.sh` | Fly |
| `bin/lib/fly-bin.sh` | Fly |
| `bin/lib/fly-cost-row.sh` | Fly |
| `bin/lib/fly-image-row.sh` | Fly |
| `bin/lib/fly-metrics.sh` | Fly |
| `bin/lib/fly-token.sh` | Fly |
| `bin/lib/gh-app-auth.sh` | GitHub |
| `bin/lib/gh-app-default.sh` | GitHub |
| `bin/lib/gh-budget.sh` | GitHub |
| `bin/lib/gh-ci-read.sh` | GitHub |
| `bin/lib/gh-limit-logger.sh` | GitHub |
| `bin/lib/gh-policy-cache.sh` | GitHub |
| `bin/lib/gh-pr-create.sh` | GitHub |
| `bin/lib/gh-pr-list.sh` | GitHub |
| `bin/lib/gh-pr-merge.sh` | GitHub |
| `bin/lib/gh-push-identity.sh` | GitHub |
| `bin/lib/gh-quota.sh` | GitHub |
| `bin/lib/gh-repo-token.sh` | GitHub |
| `bin/lib/gh-rest-auth.sh` | GitHub |
| `bin/lib/gh-rest-etag.sh` | GitHub |
| `bin/lib/gh-rest-ledger.sh` | GitHub |
| `bin/lib/gh-rest-list.sh` | GitHub |
| `bin/lib/gh-rest-var.sh` | GitHub |
| `bin/lib/gh-rest.sh` | GitHub |
| `bin/lib/gh-token-live.sh` | GitHub |
| `bin/lib/hub-move-fly.sh` | Fly |

## Poll loops and sweeps

### Merge conductor

```text
PATH: bin/merge-conductor.sh (lane merge-conductor, hub, */30) with merge-queue (9 product boxes, */20) and merge-queue-reconcile (hub, */2)
UNIT: PRs/day merged to cromford main
NOW: 47.57 PRs/day (src: git log origin/main --first-parent, 333 "Merge pull request" commits 2026-10-14..2026-10-20 UTC, 2026-10-21)
NEXT: 10x = 475.7 PRs/day
CEILING: not measured (needs: the merge-queue batch CI wall time and batch size from the hub)
BREAKS FIRST AT CEILING: GitHub rate limit (the conductor reads PR state over REST; the 2026-09-22 UNVERIFIABLE burst was in merge-conductor.log, see GitHub REST)
SIGNAL: merge-conductor.log, the mq-list rows (/api/merge-queue), dequeue-watch
COST NOW/NEXT/CEILING: not measured / not measured / not measured (needs: the CI minutes ledger)
BUILT FOR TODAY: one conductor tick every 30 min on the hub; a batch merge queue
DEFER UNTIL CEILING: event-driven ticks from the webhook wakes; trigger = a ready PR waits more than 2 conductor ticks on 3 days of 7
```

### Blocked resolver

```text
PATH: bin/blocked-resolver.sh (lane blocked-resolver, hub, 144 runs/day)
UNIT: runs/day
NOW: 144 runs/day (src: catalog/lanes.d/blocked-resolver.json cadence 4,14,24,34,44,54 * * * *, 2026-10-21)
NEXT: 10x = 1,440 runs/day
CEILING: not measured (needs: run duration from the hub's lane log; a tick longer than 10 min overlaps the next, which the lane-gate single run refuses)
BREAKS FIRST AT CEILING: box CPU and the model cost cap (each fix round is a model session)
SIGNAL: the hub load verdict (hub-load-sample lane, BH-7616), blocked-resolver.log
COST NOW/NEXT/CEILING: not measured / not measured / $4,000 a day (the fleet ceiling)
BUILT FOR TODAY: one hub process, single run per tick
DEFER UNTIL CEILING: shard by project; trigger = a tick that the next tick finds still running on 3 days of 7
```

### Review autopilot and lead review

```text
PATH: review-autopilot (hub, 24 runs/day), lead-review (9 product boxes, */15), lead-review-land (hub, */15)
UNIT: reviews/day
NOW: not measured (needs: the jobs verdict rows count per day from the hub)
NEXT: 10x (not computable: NOW not measured)
CEILING: not measured (needs: reviews per box per hour at full load; the project-10 review-lane bottleneck named in the ticket has no recorded number in this repo)
BREAKS FIRST AT CEILING: reviewer throughput
SIGNAL: lead-review-precision (daily), the needs-review worklist
COST NOW/NEXT/CEILING: not measured / not measured / $4,000 a day (the fleet ceiling)
BUILT FOR TODAY: one review per head sha (BH-2202), on the product box of the project
DEFER UNTIL CEILING: a review pool across boxes; trigger = the needs-review worklist holds a PR more than 2 h on 3 days of 7
```

### Fly pool

```text
PATH: bin/fly-pool.sh through bin/fly-pool-tick.sh (lane fly-pool, hub, */10) and fly-dispatch (hub, */10)
UNIT: runs/day
NOW: 144 runs/day (src: catalog/lanes.d/fly-pool.json cadence */10 * * * *, 2026-10-21)
NEXT: 10x = 1,440 runs/day
CEILING: the pool cap per project and the Fly spend ceiling (see Fly API)
BREAKS FIRST AT CEILING: pool cap
SIGNAL: fly-pool.log, the machine-hours alert
COST NOW/NEXT/CEILING: not measured / not measured / $2,628.39 a day
BUILT FOR TODAY: one reap and spawn pass per 10 min
DEFER UNTIL CEILING: see Fly API; trigger = see Fly API
```

### Triage shards

```text
PATH: run-triage on the 9 product boxes (bin/triage-shard.sh, dispatched by bin/lib/rt/shards.sh), plus alert-triage and sentry-triage on the hub
UNIT: runs/day
NOW: 10,368 runs/day (src: catalog/lanes.d/run-triage.json, 8 cron lines per box x 144 x 9 boxes, 2026-10-21)
NEXT: 10x = 103,680 runs/day
CEILING: the model cost cap; a shard re-bought an unchanged conclusion 3-6x per hour before the per-ticket fingerprint (docs/audit-sources/audit-runaway-spend.md: $896 for cromford on 2026-09-18; fixed by BH-1015)
BREAKS FIRST AT CEILING: cost cap
SIGNAL: the triage-gate brakes, the per-ticket fingerprint (BH-1015), the cost breakers
COST NOW/NEXT/CEILING: not measured / not measured / $4,000 a day (the fleet ceiling)
BUILT FOR TODAY: one tick per project per 10 min; a session only when the ticket fingerprint changed
DEFER UNTIL CEILING: event-driven triage from the board webhook; trigger = triage cost above 20% of the model spend in a week
```

## Cron lanes

### Cron lanes, all boxes

```text
PATH: every lane in catalog/lanes.d/ (186 lane ids) on the boxes it names, rendered to each box's crontab by bin/render-cron.sh
UNIT: lane runs/day
NOW: 138,346 runs/day on all boxes, 29,858 on the hub (src: catalog/lanes.d/*.json cadence x boxes, computed over 2026, 2026-10-21)
NEXT: 10x = 1,383,464 runs/day
CEILING: box CPU on the hub; not measured (needs: the hub load samples from hub-load-sample)
BREAKS FIRST AT CEILING: box CPU
SIGNAL: the hub load verdict and the load shed (BH-7616, bin/lib/hub-load-shed.sh), lane_runs stats (/api/lane-runs/stats)
COST NOW/NEXT/CEILING: not measured / not measured / not measured (needs: per-lane cost from cost_rows)
BUILT FOR TODAY: 185 of 186 lanes take the lane-gate single run (lane_gate_or_exit, BH-7422); 1 lane shows no overlap guard (orc-monitor); 6 lanes have no cron line
DEFER UNTIL CEILING: move hub lanes to a second hub box (hub2 exists); trigger = the hub load verdict says over for 1 h on 3 days of 7
```

Duration is not measured for any lane: the hub's lane logs and the jobs
`lane_runs` table are not reachable from the audit box. Runs/day counts each
cron line of the cadence; a lane with no cron line says so.

| lane id | boxes | cadence | runs/day per box | runs/day all boxes | overlap guard | duration |
|---|---|---|---|---|---|---|
| `alert-digest` | hub | `30 17 * * *` | 1 | 1 | lane-gate single run | not measured (needs: hub logs/alert-digest.log or the jobs `lane_runs` read) |
| `alert-flush` | project-4, hub, project-1, project-10, project-2 | `*/15 * * * *` | 96 | 480 | lane-gate single run | not measured (needs: hub logs/alert-flush.log or the jobs `lane_runs` read) |
| `alert-triage` | hub | `*/10 * * * *` | 144 | 144 | lane-gate single run + flock -n + hub lease | not measured (needs: hub logs/alert-triage.log or the jobs `lane_runs` read) |
| `alert-warn-flush` | project-4, hub, project-6, project-6-os, project-1, project-3, project-10, project-9, small, project-2, project-5 | `*/30 * * * *` | 48 | 528 | lane-gate single run | not measured (needs: hub logs/alert-digest.log or the jobs `lane_runs` read) |
| `alerts-groom` | hub | `12 */2 * * *` | 12 | 12 | lane-gate single run + flock -n | not measured (needs: hub logs/alerts-groom.log or the jobs `lane_runs` read) |
| `alerts-medic` | hub | `18,48 * * * *` | 48 | 48 | lane-gate single run | not measured (needs: hub logs/alerts-medic.log or the jobs `lane_runs` read) |
| `apply-migrations` | project-4, project-6, project-6-os, project-1, project-3, project-9, small, project-2, project-5 | `*/15 * * * *` | 96 | 864 | lane-gate single run + flock -n | not measured (needs: hub logs/apply-migrations.log or the jobs `lane_runs` read) |
| `archie` | hub | `*/15 * * * *` | 96 | 96 | lane-gate single run + flock -n | not measured (needs: hub logs/archie.log or the jobs `lane_runs` read) |
| `archie-fm` | hub | `*/10 * * * *` | 144 | 144 | lane-gate single run + flock -n | not measured (needs: hub logs/archie-fm.log or the jobs `lane_runs` read) |
| `archie-fm-improve` | hub | `43 * * * *` | 24 | 24 | lane-gate single run + flock -n | not measured (needs: hub logs/archie-fm-improve.log or the jobs `lane_runs` read) |
| `archie-fm-queue` | hub | `*/10 * * * *` | 144 | 144 | lane-gate single run + flock -n | not measured (needs: hub logs/archie-fm-queue.log or the jobs `lane_runs` read) |
| `archie-fm-watch` | hub | `7-57/10 * * * *` | 144 | 144 | lane-gate single run + flock -n | not measured (needs: hub logs/archie-fm-watch.log or the jobs `lane_runs` read) |
| `archie-learn` | hub | `35 6 * * *` | 1 | 1 | lane-gate single run + flock -n | not measured (needs: hub logs/archie-learning.log or the jobs `lane_runs` read) |
| `archie-overlook` | hub | `8-58/15 * * * *` | 96 | 96 | lane-gate single run + flock -n | not measured (needs: hub logs/archie-overlook.log or the jobs `lane_runs` read) |
| `archie-research` | hub | `40 6 * * *` | 1 | 1 | lane-gate single run + flock -n | not measured (needs: hub logs/archie-research.log or the jobs `lane_runs` read) |
| `audit-tail` | project-4, hub, project-6, project-6-os, project-1, project-3, project-9, small, project-2, project-5 | `*/5 * * * *` | 288 | 2880 | lane-gate single run + flock -n | not measured (needs: hub logs/audit-tail.log or the jobs `lane_runs` read) |
| `backup-records-sync` | hub | `*/5 * * * *` | 288 | 288 | lane-gate single run | not measured (needs: hub logs/backup-records-sync.log or the jobs `lane_runs` read) |
| `batch-resolve` | hub | `*/5 * * * * (via bin/merge-conductor.sh)` | 288 | 288 | lane-gate single run + flock -n | not measured (needs: hub logs/batch-resolve.log or the jobs `lane_runs` read) |
| `blocked-resolver` | hub | `4,14,24,34,44,54 * * * *` | 144 | 144 | lane-gate single run + flock -n | not measured (needs: hub logs/blocked-resolver.log or the jobs `lane_runs` read) |
| `board-conformance` | hub | `35 7 * * *` | 1 | 1 | lane-gate single run + flock -n | not measured (needs: hub logs/board-conformance.log or the jobs `lane_runs` read) |
| `box-chat` | project-4, hub, project-6, project-6-os, project-1, project-3, project-9, small, project-2, project-5 | `on demand (via a Mission Control chat hand-off from bin/poll-commands.sh; no cron line)` | n/a (no cron line) | n/a | lane-gate single run | not measured (needs: hub logs/box-chat.log or the jobs `lane_runs` read) |
| `box-console-commands` | project-4, project-6, project-6-os, project-1, project-3, project-9, small, project-2, project-5 | `* * * * *` | 1440 | 12960 | lane-gate single run + flock -n | not measured (needs: hub logs/box-console-commands.log or the jobs `lane_runs` read) |
| `box-ops` | project-4, hub, project-6, project-6-os, project-1, project-3, project-10, project-9, small, project-2, project-5 | `* * * * *` | 1440 | 15840 | lane-gate single run + flock -n + hub lease | not measured (needs: hub logs/box-ops.log or the jobs `lane_runs` read) |
| `box-self-report` | project-4, hub, project-6, project-6-os, project-1, project-3, project-10, project-9, small, project-2, project-5 | `27 * * * *` | 24 | 264 | lane-gate single run + flock -n | not measured (needs: hub logs/box-self-report.log or the jobs `lane_runs` read) |
| `box-ssh-probe` | hub | `*/2 * * * *` | 720 | 720 | lane-gate single run + flock -n | not measured (needs: hub logs/box-ssh-probe.log or the jobs `lane_runs` read) |
| `builds-retention` | hub | `27 4 * * *` | 1 | 1 | lane-gate single run + flock -n | not measured (needs: hub logs/builds-retention.log or the jobs `lane_runs` read) |
| `cache-hit-report` | hub | `0 5 * * *` | 1 | 1 | lane-gate single run | not measured (needs: hub logs/cache-hit-report.log or the jobs `lane_runs` read) |
| `cap-loss-detector` | hub | `20 6 * * *` | 1 | 1 | lane-gate single run | not measured (needs: hub logs/cap-loss.log or the jobs `lane_runs` read) |
| `check-migration-prs` | hub | `7,27,47 * * * *` | 72 | 72 | lane-gate single run | not measured (needs: hub logs/check-migration-prs.log or the jobs `lane_runs` read) |
| `ci-batch-ledger` | hub | `11,41 * * * *` | 48 | 48 | lane-gate single run | not measured (needs: hub logs/ci-batch-ledger.log or the jobs `lane_runs` read) |
| `ci-minutes-watch` | hub | `23 */6 * * *` | 4 | 4 | lane-gate single run | not measured (needs: hub logs/ci-minutes-watch.log or the jobs `lane_runs` read) |
| `ci-nightly-full` | hub | `17 * * * *; 41 * * * *` | 48 | 48 | lane-gate single run | not measured (needs: hub logs/ci-nightly-full.log or the jobs `lane_runs` read) |
| `ci-plan-settings` | hub | `23 * * * *` | 24 | 24 | lane-gate single run + flock -n | not measured (needs: hub logs/ci-plan-settings.log or the jobs `lane_runs` read) |
| `ci-shard-watch` | hub | `*/5 * * * *` | 288 | 288 | lane-gate single run | not measured (needs: hub logs/ci-shard-watch.log or the jobs `lane_runs` read) |
| `claude-auth-check` | hub | `51 * * * *` | 24 | 24 | lane-gate single run + flock -n | not measured (needs: hub logs/claude-auth-check.log or the jobs `lane_runs` read) |
| `cli-version-check` | hub | `40 5 * * *` | 1 | 1 | lane-gate single run | not measured (needs: hub logs/cli-version-check.log or the jobs `lane_runs` read) |
| `clock-sync` | project-4, hub, project-6, project-6-os, project-1, project-3, project-10, project-9, small, project-2, project-5 | `*/30 * * * *` | 48 | 528 | lane-gate single run | not measured (needs: hub logs/clock-sync.log or the jobs `lane_runs` read) |
| `component-watch` | hub | `*/15 * * * *` | 96 | 96 | lane-gate single run + flock -n | not measured (needs: hub logs/component-watch.log or the jobs `lane_runs` read) |
| `conflict-hotspots-fleet` | project-4, project-6, project-6-os, project-1, project-3, project-9, small, project-2, project-5 | `23 3 * * 0` | 0.14 | 1.28 | lane-gate single run + flock -n | not measured (needs: hub logs/conflict-hotspots.log or the jobs `lane_runs` read) |
| `console-preview-deploy` | hub | `*/5 * * * *` | 288 | 288 | lane-gate single run + flock -n | not measured (needs: hub logs/console-preview-deploy.log or the jobs `lane_runs` read) |
| `cost-local-brake` | project-4, project-6, project-6-os, project-1, project-3, project-9, small, project-2, project-5 | `3,13,23,33,43,53 * * * *` | 144 | 1296 | lane-gate single run | not measured (needs: hub logs/cost-local-brake.log or the jobs `lane_runs` read) |
| `cost-reconcile` | hub | `50 * * * *; 50 4 * * *` | 25 | 25 | lane-gate single run | not measured (needs: hub logs/cost-reconcile.log or the jobs `lane_runs` read) |
| `cost-rollup` | hub | `45 4 * * *; 50 0-3,5-23 * * *` | 24 | 24 | lane-gate single run + flock -n | not measured (needs: hub logs/cost-rollup.log or the jobs `lane_runs` read) |
| `cost-rows-push` | project-4, hub, project-6, project-6-os, project-1, project-3, project-9, small, project-2, project-5 | `1,11,21,31,41,51 * * * *` | 144 | 1440 | lane-gate single run + flock -n | not measured (needs: hub logs/cost-rows-push.log or the jobs `lane_runs` read) |
| `d1-retention` | hub | `41 * * * *` | 24 | 24 | lane-gate single run | not measured (needs: hub logs/d1-retention.log or the jobs `lane_runs` read) |
| `daily-digest` | hub | `*/15 * * * *` | 96 | 96 | lane-gate single run + flock -n | not measured (needs: hub logs/daily-digest.log or the jobs `lane_runs` read) |
| `data-lane` | hub | `on demand (via bin/archie-fm.sh, the archie-fm */10 tick, which runs bin/data-lane-apply.sh <project> <pr> <build-dir> once per candidate PR head, BH-4927; no cron line of its own)` | n/a (no cron line) | n/a | lane-gate single run + flock -n | not measured (needs: hub logs/<project>.log or the jobs `lane_runs` read) |
| `deploy-train` | project-4, project-6, project-6-os, project-1, project-3, project-9, small, project-2, project-5 | `4,19,34,49 * * * *` | 96 | 864 | lane-gate single run + flock -n | not measured (needs: hub logs/deploy-train.log or the jobs `lane_runs` read) |
| `dequeue-watch` | hub | `*/5 * * * *` | 288 | 288 | lane-gate single run + flock -n | not measured (needs: hub logs/dequeue-watch.log or the jobs `lane_runs` read) |
| `disk-clean` | project-4, hub, project-6, project-6-os, project-1, project-3, project-9, small, project-2, project-5 | `47 4 * * *` | 1 | 10 | lane-gate single run + flock -n | not measured (needs: hub logs/disk-clean.log or the jobs `lane_runs` read) |
| `disk-guard` | project-4, hub, project-6, project-6-os, project-1, project-3, project-9, small, project-2, project-5 | `*/10 * * * *` | 144 | 1440 | lane-gate single run | not measured (needs: hub logs/disk-guard.log or the jobs `lane_runs` read) |
| `doorbell-coverage-check` | hub | `50 5 * * *` | 1 | 1 | lane-gate single run | not measured (needs: hub logs/doorbell-coverage.log or the jobs `lane_runs` read) |
| `env-diff` | project-4, hub, project-6, project-6-os, project-1, project-3, project-10, project-9, small, project-2, project-5 | `*/15 * * * *` | 96 | 1056 | lane-gate single run + flock -n | not measured (needs: hub logs/env-diff.log or the jobs `lane_runs` read) |
| `extra-usage-track` | project-4, hub, project-6, project-6-os, project-1, project-3, project-9, small, project-2, project-5 | `13,28,43,58 * * * *` | 96 | 960 | lane-gate single run | not measured (needs: hub logs/extra-usage.log or the jobs `lane_runs` read) |
| `feature-map-draft` | project-4, project-6, project-6-os, project-1, project-3, project-9, small, project-2, project-5 | `on demand (via an operator at the shell; no cron line)` | n/a (no cron line) | n/a | lane-gate single run | not measured (needs: hub logs/feature-map-draft.log or the jobs `lane_runs` read) |
| `fix-round-claim` | project-4, project-6, project-6-os, project-1, project-3, project-9, small, project-2, project-5 | `*/2 * * * *` | 720 | 6480 | lane-gate single run + flock -n | not measured (needs: hub logs/fix-round-claim.log or the jobs `lane_runs` read) |
| `flag` | hub | `23 * * * *` | 24 | 24 | lane-gate single run + flock -n | not measured (needs: hub logs/flags.log or the jobs `lane_runs` read) |
| `flaky-detect` | hub | `40 5 * * *` | 1 | 1 | lane-gate single run | not measured (needs: hub logs/flaky-detect.log or the jobs `lane_runs` read) |
| `flaky-tier` | hub | `20 9 * * *` | 1 | 1 | lane-gate single run + flock -n | not measured (needs: hub logs/flaky-tier.log or the jobs `lane_runs` read) |
| `fleet-propagate` | hub | `*/5 * * * *` | 288 | 288 | lane-gate single run + flock -n | not measured (needs: hub logs/fleet-propagate.log or the jobs `lane_runs` read) |
| `fleet-slo` | hub | `*/10 * * * *` | 144 | 144 | lane-gate single run | not measured (needs: hub logs/fleet-slo.log or the jobs `lane_runs` read) |
| `fleet-status-push` | hub | `*/10 * * * *` | 144 | 144 | lane-gate single run + hub lease | not measured (needs: hub logs/fleet-status-push.log or the jobs `lane_runs` read) |
| `fleet-version-check` | hub | `*/10 * * * *` | 144 | 144 | lane-gate single run + flock -n | not measured (needs: hub logs/fleet-version-check.log or the jobs `lane_runs` read) |
| `fly-dispatch` | hub | `*/10 * * * *` | 144 | 144 | lane-gate single run + flock -n | not measured (needs: hub logs/fly-dispatch.log or the jobs `lane_runs` read) |
| `fly-idle-check` | hub | `37 6 * * *` | 1 | 1 | lane-gate single run + flock -n | not measured (needs: hub logs/fly-idle-check.log or the jobs `lane_runs` read) |
| `fly-idle-reaper` | hub | `2-59/5 * * * *` | 288 | 288 | lane-gate single run + flock -n | not measured (needs: hub logs/fly-idle-reaper.log or the jobs `lane_runs` read) |
| `fly-image-refresh` | hub | `40 5 * * *` | 1 | 1 | lane-gate single run | not measured (needs: hub logs/fly-image-refresh.log or the jobs `lane_runs` read) |
| `fly-pool` | hub | `*/10 * * * * (via bin/fly-pool-tick.sh)` | 144 | 144 | lane-gate single run + flock -n | not measured (needs: hub logs/fly-pool.log or the jobs `lane_runs` read) |
| `fly-pool-tick` | hub | `*/10 * * * *` | 144 | 144 | lane-gate single run + flock -n | not measured (needs: hub logs/fly-pool.log or the jobs `lane_runs` read) |
| `fly-results-ingest` | hub | `*/2 * * * *` | 720 | 720 | lane-gate single run | not measured (needs: hub logs/fly-results-ingest.log or the jobs `lane_runs` read) |
| `gh-ledger-push` | project-4, hub, project-6, project-6-os, project-1, project-3, project-10, project-9, small, project-2, project-5 | `3,13,23,33,43,53 * * * *` | 144 | 1584 | lane-gate single run + flock -n | not measured (needs: hub logs/gh-ledger-push.log or the jobs `lane_runs` read) |
| `gh-pat-charge-alert` | hub | `17 * * * *` | 24 | 24 | lane-gate single run + flock -n | not measured (needs: hub logs/gh-pat-charge-alert.log or the jobs `lane_runs` read) |
| `greenfield` | hub | `on demand (via an operator running bin/greenfield.sh from a checkout; no cron line)` | n/a (no cron line) | n/a | lane-gate single run | not measured (needs: hub logs/greenfield.log or the jobs `lane_runs` read) |
| `harden-state` | project-4, hub, project-6, project-6-os, project-1, project-3, project-10, project-9, small, project-2, project-5 | `*/10 * * * *` | 144 | 1584 | lane-gate single run | not measured (needs: hub logs/harden-state.log or the jobs `lane_runs` read) |
| `harness-sync-timer` | project-4, hub, hub2, project-6, project-6-os, project-1, project-3, review2, project-9, small, project-2, project-5 | `*/5 * * * *` | 288 | 3456 | lane-gate single run + flock -n | not measured (needs: hub logs/harness-sync-timer.log or the jobs `lane_runs` read) |
| `healthcheck` | project-4, project-6, project-6-os, project-1, project-3, project-9, small, project-2, project-5 | `43 6,18 * * *` | 2 | 18 | lane-gate single run | not measured (needs: hub logs/healthcheck.log or the jobs `lane_runs` read) |
| `heartbeat-reaper` | hub | `*/5 * * * *` | 288 | 288 | lane-gate single run + hub lease | not measured (needs: hub logs/heartbeat-reaper.log or the jobs `lane_runs` read) |
| `hotspot-split-ticket` | hub | `53 4 * * 1` | 0.14 | 0.14 | lane-gate single run + flock -n | not measured (needs: hub logs/hotspot-split-ticket.log or the jobs `lane_runs` read) |
| `hub-load-sample` | hub | `*/10 * * * *` | 144 | 144 | lane-gate single run + flock -n + hub lease | not measured (needs: hub logs/hub-load-sample.log or the jobs `lane_runs` read) |
| `hub-probe` | hub | `*/10 * * * *` | 144 | 144 | lane-gate single run + flock -n | not measured (needs: hub logs/hub-probe.log or the jobs `lane_runs` read) |
| `impact-learn-lane` | hub | `23 * * * *` | 24 | 24 | lane-gate single run + flock -n | not measured (needs: hub logs/impact-learn.log or the jobs `lane_runs` read) |
| `issue-state-ledger` | hub | `*/15 * * * *` | 96 | 96 | lane-gate single run + flock -n | not measured (needs: hub logs/issue-state-ledger.log or the jobs `lane_runs` read) |
| `jobs-watchdog` | project-4, hub, project-6, project-6-os, project-1, project-3, project-10, project-9, small, project-2, project-5 | `*/5 * * * *` | 288 | 3168 | lane-gate single run + flock -n | not measured (needs: hub logs/jobs-watchdog.log or the jobs `lane_runs` read) |
| `lane-cpu-rank` | hub | `5 14 * * *` | 1 | 1 | lane-gate single run + flock -n + hub lease | not measured (needs: hub logs/lane-cpu-rank.log or the jobs `lane_runs` read) |
| `lane-fleet` | hub | `* * * * *` | 1440 | 1440 | lane-gate single run + flock -n | not measured (needs: hub logs/lane-fleet.log or the jobs `lane_runs` read) |
| `lane-move` | hub | `6,16,26,36,46,56 * * * *` | 144 | 144 | lane-gate single run + flock -n + hub lease | not measured (needs: hub logs/lane-move.log or the jobs `lane_runs` read) |
| `lane-reaper` | project-4, hub, project-6, project-6-os, project-1, project-3, project-10, project-9, small, project-2, project-5 | `*/10 * * * *` | 144 | 1584 | lane-gate single run + flock -n | not measured (needs: hub logs/lane-reaper.log or the jobs `lane_runs` read) |
| `lane-reprobe` | hub | `*/5 * * * *` | 288 | 288 | lane-gate single run + flock -n | not measured (needs: hub logs/lane-reprobe.log or the jobs `lane_runs` read) |
| `lane-run-box` | project-6-os | `* * * * *` | 1440 | 1440 | lane-gate single run + flock -n | not measured (needs: hub logs/lane-run-box-cron.log or the jobs `lane_runs` read) |
| `lane-run-wait-alert` | hub | `* * * * *` | 1440 | 1440 | lane-gate single run | not measured (needs: hub logs/lane-run-wait-alert.log or the jobs `lane_runs` read) |
| `lane-snapshot-publish` | hub | `2,12,22,32,42,52 * * * *` | 144 | 144 | lane-gate single run + flock -n | not measured (needs: hub lane log or the jobs `lane_runs` read) |
| `lead-review` | project-4, project-6, project-6-os, project-1, project-3, project-9, small, project-2, project-5 | `*/15 * * * *` | 96 | 864 | lane-gate single run + flock -n | not measured (needs: hub logs/lead-review.log or the jobs `lane_runs` read) |
| `lead-review-enqueue` |  | `*/15 * * * *` | 96 | 0 | lane-gate single run + flock -n | not measured (needs: hub logs/lead-review-enqueue.log or the jobs `lane_runs` read) |
| `lead-review-land` | hub | `*/15 * * * *` | 96 | 96 | lane-gate single run + flock -n | not measured (needs: hub logs/lead-review-land.log or the jobs `lane_runs` read) |
| `lead-review-precision` | hub | `40 5 * * *` | 1 | 1 | lane-gate single run + flock -n | not measured (needs: hub logs/lead-review-precision.log or the jobs `lane_runs` read) |
| `lesson-classify` | hub | `23 * * * *` | 24 | 24 | lane-gate single run + flock -n | not measured (needs: hub logs/lesson-classify.log or the jobs `lane_runs` read) |
| `lesson-measure` | hub | `23 7 * * *` | 1 | 1 | lane-gate single run + flock -n | not measured (needs: hub logs/lesson-measure.log or the jobs `lane_runs` read) |
| `lesson-propose` | hub | `41 6 * * *` | 1 | 1 | lane-gate single run + flock -n | not measured (needs: hub logs/lesson-propose.log or the jobs `lane_runs` read) |
| `locks-mint-digest` | hub | `41 14 * * *` | 1 | 1 | lane-gate single run | not measured (needs: hub logs/locks-mint-digest.log or the jobs `lane_runs` read) |
| `lookback` | hub | `45 6 * * 1` | 0.14 | 0.14 | lane-gate single run + flock -n | not measured (needs: hub logs/lookback.log or the jobs `lane_runs` read) |
| `main-red-bisect` | hub | `*/10 * * * *` | 144 | 144 | lane-gate single run + flock -n | not measured (needs: hub logs/main-red-bisect.log or the jobs `lane_runs` read) |
| `main-red-pr-pair` | hub | `*/10 * * * *` | 144 | 144 | lane-gate single run + flock -n | not measured (needs: hub logs/main-red-pr-pair.log or the jobs `lane_runs` read) |
| `main-red-recheck` | hub | `*/5 * * * *` | 288 | 288 | lane-gate single run | not measured (needs: hub logs/main-red.log or the jobs `lane_runs` read) |
| `merge-conductor` | hub | `*/30 * * * *` | 48 | 48 | lane-gate single run + flock -n | not measured (needs: hub logs/merge-conductor.log or the jobs `lane_runs` read) |
| `merge-conductor-backstop` | hub | `*/5 * * * *` | 288 | 288 | lane-gate single run + flock -n | not measured (needs: hub logs/merge-conductor-backstop.log or the jobs `lane_runs` read) |
| `merge-conductor-wake` | hub | `* * * * *` | 1440 | 1440 | lane-gate single run + flock -n | not measured (needs: hub logs/merge-conductor-wake-cron.log or the jobs `lane_runs` read) |
| `merge-queue` | project-4, project-6, project-6-os, project-1, project-3, project-9, small, project-2, project-5 | `*/20 * * * *` | 72 | 648 | lane-gate single run | not measured (needs: hub logs/merge-queue.log or the jobs `lane_runs` read) |
| `merge-queue-reconcile` | hub | `*/2 * * * *` | 720 | 720 | lane-gate single run | not measured (needs: hub logs/merge-queue-reconcile.log or the jobs `lane_runs` read) |
| `mergify-sync` | hub | `47 6 * * *` | 1 | 1 | lane-gate single run | not measured (needs: hub logs/mergify-sync.log or the jobs `lane_runs` read) |
| `metrics-collect` | project-4, hub, project-1, project-2 | `38 * * * *` | 24 | 96 | lane-gate single run + flock -n | not measured (needs: hub logs/metrics-collect.log or the jobs `lane_runs` read) |
| `migration-autopilot` | hub | `9,24,39,54 * * * *` | 96 | 96 | lane-gate single run + flock -n | not measured (needs: hub logs/migration-autopilot.log or the jobs `lane_runs` read) |
| `model-prices-sync` | project-4, project-6, project-6-os, project-1, project-3, project-9, small, project-2, project-5 | `5 5 * * *` | 1 | 9 | lane-gate single run | not measured (needs: hub logs/agent-rules.log or the jobs `lane_runs` read) |
| `model-route-gap-check` | hub | `35 4 * * *` | 1 | 1 | lane-gate single run | not measured (needs: hub logs/model-route-gap-check.log or the jobs `lane_runs` read) |
| `model-watch` | hub | `47 5 * * *` | 1 | 1 | lane-gate single run + flock -n | not measured (needs: hub logs/model-watch.log or the jobs `lane_runs` read) |
| `orc-monitor` | hub | `*/5 * * * *` | 288 | 288 | none found | not measured (needs: hub logs/orc-monitor.log or the jobs `lane_runs` read) |
| `orchestrator-burn` | hub | `55 * * * *` | 24 | 24 | lane-gate single run | not measured (needs: hub logs/orchestrator-burn.log or the jobs `lane_runs` read) |
| `orgo-state` | hub | `*/5 * * * *` | 288 | 288 | lane-gate single run + flock -n + hub lease | not measured (needs: hub logs/orgo-state.log or the jobs `lane_runs` read) |
| `outcome-check` | hub | `*/30 * * * *` | 48 | 48 | lane-gate single run + flock -n | not measured (needs: hub logs/outcome-check.log or the jobs `lane_runs` read) |
| `outcome-metrics` | hub | `20 5 * * 1` | 0.14 | 0.14 | lane-gate single run + flock -n | not measured (needs: hub logs/outcome-metrics.log or the jobs `lane_runs` read) |
| `pipeline-health` | hub | `*/10 * * * *` | 144 | 144 | lane-gate single run + flock -n | not measured (needs: hub logs/pipeline-health.log or the jobs `lane_runs` read) |
| `poll-commands` | hub | `* * * * *` | 1440 | 1440 | lane-gate single run + flock -n + hub lease | not measured (needs: hub logs/poll-commands.log or the jobs `lane_runs` read) |
| `pool-tick-summary` | hub | `*/2 * * * *` | 720 | 720 | lane-gate single run + flock -n | not measured (needs: hub logs/pool-tick-summary.log or the jobs `lane_runs` read) |
| `postmerge-qa` | project-4, project-1, project-3, project-2, project-5 | `21,51 * * * *; 26,56 * * * *; 31 * * * *; 36 * * * *; 46 * * * *` | 168 | 840 | lane-gate single run + flock -n | not measured (needs: hub logs/postmerge-qa.log or the jobs `lane_runs` read) |
| `pr-owner-sweep` | hub | `*/30 * * * *` | 48 | 48 | lane-gate single run + flock -n | not measured (needs: hub logs/pr-owner-sweep.log or the jobs `lane_runs` read) |
| `pr-state-reconcile` | hub | `*/15 * * * *` | 96 | 96 | lane-gate single run + flock -n | not measured (needs: hub logs/pr-state-reconcile.log or the jobs `lane_runs` read) |
| `pr-url-reconcile` | hub | `3,13,23,33,43,53 * * * *` | 144 | 144 | lane-gate single run + flock -n | not measured (needs: hub logs/pr-url-reconcile.log or the jobs `lane_runs` read) |
| `prebuild-repro` | project-4, hub, project-6, project-6-os, project-1, project-3, project-9, small, project-2, project-5 | `per build (via bin/run-build.sh)` | n/a (no cron line) | n/a | lane-gate single run | not measured (needs: hub lane log or the jobs `lane_runs` read) |
| `preplan-tick` | project-4, hub, project-6, project-6-os, project-1, project-3, project-9, small, project-2, project-5 | `*/2 * * * *` | 720 | 7200 | lane-gate single run | not measured (needs: hub logs/preplan.log or the jobs `lane_runs` read) |
| `prequeue-learned` | hub | `23,53 * * * *` | 48 | 48 | lane-gate single run | not measured (needs: hub logs/prequeue-learned.log or the jobs `lane_runs` read) |
| `progress-push` | hub | `*/10 * * * *` | 144 | 144 | lane-gate single run + hub lease | not measured (needs: hub logs/progress-push.log or the jobs `lane_runs` read) |
| `prompt-eval` | hub | `50 6 * * 1` | 0.14 | 0.14 | lane-gate single run | not measured (needs: hub logs/prompt-eval.log or the jobs `lane_runs` read) |
| `qa-wiring-sweep` | hub | `55 5 * * *` | 1 | 1 | lane-gate single run | not measured (needs: hub logs/qa-wiring.log or the jobs `lane_runs` read) |
| `quota-poll` | project-4, hub, project-6, project-6-os, project-1, project-3, project-9, small, project-2, project-5 | `*/10 * * * *; 23 * * * *` | 168 | 1680 | lane-gate single run | not measured (needs: hub logs/quota-poll.log or the jobs `lane_runs` read) |
| `rebase-train` | hub, project-1 | `11,41 * * * *; 13,43 * * * *; 16,46 * * * *; 19,49 * * * *` | 192 | 384 | lane-gate single run + flock -n | not measured (needs: hub logs/rebase-train.log or the jobs `lane_runs` read) |
| `reconcile-prs` | project-4, hub, project-6, project-6-os, project-1, project-3, project-9, small, project-2, project-5 | `*/10 * * * *` | 144 | 1440 | lane-gate single run + flock -n | not measured (needs: hub logs/reconcile-prs.log or the jobs `lane_runs` read) |
| `registry-export` | hub | `41 3 * * *` | 1 | 1 | lane-gate single run | not measured (needs: hub logs/registry-export.log or the jobs `lane_runs` read) |
| `registry-sync` | project-4, hub, project-6, project-1, project-3, project-10, project-9, small, project-2, project-5 | `*/5 * * * *` | 288 | 2880 | lane-gate single run + flock -n | not measured (needs: hub logs/registry-sync.log or the jobs `lane_runs` read) |
| `reopen-metrics` | hub | `15 4 * * *` | 1 | 1 | lane-gate single run | not measured (needs: hub logs/reopen-metrics.log or the jobs `lane_runs` read) |
| `repair-on-push` | hub | `* * * * *` | 1440 | 1440 | lane-gate single run + flock -n | not measured (needs: hub logs/repair-on-push.log or the jobs `lane_runs` read) |
| `restore-drill` | hub | `0 6 * * 0` | 0.14 | 0.14 | lane-gate single run + flock -n | not measured (needs: hub logs/restore-drill.log or the jobs `lane_runs` read) |
| `restore-lab` | hub | `*/5 * * * *` | 288 | 288 | lane-gate single run + flock -n | not measured (needs: hub logs/restore-lab.log or the jobs `lane_runs` read) |
| `review-autopilot` | hub | `17 * * * *` | 24 | 24 | lane-gate single run + flock -n | not measured (needs: hub logs/review-autopilot.log or the jobs `lane_runs` read) |
| `review-mode-expire` | hub | `*/15 * * * *` | 96 | 96 | lane-gate single run + flock -n | not measured (needs: hub logs/review-mode-expire.log or the jobs `lane_runs` read) |
| `review-prs` | project-4, project-6, project-6-os, project-1, project-3, project-9, small, project-2, project-5 | `*/30 * * * *` | 48 | 432 | lane-gate single run + flock -n | not measured (needs: hub logs/review-prs.log or the jobs `lane_runs` read) |
| `review-rescue` | hub | `7,37 * * * *` | 48 | 48 | lane-gate single run + flock -n | not measured (needs: hub logs/review-rescue.log or the jobs `lane_runs` read) |
| `review-tighten` | hub | `45 5 * * *` | 1 | 1 | lane-gate single run + flock -n | not measured (needs: hub logs/review-tighten.log or the jobs `lane_runs` read) |
| `roadmap-file` | hub | `*/5 * * * *` | 288 | 288 | lane-gate single run + flock -n | not measured (needs: hub logs/roadmap-file.log or the jobs `lane_runs` read) |
| `roadmap-issue-sync` | hub | `*/15 * * * *` | 96 | 96 | lane-gate single run + flock -n | not measured (needs: hub logs/roadmap-issue-sync.log or the jobs `lane_runs` read) |
| `route-shadow-report` | hub | `15 6 * * *` | 1 | 1 | lane-gate single run | not measured (needs: hub logs/route-shadow-report.log or the jobs `lane_runs` read) |
| `rule-adopt` | hub | `*/15 * * * *` | 96 | 96 | lane-gate single run + flock -n | not measured (needs: hub logs/rule-adopt.log or the jobs `lane_runs` read) |
| `rule-miner` | hub | `30 5 * * 1` | 0.14 | 0.14 | lane-gate single run + flock -n | not measured (needs: hub logs/rule-miner.log or the jobs `lane_runs` read) |
| `rules-drift-check` | hub | `13 * * * *` | 24 | 24 | lane-gate single run | not measured (needs: hub logs/rules-drift-check.log or the jobs `lane_runs` read) |
| `run-product` | project-4, project-6-os, project-1, project-3, project-9, small, project-2, project-5 | `1 9 * * 1; 2 9 * * 1; 4 9 * * 1; 5 9 * * 1; 6 9 * * 1; 8 9 * * 1; 9 9 * * 1` | 1.00 | 7.98 | lane-gate single run + flock -n | not measured (needs: hub logs/run-product.log or the jobs `lane_runs` read) |
| `run-triage` | project-4, project-6, project-6-os, project-1, project-3, project-9, small, project-2, project-5 | `1,11,21,31,41,51 * * * *; 2,12,22,32,42,52 * * * *; 3,13,23,33,43,53 * * * *; 4,14,24,34,44,54 * * * *; 5,15,25,35,45,55 * * * *; 6,16,26,36,46,56 * * * *; 8,18,28,38,48,58 * * * *; 9,19,29,39,49,59 * * * *` | 1152 | 10368 | lane-gate single run + flock -n | not measured (needs: hub logs/triage.log or the jobs `lane_runs` read) |
| `scheduler` | hub | `*/5 * * * *` | 288 | 288 | lane-gate single run + flock -n + hub lease | not measured (needs: hub logs/scheduler.log or the jobs `lane_runs` read) |
| `security-scan` | project-4, project-1, project-2 | `0 10 * * 0; 0 14 * * 0; 0 8 * * 0` | 0.43 | 1.28 | lane-gate single run | not measured (needs: hub logs/security-scan.log or the jobs `lane_runs` read) |
| `sentry-triage` | hub | `11,41 * * * *` | 48 | 48 | lane-gate single run + flock -n | not measured (needs: hub logs/sentry-triage.log or the jobs `lane_runs` read) |
| `served-sha-watch` | hub | `*/5 * * * *` | 288 | 288 | lane-gate single run + flock -n | not measured (needs: hub logs/served-sha-watch.log or the jobs `lane_runs` read) |
| `split-watchdog` | hub | `*/10 * * * *` | 144 | 144 | lane-gate single run + flock -n | not measured (needs: hub logs/split-watchdog.log or the jobs `lane_runs` read) |
| `staff` | hub | `*/15 * * * *` | 96 | 96 | lane-gate single run + flock -n | not measured (needs: hub logs/staff.log or the jobs `lane_runs` read) |
| `staff-outcomes` | hub | `37 * * * *` | 24 | 24 | lane-gate single run + flock -n | not measured (needs: hub logs/staff-outcomes.log or the jobs `lane_runs` read) |
| `stale-owed-tickets` | hub | `50 * * * *` | 24 | 24 | lane-gate single run + flock -n | not measured (needs: hub logs/stale-owed-tickets.log or the jobs `lane_runs` read) |
| `standby-verify` |  | `*/5 * * * *` | 288 | 0 | lane-gate single run + flock -n + hub lease | not measured (needs: hub logs/standby-verify.log or the jobs `lane_runs` read) |
| `state-backup` | project-4, hub, project-6, project-6-os, project-1, project-3, project-10, project-9, small, project-2, project-5 | `5,20,35,50 * * * *` | 96 | 1056 | lane-gate single run + flock -n | not measured (needs: hub logs/state-backup.log or the jobs `lane_runs` read) |
| `stranded-watch` | hub | `8,38 * * * *` | 48 | 48 | lane-gate single run | not measured (needs: hub lane log or the jobs `lane_runs` read) |
| `stuck-work` | hub | `*/5 * * * *` | 288 | 288 | lane-gate single run + flock -n | not measured (needs: hub logs/stuck-work.log or the jobs `lane_runs` read) |
| `sweep-stale-builds` | hub | `55 4 * * *` | 1 | 1 | lane-gate single run + flock -n | not measured (needs: hub logs/sweep-stale-builds.log or the jobs `lane_runs` read) |
| `tailscaled-watchdog` | project-4, hub, project-6, project-6-os, project-1, project-3, project-9, small, project-2, project-5 | `*/2 * * * *` | 720 | 7200 | lane-gate single run | not measured (needs: hub logs/tailscaled-watchdog.log or the jobs `lane_runs` read) |
| `testhost-tick` | hub | `*/5 * * * *` | 288 | 288 | lane-gate single run + hub lease | not measured (needs: hub logs/testhost-tick.log or the jobs `lane_runs` read) |
| `tickets-snapshot-push` | hub | `8,18,28,38,48,58 * * * *` | 144 | 144 | lane-gate single run | not measured (needs: hub logs/tickets-snapshot-push.log or the jobs `lane_runs` read) |
| `tmp-sweep` | project-4, hub, project-6, project-6-os, project-1, project-3, project-9, small, project-2, project-5 | `8,23,38,53 * * * *` | 96 | 960 | lane-gate single run + flock -n | not measured (needs: hub logs/tmp-sweep.log or the jobs `lane_runs` read) |
| `trap-eval` | project-4, project-6, project-6-os, project-1, project-3, project-9, small, project-2, project-5 | `on demand (via an operator at the shell; no cron line)` | n/a (no cron line) | n/a | lane-gate single run + flock -n | not measured (needs: hub logs/trap-eval.log or the jobs `lane_runs` read) |
| `unblock-metrics` | hub | `17 * * * *` | 24 | 24 | lane-gate single run + flock -n | not measured (needs: hub logs/unblock-metrics.log or the jobs `lane_runs` read) |
| `untriaged-digest` | hub | `17 6 * * *` | 1 | 1 | lane-gate single run | not measured (needs: hub logs/untriaged-digest.log or the jobs `lane_runs` read) |
| `untriaged-sweep` | hub | `8,38 * * * *` | 48 | 48 | lane-gate single run | not measured (needs: hub logs/untriaged-sweep.log or the jobs `lane_runs` read) |
| `untriaged-wake` | hub | `*/10 * * * *` | 144 | 144 | lane-gate single run | not measured (needs: hub logs/untriaged-wake.log or the jobs `lane_runs` read) |
| `update-model-prices` | hub | `30 4 * * *` | 1 | 1 | lane-gate single run | not measured (needs: hub logs/update-model-prices.log or the jobs `lane_runs` read) |
| `update-runners` | project-4, hub, project-6, project-6-os, project-1, project-3, project-10, project-9, small, project-2, project-5 | `17 5 * * *` | 1 | 11 | lane-gate single run | not measured (needs: hub logs/update-runners.log or the jobs `lane_runs` read) |
| `utilization-push` | hub | `7 * * * *` | 24 | 24 | lane-gate single run + flock -n | not measured (needs: hub logs/utilization-push.log or the jobs `lane_runs` read) |
| `utilization-quiet` | hub | `20 7 * * *` | 1 | 1 | lane-gate single run + flock -n | not measured (needs: hub logs/utilization-quiet.log or the jobs `lane_runs` read) |
| `vendor-spend-pull` | hub | `33 * * * *` | 24 | 24 | lane-gate single run | not measured (needs: hub logs/vendor-spend.log or the jobs `lane_runs` read) |
| `vercel-deploy-snapshot` | hub | `*/4 * * * *` | 360 | 360 | lane-gate single run | not measured (needs: hub logs/vercel-deploy-snapshot.log or the jobs `lane_runs` read) |
| `wake-loop` | project-4, hub, project-6, project-6-os, project-1, project-3, project-10, project-9, small, project-2, project-5 | `* * * * *` | 1440 | 15840 | lane-gate single run + flock -n + hub lease | not measured (needs: hub logs/wake-loop.log or the jobs `lane_runs` read) |
| `watchdog-ping` | project-4, hub, hub2, project-6, project-6-os, project-1, project-3, review2, project-9, small, project-2, project-5 | `*/5 * * * *` | 288 | 3456 | lane-gate single run | not measured (needs: hub logs/watchdog-ping.log or the jobs `lane_runs` read) |
| `watchdog-poll` | hub | `*/2 * * * *` | 720 | 720 | lane-gate single run | not measured (needs: hub logs/watchdog-poll.log or the jobs `lane_runs` read) |
| `watchdog-responder` | hub | `3,23,43 * * * *` | 72 | 72 | lane-gate single run | not measured (needs: hub logs/responder.log or the jobs `lane_runs` read) |

## D1 tables

### D1 tables, all

```text
PATH: every table created in worker/jobs/schema.d/ (206 tables) in the harness-jobs D1
UNIT: rows/day
NOW: not measured (needs: a jobs worker read with HARNESS_SECRET; the d1-count probe covers 4 tables only, and this box has no egress to the worker)
NEXT: 10x (not computable: NOW not measured)
CEILING: D1 overload (see Cloudflare D1 and the jobs worker); reached on 2026-10-14
BREAKS FIRST AT CEILING: D1 overload
SIGNAL: retention_runs audit rows, the d1-overload console line
COST NOW/NEXT/CEILING: not measured / not measured / not measured
BUILT FOR TODAY: 137 of 206 tables have a named index in schema.d; 36 have a rule in worker/jobs/src/routes/retention.js; 144 have neither a retention rule nor any DELETE in the worker
DEFER UNTIL CEILING: a retention rule for each growing table without one; trigger = a table passes 100k rows (the d1-count probe, or a new count route)
```

A table with `none found` under retention has no rule in `retention.js` and no
`DELETE FROM` in the worker source. Some of those are small config tables that
do not grow; the audit could not count rows to tell them apart.

| table | rows/day | indexes (schema.d) | retention rule |
|---|---|---|---|
| `account_leases` | not measured (needs: jobs worker read with HARNESS_SECRET) | `idx_account_leases_live` | no retention.js rule; a DELETE exists in `worker/jobs/src/routes/account-leases.js` |
| `alert_actions` | not measured (needs: jobs worker read with HARNESS_SECRET) | `idx_alert_actions_alert` | none found |
| `alert_decisions` | not measured (needs: jobs worker read with HARNESS_SECRET) | `idx_alert_decisions_alert`, `idx_alert_decisions_at`, `idx_alert_decisions_component` | retention.js: alert_decisions.age (retention.alert_decisions.days, default 90 d) |
| `alert_family_scripts` | not measured (needs: jobs worker read with HARNESS_SECRET) | `idx_alert_family_scripts_enabled_priority` | none found |
| `alert_lines` | not measured (needs: jobs worker read with HARNESS_SECRET) | `idx_alert_lines_applied`, `ux_alert_lines_dedup` | retention.js: alert_lines.applied (retention.alert_lines.applied_days, default 7 d); alert_lines.unapplied (retention.alert_lines.unapplied_days, default 30 d) |
| `alerts` | not measured (needs: jobs worker read with HARNESS_SECRET) | `idx_alerts_family`, `idx_alerts_state` | none found |
| `archie_actions` | not measured (needs: jobs worker read with HARNESS_SECRET) | `idx_archie_actions_day`, `idx_archie_actions_pr` | none found |
| `archie_classes` | not measured (needs: jobs worker read with HARNESS_SECRET) | none named in schema.d (PRIMARY KEY only, if any) | none found |
| `archie_decisions` | not measured (needs: jobs worker read with HARNESS_SECRET) | `idx_archie_decisions_created`, `idx_archie_decisions_initiative` | none found |
| `archie_research` | not measured (needs: jobs worker read with HARNESS_SECRET) | `idx_archie_research_day` | none found |
| `block_categories` | not measured (needs: jobs worker read with HARNESS_SECRET) | none named in schema.d (PRIMARY KEY only, if any) | none found |
| `block_classify_runs` | not measured (needs: jobs worker read with HARNESS_SECRET) | `idx_block_classify_runs_status` | none found |
| `block_findings` | not measured (needs: jobs worker read with HARNESS_SECRET) | `idx_block_findings_at`, `idx_block_findings_cat` | none found |
| `box_commands` | not measured (needs: jobs worker read with HARNESS_SECRET) | `box_commands_box_status`, `box_commands_open` | none found |
| `box_commands_v2` | not measured (needs: jobs worker read with HARNESS_SECRET) | `box_commands_v2_box_status`, `box_commands_v2_open` | none found |
| `box_console_commands` | not measured (needs: jobs worker read with HARNESS_SECRET) | `idx_box_console_commands_box` | none found |
| `box_ssh_state` | not measured (needs: jobs worker read with HARNESS_SECRET) | none named in schema.d (PRIMARY KEY only, if any) | none found |
| `box_status` | not measured (needs: jobs worker read with HARNESS_SECRET) | none named in schema.d (PRIMARY KEY only, if any) | none found |
| `budget_cap_flags` | not measured (needs: jobs worker read with HARNESS_SECRET) | none named in schema.d (PRIMARY KEY only, if any) | none found |
| `budget_catalog` | not measured (needs: jobs worker read with HARNESS_SECRET) | none named in schema.d (PRIMARY KEY only, if any) | none found |
| `build_queue` | not measured (needs: jobs worker read with HARNESS_SECRET) | `idx_build_queue_status` | none found |
| `burn_days` | not measured (needs: jobs worker read with HARNESS_SECRET) | none named in schema.d (PRIMARY KEY only, if any) | none found |
| `call_guard` | not measured (needs: jobs worker read with HARNESS_SECRET) | `idx_call_guard_at`, `idx_call_guard_key` | no retention.js rule; a DELETE exists in `worker/jobs/src/routes/call-guard.js` |
| `ci_batches` | not measured (needs: jobs worker read with HARNESS_SECRET) | `idx_ci_batches_repo_completed` | none found |
| `ci_duration_runs` | not measured (needs: jobs worker read with HARNESS_SECRET) | none named in schema.d (PRIMARY KEY only, if any) | none found |
| `ci_flakes` | not measured (needs: jobs worker read with HARNESS_SECRET) | `idx_ci_flakes_day`, `idx_ci_flakes_repo_kind` | none found |
| `ci_health` | not measured (needs: jobs worker read with HARNESS_SECRET) | none named in schema.d (PRIMARY KEY only, if any) | none found |
| `ci_suite_duration_samples` | not measured (needs: jobs worker read with HARNESS_SECRET) | none named in schema.d (PRIMARY KEY only, if any) | no retention.js rule; a DELETE exists in `worker/jobs/src/routes/ci-durations.js` |
| `ci_suite_durations` | not measured (needs: jobs worker read with HARNESS_SECRET) | none named in schema.d (PRIMARY KEY only, if any) | none found |
| `ci_test_tier_sets` | not measured (needs: jobs worker read with HARNESS_SECRET) | none named in schema.d (PRIMARY KEY only, if any) | none found |
| `cli_versions` | not measured (needs: jobs worker read with HARNESS_SECRET) | `idx_cli_versions_box_at` | none found |
| `closeout_aged` | not measured (needs: jobs worker read with HARNESS_SECRET) | `idx_closeout_aged_project` | none found |
| `concurrency_rules` | not measured (needs: jobs worker read with HARNESS_SECRET) | none named in schema.d (PRIMARY KEY only, if any) | no retention.js rule; a DELETE exists in `worker/jobs/src/routes/rules.js` |
| `conductor_held_pages` | not measured (needs: jobs worker read with HARNESS_SECRET) | `idx_conductor_held_first` | no retention.js rule; a DELETE exists in `worker/jobs/src/routes/conductor-held.js` |
| `config_changes` | not measured (needs: jobs worker read with HARNESS_SECRET) | `idx_config_changes_kind_name` | none found |
| `conflict_hotspot_runs` | not measured (needs: jobs worker read with HARNESS_SECRET) | none named in schema.d (PRIMARY KEY only, if any) | none found |
| `conflict_hotspots` | not measured (needs: jobs worker read with HARNESS_SECRET) | `idx_conflict_hotspots_rank` | no retention.js rule; a DELETE exists in `worker/jobs/src/routes/conflict-hotspots.js` |
| `context_packs` | not measured (needs: jobs worker read with HARNESS_SECRET) | none named in schema.d (PRIMARY KEY only, if any) | none found |
| `cost_cap_changes` | not measured (needs: jobs worker read with HARNESS_SECRET) | `idx_cost_cap_changes_key` | none found |
| `cost_fold_mark` | not measured (needs: jobs worker read with HARNESS_SECRET) | none named in schema.d (PRIMARY KEY only, if any) | none found |
| `cost_project_hourly` | not measured (needs: jobs worker read with HARNESS_SECRET) | `idx_cost_project_hourly_hour` | retention.js: cost_project_hourly.age (retention.cost_project_hourly.days, default 400 d) |
| `cost_reconciliation` | not measured (needs: jobs worker read with HARNESS_SECRET) | `idx_reconcile_end` | none found |
| `cost_rows` | not measured (needs: jobs worker read with HARNESS_SECRET) | `cost_rows_session`, `idx_cost_rows_account`, `idx_cost_rows_pr`, `idx_cost_rows_project_ts`, `idx_cost_rows_run_id`, `idx_cost_rows_ticket`, `idx_cost_rows_ts` | retention.js: cost_rows.archive (retention.cost_rows.archive_days, default 0 d) |
| `cost_rows_live` | not measured (needs: jobs worker read with HARNESS_SECRET) | `cost_rows_live_run`, `cost_rows_live_upd` | no retention.js rule; a DELETE exists in `worker/jobs/src/routes/cost-live.js` |
| `d1_overload_streaks` | not measured (needs: jobs worker read with HARNESS_SECRET) | none named in schema.d (PRIMARY KEY only, if any) | none found |
| `decisions` | not measured (needs: jobs worker read with HARNESS_SECRET) | `idx_decisions_dedupe`, `idx_decisions_stamp` | none found |
| `deploy_queue` | not measured (needs: jobs worker read with HARNESS_SECRET) | `idx_deploy_queue_status` | none found |
| `dequeue_actions` | not measured (needs: jobs worker read with HARNESS_SECRET) | `idx_dequeue_actions_repo_pr_class`, `idx_dequeue_actions_status_created` | none found |
| `dequeue_events` | not measured (needs: jobs worker read with HARNESS_SECRET) | `idx_dequeue_events_created`, `idx_dequeue_events_llm_fp` | none found |
| `docker_pool_leases` | not measured (needs: jobs worker read with HARNESS_SECRET) | `idx_docker_pool_leases_box`, `idx_docker_pool_leases_due`, `idx_docker_pool_leases_ended`, `idx_docker_pool_leases_key`, `uq_docker_pool_leases_live` | retention.js: docker_pool_leases.ended (retention.docker_pool_leases.days, default 30 d) |
| `docker_pool_results` | not measured (needs: jobs worker read with HARNESS_SECRET) | `idx_docker_pool_results_posted`, `idx_docker_pool_results_unread`, `uq_docker_pool_results_claim` | retention.js: docker_pool_results.age (retention.docker_pool_results.days, default 30 d) |
| `extra_usage_snapshots` | not measured (needs: jobs worker read with HARNESS_SECRET) | `idx_extra_usage_ts` | none found |
| `findings` | not measured (needs: jobs worker read with HARNESS_SECRET) | `idx_findings_dedupe`, `idx_findings_stamp` | none found |
| `fix_round_jobs` | not measured (needs: jobs worker read with HARNESS_SECRET) | `fix_round_jobs_box`, `fix_round_jobs_open` | none found |
| `flaky_quarantine` | not measured (needs: jobs worker read with HARNESS_SECRET) | none named in schema.d (PRIMARY KEY only, if any) | none found |
| `flaky_quarantine_changes` | not measured (needs: jobs worker read with HARNESS_SECRET) | `idx_flaky_quarantine_changes_rt` | none found |
| `fleet_cooldowns` | not measured (needs: jobs worker read with HARNESS_SECRET) | `idx_fleet_cooldowns_kind_until` | no retention.js rule; a DELETE exists in `worker/jobs/src/routes/cooldowns.js` |
| `fly_idle_daily` | not measured (needs: jobs worker read with HARNESS_SECRET) | none named in schema.d (PRIMARY KEY only, if any) | none found |
| `fly_idle_destroys` | not measured (needs: jobs worker read with HARNESS_SECRET) | `fly_idle_destroys_destroyed_at` | retention.js: fly_idle_destroys.age (retention.fly_idle_destroys.days, default 400 d) |
| `fly_idle_machines` | not measured (needs: jobs worker read with HARNESS_SECRET) | none named in schema.d (PRIMARY KEY only, if any) | no retention.js rule; a DELETE exists in `worker/jobs/src/routes/fly-idle.js` |
| `fly_idle_pass` | not measured (needs: jobs worker read with HARNESS_SECRET) | none named in schema.d (PRIMARY KEY only, if any) | none found |
| `fly_idle_stops` | not measured (needs: jobs worker read with HARNESS_SECRET) | `fly_idle_stops_stopped_at` | retention.js: fly_idle_stops.age (retention.fly_idle_stops.days, default 400 d) |
| `fly_images` | not measured (needs: jobs worker read with HARNESS_SECRET) | `idx_fly_images_active` | none found |
| `gh_budget` | not measured (needs: jobs worker read with HARNESS_SECRET) | none named in schema.d (PRIMARY KEY only, if any) | none found |
| `gh_ledger` | not measured (needs: jobs worker read with HARNESS_SECRET) | `idx_gh_ledger_hour` | no retention.js rule; a DELETE exists in `worker/jobs/src/routes/gh-ledger.js` |
| `harness_flags` | not measured (needs: jobs worker read with HARNESS_SECRET) | `harness_flags_name` | none found |
| `hotspot_tickets` | not measured (needs: jobs worker read with HARNESS_SECRET) | `idx_hotspot_tickets_filed` | retention.js: hotspot_tickets.age (retention.hotspot_tickets.days, default 365 d) |
| `hub_lease` | not measured (needs: jobs worker read with HARNESS_SECRET) | none named in schema.d (PRIMARY KEY only, if any) | none found |
| `hub_lease_changes` | not measured (needs: jobs worker read with HARNESS_SECRET) | `idx_hub_lease_changes_at` | none found |
| `hub_probe_requests` | not measured (needs: jobs worker read with HARNESS_SECRET) | `idx_hub_probe_status` | none found |
| `initiative_events` | not measured (needs: jobs worker read with HARNESS_SECRET) | `idx_initiative_events_initiative` | none found |
| `initiatives` | not measured (needs: jobs worker read with HARNESS_SECRET) | `idx_initiatives_due` | none found |
| `is` | not measured (needs: jobs worker read with HARNESS_SECRET) | none named in schema.d (PRIMARY KEY only, if any) | none found |
| `jev_risk_calls` | not measured (needs: jobs worker read with HARNESS_SECRET) | `idx_jev_risk_repo_pr` | none found |
| `job_artifacts` | not measured (needs: jobs worker read with HARNESS_SECRET) | `idx_artifacts_kind_updated`, `idx_artifacts_ref` | none found |
| `job_claims` | not measured (needs: jobs worker read with HARNESS_SECRET) | `idx_claims_lane` | none found |
| `job_heartbeats` | not measured (needs: jobs worker read with HARNESS_SECRET) | `idx_heartbeats_beat` | retention.js: job_heartbeats.closed (retention.job_heartbeats.days, default 30 d) |
| `job_phases` | not measured (needs: jobs worker read with HARNESS_SECRET) | `idx_phases_job`, `idx_phases_open` | none found |
| `job_transcripts` | not measured (needs: jobs worker read with HARNESS_SECRET) | `idx_transcripts_job` | none found |
| `jobs` | not measured (needs: jobs worker read with HARNESS_SECRET) | `idx_jobs_created`, `idx_jobs_kind_spawn`, `idx_jobs_project_created`, `idx_jobs_project_status`, `idx_jobs_project_status_created`, `idx_jobs_project_ticket`, `idx_jobs_project_ticket_created`, `idx_jobs_status_created` | none found |
| `landing_decisions` | not measured (needs: jobs worker read with HARNESS_SECRET) | `idx_landing_decisions_at`, `idx_landing_decisions_repo_id` | retention.js: landing_decisions.age (retention.landing_decisions.days, default 90 d) |
| `lane_flag_sightings` | not measured (needs: jobs worker read with HARNESS_SECRET) | `idx_lane_flag_sightings_lane` | none found |
| `lane_machines` | not measured (needs: jobs worker read with HARNESS_SECRET) | `idx_lane_machines_state` | none found |
| `lane_run_hub_load` | not measured (needs: jobs worker read with HARNESS_SECRET) | none named in schema.d (PRIMARY KEY only, if any) | none found |
| `lane_run_wait_alerts` | not measured (needs: jobs worker read with HARNESS_SECRET) | none named in schema.d (PRIMARY KEY only, if any) | no retention.js rule; a DELETE exists in `worker/jobs/src/routes/lane-runs-metrics.js` |
| `lane_runs` | not measured (needs: jobs worker read with HARNESS_SECRET) | `idx_lane_runs_claim`, `idx_lane_runs_lane`, `idx_lane_runs_lane_project`, `lane_runs_live` | none found |
| `lane_snapshot_parts` | not measured (needs: jobs worker read with HARNESS_SECRET) | none named in schema.d (PRIMARY KEY only, if any) | no retention.js rule; a DELETE exists in `worker/jobs/src/routes/lane-snapshots.js` |
| `lane_snapshot_writebacks` | not measured (needs: jobs worker read with HARNESS_SECRET) | `idx_lane_snapshot_writebacks_lp` | no retention.js rule; a DELETE exists in `worker/jobs/src/routes/lane-snapshots.js` |
| `lane_snapshots` | not measured (needs: jobs worker read with HARNESS_SECRET) | none named in schema.d (PRIMARY KEY only, if any) | none found |
| `lane_ticks` | not measured (needs: jobs worker read with HARNESS_SECRET) | `idx_lane_ticks_lane`, `idx_lane_ticks_tick` | retention.js: lane_ticks.stale (retention.lane_ticks.days, default 30 d) |
| `lanes` | not measured (needs: jobs worker read with HARNESS_SECRET) | `idx_lanes_proc_beat`, `idx_lanes_tick` | none found |
| `lead_protected_paths` | not measured (needs: jobs worker read with HARNESS_SECRET) | `lpp_live` | none found |
| `lead_review_requests` | not measured (needs: jobs worker read with HARNESS_SECRET) | `idx_lead_review_requests_status` | none found |
| `ledgers` | not measured (needs: jobs worker read with HARNESS_SECRET) | `idx_ledgers_kind`, `idx_ledgers_kind_status_created`, `idx_ledgers_kind_updated` | none found |
| `lessons` | not measured (needs: jobs worker read with HARNESS_SECRET) | `idx_lessons_cat`, `idx_lessons_esc`, `idx_lessons_merged`, `idx_lessons_status`, `idx_lessons_type` | none found |
| `machines` | not measured (needs: jobs worker read with HARNESS_SECRET) | `idx_machines_key`, `idx_machines_project` | none found |
| `main_red` | not measured (needs: jobs worker read with HARNESS_SECRET) | `main_red_project` | none found |
| `main_red_events` | not measured (needs: jobs worker read with HARNESS_SECRET) | `main_red_events_name` | none found |
| `main_red_pairs` | not measured (needs: jobs worker read with HARNESS_SECRET) | `main_red_pairs_open` | none found |
| `main_red_pr_errors` | not measured (needs: jobs worker read with HARNESS_SECRET) | `main_red_pr_errors_at` | no retention.js rule; a DELETE exists in `worker/jobs/src/routes/main-red-state.js` |
| `main_red_verdicts` | not measured (needs: jobs worker read with HARNESS_SECRET) | none named in schema.d (PRIMARY KEY only, if any) | none found |
| `mc_budget` | not measured (needs: jobs worker read with HARNESS_SECRET) | none named in schema.d (PRIMARY KEY only, if any) | retention.js: mc_budget.age (retention.mc_budget.days, default 30 d) |
| `merge_queue` | not measured (needs: jobs worker read with HARNESS_SECRET) | `idx_merge_queue_status` | none found |
| `merge_queue_batches` | not measured (needs: jobs worker read with HARNESS_SECRET) | none named in schema.d (PRIMARY KEY only, if any) | none found |
| `merge_queue_check_medians` | not measured (needs: jobs worker read with HARNESS_SECRET) | none named in schema.d (PRIMARY KEY only, if any) | none found |
| `merge_queue_checks` | not measured (needs: jobs worker read with HARNESS_SECRET) | `idx_merge_queue_checks_median` | none found |
| `merge_trains` | not measured (needs: jobs worker read with HARNESS_SECRET) | `idx_merge_trains_outcome` | none found |
| `model_prices` | not measured (needs: jobs worker read with HARNESS_SECRET) | none named in schema.d (PRIMARY KEY only, if any) | none found |
| `model_route_changes` | not measured (needs: jobs worker read with HARNESS_SECRET) | `idx_model_route_changes_role` | none found |
| `model_routes` | not measured (needs: jobs worker read with HARNESS_SECRET) | `idx_model_routes_key`, `idx_model_routes_role` | no retention.js rule; a DELETE exists in `worker/jobs/src/routes/model-routes.js` |
| `model_slugs` | not measured (needs: jobs worker read with HARNESS_SECRET) | none named in schema.d (PRIMARY KEY only, if any) | none found |
| `model_watch` | not measured (needs: jobs worker read with HARNESS_SECRET) | `idx_model_watch_status` | none found |
| `orgo_account_reads` | not measured (needs: jobs worker read with HARNESS_SECRET) | none named in schema.d (PRIMARY KEY only, if any) | none found |
| `orgo_computers` | not measured (needs: jobs worker read with HARNESS_SECRET) | `orgo_computers_account` | none found |
| `otp_messages` | not measured (needs: jobs worker read with HARNESS_SECRET) | `idx_otp_messages_received`, `idx_otp_messages_recipient`, `uq_otp_messages_msg` | retention.js: otp_messages.age (retention.otp_messages.days, default 1 d) |
| `outcome_metrics` | not measured (needs: jobs worker read with HARNESS_SECRET) | `idx_outcome_created`, `idx_outcome_day` | none found |
| `participant_machines` | not measured (needs: jobs worker read with HARNESS_SECRET) | `idx_participant_machines_status` | none found |
| `pause_flags` | not measured (needs: jobs worker read with HARNESS_SECRET) | none named in schema.d (PRIMARY KEY only, if any) | none found |
| `pauses` | not measured (needs: jobs worker read with HARNESS_SECRET) | `pauses_live` | none found |
| `phase_contracts` | not measured (needs: jobs worker read with HARNESS_SECRET) | none named in schema.d (PRIMARY KEY only, if any) | none found |
| `pool_holds` | not measured (needs: jobs worker read with HARNESS_SECRET) | none named in schema.d (PRIMARY KEY only, if any) | no retention.js rule; a DELETE exists in `worker/jobs/src/routes/pool-state.js` |
| `pool_record_files` | not measured (needs: jobs worker read with HARNESS_SECRET) | `idx_pool_record_files_reaped`, `idx_pool_record_files_result`, `idx_pool_record_files_unread`, `uq_pool_record_files_file` | retention.js: pool_record_files.reaped (retention.pool_record_files.reaped_days, default 1 d); pool_record_files.unread (retention.pool_record_files.unread_days, default 3 d) |
| `pool_spawns` | not measured (needs: jobs worker read with HARNESS_SECRET) | `idx_pool_spawns_ts` | no retention.js rule; a DELETE exists in `worker/jobs/src/routes/pool-state.js` |
| `pool_terminals` | not measured (needs: jobs worker read with HARNESS_SECRET) | none named in schema.d (PRIMARY KEY only, if any) | none found |
| `pool_tick_summary` | not measured (needs: jobs worker read with HARNESS_SECRET) | none named in schema.d (PRIMARY KEY only, if any) | none found |
| `port_cursor` | not measured (needs: jobs worker read with HARNESS_SECRET) | none named in schema.d (PRIMARY KEY only, if any) | none found |
| `pr_attempts` | not measured (needs: jobs worker read with HARNESS_SECRET) | none named in schema.d (PRIMARY KEY only, if any) | no retention.js rule; a DELETE exists in `worker/jobs/src/routes/pr-state.js` |
| `pr_costs` | not measured (needs: jobs worker read with HARNESS_SECRET) | none named in schema.d (PRIMARY KEY only, if any) | none found |
| `pr_owners` | not measured (needs: jobs worker read with HARNESS_SECRET) | `idx_pr_owners_project` | none found |
| `pr_state_events` | not measured (needs: jobs worker read with HARNESS_SECRET) | `idx_pr_state_events_dedupe`, `idx_pr_state_events_gate`, `idx_pr_state_events_pr`, `idx_pr_state_events_state_at` | none found |
| `preplans` | not measured (needs: jobs worker read with HARNESS_SECRET) | `idx_preplans_project` | no retention.js rule; a DELETE exists in `worker/jobs/src/routes/preplans.js` |
| `price_audit` | not measured (needs: jobs worker read with HARNESS_SECRET) | none named in schema.d (PRIMARY KEY only, if any) | none found |
| `price_fly` | not measured (needs: jobs worker read with HARNESS_SECRET) | none named in schema.d (PRIMARY KEY only, if any) | none found |
| `product_proposals` | not measured (needs: jobs worker read with HARNESS_SECRET) | none named in schema.d (PRIMARY KEY only, if any) | none found |
| `project_leases` | not measured (needs: jobs worker read with HARNESS_SECRET) | none named in schema.d (PRIMARY KEY only, if any) | none found |
| `projects` | not measured (needs: jobs worker read with HARNESS_SECRET) | none named in schema.d (PRIMARY KEY only, if any) | none found |
| `queue_batch_minutes` | not measured (needs: jobs worker read with HARNESS_SECRET) | `idx_queue_batch_minutes_day` | none found |
| `queue_risk_scores` | not measured (needs: jobs worker read with HARNESS_SECRET) | `idx_queue_risk_scores_repo_pr`, `idx_queue_risk_scores_route` | none found |
| `reconcile_memory` | not measured (needs: jobs worker read with HARNESS_SECRET) | none named in schema.d (PRIMARY KEY only, if any) | no retention.js rule; a DELETE exists in `worker/jobs/src/routes/reconcile-memory.js` |
| `reconcile_owner_beat` | not measured (needs: jobs worker read with HARNESS_SECRET) | none named in schema.d (PRIMARY KEY only, if any) | none found |
| `registry_audit` | not measured (needs: jobs worker read with HARNESS_SECRET) | `idx_registry_audit_at` | none found |
| `registry_box_accounts` | not measured (needs: jobs worker read with HARNESS_SECRET) | none named in schema.d (PRIMARY KEY only, if any) | none found |
| `registry_boxes` | not measured (needs: jobs worker read with HARNESS_SECRET) | none named in schema.d (PRIMARY KEY only, if any) | none found |
| `registry_lane_boxes` | not measured (needs: jobs worker read with HARNESS_SECRET) | none named in schema.d (PRIMARY KEY only, if any) | none found |
| `registry_meta` | not measured (needs: jobs worker read with HARNESS_SECRET) | none named in schema.d (PRIMARY KEY only, if any) | none found |
| `registry_projects` | not measured (needs: jobs worker read with HARNESS_SECRET) | none named in schema.d (PRIMARY KEY only, if any) | none found |
| `registry_seed_runs` | not measured (needs: jobs worker read with HARNESS_SECRET) | `idx_registry_seed_runs_started` | none found |
| `restore_lab_runs` | not measured (needs: jobs worker read with HARNESS_SECRET) | `restore_lab_runs_open` | none found |
| `retention_runs` | not measured (needs: jobs worker read with HARNESS_SECRET) | `idx_retention_runs_rule`, `idx_retention_runs_started` | retention.js: retention_runs.age (retention.retention_runs.days, default 90 d) |
| `retry_policies` | not measured (needs: jobs worker read with HARNESS_SECRET) | none named in schema.d (PRIMARY KEY only, if any) | none found |
| `review_gate` | not measured (needs: jobs worker read with HARNESS_SECRET) | none named in schema.d (PRIMARY KEY only, if any) | none found |
| `review_gate_thresholds` | not measured (needs: jobs worker read with HARNESS_SECRET) | none named in schema.d (PRIMARY KEY only, if any) | none found |
| `risk_tiers` | not measured (needs: jobs worker read with HARNESS_SECRET) | `idx_risk_tiers_repo_pr`, `idx_risk_tiers_tier` | none found |
| `roadmap_decisions` | not measured (needs: jobs worker read with HARNESS_SECRET) | `idx_roadmap_decisions_project` | none found |
| `roadmap_idea_events` | not measured (needs: jobs worker read with HARNESS_SECRET) | `idx_roadmap_idea_events_at`, `idx_roadmap_idea_events_idea` | retention.js: roadmap_idea_events.age (retention.roadmap_idea_events.days, default 730 d) |
| `roadmap_ideas` | not measured (needs: jobs worker read with HARNESS_SECRET) | `idx_roadmap_ideas_discarded`, `idx_roadmap_ideas_project_lane_updated`, `idx_roadmap_ideas_project_updated`, `ux_roadmap_ideas_idem`, `ux_roadmap_ideas_source_ref` | retention.js: roadmap_ideas.discarded (retention.roadmap_ideas.discarded_days, default 180 d) |
| `roadmap_links` | not measured (needs: jobs worker read with HARNESS_SECRET) | `idx_roadmap_links_project`, `idx_roadmap_links_repo_issue`, `idx_roadmap_links_state_seen`, `idx_roadmap_links_wave` | none found |
| `roadmap_waves` | not measured (needs: jobs worker read with HARNESS_SECRET) | `idx_roadmap_waves_project`, `idx_roadmap_waves_status`, `ux_roadmap_waves_fp` | retention.js: roadmap_waves.closed (retention.roadmap_waves.days, default 365 d) |
| `route_rule_changes` | not measured (needs: jobs worker read with HARNESS_SECRET) | `idx_route_rule_changes_name` | none found |
| `route_rules` | not measured (needs: jobs worker read with HARNESS_SECRET) | `idx_route_rules_priority` | none found |
| `route_shadow` | not measured (needs: jobs worker read with HARNESS_SECRET) | `idx_route_shadow_at`, `idx_route_shadow_build`, `idx_route_shadow_job` | none found |
| `routing` | not measured (needs: jobs worker read with HARNESS_SECRET) | none named in schema.d (PRIMARY KEY only, if any) | none found |
| `routing_changes` | not measured (needs: jobs worker read with HARNESS_SECRET) | `idx_routing_changes_project` | none found |
| `sched_diffs` | not measured (needs: jobs worker read with HARNESS_SECRET) | `idx_sched_diffs_at`, `ux_sched_diffs_pta` | retention.js: sched_diffs.age (retention.sched_diffs.days, default 30 d) |
| `sched_ready` | not measured (needs: jobs worker read with HARNESS_SECRET) | `idx_sched_ready_at`, `ux_sched_ready_pat` | retention.js: sched_ready.age (retention.sched_ready.days, default 3 d) |
| `sched_ticks` | not measured (needs: jobs worker read with HARNESS_SECRET) | `idx_sched_ticks_at`, `ux_sched_ticks_pa` | retention.js: sched_ticks.age (retention.sched_ticks.days, default 30 d) |
| `setting_sigs` | not measured (needs: jobs worker read with HARNESS_SECRET) | none named in schema.d (PRIMARY KEY only, if any) | none found |
| `settings` | not measured (needs: jobs worker read with HARNESS_SECRET) | none named in schema.d (PRIMARY KEY only, if any) | no retention.js rule; a DELETE exists in `worker/jobs/src/lib/core.js`, `worker/jobs/src/routes/settings.js` |
| `split_watchdog_actions` | not measured (needs: jobs worker read with HARNESS_SECRET) | `idx_split_watchdog_family`, `idx_split_watchdog_last` | none found |
| `staff_agents` | not measured (needs: jobs worker read with HARNESS_SECRET) | none named in schema.d (PRIMARY KEY only, if any) | none found |
| `staff_autonomy_changes` | not measured (needs: jobs worker read with HARNESS_SECRET) | `idx_staff_autonomy_changes_agent_id`, `idx_staff_autonomy_changes_created` | retention.js: staff_autonomy_changes.age (retention.staff_autonomy_changes.days, default 1095 d) |
| `staff_chat` | not measured (needs: jobs worker read with HARNESS_SECRET) | `idx_staff_chat_agent_id`, `idx_staff_chat_agent_state`, `idx_staff_chat_reply_to`, `idx_staff_chat_role_created` | retention.js: staff_chat.age (retention.staff_chat.days, default 365 d) |
| `staff_classes` | not measured (needs: jobs worker read with HARNESS_SECRET) | none named in schema.d (PRIMARY KEY only, if any) | none found |
| `staff_decisions` | not measured (needs: jobs worker read with HARNESS_SECRET) | `idx_staff_decisions_agent`, `idx_staff_decisions_agent_created` | none found |
| `staff_findings` | not measured (needs: jobs worker read with HARNESS_SECRET) | `idx_staff_findings_agent`, `idx_staff_findings_agent_claimed`, `idx_staff_findings_agent_updated`, `idx_staff_findings_done`, `idx_staff_findings_status_id` | retention.js: staff_findings.done (retention.staff_findings.done_days, default 365 d) |
| `staff_lanes` | not measured (needs: jobs worker read with HARNESS_SECRET) | `idx_staff_lanes_lane` | none found |
| `staff_outcomes` | not measured (needs: jobs worker read with HARNESS_SECRET) | `idx_staff_outcomes_agent`, `idx_staff_outcomes_agent_resolved`, `idx_staff_outcomes_family`, `idx_staff_outcomes_resolved` | retention.js: staff_outcomes.age (retention.staff_outcomes.days, default 180 d) |
| `staff_promotion_decisions` | not measured (needs: jobs worker read with HARNESS_SECRET) | `idx_staff_promotion_decisions_agent`, `ux_staff_promotion_decisions_promotion` | none found |
| `staff_promotions` | not measured (needs: jobs worker read with HARNESS_SECRET) | `idx_staff_promotions_decided`, `ux_staff_promotions_pending` | retention.js: staff_promotions.void (retention.staff_promotions.void_days, default 30 d); staff_promotions.applied (retention.staff_promotions.applied_days, default 180 d) |
| `staff_suppressions` | not measured (needs: jobs worker read with HARNESS_SECRET) | `idx_staff_suppressions_fp`, `idx_staff_suppressions_status_created`, `idx_staff_suppressions_status_expires`, `ux_staff_suppressions_pending` | retention.js: staff_suppressions.revoked (retention.staff_suppressions.revoked_days, default 180 d); staff_suppressions.expired (retention.staff_suppressions.expired_days, default 180 d) |
| `staff_ticks` | not measured (needs: jobs worker read with HARNESS_SECRET) | `idx_staff_ticks_agent_started`, `idx_staff_ticks_started` | retention.js: staff_ticks.age (retention.staff_ticks.days, default 90 d) |
| `stage_events` | not measured (needs: jobs worker read with HARNESS_SECRET) | `idx_events_created`, `idx_events_job`, `idx_events_stage_created` | retention.js: stage_events.closed (retention.stage_events.days, default 90 d) |
| `stage_events_daily` | not measured (needs: jobs worker read with HARNESS_SECRET) | none named in schema.d (PRIMARY KEY only, if any) | retention.js: stage_events_daily.archive (retention.stage_events_daily.archive_days, default 0 d) |
| `standby_status` | not measured (needs: jobs worker read with HARNESS_SECRET) | none named in schema.d (PRIMARY KEY only, if any) | none found |
| `standby_verify_runs` | not measured (needs: jobs worker read with HARNESS_SECRET) | `standby_verify_runs_open` | none found |
| `steer_notes` | not measured (needs: jobs worker read with HARNESS_SECRET) | `idx_steer_notes_job`, `idx_steer_notes_outbox`, `idx_steer_notes_ticket` | none found |
| `suite_results` | not measured (needs: jobs worker read with HARNESS_SECRET) | `idx_suite_results_key`, `idx_suite_results_updated` | no retention.js rule; a DELETE exists in `worker/jobs/src/routes/suite-results.js` |
| `suite_reuse_runs` | not measured (needs: jobs worker read with HARNESS_SECRET) | `idx_suite_reuse_runs_created` | none found |
| `telegram_topics` | not measured (needs: jobs worker read with HARNESS_SECRET) | none named in schema.d (PRIMARY KEY only, if any) | none found |
| `ticket_edges` | not measured (needs: jobs worker read with HARNESS_SECRET) | `idx_ticket_edges_at`, `idx_ticket_edges_child`, `ux_ticket_edges_pc` | retention.js: ticket_edges.age (retention.ticket_edges.days, default 365 d) |
| `ticket_holds` | not measured (needs: jobs worker read with HARNESS_SECRET) | `idx_ticket_holds_at`, `idx_ticket_holds_ticket_at`, `ux_ticket_holds_comment` | retention.js: ticket_holds.age (retention.ticket_holds.days, default 365 d) |
| `token_health` | not measured (needs: jobs worker read with HARNESS_SECRET) | none named in schema.d (PRIMARY KEY only, if any) | none found |
| `triage_state` | not measured (needs: jobs worker read with HARNESS_SECRET) | `idx_triage_state_recheck` | none found |
| `utilization_snapshots` | not measured (needs: jobs worker read with HARNESS_SECRET) | `idx_util_hour` | no retention.js rule; a DELETE exists in `worker/jobs/src/routes/utilization.js` |
| `vendor_spend` | not measured (needs: jobs worker read with HARNESS_SECRET) | `idx_vendor_spend_ts` | none found |
| `verdict_history` | not measured (needs: jobs worker read with HARNESS_SECRET) | `idx_verdict_history_job` | none found |
| `verdicts` | not measured (needs: jobs worker read with HARNESS_SECRET) | `idx_verdicts_created`, `idx_verdicts_pr_head` | none found |
| `wake_claims` | not measured (needs: jobs worker read with HARNESS_SECRET) | `idx_wake_claims_box_wake` | no retention.js rule; a DELETE exists in `worker/jobs/src/routes/wakes.js` |
| `wake_cooldowns` | not measured (needs: jobs worker read with HARNESS_SECRET) | none named in schema.d (PRIMARY KEY only, if any) | none found |
| `wake_cursors` | not measured (needs: jobs worker read with HARNESS_SECRET) | none named in schema.d (PRIMARY KEY only, if any) | no retention.js rule; a DELETE exists in `worker/jobs/src/routes/wakes.js` |
| `wake_repo_last` | not measured (needs: jobs worker read with HARNESS_SECRET) | `idx_wake_repo_last_last_id` | none found |
| `wakes` | not measured (needs: jobs worker read with HARNESS_SECRET) | `idx_wakes_at`, `idx_wakes_dedupe`, `idx_wakes_kind_id`, `idx_wakes_repo_id`, `idx_wakes_repo_lc_id`, `idx_wakes_unacked` | retention.js: wakes.age (retention.wakes.days, default 30 d); wakes.acked (retention.wakes.acked_days, default 3 d) |
| `web_vault` | not measured (needs: jobs worker read with HARNESS_SECRET) | `idx_web_vault_last_used`, `uq_web_vault_entry` | none found |
| `web_vault_audit` | not measured (needs: jobs worker read with HARNESS_SECRET) | `idx_web_vault_audit_at`, `idx_web_vault_audit_entry` | retention.js: web_vault_audit.age (retention.web_vault_audit.days, default 90 d) |
| `web_vault_run_token` | not measured (needs: jobs worker read with HARNESS_SECRET) | `idx_web_vault_run_token_at` | retention.js: web_vault_run_token.age (retention.web_vault_run_token.days, default 2 d) |
| `webhook_deliveries` | not measured (needs: jobs worker read with HARNESS_SECRET) | `idx_webhook_deliveries_at` | no retention.js rule; a DELETE exists in `worker/jobs/src/routes/webhooks.js` |

## Per-ticket fan-out

### Tickets shipped and PRs per ticket

```text
PATH: one ticket to N builds, N PRs, N reviews, N CI runs and N comments
UNIT: tickets/day, and PRs per ticket
NOW: 42 tickets/day shipped (src: git log origin/main --first-parent, 294 distinct ticket/bh-* branches merged 2026-10-14..2026-10-20 UTC, 2026-10-21); 1.13 PRs per ticket (333 PRs / 294 tickets, same source)
NEXT: 10x = 420 tickets/day
CEILING: the lowest of the GitHub REST bucket, the pool cap and reviewer throughput (see those blocks)
BREAKS FIRST AT CEILING: GitHub rate limit (see LANDMINES.md)
SIGNAL: the utilization read (/api/utilization), the pipeline-health lane
COST NOW/NEXT/CEILING: not measured / not measured / $4,000 a day (the fleet ceiling)
BUILT FOR TODAY: one branch and one PR per ticket; a rebuild only after a block
DEFER UNTIL CEILING: nothing beyond the vendor blocks; trigger = see GitHub REST
```

### Builds, reviews, CI runs and comments per ticket

```text
PATH: per ticket: builds (run-build.sh and the pool), reviews (lead review), CI runs (harness-ci.yml and the merge queue), board comments
UNIT: builds, reviews, CI runs and comments per ticket
NOW: not measured (needs: the jobs jobs, verdict and ledger rows per ticket from the hub, and the GitHub Actions run list; neither is reachable from this box)
NEXT: 10x (not computable: NOW not measured)
CEILING: see GitHub REST and Fly API
BREAKS FIRST AT CEILING: GitHub rate limit
SIGNAL: call-guard (/api/call-guard), the builds-of-record lib (BH-2312)
COST NOW/NEXT/CEILING: not measured / not measured / $4,000 a day (the fleet ceiling)
BUILT FOR TODAY: re-review only on a new head sha; CI repair rounds capped by BR_CI_REPAIR_ROUNDS
DEFER UNTIL CEILING: nothing; trigger = call-guard trips more than 5 times in a day
```

## Human-rate consumers

### PR review capacity per project

```text
PATH: the human who reads a project's PRs and board (the harness itself merges on its own double gate; no merge waits on a human)
UNIT: PRs/day per project a person reads
NOW: not measured (needs: a per-project count of PRs a person opened or commented on; the repo holds no such ledger)
NEXT: 10x (not computable: NOW not measured)
CEILING: not measured (needs: an operator's statement of PRs a day they can read)
BREAKS FIRST AT CEILING: reviewer throughput
SIGNAL: none today
COST NOW/NEXT/CEILING: $0 / $0 / $0 (no vendor cost; the cost is a person's time)
BUILT FOR TODAY: one PR per ticket and a what-shipped board comment
DEFER UNTIL CEILING: a daily digest per project in place of per-PR reads; trigger = an operator asks for it
```

### Telegram alert volume

```text
PATH: pages and warn lines that reach the operator on Telegram (bin/lib/page-critical.sh, alert-flush, alert-warn-flush, alert-digest)
UNIT: alerts/day
NOW: not measured (needs: the hub's ALERTS.log or the jobs alerts read)
NEXT: 10x (not computable: NOW not measured)
CEILING: not measured (needs: an operator's statement of pages a day they act on)
BREAKS FIRST AT CEILING: reviewer throughput
SIGNAL: alerts-groom and alerts-medic (hub), the alert families in /api/alerts
COST NOW/NEXT/CEILING: $0 / $0 / $0
BUILT FOR TODAY: critical pages direct; warn lines flushed every 30 min; one digest a day
DEFER UNTIL CEILING: a page budget per day; trigger = more than 50 pages in one day
```
