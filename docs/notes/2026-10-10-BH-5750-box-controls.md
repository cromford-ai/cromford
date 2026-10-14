# 2026-10-10 BH-5750: Mission Control box controls

Doc: ADDING-A-BOX, HARNESS-COORDINATION

## What changed

`/machines` can now operate Orgo boxes and Fly pools through the existing
box_commands queue. Each action is a box_commands row addressed to `hub`. The
hub's `box-ops` lane claims it and runs the BH-5749 CLI.

- **Queue store.** The worker reads and writes `box_commands_v2`
  (`worker/jobs/schema.d/0014-bh-5750-box-commands-v2.sql`). It is
  `box_commands` with a wider `type` CHECK. A CHECK cannot change in place on D1
  (BH-1555), and a rebuild needs a DROP, so the new table is the additive path.
  The fragment copies every old row with its id (`INSERT OR IGNORE … SELECT`).
  The old table stays and is not read.
- **Nine new types.** `orgo_restart`, `orgo_stop`, `orgo_resize_quote`,
  `orgo_resize`, `orgo_retire`, `orgo_launch_quote`, `orgo_launch`,
  `fly_pool_cap`, `fly_onboard`. The worker list is
  `worker/jobs/src/lib/box-command-types.js`. The console keeps its own copy in
  `console-ui/src/lib/box-commands.js`.
  `worker/jobs/test/box-command-types-drift.bh-5750.test.js` holds the two
  lists and the v2 CHECK equal.
- **Owner gate.** Each new type is accepted only from an actor in the worker
  secret `BOX_OPS_OWNERS` (comma list, trimmed and lower-cased). Any other actor
  gets 403 `owner_only` and one `refused:owner` audit row. An unset secret means
  nobody is an owner. The actor is the Cloudflare Access email the coord proxy
  stamps, so with Access off every new action is 403. The worker now records an
  email actor as sent. Before, `laneName` turned every email actor into
  `unknown`.
- **Price token.** `orgo_resize` and `orgo_launch` need `quote_id` and
  `confirm_monthly_usd`. The quote must be an ok row of the matching quote type,
  with the same target and args, from the same actor. It must be fresher than
  settings `box_ops_quote_ttl_s` (fallback 900 s). Its recorded figure must
  equal `confirm_monthly_usd`. Else 409 `stale_quote`. The figure comes from the
  quote row's detail, never from the browser: for a resize, the first
  `COST: resize <id> +$N/mo` or `PLAN cost +$N/mo` line (none on an ok quote =
  0); for a launch, `usd_mo=N` (none = no figure). The resize dry run prints the
  `PLAN cost` form. It does not print `COST:`.
- **Hub handlers.** `bin/box-ops.sh` `run_op` runs `box-ops.sh
  restart|stop|resize|retire`, `bin/box-launch.sh`, `bin/pool-cap.sh --set` and
  `bin/fly-onboard.sh`. A quote runs without `--apply`. An apply row runs with
  `--apply` (and `--confirm-monthly-usd <figure>` when it costs money). Rows run
  under `BOX_OPS_ORGO_TIMEOUT_S` (1500 s, below the 1800 s claim TTL). The exit
  map and the detail order are in the script header.
  `already running`, WAITING, NEEDS PURCHASE and every rc other than 0 are
  recorded as `fail`.
- **Retire and launch** run against `BOX_OPS_REPO_ROOT`, passed as `--root`.
  It must be a git checkout top level that is not the live harness root
  (`/root/harness` is an rsync target and not a checkout). When it is unset or
  wrong, the handler refuses `not configured` and runs nothing. A launch quote
  is refused the same way, so a launch never reaches the Orgo create (the
  spend) with a root it cannot finish in.
- **`bin/pool-cap.sh --set <p> <n> [--apply]`** re-numbers an existing
  `flags/fly-pool-<p>` file. It never creates one, because the file is the
  pool's on switch. The print path did not change.
- **`fly_onboard`** calls `bin/fly-onboard.sh <p> [--cap N]`, with no change to
  that script. It is ok only on its `FLY_ONBOARD <p> OK|ALREADY` verdict line.
- **Live Orgo state.** The new hub lane `bin/orgo-state.sh` (every 5 min, from
  `catalog/lanes.d/orgo-state.json`) reads `GET /computers` per account in
  `catalog/orgo-plans.json`. It sends `PUT /api/orgo-computers`
  (`worker/jobs/src/routes/orgo-computers.js`, tables in `schema.d/0015`). A
  complete read sets `gone_at` on a computer that is no longer listed. A failed
  read changes no computer row. An account with no key is logged
  `not configured` and is not sent.
- **Console.** `/machines` adds RESTART, RESIZE, STOP and RETIRE on each Orgo
  row, the ORGO STATE and SPECS columns, a LAUNCH BOX form, and the Fly pool
  CAP and ONBOARD TO POOL controls. A resize or launch first gets a price from
  the hub. CONFIRM is enabled only on an ok quote. The `docs/verification-map`
  entry BH-2518 has the selectors.

## Operator steps

1. Set the worker secret: `npx wrangler secret put BOX_OPS_OWNERS` on
   harness-jobs, with the owner emails as a comma list.
2. Keep Cloudflare Access on for the console (`CF_ACCESS_TEAM_DOMAIN`,
   `CF_ACCESS_AUD`). Without it every owner action is 403.
3. To allow a console retire or launch, set `BOX_OPS_REPO_ROOT` in the hub's
   `env/global.env` to a git checkout of cromford. The retire PR and merge
   stay a human step.
4. Optional: set settings `box_ops_quote_ttl_s` to change the 900 s quote life.
