# Untriaged digest lane: bin/untriaged-digest.sh (BH-2756, BH-2751 ask 4)

Doc: ALERTS-STATE-MACHINE, GH-REST

## What changed

A new hub lane, `untriaged-digest`, runs daily at 06:17Z
(`cron/lanes/172-untriaged-digest.cron`, behind `hub-lease.sh check`). For
every project in `fleet.conf`, it sends at most one line a day:

    [<p>] N open tickets with no triage verdict older than Xh (oldest #<n>, <age>h)

- **GitHub-Issues projects** (the rows whose board prefix is `-`,
  `ut_gh_projects`): an open `ai-build` issue with no comment counts as having
  no verdict. The read is `ut_open_issues` from `bin/lib/untriaged-lib.sh`,
  which this lane does not change. A read that hit the 500-issue cap prints
  `N+`.
- **In-app projects** (`bin/fleet-conf.sh --projects-with-board`): a `todo`
  ticket with a null `triageVerdict`, filed by someone other than `system`,
  and active after 2026-07-29. The read is `ut_inapp_untriaged` in the new
  `bin/lib/untriaged-board-read.sh`. The prefix comes from
  `fleet-conf.sh <p> board_prefix`. The token and base come from
  `$HENV/<p>.env` through `bin/lib/board-creds.sh`.

The line goes through `bin/lane-alert.sh --severity warn --id
untriaged-digest:<p>:<yyyymmdd>`, so a second run on the same UTC day sends
nothing. N = 0 sends nothing. There is no LLM call anywhere in the lane.

## Could not count

A failed read is never reported as 0 and never goes silent. In each of these
cases the project gets `[<p>] could not count untriaged tickets (<reason>)`
on the same daily id:

- a GitHub read that was declined (rate limit, 403). The reason is
  `GH_REST_REASON`.
- a board fetch that failed, or a body that is not a board
- an env file with no token or base, or with two of either. `board-creds`
  also writes its own once-a-day `[internal-token]` line for this.
- a count that jq could not compute

If the registry or a lib cannot be read, the line uses `<p>=fleet`.

This means a registry row with a board prefix but no env file on the hub
shows up every day as "could not count (no board token)", for example
`project-8` or `project-9` on a hub that has not been configured
for them yet. That is the point: you see the gap instead of silence.

## Why the in-app list is the registry

The first build (#2852) sourced the four in-app env files by name and kept a
four-row board table. `tests/fleet-projects-not-hardcoded-test.sh` failed it,
and that guard exists because a hardcoded project list is how every project
enrolled after the first four went invisible (2026-09-10). This lane now
names no project. The digest loads only `global.env`.

## The move out of untriaged-sweep

`bin/untriaged-sweep.sh` used to make the boards → tickets curl pair inline
in `sweep()`. That read is now `ut_inapp_untriaged` with a 3600 s age, sourced
below the lane gate. The sweep's ALERTS text, beat payload and
`state/untriaged-alerted.txt` dedupe are unchanged. Its four named `sweep`
calls and env loads are also unchanged (they are allowlisted; rewriting them
was out of scope).

## Knob and switch

- `UNTRIAGED_ALERT_AFTER_H` (settings row on `untriaged-digest`, default 6,
  hours). It must be a whole number ≥ 1. Anything else is refused, not
  clamped. It sends one `untriaged-digest:config:<day>` line and counts
  nothing.
- Off: `bin/harness-ctl.sh off untriaged-digest`
  (`flags/lane-off-untriaged-digest`), or `flags/all-off`. The gate runs
  before any board is read.

Tests: `tests/untriaged-digest.bh-2756-test.sh`.
