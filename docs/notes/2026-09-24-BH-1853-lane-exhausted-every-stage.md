# An exhausted runner lane defers from every stage, and one cooled account no longer holds the project

Doc: RUN-BUILD-GRAPH

## What changed

Follow-ups from the #1850 lead review (BH-1853).

- **Every stage reads its own `.class` sidecar** (`bin/run-build.sh`, new block
  `stage lane verdict`). Execute, the three review lenses, their fix rounds and
  the merged re-review used to end `EXECUTE_EMPTY` or `*_BLOCKED` when the
  session ran out of runner lane. Now, when the sidecar says `RUNNER_EXHAUSTED`
  or ` class=auth` (the same predicate as `pool_lane_failure` in
  `bin/fly-pool.sh`), the build ends
  `BUILD_DEFERRED <stage> session ended <class line>`, exit 3. The pool reap
  then cools the account, unpins it and requeues the ticket without charging a
  deferral, the same as for plan. An execute that committed real non-wip work is
  not deferred. It goes on to review as before.

  | stage | RESULT | guard | effect |
  |---|---|---|---|
  | EXECUTE / REVIEW | `BUILD_DEFERRED <stage> session ended RUNNER_EXHAUSTED …` or `… class=auth …` | the stage's `<outfile>.class` sidecar blames the runner lane | retried; the pool reap cools, unpins and requeues without charging a deferral |

- **The plan verdict keeps `exhausted=`**. The class line is rendered as its
  first line capped at 1000 bytes instead of `head -c 200`, which cut the
  `exhausted=` and `resets_at=` fields off a long `seen=` list.
- **No project hold when another account can serve** (`bin/fly-pool.sh`). If the
  reap cooled this machine's account, read the cooldown back, and
  `pool_account_others_ok` finds another account, `_spawn-hold` is not written.
  Only that machine is destroyed, and the next spawn re-leases. Every other lane
  failure holds as before.
- **Cooldown stamps never move backwards**. Every writer of
  `state/quota/cooldown/claude/<acct>` keeps the later of the old and new stamp.
- **Codex-primary ladder**. When the OpenRouter gate refuses the fallback while
  claude can still serve, the stage gets a claude rung in its place.
