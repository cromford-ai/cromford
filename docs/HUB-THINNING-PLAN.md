# Hub thinning — plan for review

**Status: PLAN for the LLM-lane migration below (no code written), plus one
landed slice — see "LANDED: the hub out of the DATA path (W2-B, 2026-09-14)".**
Architectural, so it goes to review before build.

---

## LANDED: the hub out of the DATA path (W2-B, 2026-09-14)

The plan below is about where a lane's **LLM call** runs. This slice is about
something the plan never named and that turned out to matter more at scale:
where a finished build's **result** travels.

**The funnel, as it was.** A pool machine's build result went to the HUB
(`bin/fly-results-ingest.sh` → `state/remote-results/<p>/KEY.json`), waited for
the owning box's next triage tick to pull it from the ledger and stage it,
waited again for that paid session to read the RESULT and post the client's
close-out comment, and only then did a `*/5` merge-conductor tick look at the
PR. Three clocks and two machines between a green build and a client hearing
about it — with the hub in the middle of every hop. The
`remote-result unconsumed >30m` alerts in `bin/pipeline-health.sh` are that
funnel backing up, seen from the side. At 4000 builders it is both the
bottleneck and the single point of failure.

**What landed.** The machine that built the thing finishes it:

| was | is |
|---|---|
| hub relays the RESULT to the owning box, box stages it, a paid session posts the board comment | the builder posts the what-shipped comment and moves the status itself (`bin/board-closeout.sh`) |
| the terminal facts reached the ledger as a one-line summary at trap time | the builder writes `{result, pr_url, sha, tier, verdict, cost_usd}` as the job's final PATCH (`job_result_put`) |
| tier-1 APPROVE reached the box's merge queue by an `ssh … touch` from the hub | the builder writes the `merge_queue` row itself; the hub's row is an idempotent duplicate |
| the conductor waited out its tick | one `wake_put` (docs/EVENTS.md §5.1) — inert until the worker route lands, and GitHub's own PR webhook already rings it |
| `bin/fly-results-ingest.sh` relayed every result | it is **bookkeeping** for a result already terminal in the ledger: artifacts pulled, builder cleared, custody stamped `RELAYED`, **no json parked and no ssh sent** |
| one ticket per box, guarded by `locks/build-key-…` | the ledger claim is the dedupe of record; the flock is a same-box fast path (docs/BUILD-CONCURRENCY.md) |

**The one thing worth being afraid of** is a SECOND comment on a client's
ticket, and it has two guards. A posted close-out appends a marker to the first
line of `RESULT` — the only identity the relay json, the ledger feed and the hub
ingest all spell identically — so `bin/fly-results-ingest.sh` reads it as
"already delivered" and `bin/run-triage.sh`'s staging marks such a dir
`COMMENTED` instead of handing it to a session. `bin/lib/builder-direct.sh` owns
that marker so there is one definition of it.

**What it does NOT do.** It words exactly one shape — a build that ended with a
PR. A deferral, a `PLAN_BLOCKED` or a refusal needs a sentence about *why*, and
that still goes to a triage session on the owning box, unchanged. It also runs
on BUILDERS only (`BUILDER_EXEC`): a watcher's own session sweeps its own build
dirs on the same box, and there is no hub in that path to take out of it.

**Kill flag:** `BUILDER_DIRECT=0` in `env/global.env` or the environment, or
`flags/builder-direct-off`. Either one restores the relay path byte for byte —
no comment, no marker, no stand-down on a lost claim, and the hub relays exactly
as it does today. Pool machines bake their image from the hub, so the change
reaches them on the next `fleet-propagate` rebake; watcher boxes get it within
5 minutes of merge.

**Tests:** `tests/builder-direct-test.sh`.

## The policy (the operator, 2026-08-24)

> The hub coordinates; boxes work. Any lane making an LLM call ABOUT a specific
> project runs on that project's box — its account, its context, its ledger. Hub
> LLM lanes = only the inherently fleet-scoped (orchestrator chat, true
> cross-project digests).

This lands in `docs/CONTEXT-COMPOSITION.md` as a placement rule regardless of
whether the migration below is approved. Placement is a composition decision: a
lane running on the wrong box has the wrong account, the wrong local state, and
the wrong ledger, which is three kinds of wrong context before anyone counts a
token.

### Enforced mechanically since BH-393

The paragraph above was policy for three weeks and nothing checked it. On
2026-09-15 ten `up10` self-improvement lanes were executing inside
`/root/harness/tmp/wt-up10-*` on the hub when `/root/harness` was wiped out from
under them (incident #388). `bin/lib/hub-box.sh` is the policy as a control, and
four entry points ask it:

| Entry point | Refuses as | What the operator sees |
|---|---|---|
| `bin/agent-call.sh` | the stage it was called with | rc **77**, `AGENT_CALL_REFUSED hub-no-build …` in the outfile, no cost row, no phase row, no beat — nothing was called and nothing was billed |
| `bin/run-build.sh` | `build` | rc **3**, `BUILD_REFUSED hub-no-build …` in the build record, naming the box (`bin/box-for.sh`) the ticket belongs on |
| `bin/run-preplan.sh` | `preplan` | rc **3**, a line in `logs/preplan.log`, and NO `plans/<project>-<KEY>` dir for a later build to adopt |
| `bin/up10-lane.sh --here` | `up10` | rc **77**, and this one has **no override** — `HUB_BUILD_OK` lets an operator build a ticket here, it does not re-open the lane that caused the incident |

Every refusal writes ONE `logs/ALERTS.log` line —
`[hub-no-build] refused <lane> <ticket> on <box> — …` — deduped per (lane,
ticket) per UTC day through `flags/alerted-hub-no-build-*`, because
`bin/preplan-tick.sh` fires every 2 minutes and would otherwise write 720 lines
a day.

**Knobs**, all in `env/global.env` on the box:

- `HUB_BUILD_OK=1` — this box may run build lanes even though it is the hub.
- `HUB_NO_BUILD_LANES` — the refused list. Default
  `build plan preplan preplan-files execute fix qa`.
- `HUB_BOX_NAME` — the hub's fleet name (default `box-hub`). Identity
  comes from `bin/box-name.sh`, never `hostname`: the hub's hostname is
  `box-hub`.

**`review` is deliberately not in the default list.** `cron/hub.cron` still runs
review-autopilot (`bin/review-autopilot.sh`), review-rescue, the merge
conductor's head-bound re-review (`bin/lib/merge-conductor-lib.sh`),
blocked-resolver's adjudication and the cost read-out (`bin/cost-readout.sh`)
through `agent-call.sh` here as `review`, and moving them is the migration below
— hub-thinning proper. (rule-miner and the alert digest pass `triage`, not
`review`, so they are a separate question.) Refusing `review` today would stop
every PR review in the fleet the minute it deployed. Adding it to `HUB_NO_BUILD_LANES` is the one-line
change the day those lanes move.

**What this does to `bin/blocked-resolver.sh`, stated plainly.** Its rung-2 fix
round passes `execute` and now gets refused on the hub, every time. Its own
failure path (`bin/blocked-resolver.sh`, the `fix round did not produce a
verified commit` branch) reads a nonzero agent rc and falls to rung 3,
`br_rebuild_fresh` → `br_enqueue_fresh`, which resolves the box through
`bin/box-for.sh` and enqueues or ssh-dispatches there. So it degrades a rung
rather than wedging — but the cost is real and is not zero: rung 3 CLOSES the
parked PR as superseded and rebuilds the ticket from scratch, so a park that
rung 2 would have fixed in place now spends a whole build. The fix for that is
to move the fix round to the owning box, which is hub-thinning proper (the
migration below), not another exemption here.

**Self-improvement work** is no longer an orchestrator session running
`git worktree add` here. `bin/up10-lane.sh <slug> <brief-file>` resolves the
owning box through `bin/box-for.sh cromford`, hops there over ssh, and on
that box files (or finds) an `ai-build` issue titled `up10: <slug>` and launches
the ordinary `bin/run-build.sh`. That is what buys it claims, review lenses, CI
and a RESULT — the three PRs the old lane opened on 2026-09-15 (#379, #380,
#381) had no issue, no build dir and no queue row, and triage logged all three
as orphans.

**Tests:** `tests/hub-no-build-lanes-test.sh`.

---

## Correction to the brief's inventory, and it changes the method

The brief names preplan-tick, untriaged-sweep, stale-owed-tickets, review-rescue,
alert-triage, alerts-medic, watchdog-responder and rule-miner as the drift layer.
Grepping each for `agent-call` gives:

| lane | calls agent-call directly? |
|---|---|
| review-rescue, rule-miner, review-autopilot, fly-results-ingest | yes |
| alert-triage, alerts-medic, watchdog-responder | yes (fleet-scoped) |
| preplan-tick, untriaged-sweep, stale-owed-tickets | **no** |

**That table is misleading, and the reason matters.** `preplan-tick.sh` makes no
LLM call itself — it `setsid`s `run-preplan.sh`, locally, and *that* calls an LLM.
A direct grep under-counts every lane that dispatches rather than calls.

So **the inventory must be transitive, and better still, measured**. We already
have the data: `fleet-cost.csv` carries `host` and `project` per row. The drift
layer is exactly:

```
rows WHERE host = hub AND project != 'fleet'/'other', grouped by stage
```

That is the ground truth — it counts what actually billed, it is immune to
dispatch indirection, and it needs no code. **Step 1 is to run that query, not to
read more scripts.** Everything below is provisional until it returns, and any
lane it shows at ~$0 is not worth moving however badly it is placed.

---

## THE HEADLINE — corrected: the race was REAL and is now OVER

**project-1 was triaged by two machines at once. It stopped on 2026-08-23.**

The last hub-billed project-1 triage row is **2026-08-23T22:33:35Z**, 26+ hours
before this was written — almost certainly ended by the Mission Control wave's
committed-crontab installs. Verified independently: `box-for.sh project-1`
resolves to `box-project-1-1` (remote, correct), the fleet.conf row has
its 6th column (the legacy `project-1 -> local` landmine did not fire), and
both the live crontab and today's two backups carry zero `run-triage` lines.

**So this section originally said "is" where the evidence only supported "was",
and the correction is the more useful artifact.** A 7-day aggregate says
*happened within 7 days*. It never says *happening*. The $328 figure was real
spend and it was also a tail — the window contained the race, the present tense
did not survive a timestamp check. **Date the last occurrence before using the
present tense about anything an aggregate shows.**

That changes the slice from a fix to a guard.

The hub's hostname is `box-hub` — it IS the project-1
watcher by original design. And `10.0.0.1` also carries
`run-triage.sh project-1` in its crontab. Both ran, and both acted, until
**2026-08-23T22:33:35Z** — the timestamp of the last hub-billed project-1 triage
row. It stopped when the Mission Control wave re-rendered the committed
crontabs. The invoker was that old live crontab line, and it is gone: the live
crontab and both of today's backups carry zero `run-triage` lines.

| | |
|---|---|
| hub, billed to project-1 | 73 claude-triage + 194 grok-triage + 21 review ≈ **$328/7d** |
| the dedicated box | ≈ **$185/7d** |

The money is the smaller half. **Two agents working the same board is a race
surface**: both fetch the same changed tickets, both decide, both comment, both
move. The failure mode is not a crash — it is two replies to one client, or a
ticket moved out from under the agent that was about to move it. Nothing in
either lane knows the other exists, so nothing errors, and the symptom is a
client seeing us answer ourselves.

**Two owners is the worst available state, and it was the state until
2026-08-23.** It resolved by accident rather than by decision, which means
nothing prevents its return — a hand-added crontab line during an incident, a
fleet.conf row losing its 6th column, or a box rebuild would each restore it
silently.

**Recommendation: assert the invariant rather than perform a migration.** The
box already owns it in practice; what is missing is anything that would notice
if that changed. One owner per project, asserted both directions in the
set-equality test, is the whole slice — and it is worth more than the removal
would have been, because it covers the next project as well as this one.

The migration framing below still stands for the lanes that ARE mis-placed
today; only the project-1 item collapses from a move to a guard. Were the race
still live, the change would be — that matches the directive, and it is the direction that also
thins the hub. The alternative (hub keeps it, box's cron goes) is defensible on
"the hub already has the context", but it leaves the largest single project's
spend on `example.com` and contradicts the policy this plan exists to apply.

Either way the change is one crontab line on each side, and **both lines must
move in the same deploy** — removing one before adding the other is either a gap
where nobody triages project-1, or a continued double-run. The set-equality test
covers exactly this: one owner per project, asserted both directions.

---

## Measured drift layer (hub-billed, 7d)

From the step-1 query. This supersedes any inventory derived by reading scripts.

| lane | 7d on the hub | note |
|---|---|---|
| project-1 triage + review | **$328** | the double-run above |
| alert-triage | **$152** | claude $80 + grok $71 + fireworks unpriced |
| alerts-medic | **$52** | 32 grok calls at $0.00 — see open question 5 |
| watchdog-responder | **$43** | |
| bench / trust evals | **~$31** | |
| **total** | **~$638/7d** | |

**Not included: the orchestrator's ~$4.6K/7d**, which bypasses `agent-call.sh`
entirely and therefore never reaches `cost.csv`. It is by far the largest number
on this page and it is invisible to the ledger the rest of the fleet uses — the
per-turn log line makes it visible per-turn rather than tomorrow.

**Measurement caveat that will mislead the next reader:** claude rows show
`mean_in ≈ 0k` because `input_tokens` excludes cache reads, and for a claude lane
the context lives almost entirely in `cache_read` (column 11). Any per-lane
comparison across runners must aggregate column 11 for claude, or claude lanes
will look weightless next to grok ones — the same shape as the codex lane that
read as weightless until #72.

## Step 1 — Measure the drift (no code) — **DONE**, results above

On the hub:

```
awk -F, 'NR>1 && $2 ~ /hub/ && $3 != "" {print $3"\t"$4}' \
  /root/harness/state/cost/fleet-cost.csv | sort | uniq -c | sort -rn | head -30
```

Produces `count · project · stage` for hub-billed, project-attributed work.
Cross-check the dollars with the existing per-project `cost_7d`. **Deliverable:
the real drift list, ranked by spend.** Only lanes on it get migrated.

## Step 2 — Classify each drift lane

Three outcomes, and the middle one is where the judgement is:

1. **Cleanly shardable** — the lane iterates projects and needs only that
   project's state. Moves to per-box crontabs, one line per box for its own
   project. `review-autopilot` looks like this (it iterates fleet.conf).
2. **Shardable with a fleet residual** — alerts. Most are project-attributable,
   some are genuinely fleet-level (a box down, a pool exhausted). Proposal: shard
   by project-of-origin, keep a small hub lane for the rest. **The residual must
   be named and budgeted, not left as "whatever is left over"** — an unnamed
   remainder is how a lane becomes untracked.
3. **Genuinely fleet-scoped** — stays hub, gets a diet instead. `rule-miner`
   (cross-project pattern mining) and `cost-rollup` (the aggregator, by
   definition) are here.

## Step 3 — Move crontab lines, not code

The migration is **per-lane reversible**: a crontab line moves, the script does
not change. `bin/` already syncs to every box, and the scripts already take a
project argument or read `fleet.conf`.

Guarded by the set-equality pattern (`watchdog-boxes-test`, `overage-per-box-test`):
a test asserts every migrated lane has exactly one cron line on exactly the box
that owns its project, both directions. **A lane that moves off the hub and onto
no box is worse than one that never moved** — it stops running, silently, and the
symptom is absence.

## Step 4 — Consequences, stated before the move

- **MIGRATION IS BLOCKED ON ACCOUNT-SIDE CAPS EXISTING.** Not "sequenced after"
  — blocked. Moving spend onto accounts that have just had extra-usage enabled
  and cannot poll their own meters (the 403) removes the last thing standing
  between a runaway lane and an invoice. Caps, then flip, then migrate.
- **Spend shifts from `operator@example.com` to the dedicated project accounts.**
  Truer attribution and a lower hub bill — but it *raises* those accounts' burn,
  and extra-usage is about to be enabled on project-2/project-3/project-4. **BLOCKED on the
  account-side caps existing** — not sequenced after them, blocked by them.
  Moving spend onto accounts that can now silently overage, in the same week,
  is how a good change produces a bad week.
- **Per-box overage meters cannot see it.** The boxes' setup-tokens lack the
  `user:profile` scope (403), so their vendor meters return nothing. The migrated
  spend is visible only in `cost.csv` self-estimates. That is a real loss of
  observability on the receiving end and belongs in the decision.
- **Each migrated lane needs a manifest row** in `catalog/context-budgets.json`
  before it moves, or it arrives on its new box unbudgeted — the capstone test
  will fail it, which is the intended behaviour.

## Step 5 — Fold the alert-triage diet into placement

The queued alert-triage diet is **superseded**: diet it where it lands, not where
it drifted. If alerts shard per project, the diet applies to each shard, and the
414K/852K means get attacked in their final home rather than twice.

## Leadership — hub-ness is a lease (2026-09-15)

**Why.** On 2026-09-15 the hub was wiped. Everything above assumes there is a
hub to thin, and until that morning "the hub" was a hostname somebody typed into
a conf file: nothing checked it, nothing could move it, and a second box pointed
at the same name would have run the whole fleet a second time. Fifty-two of the
lines in `cron/hub.cron` act on the FLEET or on a SHARED resource — merges,
deploys, Fly dispatch, board writes, fleet-wide ssh — so two boxes running them
means every one of those actions happens twice. Hub-ness had to become something
a box can hold, lose and take, not something it is told it is.

**The three verbs.** `bin/hub-lease.sh` is the whole client, and it has exactly
three:

- `renew` — POST `/api/hub-lease`. Takes the lease or extends it, sending the
  `epoch` it last saw. The worker answers `renewed`, `taken`, a bootstrap
  `INSERT`, or `409 lease held` — one statement each, judged by `meta.changes`,
  so two boxes racing cannot both be told they won.
- `check` — GET `/api/hub-lease?holder=…`. Exit 0 means "this box holds it",
  non-zero means "it does not". Nothing else. This is the verb the crontab runs.
- `promote --holder <box>` — the operator verb for MOVING hub-ness. Since
  BH-2272 it goes through the guarded `POST /api/hub/promote` (the legacy
  `/api/hub-lease/promote` force-promote answers 410): `<box>` must be the hub
  or a fleet.conf `# @standby` box, the command reads the live epoch and sends
  it as `expected_epoch` with `confirm: true`, and the worker applies the
  `hub.promote_enabled` setting, the live-lease refusal and the audit row. It
  bumps `epoch`, which fences the box being moved off: that box's next renew
  answers 409. Stop the old hub (or cut its lane gate) FIRST — a hub that
  cannot reach the worker fails open and keeps running (BH-1000).

**The crontab marker.** The gating is rendered, never hand-typed. Every hub-only
line in `cron/hub.cron` sits between `# BEGIN hub-lanes` and `# END hub-lanes`,
and `bin/render-crontab.sh` puts `/root/harness/bin/hub-lease.sh check && ` in
front of each of their commands. Eleven blocks, 52 gated lines, and the checked-in
file IS the render, so a re-render can never silently drop the prefix
(`tests/hub-cron-gated-test.sh`, `tests/cron-fleet-parity-test.sh`). One line is
deliberately outside every block: `* * * * *` `hub-lease.sh renew`. A box that
never renews can never hold the lease it is being asked to prove.

Twenty lines stay ungated on purpose, because they maintain or report on THIS
box and the same scripts already run on every other box: `poll-commands` (a
demoted hub must stay reachable from the console — that is the one way an
operator can promote it back), `watchdog-ping`, `update-runners`, `clock-sync`,
`disk-clean`, `harden-state`, the per-account meters, and the per-box lanes.

**The fail-safe, as the code actually behaves** (`bin/hub-lease.sh`):

- `check` caches its answer for 60 s (`HUB_LEASE_CACHE_S`, line 23). All 52 lanes
  share that one file, so the steady-state read rate against the worker is about
  one GET a minute, not 52.
- If the worker is unreachable, the CURRENT holder keeps firing for a 600 s grace
  window (`HUB_LEASE_GRACE_S`, line 24) — and only the current holder. A box whose
  cache says `held=0` gets no grace at all.
- Past the grace window the lane SKIPS, and one ALERTS line is written behind
  `flags/alerted-hub-lease-unreachable` (line 144) so an outage pages once rather
  than every minute.
- With no cache at all there is no alert, because there is no claim to alert
  about. That is also the rollout state: at merge, `check` exits 1 and the gated
  lanes skip a tick or two, quietly, until the first `renew` lands.
- If `bin/hub-lease.sh` is missing — a box that lost its own `bin/`, which is
  exactly what happened on 2026-09-15 — the shell returns 127 and the `&&` fails
  by construction. The lane skips. That is the property, and it is why the gate
  is a command and not a config flag.

Fail-open is NOT the property here, and that is the point: an unreachable
coordinator must PAUSE fleet-wide action, not permit it. Fail-open belongs to the
alert path only, and it holds.

**Failback is automatic, and it falls out of one rung.** Rung 2 of renew takes
any lease whose `expires_at` has passed. Nothing has to notice that the holder
died: the TTL defaults to 180 s and the client renews every minute, so two missed
renews expire it and the next box to renew simply takes it, with the epoch
bumped. No watchdog, no election, no human.

**Automatic promotion is the watchdog's (BH-401), and it ships OFF.** The
external watchdog promotes a standby when the hub is dead on both clocks. The
holder's ping has to be more than 16 min old on the watchdog's clock
(`cfg:failover_ping_min`, three missed `*/5` pings), AND its lease has to have
gone more than 10 min unrenewed on the jobs server's clock
(`cfg:failover_lease_min`). The standby must be the only box that reports itself
healthy, with a fresh report and a fresh ping. The watchdog calls
the guarded `POST /api/hub/promote` (with `expected_epoch`, `actor: watchdog`,
`confirm: true`) once per lease epoch, so D1 `hub.promote_enabled` must also be
on and every attempt leaves a `hub_lease_changes` row. It writes its
`failover:<epoch>` marker before the call and never retries. It is armed only by
KV `cfg:failover=on` plus a declared hub fence, `cfg:failover_hub_fence_s`, at
least 120 s under the lease window (480 s at the defaults). Anything else is
off, and armed-but-unfenced pages hourly instead of promoting. It also needs
`JOBS_URL` set on the watchdog, and without that it does nothing. The old hub stays demoted until a
human runs `bin/hub-lease.sh promote --holder <old>`. The epoch bump makes
its rung-1 renew miss. That holds only while the new holder keeps renewing,
because if the lease expires, rung 2 lets any box take it, the old hub included. The rule and its KV keys are in `docs/watchdog-spec.md`
§ Hub failover. Standbys report themselves through watchdog routes that
belong to a sibling slice of #401. Until those exist there is no standby row, and
the watchdog pages "HUB FAILOVER not possible" instead of promoting.

**Residual split-brain window.** The epoch bump only fences a holder that can
still HEAR the jobs worker. The case failover exists for is a hub that is alive
but partitioned from `*.workers.dev` (DNS, a Cloudflare edge or egress problem,
a firewall): its pings and renews stop, the watchdog promotes from Cloudflare's
side, and the old hub never gets a 409 because its renews fail as
*unreachable*, not *answered*. On the configured hub `bin/hub-lease.sh` then
fails OPEN (BH-1000), with no end, so without a fence the old hub keeps
dispatching and merging next to the new one for as long as the partition
lasts. There is no time bound in that case.

The bound comes from the hub's self-fence, `HUB_LEASE_FENCE_S` (BH-1922): past
that many seconds without an answered call, `check` exits 1 on the old hub (the
held=1 grace is capped at it too) and every gated lane stops. Its clock starts
at the last answered call. In a partition renews and checks stop together, so
that is at most one renew interval (60 s) after the lease's `updated_at`, so a fence F trips no later than F + 60 s after the lease stopped
renewing. The watchdog promotes no earlier than `cfg:failover_lease_min` after
that and refuses to arm unless F + 120 s fits under it. So `check` on the old
hub is already non-zero when the promote lands. What is left is work already in
flight: a gated lane that passed `check` before the fence keeps running to its
end, and can overlap the new holder's first lanes. That remainder is bounded by
the longest gated lane, not by the lease TTL. With `HUB_LEASE_FENCE_S` unset,
automatic promotion must stay off. `cfg:failover_hub_fence_s` is the operator's
statement that the hub has the fence set; the watchdog cannot read the hub's env.

**What is NOT built, stated so nobody plans around it.** There is no standby box
— no second machine is kept warm waiting to become the hub, and today only the
hub runs `renew` at all, so an expired lease sits expired until someone renews or
promotes. There is no automatic promotion either: nothing watches for "the hub
has been gone N minutes" and moves hub-ness on its own. Moving it is a human
decision executed with one command, `bin/hub-lease.sh promote --holder <box>`
(through the guarded `POST /api/hub/promote` since BH-2272; stop the old hub
first), and that command is not a rollout step.

---

## Failover drill (BH-402)

Status: the drill script, `bin/failover-drill.sh`, lands with BH-402.3 (#2749).
Until that merges, this section is the procedure it will run. The renew pause
it depends on is already in `bin/hub-lease.sh` (BH-2750).

The drill checks that the standby really takes over. It stops the hub renewing
its lease, waits for the watchdog to promote the standby, proves the standby
does the hub's work, then promotes the hub back.

**Before you run it**, on the hub:

- KV `cfg:failover=on`, and `cfg:failover_hub_fence_s` set.
- KV `cfg:orgo_restart` off for the run, so the watchdog does not restart the
  hub while the drill is holding its lease back on purpose.
- D1 `hub.promote_enabled=1`.
- `FAILOVER_DRILL_POOL_PROJECT` set to a fixture project whose `flags/fly-pool`
  is on.
- `flags/failover-drill-ok` present. The drill refuses without it.

**Expected noise.** The watchdog's hub-stale page fires, because stale is what
the drill is causing. You also get a chat reply in Telegram from the chat proof.

**Command:** `bin/failover-drill.sh [--force] [--report-dir <dir>]`. Exit 0 is
PASS, 1 is FAIL or INCOMPLETE, 2 is a bad argument, 3 is a refusal (a
precondition is missing; stderr names it). `--force` skips the once-a-day guard.

**Reading the report.** It is written to
`<report-dir>/FAILOVER-DRILL-<YYYY-MM-DD>.md`, default dir
`$HARNESS/state/failover-drill`. It has a timeline table, four proof lines of
the form `PROOF <n> <name>: <verdict> — <detail>`, the demotion result, and a
last line `Verdict: PASS|INCOMPLETE|FAIL`. PASS means every proof is OK and
both demotion checks passed. INCOMPLETE means at least one proof is UNPROVEN
and none failed. The same verdict goes to `state/failover-drill-last.json`
(`{ts, verdict, detail, report}`) and one line to `logs/failover-drill.log`.

**Committing the report.** The drill never commits. Copy the report to
`docs/FAILOVER-DRILL-<date>.md` in a PR.

**Renew pause.** `flags/hub-lease-renew-paused` holds an integer epoch deadline.
While now is before it, `bin/hub-lease.sh renew` logs
`renew: paused by flags/hub-lease-renew-paused until <iso>` and exits 1 without
calling the worker. Once the deadline passes, or if the file is empty or not an
integer, renew deletes it, logs `renew: pause flag expired/invalid, removed`
and renews as normal. So a SIGKILLed drill cannot leave the hub unrenewed past
its own deadline. `check` and `promote` ignore the file.

**Manual failback.** If the drill dies with the standby holding the lease, it
does not promote back on its own; it writes one ALERTS line saying so. Run
`bin/hub-lease.sh promote --holder <hub> --override-live-lease`. After a
SIGKILL, also remove `flags/lane-off-watchdog-ping`,
`flags/lane-off-poll-commands` and `flags/hub-lease-renew-paused` on the hub.

**Knobs.** Environment variables with defaults, because the drill is not a
registered lane yet:

| Variable | Default | What it does |
|---|---|---|
| `FAILOVER_DRILL_POOL_PROJECT` | unset; set it before the run | fixture project for the pool proof |
| `FAILOVER_DRILL_PROMOTE_DEADLINE_S` | 1500 | how long to wait for the watchdog's promote; must stay under 1740 |
| `FAILOVER_DRILL_MIN_INTERVAL_H` | 24 | the once-a-day guard `--force` skips |
| `FAILOVER_DRILL_POLL_S` | 30 | poll interval while waiting for the promote |
| `FAILOVER_DRILL_DEMOTE_SETTLE_S` | 180 | how long the old hub gets to see it lost the lease |
| `FAILOVER_DRILL_SSH` | `ssh -o BatchMode=yes -o ConnectTimeout=10` | ssh command used to reach the standby |
| `FAILOVER_DRILL_NOW` | unset | test seam for the clock |

**Enabling it monthly.** `cron/boxes/hub.d/696-failover-drill-proposal.cron`
carries the proposed line, commented out. It stays that way until the first
manual run passes. Enabling it is a lane: a `catalog/lanes.d` entry and the line
moved to `cron/lanes/` with `# @hub-lanes`.

---

## Open questions for review

1. **Does the hub run builds?** `preplan-tick` only fires when a `run-build` is
   already running on the same machine. If the hub never builds, preplan-tick
   never fires there and is a non-issue — the measurement in step 1 settles it.
2. **Alert sharding key.** Alerts are fleet-tagged; project-of-origin is usually
   derivable but not always. What happens to an alert whose project cannot be
   determined — hub residual, or a named "unattributed" bucket? Decided: a named
   bucket. **A bucket can be counted; a residual is just whatever is left.**
3. **Ordering against the extra-usage flip.** My recommendation is caps first,
   flip second, migrate third. Migrating into freshly-uncapped accounts inverts
   the safety the caps are meant to provide.
4. **Who owns project-1?** The one decision that blocks everything else here.
   Recommendation above; it is not mine to make alone.
5. **medic's 32 grok calls priced at $0.00.** Either the grok capture missed
   them or they were empty calls that still billed. Both matter: the first is a
   ledger hole in a lane we are about to hold to a budget, the second is the
   `empty`-vs-`failed` distinction from the metered-API doctrine. Worth settling
   before medic gets used as the counterexample everything else is measured
   against.
6. **Is rule-miner worth keeping at all?** Weekly, fleet-scoped, and its output
   feeds a process nobody has measured this week. Worth a look before it gets a
   budget row rather than after.
