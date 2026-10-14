# The deploy wake class: deployment_status drives the train's verify and both migration lanes

Doc: EVENTS

**What changed.** BH-1062 is the BH-1034 child that wires the `deploy` class.
The worker only stores a `deploy` wake for a `deployment_status` whose state is
`success`, so the row means "production is serving this sha" — and three lanes
were learning that fact from a clock instead.

| kind | lanes | machine | flag | cooldown | backstop window |
|---|---|---|---|---|---|
| `deploy` | `deploy-train` (file only, no launch) | the hub, where the train already runs | `wake-lanes-deploy` | none (the one-shot is uncooled) | n/a |
| `deploy` | `migration-autopilot` | hub-local when `crontab -l` names it (`cron/lanes/430-migration-autopilot.cron`), else the owning box | `wake-lanes-deploy` | 120s | 1800s (`WAKE_BACKSTOP_S` default) |
| `deploy` | `apply-migrations` | the owning box, which holds `/root/repos/<project>` | `wake-lanes-deploy` | 120s | 3600s |

**The one-shot.** `bin/lib/wake-class-deploy.sh`'s dispatch writes
`state/deploy-wake-<project>` containing the deployment sha, unconditionally and
with no cooldown, before it launches anything. It is a file rather than a launch
because `bin/deploy-train.sh` is already running when the deploy lands — the only
thing it can be told is "stop sleeping". `train_wait` (which replaced the loop's
single `sleep "${TRAIN_POLL_SECS:-20}"`) now waits in ≤5s slices and returns
early the moment it sees that file, then `rm -f`s it. A stale file left by a
finished train therefore costs the next train exactly one early version curl.
`TRAIN_POLLS` and `TRAIN_POLL_SECS` are unchanged, and `TRAIN_POLL_SECS=0` still
falls straight through.

**The two backstop skips.** `bin/migration-autopilot.sh` and
`bin/apply-migrations.sh` each gained the contract's two lines right after their
own `flock`, keyed on `flags/wake-lanes-deploy` and a per-lane
`state/wake-ran/<lane>-<project>` stamp that only a `WAKE_LAUNCH=1` run writes.
`apply-migrations` guards its call with `[ "$MODE" = cron ]` and passes window
`3600`: a `--files` caller is the hotfix lane (BH-375) and is never skipped.
Every unclear answer — no lib, no flag, no stamp, `flags/wake-lanes-off` — means
RUN, so both lanes' cron lines behave exactly as they do today.

**Inert until armed.** The class flag is off by default, so these files change
nothing until an operator runs:

```
bin/jobs-client.sh flag-set wake-lanes-deploy on "BH-1034"
```

That step is manual and waits on the BH-1059 contract child's worker deploy,
which is what stores `deploy` wakes in the first place.

**What it touches.** `bin/lib/wake-class-deploy.sh` (new), `bin/deploy-train.sh`,
`bin/migration-autopilot.sh`, `bin/apply-migrations.sh`, the two new suites
`tests/wake-deploy-drives-lanes.bh-1062-test.sh` and
`tests/deploy-train-wake-wait.bh-1062-test.sh`,
`docs/verification-map/entries/BH-1062.md`, and this note. `bin/wake-loop.sh`,
`bin/lib/wake-lanes.sh`, `worker/jobs/src/index.js` and every `cron/` file are
untouched by construction.
