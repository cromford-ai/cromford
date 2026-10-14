# Project triage off grok, and a fast-fail cooldown for any runner (BH-3224)

Doc: COST

## Why

In the 48h to 2026-09-28 the hub made about 220 grok triage calls that exited
rc 1 in 1-3 s with no usage (cromford, harness-console,
project-8), against 19 priced grok triage calls ($4.63). Each dead
attempt added latency and an unpriced $0 cost row before the ladder fell back.
Grok was first because the hub's `env/global.env` carries `RUNNER_TRIAGE=grok`,
and `bin/runner-routes-seed.sh` copied that into the `stage.triage` route
(model_route_changes id 80, 2026-09-24). The decision from that data: grok comes
off project triage.

## What changed

1. **A settings row pins the run-triage lane to claude.** `worker/jobs/schema.sql`
   seeds `lane.run-triage.runner_triage=claude` (actor `seed`, INSERT OR
   IGNORE, so an operator's edit survives every re-apply). `bin/run-triage.sh`
   runs `lane_env_apply run-triage`, which exports the row over the box env, so
   `RUNNER_TRIAGE=grok` in `env/global.env` no longer picks the runner for
   project triage. Shards launched by run-triage inherit it (`TSH_RUNNER`).
2. **A fast-fail cooldown in `bin/agent-call.sh`** (`bin/lib/runner-fastfail.sh`).
   A listed runner that fails in at most `RUNNER_FASTFAIL_S` seconds with no
   tokens reported is marked in `state/runner-fastfail/<runner>` for
   `RUNNER_FASTFAIL_COOLDOWN_S`. While the mark is live, `runner_ready` says no
   for it, so it is skipped as the primary and as the tier-2 grok rung of every
   stage. When the window ends, the next real call is the reprobe: success
   removes the mark, and another instant failure re-arms it with the same
   `since`. A slow failure, a failure with usage, rc 74..79 (nothing was
   called), an external kill and a budget or context stop neither mark nor
   clear. The mark is per box, because grok's credential is per box.

A primary skipped this way writes one `failovers.log` line, and no ALERTS line:

    <stamp> [<project>] <stage> grok skipped: failed instantly (rc=1, 1s, no usage) — cooling down until 17:10Z, using claude

A caller that allows only that runner (`AGENT_CALL_RUNNERS=grok`) is refused
rc 2 as before, and the refusal says `cooling down after instant failures`
rather than `not installed/authed`.

## Knobs (catalog/lanes.d/_lib.runner-fastfail.json)

| env | default | settings key |
|---|---|---|
| `RUNNER_FASTFAIL_RUNNERS` | `grok` | `lib.runner-fastfail.runner_fastfail_runners` |
| `RUNNER_FASTFAIL_S` | 5 | `lib.runner-fastfail.runner_fastfail_s` |
| `RUNNER_FASTFAIL_COOLDOWN_S` | 1800 (0 = off) | `lib.runner-fastfail.runner_fastfail_cooldown_s` |

A value that is not a number falls back to the default, never to 0.

## Not done here: the stage.triage route row

The `stage.triage` route on live still has grok at rung 0. Flipping it needs an
`UPDATE`, and `worker/jobs/schema.sql` is additive only
(`tests/schema-additive.bh-1000-test.sh`), so it is an operator step: on the
console Model routes page, PUT `stage.triage` rung 0 back to
`claude-fable-5-1` / `claude` (change 80's `before_*`). Until then agent-call
writes one true ALERTS line per project per day saying the run-triage env
value (`claude`) overrides the route. `bin/alerts-medic.sh` and
`bin/watchdog-responder.sh` also call stage `triage` and still read the hub env
`RUNNER_TRIAGE=grok`; the cooldown is what protects them until that line is
removed from the hub's `env/global.env`.

## Operator checks

    grep 'cooling down' /root/harness/logs/failovers.log | tail
    ls -l /root/harness/state/runner-fastfail/ && cat /root/harness/state/runner-fastfail/grok

## Putting grok back

- `bin/harness-ctl.sh set run-triage RUNNER_TRIAGE grok` (or delete the
  `lane.run-triage.runner_triage` row), and PUT `stage.triage` rung 0 to grok
  on the console Model routes page.
- The cooldown stays on and only acts if grok fails instantly again. Turn it off
  with the settings row `lib.runner-fastfail.runner_fastfail_cooldown_s=0`.
