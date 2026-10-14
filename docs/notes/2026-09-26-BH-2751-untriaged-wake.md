# Untriaged wake: a doorbell for tickets GitHub never rings about (BH-2751 part 2, BH-2754)

Doc: EVENTS

## What changed

Until now the GitHub webhook (`worker/jobs/src/routes/webhooks.js`) was the
only thing that wrote a `wakes` row. An open `ai-build` issue that nobody
touched never rang, so `bin/wake-loop.sh` never triaged it. On 2026-09-26 that
was 145 tickets.

Two pieces fix that. Neither calls a model. The route writes only its `wakes`
row. The lane's own write is the POST, but its call into the real
`bin/unblocked-children.sh` can close a board issue: with revdep on, that
script runs `bin/decompose-parent-close.sh --cooled`, which closes a decomposed
master whose children have all closed and comments on it. The cooling and the
markers are the same as for wake-loop's own call, so the lane only makes that
close happen sooner (every 10 minutes after any close). The dep-verify class is
off for the lane's call (`DEP_VERIFY=0`): its one-time "Building this now"
comment would promise a build for a child this lane then declines to wake.
A box that sets `DEP_VERIFY=1` explicitly in `env/global.env` turns it back
on, because `unblocked-children.sh` loads that file itself.

- **`POST /api/wakes/nudge`** on harness-jobs, bearer-authed like its
  neighbours. Body `{repo, key, reason, dedupe}`. It runs
  `INSERT OR IGNORE INTO wakes (repo, kind, key, event, minute, at)` with
  kind `issue`, event `nudge:<reason>` and minute `nudge:<dedupe>`, and answers
  `{inserted: 0|1}`. Any bad field is a 400 and no statement runs: `repo`
  must be `owner/name`, `key` must be a JSON integer from 1 to 1e9 (a string
  `"12"` is refused), `reason` must be `untriaged` or `unblocked`, and `dedupe`
  must be 1 to 64 chars of `[a-z0-9:#-]`. `key` is stored as TEXT, the same as
  a webhook row, so both share one key space.
- **`bin/untriaged-wake.sh`**, a hub lane on `*/10` (`cron/lanes/171-untriaged-wake.cron`).
  For every GitHub-Issues project (`ut_gh_projects`) it posts:
  - `untriaged:<n>` for an open `ai-build` issue with 0 comments, created more
    than `UNTRIAGED_WAKE_AFTER_MIN` ago (`ut_open_issues`).
  - `unblocked:<n>:<lastdep>` for a child that the real
    `bin/unblocked-children.sh` releases after a close inside the last
    `UNTRIAGED_WAKE_LOOKBACK_MIN`. The script is called the way wake-loop calls
    it on the hub, with `REVDEP_TAKE=0`, plus `DEP_VERIFY=0`. Only the two "every blocker is CLOSED"
    line forms count. The dep-verified soft forms and STACKABLE lines still
    have an open blocker, so they are not "its last dep closed". `lastdep` is
    the named blocker that closed latest in the window, or the highest number
    named when none of them closed in the window.

## Once only

The dedupe store is the existing `UNIQUE idx_wakes_dedupe(repo,kind,key,minute)`.
There is no schema change and no local watermark. Every tick recomputes from
GitHub and re-posts, and the index turns a repeat into `inserted:0`. A webhook
minute (`YYYY-MM-DDTHH:MM:00Z`) can never equal `nudge:*`. The 30-day prune
deletes old nudge rows, so a ticket that is still untriaged after that gets one
fresh nudge per retention window.

## Failure

A nudge is counted only when the worker answers 2xx with `inserted:1`. A 2xx
with `inserted:0` is counted as `already`. Anything else stops posting for the
run and is logged as `could-not-run <code>`: a 404 (route not deployed), a 401,
another non-2xx, a transport failure, or `not-configured` when `JOBS_URL` or
`HARNESS_SECRET` is empty. The rest is left for the next tick. A failed GitHub
read is `could-not-run <status>@<project>`, never zero candidates. A failure on
the closed read keeps the untriaged candidates that were already found. An
open read that reaches its 500-issue cap logs `capped@<project>`, and a closed
read that reaches its 300-row cap logs `capped-closed@<project>`. The
lane always exits 0 and writes one line per run to `logs/untriaged-wake.log`:

```
<ts> untriaged-wake seen=<open issues read> candidates=<n> nudged=<n> already=<n> left=<n>[ (#a #b …)][ capped@<project>][ capped-closed@<project>][ could-not-run <code>[@<project>]]
```

## Knobs and switch

Settings rows on lane `untriaged-wake` (`catalog/lanes.d/untriaged-wake.json`):

| Knob | Default | Range |
|---|---|---|
| `UNTRIAGED_WAKE_AFTER_MIN` | 30 | 1..10080 |
| `UNTRIAGED_WAKE_LOOKBACK_MIN` | 60 | 10..1440 |
| `UNTRIAGED_WAKE_MAX` | 25 | 0..200, where 0 posts nothing |

A value that is not a whole number is `could-not-run knob <NAME>`, with no
read and no post. The lane stops on `flags/lane-off-untriaged-wake`
(`bin/harness-ctl.sh off untriaged-wake`) or on `flags/all-off`.

## Deploy dependency

The lane needs the worker route to be deployed. Until the harness-jobs deploy
lands, every run that has a candidate logs `could-not-run 404` and posts
nothing.
