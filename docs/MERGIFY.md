# Mergify as the fleet's merge queue — ops page

**Decision (the operator, 2026-09-12).** GitHub's native merge queue is unavailable to us: example-org
is on GitHub **Team**, and the rulesets API rejects a `merge_queue` rule on a private repo
with `422 Invalid rule 'merge_queue'` (GitHub limits private-repo merge queues to Enterprise
Cloud). **Mergify** — a GitHub App, free at ≤ 5 active contributors — gives the same
guarantee on the plan we have: a PR is built on top of *current* main, alone or in a batch,
and merged only if that tree is green.

The harness treats it as a second merge-queue **provider**. The design, the label contract
and what is verified vs assumed live in `docs/MERGE-CONDUCTOR.md` §6; this page is what an
operator has to DO.

First repo: **`example-org/project-5`**.

---

## 1. Ops steps (a human does these; the harness does not)

The harness deliberately never creates repo-level metadata or installs apps on a failure
path — a merger that can invent a label is how a typo becomes a silent second queue. So:

1. **Install the Mergify GitHub App on the org**, granting it the repos you want queued.
   <https://github.com/apps/mergify> → *Install* → **example-org** → *Only select
   repositories* → `project-5`. Mergify needs read/write on pull requests, checks, contents
   and issues; it asks for them at install time.

   **Then ACTIVATE TWO products in the Mergify dashboard: Merge Queue AND Workflow
   Automation.** They are separate toggles. `queue_rules` and the `@mergifyio queue` command
   belong to Merge Queue; `pull_request_rules` — the `label = merge-queue` rule that makes our
   label an entry — belong to Workflow Automation. With only Merge Queue on, the label rule is
   never evaluated: on 2026-09-13 twelve of twelve project-5 entries came from the command and
   zero from the label until the operator activated Workflow Automation (dashboard → repo → Workflow
   Automation → "Activate"; the rule then shows as **Enabled**). Installing the app is not
   enough and this is not theoretical: on 2026-09-12 `@mergifyio queue` on `project-5`
   #510 answered **"The product Merge Queue needs to be activated"** with everything else
   already correct. The harness asks the queue, gets nothing, and since BH-2199 **holds** the
   PR READY — it never merges around a `queue_rules` repo's queue — raising one alert a day:
   `mergify queue not answering for <slug> — READY PRs are held, NOT merged`, and asking again
   every `MC_MERGIFY_REASK_TICKS` held ticks. Nothing lands until the queue answers or a lead
   merges by hand, so treat that alert as work to do now.
2. **Create the trigger label in each queued repo** (once per repo):

   ```bash
   gh label create merge-queue -R example-org/project-5 \
     --color 0E8A16 --description "Harness merge conductor: enqueue in Mergify"
   ```

   And the two labels the hotfix lane reads (section 2.1), once per repo, for the
   same reason — the harness never creates repo metadata on a failure path.
   `fix-main-red` is the one the Mergify hotfix queue keys on; `hotfix` is the
   pool's build-priority label and queues in `default`:

   ```bash
   gh label create fix-main-red -R example-org/project-5 --color B60205 --description "Fixes a red main: Mergify hotfix queue, head of the line, batch of one"
   gh label create hotfix -R example-org/project-5 --color D93F0B --description "Hotfix lane: built first by the pool; queues in default"
   ```

   If this is missing, the label write (REST `POST /issues/{n}/labels`) fails and the conductor holds the PR (BH-2199) with the daily alert — the old `gh pr edit --add-label`
   errors, the failure is logged with gh's own message, and two of them page
   `BLOCKED_HUMAN`. It never fails quietly.
3. **Commit `.mergify.yml` to the repo's DEFAULT BRANCH** (template below). The harness
   probes exactly that path: `.mergify.yml` at the repo root, containing `queue_rules:`.
   Mergify also reads `.github/mergify.yml` and `.mergify/config.yml` — the harness does
   **not** probe those, so use the root file.
4. **Check the required check name.** The template's `check-success` must be the exact name
   of the repo's required CI check. Read it off a recent run:

   ```bash
   gh api repos/example-org/project-5/commits/$(gh api repos/example-org/project-5 -q .default_branch \
     | xargs -I{} gh api repos/example-org/project-5/commits/{} -q .sha)/check-runs -q '.check_runs[].name'
   ```

5. **Confirm the harness sees it**, on the hub:

   ```bash
   . /root/harness/bin/lib/merge-conductor-lib.sh
   rm -f /root/harness/tmp/merge-queue-example-org_project-5.provider   # also drops its policy cache
   mc_queue_provider example-org/project-5   # -> mergify
   ```

   Until step 3 lands on the default branch this prints `none` and every actor behaves
   exactly as it does today. That is the rollback, and it needs no coordination.

---

## 2. `.mergify.yml` template

The source is `config/mergify/template.yml` plus one `config/mergify/repos/<project>.conf`
per repo (its checks, merge method and queue knobs). `bin/mergify-template.sh render <conf>`
prints that repo's `.mergify.yml`; `compare <conf> <yaml>` says whether a file drifted from
the render (rc 0 in sync, rc 1 a diff, rc 3 cannot compare), and `--check` runs every conf.
The block below is `project-5.conf`'s render with its comments filled out, and
`tests/mergify-template.bh-1673-test.sh` compares it against that render.

```yaml
# Merge queue for the cromford merge conductor.
# The conductor enqueues a PR by adding the `merge-queue` label (it never runs
# `gh pr merge` on this repo — that would bypass this queue), and settles the
# landing when Mergify merges the PR.
merge_queue:
  # How many batches Mergify may build SPECULATIVELY, at once, ahead of the one
  # it is merging. (This is the option older Mergify called `speculative_checks`
  # and set per queue rule; current Mergify names it `max_parallel_checks` and
  # sets it here.) Small batches only pay off if several of them can be in
  # flight, so this moves up when batch_size moves down.
  max_parallel_checks: 6

queue_rules:
  # FIRST IN THE FILE IS FIRST IN LINE. Mergify picks pull requests for the next
  # batch in queue order, so the hotfix queue is above default and nothing else.
  # It takes `fix-main-red` PRs only; a `hotfix` PR queues in default like any
  # other. Section 2.1 below is what this queue is for.
  - name: hotfix
    queue_conditions:
      - base=main
      - label=fix-main-red
      # A standing changes-requested review keeps a PR out of the queue, and
      # dequeues one that gets it while queued (BH-2275).
      - "#changes-requested-reviews-by=0"
      - "check-success=Build + Unit tests"
    merge_conditions:
      # ... and a batch holding such a PR cannot merge (BH-2275).
      - "#changes-requested-reviews-by=0"
      - "check-success=Build + Unit tests"
    merge_method: squash
    # ONE. An emergency never shares a batch: a batch is all-or-nothing, so a
    # red sibling would eject the fix that is meant to stop the bleeding.
    batch_size: 1
    # And it never waits to fill that batch of one.
    batch_max_wait_time: 0 s
    max_checks_retries: 0
    checks_timeout: 45 min
  - name: default
    # Refuse to take a PR whose own CI is not green yet.
    queue_conditions:
      - base=main
      # A standing changes-requested review keeps a PR out of the queue, and
      # dequeues one that gets it while queued (BH-2275).
      - "#changes-requested-reviews-by=0"
      - "check-success=Build + Unit tests"
    # Refuse to MERGE a batch whose build is not green.
    merge_conditions:
      # ... and a batch holding such a PR cannot merge (BH-2275).
      - "#changes-requested-reviews-by=0"
      - "check-success=Build + Unit tests"
    merge_method: squash
    # FOUR since 2026-09-21 (the operator); a repo that can't afford the larger ejection
    # blast radius overrides it in its conf (cromford runs 8, with one retry).
    batch_size: 4
    batch_max_wait_time: 3 min
    # A retry hides a real failure and costs another CI run, so 0 is Mergify's
    # default and the conf's default (`max_checks_retries`, 0..2); a repo can
    # opt into one retry for flaky shards (project-5 does). The hotfix queue
    # stays 0 whatever the conf says.
    max_checks_retries: 1
    # Explicit so a slow run is not dequeued by an `auto` timeout.
    checks_timeout: 45 min

# PRIORITY IS WHAT PREEMPTS, queue order is what seeds the next batch — the two
# do different jobs and the hotfix lane needs both (section 2.1). This one
# interrupts running batches, so it fires for a main-red fix only.
priority_rules:
  - name: hotfix first
    conditions:
      - label=fix-main-red
    priority: high
    allow_checks_interruption: true

pull_request_rules:
  - name: queue a hotfix at the head of the line
    conditions:
      - base=main
      - label=merge-queue
      - label=fix-main-red
    actions:
      queue:
        name: hotfix
  - name: queue on the harness label
    conditions:
      - base=main
      - label=merge-queue
      # EVERYTHING ELSE, literally: without this a fix-main-red PR matches both
      # rules and Mergify is handed two queue actions for one pull request.
      - -label=fix-main-red
    actions:
      queue:
        name: default
```

Notes on the values:

- **`check-success=Build + Unit tests`** is a placeholder for *this repo's* required check —
  replace it with the exact name from step 4, in both condition lists. A name that matches
  nothing means the PR never satisfies `queue_conditions` and sits in `QUEUED` until the
  conductor's 3600s budget pages.
- **`queue_check=`** (conf key, 2026-09-24) is for a repo
  that runs its test corpus ONLY on the batch draft, as cromford now does ("each tree is
  tested exactly once"). `queue_check=` lines replace the check list in `queue_conditions`
  (the fast checks an ordinary PR runs); `check=` lines stay the `merge_conditions`, which
  Mergify evaluates on the draft. With the two lists different Mergify never checks a PR in
  place, so every batch (even a batch of one) is a draft. A conf without the key renders
  exactly as the template above.
- **`batch_size: 4` + `max_parallel_checks: 3` + `batch_max_wait_time: 3 min`** is the
  default since 2026-09-21 (the operator), and a repo that can't afford the larger ejection blast
  radius overrides it in its conf. cromford ran `batch_size: 2` / `2 min` until
  2026-09-24, when the operator moved it to `batch_size: 8`, `batch_max_wait_time: 3 min` and
  `max_checks_retries: 1` (the conf's opt-in retry, default queue only): the pool now builds
  ~12 PRs at a time, and Mergify splits a red batch to find the culprit. The history: on
  2026-09-14 it went to `batch_size: 2`. Before that it was `batch_size: 5`, on the reasoning that the
  pool lands several PRs a tick and batching five of them turns five serial CI runs into one.
  What that reasoning left out is the failure path: a batch is all-or-nothing, so ONE red PR
  ejects every sibling in its batch. `project-5` #611 was ejected at 03:53Z on 2026-09-14
  because a *different* PR in its batch of five went red — #611 itself was green, and it paid
  a full re-queue, a fresh `merge_group` build and a `queue-ejected` mark (two of those and
  the conductor parks the PR in `BLOCKED_HUMAN`). At `batch_size: 2` one red PR costs at most
  one innocent sibling, and `max_parallel_checks: 3` keeps the throughput by building three
  batches speculatively instead of one big one. The harness reads nothing from these numbers
  — they are a queue-side tuning knob, and `docs/MERGE-CONDUCTOR.md` §6's ejection handling
  is unchanged either way.
- **`merge_method: squash`** matches every other merge path in the fleet.
- Mergify's own labels (`queued` by default, `dequeued` by default, `checking` unset by
  default) are left at their defaults. The harness reads them as a second witness and writes
  exactly one of them, on exactly one path: **the re-entry sweep removes `dequeued`**
  (BH-636). That is not a general licence — `mc_dequeue_label` still touches only our own
  trigger label — it is that `dequeued` is the marker keeping the head out of the queue, so
  re-adding `merge-queue` while it is on would be a no-op. Everything else Mergify labels
  stays Mergify's.
- **The label is the mark, the command is the ask, the idle check is not a witness
  (2026-09-13).** Twelve of twelve queue entries on `project-5` that day were "triggered by
  @operator with the `@mergifyio queue` command" — the `label = merge-queue` rule in
  `.mergify.yml` has never queued a PR (why is in the Mergify dashboard's Activity Log, not
  in GitHub). And Mergify posts a neutral `Mergify Merge Queue` check titled **"Merge queue
  is ready"** on every PR it has evaluated, queued or not (#546 carried it with no label
  ever; #547 carried it for 46 minutes unqueued), so that line is filtered out of the
  witness (`mc_mergify_check_live`). The `queued` label lands ~2 s after a real entry.

---

## 2.1 Hotfix queue

**The Mergify hotfix queue keys on `fix-main-red`, on the pull request.** That
is the main-red label (`MAIN_RED_LABEL`, `bin/lib/main-red-label.sh`). The
`hotfix` label (`bin/lib/hotfix-lib.sh`, renamed fleet-wide by `HOTFIX_LABEL`
in `env/global.env`) stays the pool's build-priority signal, so a ticket
labelled `hotfix` is still built first. Its PR queues in `default` like any
other. A PR in the hotfix queue is reviewed, built and gated exactly like every
other PR: same `queue_conditions`, same required check, same branch protection.
This lane changes the ORDER of the queue, never the bar.

**Why `fix-main-red` and not `hotfix` (BH-2121).** Jumping the queue is not
free: `allow_checks_interruption` restarts every batch already running. On
2026-09-24 at 17:04Z a `hotfix` PR (#2104) did that. A green 8-PR batch was
thrown away and three batches restarted. Urgent is not the same as main being
red, so only a PR that fixes a red main may do this.

**Why `batch_size: 1`.** A batch is all-or-nothing — one red PR ejects every
sibling in it (`project-5` #611, 2026-09-14). An emergency that can be ejected
by somebody else's red test is not an emergency lane, so a hotfix rides alone
and `batch_max_wait_time: 0 s` says it never waits for company it cannot have.

**Which mechanism actually preempts** (read off docs.mergify.com's
`merge-queue/priority`, `merge-queue/batches` and `merge-queue/rules` pages on
2026-09-17, not from memory). They do two different jobs:

- **Queue order** — "Priority is always the first criterion when selecting pull
  requests for batching", and batching "never overrides priority or queue
  order". That is what makes the hotfix queue the next batch SEEDED, and the
  reason its entry sits above `default` in `queue_rules`.
- **`priority_rules` + `allow_checks_interruption: true`** — the documented
  control over checks that are ALREADY RUNNING: by default (`false`) Mergify
  "does not interrupt ongoing checks: the higher-priority pull request is
  inserted just after the pull requests whose checks are running", and `true`
  lets it "interrupt those checks and test the higher-priority pull request
  first". That is what gets a hotfix past a `default` batch already in flight.

So the template configures both, each for the thing its own documentation says
it does. What the docs do NOT state is whether that interruption reaches across
two queues; the harness does not claim it does. The proof is Mergify's own
status comment on a labelled PR, and until that has been read on a live repo
this page says exactly that: **owed, not observed.**

**Degraded mode — when the queue is not answering at all.** Since BH-2199 the
conductor HOLDS every READY PR, hotfix included, and asks the queue again every
`MC_MERGIFY_REASK_TICKS` held ticks; the hotfix is still asked first. The
paragraph below describes the direct-merge ordering this replaced (it no longer
merges anything): with the Merge Queue product off (or the label write refused)
the conductor used to bypass the queue and merge directly, and then nothing on
Mergify's side was ordering anything.
So `bin/merge-conductor.sh` does the ordering itself, and only in that mode: it
launches the repo's `hotfix`-labelled PRs first and records them for the tick,
and a plain PR that finds one still in flight logs
`degraded direct merge DEFERRED this tick: hotfix PR(s) #N merge first` and
tries again on the next tick (≤ 5 min) — it never waits on the hotfix, and it
writes nothing meanwhile. When the hotfix lands this way the lane says so out
loud: a `HOTFIX merged` line in `logs/ALERTS.log` with the ticket and the PR
URL, plus one triaged `fleet_alert` beat, deduped by
`state/hotfix-announced/<project>/<KEY>.merged`. The daily
`mergify queue not answering …` alert is unchanged and still fires once per
repo per day.

**Kill switch.** `touch /root/harness/flags/hotfix-lane-off` (or `HOTFIX_LANE=0`
in `env/global.env`) puts the whole lane back to its pre-#367 behaviour with no
edit to a script: no reordering, no deferral, no announcement. The Mergify side
is rolled back by taking the `hotfix` queue and its `priority_rules` entry out
of `.mergify.yml` on the default branch, which is section 4's story unchanged.

## 2.2 Pre-queue verdict

**The status.** The conductor publishes a commit status with context
`prequeue-verdict` on the PR head (BH-5441). The code is in
`bin/lib/mc-prequeue.d/status.sh`. It calls `vs_publish` with the context
changed, so it uses the same identity as `lead-verdict`. One POST goes out per
(head, state). The `pqst <slug> <head> <state>` attempt line records it, and
only a 2xx writes that line. A refused POST writes one log line and no attempt
line, so the next tick that asks the gate tries again.

**Who publishes it, and when.**

- `pq_gate`, on the tick that decides, before the READY mark and the enqueue:
  - A red that names a suite publishes `failure`. The description is the first
    line of the cache entry's `.why` file, else `suites: <list>`.
  - A proceed publishes `success`. The description gives the reason:
    `green on main <m12>` (also `no-selection` and `conflict`),
    `could-not-run (<why>): enqueued without it`, `no pre-queue workflow`,
    `proceed on main <m12>` (a resolver proceed with no entry on this main),
    or `gate off`.
  - A `hold` (main tip unreadable, a run still pending), a `rebase` and a
    `defer` publish nothing. None of them enqueues on that tick.
- The QUEUED TTL arm (`mc_vs_ttl_republish`, with an approval bound to the head
  and actions and merges on) and the rebind arm (`mc_rebind_publish`, after a
  published lead-verdict carry) call `pq_status_ensure`. It publishes `success`
  only when the head has no `prequeue-verdict` status and no cache entry for
  that head reads red (any PR number, any main). It never overwrites a
  `failure`. It also does nothing on `error`, `pending`, `success` or a status
  it cannot read.

The queue readers skip this context: autoenqueue G4 and the archie-fm-queue
enqueue step (`_ae_required_checks`), and the stuck-batch pass
(`mc_mergify_required_checks`). They read the names from `qsc_list` in
`bin/lib/queue-status-contexts.sh`: the lead-verdict context in force, then
`prequeue-verdict`.

**The conf key.** `default_status_check=<name>` (repeatable) renders
`check-success=<name>` in the `default` queue's `queue_conditions` only, after
the queue checks. It never goes in the hotfix queue or in a `merge_conditions`.
The renderer refuses the same values as `status_check`, and it refuses a name
that is also a `check=`, `queue_check=` or `status_check=` line (rc 2). A conf
without the key renders byte for byte as before. No conf sets it today.

**The `fix-main-red` override.** The hotfix queue has no `prequeue-verdict`
condition. A `fix-main-red` PR enters it with no pre-queue verdict. The hotfix
queue interrupts running batches (section 2.1), so use `fix-main-red` for a
main-red fix only.

**The switch.** `lane.merge-conductor.mc_prequeue_gate=0` (per project:
`lane.merge-conductor.<project>.mc_prequeue_gate`) turns the gate off. The gate
then publishes `success` with the description `gate off` on every head it is
asked about, so the default queue still admits it.

**The flip.** The condition is not live. If `default_status_check` is set in
the same merge that adds the publisher, Mergify dequeues every queued head that
has no status yet. The flip is a separate PR. Do these steps in order:

1. Merge the PR that adds the publisher (BH-5441).
2. Wait one conductor tick. A head the conductor gates after the merge gets its
   status on that tick. A head that was already QUEUED is not gated again: it
   gets a status only from the TTL ensure (past `MC_QUEUE_TTL`) or a rebind.
3. For every QUEUED head, run
   `gh api repos/example-org/cromford/commits/<head>/status --jq '.statuses[]|select(.context=="prequeue-verdict")|.state'`.
   Each one must print `success`.
4. If one prints nothing, stop. Find out why that head has no status.
5. Decide the archie-fm-queue path. It enqueues through `mc_enqueue_mergify`
   and never calls `pq_gate`, so a head it enqueues has no status until the TTL
   ensure runs. Either make that path call `pq_gate` first, or accept that its
   heads wait for the TTL ensure.
6. Add `default_status_check=prequeue-verdict` to
   `config/mergify/repos/cromford.conf`.
7. Regenerate `.mergify.yml` and run `bin/mergify-template.sh --check`.
8. Put the probe output from step 3 in that PR body.

---

## 3. What the harness then does

| | |
|---|---|
| Enqueue | `bin/merge-conductor.sh` classifies the PR `READY`, re-reads its head, adds `merge-queue`, posts `@mergifyio queue`, waits for a **live** Mergify witness (its `queued`/`checking` label, or a `Mergify Merge Queue` check whose title is not the idle "Merge queue is ready"), and writes the row `QUEUED` |
| Settle | the conductor's `QUEUED` pass sees `MERGED` and runs `mc_settle_merged`: merge ledger row, `state/merge-sweep-done.txt`, the `merge_sha` artifact, the issue close, the deploy request, the ship beat — exactly once |
| Eject | a failed Mergify check (or the label gone) → `WAIT_CI reason=queue-ejected`, our label removed, the head marked `ejected` |
| Re-entry | **BH-636.** Mergify ejects the CULPRIT OF A BATCH, and a batch goes red for a sibling's flake as readily as for this diff. So an ejected head whose own checks are still green at that sha, whose approval is bound to that sha and whose merge state is `CLEAN` goes back in ONCE per (PR, sha): `dequeued` removed, `merge-queue` re-added, `@mergifyio requeue` posted, witness polled, log `REQUEUED <pr> <sha>`. Capped at `MC_REQUEUE_CAP` (5) per project per tick. A RED head is never re-queued — it is named once (`DEQUEUED_RED`) and left to the red ladder. **Nothing on this path merges**: an unwitnessed requeue parks the row rather than falling through to a second queue ask (and since BH-2199 no path merges around the queue) |
| Eject again | a second ejection after a requeue (`reejected`) → `BLOCKED_HUMAN reason=queue-ejected-twice`, which `bin/blocked-resolver.sh` owns. A genuinely broken PR cannot loop |
| Change requested | every queue rule carries `#changes-requested-reviews-by=0` in queue_conditions and merge_conditions (BH-2275), so a PR with a standing change request never enters and a batch holding one cannot merge. When a lead/human CR lands on a queued or held PR, the conductor removes `merge-queue` and posts `@mergifyio dequeue` once per (PR, head, review) (`CR_DEQUEUED` in its log) |
| Provider unreadable | a `.mergify.yml` probe that fails (5xx, rate limit, network error; a 404 is still "no queue") makes the provider `unknown`, never cached: the conductor holds the repo's tick with one alert a day, and `mc_enqueue` and the console Merge button refuse. Nothing merges on a guess (BH-2275) |
| Queue not answering | the label goes on, nothing acknowledges it, so the conductor **holds** the PR READY (BH-2199: never a direct merge on a `queue_rules` repo), keeps our label on, raises one alert per repo per day, and asks again every `MC_MERGIFY_REASK_TICKS` held ticks. A direct merge is a lead action. The `@mergifyio queue` comment itself is posted once per head (the ask ledger, `MC_MERGIFY_REASK_S`, default 6h; cleared when Mergify answers) — docs/verification-map/ci-cost-lanes.md |
| Stuck batch | **BH-1790, BH-1887.** Mergify sometimes misses a check-completion event and leaves a batch draft (`mergify/merge-queue/*`) green and unmerged, which stalls the queue behind it. Each tick the conductor lists the repo's open batch drafts and reads the `check-success` names in `.mergify.yml`'s `queue_rules` (every queue, both condition lists; `~=`, `!=` and negated conditions are not required names; `pull_request_rules` are not queue conditions). A draft whose non-Mergify check runs are all completed and green, with a run for every one of those names, the newest completion at least `MC_MERGIFY_STUCK_SECS` (300) old, gets `@mergifyio refresh` on the DRAFT, at most once per `MC_MERGIFY_REFRESH_WINDOW_SECS` (3600; 0 = once per head; 1-299 reads as the conductor tick, 300 or `MC_TICK_SECS` if longer). A required name with no run = no refresh, logged `has no run for required check(s)`. The attempts ledger records `mergifyrefresh` when the refresh is first tried and `mergifyposted` only when the POST returned 0; a failed POST is retried on the next tick and does not use up the window. Merge mode only; other modes log `MERGIFY_REFRESH WOULD`. Still stuck `MC_MERGIFY_STUCK_ALERT_SECS` (600) past the point the refresh was due = one `MERGIFY_BATCH_STUCK` alert per day, for the OLDEST open batch draft only (a green batch behind it is waiting on it by design); when no refresh was ever posted the alert says it could NOT be posted. An unreadable list, check-run page or `.mergify.yml` refreshes nothing |
| Everyone else | `bin/merge-sweep.sh`, `bin/review-prs.sh`, `bin/run-build.sh`'s tier-1 gate, `bin/merge-queue.sh` and `bin/tier2-merge-sweep.sh` all stand down on a mergify repo and say so in their logs |

`bin/poll-commands.sh`'s `merge_pr` is the one exception: an explicit human merge from
Mission Control still merges directly (bypassing the queue on purpose), and reports back
honestly which of the two happened.

---

## 4. Rollback

Any one of these returns the repo to the synchronous path. No flag to flip, no fleet-wide
coordination. **When** depends on whether you nudge it:

- **Immediately** if you delete `tmp/merge-queue-<owner>_<repo>.provider` on the hub.
  The next probe then also drops that repo's entries under `state/gh-policy-cache/`, so it
  asks GitHub fresh (BH-1586).
- **Otherwise within `GH_POLICY_TTL_SECS` + `MC_QUEUE_TTL`** (default 1 h + 5 min). A
  present `.mergify.yml` is a positive policy answer and is cached for the knob's TTL
  (`lib.gh-policy-cache.gh_policy_ttl_secs`). Until then the conductor keeps labelling and
  nothing merges. That is a stall, never a bypass.

Onboarding runs the other way and is never delayed by the cache. A missing `.mergify.yml`
(a 404) is **never** cached, because `none` is the bypass direction. So a repo that gains
`.mergify.yml` reads `mergify` at the next probe (≤ `MC_QUEUE_TTL`, or at once if you
delete the provider file).

- delete the `pull_request_rules` entry (nothing is ever enqueued again), or
- remove `.mergify.yml` from the default branch (`mc_queue_provider` → `none`, every actor
  reverts to exactly the code path it took before), or
- uninstall the app for that repo (`.mergify.yml` still present → the provider still reads
  `mergify` and enqueues fail loudly rather than silently; prefer one of the two above).

Then take the label off any PR still carrying it:

```bash
for n in $(gh pr list -R example-org/project-5 --label merge-queue --json number -q '.[].number'); do
  gh pr edit "$n" -R example-org/project-5 --remove-label merge-queue
done
```

---

## 5. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `mc_queue_provider` says `none` | `.mergify.yml` not on the default branch, not at the root, or has no `queue_rules:` | step 3 |
| conductor log: `gh pr edit --add-label merge-queue failed: … not found` | the label does not exist in the repo | step 2 |
| alert `mergify queue not answering for <slug> — READY PRs are held, NOT merged` (before BH-2199: `— merged directly (degraded)`), PRs sit READY with the `merge-queue` label | **the Merge Queue product is not activated** (Mergify's own words: "The product Merge Queue needs to be activated"), or the app is not installed on this repo, or no `pull_request_rules` entry keys on the label | steps 1 and 3. Nothing merges meanwhile (BH-2199); a lead may merge an urgent PR by hand. The alert repeats once a day until it is fixed |
| PR sits `QUEUED` past its 3600s budget and pages | `queue_conditions` never satisfied (usually a wrong `check-success` name), or the queue is paused | step 4; `gh pr view <n>` shows the Mergify check's own explanation |
| a `fix-main-red` PR is queued in `default` (Mergify's status comment names the queue). A PR with only `hotfix` in `default` is expected: that label is build priority, not a queue key | the `fix-main-red` label is not on the PR, or the repo's `.mergify.yml` on its DEFAULT branch predates the hotfix queue or still keys it on `hotfix` (before BH-2121) | step 2 for the label; land the `.mergify.yml` change on the default branch (section 2). The PR still merges — through the ordinary queue, at ordinary speed |
| repeated `queue-ejected` | the PR genuinely breaks against current main | read the batch's CI run; the conductor pages `BLOCKED_HUMAN` on the second ejection. Since BH-636 the FIRST ejection of a still-green head is re-queued once (`REQUEUED <pr> <sha>` in `merge-conductor.log`) — a PR that is ejected again after that is the one the batch really is about |
| `REQUEUE_UNWITNESSED` in the log, row `WAIT_CI reason=requeued on <sha8>, awaiting Mergify's witness` | the labels went back on and Mergify acknowledged nothing — usually the same cause as "queue not answering" above | steps 1 and 3. The row deliberately WAITS: the re-entry sweep never merges, and one requeue per (PR, sha) is all it will ever buy |
| a batch draft sits green for minutes and nothing merges; Mergify says "Waiting for check-success = …" on a check that passed | Mergify missed the check-completion event (BH-1790) | the conductor posts `@mergifyio refresh` on the draft after `MC_MERGIFY_STUCK_SECS`; by hand, post the same comment on the DRAFT (a member PR does not help). `MERGIFY_BATCH_STUCK` means the refresh did not help (read the queue in the Mergify dashboard), or, when it says the refresh could NOT be posted, that the conductor's token could not comment: post it by hand |

Mergify's REST API (`GET https://api.mergify.com/v1/repos/:owner/:repo/merge-queue/status`,
`POST …/merge-queue/pull/:n/dequeue`, `Authorization: Bearer <token>`) is useful for a human
debugging a wedged queue. The harness deliberately does **not** use it for reads: it would be a
second credential to rotate and a second source of truth, and everything the conductor needs is
already visible through `gh`. The one planned exception is the scopes upload in section 6, which
is dark until its flip PR mints that credential. The one read exception is the hub lane
`bin/merge-queue-reconcile.sh` (BH-5670): it reads `merge-queue/status` only while a repo has an
active queue row, only behind `MERGIFY_API_TOKEN`, and only to correct a stage row a dropped
webhook left wrong (docs/notes/2026-10-10-BH-5670-merge-queue-reconcile.md).

---

## 6. Parallel lanes (BH-4979)

**Status: shipped dark.** `config/mergify/repos/cromford.conf` says `queue_mode=serial`,
so `.mergify.yml` is unchanged and the queue still runs one serial stream of batches. With no
settings row the conductor runs in `shadow` mode. It works out each PR's lane and logs it,
and it uploads nothing.

**What a lane is.** Mergify's "partition rules" were removed on 2025-10-31. Their successor is
parallel queue mode with manual scopes: `merge_queue.mode: parallel` plus
`scopes: {source: {manual: {}}}`, with each commit told its scopes by
`PUT /v1/repos/<owner>/<repo>/commits/<sha>/scopes`. That endpoint and its body
(`{"scopes":[…],"all_scopes":false}`) come from the BH-4979 plan's research. Nothing on the
fleet has called it yet, so the flip PR's probe is what confirms it. PRs that share a scope
are batched together in order. PRs with disjoint scopes test and merge in their own lanes on
fresh main. A PR uploaded with `all_scopes: true` is a barrier: the serial lane.

**How a PR gets its scopes** (`bin/lib/queue-partition.sh`, called from `mc_enqueue_mergify`
after the `lead-verdict` publish and before the label, so every enqueue path goes through it):

- The scopes are the suites `bin/test-impact.sh select --why` maps the PR's changed files to,
  built against the conductor's own checkout of main, **minus the always-suites**. Every
  selection carries those, so counting them would put every PR in one partition. A suite
  also picked for another reason stays. Only always-suites (a docs-only PR) gives the single
  scope `_inert`.
- **Serial (`all_scopes`)**: a file list that can't be read, more than 25 files, the
  `fix-main-red` label, a merge train, `risk_tier` = `high` (only when #4973's
  `risk_tier` is already loaded; not on main yet), a path matching the settings row `queue_partition.serial_re`
  (fallback `QP_SERIAL_RE_DEFAULT`: `.mergify.yml`, `.github/`, `config/mergify/`, the jobs
  schema, migrations, `bin/lib/jobs/`, `bin/merge-*`, `bin/lead-*`, `bin/lib/verdicts.sh`,
  `bin/lib/mc/`, `bin/test-impact*`, `bin/ci-plan.sh`), or anything `test-impact.sh` would run
  the full corpus for (an infra change, a file main's map can't place, which includes every
  file the PR adds).
- Only a repo whose conf carries a `queue_mode=` line takes part, because the map is
  cromford's own tree. project-5's conf has none, so project-5 is untouched.

**The mode row** `queue_partition.mode` (`bin/jobs-client.sh setting-set …`):

| value | what the conductor does |
|---|---|
| no row, worker outage | `shadow` |
| `shadow` | logs `PARTITION <slug>#<n>@<head12> lane=<scoped\|serial> scopes=<k> reason=<why>` to `logs/merge-conductor.log`, uploads nothing |
| `enforce` | the same line, then the PUT (key on stdin via `curl --config -`, never argv). One PUT per head and payload: the ledger is `state/merge-conductor/queue-partition/<slug_>_<n>`, written only after a 2xx |
| `off` | nothing |
| anything else | `off`, with one log line saying so |

**Fail-closed.** On a `queue_mode=parallel` conf, a PR whose scopes were not uploaded (failed
PUT, no key, or mode `shadow`/`off`) is held with rc 3 and no label: the BH-2199 hold, no
strike. A scopeless PR never enters a parallel queue. On a `serial` conf, a failed upload is
one log line and the enqueue goes ahead.

**Read the shadow log first.** `grep PARTITION /root/harness/logs/merge-conductor.log` on
the hub shows the lane every enqueued cromford PR would have taken. If nearly every line
is `lane=serial`, lanes buy nothing yet. Tune `queue_partition.serial_re` before flipping.

**The flip checklist** (one PR, and it must carry the probe: the 2026-09-19 gating rule):

1. Mint a Mergify application key with the `ci` scope (Mergify dashboard, a human step).
2. Put it on the hub and the standby hub as `MERGIFY_CI_KEY` in `/etc/harness/env/`. CI
   doesn't need it.
3. Probe: `PUT /v1/repos/example-org/cromford/commits/<an open PR's head>/scopes` with
   `{"scopes":["_inert"],"all_scopes":false}` must answer 2xx. Paste the curl and its answer
   into the flip PR body.
4. In that PR: `queue_mode=parallel` in the conf, the re-rendered `.mergify.yml`
   (`bin/mergify-template.sh render`), and after it merges, the settings row
   `queue_partition.mode=enforce`. Between the merge and the row, enqueues are held (rc 3), not
   mis-queued. Set the row in the same sitting.

`scope_default_capacity` (conf, 1..8, never above `max_parallel_checks`) bounds the batches per
scope. `max_parallel_checks` stays the global ceiling, so lanes can't run more drafts at once
than today. `tests/mergify-scopes-cost-shape.bh-4979-test.sh` pins that the parallel render
changes nothing but the mode and the scopes block.

Rollback: set the row to `off` and the conf back to `serial` (`.mergify.yml` re-rendered). On a
parallel conf, `off` alone holds every enqueue, so the conf change is the real rollback.

## 7. Solo lane (BH-5430)

**Status: shipped in shadow.** `config/mergify/repos/cromford.conf` carries
`solo_label=queue-solo`, so `.mergify.yml` has a `solo` queue (between `hotfix` and `default`,
`batch_size: 1`, `0 s`, no retries, default's conditions plus `label = queue-solo`) and a rule
that routes `merge-queue` + `queue-solo` (and not `fix-main-red`) to it. The default rule
excludes `queue-solo`, so a PR matches one rule. There is no priority rule for `solo`, so
nothing interrupts running checks for it. The seeded mode row is `shadow`: the conductor
scores and logs, and adds no label.

**Why.** A batch is all-or-nothing and speculative batches stack. One risky PR fails its batch of
8 and every batch behind it, and Mergify bisects. On 2026-10-08 that held every merge for more
than 1.5 hours. A PR likely to break now tests alone.

**The score** (`bin/lib/queue-risk.sh`, called from `mc_enqueue_mergify` after the partition
block and before the `merge-queue` label, so every enqueue path re-scores under the current
rows). Each signal counts once per PR. Every weight, glob set, size limit, the threshold and
the mode are `queue_risk.*` settings rows (seeded in `worker/jobs/schema.sql`; the lib's
constants are only fallbacks):

| signal | weight row (seed) | what trips it |
|---|---|---|
| `shared_lib` | 30 | `queue_risk.globs.shared_lib` (`bin/lib/*`) |
| `ci_config` | 40 | `.github/*`, `.mergify.yml`, `config/mergify/*`, `bin/test-impact*`, `bin/ci-plan.sh` |
| `registry` | 25 | `catalog/*`, `cron/*`, `worker/jobs/src/index.js` |
| `generated` | 20 | the committed paths of the `## Generated files` table: `rules/CLAUDE.md`, `env-templates/*` (`catalog/lanes.json` and `cron/*.cron` are git-ignored, so no PR diff carries them) |
| `share_mirror` | 30 | `bin/share/*` |
| `schema` | 40 | `worker/jobs/schema.sql`, `worker/*/schema.d/*`, `*migrations/*`, `worker/jobs/src/lib/core.js` |
| `new_tests` | 10 | a test-shaped path main does not have yet |
| `size` | 15, twice at `size_lines_big` | additions + deletions ≥ `queue_risk.size_lines` (400); ≥ `size_lines_big` (1000) |
| `size_files` | 10 | changed files ≥ `queue_risk.size_files` (15) |
| `ejected_before` | 25 each, capped at 2 | `bejculprit <slug>#<n>` lines in the conductor's attempt ledger |
| `prequeue_red` | 20 | a `pqred <slug>#<n>` line (BH-4545's pre-queue park) |

`score >= queue_risk.threshold` (50) is `solo`. A PR whose files can't be read is `batch` with
the reason `files-unavailable`: unknown risk keeps today's routing and never goes solo, so a
GitHub blip can't put every PR in a size-1 lane. A `fix-main-red` PR and a merge train are not
scored (reason `fix-main-red` / `train`). An unreadable row uses the fallback and adds
`rows-unreadable` to the reasons.

**The mode row** `queue_risk.mode`:

| value | what the conductor does |
|---|---|
| no row, worker outage | `shadow` |
| `shadow` | logs `QRISK <slug>#<n>@<head12> score=<s> threshold=<t> route=<solo\|batch> mode=shadow (would route <r>) reasons=<…>` to `logs/merge-conductor.log` and records it (`POST /api/queue-risk`); no label write |
| `enforce` | the same line and record; `solo` adds `queue-solo` before `merge-queue`; `batch` on a PR still carrying `queue-solo` removes it |
| `off` | nothing, not even the PR read |
| anything else | `off`, with one log line |

Mission Control's MERGE QUEUE table shows each PR's score in a BREAK RISK column; the badge
opens the per-signal reasons.

**Before setting `enforce`, read the back-test.** On the last 50 merges to main before
2026-10-08 the seeded rules routed 38 solo (76%): almost every harness PR touches `bin/lib/` and
a catalog. That would serialize the queue, which is worse than today. A threshold of 100
routed 11 of 50 (22%). Tune `queue_risk.threshold` (or the weights) from the shadow QRISK lines
first.

**Forcing a PR solo.** Adding `queue-solo` by hand works until the next enqueue of a low-scoring
head in `enforce`, which removes it. To keep one solo, change a row instead.

**Parallel mode.** `solo` is its own queue rule. A PR sitting in it ignores the scopes
`qp_enqueue_step` uploaded for it.

**Operator step.** `gh label create queue-solo -R example-org/cromford` once. Until then the
first label POST creates it with GitHub's default colour.

**Rollback.** `queue_risk.mode=off`. Then delete `solo_label=` from the conf and re-render
`.mergify.yml`.
