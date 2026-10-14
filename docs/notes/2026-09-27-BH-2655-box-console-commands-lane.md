# Box console commands lane: bin/box-console-commands.sh (BH-2655, BH-2528.2)

Doc: box-console-commands

## What changed

A new per-box lane, `box-console-commands`, and the executor it calls.

- **`bin/box-console-commands.sh`** runs every minute on each project box
  (`catalog/lanes.d/box-console-commands.json` lists them; the hub is not one,
  and the script exits 0 on the hub as well). It claims the rows the hub
  forwarded to this box with `box_ccmd_claim`, 4 cycles 15 s apart. For each
  row it checks, in order:
  1. the row's project resolves through `bin/box-for.sh` to THIS box, else
     `refused: <project> is not owned by <box>` and nothing runs;
  2. a `created_at` older than `BOX_CONSOLE_COMMANDS_TTL_S` is
     `refused: expired (...)` and nothing runs. A row without one runs; the
     hub's `box_ccmd_expire` owns those;
  3. `bcx_run`, then `box_ccmd_result` with the outcome (and the fetch JSON as
     the body for `fetch_log` / `fetch_artifact`).

  A result post that fails is one log line naming the id. The row stays
  `claimed` and is not run again here. A failed claim is one log line and the
  run ends with rc 0; it writes no ALERTS line, because the worker routes
  (#2654) may not be deployed yet.
- **`bin/lib/box-cmd-exec.sh`** holds `bcx_run <type> <project> <payload>
  <id>`. It takes the per-type bodies from the LOCAL branches of
  `bin/poll-commands.sh` (which is unchanged): `run_triage`, `fetch_log`,
  `fetch_artifact`, `chat` (box sessions only; orchestrator chat stays on the
  hub), `update_company_map`, `chat_proposal`, `post_/kill_/revise_proposal`.
  Any other type is `refused: <type> does not run on a box`. It re-checks the
  row itself: fleet.conf membership, JSON payload, slug charset, the fetch
  scripts' `--path` whitelists, a payload `.project` that differs from the row,
  and empty map or chat text. Synchronous calls are `timeout 30`. Detached
  launches close fds 7 and 9, so they never hold the lane lock.
- One difference from poll-commands' copy: the map text is written with
  `jq -j`, so an empty `.content` really is an empty file and is refused.
  `jq -r` adds a newline, which made the old emptiness check never fire.

## Switch, knobs, log

- Switch: `flags/lane-off-box-console-commands` (and `all-off`).
- `BOX_CONSOLE_COMMANDS_CLAIM_LIMIT` (default 10) and
  `BOX_CONSOLE_COMMANDS_TTL_S` (default 300), read through `lane_env_apply`
  from the settings rows BH-2653 seeded.
- `logs/box-console-commands.log`: one `claimed=N done=N failed=N` line per run
  that claimed anything, nothing for an idle tick. `done` counts only rows that
  ran OK and whose result was posted.
