# BH-9862: a merge that deploys to staging is not live

## What changed in the world

project-3 split its branches on 2026-11-19. `main` deploys to a staging site with
its own database. The live site deploys from the `production` branch, and that
branch moves only when a person publishes a release in the app.

The harness assumed, in five lanes, that a merge to `main` is a production
deploy. For project-3 that assumption did harm in two places within one day:

- `bin/deploy-train.sh` read the production version address after each merge,
  never saw the merge there, and opened a rollback PR (project-3 #1223). An
  operator turned the lane off for the project.
- `bin/board-closeout.sh` moved each ticket to `review` at PR open. The app's
  hourly audit moved it back and told the client. 8 tickets on 2026-11-19.

## The fact, and where it lives

`catalog/release-model.tsv` has one row per project whose default branch
deploys to staging. `bin/lib/release-model.sh` reads it. No row, no file, an
unknown model or a staging row with no `https://` base all answer
`production`, so every other project runs as before.

It is a catalog row and not an env knob for two reasons. The project env file
on a box is immutable, and it sets `VERSION_URL` to production. And a builder
on a pool machine posts the close-out, so the fact must travel with the
checkout.

## What each lane does for a staging project

| Lane | Before | Now |
| --- | --- | --- |
| `bin/board-closeout.sh`, PR open | comment, move to `review` | comment with staging links, no move |
| `bin/board-closeout.sh`, merged | "on its way to production", `done` | "merged and on its way to staging", "not live on production yet", `review`; the production-red defer does not hold it |
| `bin/deploy-train.sh` | checks production, reverts on a miss | checks staging, alerts on a miss with the word "staging", no revert, no deploy hook, no production migration driver; its ledger row carries `target: staging` |
| `bin/merged-ticket-advance.sh` | reads production, "production is serving it" | reads staging, "on staging", "not live on production yet" |
| `bin/postmerge-qa.sh` | gates on production, drives production | gates on staging, then records `NOT_COVERED_NO_QA_ENV` with no drive |
| `bin/migration-autopilot.sh` | applies SQL through the production endpoint | does nothing |

`release_model_apply` is called below each lane's env load, because the env
file is what sets the production address.

## What the harness does not do

It does not release. It never dispatches the project's release workflow, never
pushes to `production`, and never writes "live" for a merge. The project's own
audit says "Live on production" after a release.

## Known limits

- There is no signed-in drive on staging. The QA account, its unban and the
  drive's flags are wired for the production site, and a drive that failed for
  that reason would page as a product defect and hold the ticket. The
  merged-ticket lane advances on `NOT_COVERED_NO_QA_ENV` and its comment says
  that nobody clicked through it on staging. A staging drive is a follow-up.
- A system-filed ticket of a staging project still goes to `done` through the
  merged-ticket lane, with the staging words.
- The `*/15` cron of `bin/apply-migrations.sh` still asks the production app
  for pending files. It applies only what the production bundle itself
  reports, so it cannot put schema ahead of a release.
- The merged-ticket lane has no hold for a slice plan (all projects, older
  than this change).

## After this lands

The deploy-train lane for project-3 can go back on:
`bin/harness-ctl.sh on deploy-train project-3 "BH-9862 landed: the train reads staging"`.
