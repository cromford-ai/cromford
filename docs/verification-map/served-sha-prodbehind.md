# Prod-behind-main page (served-sha watch hook)

**What it is:** `bin/lib/served-sha-watch.d/30-prodbehind.sh`, a hook of the hub
lane `bin/served-sha-watch.sh` ([served-sha-watch.md](served-sha-watch.md))
(BH-8255). It pages ONE id per project, `prodbehind:<project>`, that stays the
same when main moves. The older hook [served-sha-alert.md](served-sha-alert.md)
pages one id per head sha and is not changed.

- `wait` or `alert` verdict: the hook keeps a project-level clock
  `.prodbehind.since` in the lane's state file. The first behind tick seeds it
  from HEAD's age. Later ticks keep it, also when HEAD changes.
- When `now - since >= SERVED_SHA_PRODBEHIND_MIN` minutes (default 45), the hook
  reads the project's production deployment list once and takes the deployment
  with the largest `.created`. Only when its state is `ERROR` does the hook write
  `.prodbehind.open = true` and then run
  `ALERT_REMINDER_S=<REPEAT_H*3600> bin/lane-alert.sh --critical --id prodbehind:<project> served-sha-watch "<text>"`,
  with text like
  `PROD BEHIND MAIN: demo-os prod serves 9f8e7d6c, main is 2b2272a4, 6 commits behind for 0h50m. Newest production deployment dpl_fixture1 (2b2272a4) failed (ERROR). Logs: vercel inspect dpl_fixture1 --logs --scope team_x`.
- `in-sync` verdict: one `lane-alert.sh --resolve --id prodbehind:<project>` when
  `.prodbehind.open` is true. The lane then deletes the state file.
- `unreadable` verdict: nothing. No page, no resolve, the clock does not move.

## How to reach it

- It runs inside the lane, so the lane's cron line, flag and Vercel auth apply.
- Knobs on the `served-sha-watch` lane: `SERVED_SHA_PRODBEHIND_MIN` (minutes,
  default 45, 0 = off) and `SERVED_SHA_PRODBEHIND_REPEAT_H` (hours, default 4).
- On a live hub: `jq .prodbehind /root/harness/state/served-sha-watch/<project>.json`,
  `cat /root/harness/state/alerts/prodbehind_<project>.json`, and
  `grep 'PROD BEHIND MAIN' /root/harness/logs/ALERTS.log`.
- The open alert shows as a `prodbehind_<project>` row on the Mission Control
  Alerts screen. The resolve closes it.

## How to drive it in a test

`tests/served-sha-prodbehind.bh-8255-test.sh` builds the lane's scratch harness
with `tests/lib/served-sha-fixture.sh`, copies `30-prodbehind.sh` into
`$T/h/bin/lib/served-sha-watch.d/`, and runs real ticks with `SERVED_SHA_NOW`
pinned. Its recorder `lane-alert.sh` writes `ALERT_REMINDER_S=<v> <argv>` per
call to `$T/alerts.txt`. Case P15 swaps in the real `bin/lane-alert.sh` and
reads `$T/h/logs/ALERTS.log` and `state/alerts/`.

## What usually lies

- `? commits behind` means the hook's own compare read failed. It is never 0.
- A newest deployment that is `BUILDING`, `QUEUED`, `INITIALIZING`, `READY` or
  `CANCELED` is no page. A `READY` newest deployment while prod is behind means a
  pinned domain or a rollback, not a failed build.
- A list read that fails, or a list with no deployment or no state, is "cannot
  tell" and is no page.
- `since` comes from HEAD's committer date on the first behind tick, so the
  first page can come on the first tick after a deploy of this hook.
- One incident can show two pages: `served-behind:<project>:<head12>` (10-alert,
  at `SERVED_SHA_LAG_MIN`) and `prodbehind:<project>` (this hook).
- If the lane is unreadable for longer than lane-alert's `ALERT_AUTO_CLOSE_S`,
  lane-alert closes the id itself, and the next page opens a new incident.
