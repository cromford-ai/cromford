# MCP pause_project / resume_project, and a console pool_hold command (BH-7708)

Doc: MCP, FLY-POOL

## Problem

To pause a project, an MCP session called `pause_board`, then had no project
automerge switch (`set_automerge` is per PR), and had no way to hold the Fly
pool. On 2026-10-20 a pause of one project took 2 tools and a manual check of
the pool queue.

## What changed

1. `mcp/tools/project-pause.mjs` adds two guarded tools. Each one sends three
   console commands in parallel (`POST /api/dash/action`), then reads
   `GET /api/dash/p/<project>` once.
   - `pause_project { project, confirm, reason? }`: `pause_board`,
     `automerge_off`, `pool_hold {hold: true}`.
   - `resume_project { project, confirm, automerge, reason? }`:
     `resume_board`, `pool_hold {hold: false}`, `automerge_on` or
     `automerge_off`.
   - Without `confirm: true` (missing, `false`, `"true"`, `1`) the tool answers
     `confirm_required` and sends nothing. No repo allowlist: the tools take a
     project, not a repo.
   - The result has one entry per part (`board`, `automerge`, `pool`) with
     `ok`, `command_id` and `error`. `ok` is true only when all three parts are
     ok; otherwise `isError` is true. A failed part does not stop the others.
     `state_after` is `{paused, automerge}` from the console read (`null` for a
     field the console did not send as a boolean). A failed read gives
     `state_after: null` and names the route in `partial`.
   - Each part is a queued command. The hub runs it on its next poll, so
     `state_after` can still show the old state.
   - `reason` defaults to `paused with MCP pause_project` /
     `resumed with MCP resume_project`, because the Pages proxy refuses a
     `pause_board` or `resume_board` with no reason.
2. New console command kind `pool_hold` (`{hold, reason, actor}`). The console
   worker does not know it and answers `400 unknown action`. The Pages proxy
   then queues the row itself (`console-ui/functions/_lib/pool-hold-command.js`),
   with the same authed probe as the BH-5820 board commands. So the MCP must
   point `HARNESS_CONSOLE_URL` at the Pages origin. Through the worker host,
   the pool part reports `http_400: unknown action`.
3. `bin/poll-commands.sh` runs `pool_hold` on the hub, in the fleet control
   arm, with `bin/cmd-pool-hold.sh <project> <payload> <id>` (timeout 30 s). It
   is never forwarded.
4. `bin/cmd-pool-hold.sh` uses the pool's existing per-project spawn hold: the
   file `state/pool/<p>/_spawn-hold` and the pool_state spawn row. While it
   stands, the fly-pool tick reaps (running builds finish) but spawns nothing
   and reuses no machine.
   - `hold: true` needs `flags/fly-pool-<p>`. The hold ends after
     `PAUSE_BOARD_TTL_S` (default 604800), the same as the board pause. The
     file is written first, then the row. A row the worker does not take is
     `row: "not written"`, still rc 0.
   - `hold: false` removes the file and clears the row. A failed row clear is
     rc 1 (retryable). It lifts any spawn hold, a lane-failure hold too.
   - rc 0 ok, 3 refused (nothing written), 1 failed.

## Not changed

The fly-pool lane, the pause and automerge arms, `mcp/tools/actions.mjs`,
`mcp/tools/guarded.mjs` and the console worker. The fly-pool tick log line for
a spawn hold still says "the runner lane failed (<why>)"; with an operator
hold, `<why>` starts with `operator hold (console pool_hold <id>)`.
