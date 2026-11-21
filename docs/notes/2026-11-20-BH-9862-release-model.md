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
| `bin/board-closeout.sh`, PR open | comment, move to `review` | comment with staging links, move to `in_progress` (BH-9870) |
| `bin/board-closeout.sh`, merged | "on its way to production", `done` | "merged and on its way to staging", "not live on production yet", stays `in_progress` (BH-9876); the production-red defer does not hold it |
| `bin/deploy-train.sh` | checks production, reverts on a miss | checks staging, alerts on a miss with the word "staging", no revert, no deploy hook, no production migration driver; its ledger row carries `target: staging` |
| `bin/merged-ticket-advance.sh` | reads production, "production is serving it" | reads staging for the deploy fact, then production (BH-9876): production serves the merge = the production comment and the normal move; not yet = "on staging", "not live on production yet", no move; unreadable = nothing this run |
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

## BH-9870: PR open moves the ticket to `in_progress`

The first version made no move at PR open. On project-3 a ticket stays in `todo`
during the build, because nothing moves it at build start. The merge lane
(`bin/merged-ticket-advance.sh`) takes a ticket only in `in_progress` or
`review`, and the app audit reads only `review`, `done` and `in_progress`. So
TK-787 (project-3 PR #1266, merged 2026-11-21) got no merge comment and no move.
The close-out now moves the ticket to `in_progress` at PR open for a staging
project. It is not `review`, because the app audit moves a `review` ticket
with an open PR back.

## BH-9873: the words for a staging project

- `bin/deploy-train.sh` writes `VERIFIED on staging at <sha>` to the log and to
  the deploy queue row. Every other project keeps `VERIFIED live at <sha>`.
- A jq that fails no longer empties the ledger detail of the train.
- The deploy-timeout alert of `bin/postmerge-qa.sh` names staging.
- `bin/check-migration-prs.sh` says that the SQL is applied to staging at merge
  and asks for the production check after the next release.

The train is silent after a merge that a person made by hand. That is correct:
only merges of this box's sweep are enqueued. With an empty queue the train
compares the staging site with `origin/main`, and it departs (and pages on a
failure) only when staging is behind `main` for `SELF_SOURCE_MIN_AGE_MIN`.

## BH-9876: the merge step

TK-787 (project-3 PR #1266, 2026-11-21) showed 2 faults in
`bin/merged-ticket-advance.sh`. The ticket went to `done` on a comment that
said "not live on production yet", because a system-filed ticket always went to
`done`. And that comment was posted 51 minutes after production served the
commit, because the lane read only the staging version.

On the project-3 board `review` and `done` mean live in production. The app audit
compares each merge with the release that production stands for. Before the
release it stamps "On staging" and moves nothing. After the release it moves
an `in_progress` ticket (waiting on the team) and posts the "live" comment.

So for a staging project the harness moves a ticket at merge in one case only:

| Production serves the merge | Comment | Move |
| --- | --- | --- |
| yes | "merged and production is serving it" | the normal one: system-filed to `done`, else `review` and the turn to the client |
| no | "on staging", "not live on production yet", "stays in progress until the release is live" | none; the app audit moves it after the release |
| unreadable | none | none; the next run reads again |

The production read is `<board base>/api/internal/version` with the board
token. The compare is `merge commit...production sha` through the GitHub
compare API (`identical` or `ahead` = serves). `bin/board-closeout.sh` at
`PR_MERGED` also leaves the ticket in `in_progress`.
