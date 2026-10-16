# Repair on push: a push to main wakes repair on the PRs it touches (BH-6963, wave 1 of #6542)

Doc: EVENTS, OPERATING

## What changed

- `wakeOf` (`worker/jobs/src/lib/core.js`) wakes kind `push` for a push to
  the repo's default branch (`repository.default_branch`, else `main`), not
  only `refs/heads/main`. An invalid name (a character outside
  `[A-Za-z0-9._/-]`, or `..`) is read as `main`.
- The wake row's `event` is `push.<before>..<after>` when both shas are full
  40-hex and `before` is not all zeros. Else it stays `push`. The kind and the
  key (the after sha) do not change, so the deploy train, the push wake class
  and pr-snapshot-wakes read the same rows as before.
- New hub lane `bin/repair-on-push.sh`, every minute. It reads the push wakes
  above its own cursor and runs `mc_rebase` at once on each open harness PR
  whose files intersect the push. The 30-minute conductor tick is not changed.

## The kind name

The ticket names the wake kind `main`. The build keeps kind `push`: that kind
is already the default-branch push wake, and five readers key on it. The
parent #6542 said the worker drops `push`; it did not.

## How the lane decides

1. The cursor is `wake_cursors` box `repair-on-push`. The lane reads with
   `GET /api/wakes?since=<cursor>&kind=push`, never a claim: a claim marks a
   row taken even when the lane could not finish it.
2. The first tick with no cursor row plants it at max id and rebases nothing.
3. A wake is complete when every intersecting PR got an `mc_rebase` call or a
   final skip. A wake with a PR skipped for `budget`, `locked`, `rebasing`,
   `files-unreadable`, `pr-unreadable` or `compare-unreadable` is not
   complete: the cursor stays below it and the next tick reads it again.
4. Every `mc_rebase` answer completes that PR, a failure too. rc 3 is also a
   HOLD, and a retry would keep the cursor below the wake for the whole hold.
5. Before a rebase, `GET compare/<after>...<pr head>`: `ahead` or `identical`
   is `reason=current`. That is why a wake read twice never rebases twice.
6. When every listed wake completed and the list was under its limit, the
   cursor moves to max id, so the stale-cursor check does not flag the lane.

## Operator check

```bash
grep REPAIR /root/harness/logs/repair-on-push.log | tail -20
```

Off: `bin/harness-ctl.sh off repair-on-push`. Budget: the settings row
`lane.repair-on-push.repair_push_budget` (default 8 `mc_rebase` calls a tick).
A conflict is a log line, not an alert: the conductor classes the PR
NEEDS_REBASE and `bin/blocked-resolver.sh` owns it (#6964 changes that ladder).
