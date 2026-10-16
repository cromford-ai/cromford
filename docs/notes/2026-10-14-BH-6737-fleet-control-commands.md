# Console command kinds for fleet control (BH-6737)

Doc: MCP

## What changed

Four new console command kinds. Each one runs one new script with the same
interface, `bin/cmd-<x>.sh <project> <payload-json> <command_id>`. Each script
prints ONE JSON line, `{"result":"ok"|"refused"|"failed", …, "reason":"…"}`,
and that line is the command's ack `result`. Exit codes: 0 ok, 3 refused, 1
failed and retryable. `bin/poll-commands.sh` maps rc 3 to `outcome:"refused"`
(BH-932), so the console stops re-leasing a refused row.

| kind | payload | where it runs | script |
|---|---|---|---|
| `dispatch_issue` | `{issue}` | hub, never forwarded | `bin/cmd-dispatch-issue.sh` |
| `machine_ctl` | `{machine_id, op: start\|stop\|destroy}` | hub, never forwarded | `bin/cmd-machine-ctl.sh` |
| `pool_cap` | `{cap}` | hub, never forwarded | `bin/cmd-pool-cap.sh` |
| `run_script` | `{script, args[]}` | row project `hub` → hub; a fleet project → its owning box | `bin/cmd-run-script.sh` |

The project is always the row project. A `project` field in the payload is
ignored.

## Why the three pool kinds run on the hub

The Fly pool exists only on the hub: `bin/fly-pool.sh`, `flags/fly-pool-<p>`,
`flags/fly-pool-app-<p>`, `state/fly/<p>.json` and `env/fly.env`. So
`dispatch_issue`, `machine_ctl` and `pool_cap` run in the hub poller's
`# >>> fleet control handler` arm for every project, like `hold_ticket`. A far
box's `bcx_run` refuses them ("does not run on a box").

## dispatch_issue

It moves an issue that is already queued for the pool to the front of the
next spawn. It does not enqueue a build. The checks, in order: the project is
a GitHub-issues board; `issue` is a positive JSON integer; `flags/fly-pool-<p>`
exists; `hold_check` says open, `ai-build`, not held; nothing builds the key
(build-key lock, a `state/fly-pool/<p>/*.json` record, a `claimed` queue row);
the key is queued (`queued` row, or `state/build-queue/<p>/<KEY>.json`). A
refusal writes nothing.

Then it writes the marker `state/dispatch-now/<p>/<KEY>` and starts one
`bin/fly-pool.sh <p>` tick, detached. `hotfix_first` in `bin/fly-pool.sh` now
orders hot jobs, then marked jobs, then the rest. A marker only changes order.
It does not bypass the cap, the dispatch mode, the hold gate or the per-key
spawn cap. Markers older than 24 h are deleted by the next dispatch.

The script waits up to `CMD_DISPATCH_WAIT_S` (default 20 s) for a pool record
that names the key. `machine_id` comes only from that record. Otherwise it is
`null` and the reason says "no machine yet".

The ticket asked for a `pool_dispatch_now` row. This ships a hub-local file
marker instead: `catalog/state-paths.json` makes `state/pool` a rows path, and
a real row would need a table, a route and a reader. A lost marker loses only
the order, never a build.

## machine_ctl

`bin/fly-api.sh` takes an optional third arg, a machine id
(`^[0-9a-z]{8,32}$`), and a new `destroy` action:
`DELETE /apps/{app}/machines/{id}?force=true`. 200 is `destroyed`, 404 is
`already gone`, any other code is `failed http=<code>` (exit 1). The builder
machine is refused (exit 2). A two-arg call reads the builder machine as
before. An id that is not the builder's uses the pool app in
`flags/fly-pool-app-<p>`.

Before a destroy, `bin/cmd-machine-ctl.sh` refuses when any
`state/fly-pool/<p>/*.json` record names the machine, or a record cannot be
read. That is the `box_ops_fly_destroy` rule. The ack `state` is the last line
that `bin/fly-api.sh` printed after the op.

## pool_cap

`cap` is a JSON integer from 0 to 999, else refused (never clamped). The pool
must be enabled (`flags/fly-pool-<p>` exists), else refused with nothing
written. The command writes ONE settings row, `lane.fly-pool.<p>.pool_cap`
(project lowercased; knob `POOL_CAP` in `catalog/lanes.d/fly-pool.knobs.d/`),
through `bin/jobs-client.sh setting-set`. `bin/pool-cap.sh --knob-key <p>` is
the one definition of the key. cap = 0 is row value 0: no per-project ceiling.
The command writes no `flags/` file (PR #7045, the operator 2026-10-16). The flag file
stays the pool's enable switch and is only read.

`bin/pool-cap.sh <p>` resolves the cap, first hit wins:

1. A number inside `flags/fly-pool-<p>` (written by `pool-cap.sh --set`, BH-5750).
2. The settings row. On a worker outage, the last value in
   `state/settings-cache.json`. Skipped when `POOL_AUTOSCALE=0`.
3. A line in `fly/pool-caps.conf`.
4. 0 (unlimited). `POOL_CAP_MAX` then trims the answer.

The ack `pool_cap` is what `bin/pool-cap.sh <p>` prints after the write. If a
flag number, `POOL_CAP_MAX` or `POOL_AUTOSCALE=0` gives another number, the ack
shows that number and the reason names the source. A failed settings write
is `failed` (retryable), and nothing else changes.

## run_script

`bin/cmd-run-script.sh` runs `bin/<script>` only when the name is an exact
entry of `catalog/run-script-allowlist.json`. The seed list: `fly-idle-check.sh`,
`fly-machine-state.sh`, `box-self-report.sh`, `pool-cap.sh`, `healthcheck.sh`.
These scripts do what their cron runs do (for example, `healthcheck.sh` can
beat an alert). Adding a script is a reviewed PR. A missing or unparseable
allowlist refuses everything.

`args` is at most 16 strings of at most 512 chars. They reach the script as
argv elements only. The run is bounded at 300 s (a timeout is `failed`,
rc 124). Output goes to `logs/run-script.log` between
`=== run_script id=<id> …` and `=== end id=<id> rc=<rc>`. Arg values are not
logged. The log keeps its last 256 KB when it passes 1 MB. `fetch_log` with
`which:"run_script"` reads it (`bin/fetch-log.sh`). The ack carries the
script's own `rc` and the last 300 bytes of output.

A far-box `run_script` reaches its box as a `box_console_commands` row. The
jobs worker route `POST /api/box-console-commands` accepts `type:"run_script"`
(`worker/jobs/src/routes/box-console-commands.js` `TYPES`). A far-box
`run_script` needs the jobs worker deploy that carries this change. Until that
deploy, the worker answers 400 and the ack says `forward to <box> failed`.

## Not in this change

The console `/api/dash/action` arms and the MCP tools that enqueue these
commands are the follow-up ticket. Fly machine create and resize are out of
scope. Until the follow-up ships, a command of these kinds reaches the hub
only as a `commands` row inserted by hand.
