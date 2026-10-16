# Events, not clocks — the GitHub webhook → `wakes` → wake loop path

<!-- changes:begin -->
> **What changed since this doc was written lives in [`docs/notes/`](notes/INDEX.md)**, one dated note per change. Add a note there instead of appending here; guardrail `doc-monolith-edit` checks it once it is armed in CI (the adoption PR that `guardrails/README.md` prescribes; not yet opened).
<!-- changes:end -->

> **STATUS: ARMED ON THE HUB (2026-09-12; verified draining 2026-09-14).** The
> org hook, the worker secret and the hub's `* * * * *` line are all in place —
> `logs/wake-loop.log` shows live drains every 15s. On a fleet where §4 has NOT
> been done nothing happens: every lane fires on the cron cadence it fires on
> today, byte for byte.

## 1. The wait this exists to remove

the operator, 2026-09-12: every post-review stage of a ticket advanced only when a clock
said so.

| Stage | Owner | Cadence | Worst-case wait |
|---|---|---|---|
| PR opened / pushed / reviewed / checks green | `bin/merge-conductor.sh` | `*/5` | 5 min |
| Merge | `bin/merge-sweep.sh` | every 10 min | 10 min |
| Deploy | `bin/deploy-train.sh` | `*/15` + a 20-min self-source floor | 15–35 min |
| Post-merge production QA | `bin/postmerge-qa.sh` | every 30–60 min | 60 min |
| Board close-out / next ticket | `bin/triage-gate.sh` | 10-min tick, 45-min queue brake | 45 min |

Stacked, that is **150–240 minutes of pure waiting per ticket** with nothing
wrong anywhere — and no webhook receiver existed in `bin/`, `worker/` or
`console-ui/functions`. The only way the fleet ever learned GitHub had changed
was to go and look, on a schedule.

## 2. The shape

```
GitHub (org-level webhook)
   │  POST /webhooks/github        X-Hub-Signature-256, raw body
   ▼
harness-jobs worker  ──►  D1 table `wakes`   {repo, kind, key, minute, at}
   │  GET /api/wakes?since=<id>   (bearer, like every other lane route)
   ▼
hub: bin/wake-loop.sh  (cron `* * * * *`, four internal 15s cycles)
   │
   ├─ pr, checks  ─► bin/merge-conductor.sh          (fleet-wide, one launch per batch)
   ├─ push(main)  ─► bin/deploy-train.sh <project>
   │                 + bin/unblocked-children.sh <project> ─► if a child was
   │                   released: bin/launch-fastpath.sh <project> <keys> first,
   │                   then bin/run-triage.sh <project> on its OWNING box for
   │                   whatever it declined
   ├─ deploy ok   ─► bin/postmerge-qa.sh <project>
   └─ issue       ─► touch state/wake-<project> (bin/triage-gate.sh consumes it,
                     one-shot) + bin/launch-fastpath.sh <project> <key> first,
                     then bin/run-triage.sh <project> on its OWNING box for
                     whatever it declined
```

### Event → wake kind → lane

What `wakeOf` (`worker/jobs/src/lib/core.js`) makes of each subscribed delivery.
Anything not listed, or listed with another action or state, is answered 202
and writes no row. The subscription list is `bin/webhook-rearm.sh --print-events`.

| Delivery | Condition | Wake kind (key) | Lane |
|---|---|---|---|
| `pull_request` | `opened` `synchronize` `reopened` `closed` `ready_for_review` | `pr` (number) | `bin/merge-conductor.sh` (hub) + the `pr-ci`/`pr-closed` wake classes |
| `pull_request_review` | `submitted` `dismissed` `edited` | `pr` (number) | `bin/merge-conductor.sh` (hub) |
| `issue_comment` | `created` `edited`, on a PR | `pr` (number) | `bin/merge-conductor.sh` (hub) |
| `issue_comment` | `created` `edited`, on an issue | `issue` (number) | triage un-brake + `bin/run-triage.sh` on the owning box |
| `issues` | `opened` `edited` `closed` `reopened` | `issue` (number) | triage un-brake + `bin/run-triage.sh` on the owning box |
| `issues` | `labeled` with `ai-build` or `hotfix` (any case; other labels and `unlabeled` dropped) — BH-4058 | `issue` (number) | same as above |
| `check_suite` | `completed` | `checks` (head sha) | `bin/merge-conductor.sh` (hub, keyed by head sha via pr-state.tsv, unkeyed on a miss) + the `flaky`/`pr-ci` wake classes |
| `check_run` | `completed` | `checks` (head sha) | `bin/merge-conductor.sh` (hub, keyed by head sha via pr-state.tsv, unkeyed on a miss) |
| `status` | `success` `failure` `error` (`pending` dropped) — BH-4058 | `checks` (sha) | `bin/merge-conductor.sh` (hub, keyed by head sha via pr-state.tsv, unkeyed on a miss) |
| `workflow_run` | `completed` — BH-4058 | `checks` (head sha) | `bin/merge-conductor.sh` (hub, keyed by head sha via pr-state.tsv, unkeyed on a miss) |
| `push` | the repo's default branch only (`repository.default_branch`, else `main`) — BH-6963 | `push` (after sha; event `push.<before>..<after>` when both are full shas and `before` is not all zeros, else `push`) | `bin/deploy-train.sh` + the `push` wake class + `bin/repair-on-push.sh` (reads by its own cursor, not a claim) |
| `deployment_status` | `success` | `deploy` (deployment sha) | `bin/postmerge-qa.sh` + the `deploy` wake class |
| `deployment_status` | `failure` `error` — BH-4058 | `deploy_failed` (deployment sha) | recorded; no lane yet (#1034 follow-up); cron covers it |
| `merge_group` | `checks_requested` `destroyed` — BH-4058 | `merge_group` (head sha) | recorded; no lane yet (#1034 follow-up); cron covers it |
| harness-jobs `POST /api/queue` (not a webhook) — BH-4169; `PUT /api/jobs/:id/artifacts` (`artifact_kind=fly_result`) — BH-4171 | row lands `queued`, `target=fly`; `fly_result` artifact written (`fly/builder-runner.sh` `fly_result_put`) | `queue` (`<project>:<KEY>` / `<project>:<job id>`, repo `harness/build-queue`) | `bin/fly-dispatch.sh` + `bin/fly-pool-tick.sh` (hub, class flag `wake-lanes-queue`, one launch of each per drain) |

`merge_group` is its own kind on purpose: its head sha is a temporary merge
commit that is in no PR's pr-state row, so as `checks` it would buy an unkeyed
(full-scope) conductor run on every queue entry. `deploy_failed` is its own
kind because a `deploy` row launches post-merge QA.

`bin/fly-results-ingest.sh` stays on its own `*/2` timer: a `fly_result`
wake does not launch it. It holds no flock, so a wake-launched copy racing the
cron copy could ingest one RESULT twice, and its relay hold is sized in sweep
intervals against the builder's 600 s idle autostop (the "THE ARITHMETIC IS
THE WHOLE POINT" header). The two lanes the wake does launch collect a
finished RESULT under their own flocks: `bin/fly-dispatch.sh` hands it to the
ingest while holding its lock, and `bin/fly-pool-tick.sh`'s `bin/fly-pool.sh`
reaps it under `locks/fly-pool-<project>.lock`.

**The fast-path hop is live.** `bin/launch-fastpath.sh` is the real launcher
(§5.7) and `bin/wake-loop.sh` calls it before `bin/run-triage.sh` — locally on
a hub-owned project, and as the first half of the `ssh` command on a box-owned
one (BH-555, #728). It is the flag `flags/fastpath-off` on the hub, not a
missing caller, that takes the hop back out: `fp_on` then never calls it and
the command is byte-identical to the pre-fast-path tick.

| Wake kind | What runs | Where | Guard before it runs |
|---|---|---|---|
| `pr`, `checks` | `bin/merge-conductor.sh` | the hub (it is fleet-wide) | `cooled pr fleet`, one launch per batch |
| `push` (main) | `bin/deploy-train.sh <project>` | the hub | `cooled push <project>` |
| `push` (main) | `bin/repair-on-push.sh` (its own `* * * * *` cron, not launched by the wake loop): `mc_rebase` on each open harness PR whose files intersect the push | the hub | its wake cursor (`wake_cursors` box `repair-on-push`), the conductor PR lock, `REPAIR_PUSH_BUDGET` |
| `push` (main) | `bin/launch-fastpath.sh <project> <keys>` first, then `bin/run-triage.sh <project>` for the declined keys | the box `fleet.conf` names | `cooled triage <project>`, **and** `bin/unblocked-children.sh` must name a released child |
| `deploy` | `bin/postmerge-qa.sh <project>` | the hub | `cooled deploy <project>` |
| `issue` | `touch state/wake-<project>`, then `bin/launch-fastpath.sh <project> <key>` first, then `bin/run-triage.sh <project>` for the declined keys | the box `fleet.conf` names | `cooled triage <project>` |

**A closure is about the tickets it RELEASED (§5.4, 2026-09-15).** An `issue` wake
whose object turns out to be CLOSED, and a `push` whose merge closed something,
expand their scope to the OPEN ai-build issues whose `Blocked-by:` lines name it —
and carry the closure itself to the owning box in `state/wake-closed-<project>`.
The same expansion first closes any decompose parent whose children have all
merged, because the tickets chained behind a split are blocked by the *parent's*
number. `flags/revdep-wake-off` puts all of it back.

**The triage launch goes to the OWNING box (2026-09-14).** This loop runs only on
the hub (`cron/hub.cron` is the one crontab with a `wake-loop.sh` line) and no
row in `fleet.conf` puts a watcher on the hub — every project names a box. So
until now the issue wake's `touch state/wake-<project>` landed on a machine
where that project's `bin/triage-gate.sh` never runs, and reached nothing at
all: `2026-09-14 04:21:17Z issue[project-5]: triage gate un-braked for the next
tick`, written on the hub, for a lane that ticks on `box-project-5-1`.
The launch now travels the way `bin/poll-commands.sh`'s `run_triage` handler has
sent it since the fleet split — `ssh -n root@<box>`, `nohup setsid` on the far
side so the tick outlives the connection, backgrounded on the near side so a
slow box never makes the doorbell deaf. The un-brake rides the same connection,
so it lands where it is read and the tick that was just bought answers `RUN
event-wake` instead of `SKIP queue-unchanged`.

**Never a second session on one ticket.** Three guards, in cost order: the
`(triage, project)` cooldown stops the ssh being paid for at all; a push launches
only when `bin/unblocked-children.sh` actually names a released child; and
`bin/run-triage.sh` takes a per-project `flock` as its first real act, so a
launch that races the cron tick logs `previous run still active, skipping` and
exits — the same collapse two cron ticks already get.

Since triage shards (2026-09-14, docs/BUILD-CONCURRENCY.md) that third guard
covers **seconds of dispatch** rather than hours of session, so a wake launch
that arrives while shards are running usually does NOT collapse on it — and does
not need to. It re-runs the gate, recomputes the scope, finds every key's
`locks/triage-key-<project>-<KEY>.lock` held by the shard already working it, and
logs `dispatched 0 shards: (none) — skipped N held`. The dedupe moved from "one tick at a time" to
"one session per ticket", which is the stronger statement: a wake can now buy
work on the tickets nobody is reading yet instead of being thrown away whole.

**A push only buys a tick when it released a child.** The row carries a head sha
and nothing else (§3, identifiers only), so "what did this merge close" is a free
`gh issue list --state closed` over the ai-build issues plus a `closedAt` window
(`WAKE_PUSH_WINDOW_S`, 900s). Those numbers go into `bin/unblocked-children.sh`
exactly as a `bin/gate-diff.sh` line would, and only its output — a ticket whose
every `Blocked-by` is now closed, or (since W2-G) one whose still-open blockers
all came back `SOFT` from `bin/dep-verify.sh` — launches anything. The conductor and the
deploy train already own the rest of a merge's aftermath; the released child is
what nothing owned (TK-332 sat 3.5 h that way). In-app board projects have no
`Blocked-by` convention, so a push there launches no triage.

**The cron lines stay.** This path is a shortcut and never a dependency. With
the webhook uninstalled, `GITHUB_WEBHOOK_SECRET` unset, harness-jobs
unreachable, or `bin/wake-loop.sh` not installed, no wake is ever read and every
lane ticks exactly as it does today. Nothing anywhere waits for a wake.

## 3. What the receiver believes

**Identifiers only.** A verified signature proves the *sender* holds the shared
secret. It proves nothing about whether the body describes something that
really happened. So the receiver keeps the repo slug and one identifier — a PR
number, an issue number, a head sha — and discards every other word: no title,
no branch, no actor, no `"merged": true`. The lanes still re-read GitHub exactly
as they do today. The worst a signed lie can achieve is one early tick of a lane
that then looks and finds nothing to do.

**Idempotent on `(repo, kind, key, minute)`.** GitHub redelivers, and a PR that
is synchronized, reviewed and check-completed inside one minute is one doorbell
press as far as the conductor is concerned — it re-reads the whole PR either
way. The unique index plus `ON CONFLICT DO NOTHING` means a redelivery storm
cannot become a launch storm; the receiver answers `duplicate: true`.

**Dedup before spend.** Two of the owning scripts buy metered LLM work (the
conductor's head-bound re-review, post-merge QA's `prodqa` lane). `wake-loop.sh`
checks a per-`(kind, project)` cooldown file *before* launching anything — at
most one launch per lane per `WAKE_COOLDOWN_S` (default 120s) however many rows
arrive. Wakes inside the window are still acked; they collapse onto the one
launch, which is what the lane would have done with them anyway.
The conductor carries two more brakes of its own, because it is the biggest
spender here (40-60 API calls a run). `WAKE_CONDUCTOR_PER_TICK` caps how many
times ONE invocation may launch it — the cooldown is the brake between ticks,
this is the brake inside one, since a cron minute polls four times and each
cycle can find a fresh pr wake. Over the cap the wake is still acked and the
loop writes one line saying so; `cron/hub.cron`'s `*/5 merge-conductor.sh` is
why a held launch is a launch deferred by minutes rather than a launch lost.
And while `bin/lib/gh-budget.sh` answers *low* for the `wake-loop` lane, the
conductor's window is multiplied by `WAKE_BUDGET_STRETCH` — a nearly-spent
GitHub hour is exactly when the loop should start fewer of them. The lib is
optional: absent, or answering *healthy* or *unknown*, the window is unchanged.

**An issue event runs that project's own tick, on that project's own box.**
It writes `state/wake-<project>` — which `bin/triage-gate.sh` consumes one-shot
*before* its 45-minute queue brake — and then launches `bin/run-triage.sh` for
it. The gate still decides what to do; the wake is what stops the tick being
braked past a client's comment, and the launch is what stops it waiting up to
ten minutes for a cron line to arrive (the operator, 2026-09-14). `flags/wake-launch-off`
puts it back to the un-brake alone.

**The watermark is local.** `state/wake-cursor` holds the highest row id this
box has handled and every poll asks `?since=<cursor>`. An ack that fails to land
therefore cannot make a lane run twice — `POST /api/wakes/ack` is housekeeping
for the operator's backlog view, never the guard.

## 4. Ops — arming it

Three steps, in this order. Steps 1 and 2 are safe on their own; the receiver is
live but unarmed after step 1 and stays inert until step 3.

### 4.1 Deploy the worker

The schema apply is a **separate command** from the deploy (`worker/jobs/README.md`
§Deploy) — `wrangler deploy` does not run `schema.sql`, and skipping the first
line would leave the receiver answering 500 on every delivery because `wakes`
does not exist yet.

```bash
set -a; . /root/harness/env/cloudflare.env; set +a
cd worker/jobs
npm test                                                            # 181 assertions, no network, no secrets
npx wrangler d1 execute harness-jobs --remote --file=./schema.sql   # additive, re-runnable; creates `wakes`
npx wrangler deploy
```

### 4.2 Set the secret

Generate a value and keep it somewhere you can paste it again in 4.3 — it goes
into two homes and nowhere else (`~/.claude/rules/key-rotation.md`).

```bash
openssl rand -hex 32           # generate; DO NOT commit it, do not echo it into a file
cd worker/jobs
npx wrangler secret put GITHUB_WEBHOOK_SECRET     # paste at the prompt
```

The value is typed at the prompt, never passed as an argument (argv is visible
in the process table) and never written to `wrangler.jsonc`. **Unset is the safe
state:** with no secret the receiver answers `503` and writes nothing.

### 4.3 Create the webhook — PER REPO, not org-wide

> **Corrected 2026-09-16.** This section used to say "one hook for the whole
> org, not one per repo … so there is no per-repo bookkeeping to keep in sync
> with `fleet.conf`", and that the admin PAT in `env/github-admin.env` carries
> `admin:org_hook`. Neither is true in production:
>
> ```bash
> $ gh api /orgs/example-org/hooks
> {"message":"Resource not accessible by personal access token", "status":"403"}
> ```
>
> The 2026-09-12T23:52Z arming hit that 403 and fell back to a loop over the
> eight fleet repos that existed at that minute. The doc was not corrected, so
> `bin/load-project.sh` was written with no doorbell step — and when it
> onboarded **cromford** on 2026-09-15 that project got a registry row, a
> prompt and five cron lines and **no hook**. It produced zero `wakes` rows ever
> (project-5 had 448 in the same id range), `bin/triage-gate.sh` never reached
> its event-wake escape and braked every tick to `SKIP queue-unchanged`, and
> `bin/orphan-reconcile.sh`'s 5-per-tick safety net became the project's only
> intake: 76 open `ai-build` issues behind 2 open PRs, with nothing anywhere
> saying why.
>
> **So a hook is per-repo bookkeeping, and it is kept in sync by machine:**
> `bin/load-project.sh` asks for every repo it onboards, and
> `bin/doorbell-coverage-check.sh` (hub, daily 05:50Z) walks `fleet.conf` and
> writes ONE `ALERTS.log` line per unarmed repo per day, carrying the command
> below. Run it by hand any time: `bin/doorbell-coverage-check.sh`, or
> `--repo <owner/repo>` for one.
>
> An org-level hook remains the better shape and would make all of this
> unnecessary — it needs a token with `admin:org_hook`, which is an operator
> action, not a code change. Until one exists, per-repo is the contract.

Deliveries for repos the fleet does not run are acked and dropped by
`repo_project()` in `wake-loop.sh`, so arming a repo too widely is harmless;
arming none is what costs a project its intake.

```bash
gh api -X POST /repos/example-org/<repo>/hooks \
  -f name=web \
  -F active=true \
  -f 'config[url]=https://harness-jobs.operator.workers.dev/webhooks/github' \
  -f 'config[content_type]=json' \
  -f 'config[insecure_ssl]=0' \
  -f 'config[secret]=PASTE_THE_SAME_SECRET_HERE' \
  -f 'events[]=pull_request' \
  -f 'events[]=pull_request_review' \
  -f 'events[]=check_suite' \
  -f 'events[]=check_run' \
  -f 'events[]=push' \
  -f 'events[]=deployment_status' \
  -f 'events[]=issues' \
  -f 'events[]=issue_comment' \
  -f 'events[]=status' \
  -f 'events[]=workflow_run' \
  -f 'events[]=merge_group'
```

**Re-arming existing hooks (BH-4058).** A hook armed before 2026-10-03 lacks
`status`, `workflow_run` and `merge_group`. `bin/webhook-rearm.sh` (hub,
by hand) reads every fleet repo's hooks and adds the canonical events to the
ones pointing at the receiver. It is a dry run by default; `--apply` sends a
`PATCH` whose body is `{"events": [...]}` only: the union of what the hook has
and the canonical list, with no `config` key, so the secret is never read or
sent and no event is ever removed. It never creates a hook and never
re-activates an inactive one. `--repo <owner/repo>` checks one repo. An
App-level webhook is only reported (`APP_HOOK missing: …`): its event list and
the App permissions it needs (Commit statuses, Actions, Merge queues: read) are
changed on the App settings page.

`config[secret]` **must be pasted by the operator** — the same value set in 4.2.
It is never stored in this repo, never printed by any script here, and the `gh`
call above is the only place it is typed outside the wrangler prompt. **This is
exactly why no script in `bin/` can arm a repo for you**, and why
`bin/doorbell-coverage-check.sh` only ever reports.

A repo hook needs `admin:repo_hook`; the admin PAT in `env/github-admin.env`
has it (it is what the coverage check reads with), the default hub PAT does not
(`bin/lib/gh-repo-token.sh` documents which token sees what). Neither carries
`admin:org_hook` — see the note at the top of this section.

GitHub sends a `ping` immediately. A healthy arming looks like:

```bash
gh api /repos/example-org/<repo>/hooks --jq '.[] | {id, url: .config.url, active, last_response}'
# last_response.status == "active", code 200

bin/doorbell-coverage-check.sh          # the whole registry, one line per repo
```

### 4.4 Install the loop on the hub

The line is already in `cron/hub.cron`, which `bin/update-runners.sh` re-applies
daily; to install it now:

```bash
ssh root@<hub> 'crontab -l | grep -q wake-loop.sh || (crontab -l; echo "* * * * * /root/harness/bin/wake-loop.sh") | crontab -'
```

These images have cron and supervisord but **no systemd**
(`MULTI-MACHINE-PLAN.md`, "Known sharp edges"), so the default is a one-minute
cron line that polls four times internally — the same 15-second pickup
`bin/poll-commands.sh` already gets, needing no supervisor and no process that
can silently die between deploys. If you would rather supervise it:

```ini
[program:wake-loop]
command=/root/harness/bin/wake-loop.sh
environment=WAKE_LOOP_CYCLES="0"
autorestart=true
```

A single `flock` on `locks/wake-loop.lock` means the cron line and a supervised
copy can never both be draining the table, so the two shapes are safe to
overlap during a migration.

### 4.5 Rotating the secret

`GITHUB_WEBHOOK_SECRET` has exactly **two homes** and rotating one without the
other silently stops every delivery (`~/.claude/rules/key-rotation.md`):

1. the Cloudflare worker secret (`npx wrangler secret put GITHUB_WEBHOOK_SECRET`
   from `worker/jobs/`), and
2. `config[secret]` on the org hook
   (`gh api -X PATCH orgs/example-org/hooks/<id> -f 'config[secret]=…'` — the PATCH
   must repeat `config[url]` and `config[content_type]`, GitHub replaces the
   whole config object).

It lives in no env file on any box: nothing on the hub side ever needs it, only
the worker and GitHub. The dead-secret symptom is deliveries turning red in
`gh api orgs/example-org/hooks --jq '.[].last_response'` with code **401**
(`{"error":"bad signature"}`) while every lane quietly falls back to its cron
cadence — nothing breaks, it just gets slow again, which is why the check
belongs in the rotation and not in an alert.

## 5. Operating it

```bash
bin/jobs-client.sh wakes              # the unacked backlog: id, repo, kind, key, event, at
bin/jobs-client.sh wakes 120          # everything past row 120
bin/jobs-client.sh wakes-ack 121 122  # ack by hand
tail -f /root/harness/logs/wake-loop.log
cat /root/harness/state/wake-cursor   # this box's watermark
```

| Knob | Default | What it does |
|---|---|---|
| `flags/wake-loop-off` | absent | Kill switch. The loop drains nothing; cron is all that is left. |
| `flags/wake-launch-off` | absent | Kill switch for the triage launch only. An issue wake goes back to touching `state/wake-<project>` and nothing else, a push wake back to the deploy train alone — the loop of 2026-09-13, byte for byte. |
| `WAKE_COOLDOWN_S` | `120` | Minimum seconds between two launches of the same `(kind, project)`. |
| `WAKE_CONDUCTOR_PER_TICK` | `1` | How many times one INVOCATION may launch `bin/merge-conductor.sh`. `0` = unlimited. `push`/`deploy`/`issue` wakes never count against it, and two projects' pr wakes in one drain were always one launch (the conductor is fleet-wide). A non-numeric value falls back to `1` with one log line; an explicit number is never clamped. With `WAKE_LOOP_CYCLES=0` an invocation is the whole process, so set `0` there. |
| `WAKE_BUDGET_STRETCH` | `5` | Multiplier on `WAKE_COOLDOWN_S` for the conductor launch alone, applied while `gh_budget_low wake-loop` (`bin/lib/gh-budget.sh`) answers low. No lib, or rc 1 (healthy) / rc 2 (unknown), means no stretch. A non-numeric value falls back to `5` with one log line. |
| `WAKE_TRIAGE_COOLDOWN_S` | `$WAKE_COOLDOWN_S` | The same window for the triage launch alone, so an operator can slow down the one lane here whose launch buys a session without slowing the doorbell. |
| `WAKE_PUSH_WINDOW_S` | `900` | How far back a push wake looks for an ai-build issue that closed — and, since §5.4, for a merged PR whose `closes #N` did the closing — when deciding whether the merge released a `Blocked-by` child. |
| `flags/revdep-wake-off` | absent | Kill switch for the reverse-dependency expansion and the decompose-parent close (§5.4). |
| `WAKE_LOOP_CYCLES` | `4` | Poll cycles per invocation. `0` = run forever (supervisord/`@reboot`). |
| `WAKE_LOOP_INTERVAL_S` | `15` | Seconds between cycles. |
| `flags/gh-app-tokens-off` | absent | Also stops the loop's App-token warm pass (§8.1). |

**Rolling it back** is a one-liner and needs no deploy: `touch
/root/harness/flags/wake-loop-off`. To go further, `gh api -X PATCH
orgs/example-org/hooks/<id> -F active=false` stops deliveries at the source. Either
way the fleet lands back on its cron cadence, which is where it was on
2026-09-11.

## 5.1 Ringing the doorbell from a lane (2026-09-14, W2-B)

Every row in `wakes` so far came from GitHub. A **builder** that has just opened
a PR knows there is something for the conductor to look at before any webhook
round-trip has been observed, and the whole point of the builder-direct path
(docs/HUB-THINNING-PLAN.md) is that no stage of a finished build waits on a tick.

`bin/jobs-client.sh wake-put <repo> <kind> <key>` is that call, and
`bin/run-build.sh`'s close-out block makes it once, as `pr`, with the PR number.
Identifiers only, exactly like the receiver (§3): a repo slug, a kind and one
key. Nothing about state, nothing about a verdict.

**The worker route does not exist yet.** `POST /api/wakes` is specified in
docs/HARNESS-COORDINATION.md ("Endpoints this client calls that the worker still
owes") for the worker change. Until it lands, `wake_put` is a **fail-open
no-op**: the worker 404s, `_jobs_req` prints nothing and returns nonzero, the
caller ignores it — and the conductor is still rung on that same PR by GitHub's
own `pull_request` delivery, which is the path armed on 2026-09-12. So nothing
waits on this either way; it removes one webhook round-trip, not a clock.

When the route lands it must keep the receiver's two properties or it is not the
same table: **identifiers only**, and **idempotent on `(repo, kind, key,
minute)`** — a builder retrying its close-out must not become a second launch.

## 5.2 The two log lines the dependency check writes (2026-09-14, W2-G)

`bin/unblocked-children.sh` runs on every tick and on every `push` wake, and
since W2-G it no longer just READS `Blocked-by:` lines — it judges them
(docs/BUILD-CONCURRENCY.md, "Verified dependencies"). Each verdict is one line in
`logs/<project>.log`, written whether or not anything was widened:

| line | means |
|---|---|
| `DEP_SOFT <child> vs <blocker> — <why>` | the child's planned files are disjoint from the blocker's file set **and** its pre-plan declares `DEPENDS: #<blocker> soft`. The child is emitted as `UNBLOCKED` and builds on the default branch now |
| `DEP_HARD <child> vs <blocker> — <why>` | the evidence says the child sits on the blocker's code: overlapping planned files, a `DEPENDS: … hard` line, or a `Blocked-by: #N (hard)` / `Needs: #N` escape hatch in the issue body. Today's `STACKABLE`/wait behaviour, unchanged |
| `DEP_SOFT <child> vs <blocker> — UNKNOWN, released (DEP_UNKNOWN_MODE=soft): <why>` | the question could not be answered — no pre-plan yet, no `DEPENDS:` line, no file evidence for the blocker — and the box is on the default `DEP_UNKNOWN_MODE=soft`, so the pair counts like `SOFT`: the child is emitted as `UNBLOCKED` (its line says `dep-unverified, released` rather than `dep-verified soft`) and builds on the default branch now; a real overlap is the merge conductor's self-rebase's to resolve |
| `DEP_HARD <child> vs <blocker> — UNKNOWN, treated as hard: <why>` | the same unanswerable question on a box with `DEP_UNKNOWN_MODE=hard`: the pre-2026-09-16 fail-closed wait |

A wave that stays five levels deep because every child came back `UNKNOWN` has to
be distinguishable from a wave nobody checked, which is why the `UNKNOWN`s are
logged rather than skipped — and, since 2026-09-16, why they are logged with the
mode that decided them. Until then `UNKNOWN` was obeyed like `HARD`, and it was the
commonest verdict by far (a decomposed child has no pre-plan until the pre-plan lane
reaches it): project-5 at 05:04Z had 22 of 49 open tickets held that way with the
Fly pool cap already at 0/unlimited. the operator: "There should be no cap, let's remove the
cap." `DEP_UNKNOWN_MODE` in `env/global.env` (default `soft`) is that removal;
`hard` is the old behaviour. Nothing here is a wake and nothing here polls: the
lines are written by the pass the tick already runs.

`DEP_VERIFY=0` in `env/global.env`, or `flags/dep-verify-off`, and no verdict is
asked for and no line is written.

## 5.3 The tick that runs the pass (2026-09-14)

Two of the dependency pass's classes were live code nothing ever called.

**`event-wake` is a board tick.** `bin/triage-gate.sh` answers `RUN event-wake`
for a delivery (§2) and `bin/run-triage.sh`'s scope `case` had arms for
`board-changed`, `queue-pending` and `results-sweep|remote-results-pending` —
and none for `event-wake`, so every wake built the plain full-SOP prompt and
`bin/unblocked-children.sh` was never called on it. Since the wake loop was
armed that is the DOMINANT gate reason: the project-5 box logged **17
`event-wake` ticks and 0 `board-changed` ticks** in one afternoon, with 0 `DEP_`
lines and 0 `STACKABLE` launches, while a hand run of the same script on the same
box printed 9 `STACKABLE` lines. A wake is now scoped exactly like a
`board-changed` tick, plus the one step the gate skips: the wake exits the gate
*before* any fingerprint is fetched, so the arm fetches it itself
(`triage-gate.sh <project> --pending`) and diffs that. A fetch that fails, or a
diff `bin/gate-diff.sh` calls unusable (rc 1 — a near-full-board diff, unreadable
state), adopts no scope and runs the full SOP, exactly as before.

**An empty diff is not an empty tick.** The pass used to run only when the board
diff was non-empty, and `STACKABLE`, the dep-verified soft class and the release
below have **no board trigger by design** — the facts they act on (a parent PR is
open; a child's pre-plan and its parent's PR disagree; a parent closed without
ever being in the fingerprint) are not things a diff mentions. So a verified-
unchanged board (`gate-diff` rc 2) now runs the pass too, on every tick shape: its
lines become the whole scope on a board/wake tick, and ride in as an `ALSO
launchable right now` section on a queue or sweep tick.

**The parent the fingerprint cannot see.** The pass lists `--label ai-build`, and
the size gate STRIPS that label from a parent it decomposed (project-5 #667 and
#668 are OPEN and unlabelled). A blocker simply missing from the list used to
read as CLOSED, so #669's blockers both looked closed, nothing in the diff had
closed them, and the child was dropped without ever being judged. Blockers the
list does not carry are now fetched by number (`gh issue view N --json
number,state,title`, at most 30 a pass), so an open parent reads OPEN — and a
blocker whose state cannot be read at all leaves the child alone rather than
releasing it. When those parents really do close, the release comes from the pass
itself, because the ai-build-scoped fingerprint can never carry that closure into
a diff:

| line | means |
|---|---|
| `UNBLOCKED <child> "…" (every blocker it names — #a, #b — is CLOSED, and no board diff ever carried that closure …)` | the STATE is the release. Rate-limited by `state/dep-verify/<project>/<child>.unblocked` and re-offered after `UNBLOCKED_REMIND_S` (default 21600s / 6h), so a child nobody launched is offered again instead of once and never. The line's own *"if no PR or build already covers it"* stays the guard, and a child that already has its own open harness PR is never offered |

## 5.4 Reconciliation — every open ai-build issue has exactly one owner (2026-09-15)

> **Events are hints, reconciliation is truth.** — the operator, 2026-09-15

Everything in §1–§5.3 is **edge-triggered**. A ticket gets worked because something
*named* it: a webhook wrote its key into `state/wake-keys-<project>`, a board diff
carried its line, a close-out in a sweep released its child. Each of those is a
message, and a message that is never sent is indistinguishable from a board with
nothing on it. On 2026-09-15 three project-5 tickets sat for hours inside exactly
that blind spot:

| what happened | what never happened |
|---|---|
| #670 closed | #671 was never keyed into a wake, so no tick ever scoped it |
| #719 merged | #721 was never re-scoped, so nothing re-read its thread |
| PR #1045 went red | nobody re-kicked TK-989 |

and through all of it the box logged `rc=skip :: gate no-change (103 tickets)`
every ten minutes — *correctly*. The gate answers "did the board move since the
last consumed tick". Nobody was answering "is every open ticket actually being
worked".

`bin/orphan-reconcile.sh <project>` answers that, from scratch, on every tick. It
keeps no memory of what it decided last time, reads no diff and trusts no event:
it lists the OPEN `ai-build` issues and names each one's OWNER.

### The owner rule

**An open `ai-build` issue has exactly ONE owner, and it is the first of these
that matches:**

- **(a) LEDGER** — a job or queue row for its key in status `queued`/`claimed`/`running`. Something is building it right now. A row that says `running` but stopped beating is **not** this script's problem: `bin/jobs-watchdog.sh` flips it to `failed` within `JOBS_ORPHAN_MIN` minutes, and the next reconcile pass then sees a ticket with no owner and launches it. Two scripts, one fact each.
- **(b) PR** — an OPEN pull request whose head branch, title or closing keyword carries its key — including the FULL child key the ISSUE's own title LEADS with (a decompose child's PR carries `TK-2416.0`, the child's name, never `TK-2566` its issue number; the child-keyed spelling is an owner of that same issue). Only the leading key is the issue's own name: a title that merely mentions another ticket's key (`TK-910: follow-up to TK-902`) is not parked by that ticket's PR. Leading zeros are normalised on both sides, so `ticket/TK-02416.0` still meets `TK-2416.0`. An open PR means the merge conductor owns it, *whatever state that PR is in*: red CI, a provenance hold and a clean green all read the same here, because all three are the conductor's job and none of them is a reason to build the ticket a second time.
- **(c) BLOCKER** — an open `Blocked-by: #M` parent, or an open CHILD that names it in a `Part of #N` line. A decompose parent whose children are open is owned BY its children and is never launchable.
- **(d) HOLD** — a human said not yet, and **the newest human comment wins** (BH-408, 2026-09-18). The thread is read newest-first and the first DECISIVE comment decides: a lift (the capital words `RESUME`/`UNHOLD`, or an explicit `hold lifted` / `hold is off` / `lift the hold`, and never behind a negation or a condition — "Do NOT RESUME this yet", "until the operator lifts the hold") releases the ticket; a `HOLD` word holds it. Neutral comments — including the harness's own "we rebuilt this ticket fresh" close-outs — are skipped. Only when no comment decides do `HOLD` in the title and then in the body hold it: project-5 #14 (title) and #887/#888 (a comment from the operator) are today's. The vocabulary is `bin/lib/hold.sh`'s three exported regexes, shared with `bin/blocked-resolver.sh`'s rebuild gate so the two lanes that re-enqueue builds cannot drift — see docs/verification-map/resolver-hold.md. Before this, ANY `HOLD` ever written held the ticket for ever, which in a harness where nothing waits on a person is a ticket nobody can un-park.
- **(e) GRACE** — an owner that ended less than `ORPHAN_GRACE_MIN` (default 12) minutes ago: a terminal ledger row, a blocker that just closed, board activity on the thread itself, or this script's own enqueue marker (`state/orphan-reconcile/<project>/<KEY>.enqueued`). The event path gets first claim on everything fresh; reconciliation is the BACKSTOP, not a competitor, and this window is what keeps the two from launching the same build twice.

**An issue that matches none of them is an ORPHAN**, and an orphan is enqueued
through the box's own launch — `setsid bin/run-build.sh <project> <issue> <KEY>`,
the same command a triage session runs, which is where the build-key flock, the
duplicate-work guard and the context gate already live.

### Where it runs, and why there

`bin/run-triage.sh` calls it **before** `bin/triage-gate.sh`, on every tick. The
gate's `SKIP` is precisely the path that hid the three tickets above, so a
reconciler behind it would be a reconciler that never ran on a quiet board. Same
reasoning as the result-staging block that already sits in front of the gate
(§ project-3 TK-139): a cost gate has no business standing in front of free
deterministic work, and an enqueue is itself one of the inputs the gate hashes,
so doing the work is also what tells the gate there is something to talk about.

Cheap by construction — three `gh` list calls, two ledger reads, no model call,
and one extra `gh issue view` only for a blocker the `ai-build` list does not
carry (the de-labelled decompose parent, #667). GitHub-Issues boards only
(`board_prefix` `-` in `fleet.conf`): the in-app boards have no `ai-build` label
and no `Blocked-by` convention.

### It fails CLOSED

This is the opposite of most scripts here, and deliberately. "We cannot name
these tickets' owners" and "these tickets have no owner" are different
sentences, and only one of them may launch a build. A failed `gh` list, an
unreachable jobs ledger, an unreadable key prefix, a blocker whose state cannot
be fetched: every one of those enqueues **nothing** and says so in one
`logs/<project>.log` line. A reconciler that guesses storms the pool.

### Guard rails

Beyond the five owner classes, an orphan is still refused when:

| refusal | why |
|---|---|
| `<key>:build-key-lock-held` | `locks/build-key-<project>-<KEY>.lock` is held, so the key is already building on this box whatever the ledger says (`locks/` is DEDUPE — the operator, 2026-09-13) |
| `<key>:awaiting-closeout` | a build dir for the key has a `RESULT` and no `COMMENTED`: the results sweep owns it, and re-launching would rebuild a ticket whose `PLAN_BLOCKED` questions nobody has answered |
| `<key>:cap` | `ORPHAN_MAX_PER_RUN` was set and reached this run. It is unset by default, so no key is capped (the operator, unlimited concurrency, 2026-10-11); an operator sets it only to brake a storm. The rest are re-offered next tick |

### What it writes

One line per run in `logs/<project>.log`, always:

```
reconcile: open=16 owned=15 orphans=1 enqueued=TK-1152 skipped=TK-904:cap
```

and a `bin/lane-alert.sh` line **only when it enqueued something**, naming each
key and why it was orphaned. A reconciler that pages on every quiet tick is a
reconciler nobody reads; "every ticket has an owner" is the normal, silent
shape, and an enqueue means the event path *missed* a ticket — which is a bug in
the event path and worth one line.

`bin/orphan-reconcile.sh <project> --explain` prints the whole verdict table
(`<KEY>\t<issue>\tOWNED|ORPHAN\t<why>`) to stdout without changing what it does.

Switches: `ORPHAN_RECONCILE=0` in `env/global.env` (or `flags/orphan-reconcile-off`)
disables it entirely, in the script and in the tick's hook;
`ORPHAN_GRACE_MIN`, `ORPHAN_MAX_PER_RUN` (unset by default: no launch cap) and
`ORPHAN_BLOCKER_FETCH_MAX` (default 20, a GitHub read cap) tune it.

## 5.5 The other direction of a closure (2026-09-15)

Everything above answers "the board moved, what does this tick read?". This
section is about the half that had no answer at all: **a wake names the object
that MOVED, and when that object closed, the only tickets a tick can act on are
the OTHER ones** — the ones whose bodies say `Blocked-by: #<it>`. Two shapes,
both on project-5, both on 2026-09-15:

- **#721.** Its blockers #718, #719 and #720 all closed at 05:33Z. Three wakes,
  three ticks, each scoped to an issue with nothing left to do. #721 never
  launched.
- **#671.** It says `Blocked-by: #670`. #670 is a decomposed parent that was
  closed by hand, and the tick that followed was scoped to #670.

`bin/unblocked-children.sh` has answered "who does this closure release" since
TK-332, in the `UNBLOCKED` / `STACKABLE` vocabulary the triage prompt already
reads. What it never received was the closure. `bin/lib/revdep-lib.sh` is the
delivery:

| Step | Where | What it does |
|---|---|---|
| is this wake a closure? | `bin/wake-loop.sh` `issue_closures()` | one `gh issue view <key> --json state` per key the wake named. §3 keeps identifiers only, so a close, an edit and a comment arrive identical and the state has to be asked for. Unreadable = not a closure |
| what did this merge close? (the `push` wake, which is where a merge's board-side aftermath has always lived — a `pr` wake still only wakes the conductor) | `bin/wake-loop.sh` `closed_diff()` | the ai-build `--state closed` list inside `WAKE_PUSH_WINDOW_S` as before, **plus** `revdep_merged_closes()`: the `closingIssuesReferences` (and a `closes #N` scan) of every PR merged inside the same window. That second source is the one that sees a closure of an issue the ai-build list cannot carry |
| who was waiting? | `released_by()` → `bin/unblocked-children.sh` | the closures are spelled as `bin/gate-diff.sh` lines and handed to the pass that already knows the answer. Its `UNBLOCKED`/`STACKABLE` lines' keys join the launch's keys |
| and on the far box? | `state/wake-closed-<project>` | written beside `state/wake-keys-<project>`, over the same one `ssh`. Read ONCE by that box's own `bin/unblocked-children.sh` and folded into its closure set, because the ai-build fingerprint there can never diff the close of a de-labelled parent. Stale after `REVDEP_CLOSED_TTL_S` (3600s) and removed on read either way |

**The decompose parent nobody closed.** `bin/run-decompose.sh` files the children
with `Part of #<parent>`, comments the split on the parent and strips `ai-build`
from it — "this issue stays open as the master". Nothing ever closed that master,
and six were closed by hand in one day. `bin/decompose-parent-close.sh <project>`
is that step: for every parent the children name, when **every** child is CLOSED
and the parent is OPEN and unlabelled, it closes the parent with a comment
listing each child and the PR that shipped it. It refuses a parent that still
carries `ai-build` (the label is the handoff — that is somebody's buildable
ticket, whatever a child says about it), refuses a parent with any child still
open or unreadable, refuses a split whose children's own `Order: n of m` lines
say the `--limit 100` list is not carrying all of them, prints the numbers it
closed and nothing else, makes no model call, and is idempotent because the
second run reads the parent as CLOSED.

It runs from **both** ends, which is the point: `bin/wake-loop.sh` calls it on the
merge/close path, and `bin/unblocked-children.sh` calls it on every tick, so a
missed webhook converges on the next cron tick. Both pass `--cooled`
(`PARENT_CLOSE_COOLDOWN_S`, 600s). And the close is itself a closure: the parent's
number joins the closure set of the very pass that made it, so the tickets chained
behind the split come out as `UNBLOCKED` lines in the same output — which is the
whole #671 → #670 case, closed and released in one pass.

| Knob | Default | What it does |
|---|---|---|
| `flags/revdep-wake-off` / `REVDEP_WAKE=0` | absent | Kill switch for this whole section: no state lookup, no closure shipped or read, no parent ever closed. `bin/wake-loop.sh` and `bin/unblocked-children.sh` are then the scripts of 2026-09-14, byte for byte |
| `REVDEP_CLOSED_TTL_S` | `3600` | How long a shipped `state/wake-closed-<project>` is still this tick's event |
| `PARENT_CLOSE_COOLDOWN_S` | `600` | Minimum seconds between two `--cooled` parent-close passes for one project. A hand run is never held |
| `PARENT_CLOSE_MAX` | `10` | Parents whose state is looked up in one pass. Everything cheaper than that lookup is unbounded, because it reads the one list the pass already paid for |

## 5.6 The other half of "events, not clocks": a clock may page, never kill (2026-09-16)

Sections 1-5 are about not WAITING on a clock. This one is about not DYING on one.

the operator, 2026-09-16: *"We shouldn't have rules that kill PRs because of time; it
should be event based."* So the standing rule for every lane in this harness:

> **A PR or a build may be closed, abandoned or rebuilt only by a concrete
> failed EVENT — a fix round that ran and did not land, a rebuild that
> superseded it, an issue somebody closed. Elapsed time may raise an alert and
> may retry an action. It may never take a terminal.**

Where the clocks are, and what each is allowed to do:

| Clock | Lane | What it does | Allowed? |
|---|---|---|---|
| `mc_budget` (`WAIT_CI` 30m, `NEEDS_REBASE` 30m, `READY` 15m, …) | `bin/merge-conductor.sh` | one alert per (PR, state entry) | yes — alert only |
| `mc_ttl` / `mc_stuck_check` (`MC_TTL_<STATE>`) | `bin/merge-conductor.sh` | one alert per (PR, state, head) **plus** `stuck_rekick` — for `NEEDS_REBASE` that is "forget this head's rebase attempt so the next tick tries again" | yes — alert + retry |
| `BR_HANDOFF_MAX_AGE_SECS` (48h) | `bin/blocked-resolver.sh` | how far back the hand-off-log recovery reads | yes — it only ever ADDS a park to the drain |
| `QUEUE_CLAIM_MIN`, `PR_ROW_TTL_MIN`, `ORPHAN_MIN`, `SILENT_MIN` | `bin/jobs-watchdog.sh` | release a ledger claim, close a `pr-*` triage row, page a silent lane | yes — no PR is touched |
| `CLOSEOUT_AGE_OUT_H` (168h) | `bin/pipeline-health.sh` | stop nagging about a missing board close-out | yes — no PR is touched |
| *(none)* | `bin/merge-sweep.sh`, `bin/unblocked-children.sh` | — | — |

The two calls that actually close a PR are both in `bin/blocked-resolver.sh`
(`br_close_pr`: the rebuild rung and `ABANDONED`) and both are reached by events
— and the one hole in that, where a MACHINE problem (no local clone, a failed
`worktree add`, `mc_rebase` rc 4) was read as a rung that ran and failed, and
closed two finished PRs on 2026-09-16, is closed by `br_setup_blocked`: it spends
no rung, closes nothing, pages once per park and re-offers the SAME rung on the
next tick. The full audit, the log evidence and
the per-edge table are in `docs/MERGE-CONDUCTOR.md` §12, "No time kills, and a
setup failure is not an event".

Setup failures now page instead of killing, which is the same trade this whole
document makes in the other direction: a lane that cannot act says so out loud
and stays where it is, rather than inventing a terminal to get out of the state.

## 5.7 The fast-path (BH-482)

A wake that names a ticket buys a triage session, and a triage session is
minutes and a model call before the first line of a build is written. Most of
those sessions re-derive the same answer: this ticket is labelled, unheld,
unblocked, nobody is building it — build it. `bin/launch-fastpath.sh <project>
<key>…` answers that question **deterministically, with no LLM anywhere in the
run**, and launches the SOP line itself. Everything it is not certain about it
DECLINES, and the caller falls through to the triage tick that would have run
anyway.

Its contract, which the wake receiver reads:

- **exit 0** iff every key launched; **exit 1** otherwise (zero keys included).
- **stdout** is the DECLINED keys, one per line, as they were given — nothing else.
- **`logs/<project>.log`** gets one line per key: `FASTPATH <KEY> (issue #n) —
  launched` or `FASTPATH-DECLINED <KEY> :: <reason>`.
- It never writes to GitHub: only `gh issue view`, `gh issue list`, `gh pr list`
  and the libs' `gh api` reads. No comment, no close, no merge, no label.

### The conditions, in order, first failure wins

The reason named is the FIRST thing that was wrong, so a reason is true in
exactly the state that produced it. Gates 0-7 are read once per run and decline
every key on the argv; 8-18 are per key.

| # | Condition | Reason when it fails |
|---|---|---|
| 0 | `flags/fastpath-off` | `fastpath off` |
| 1 | `fleet-conf.sh <p> board_prefix` is `-` and the repo resolves | `not a GitHub-Issues board` |
| 2 | `flag_active paused-<p>` (best effort) then `flags/paused-<p>` | `project paused` |
| 3 | `preplan_key_prefix` reads `<PFX>` out of `prompts/<p>.md` | `no key prefix` |
| 4 | `gh_repo_use_token <repo>` | `repo invisible to every token` |
| 5 | `gh_budget_low launch-fastpath` (rc 0 = low; unknown proceeds) | `gh budget low` |
| 6 | the two ledger reads — `_jobs_req GET /api/jobs`, `queue_list <p>` | `ledger unreachable` |
| 7 | `gh pr list --state open --json …,isDraft` | `pr list unreadable` |
| 8 | the key parses (`<n>` or `<PFX>-<n>`, case-insensitive) and `gh issue view <n>` is JSON | `unparseable key` / `issue unreadable` |
| 9 | `state == OPEN` | `issue not open` |
| 10 | the `ai-build` label is present | `no ai-build label` |
| 11 | the body has h2/h3 `Scope` **and** `Acceptance tests` headings (prose does not count) | `body lacks ## Scope / ## Acceptance tests` |
| 12 | not held — the NEWEST human comment wins (`bin/lib/hold.sh`'s three regexes, class (d) of §5.4), then `HOLD` in the title, then in the body | `HOLD in <title\|body\|comment>` |
| 13 | every `#M` in a `Blocked-by:` line is closed, or `bin/dep-verify.sh` says `SOFT` | `blocker #M open (<HARD\|UNKNOWN> …)` |
| 14 | no open non-draft PR whose head/title carries the key, or whose body closes it | `open PR #x` |
| 14b | no open non-draft PR carrying the FULL key this issue's title LEADS with — the decompose-child class (b2) of §5.4 | `open PR #x (title key <PFX>-<n>.<m>)` |
| 15 | no `queued\|claimed\|running` jobs or queue row for the key | `ledger: <row>` |
| 16 | `locks/build-key-<p>-<KEY>.lock` is free (tested, never taken) | `already building (build-key lock held)` |
| 17 | no `builds/<p>-<KEY>-*/` or `builds/pool-<p>-<KEY>-*/` record | `prior build record exists — relaunches are triage's call` |
| 18 | `state/orphan-reconcile/<p>/<KEY>.enqueued` is older than `ORPHAN_GRACE_MIN` (floored at 60s for the IN-LOCK read, so `ORPHAN_GRACE_MIN=0` cannot switch the dedupe off) | `reconciler enqueued it <k>m ago` |

Conditions 16-18 are the three LOCAL reads, and they are read TWICE: once here in
condition order, and once more inside the launch lock below. That second read is
the dedupe. Without it two runs that decide the same key at the same moment both
see "no marker", the first writes it and releases the lock in a few milliseconds,
and the second takes the now-free lock and spawns the same build again. 9-15 stay
outside the lock — they are GitHub and ledger state no peer run mutates, and
buying those reads under a lock would turn dedupe into a queue.

Over the 50-key run cap a key is declined `over the 50-key run cap` — capped
work is never silently dropped. Every read that FAILS declines; nothing here
maps a failed read to a launch.

### The launch

Under `flock -n` on `locks/launch-fastpath-<p>-<KEY>.lock` — dedupe, seconds
long, and fd 9 is closed in the child, so `bin/run-build.sh` never inherits it
(a lock held for the length of a build is a queue). The lock covers conditions
16-18 **and** the launch: whoever holds it re-reads the build-key lock, the build
records and the marker before writing the marker, so the loser of a race declines
`racing launch, declined` if it met the lock held and `reconciler enqueued it 0m
ago` if it got the lock after the winner released it. The marker
`state/orphan-reconcile/<p>/<KEY>.enqueued` is written BEFORE the spawn, because
it is §5.4's own grace input: a run killed between the two leaves the reconciler
standing down rather than launching a second copy. Then the SOP line, verbatim:

```sh
setsid "$HARNESS/bin/run-build.sh" "$p" "$n" "$KEY" > "$HARNESS/logs/$p.<key>-build.out" 2>&1 &
```

`bin/run-build.sh` stays the single writer: on a Fly-routed project it writes the
`build_queue` row and answers `QUEUED_FLY`, on a box it builds. The fast path
writes no queue row and no `READY-QUEUE.log` line of its own. A held lock is
`racing launch, declined`; a spawn that fails is `launch failed (<rc>)` with the
marker removed. After a successful spawn the launched key is removed from
`state/wake-keys-<p>` (both spellings, under a short flock on that file, the file
deleted when it empties) so the same ticket does not also buy a triage session.

### Both kill switches

- **`flags/fastpath-off` on the hub** — `fp_on` in `bin/wake-loop.sh` is false,
  the receiver skips the call entirely, and the command it runs is
  byte-identical to the pre-fast-path tick's.
- **`flags/fastpath-off` on a box** — this script declines every key with
  `fastpath off` before any gh call, and the caller falls through to triage.

## 6. What is inert until §4 is done

Everything. Specifically:

- The `wakes` table ships **empty** and stays empty with no webhook.
- `POST /webhooks/github` answers **503** with no `GITHUB_WEBHOOK_SECRET` — it
  never falls back to accepting unsigned deliveries.
- `bin/wake-loop.sh` reads an empty feed, launches nothing, and exits 0. With
  harness-jobs unreachable it logs one line and exits 0 (fail-open, like every
  other `jobs-client.sh` caller).
- `bin/triage-gate.sh` never reaches its `state/wake-<project>` check because
  nothing writes that file, and no triage tick is ever launched out of band —
  with no rows there is no wake to launch one from.

## 7. Tests

| Suite | Proves |
|---|---|
| `worker/jobs/test/index.test.js` (`webhook:` / `wakes`) | unsigned, wrongly-signed and post-signing-tampered deliveries write nothing; an unarmed receiver refuses rather than opens; the insert is idempotent on `(repo, kind, key, minute)`; payload text and payload *claims* never reach a row; each event class lands on the lane that owns it; unowned events and malformed identifiers are dropped; the feed's watermark ignores the ack column; the ack touches only the named unacked rows. |
| `tests/wake-loop-test.sh` | each wake kind launches its owning script and nothing else; a batch of PR/check wakes collapses to one conductor launch; the train and QA are launched with the project resolved from the repo; an issue wake un-brakes the gate *and* runs that project's triage tick, locally when `fleet.conf` says `local` and over one `ssh -n … nohup setsid` (un-brake included) when it names a box; the gate consumes the file one-shot; a push launches triage only when `bin/unblocked-children.sh` names a released child, and only for a close inside `WAKE_PUSH_WINDOW_S`; the `push` and `triage` cooldowns are separate keys so the train and the tick cannot eat each other's launch; two issue wakes in the window buy one tick (and two at `WAKE_TRIAGE_COOLDOWN_S=0`); `flags/wake-launch-off` launches nothing and does not even ask GitHub what closed; a foreign repo is dropped and logged; the cursor advances and the next poll carries it; the cooldown holds a second launch (and releases it at `WAKE_COOLDOWN_S=0`) and its DEFAULT holds one 61s later and releases it past 120s; `WAKE_CONDUCTOR_PER_TICK` caps the conductor launches of one invocation and says so once, starts fresh in the next process, honours `0` as unlimited and an explicit `2` as two, falls back to `1` on a typo with a log line, and never counts a push wake against itself; `WAKE_BUDGET_STRETCH` multiplies the conductor's window only while the shimmed `gh_budget_low` answers low, leaves it alone on healthy, unknown and a missing lib, and falls back to `5` on a typo; an empty feed, a garbage answer and the kill switch are all silent exit 0. |
| `tests/event-wake-scope-test.sh` | §5.3, against the real `bin/run-triage.sh`: an `event-wake` tick fetches its own fingerprint and adopts a scope, an unchanged board still runs the pass and its lines ARE the scope, a diff and the pass's lines ride together, an unusable diff and a failed fetch both fall through to the full SOP without paying for the pass, `board-changed` keeps its own path (and buys no second fingerprint fetch), and a sweep tick on an unchanged board carries the launchable children in its `ALSO` section. |
| `tests/reverse-dep-wake-test.sh` | §5.4, against the real loop, the real dependency pass and the real parent-close: an issue wake whose object CLOSED carries the tickets its closure released and ships the closure itself to the owning box, one whose object is still OPEN expands nothing, a merged PR's `closes #N` releases a dependent of an issue the ai-build list cannot see, the local transport writes both files where that box reads them, `flags/revdep-wake-off` asks GitHub nothing, a parent closes only when every child is closed (and never while it still carries `ai-build`, and never twice), its close releases the ticket chained behind it in the same pass, and a shipped closure is read one-shot and ignored past its TTL. |
| `tests/dep-verify-test.sh` + `tests/unblocked-children-test.sh` | the §5.2 lines' source: every incomplete-evidence shape answering `UNKNOWN`, `SOFT` only with both halves of the evidence, the author's escape hatch beating a plan that disagrees, the cache invalidating on a plan edit, and `DEP_VERIFY=0` putting the release class back to `STACKABLE` with no log line and no comment; `DEP_UNKNOWN_MODE` releasing an un-pre-planned child (default `soft`, the `dep-unverified, released` line and its honest thread comment) and `hard` holding it as before, with a genuine `HARD` pair held under both. Plus §5.3: a de-labelled OPEN parent read as OPEN, the marker-gated release and its window, and the real TK-667/TK-669 planned-files lists — disjoint on two different migrations in one named directory, still `HARD` on the `prisma/schema.prisma` both slices append to. |
| `tests/orphan-reconcile-test.sh` | §5.4, against the real `bin/orphan-reconcile.sh` and the real `bin/run-triage.sh`: each of the five owner classes claiming its own fixture ticket (a running ledger job, a queued queue row, an open PR carrying the key, an open `Blocked-by` parent, a decompose parent owned by its open children, `HOLD` in a title and in a comment, a blocker that closed two minutes ago, a thread that just moved), the three tickets of the 2026-09-15 incident reading ORPHAN, the launch shape, the one-line summary and the alert; idempotence (a second run one minute later enqueues nothing, because its own marker is a grace hold); `ORPHAN_MAX_PER_RUN`; the build-key flock and the un-swept `RESULT` dir as hard refusals; a de-labelled OPEN parent and an unreadable blocker both reading OPEN; a ledger outage and a dead `gh` token enqueueing nothing; both kill switches; an in-app board project as an immediate no-op; the hook running on a tick the gate `SKIP`s without buying a session; and (BH-408) class (d) by RECENCY — a `HOLD` released by a newer `RESUME` launching, a `HOLD` followed by "Do NOT RESUME this yet", a `RESUME` overridden by a newer `HOLD` and a neutral harness comment after a `HOLD` all staying `OWNED hold:comment`, plus the no-`bin/lib/hold.sh` fallback holding everything as before. |
| `tests/launch-fastpath-test.sh` | §5.7, against the real `bin/launch-fastpath.sh`: each of the nineteen conditions declining with its own reason and nothing else (the label, both body headings and the prose negative, `HOLD` in a title, a body and a comment against lowercase `hold` in prose, a HARD and an UNKNOWN blocker against a SOFT one and a closed one, an open PR by head and by closing keyword against a body that merely lists the number and against a draft, a live jobs row and a live queue row against a `done` one, the held build-key lock, a prior build record, a fresh reconciler marker); class (d) by RECENCY on this lane too — a `HOLD` released by a newer `RESUME` launching, a lift behind a negation, a newer `HOLD` over an older `RESUME`, a neutral harness comment and lowercase `resume` all staying `HOLD in comment`, plus the no-`bin/lib/hold.sh` fallback holding everything as before; class (b2), the decompose child — a child-keyed open PR (`ticket/TK-2416.0`) owning issue `#2566` whose title LEADS with `TK-2416.0`, leading zeros meeting on both sides, against a key named LATER in the title and against a draft; `ORPHAN_GRACE_MIN=0` still launching a key exactly once, sequentially and in ten concurrent trials; a wake-keys file consumed between this script's read and its rewrite staying deleted; a project name that is not a name writing nothing outside `logs/`; and T1.32, the one source-text assertion — the `line_re`…`close_re` diff against `bin/orphan-reconcile.sh` being empty; the launch itself — the argv token-for-token against the SOP line in `prompts/<project>.md`, the marker written BEFORE the spawn, one `FASTPATH` line, no `READY-QUEUE.log`, the wake key removed in both spellings and the file deleted when it empties; every key form condition 8 takes (`900`, `TK-900`, `TK-900`, `TK-0900`) launching as the one canonical key; a second run inside the grace window declining; the launch lock declining rather than waiting; TWO runs started together on the same key launching it exactly once, ten trials, the loser declined by name; a spawn that cannot run reported as `launch failed` with no marker left behind; both kill switches, an in-app board, a dead token, a low budget, a missing jobs client, a ledger outage and an unreadable PR list each declining every key with zero launches; the 51st key declined with a reason; and — in every one of those cases — not one LLM call. |
| `tests/resolver-hold-test.sh` | the other half of class (d): `bin/lib/hold.sh` and `bin/blocked-resolver.sh`'s hold gate, against the real script — the classifier's whole adversarial table (what holds, what lifts, what neither, a bot's word, an unreadable `created_at`), and then a held ticket closing nothing, enqueueing nothing, resuming nothing, spending no rung, parking `HELD` with one `[resolver] HOLD respected` line and no alert or board comment; a missing `ai-build` label and a closed issue doing the same; an unreadable read costing the ticket nothing and the next healthy tick rebuilding; the lift resuming the ladder with its counters intact; a `HELD` row eating no `BR_PER_TICK` slot; an in-app lane reading no issue at all; and observe mode writing nothing. |
| `tests/builder-direct-test.sh` | the §5.1 caller: `wake_put` refuses an incomplete row, and the close-out block rings `pr` with the PR number exactly once — and not at all with `BUILDER_DIRECT=0` or on a watcher build. |
| `worker/jobs/test/wakeof-new-events.bh-4058.test.js` | BH-4058, through the signed route: `issues.labeled` wakes triage for `ai-build`/`hotfix` (any case) and for no other label, `unlabeled` or a missing label; a failed or errored deployment is `deploy_failed`, never `deploy`; `status`, `workflow_run.completed` and `check_run.completed` are `checks` on the sha; `merge_group` `checks_requested`/`destroyed` is `merge_group`; pending/in-flight actions are dropped; no label name, branch name or status text reaches a row; an unsigned delivery is still 401. |
| `tests/wake-loop-new-kinds.bh-4058-test.sh` + `tests/webhook-rearm.bh-4058-test.sh` + `tests/load-project-events.bh-4058-test.sh` | BH-4058: the loop acks `deploy_failed`/`merge_group` rows with no lane and no `unknown kind` line (and a mutant without the quiet arm says `unknown kind`); `bin/webhook-rearm.sh` dry-runs by default with GETs only, patches only receiver hooks with the union and no `config`, is a no-op the second time, never leaks the secret, stops on a low budget, and reports the App hook without writing it; the `bin/load-project.sh` arming banner subscribes exactly `--print-events`. |
| `tests/wake-lanes-armed-watchdog.bh-4060-test.sh` | §9.1's watchdog: `wake_armed_watch_eval` against a fixture `flags/` and `logs/wake-loop.log` (flag and no armed line, a stale line or an unparseable stamp fire; a fresh line, no flags, the kill switch, a stopped loop and a window of 0 do not; a line that only quotes the phrase is not the armed line; no root refuses), and the `# >>> wake classes armed (BH-4060)` block extracted verbatim from `bin/pipeline-health.sh`: one alert keyed `wakearmed:hub` whatever the classes or age, nothing on a fresh line, a standing key carried when `flag_active` or the lib is missing, and `wakearmed` in `RETRACT_NS`. |
| `tests/gh-token-test.sh` | the §8.1 token: the JWT is a real RS256 JWS whose signature verifies against the App's public key, the exchange is scoped to one repo, a warm cache costs no request and a token inside 5 minutes of expiry is re-minted, two concurrent asks buy ONE token, and an unconfigured box (or `GH_APP_TOKENS=0`, or `flags/gh-app-tokens-off`) prints today's PAT — including the admin PAT for a repo only that one can see — without touching GitHub at all. |

## 8. The polling inventory — what still asks GitHub on a clock

This is the **map for the webhooks-only follow-up**, not the follow-up. §1–§6 moved four
event classes (`pr`, `checks`, `push`, `deploy`) off a clock and onto a doorbell, but the cron
lines stayed, and every lane below still *also* polls. That is the safety argument for the
wake loop (§1) and it is the reason GitHub's rate limit is a throughput ceiling
(`docs/BUILD-CONCURRENCY.md`, "one PAT, 5000 requests an hour"): the fleet spends requests on
a schedule whether anything changed or not.

Cadence is the cron line as rendered by `bin/lib/cron-lines.sh` / `cron/hub.cron`. "Per
project" means the line is repeated once per project on the box, so multiply by the box's
project count. Only **reads on a cadence** are listed; write calls (`gh pr comment`,
`gh issue close`, `gh pr merge`) are not polls and are excluded.

| Script | GitHub endpoint(s) polled | Cadence | Replaceable by a webhook? |
|---|---|---|---|
| `merge-conductor.sh` | `GET /repos/{r}/pulls` (open + closed), `gh pr view` per PR, `gh issue view` | `*/5`, fleet-wide | **yes** — `pull_request`, `check_suite`, `status`; already wake-driven |
| `merge-sweep.sh` | `GET /repos/{r}/pulls`, `GET /repos/{r}/actions/runs?head_sha=`, `gh pr diff` | `6,16,26,36,46,56`, fleet-wide | **yes** — `pull_request` + `check_suite`/`workflow_run` |
| `merge-queue.sh` | `gh pr view --json state,mergeable,headRefOid,mergeCommit` | `6,26,46`, per project | **yes** — `pull_request`, `status` |
| `review-prs.sh` | `GET /repos/{r}/pulls` (open), `gh pr diff`, `GET /repos/{r}/commits` (paginated) | `7,37`, per project | **yes** — `pull_request` `opened`/`synchronize` |
| `review-autopilot.sh` | `gh pr list --author`, `gh pr view --json mergeable,mergeStateStatus,statusCheckRollup` | `17 * * * *` | **yes** — `pull_request` + `check_suite` |
| `review-rescue.sh` | `gh pr list --state open --search`, `gh issue view --json state` | `7,37` | **yes** — `pull_request` `closed`, `issues` |
| `reconcile-prs.sh` | `gh pr view --json state,mergeCommit` | `*/10` | **yes** — `pull_request` `closed` |
| `tier2-merge-sweep.sh` | `gh pr view --json state` | `3,13,23,33,43,53` | **yes** — `pull_request` `closed` |
| `check-migration-prs.sh` | `gh pr list --state merged --json files` | `7,27,47` | **yes** — `pull_request` `closed` (merged) |
| `rebase-train.sh` | `gh pr view --json state,mergeStateStatus,headRefName` | `*/30`, per project | **yes** — `pull_request` `synchronize` + `push` to the base |
| `tickets-snapshot-push.sh` | `GET /repos/{r}/pulls?state=open`, `/pulls?state=closed&head=`, `/git/matching-refs/heads/`, `/commits/{sha}` | `8,18,28,38,48,58` | **yes** for the PR rows (`pull_request`); the branch inventory needs `push` |
| `unblocked-children.sh` | `gh issue list --label ai-build`, `gh pr list --state open` | after each merge, and every tick while the STACKABLE / soft classes are armed | **partly** — `issues` `closed` answers the release half; "does the parent have an open PR right now" is a moment-in-time question |
| `dep-verify.sh` (from `unblocked-children.sh`) | `gh pr list --state all`, `gh api pulls/{n}/files` | once per unjudged `(child, blocker)` pair; a cached verdict costs the list only, and a child with no pre-plan costs nothing at all | **no** — it is a comparison of two file sets at a moment, and the cache is keyed on their shas rather than on a clock |
| `triage-gate.sh` | `gh issue list --label ai-build`, `gh pr list --state open` | `*/10`, per project (inside `run-triage.sh`) | **partly** — the wake already un-brakes it, but its fingerprint is a hash of the WHOLE state, so it needs a full read to compare |
| `deploy-verify.sh`, `wait-preview.sh`, `postmerge-qa.sh` | `GET /repos/{r}/deployments`, `/deployments/{id}/statuses` | per deploy; `wait-preview` polls up to 600s | **yes, biggest single win** — `deployment_status`. Needs the App's `deployments: read`. |
| `pre-arm-guards.sh` | `GET /repos/{r}/branches/main`, `gh run list`, `gh run view --json status,conclusion` | per arming attempt, polls to completion | **partly** — `workflow_run` gives completion; fetching the run LOG stays a pull |
| `pipeline-health.sh` | `GET /repos/{r}/actions/runs?branch=main&created=>…`, `gh pr list`, `gh issue list` | `*/10` | **partly** — its detectors are trends over a window, so a webhook stream would have to be materialised into that window first |
| `fly-pool.sh` (reap) | `gh pr view --json state`, `gh api repos/{r}` | `*/2` | **no** — it verifies a build's `PR_CREATED` claim at a moment in time; "does this PR exist right now" is not a question an event answers |
| `claude-auth-check.sh` | `gh api repos/{r}` (the `ghinvisible:` canary) | `51 * * * *` | **no** — deliberately a live probe of what the token can see |
| `flaky-detect.sh` | `GET /repos/{r}/actions/runs?created=>…` (paginated) | `40 5 * * *` | **no** — a historical window scan |
| `outcome-metrics.sh`, `reopen-metrics.sh`, `rule-miner.sh` | `/commits?since=`, `/commits/{sha}/check-runs`, `/pulls/{n}/files`, issue events | weekly / daily | **no** — retrospective reporting over a past window |

Not in the table, and why: `blocked-resolver.sh`, `flaky-quarantine.sh`, `deploy-train.sh`,
`guardrail-promote.sh`, `iron-law-guard.sh`, `load-project.sh`, `bootstrap-machine.sh`,
`fly-image-build.sh`, `checks-run.sh`, `board-invariants.sh`, `verify-claims.sh`,
`triage-map.sh`, `lander.sh`, `agent-call.sh` and the alert lanes touch GitHub only to
**write**, or read once inside a run something else scheduled. Neither is a poll, so neither
is a webhook candidate.

**What the rows add up to.** Eleven of the twenty-two lanes are a straight `pull_request` /
`check_suite` / `deployment_status` substitution — the receiver in `worker/jobs` already
verifies and stores the first two (§3). The honest residue is five lanes that cannot be
event-driven: two live probes, and three retrospective window scans. A webhooks-only fleet
therefore means "these eleven stop polling", not "nothing polls".

### 8.1 The token those polls spend, and the warm pass

Every row above spends from a rate-limit bucket. Until 2026-09-14 that was ONE bucket for the
whole fleet — the PAT in `env/global.env` at 5000 requests/hour for the entire account, copied
onto every pool machine as well. `bin/gh-token.sh` mints a short-lived repo-scoped GitHub App
installation token instead, which is rate-limited per installation; `docs/BUILD-CONCURRENCY.md`
has the comparison and `docs/OPERATOR-SETUP.md` has the one-time setup.

A call that still spends a PAT is now announced, not just reportable. The hub lane
`bin/gh-pat-charge-alert.sh` (hourly at :17) reads the fleet `gh_ledger` for the last complete
UTC hour — the `gh-quota-report.sh --fleet` read, falling back to the hub's own ledger file when
the worker is down — and writes ONE `logs/ALERTS.log` line per box, `pat-*` / `graphql-pat-*`
bucket and UTC day with the counted calls and the top 3 callers (`pat-default` is the gh
keyring login, operator; `pat-<sha>` is a PAT exported as `GH_TOKEN`). The fix it points at is
`gh_default_auth_for_slug` / `gh_auth_for` in `bin/lib/gh-app-auth.sh`. It costs no GitHub call;
[verification-map/gh-pat-charge-alert.md](verification-map/gh-pat-charge-alert.md) has the rest.

This loop keeps that cache **warm** so no build or merge ever pays for a mint on its critical
path. Once per invocation (not per cycle), after taking its flock, it launches
`bin/gh-token.sh --warm` detached — with fd 9 closed, for the reason #310 gave: a child
holding this loop's lock makes the next cron minute a no-op. A token lives an hour and is
refreshed 5 minutes before expiry, so in practice that is one mint per repo per ~55 minutes
and every other tick reads a cache and asks GitHub nothing.

Inert unless armed: `gh_auth_armed` is a file test, so with no `env/github-app.env` (or
`GH_APP_TOKENS=0`, or `flags/gh-app-tokens-off`) the loop forks nothing and is byte-for-byte
what it was.

## 9. Arming the wake classes, and the lanes still on a timer (BH-4060)

**No wake class is armed as of BH-4060's first slice.** On 2026-10-03 the hub had
no `flags/wake-lanes-*` flag and `logs/wake-loop.log` had never printed
`wake classes armed:`, so every lane #1034 moved to events still runs on its
cron. Arming is a data change an operator makes on the hub. A build cannot make
it, and nothing in the code arms a class by default.

### 9.1 Operator runbook: arm one class at a time

Order: `pr-closed`, `pr-ci`, `push`, `deploy`, `flaky`, `split-chain`.
BH-4058's new wake kinds, `deploy_failed` and `merge_group`, are acked with no
lane and have no `bin/lib/wake-class-*.sh` file yet, so there is nothing to arm
for them.

For each class, on the hub:

1. `bin/jobs-client.sh flag-set wake-lanes-<class> on "<reason>"`.
2. Within 2 minutes, `grep 'wake classes armed:' logs/wake-loop.log | tail -1`
   names the class. If it does not, stop and turn the flag back off.
3. Wait for one real wake to launch the class's lane, and paste that
   `logs/wake-loop.log` line, timestamp included, into the tracking PR or issue.
   The line starts with the class's launch label: `pr-closed:` and `pr-ci:` for
   the hub lanes, `review-prs[<p>]`, `rebase-train[<p>]`,
   `push[cromford]`, `migration-autopilot[<p>]` / `apply-migrations[<p>]`,
   `checks[<p>] flaky-detect` and `split-chain[<p>]` for the rest.
4. Only then arm the next class.

A class's lanes move to backstop crons of 30 minutes or longer only after step
3's evidence exists for that class. That is a later slice. Turning a class off
is `bin/jobs-client.sh flag-set wake-lanes-<class> off "<reason>"`, and
`flags/wake-lanes-off` stops every class at once.

**The watchdog.** `bin/pipeline-health.sh` (hub, `*/10`) pages once, keyed
`wakearmed:hub`, when a class flag is on (`flag_active wake-lanes-<class>` for a
class file under `bin/lib`) and the armed line is missing or older than
`WAKE_ARMED_WATCH_S` (registry default 3600, 0 = off). It stays quiet under
`flags/wake-lanes-off`, `flags/wake-loop-off` or `flags/lane-off-wake-loop`,
because the line is meant to be missing or the loop is stopped on purpose. It
retracts when the line comes back or the flags go. When it can't tell (no
`flag_active`, no lib), a standing page is kept. `bin/lib/wake-armed-watch.sh`
makes the decision.

### 9.2 Tick-only lanes from the audit, and why each stays on a timer

- `dequeue-watch`: Mergify's dequeue is not a delivery the receiver turns into a lane wake. `merge_group` rows are acked with no lane since BH-4058, so the `*/5` scan of dequeued PRs is the only trigger.
- `stuck-work`: it pages on time past an SLA per state. Being stuck means no event happened, so no event can trigger it.
- `main-red-pr-pair`: it compares the same failing job across open PRs. That is a cross-PR comparison, not a reaction to one delivery.
- `main-red-bisect`: it is driven by red episodes on main and runs bisect builds. Each episode is read from git, not from a wake.
- `merge-queue`: it drains `state/merge-queue/` entries that harness lanes write. The entries are its trigger, not GitHub events.
- `review-rescue`: it re-enters builds whose review died without a PR, read from build RESULTs. A `pull_request.closed` wake could join it to the `pr-closed` class later. It stays on its timer until `pr-closed` has been seen firing for real.
- `pr-url-reconcile`: it re-links build records whose `gh pr create` failed. Build records are not GitHub events.
- `fix-round-claim`: it claims harness-jobs `fix_round_jobs` rows on each project box. Rows are not GitHub events.
- `issue-state-ledger`: its sweep against a watermark is how it stays correct. A missed webhook must not leave the ledger wrong.
- `untriaged-wake`: it produces wakes itself, for tickets GitHub never rings about. A wake can't trigger the lane that exists because there was none.
- `daily-digest`: it runs once a UTC day, so it is time-based on purpose.
