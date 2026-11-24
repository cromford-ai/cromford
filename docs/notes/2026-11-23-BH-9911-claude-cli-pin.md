# BH-9911 — one pinned Claude Code CLI version; a canary box tests each new release first

Doc: OPERATING

## The defect

`bin/cli-update.sh` (every box, 05:17 through `bin/update-runners.sh`) moved
claude to `latest` every day. On 2026-11-03 that put 2.1.317 on the hub. That
release gave up on stdin after 3 s and broke every orchestrator turn (BH-9019).

## The change

All of it is off until the settings row `claude_cli.pin.enabled` is `1`
(seeded `0`). With the row at `0`, every script below does what it did before.

1. **The pin.** `bin/lib/claude-cli-pin.sh` reads the rows. `claude_cli.pinned_version`
   (seed and code fallback `2.1.330`) is the version the fleet runs.
   `ccp_target_version <box>` gives the canary version on the canary box and
   the pin everywhere else.
2. **Installs.** With the pin on:
   - `bin/cli-update.sh` runs `claude install <V>` / `npm install -g @anthropic-ai/claude-code@<V>`,
     repoints every symlink that is not at `<V>` (newer ones too), and records
     `ok=1` only when claude ends on `<V>`. A planned downgrade is not WORSE.
     Off the pin afterwards: `ok=0`, rc 1, note `off-pin <after> want <V>`.
   - `bin/fly-image-build.sh` bakes the pin (never the hub's version).
   - `bin/bootstrap-machine.sh` block `# >>> claude cli pin (BH-9911)` runs
     `CLI_UPDATE_CLIS=claude CLI_UPDATE_SYS_TOOLS= bin/cli-update.sh`; not on
     the pin afterwards is FATAL.
   - `fly/lane-run.toml`: its build comment reads `claude_cli.pinned_version`.
3. **Knob outage.** Each read of `claude_cli.pin.enabled` is cached in
   `state/claude-cli-pin/pin-enabled`. When the worker cannot answer and the
   last read was `1`, cli-update leaves claude as it is (note `pin-unknown`)
   and the image bake refuses (FATAL). When the last read was `0` or there is
   no cache, both behave as before. This keeps a worker outage from sending a
   pinned box to `latest`.
4. **Canary.** `claude_cli.canary_box` (seed `box-small`) is the one
   box that installs `claude_cli.canary_version`. Names match after one
   leading `HARNESS_BOX_PREFIX` (`box-` by default,
   `bin/lib/deployment.sh`) is removed. The hub is never the canary.
5. **Canary smoke** `bin/claude-cli-smoke.sh` (lane `claude-cli-smoke`, hourly
   :47, every box but the hub; exits at once off the canary). Five agent-call
   steps (`stdin`, `late_stdin` through a PATH wrapper that holds stdin back
   `claude_cli.smoke_late_stdin_s`, `tool_call`, `haiku`, `lane_tick`) and one
   log check (`fail_classes`: a `RUNNER_*` class new since the install). Model
   route `claude-cli.smoke` (copy of `bootstrap.smoke` rung 0). Rows go to D1
   table `claude_cli_smoke` through `POST /api/claude-cli/smoke`. A red model
   step is one ALERTS line `CLAUDE CLI CANARY RED: <V> on <box> failed <step> ...`.
   Dedup before spend: a canary version that is not newer than the pin (after
   promote it has nothing left to prove), unsent pending rows, a failed row
   read, a red version (terminal; `--force` runs it again) or a run younger
   than `claude_cli.smoke_interval_h` make no call. Each step runs under an
   outer `timeout` of `claude_cli.smoke_step_timeout_s` +
   `claude_cli.smoke_step_grace_s`, then KILL after
   `claude_cli.smoke_step_kill_after_s`. A row's detail is cut to
   `claude_cli.smoke_detail_max` (the same row the worker checks, so lowering
   it never turns every POST into a 400) and a step excerpt to
   `claude_cli.smoke_excerpt_max`. A pending file the worker refuses with a 4xx
   (not 401, 403, 404, 408 or 429) moves to
   `state/claude-cli-smoke/dead-<run_id>.json` with ONE ALERTS line
   `CLAUDE CLI SMOKE ROWS REFUSED: ...` and is never resent, so it cannot stop
   the canary for good. A 5xx or an outage keeps the file for the next run.
   A dead-letter file of the canary version whose newest `at` is younger than
   `claude_cli.smoke_interval_h` counts as a run for the dedup (no spend, one
   log line), because its rows never reach D1.
6. **Hub lane** `bin/claude-cli-pin.sh` (lane `claude-cli-pin`):
   - `watch` 04:37: a newer npm release becomes `claude_cli.canary_version`.
     It never writes the pin.
   - `promote` 04:47: sets `claude_cli.pinned_version` to the canary version
     after a complete green run at least `claude_cli.canary_soak_h` (24) old,
     no red model step, the newest run green, and the newest `fail_classes` ok.
   - `drift` 05:52: one warn beat per box (`box_status.cli_version`) or pool
     image (`state/fly/<project>.cli`) off its target; repeats are held in
     `state/claude-cli-pin/drift-sent.tsv`. Summary line
     `drift: <n> of <m> boxes and <k> of <j> images off the pin`.
     A failed read, or an answer with no `boxes` array, is
     `drift: not measured (...)`, never a 0 count.

## Knobs (settings rows; each code fallback equals the seed)

`claude_cli.pin.enabled` 0, `claude_cli.pinned_version` 2.1.330,
`claude_cli.canary_box` box-small, `claude_cli.canary_version` (no
row), `claude_cli.canary_soak_h` 24, `claude_cli.smoke_interval_h` 6,
`claude_cli.smoke_late_stdin_s` 5, `claude_cli.smoke_step_timeout_s` 120,
`claude_cli.fail_class_window_h` 168, `claude_cli.watch_timeout_s` 60,
`claude_cli.drift_max_age_h` 48, `claude_cli.smoke_list_limit` 200,
`lane.claude-cli-smoke.llm_usd_cap_day` 1, `retention.claude_cli_smoke.days` 90.

Seeded in `worker/jobs/schema.d/202611241200-bh-9911-claude-cli-smoke-caps.sql`:
`claude_cli.smoke_step_grace_s` 30 and `claude_cli.smoke_step_kill_after_s` 10
(read by `bin/claude-cli-smoke.sh`), `claude_cli.watch_kill_after_s` 10 (KILL
after `claude_cli.watch_timeout_s` in `watch`), `claude_cli.smoke_excerpt_max` 200
(characters of a step's answer or error kept for the row and the RED line), and
the route bounds read by
`worker/jobs/src/routes/claude-cli-smoke.js` through the settings snapshot:
`claude_cli.smoke_post_rows_max` 50 (rows per POST), `claude_cli.smoke_detail_max`
500 (characters of one row's detail; the smoke reads it too), `claude_cli.smoke_list_limit_max` 500 and
`claude_cli.smoke_list_limit_default` 100 (rows per GET),
`claude_cli.smoke_box_max_len` 128 (characters of box, POST and GET),
`claude_cli.smoke_run_id_max_len` 80 and `claude_cli.smoke_at_max_len` 40
(characters of run_id and at). A row that is absent or not an integer in
range falls back to the code constant.

## Operator step (turn it on)

1. Before 05:17Z, set `claude_cli.pin.enabled=1` (`bin/jobs-client.sh setting-set claude_cli.pin.enabled 1`).
   Turned on after 05:17, the 05:52 drift run warns once for each box not yet on the pin.
2. Read the next drift line on the hub: `bin/claude-cli-pin.sh drift`.
