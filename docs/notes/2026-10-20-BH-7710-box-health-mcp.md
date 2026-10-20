# The MCP server finds a hung box and restarts it: box_health, box_restart (BH-7710)

Doc: MCP, LANES

## Why

On 2026-10-20 a box hung from about 04:21Z. Tailscale showed it offline and
Orgo showed it running. Every pool spawn for its project failed at the env
bundle (`ssh env extract from <ip> failed (ssh rc 255)`). Nobody saw it for
about 9 hours. A Mac session found it and restarted it through the Orgo API
by hand. No stored fact said "the hub cannot reach this box".

## What changed

1. **Hub lane `bin/box-ssh-probe.sh`** (`*/2 * * * *`, `# @hub-lanes`, registry
   `catalog/lanes.d/box-ssh-probe.json`, cron `cron/lanes/771-box-ssh-probe.cron`).
   Each tick it ssh's every registry box that has a tailnet IP, is not the hub
   and is not `role: retired`: `ssh -n -o BatchMode=yes -o ConnectTimeout=8 root@<ip> true`
   under `timeout BOX_SSH_PROBE_TIMEOUT_S` (default 15). All probes run at once.
   It counts the lines of `state/pool-tailnet/<ip>.fails` (written by `ptn_note`,
   `bin/lib/pool-tailnet.sh`) inside `POOL_TAILNET_WINDOW_S` (default 900). It
   posts one row per box to `POST /api/box-ssh`. It writes no ALERTS line for an
   unreachable box; `ptn_note` and the watchdog page on that. A bad
   `BOX_SSH_PROBE_TIMEOUT_S` is one ALERTS line and exit 1. No registry is one
   log line and exit 0. Log: `logs/box-ssh-probe.log`.
2. **Table `box_ssh_state`** (`worker/jobs/schema.d/202610201507-bh-7710-box-ssh-state.sql`).
   One row per box, upserted on the PRIMARY KEY. `last_ok_at` moves only on
   rc 0 and is kept in SQL across failed reports. Retention: none needed, the
   table does not grow (one row per box, overwritten each tick).
3. **Routes `worker/jobs/src/routes/box-ssh.js`** (fragment
   `worker/jobs/test/route-table.d/bh-7710-box-ssh.txt`), bearer-gated:
   - `POST /api/box-ssh {rows:[{box, ip, rc, lane_fails, lane_window_s, lane_last_fail_at}]}`:
     1..200 rows, a bad row is counted in `rejected`, the good rows are one batch.
   - `GET /api/box-health`: one entry per registry box with the ssh row, the
     lane failures, the newest lane tick (`last_beat_at`), the Orgo computers
     that carry the box's name (`vm.live`, `vm.gone`), and `restart`, the
     box-commands body that restarts it (`{box:'hub', type:'orgo_restart',
     target:<box_id>, account}`, only for a non-hub box with exactly one live
     computer). A failed sub-read is named in `partial`. Five reads in parallel.
4. **MCP tools `mcp/tools/box-health.mjs`**, one new file; no shared tool file changed.
   Both read ONE route, `GET /api/coord/box-health`.
   - `box_health {box?}` (read): per box `state` (`ok`, `hung`, `unreachable`,
     `unknown`), `ssh` (`reachable`, `last_rc`, `probed_at`, `last_ok_at`,
     `probe_stale`), `heartbeat` (`last_beat_at`, `age_s`), `vm` (`hosted`,
     `status`, `seen_at`, `account`), `lane_ssh_failures`, and `hung`, the list
     of hung boxes. `hung` = a fresh probe (10 min or less) failed, the last
     answer is older than 300 s or never, and the VM is running.
   - `box_restart {box, confirm, force?, reason?}` (guarded): `confirm_required`
     with 0 requests unless `confirm` is the boolean true. It refuses
     `not_vm_hosted` (the hub, no live VM), `vm_state_unknown`, `vm_ambiguous`,
     even with `force`. Without `force` it refuses `ssh_state_unknown`,
     `ssh_state_stale` and `box_answered_ssh: <n>s ago` (inside 300 s). Then it
     sends ONE `POST /api/coord/box-commands` with the `restart` body. The hub's
     `bin/box-ops.sh` runs it with the Orgo key that stays on the hub, and the
     worker writes the `box_command_request` audit row. This is the console
     RESTART button's path. The owner gate (`BOX_OPS_OWNERS`) is unchanged: an
     actor that is not an owner gets `http_403: owner_only`.

## Why the worker joins the reads

The plan read four console routes from the MCP tool, one of them
`/api/coord/orgo-computers`, and sent type `orgo_restart`. `mcp/` is public
tree, and `mcp/test/generic-defaults.test.mjs` G2 refuses the vendor name in
any file under it. So `GET /api/box-health` does the join on the worker, and
the restart command type comes from the worker's answer. The MCP code names
no vendor and makes one request instead of four.

## Drive it

```sh
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"box_health","arguments":{}}}' \
  | HARNESS_CONSOLE_URL=<console> HARNESS_CONSOLE_TOKEN=<token> node mcp/server.mjs
bin/box-ssh-probe.sh            # on the hub, one tick; then read logs/box-ssh-probe.log
```

Tests: `tests/box-ssh-probe.bh-7710-test.sh` (the lane), `tests/mcp-box-health.bh-7710-test.sh`
(wraps `mcp/test/box-health.bh-7710.test.mjs` and `worker/jobs/test/box-ssh.bh-7710.test.js`).
