# Console alerts — keep the Alerts screen truthful

> Executor for the WORKER half: the operator's LOCAL Claude Code (has harness-console source + wrangler).
> The HUB half (`bin/alerts-groom.sh`, cron) is already deployed and FAILS SOFT (exits quietly)
> until the worker endpoints below exist — deploy order is safe either way.

## Goal (the operator, 2026-07-28)
An alert visible on the console Alerts screen must always mean something CURRENT. Handled or
stale alerts clear themselves; nobody hand-taps 50 Resolve buttons.

## Worker changes (console repo)

1. `GET /api/alerts/open` — HARNESS_SECRET bearer. Returns
   `{alerts:[{id, akey, project, line, createdAt}]}` for unresolved alerts (cap 500).
2. `POST /api/alerts/resolve` — HARNESS_SECRET bearer. Body ONE of:
   - `{"ids":[...]}` — resolve specific alerts
   - `{"olderThanHours":N}` — resolve everything older than N hours
   Returns `{resolved:<count>}`.
3. Auto-resolve in the worker (no cron needed, do it lazily on alert LIST/ingest):
   any alert older than 48h whose `akey` has NOT re-fired in the last 24h is marked
   resolved with reason `auto-stale`. A recurring problem keeps re-firing its akey and
   therefore stays visible; a one-off ages out on its own.
4. Resolved alerts keep their row in storage (audit), just leave the open screen.

## Hub half (already live, for reference)

`bin/alerts-groom.sh` — cron every 2h on the HUB only:
- reads EVERY open row, oldest first: D1 `harness-console-db` pages with an id cursor
  (`bin/lib/alerts-open-read.sh`, BH-9114; the worker's `/api/alerts/open` caps at the newest
  500), and `GET /api/alerts/open` is the fallback. Resolves are POSTed in chunks of at most
  `ALERTS_GROOM_RESOLVE_CHUNK` (100) ids. For each alert, resolve it when its subject is VERIFIABLY settled:
  - the row is ABOUT A PR BEING OPEN (an `mq-*` akey, or a line matching
    `ALERTS_PR_SUBJECT_RE`: merge queue, rebase-train, blocked-resolver
    ESCALATED) and that PR is now MERGED or CLOSED. Any owner/repo casing; an
    `mq-<kind>:<project>:<N>` row with no URL resolves its repo via `fleet.conf`;
    one GitHub call per PR per pass. `mq-headbound` / `mq-tc` settle only on a
    close WITHOUT merge (a merge means unreviewed or failing code reached main).
    A row that merely names a PR is NOT settled by its merge (V1, 2026-09-25):
    POST-MERGE PROD QA FAILED / NOT RUN and HOTFIX POST-DEPLOY APPLY FAILED /
    CLOSE-OUT OWED begin at the merge (`tests/alerts-groom-pr-scope.v1-test.sh`).
  - line is a `MIGRATION-PR merged` ping and that app's migrations endpoint reports 0 pending
  - line references a build dir whose RESULT exists and is marked COMMENTED
  - line is `STUCK`/`rc=1` for a project whose last watcher cycle is rc=0/skip (recovered)
- Everything it can't verify it leaves alone — the 48h auto-stale rule catches the rest.
- One log line per pass to `logs/alerts-groom.log`; never beats (grooming is silent).

## V1 alert hygiene (2026-09-25): a closed PR closes its alerts in the same drain

Rows like `mq-hb-lander:<project>:<PR>` stayed open after the PR merged. Two
causes, two fixes:

1. **The groomer could not see some of them.** Its PR match was
   `github\.com/example-org/[a-z-]+/pull/N`, so a repo with capitals, a dot or a
   digit (`example-org/project-9`, `example-org/project-7`) never matched, and a
   merge-queue row whose line carried no URL was invisible. That fix, and the
   scoping of its PR rule to PR-open subjects only, ships separately in the
   groomer PR (`tests/alerts-groom-pr-scope.v1-test.sh`).
2. **The groomer is a 2h cron.** When `bin/wake-loop.sh` drains a
   `pull_request.closed` wake, the `pr-closed` class
   (`bin/lib/wake-class-pr-closed.sh`) now also launches
   `bin/alerts-resolve-closed-prs.sh <owner/repo#N>...` with every PR that
   closed. The webhook is the evidence, so it asks GitHub nothing. It resolves
   (reason `pr-closed-wake`) only rows whose whole subject is the PR being open:
   `mq-*` akeys for that project and PR, and lines naming that PR's URL that
   match `ALERTS_PR_SUBJECT_RE` (default
   `Merge queue: #|\[rebase-train\]|\[blocked-resolver\] ESCALATED`; env or
   `flags/alerts.conf` only, never a settings row). A row that
   only mentions the PR (migration SQL still owed after the merge, a failed
   post-deploy apply) is not settled by the PR closing and is left alone.
   `mq-headbound` and `mq-tc` are never closed here: the webhook does not say
   merged or closed, and a merge there means unreviewed or failing code reached
   main. The groomer, which asks GitHub, settles them on a close without merge.

It is not cooled: it asks nothing external and touches only rows about the PRs
it was handed. One launch per drain. Log lines go to `logs/alerts-groom.log`.

## Acceptance
1. Deploy worker. 2. `curl -H "Authorization: Bearer $HARNESS_SECRET" $CONSOLE_URL/api/alerts/open`
returns JSON. 3. Within 2h the hub groomer resolves the settled backlog; screen shows only live
items. 4. A deliberately re-fired alert (same akey) stays visible past 48h.
