# BH-7122: a hub sync killed after the code copy is not "OLD harness"

Doc: none

## What changed

- `bin/harness-sync.sh` writes `state/harness-sync-phase`, one line:
  `<phase> <sha40> <iso-ts>`. The phase is `copied` after the code copy
  (catalog/, agent-core/, bin/, prompts/, fly/, checks/, guardrails/,
  config/, fleet.conf, vercel.conf), `step=<name>` at the start of each step
  after it, and `done` at the end.
- Each foreground post-copy step (catalog-sync, agent-rules, skills,
  pool-halt, worker-phase, cost-caps, codegraph) runs under its own timeout,
  `HARNESS_SYNC_POST_STEP_TIMEOUT_S` (settings row
  `lane.fleet-propagate.harness_sync_post_step_timeout_s`, default 240). A cut
  step does not stop the steps after it, and harness-sync keeps its exit codes.
- Each step writes one `update-runners.log` line:
  `harness sync: step=<name> rc=<n|busy> secs=<n>`. The three detached steps
  (model-prices, docs-sync, console-pages) get it from the new runner
  `bin/harness-sync-step.sh`, which keeps their own timeouts.
- Each deploy step has a marker `state/harness-sync-pending/<step>`
  (`<sha40> <epoch> <queued|rc=<n>> <alerted>`) from copy time until it ends
  rc 0. A failed or cut deploy step writes one ALERTS line per step and sha.
  The next sync logs `re-running pending step <name> from <sha7> (<status>)`.
- `bin/fleet-propagate.sh` runs the hub sync under `timeout
  $HUB_SYNC_TIMEOUT_S` (settings row `lane.fleet-propagate.hub_sync_timeout_s`,
  default 300). After rc 124 it reads the stamp. If the phase is `copied`,
  `step=*` or `done` and the stamp sha is the new sha or descends from it, the
  hub stays `ok`: the run line says `hub=ok(post-copy timeout: <step>)`, the
  record gets `hub_post_copy` and `hub_pending`, and the alert is a
  `--severity warn` beat that names the step and the pending deploy steps.
  Anything else stays the CRITICAL page.
- `bin/alert-verify/fleet-propagate-partial.sh` accepts the new hub token as
  clean.

## Why

The hub step ran the whole sync under one `timeout 300`. The code copy runs
early and most kills land in the steps after it, so a kill paged "Still
running the OLD harness: hub" while the live bin/ was already at the new sha.

## Key rename

The ticket named `lane.harness-sync.post_step_timeout_s`. No lane
`harness-sync` exists in `catalog/lanes.d/`, so the registry cannot build that
key. The knob is on the fleet-propagate lane with the other harness-sync knobs:
`lane.fleet-propagate.harness_sync_post_step_timeout_s`.
