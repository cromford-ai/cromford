# The plan-time overlap gate counts a hotspot a plan names only lightly (BH-5268)

Doc: SCHEDULER, BUILD-CONCURRENCY

## What changed

`bin/plan-overlap.sh` already sequenced two plans whose file lists intersect, for
any project: an equal or prefix path against a live build dir, a claim file, or
a fleet `job_claims` row prints `OVERLAP_DEFER <KEY> vs <KEY2> files=[...]`, rc 1,
and the gates stage turns that into BUILD_DEFERRED. Disjoint plans got rc 0.
That is unchanged, and `tests/plan-overlap-fleet.bh-5268-test.sh` now pins it for
a fixture project that is not cromford.

The gap was the file list itself. `bin/planned-files.sh` keeps only paths under
`src|prisma|scripts|e2e|tests|app|lib|components|pages|public|docs|content|middleware`.
A plan that names `bin/deploy.sh`, a `cron/` file or a root `next.config.js` in a
task line or a caller note claimed nothing there, so two plans could never be
seen colliding on exactly the files that conflict most.

Now the stored conflict hotspots (the `conflict_hotspots` rows from BH-5267, read
through `GET /api/conflict-hotspots?project=<p>&limit=<TOP>`) close that gap:

- `bin/lib/plan-hotspots.sh` reads the project's hotspot rows (`ph_hot_list`) and
  finds which of them a plan.md names as a whole path token anywhere outside its
  `## Sibling claims` section (`ph_mentions`). `bin/deploy.sh.bak`,
  `xbin/deploy.sh` and `old/bin/deploy.sh` are not mentions of `bin/deploy.sh`.
- `bin/plan-overlap.sh` judges the candidate's planned files plus its hotspot
  mentions, and does the same for a local sibling build dir's plan.md. A collision
  on a hotspot also prints `PLAN_OVERLAP_HOTSPOT <KEY> vs <OTHER> hot=[...]` on
  stderr (the build's pipeline.log). The `OVERLAP_DEFER` line is unchanged.
- The `hotspot claim` region of `bin/lib/rb/plan.sh` publishes planned files plus
  hotspot mentions as the claim, to `state/claims/<p>/<KEY>` and to the build's
  `job_claims` row, through `$BUILD/claim-files.txt`. So a sibling planner on any
  box sees the light touch too. It logs `HOTSPOT_CLAIM n=<k> source=rows|cache|none`.
  `planned-files.txt` is never changed, so the size and scope gates read what
  they read before.

A hotspot alone never defers anything. It only widens what a plan claims; there
still has to be an in-flight claim on the same path.

## Every decision is recorded on the ticket's job

Each judged run of `bin/plan-overlap.sh` with a `JOB_ID` writes one job artifact,
kind `plan_overlap`, ref `sequenced` or `parallel`, with the detail
`{"project","other","files":[...],"hot":[...],"hot_source":"rows|cache|none"}`.
It shows on the job's Mission Control page. A failed write never changes the
verdict, and no artifact means "not recorded", never "parallel". The kill switch
and the no-plan-data exit record nothing, because nothing was decided. Nothing is
posted to the board issue.

## Failure semantics

- The hotspot read answers only when the body has a `hotspots` array. Anything
  else is an outage, never "no hotspots".
- On an outage the last good list for that project
  (`state/plan-hotspots/<project>.txt`, written on success only) is used, with
  `PLAN_HOTSPOTS_CACHED <p>` on stderr. With no cache: `PLAN_HOTSPOTS_UNREAD <p>`
  and no augmentation, which is exactly the old verdict.
- A row's `file` is used only if it is a safe repo-relative path: no leading `/`,
  no `..`, no empty segment, only `[A-Za-z0-9._@()/+-]`.

## Knobs

Registry lib `plan-overlap-hotspots` (`catalog/lanes.d/_lib.plan-overlap-hotspots.json`),
read through `lib_env_apply`, so a settings row
`lib.plan-overlap-hotspots[.<project>].<env>` is the source of truth:

- `PLAN_OVERLAP_HOTSPOT_TOP`, default 50, 0..500. 0 = off, no request.
- `PLAN_OVERLAP_HOTSPOT_MIN`, default 2, 1..1000. The minimum stored `conflicts`.

A value out of range or not an integer turns hotspots off for that run, with one
`PLAN_HOTSPOTS_BADKNOB <NAME>=<value>` stderr line. It is never clamped.
`OVERLAP_SCHED=0` and `switch.plan-overlap-off` still exit before any read,
including the hotspot request.

## Not in this slice

The `After:` hold marker is BH-4988's (`bin/plan-after.sh`), and a stacked child
basing on main after its parent merges is BH-5234's. Nothing here writes
`Blocked-by:`.
