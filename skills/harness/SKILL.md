---
name: harness
description: Work on any of the operator's projects through the cromford fleet — load a project into the fleet (load-project.sh), plan locally and hand the plan off as ai-build GitHub Issues the remote pipeline executes, and check/steer remote build status. Use when asked to "load a project into the harness", "hand this plan to the harness", "have the harness build this", "harness status", or to onboard a repo for remote autonomous builds.
---

# /harness — remote builds through the cromford fleet

The fleet (repo `~/cromford`, private `example-org/cromford`) watches
project boards and runs the full pipeline remotely: PLAN (acceptance tests + QA
screens) → red/green EXECUTE → semgrep → adversarial REVIEW → PR → preview QA →
merge lanes → deploy-verify, with model fallbacks, Fly builder lanes, cost-per-PR
attribution, and a watchdog. Small projects share one box (`box-small`);
their "board" is **GitHub Issues labeled `ai-build`** on the project repo.

Three verbs. Pick from the user's intent:

## 1. load — onboard a project into the fleet

```bash
cd ~/cromford && git pull --ff-only
bin/load-project.sh <owner/repo>              # e.g. example-org/project-11
#  --prod <url>        prod base URL (healthchecks + comment links)
#  --box <host>        default box-small
#  --context <file>    extra prompt context (mission, sharp edges)
#  --prefix <KEY>      ticket key prefix (default: initials, project-11 → RA)
#  --require-readiness <n>  refuse to enrol below this level (default 0 = off;
#                      n is 0..max_level from catalog/readiness-levels.json)
#  --repo-dir <checkout>  the local checkout to grade (required above 0)
```

Grade a repo before loading it: `bin/readiness-report.sh <checkout>` prints the
checks and a `READINESS LEVEL: n/max` line, and `--require-readiness` turns that
into a refusal that happens before anything is written (docs/READINESS.md).

It registers the project (registry row + rendered watcher prompt), pushes, ensures
the `ai-build` label, and bootstraps the box over ssh (crons, repo clone, smoke).
Loading builds NOTHING — the watcher only acts on `ai-build` issues.
Verify: the summary line, then `ssh root@<box> 'crontab -l | grep <project>'`.

**Browser QA wiring — a load is NOT done until all five are set** (project-6-os
merged 47 PRs with zero browser QA because these were missing; cromford #6254
makes load-project check them). Check with
`ssh root@10.0.0.9 'cd /root/harness; bin/postmerge-qa.sh <project> --dry-run'`:
1. `vercel.conf` row `<project> <teamId> <projectId> <prod-domain>` (preview QA).
2. A real prod URL in the registry (`--prod`; `bin/prod-url.sh <project>`), never `-`.
3. A Clerk QA test account on the PROD instance: create a user, record its id in
   hub `state/qa-accounts.json`, and put `QA_TEST_USER_ID` + `QA_CLERK_SECRET_KEY`
   (prod `sk_live`) in hub `env/<project>.env`. the operator approved test accounts for prod QA.
4. `deploy.<project>.kind` is not `none` (prod smoke on).
5. The prod host is one Clerk prod accepts: `curl -H "Origin: <prod>" https://clerk.<root>/v1/environment`
   must return 200. A `*.vercel.app` host returns 400 `origin_invalid` — use a
   subdomain of the Clerk root domain.

The fleet registry is D1 (BH-5651). To load into it, set `REGISTRY_SOURCE=db`
and `REGISTRY_ADMIN_TOKEN` in the shell that runs `bin/load-project.sh`, with
`HARNESS_SECRET` and `JOBS_URL` (or the fleet default):

- `bin/load-project.sh` writes the project row with `bin/registry.sh
  add-project`, then reads the row back from the registry.
- It does not change `fleet.conf` and does not commit it. It commits only
  `prompts/<project>.md`.
- With `REGISTRY_SOURCE=db` and no `REGISTRY_ADMIN_TOKEN`, it stops with
  FATAL and writes nothing.
- Without `REGISTRY_SOURCE=db`, it appends the row to the committed
  `fleet.conf` (file mode).

Check the row: `bin/registry.sh show`. The project must be in the
`projects=` list of its box.

## 2. plan + handoff — plan here, execute remotely

Plan the work in the project's own directory the normal way (plan mode, repo
CLAUDE.md, acceptance tests). When the operator approves the plan, file it as GitHub
Issues — the issue body IS the spec the remote PLAN stage receives:

- **One issue per PR-sized chunk** (PLAN ECONOMY: small tickets get small plans).
  Sequence dependent chunks with `Blocked-by: #<n>` lines, and mean it literally:
  **`Blocked-by` means this chunk needs that chunk's CODE** — it imports, calls,
  extends or migrates on top of what #n adds, so it cannot compile or run until
  #n lands. An ordering *preference* is not a dependency and should not be
  declared: leave the line out, or write `After: #<n>`, which is a note to a
  human (nothing in the harness parses it, so it creates no wait). An
  over-declared blocker is a chunk that sits idle for an hour it did not owe.
  Since 2026-09-14 the harness no longer takes the line on trust: `bin/dep-verify.sh`
  checks each blocker against the child's planned files and its plan's
  `DEPENDS:` line, and releases the child onto main when both say the link is
  ordering-only (docs/BUILD-CONCURRENCY.md, "Verified dependencies"). To pin a
  real code dependency so nothing second-guesses it, write `Blocked-by: #<n> (hard)`
  or `Needs: #<n>` — either one is obeyed with no verification.
- **An emergency chunk gets the `hotfix` label beside `ai-build`.** It plans
  first, builds first, and exceeds the WIP and pool caps by one machine when
  they are at cap (below cap it simply takes a free slot); its PR
  comes back labelled `hotfix` with `HOTFIX:` as the first body line, and the
  fleet announces it when it is first seen, when the PR opens and when it
  merges. Everything else still applies: tests, review, and a `Blocked-by:` /
  `Needs:` line it declares still hold it (a hotfix that needs code which has
  not landed is not ready), and a `paused-<project>` flag still holds it.
- **Body sections:** `## Scope` (what + files to touch), `## Acceptance tests`
  (concrete: test file path + what each asserts, in the repo's framework),
  `## QA screens` (routes + primary flow, for UI work), `## Out of scope`.
  State the repo's Verification Contract commands if the CLAUDE.md doesn't.
- **Repos WITH an `AGENT_ARCHITECTURE.md`:** the plan cites which of its contract
  rules the change touches (by rule number, in `## Scope`) — a boundary it
  crosses, a durable value it writes, a shared root it would otherwise branch.
  An unnamed rule is a rule the builder will not weigh against the shortest
  compiling path.
- File with the user's gh (global PAT):
  `gh issue create -R <slug> --title "..." --label ai-build --body-file <f>`
- THREAD RECENCY IS LAW on the remote side: a newer issue comment voids the body.
  To revise a filed plan, comment on the issue; to hold it, comment `HOLD`;
  to cancel, remove the `ai-build` label or close it.

After filing, report: issue URLs, blocker chain, owning box + cadence (offset
from `bin/fleet-conf.sh <project> offset`, fires every 10 min). PRs come back
under keys like `RA-<issue#>`; tier-1 merges land only with QA proof, and
every tier merges on lead review + gates; risk tiers are reported, not gated.

### Ticket templates the harness ships

Three drafted `ai-build` bodies live in the repo. All are ready to file as-is;
none is filed automatically except where noted:

- **`docs/VMAP-BACKFILL-TICKET.md`** — the **verification map** backfill: explore
  the app + routes and draft `docs/verification-map/` (README index + one entry
  per user-facing feature + driving conventions), in the shape of
  `docs/verification-map/TEMPLATE.md`. That map is what the remote PLAN stage
  reads as its primer (`bin/verification-map.sh render` writes
  `state/<project>-context.md` from it) and what preview QA takes screens and
  selectors from. New projects: `bin/load-project.sh <owner/repo> --vmap-ticket`
  files it at onboarding (opt-in, once per repo). Existing projects: file it by
  hand with `gh issue create -R <slug> --title "verification map: explore the app
  and draft docs/verification-map/" --label ai-build --body-file
  docs/VMAP-BACKFILL-TICKET.md`. Adoption also brings the
  `verification-map-freshness` guardrail, which fails a PR that changes routes
  without touching the map — without it the map is wrong within a month, and a
  wrong map is worse than none because agents drive it as if it were true.
- **`docs/ARCH-AUDIT-TICKET.md`** — the **agent-architecture contract**: run the
  audit brief (`prompts/arch-audit.md`) against the repo and draft
  `AGENT_ARCHITECTURE.md` at its root — the five-rule contract, the repo's own
  named nouns, and a mechanical-backing table that marks every unenforced rule
  `PROSE-ONLY (debt)` rather than letting prose pass for enforcement. Shape:
  `docs/AGENT-ARCHITECTURE-TEMPLATE.md`. That root file is what
  `bin/verification-map.sh` lists into the PLAN primer, so the name and location
  are load-bearing. New projects: `bin/load-project.sh <owner/repo> --arch-ticket`
  (opt-in, once per repo). Existing projects: file it by hand with `gh issue
  create -R <slug> --title "agent architecture: audit the repo and draft
  AGENT_ARCHITECTURE.md" --label ai-build --body-file docs/ARCH-AUDIT-TICKET.md`.
  The audit only ever PROPOSES checks; they reach CI through the normal
  guardrail-promotion PR, reviewed by a person.
- **`guardrails/PILOT-TICKET.md`** — adopting the mechanical guardrail pack
  (hardcoded model ids, native dialogs, RLS on CREATE TABLE) into a repo's CI.

### Rollout — hand the harness a sequence of waves

Use a rollout when the work is a deliberate sequence of 2 to 12 waves that has
to land in order, and you would otherwise file that many issues by hand and sit
there labelling each one as the previous merged. One ticket carries the whole
sequence. The harness files the children and sequences them, so nobody has to
babysit the order. If the chunks are independent, file them as ordinary issues
instead; a rollout is for work where wave 2 builds on wave 1's code.

The body convention is one `## Rollout` section with one block per wave:

```
## Rollout
### Wave: <title>
after: <title of an earlier wave>[, <title>]     (optional; omit for none)
<body: the wave's own Scope / Acceptance tests / QA screens / Out of scope>
### Wave: <title>
...
```

`### Wave: <title>` and `### Wave <n>: <title>` are both accepted. The prefix is
case-insensitive and a space before the colon is fine, so `### wave 3 : a` is
the wave `a`. An `after:` line names waves by the title left once that prefix
comes off, matched case-insensitively. `after:` splits on commas, so no wave
title may contain a comma when any wave has an `after:` line.

What the harness does with it, when the lane runs: it files one child per wave,
titled `<KEY>.<n>: <title>`, whose body is the wave's own text plus a footer
carrying `Part of #<parent>`, `Order: <n> of <total>` and, for a wave that
follows another, `Blocked-by: #<n> (hard)`. Then it parks the master. On the
issues lane that means removing the `ai-build` label; on an in-app board it
means moving the master to `in_progress`. There is no model call in this stage
at all. You already wrote the waves, and the ordinary PLAN stage fleshes each
child out when its turn comes.

Make wave 1 the end-to-end tracer: the thinnest path from a real trigger to an
observable result, so wrong assumptions surface on wave 1 and not after wave 4
is built on them. Later waves each add one capability, not one layer.
Wave 1 also pre-creates the shared seams later waves will touch: a fragment
file or registry slot per wave instead of a shared list each appends to, a
section stub per wave in a shared prompt or doc, an empty module file per wave.
Later waves with disjoint files then build in parallel. Two waves that still
share a file are sequenced by the planner (`PLAN_SIBLING ... choice=after`, then
an `After:` hold until the first one's PR merges or closes), and that decision
is posted once on the held child.

It refuses rather than guesses. Fewer than 2 or more than 12 waves, two waves
with the same title or one with no title, an `after:` that names a later wave,
an unknown wave or itself (an unknown name is quoted with the titles it could
have matched), a comma in a wave title while any wave has an `after:` line, an
indented or empty `after:` line, an unclosed code block, a `## Rollout` heading
inside a wave body (no nested rollouts), and, on an in-app board, a board that
does not advertise the `dependencies` capability. A refusal files nothing: we
would rather leave the ticket alone than file an unsequenced pile of children
nobody asked for. On the issues lane, a refusal of the body's shape is posted
on the master with the parser's reason and how to fix it, once per reason, and
the `ai-build` label comes off. Fix the body, then add `ai-build` back.

To hold or cancel a single wave, comment `HOLD` on that child. The resolver-hold
rule reads the thread newest-first, so the hold stops every rebuild of that
child until a newer `RESUME` lifts it. And revise a filed rollout by commenting
on the children, never by editing the master: thread recency is law on the
remote side, and the master's body has already been consumed.

The lane ships across the slices of issue #816, so a box only dispatches a
rollout once `bin/run-rollout.sh` is present on it. Until that slice lands on a
box, a `## Rollout` body there is planned and built like any other ticket.

## 3. status — check or steer remote work

```bash
BOX=$(~/cromford/bin/box-for.sh <project>)   # "local" = the hub
ssh root@$BOX 'tail -20 /root/harness/logs/<project>.log'
ssh root@$BOX 'ls -t /root/harness/builds/<project>-*/ 2>/dev/null | head; for r in /root/harness/builds/<project>-*/RESULT; do echo "$r: $(head -1 "$r" 2>/dev/null)"; done'
gh pr list -R <slug> --state all --limit 10
gh issue list -R <slug> --label ai-build --state all --limit 20
```

Steering: pause = `ssh root@$BOX 'touch /root/harness/flags/paused-<project>'`
(resume: rm the flag). Force a tick now:
`ssh root@$BOX 'setsid /root/harness/bin/run-triage.sh <project> >/dev/null 2>&1 &'`.
WIP cap: `echo 1 > /root/harness/flags/wip-limit-<project>` on the box.

Fly test host certificate: never run `flyctl ssh issue` directly, and never
with `--overwrite` or into an unbounded `> file` (a hand issue like that looped
for 44 h and wrote 596 GB on 2026-10-05). Use
`~/cromford/bin/issue-testhost-cert.sh [--key PATH] [--force]`. It takes the
remote gate's bounded path and caps flyctl's output at 1 MiB. Exit 0 = a cert is
in place, 1 = issue failed but the old cert is still valid, 125 = no valid cert.

Costs land per-PR (comment on the PR + nightly rollup on the hub). Alerts and
chat go to Telegram and Slack through the console; don't build a second channel.
